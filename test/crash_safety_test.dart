// ignore_for_file: deprecated_member_use
// CONTRACT §13: the SDK never takes the app down. Internal pieces are made
// to fail, and the app's own operation must complete while later SDK calls
// still work; every public call is made before the SDK starts, after it
// stops, twice and at the same time; the app's own crashes still reach the
// handlers that were there before.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart' as logging;
import 'package:traceway/src/core/control_state.dart';
import 'package:traceway/src/core/merge.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/error_handler.dart';
import 'package:traceway/src/events/network_capture.dart';
import 'package:traceway/src/guarded.dart';
import 'package:traceway/src/metrics/app_vitals.dart';
import 'package:traceway/src/metrics/metrics_recorder.dart';
import 'package:traceway/src/metrics/pending_metrics.dart';
import 'package:traceway/src/opamp/client.dart';
import 'package:traceway/src/opamp/messages.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/src/persistence/buffer_persistence.dart';
import 'package:traceway/src/persistence/state_store.dart';
import 'package:traceway/src/replay/network_state.dart';
import 'package:traceway/src/replay/replay_source.dart';
import 'package:traceway/src/replay/video_recorder.dart';
import 'package:traceway/src/traceway_client.dart'
    show TracewayTestOverrides;
import 'package:traceway/src/traceway_mask.dart';
import 'package:traceway/src/wireframe/vnode.dart';
import 'package:traceway/src/wireframe/wireframe_capture.dart';
import 'package:traceway/src/wireframe/wireframe_images.dart';
import 'package:traceway/src/wireframe/wireframe_recorder.dart';
import 'package:traceway/traceway.dart';

import 'support.dart';

/// An app object whose `toString` throws: a `late` field read too early.
class _Hostile {
  @override
  String toString() => throw StateError('toString');
}

/// A pattern of the app's that throws when it is matched.
class _HostilePattern implements Pattern {
  @override
  Iterable<Match> allMatches(String string, [int start = 0]) =>
      throw StateError('pattern');

  @override
  Match? matchAsPrefix(String string, [int start = 0]) =>
      throw StateError('pattern');
}

/// A screen recorder that fails at everything a recorder does.
class _ThrowingSource implements ReplaySource {
  bool running = false;

  @override
  bool get isRunning => running;

  @override
  void start() => running = true;

  @override
  void stop() => running = false;

  @override
  void clearBuffer() {}

  @override
  bool hasFrames({DateTime? since, DateTime? until}) =>
      throw StateError('hasFrames');

  @override
  Future<SessionRecordingPayload?> captureRecording(String clipId,
          {DateTime? since, DateTime? until}) =>
      throw StateError('captureRecording');
}

/// A recorder whose clip is never made: a platform encoder that never
/// answers.
class _StuckSource extends FakeReplaySource {
  @override
  Future<SessionRecordingPayload?> captureRecording(String clipId,
          {DateTime? since, DateTime? until}) =>
      Completer<SessionRecordingPayload?>().future;
}

class _ThrowingLogExporter implements LogRecordExporter {
  int calls = 0;

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logs) async {
    calls++;
    throw StateError('export');
  }

  @override
  Future<void> forceFlush() => throw StateError('forceFlush');

  @override
  Future<void> shutdown() => throw StateError('shutdown');
}

class _Proxy extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'PROXY proxy.test:8888';
}

/// Uncaught errors [body] leaves in its zone.
Future<List<Object>> _zoneErrors(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body();
    } finally {
      done.complete();
    }
  }, (error, stack) => errors.add(error));
  await done.future;
  // Errors of futures nothing awaited arrive a turn or two later.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return errors;
}

/// What an app observer registered after Traceway's is told.
class _LifecycleSpy with WidgetsBindingObserver {
  final List<AppLifecycleState> states = [];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => states.add(state);
}

