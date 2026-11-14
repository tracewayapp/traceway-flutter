import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/persistence/state_store.dart';
import 'package:traceway/src/replay/recordings_transport.dart';
import 'package:traceway/src/replay/replay_controller.dart';
import 'package:traceway/src/session/session_manager.dart';

import 'support.dart';

void main() {
  group('SessionManager', () {
    late int now;
    late List<String> events;
    SessionManager manager(StateStore store) => SessionManager(
          store: store,
          now: () => now,
          onStart: (s, resumed) =>
              events.add('${resumed ? 'resume' : 'start'}:${s.id}'),
          onEnd: (s, endedAt) => events.add('end:${s.id}@$endedAt'),
        );

    setUp(() {
      now = 1000000;
      events = [];
    });

    test('ends after inactivity at the last activity and starts a new one',
        () {
      final m = manager(StateStore(null))..start();
      final first = m.currentId!;
      now += 60000;
      m.markActivity();
      final lastActivity = now;
      now += defaultInactivityMs;
      m.check();
      expect(m.currentId, isNot(first));
      expect(events, [
        'start:$first',
        'end:$first@$lastActivity',
        'start:${m.currentId}',
      ]);
      m.stop();
    });

    test('ends at the maximum duration even with activity', () {
      final m = manager(StateStore(null))..start();
      final first = m.currentId!;
      for (var i = 0; i < 13; i++) {
        now += 5 * 60000;
        m.markActivity();
      }
      expect(m.currentId, isNot(first));
      m.stop();
    });

    test('a restart inside the inactivity window resumes the session', () {
      final store = StateStore(null);
      final a = manager(store)..start();
      final id = a.currentId!;
      expect(a.nextSegmentIndex(), 0);
      a.stop();
      now += 60000;
      final b = manager(store)..start();
      expect(b.currentId, id);
      expect(b.nextSegmentIndex(), 1);
      expect(events.last, 'resume:$id');
      b.stop();
      now += defaultInactivityMs;
      final c = manager(store)..start();
      expect(c.currentId, isNot(id));
      c.stop();
    });
  });

  group('StateStore', () {
    test('persists values across instances', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_state');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = StateStore(dir);
      await a.load();
      a.set('k', {'n': 1});
      a.set('gone', 'x');
      a.set('gone', null);
      await a.flush();
      final b = StateStore(dir);
      await b.load();
      expect(b.get('k'), {'n': 1});
      expect(b.get('gone'), isNull);
    });

    test('a corrupt file starts empty', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_state');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/state.json').writeAsStringSync('{not json');
      final store = StateStore(dir);
      await store.load();
      expect(store.get('k'), isNull);
    });
  });

  group('RecordingsTransport', () {
    RecordingSegment segment() => RecordingSegment(
          exceptionId: 'e1',
          events: [
            {'type': 'flutter_video', 'data': 'AAAA', 'format': 'mp4'}
          ],
          startedAt: DateTime.utc(2026, 1, 1),
          endedAt: DateTime.utc(2026, 1, 1, 0, 0, 10),
        );

    test('posts gzipped JSON with the bearer token', () async {
      late http.Request seen;
      final transport = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      );
      transport.send([segment()]);
      await transport.flush();
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['Content-Encoding'], 'gzip');
      final body = jsonDecode(utf8.decode(gzip.decode(seen.bodyBytes))) as Map;
      final sent = (body['segments'] as List).single as Map;
      expect(sent['exceptionId'], 'e1');
      expect(sent['startedAt'], '2026-01-01T00:00:00.000Z');
      expect(sent.containsKey('sessionId'), isFalse);
      expect(transport.sentSegments, 1);
    });

    test('retries a transient failure and then delivers', () async {
      var calls = 0;
      final transport = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        retryDelaysMs: const [1, 1, 1],
        httpClient: MockClient(
            (_) async => http.Response('', ++calls < 3 ? 503 : 200)),
      );
      transport.send([segment()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 3);
      expect(transport.sentSegments, 1);
      expect(transport.pending, 0);
    });

    test('gives up after the retry budget, and at once on a permanent error',
        () async {
      var calls = 0;
      final failing = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        retryDelaysMs: const [1, 1, 1],
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 500);
        }),
      );
      failing.send([segment()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 4);
      expect(failing.failedSegments, 1);
      expect(failing.pending, 0);

      calls = 0;
      final rejected = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 413);
        }),
      );
      rejected.send([segment()]);
      await rejected.flush();
      expect(calls, 1);
      expect(rejected.failedSegments, 1);
    });
  });

  group('ReplayController', () {
    late List<http.Request> posts;
    ReplayController controller() => ReplayController(
          transport: RecordingsTransport(
            url: 'https://h/api/recordings',
            token: 'tok',
            httpClient: MockClient((request) async {
              posts.add(request);
              return http.Response('{}', 200);
            }),
          ),
          sessionId: () => 's1',
          nextSegmentIndex: () => 0,
        );

    setUp(() => posts = []);

    test('has no stream mode', () {
      final c = controller()..apply(Mode.stream, maxAgeMs: 600000);
      expect(c.mode, Mode.buffer);
    });

    test('never uploads without an exception id', () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      expect(c.flush(30000, null), isFalse);
      expect(c.flush(30000, ''), isFalse);
      await c.drain();
      expect(source.captures, isEmpty);
      expect(posts, isEmpty);
    });

    test('the window is the smaller of the lookback and the buffer age',
        () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 4000);
      final before = DateTime.now();
      expect(c.flush(30000, 'e1'), isTrue);
      await c.drain();
      final window = before.difference(source.captures.single.since!);
      expect(window.inMilliseconds, inInclusiveRange(3900, 4100));
      expect(posts, hasLength(1));
    });

    test('off stops the source, clears frames and refuses to flush', () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      expect(source.running, isTrue);
      c.apply(Mode.off, maxAgeMs: 600000);
      expect(source.running, isFalse);
      expect(source.clears, greaterThan(0));
      expect(c.flush(30000, 'e1'), isFalse);
      await c.drain();
      expect(posts, isEmpty);
    });
  });
}
