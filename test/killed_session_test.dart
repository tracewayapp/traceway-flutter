import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

import 'support.dart';

// An app on a phone is rarely shut down: it goes to the background and the
// system kills it there, so `shutdown()` and the session's own end never
// run. These tests take that path. What the session used reaches the server
// before the kill, and the next launch closes the session the kill left
// open (field-test findings flutter-001 and flutter-002).

const _withReplay = TracewayOptions(remoteConfig: false, screenCapture: true);

int _ms(LogRecord record) => record.timestamp!.toInt() ~/ 1000000;

Iterable<LogRecord> _of(Harness h, String event, String session) =>
    h.named(event).where((r) => attr(r, 'session.id') == session);

/// The `app.memory.peak` observations [h] posted.
List<double> _memoryPeaks(Harness h) => [
      for (final post in h.requestsTo('/api/otel/v1/metrics'))
        for (final rm in proto.ExportMetricsServiceRequest.fromBuffer(
                otlpBody(post))
            .resourceMetrics)
          for (final sm in rm.scopeMetrics)
            for (final m in sm.metrics)
              if (m.name == 'app.memory.peak')
                for (final p in m.histogram.dataPoints) p.sum,
    ];

Map<String, dynamic> _read(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

void main() {
  late Directory dir;
  late File state;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('traceway_killed');
    state = File('${dir.path}/state.json');
  });

  tearDown(() async {
    await TracewayClient.resetForTest();
    await dir.delete(recursive: true);
  });

  /// A session that uploaded one replay clip, so its counters are not 0.
  Future<(Harness, String)> sessionWithReplay() async {
    final h = await startHarness(options: _withReplay, stateDirectory: dir);
    h.client.replaySource = FakeReplaySource();
    final session = h.client.currentSessionId!;
    h.client.captureException(StateError('boom'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await h.client.replay.drain();
    expect(h.requestsTo('/api/recordings'), hasLength(1));
    return (h, session);
  }

  void toBackground(Harness h) {
    h.client.didChangeAppLifecycleState(AppLifecycleState.inactive);
    h.client.didChangeAppLifecycleState(AppLifecycleState.hidden);
    h.client.didChangeAppLifecycleState(AppLifecycleState.paused);
  }

  test('going to the background sends what replay used so far', () async {
    final (h, session) = await sessionWithReplay();
    toBackground(h);
    // Nothing calls flush: going to the background sends what is queued.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final updates = _of(h, 'traceway.session.update', session).toList();
    expect(updates, isNotEmpty,
        reason: 'without it the server keeps what session.start said: '
            'no events, no bytes');
    expect(attr(updates.last, 'traceway.collection.events'), 1);
    expect(attr(updates.last, 'traceway.collection.bytes'), greaterThan(256));
    expect(attr(updates.last, 'traceway.replay.image_bytes'), 0);

    // The counters and the memory peak are stored with the session, for the
    // launch after a kill.
    final disk = _read(state);
    expect(disk['session']['id'], session);
    expect(disk['budget']['sessionId'], session);
    expect(disk['budget']['events'], 1);
    final memory =
        disk.entries.singleWhere((e) => e.key.startsWith('metricsMemory:'));
    expect(memory.value['s'], session);
    expect(memory.value['b'], greaterThan(0));
  });

  test('a flush sends the counters, and only when they changed', () async {
    final (h, session) = await sessionWithReplay();
    await h.client.flush();
    final updates = _of(h, 'traceway.session.update', session).toList();
    expect(updates, isNotEmpty);
    expect(attr(updates.last, 'traceway.collection.events'), 1);
    await h.client.flush();
    expect(_of(h, 'traceway.session.update', session),
        hasLength(updates.length));
  });

  test(
      'the next launch after the session expired ends it, with its counters '
      'and memory peak, before the new session starts', () async {
    final (first, session) = await sessionWithReplay();
    toBackground(first);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // The system kills the app in the background: what is on disk now is all
    // the next launch has.
    final disk = _read(state);
    await TracewayClient.resetForTest();
    // The app is opened again 20 minutes later; the session expired meanwhile.
    const away = 20 * 60 * 1000;
    final stored = Map<String, dynamic>.from(disk['session'] as Map);
    final startedAt = (stored['startedAtMs'] as int) - away;
    final lastActivity = (stored['lastActivityMs'] as int) - away;
    disk['session'] = {
      ...stored,
      'startedAtMs': startedAt,
      'lastActivityMs': lastActivity,
    };
    state.writeAsStringSync(jsonEncode(disk));
    final memory = disk.entries
        .singleWhere((e) => e.key.startsWith('metricsMemory:'))
        .value as Map;

    final next = await startHarness(options: _withReplay, stateDirectory: dir);
    await next.client.flush();
    final ends = _of(next, 'session.end', session).toList();
    expect(ends, hasLength(1),
        reason: 'the SDK closes the session the kill left open, instead of '
            'leaving it to the server 15 minutes after its last data');
    final end = ends.single;
    expect(_ms(end), lastActivity);
    expect(attr(end, 'traceway.session.started_at'), startedAt);
    expect(attr(end, 'traceway.collection.events'), 1);
    expect(attr(end, 'traceway.collection.bytes'), disk['budget']['bytes']);
    expect(attr(end, 'traceway.replay.image_bytes'), 0);

    final current = next.client.currentSessionId;
    expect(current, isNot(session));
    expect(attr(next.named('session.start').single, 'session.id'), current);
    expect(next.eventNames.indexOf('session.end'),
        lessThan(next.eventNames.indexOf('session.start')));
    expect(_memoryPeaks(next), [memory['b']]);
  });

  /// Moves the stored session [by] ms into the past, as if the app had not
  /// run for that long.
  void age(int by) {
    final disk = _read(state);
    final stored = Map<String, dynamic>.from(disk['session'] as Map);
    disk['session'] = {
      ...stored,
      'startedAtMs': (stored['startedAtMs'] as int) - by,
      'lastActivityMs': (stored['lastActivityMs'] as int) - by,
    };
    state.writeAsStringSync(jsonEncode(disk));
  }

  test('a session shutdown ended is not ended again by a later launch',
      () async {
    final h = await startHarness(options: _withReplay, stateDirectory: dir);
    final session = h.client.currentSessionId!;
    await TracewayClient.resetForTest();
    expect(_of(h, 'session.end', session), hasLength(1));
    age(20 * 60 * 1000);
    final next = await startHarness(options: _withReplay, stateDirectory: dir);
    await next.client.flush();
    expect(_of(next, 'session.end', session), isEmpty);
    expect(next.client.currentSessionId, isNot(session));
  });

  test(
      'a launch that reports no sessions still ends the one an earlier '
      'launch reported', () async {
    final (first, session) = await sessionWithReplay();
    toBackground(first);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final disk = _read(state);
    await TracewayClient.resetForTest();
    state.writeAsStringSync(jsonEncode(disk));
    age(20 * 60 * 1000);
    final next = await startHarness(
        options: const TracewayOptions(remoteConfig: false, sessions: false),
        stateDirectory: dir);
    await next.client.flush();
    final end = _of(next, 'session.end', session).single;
    expect(attr(end, 'traceway.collection.events'), 1);
    expect(next.named('session.start'), isEmpty);
  });

  test('a shorter inactivity timeout ends a killed session sooner',
      () async {
    TracewayClient.sessionInactivityOverride =
        const Duration(milliseconds: 400);
    addTearDown(() => TracewayClient.sessionInactivityOverride = null);
    final first = await startHarness(stateDirectory: dir);
    final session = first.client.currentSessionId!;
    toBackground(first);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final disk = _read(state);
    await TracewayClient.resetForTest();
    state.writeAsStringSync(jsonEncode(disk));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final next = await startHarness(stateDirectory: dir);
    await next.client.flush();
    expect(_of(next, 'session.end', session), hasLength(1));
    expect(next.client.currentSessionId, isNot(session));
  });
}