/// Stops the SDK at the end of a widget test, as the app would.
void _stopAfter(WidgetTester tester) => addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(TracewayClient.resetForTest);
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(TracewayClient.resetForTest);

  group('guarded', () {
    test('contains a failure and never rethrows', () async {
      var after = false;
      expect(() => guarded('test', () => throw StateError('x')), returnsNormally);
      guarded('test', () => after = true);
      expect(after, isTrue);
      expect(guardedOr('test', 7, () => throw StateError('x')), 7);
      expect(guardedOr('test', 7, () => 8), 8);
      await expectLater(
          guardedAsync('test', () async => throw StateError('x')), completes);
      await expectLater(
          guardedAsync('test', () => throw StateError('sync')), completes);
    });

    test('debug output: one line per place, through no Traceway record',
        () async {
      final h = await startHarness();
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      addTearDown(() => debugPrint = previous);
      guardedDebugLogging = true;
      addTearDown(() => guardedDebugLogging = false);
      for (var i = 0; i < 3; i++) {
        guarded('crash-safety place', () => throw StateError('boom $i'));
      }
      expect(printed.where((l) => l.contains('crash-safety place')),
          ['Traceway: crash-safety place failed: Bad state: boom 0']);
      await h.client.flush();
      expect(h.named(eventException), isEmpty);
    });

    test('safeToString describes an object whose toString throws', () {
      expect(safeToString(_Hostile()), "Instance of '_Hostile'");
      expect(safeToString(null), 'null');
      expect(safeToString(3), '3');
    });
  });

  group('FLT-1: public calls with hostile arguments', () {
    test('capture and log calls never throw into the app, and later calls '
        'still work', () async {
      final h = await startHarness();
      expect(() => Traceway.captureException(_Hostile(), StackTrace.current),
          returnsNormally);
      expect(() => Traceway.captureException(_Hostile()), returnsNormally);
      expect(() => Traceway.log('x', error: _Hostile()), returnsNormally);
      expect(
          () => Traceway.log('x',
              error: _Hostile(), stackTrace: StackTrace.current),
          returnsNormally);
      expect(
          () => Traceway.startInteraction('checkout')
              .captureException(_Hostile()),
          returnsNormally);
      expect(
          () => Traceway.startInteraction('checkout')
              .setAttribute('k', _Hostile()),
          returnsNormally);
      expect(
          () => Traceway.recordAction(
              category: 'c', name: 'n', data: {'k': _Hostile()}),
          returnsNormally);
      expect(() => Traceway.metric('checkout.duration', 1, {'k': _Hostile()}),
          returnsNormally);
      expect(() => h.client.captureUnhandledException(_Hostile()),
          returnsNormally);
      Traceway.captureException(StateError('after'));
      await h.client.flush();
      final messages =
          h.named(eventException).map((r) => attr(r, 'exception.message'));
      expect(messages, contains("Instance of '_Hostile'"));
      expect(messages, contains('Bad state: after'));
    });

    test('a package:logging record with a hostile error is no uncaught error',
        () async {
      final h = await startHarness();
      final errors = await _zoneErrors(() async {
        logging.Logger('checkout').severe('failed', _Hostile());
        await h.client.flush();
      });
      expect(errors, isEmpty);
    });

    test('an ignoreErrors pattern that throws matches nothing, and captures '
        'keep working', () async {
      final h = await startHarness(
          options: TracewayOptions(
              remoteConfig: false, ignoreErrors: [_HostilePattern()]));
      expect(() => h.client.captureException(StateError('kept')),
          returnsNormally);
      expect(() => h.client.captureUnhandledException(StateError('crash')),
          returnsNormally);
      await h.client.flush();
      expect(h.named(eventException), hasLength(2));
    });

    test('a beforeCapture that throws keeps the record', () async {
      final h = await startHarness(
          options: TracewayOptions(
              remoteConfig: false,
              beforeCapture: (_) => throw StateError('callback')));
      expect(() => Traceway.captureMessage('kept'), returnsNormally);
      await h.client.flush();
      expect(h.named(eventMessage), hasLength(1));
    });
  });

  group('FLT-2: the app\'s own uncaught errors', () {
    late ErrorCallback? previousPlatform;
    late FlutterExceptionHandler? previousFlutter;
    setUp(() {
      previousPlatform = PlatformDispatcher.instance.onError;
      previousFlutter = FlutterError.onError;
    });
    tearDown(() {
      PlatformDispatcher.instance.onError = previousPlatform;
      FlutterError.onError = previousFlutter;
    });

    /// Runs [body] as `Traceway.run` runs the app, in a zone of its own
    /// inside a zone of the host's that collects what reaches it.
    Future<List<Object>> inTracewayZone(
        ErrorHandler handler, void Function() body) async {
      final host = <Object>[];
      runZonedGuarded(() {
        runZonedGuarded(body, handler.handleZoneError);
      }, (error, stack) => host.add(error));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return host;
    }

    test('reach an enclosing zone once, after Traceway recorded them once',
        () async {
      final h = await startHarness();
      final handler = ErrorHandler()..install();
      final error = StateError('async');
      final host = await inTracewayZone(handler, () {
        scheduleMicrotask(() => throw error);
      });
      await h.client.flush();
      expect(host, [same(error)]);
      expect(h.named(eventException), hasLength(1));
    });

    test('from the root zone they reach the app\'s PlatformDispatcher.onError '
        'once, recorded once', () async {
      final h = await startHarness();
      final seen = <Object>[];
      PlatformDispatcher.instance.onError = (error, stack) {
        seen.add(error);
        return true;
      };
      final handler = ErrorHandler()..install();
      final error = StateError('async');
      // What the engine does with an error the root zone did not handle.
      final host = <Object>[];
      runZonedGuarded(() {
        runZonedGuarded(
            () => scheduleMicrotask(() => throw error), handler.handleZoneError);
      }, (e, s) {
        host.add(e);
        PlatformDispatcher.instance.onError!(e, s);
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await h.client.flush();
      expect(host, [same(error)]);
      expect(seen, [same(error)]);
      expect(h.named(eventException), hasLength(1));
      // Another error that only the platform handler sees is recorded.
      PlatformDispatcher.instance.onError!(StateError('isolate'), StackTrace.current);
      await h.client.flush();
      expect(h.named(eventException), hasLength(2));
    });

    test('without the SDK running they still reach the enclosing zone',
        () async {
      final reported = <FlutterErrorDetails>[];
      FlutterError.onError = reported.add;
      final error = StateError('lost?');
      final host = await inTracewayZone(ErrorHandler(), () {
        scheduleMicrotask(() => throw error);
      });
      expect(host, [same(error)]);
      expect(reported, isEmpty);
    });

    test('a Flutter error still reaches the app\'s handler once', () async {
      final h = await startHarness();
      final seen = <Object>[];
      FlutterError.onError = (details) => seen.add(details.exception);
      ErrorHandler().install();
      FlutterError.reportError(
          FlutterErrorDetails(exception: StateError('layout')));
      await h.client.flush();
      expect(seen, hasLength(1));
      expect(h.named(eventException), hasLength(1));
    });
  });

  group('FLT-3: a failing replay flush', () {
    test('does not lose the exception that ran it', () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, screenCapture: true));
      h.client.replaySource = _ThrowingSource();
      expect(() => h.client.captureException(StateError('real')),
          returnsNormally);
      await h.client.flush();
      final issue = h.named(eventException).single;
      expect(attr(issue, 'exception.message'), 'Bad state: real');
      expect(attr(issue, 'traceway.replay.status'), 'buffer_unavailable');
      // The SDK keeps working.
      h.client.captureException(StateError('next'));
      await h.client.flush();
      expect(h.named(eventException), hasLength(2));
    });

    test('a damaged record restored from disk leaves out that record only',
        () {
      final persistence = BufferPersistence(null)
        ..restored.addAll([
          RestoredEntry(10, 'console', 'logs',
              Uint8List.fromList(utf8.encode('not protobuf')), null),
          RestoredEntry(20, 'console', 'logs', _restorableLogs, null),
        ]);
      final bodies = persistence.take(0, null, 100, (_) => true);
      expect(bodies['logs'], hasLength(1));
      expect(persistence.restored, isEmpty);
    });
  });

  group('FLT-4: a damaged pending metrics payload', () {
    test('is dropped by take, the others still go', () {
      final store = StateStore(null);
      final now = DateTime.now().millisecondsSinceEpoch;
      store.set('metricsPending', [
        {'id': 'bad', 't': now, 'p': '%%%'},
        {'id': 'good', 't': now, 'p': base64Encode([1, 2, 3])},
      ]);
      final pending = PendingMetrics(() => store);
      late List<PendingPayload> taken;
      expect(() => taken = pending.take({}), returnsNormally);
      expect(taken.map((p) => p.id), ['good']);
      expect(store.get('metricsPending'), isNull);
    });

    test('does not stop the start-up, nor file an uncaught error', () async {
      final dir = await Directory.systemTemp.createTemp('traceway-crash');
      addTearDown(() => dir.delete(recursive: true));
      final first = await startHarness(stateDirectory: dir);
      await first.client.shutdown();
      final file = File('${dir.path}/state.json');
      final state = jsonDecode(await file.readAsString()) as Map;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final key in [
        'metricsPending',
        ...state.keys.where((k) => '$k'.startsWith('metricsMemory:')).map(
            (k) => 'metricsPending:${'$k'.substring('metricsMemory:'.length)}'),
      ]) {
        state[key] = [
          {'id': 'x', 't': now, 'p': '%%%'}
        ];
      }
      state['localCaptures'] = [
        {
          'id': 'local:t',
          'triggerId': 't',
          'untilMs': now + 600000,
          'signals': ['network'],
          'replay': false,
        }
      ];
      await file.writeAsString(jsonEncode(state));
      late Harness second;
      final errors = await _zoneErrors(() async {
        second = await startHarness(stateDirectory: dir);
        await second.client.flush();
      });
      expect(errors, isEmpty);
      expect(second.client.control.modeFor('network'), Mode.stream);
    });
  });

  group('FLT-5: hooks in the app\'s control flow', () {
    test('a lifecycle change with a failing recorder returns normally',
        () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              recordAllSessions: true));
      h.client.replaySource = _ThrowingSource();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]) {
        expect(() => h.client.didChangeAppLifecycleState(state),
            returnsNormally);
      }
      h.client.captureMessage('still working');
      await h.client.flush();
      expect(h.named(eventMessage), hasLength(1));
    });

    testWidgets('a lifecycle change through the binding with a failing '
        'recorder reaches the app\'s observers and reports nothing',
        (tester) async {
      final h = (await tester.runAsync(() => startHarness(
          options: const TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              recordAllSessions: true))))!;
      _stopAfter(tester);
      h.client.replaySource = _ThrowingSource();
      final app = _LifecycleSpy();
      tester.binding.addObserver(app);
      addTearDown(() => tester.binding.removeObserver(app));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        expect(tester.takeException(), isNull, reason: '$state');
      }
      expect(app.states, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap through the Traceway widget reaches the app with a '
        'failing recorder', (tester) async {
      final h = (await tester.runAsync(() => startHarness(
          options: const TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              recordAllSessions: true))))!;
      _stopAfter(tester);
      var taps = 0;
      await tester.pumpWidget(Traceway(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: GestureDetector(
            onTap: () => taps++,
            child: const Text('Pay'),
          ),
        ),
      ));
      await tester.pump();
      h.client.replaySource = _ThrowingSource();
      await tester.tap(find.text('Pay'));
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('FLT-6: Traceway.run twice', () {
    testWidgets('records an error once and wraps HTTP once', (tester) async {
      final h = (await tester.runAsync(() => startHarness(
          options: TracewayOptions(
              remoteConfig: false,
              captureMetrics: false,
              beforeCapture: (_) {
                _beforeCaptureCalls++;
                return true;
              }))))!;
      _stopAfter(tester);
      _beforeCaptureCalls = 0;
      final previousFlutter = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      final previousHttp = HttpOverrides.current;
      final seen = <Object>[];
      FlutterError.onError = (details) => seen.add(details.exception);
      try {
        for (var i = 0; i < 2; i++) {
          Traceway.run(
            token: 'test-token',
            baseUrl: 'https://traceway.test',
            child: const SizedBox(),
          );
        }
        await tester.pump();
        FlutterError.reportError(
            FlutterErrorDetails(exception: StateError('once')));
        final overrides = HttpOverrides.current;
        expect(overrides, isA<TracewayHttpOverrides>());
        expect((overrides as TracewayHttpOverrides).previousForTest,
            isNot(isA<TracewayHttpOverrides>()));
      } finally {
        FlutterError.onError = previousFlutter;
        PlatformDispatcher.instance.onError = previousPlatform;
        HttpOverrides.global = previousHttp;
      }
      expect(seen, hasLength(1));
      expect(_beforeCaptureCalls, 1);
      await tester.runAsync(() => h.client.flush());
      expect(h.named(eventException), hasLength(1));
    });
  });

  group('FLT-7: the app\'s HTTP override', () {
    test('still picks the proxy', () {
      final o = TracewayHttpOverrides(_Proxy());
      expect(o.findProxyFromEnvironment(Uri.parse('http://x.test'), const {}),
          'PROXY proxy.test:8888');
      expect(
          TracewayHttpOverrides(null)
              .findProxyFromEnvironment(Uri.parse('http://x.test'), const {}),
          'DIRECT');
    });

    test('a request made through it takes the app\'s proxy', () async {
      final asked = <Uri>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((request) {
        asked.add(request.uri);
        request.response
          ..statusCode = 204
          ..close();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final request =
            await client.getUrl(Uri.parse('http://upstream.invalid/x'));
        final response = await request.close();
        await response.drain<void>();
        client.close();
        expect(response.statusCode, 204);
      }, TracewayHttpOverrides(_LoopbackProxy(proxy.port)));
      expect(asked.single.toString(), 'http://upstream.invalid/x');
    });
  });

  group('FLT-8: the app\'s OpenTelemetry', () {
    test('an app may set OpenTelemetry up after Traceway started', () async {
      final h = await startHarness();
      final hostSpans = InMemorySpanExporter();
      await expectLater(
          OTel.initialize(
            serviceName: 'host',
            enableMetrics: false,
            detectPlatformResources: false,
            spanProcessor: SimpleSpanProcessor(hostSpans),
          ),
          completes);
      final tracer = OTel.tracerProvider().getTracer('host');
      tracer.startSpan('host span', root: true).end();
      h.client.captureMessage('still Traceway');
      h.client.recordNetworkEvent(NetworkEvent(
          method: 'GET',
          url: 'https://example.test',
          statusCode: 200,
          duration: Duration.zero));
      await h.client.flush();
      expect(h.named(eventMessage), hasLength(1));
      expect(hostSpans.spans.map((s) => s.name), ['host span']);
      // Traceway's shutdown leaves the app's tracing running.
      await h.client.shutdown();
      tracer.startSpan('after', root: true).end();
      await Future<void>.delayed(Duration.zero);
      expect(hostSpans.spans.map((s) => s.name), ['host span', 'after']);
    });

    test('spans the app makes before setting OpenTelemetry up are not '
        'Traceway\'s', () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false,
              collection: {
                'signals': {
                  'network': {'mode': 'stream'}
                }
              }));
      OTel.tracerProvider().getTracer('host').startSpan('app span', root: true).end();
      await h.client.flush();
      expect(h.spans.spans.map((s) => s.name), isNot(contains('app span')));
    });
  });

  group('FLT-11: video and maskAllInputs', () {
    testWidgets('password pixels are blank even when general input masking is off',
        (tester) async {
      final root = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: root,
            child: Column(children: [
              TextField(
                  key: const ValueKey('email'),
                  controller: TextEditingController(text: 'me@mail.test')),
              const TextField(obscureText: true),
              const SelectableText('read only'),
            ]),
          ),
        ),
      ));
      final context = root.currentContext!;
      final origin = tester.getTopLeft(find.byKey(root));
      final password = tester.allRenderObjects.whereType<RenderEditable>()
          .singleWhere((r) => r.obscureText);
      final passwordBounds = MatrixUtils.transformRect(
          password.getTransformTo(null), Offset.zero & password.size);
      for (final all in [false, true]) {
        final regions = maskRegionsIn(context, maskAllInputs: all);
        expect(regions, hasLength(all ? 2 : 1));
        final blank = regions.singleWhere((r) => r.mode is TracewayMaskBlank);
        expect(blank.rect.shift(origin), passwordBounds);
      }
      final regions = maskRegionsIn(context, maskAllInputs: true)
          .where((r) => r.mode is TracewayMaskBlur);
      final typed = tester.allRenderObjects
          .whereType<RenderEditable>()
          .singleWhere((r) => !r.obscureText && !r.readOnly);
      final field = MatrixUtils.transformRect(
          typed.getTransformTo(null), Offset.zero & typed.size);
      expect(regions.single.rect.shift(origin), field);
      expect(regions.single.mode, isA<TracewayMaskBlur>());
    });

    test('the video recorder follows replay.maskAllInputs', () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, screenCapture: true));
      final recorder = FakeVideoRecorder(TracewayVideoRecorderConfig(
          repaintBoundaryKey: GlobalKey(),
          maxFrames: 10,
          pixelRatio: 1,
          fps: 15,
          debug: false));
      h.client.screenRecorder = recorder;
      expect(recorder.masked, isTrue);
      h.client.control.applyRemote(
          parseSettingsDocument('{"replay":{"maskAllInputs":false}}'));
      expect(recorder.masked, isFalse);
      h.client.screenRecorder = null;
    });
  });

  group('stricter replay privacy and the clips waiting to be uploaded', () {
    const video = TracewayVideoRecorderConfig(
        repaintBoundaryKey: GlobalObjectKey('video'),
        maxFrames: 10,
        pixelRatio: 1,
        fps: 15,
        debug: false);
    late bool reject;
    late Harness h;

    Future<void> start() async {
      reject = true;
      h = await startHarness(
        options:
            const TracewayOptions(remoteConfig: false, screenCapture: true),
        handler: (request) async =>
            reject && request.url.path.endsWith('/api/recordings')
                ? http.Response('', 503)
                : null,
      );
    }

    void settings(String replay) => h.client.control
        .applyRemote(parseSettingsDocument('{"replay":$replay}'));

    /// An exception whose clip the server turns away for now.
    Future<void> queueClip(String message) async {
      h.client.captureException(StateError(message));
      await h.client.flush();
      expect(h.client.replay.transport.pending, 1, reason: message);
    }

    Future<int> postsOnceAccepted() async {
      reject = false;
      final before = h.requestsTo('/api/recordings').length;
      await h.client.flush();
      return h.requestsTo('/api/recordings').length - before;
    }

    test('masking inputs again drops them', () async {
      await start();
      h.client.screenRecorder = FakeVideoRecorder(video);
      settings('{"maskAllInputs":false}');
      await queueClip('typed in the clear');
      settings('{"maskAllInputs":true}');
      expect(h.client.replay.transport.pending, 0);
      expect(await postsOnceAccepted(), 0);
      h.client.screenRecorder = null;
    });

    test('unmasking inputs keeps them', () async {
      await start();
      h.client.screenRecorder = FakeVideoRecorder(video);
      await queueClip('masked');
      settings('{"maskAllInputs":false}');
      expect(h.client.replay.transport.pending, 1);
      expect(await postsOnceAccepted(), 1);
      h.client.screenRecorder = null;
    });

    for (final (from, to) in [('always', 'wifi'), ('always', 'off'), ('wifi', 'off')]) {
      test('image policy $from to $to drops them', () async {
        await start();
        h.client.screenRecorder =
            WireframeRecorder(rootKey: GlobalKey(), maxFrames: 10);
        h.client.replaySource = FakeReplaySource();
        settings('{"images":"$from"}');
        await queueClip('pictures');
        settings('{"images":"$to"}');
        expect(h.client.replay.transport.pending, 0);
        expect(await postsOnceAccepted(), 0);
        h.client.screenRecorder = null;
      });
    }

    test('a looser image policy keeps them', () async {
      await start();
      h.client.screenRecorder =
          WireframeRecorder(rootKey: GlobalKey(), maxFrames: 10);
      h.client.replaySource = FakeReplaySource();
      settings('{"images":"off"}');
      await queueClip('placeholders');
      settings('{"images":"always"}');
      expect(h.client.replay.transport.pending, 1);
      expect(await postsOnceAccepted(), 1);
      h.client.screenRecorder = null;
    });

    test('a video shows the same pixels under every image policy: its '
        'clips stay', () async {
      await start();
      h.client.screenRecorder = FakeVideoRecorder(video);
      settings('{"images":"always"}');
      await queueClip('video');
      settings('{"images":"off"}');
      expect(h.client.replay.transport.pending, 1);
      expect(await postsOnceAccepted(), 1);
      h.client.screenRecorder = null;
    });
  });

  group('FLT-12: the Traceway widget across clients', () {
    testWidgets('keeps the app\'s state when the SDK stops and records for a '
        'client started later', (tester) async {
      const options = TracewayOptions(remoteConfig: false, screenCapture: true);
      final a = (await tester.runAsync(() => startHarness(options: options)))!;
      _stopAfter(tester);
      await tester.pumpWidget(const Traceway(child: _Counter()));
      await tester.pump();
      await tester.tap(find.byType(_Counter));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(a.client.screenRecorder, isNotNull);

      await tester.runAsync(a.client.shutdown);
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      final b = (await tester.runAsync(() => TracewayClient.initializeForTest(
          connectionString, options,
          overrides: TracewayTestOverrides(
              logExporter: InMemoryLogExporter(),
              spanExporter: InMemorySpanExporter(),
              httpClient: MockClient((_) async => http.Response('{}', 200))))))!;
      // The widget follows the change.
      await tester.pump();
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(b.screenRecorder, isNotNull);
    });
  });

  group('FLT-13: shutdown with a clip that is never made', () {
    test('completes', () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, screenCapture: true));
      h.client.replay.drainTimeout = const Duration(milliseconds: 200);
      h.client.replaySource = _StuckSource();
      h.client.captureException(StateError('clip'));
      await expectLater(
          h.client.shutdown().timeout(const Duration(seconds: 5)), completes);
    });
  });

  group('FLT-14: out-of-range remote numbers', () {
    test('an infinite maxPerSession is skipped, not the document', () {
      final out = applyOverlay(
          defaultSettings(),
          parseSettingsDocument('{"signals":{"console":{"mode":"stream"}},'
              '"triggers":[{"id":"t","maxPerSession":1e400,"cooldownSeconds":1e400,'
              '"steps":[{"match":{"key":"event.name","op":"eq","value":"x"}}],'
              '"actions":[{"type":"flush","lookbackSeconds":5}]}]}'));
      expect(out.signals['console']!.mode, Mode.stream);
      final trigger = out.triggers.firstWhere((t) => t.id == 't');
      expect(trigger.maxPerSession, isNull);
    });

    test('a huge heartbeat polls at most a day apart', () async {
      final opamp = OpampHttpClient(
        endpoint: 'https://traceway.test/api/otel/v1/opamp',
        headers: const {},
        instanceUid: Uint8List(16),
        capabilities: 0,
        describe: () =>
            AgentDescription(identifying: const {}, nonIdentifying: const {}),
        onRemoteConfig: (_) => const ApplyResult.applied(),
        httpClient: MockClient((_) async => http.Response.bytes(
            encodeServerToAgent(heartbeatIntervalSeconds: 1 << 50), 200)),
      )..start();
      addTearDown(opamp.stop);
      await opamp.poll();
      expect(opamp.pollIntervalMs, lessThanOrEqualTo(24 * 60 * 60 * 1000));
      expect(opamp.pollIntervalMs, greaterThan(0));
    });
  });

  group('FLT-15: the persistent frame callback', () {
    testWidgets('is added once per process, whatever the instances',
        (tester) async {
      final before = AppVitals.frameCallbacksAdded;
      final recorder = MetricsRecorder(
        control: ControlState(defaultSettings(), ceilingsFrom()),
        sessionId: () => null,
        installationId: () => 'i',
        resource: () => const {},
        send: (_) async => 200,
        store: () => StateStore(null),
        scopeName: 's',
        scopeVersion: 'v',
      );
      for (var i = 0; i < 3; i++) {
        AppVitals(recorder, currentScreen: () => '/')
          ..start()
          ..stop();
      }
      expect(AppVitals.frameCallbacksAdded - before, lessThanOrEqualTo(1));
      expect(AppVitals.frameCallbacksAdded, 1);
    });
  });

  group('FLT-16: navigators', () {
    testWidgets('a nested Navigator with its own observer builds',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [Traceway.navigatorObserver],
        home: Navigator(
          observers: [TracewayNavigatorObserver()],
          onGenerateRoute: (settings) =>
              MaterialPageRoute(builder: (_) => const Text('tab')),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('tab'), findsOneWidget);
    });
  });

  group('every public call', () {
    Future<void> callEverything() async {
      Traceway.recordAction(category: 'c', name: 'n', data: {'k': 1});
      Traceway.track('evt', {'k': 1});
      Traceway.captureException(StateError('x'), StackTrace.current, {'a': 'b'});
      Traceway.captureMessage('m', {'a': 'b'});
      Traceway.setAttribute('user.id', 'u');
      Traceway.setAttributes({'a': 'b'});
      Traceway.removeAttribute('a');
      Traceway.clearAttributes();
      Traceway.getInstanceId();
      Traceway.currentSessionId;
      Traceway.log('l', level: TracewayLogLevel.warn, error: StateError('e'));
      Traceway.recordNavigation('/a', route: '/a');
      Traceway.setRoute('/a');
      final interaction = Traceway.startInteraction('i', attributes: {'k': 1});
      interaction.run(() => interaction.setAttribute('k', 2));
      interaction.captureException(StateError('i'));
      interaction.end();
      interaction.end();
      Traceway.reportFullyDisplayed();
      Traceway.metric('checkout.duration', 2, {'plan': 'pro'});
      Traceway.count('cart.add');
      Traceway.setMetricDimension('arm', 'b');
      Traceway.tracer?.startSpan('app span').end();
      await Traceway.refreshConfig();
      await Traceway.flush(1000);
    }

    test('before the SDK starts', () async {
      await TracewayClient.resetForTest();
      final errors = await _zoneErrors(() async {
        await callEverything();
        await Traceway.shutdown();
      });
      expect(errors, isEmpty);
    });

    test('while it runs, twice, and at the same time', () async {
      final h = await startHarness();
      final errors = await _zoneErrors(() async {
        await callEverything();
        await Future.wait([callEverything(), callEverything()]);
      });
      expect(errors, isEmpty);
      await h.client.flush();
      expect(h.named(eventException), isNotEmpty);
    });

    test('after it stopped, and stopping twice or while flushing', () async {
      final h = await startHarness();
      final errors = await _zoneErrors(() async {
        await Future.wait([
          h.client.flush(),
          h.client.shutdown(),
          h.client.shutdown(),
          h.client.flush(),
        ]);
        await callEverything();
        h.client.captureException(StateError('after'));
        h.client.didChangeAppLifecycleState(AppLifecycleState.paused);
        await h.client.shutdown();
      });
      expect(errors, isEmpty);
    });
  });

  group('fault injection', () {
    test('an exporter that throws: captures return, flush completes, the SDK '
        'keeps working', () async {
      final exporter = _ThrowingLogExporter();
      final errors = await _zoneErrors(() async {
        final client = await TracewayClient.initializeForTest(
          connectionString,
          const TracewayOptions(
              remoteConfig: false,
              collection: {
                'signals': {
                  'console': {'mode': 'stream'}
                }
              }),
          overrides: TracewayTestOverrides(
            logExporter: exporter,
            spanExporter: InMemorySpanExporter(),
            httpClient: MockClient((_) async => http.Response('{}', 200)),
          ),
        );
        client.captureException(StateError('one'));
        client.log('line');
        await client.flush().timeout(const Duration(seconds: 10));
        client.captureException(StateError('two'));
        await client.flush().timeout(const Duration(seconds: 10));
        await client.shutdown().timeout(const Duration(seconds: 10));
      });
      expect(errors, isEmpty);
      expect(exporter.calls, greaterThan(0));
    });

    test('a transport that throws: flush and shutdown complete', () async {
      final errors = await _zoneErrors(() async {
        final h = await startHarness(
          options: const TracewayOptions(),
          handler: (_) => throw const SocketException('down'),
        );
        h.client.captureException(StateError('offline'));
        h.client.recordMetric('checkout.duration', 3);
        await h.client.flush().timeout(const Duration(seconds: 20));
        await h.client.shutdown().timeout(const Duration(seconds: 20));
      });
      expect(errors, isEmpty);
    });

    test('settings that do not parse: start-up completes and records flow',
        () async {
      final errors = await _zoneErrors(() async {
        final h = await startHarness(
          options: const TracewayOptions(
              collection: {'triggers': 'garbage', 'signals': 7}),
          handler: (request) async => request.url.path.endsWith('/opamp')
              ? opampConfig({'signals': 'not an object'}, [1, 2, 3])
              : null,
        );
        await h.client.refreshConfig();
        h.client.captureMessage('after bad settings');
        await h.client.flush();
        expect(h.named(eventMessage), hasLength(1));
      });
      expect(errors, isEmpty);
    });

    test('a recorder that fails at everything: errors, lifecycle and flush '
        'still work', () async {
      final errors = await _zoneErrors(() async {
        final h = await startHarness(
            options: const TracewayOptions(
                remoteConfig: false,
                screenCapture: true,
                recordAllSessions: true));
        h.client.replaySource = _ThrowingSource();
        h.client.captureException(StateError('a'));
        h.client.didChangeAppLifecycleState(AppLifecycleState.paused);
        h.client.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await h.client.flush();
        expect(h.named(eventException), hasLength(1));
      });
      expect(errors, isEmpty);
    });
  });

  group('replay images, the keyboard and the tracer (§14)', () {
    final root = GlobalKey();
    Widget screen(Widget child) => RepaintBoundary(
        key: root,
        child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(alignment: Alignment.topLeft, child: child)));

    testWidgets(
        'an image encoder, a budget and an unmetered check that throw cost '
        'the picture, not the frame', (tester) async {
      final photo = (await tester.runAsync(() => _opaqueImage(40, 30)))!;
      await tester.pumpWidget(screen(SizedBox(
          width: 40, height: 30, child: Image(image: _Picture(photo)))));
      for (final images in [
        WireframeImages(encoder: (rgba, w, h) => throw StateError('encoder')),
        WireframeImages(
            encoder: (rgba, w, h) async => throw StateError('encoder')),
        WireframeImages()..budget = _ThrowingBudget(),
      ]) {
        final capture = WireframeCapture()
          ..images = images
          ..imagePolicy = TracewayImagePolicy.wifi
          ..unmetered = () => true;
        // An uncaught error in the test's zone would fail the test.
        await tester.runAsync(() async {
          for (var i = 0; i < 3; i++) {
            final frame =
                capture.capture(root.currentContext! as Element, DateTime.now())!;
            // The image still has its node: the placeholder.
            expect(
                _nodes(frame.screen!).where(
                    (n) => (n.attributes['class'] ?? '').startsWith('im')),
                hasLength(1));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        expect(tester.takeException(), isNull);
        expect(capture.lastError, isNull);
      }
      final throwingCheck = WireframeCapture()
        ..images = WireframeImages()
        ..imagePolicy = TracewayImagePolicy.wifi
        ..unmetered = () => throw StateError('unmetered');
      expect(throwingCheck.capture(root.currentContext! as Element, DateTime.now()),
          isNotNull);
    });

    test('an isUnmeteredNetwork that throws, at once or later, is metered',
        () async {
      final errors = await _zoneErrors(() async {
        final sync = NetworkState(isUnmetered: () => throw StateError('sync'));
        expect(sync.unmetered(), isFalse);
        final async = NetworkState(
            isUnmetered: () async => throw StateError('async'),
            maxAge: Duration.zero);
        expect(async.unmetered(), isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(async.unmetered(), isFalse);
        final interfaces = NetworkState(
            interfaces: () async => throw const SocketException('down'),
            operatingSystem: 'android');
        interfaces.unmetered();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(interfaces.unmetered(), isFalse);
      });
      expect(errors, isEmpty);
    });

    testWidgets(
        'the client records with an isUnmeteredNetwork that throws, and a '
        'keyboard inset that is not a number draws no keyboard', (tester) async {
      final app = (await tester.runAsync(() => TracewayClient.initializeForTest(
            connectionString,
            TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              screenCaptureMode: TracewayScreenCaptureMode.wireframe,
              isUnmeteredNetwork: () => throw StateError('isUnmeteredNetwork'),
            ),
            overrides: TracewayTestOverrides(
                httpClient: MockClient((_) async => http.Response('{}', 200))),
          )))!;
      _stopAfter(tester);
      final photo = (await tester.runAsync(() => _opaqueImage(40, 30)))!;
      await tester.pumpWidget(Traceway(
          child: Directionality(
              textDirection: TextDirection.ltr,
              child: SizedBox(
                  width: 40, height: 30, child: Image(image: _Picture(photo))))));
      await tester.pump(const Duration(milliseconds: 200));
      final recorder = app.screenRecorder! as WireframeRecorder;
      expect(recorder.bufferedFrameCount, greaterThan(0));
      expect(tester.takeException(), isNull);

      for (final bottom in [double.nan, double.infinity, -50.0]) {
        await tester.pumpWidget(MediaQuery(
            data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: bottom)),
            child: screen(const Text('typing'))));
        final frame = WireframeCapture()
            .capture(root.currentContext! as Element, DateTime.now())!;
        expect(_nodes(frame.screen!).where((n) => n.id == keyboardNodeId),
            isEmpty);
      }
    });
  });
}

int _beforeCaptureCalls = 0;

/// A replay image budget that fails at everything.
class _ThrowingBudget implements ImageBudget {
  @override
  String? get sessionId => throw StateError('sessionId');

  @override
  bool hasRoom(String? sessionId) => throw StateError('hasRoom');

  @override
  bool admit(String? sessionId, int bytes) => throw StateError('admit');
}

/// An image provider that hands out [picture] at once.
class _Picture extends ImageProvider<_Picture> {
  _Picture(this.picture);
  final ui.Image picture;

  @override
  Future<_Picture> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_Picture>(this);

  @override
  ImageStreamCompleter loadImage(_Picture key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: picture.clone())));
}

Future<ui.Image> _opaqueImage(int w, int h) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      Uint8List.fromList(List.filled(w * h * 4, 200)), w, h,
      ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

Iterable<VNode> _nodes(VNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* _nodes(c);
  }
}

/// Sends every request to the proxy listening on [port].
class _LoopbackProxy extends HttpOverrides {
  _LoopbackProxy(this.port);
  final int port;

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'PROXY 127.0.0.1:$port';
}

/// A restored OTLP `ResourceLogs`: one empty scope, enough to parse.
final Uint8List _restorableLogs = Uint8List.fromList(const [0x12, 0x00]);

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: GestureDetector(
          onTap: () => setState(() => count++),
          child: SizedBox(width: 200, height: 200, child: Text('$count')),
        ),
      );
}
