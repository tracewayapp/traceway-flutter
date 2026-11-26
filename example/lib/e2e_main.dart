// A scripted run of the SDK against a real Traceway server, used to verify
// the whole pipeline end to end. It taps its own buttons (real pointer events
// through the engine's hit testing), navigates, throws, follows a recorded
// journey and keeps emitting events while the harness changes remote config
// and starts and cancels a capture.
//
//   flutter run -t lib/e2e_main.dart --dart-define=TRACEWAY_DSN=token@http://host:8082
//
// Progress is printed as `E2E_PHASE <name>` lines; tool/e2e/run.py follows
// them and checks the server at each point.
//
// With E2E_COLLECTOR=<OTLP/HTTP base URL> in the environment, the scenarios
// `external` (Traceway plus another OpenTelemetry backend) and `standalone`
// (no connection string) send their telemetry to that collector.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' as otel;
import 'package:dartastic_opentelemetry/testing.dart' as otel_test;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
// ignore: implementation_imports
import 'package:traceway/src/screen_recorder.dart';
import 'package:traceway/traceway.dart';

const _dsn = String.fromEnvironment('TRACEWAY_DSN');
const _quietSeconds = int.fromEnvironment('E2E_QUIET_SECONDS', defaultValue: 20);

/// How long the recording trigger's capture streams.
const _journeyCaptureSeconds = 30;

String get _base => _dsn
    .substring(_dsn.indexOf('@') + 1)
    .replaceFirst(RegExp(r'/api/report$'), '');

/// The hardware encoder plugin has no desktop Linux build, so there the
/// clip is encoded by the `ffmpeg` binary instead. Frames, masks, segments
/// and upload are the SDK's own.
class FfmpegVideoEncoder implements VideoEncoder {
  Process? _process;

  @override
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required String filepath,
    required bool debug,
  }) async {
    final process = await Process.start('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-f', 'rawvideo', '-pix_fmt', 'rgba',
      '-s', '${width}x$height', '-r', '$fps', '-i', '-',
      '-c:v', 'libx264', '-profile:v', 'baseline', '-pix_fmt', 'yuv420p',
      '-movflags', '+faststart', filepath,
    ]);
    unawaited(process.stderr.drain<void>());
    unawaited(process.stdout.drain<void>());
    _process = process;
  }

  @override
  Future<void> appendFrame(Uint8List rgba) async {
    _process!.stdin.add(rgba);
    await _process!.stdin.flush();
  }

  @override
  Future<void> finish() async {
    await _process!.stdin.close();
    final code = await _process!.exitCode;
    if (code != 0) throw StateError('ffmpeg exited with $code');
  }
}

// Android activities cannot inherit the host harness's environment. Flutter's
// system temp directory is inside the app's private data directory.
Map<String, String> _readLaunchSettings() {
  if (Platform.isAndroid) {
    final file = File('${Directory.systemTemp.parent.path}/files/e2e-launch.json');
    if (file.existsSync()) {
      return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
    }
  }
  return Platform.environment;
}

final _launchSettings = _readLaunchSettings();

Future<void> main() async {
  if (_dsn.isEmpty) {
    stderr.writeln('Set --dart-define=TRACEWAY_DSN=token@http://host:port');
    exit(64);
  }
  if (Platform.isLinux) {
    // ignore: invalid_use_of_visible_for_testing_member
    ScreenRecorder.encoderOverride = FfmpegVideoEncoder();
  }
  final scenario = _launchSettings['E2E_SCENARIO'];
  final collector = _launchSettings['E2E_COLLECTOR'];
  final echo = _launchSettings['E2E_ECHO'];
  final otherBackend = collector != null &&
      (scenario == 'external' || scenario == 'standalone');
  if (scenario == 'external') {
    await otel.OTel.initialize(
      serviceName: 'e2e-host-app',
      logRecordProcessor: otel.SimpleLogRecordProcessor(otel_test.InMemoryLogExporter()),
      spanProcessor: otel.SimpleSpanProcessor(otel_test.InMemorySpanExporter()),
      enableMetrics: false,
      detectPlatformResources: false,
    );
  }
  Traceway.run(
    connectionString: scenario == 'standalone' ? null : _dsn,
    options: TracewayOptions(
      telemetry: otherBackend
          ? TracewayTelemetry(
              url: collector,
              headers: const {'x-e2e-key': 'collector-secret'},
            )
          : null,
      // Requests to the harness's echo server carry the W3C trace context.
      propagateTraceHeaderUrls: [if (echo != null) '$echo/checkout'],
      screenCapture: true,
      debug: true,
      version: 'e2e-1.0.0',
      serviceName: 'traceway-flutter-e2e',
      environment: 'e2e',
      attributes: {'user.id': 'e2e-user'},
      // A recording trigger defined in the app itself; remote rules come on
      // top of it.
      collection: {
        if (otherBackend)
          'signals': {
            'console': {'mode': 'stream'},
            'custom': {'mode': 'stream'},
            'network': {'mode': 'stream'},
            'userActions': {'mode': 'stream'},
          },
        'triggers': [
          {
            'id': 'e2e-open-profile',
            'name': 'Open profile',
            'cooldownSeconds': 0,
            'maxPerSession': 1,
            'steps': [
              {
                'match': {
                  'event': {'type': 'navigation', 'value': '/users/{id}'}
                }
              },
              {
                'match': {
                  'event': {'type': 'click', 'value': '#open-profile'}
                },
                'withinSeconds': 30,
              },
              {
                'match': {
                  'event': {
                    'type': 'log',
                    'value': 'Profile loaded',
                    'mode': 'contains'
                  }
                },
                'withinSeconds': 10,
              },
            ],
            'actions': [
              {
                'type': 'capture',
                'durationSeconds': _journeyCaptureSeconds,
                'lookbackSeconds': 30,
                'replay': true,
              }
            ],
          }
        ],
      },
    ),
    child: const E2eApp(),
  );
}

final _navigatorKey = GlobalKey<NavigatorState>();
final _payTarget = GlobalKey();
final _profileTarget = GlobalKey();

class E2eApp extends StatelessWidget {
  const E2eApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [Traceway.navigatorObserver],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => switch (settings.name) {
            '/' => const _Home(),
            final String name when name.startsWith('/users/') =>
              const _UserPage(),
            _ => const Scaffold(body: Center(child: Text('detail'))),
          },
        ),
      );
}

class _UserPage extends StatelessWidget {
  const _UserPage();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('User 42')),
        body: Center(
          child: KeyedSubtree(
            key: _profileTarget,
            child: ElevatedButton(
              key: const Key('open-profile'),
              onPressed: () => debugPrint('e2e Profile loaded for 42'),
              child: const Text('Open profile'),
            ),
          ),
        ),
      );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

var _pointer = 100;

/// A tap the way the engine delivers one: through hit testing and the
/// gesture arena, with the SDK's listener seeing it like any app widget.
void tap(GlobalKey target) {
  final box = target.currentContext!.findRenderObject()! as RenderBox;
  final position = box.localToGlobal(box.size.center(Offset.zero));
  final viewId = View.of(target.currentContext!).viewId;
  final pointer = _pointer++;
  GestureBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
      viewId: viewId));
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
      viewId: viewId));
}

class _HomeState extends State<_Home> {
  int _frame = 0;
  String _phase = 'starting';
  int _paid = 0;
  bool _freezeNextBuild = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Something has to move, or every frame of the clip is the same picture.
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      // An unfocused desktop window must resume for the recorder to capture.
      // Every resume polls OpAMP, and the restart scenario needs to stay paused.
      final binding = WidgetsBinding.instance;
      if ((Platform.isLinux || Platform.isMacOS || Platform.isWindows) &&
          binding.lifecycleState == AppLifecycleState.inactive) {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      if (mounted) setState(() => _frame++);
    });
    unawaited(_script());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _setPhase(String phase) {
    debugPrint('E2E_PHASE $phase');
    if (mounted) setState(() => _phase = phase);
  }

  Future<void> _wait(int seconds) =>
      Future<void>.delayed(Duration(seconds: seconds));

  Future<void> _script() async {
    final client = TracewayClient.instance!;
    await _wait(3);
    _setPhase('start instance=${client.getInstanceId()}');
    switch (_launchSettings['E2E_SCENARIO']) {
      case 'exit-after-error':
        await client.ready;
        client.captureUnhandledException(
          StateError('e2e exit after capture'),
          StackTrace.current,
        );
        debugPrintSynchronously('E2E_PHASE captured');
        exit(0);
      case 'recover-error':
        await client.flush(15000);
        _setPhase('recovered');
        return;
      case 'restart-a':
        // Leave breadcrumbs, let the SDK save its buffer the way it does when
        // the app goes to the background, then wait to be killed.
        debugPrint('e2e before the kill');
        tap(_payTarget);
        WidgetsBinding.instance
            .handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await _wait(2);
        _setPhase('saved session=${client.currentSessionId}');
        await Completer<void>().future;
      case 'restart-b':
        _setPhase('resumed session=${client.currentSessionId}');
        unawaited(
            Future<void>.microtask(() => throw StateError('e2e after restart')));
        await _wait(4);
        await client.flush(15000);
        _setPhase('done');
        return;
      case 'external' || 'standalone':
        final scenario = _launchSettings['E2E_SCENARIO'];
        debugPrint('e2e $scenario log');
        Traceway.track('e2e_${scenario}_event', {'n': 1});
        try {
          await http.get(Uri.parse('$_base/api/has-organizations?$scenario'));
          final echo = _launchSettings['E2E_ECHO'];
          if (echo != null) {
            await http.get(Uri.parse('$echo/checkout?$scenario'));
            await http.get(Uri.parse('$echo/other?$scenario'));
          }
        } catch (_) {}
        tap(_payTarget);
        Traceway.count('e2e.$scenario', 2);
        await client.flush(15000);
        _setPhase('telemetry_sent session=${client.currentSessionId}');
        await _wait(2);
        unawaited(Future<void>.microtask(
            () => throw StateError('e2e $scenario boom')));
        await _wait(6);
        await client.flush(15000);
        _setPhase('done');
        return;
    }

    // ---- 1. breadcrumbs, all kept on the device -------------------------
    debugPrint('e2e breadcrumb log');
    Traceway.recordAction(category: 'e2e', name: 'tap', data: {'step': 1});
    Traceway.track('e2e_event', {'n': 1});
    try {
      final response = await http.get(Uri.parse('$_base/api/has-organizations'));
      debugPrint('e2e http ${response.statusCode}');
    } catch (e) {
      debugPrint('e2e http failed: $e');
    }
    unawaited(_navigatorKey.currentState!.pushNamed('/e2e-detail'));
    await _wait(1);
    _navigatorKey.currentState!.pop();
    await _wait(1);
    tap(_payTarget);
    await client.flush(5000);
    _setPhase('breadcrumbs_done');
    await _wait(_quietSeconds);

    // ---- 2. an exception -------------------------------------------------
    _setPhase('exception');
    unawaited(Future<void>.microtask(() => throw StateError('e2e boom')));
    await _wait(10);
    await client.flush(15000);
    _setPhase('exception_sent');

    // ---- 3. a recorded journey: navigation, tap, log --------------------
    unawaited(_navigatorKey.currentState!.pushNamed('/users/42'));
    await _wait(1);
    // The page has what it loads: ends its time to full display.
    Traceway.reportFullyDisplayed();
    await _wait(1);
    tap(_profileTarget);
    _setPhase('journey_started');
    for (var i = 0; i < _journeyCaptureSeconds + 8; i++) {
      await _wait(1);
      debugPrint('e2e journey tick $i');
    }
    _navigatorKey.currentState!.pop();
    await _wait(2);
    debugPrint('e2e after journey');
    await client.flush(15000);
    _setPhase('journey_done');

    // ---- 4. a capture from the dashboard --------------------------------
    // These lines are buffered; the capture's lookback brings them up.
    for (var i = 0; i < 3; i++) {
      debugPrint('e2e pre-capture tick $i');
      await _wait(1);
    }
    _setPhase('await_capture');
    for (var i = 0; i < 60; i++) {
      await client.refreshConfig();
      debugPrint('e2e remote tick $i');
      await _wait(1);
    }
    await client.flush(15000);
    _setPhase('capture_done');

    // ---- 5. a remote rule built from the selector the server recorded ---
    for (var i = 0; i < 40; i++) {
      await client.refreshConfig();
      // ignore: invalid_use_of_visible_for_testing_member
      final ready = client.settings.triggers.any((t) => t.id == 'e2e-remote-pay');
      if (ready) break;
      await _wait(1);
    }
    tap(_payTarget);
    for (var i = 0; i < 6; i++) {
      await _wait(1);
      Traceway.track('e2e_tick', {'i': i});
    }

    // ---- 7. what the metrics measure -------------------------------------
    // A frame that takes 800 ms to build is frozen; 2.6 s without the UI
    // isolate running a timer is a hang.
    if (mounted) setState(() => _freezeNextBuild = true);
    await _wait(1);
    final until = DateTime.now().add(const Duration(milliseconds: 2600));
    while (DateTime.now().isBefore(until)) {}
    await _wait(1);
    Traceway.metric('e2e.checkout', 1234, {'plan': 'pro'});
    Traceway.count('e2e.cart_add', 3);
    await client.flush(10000);
    _setPhase('done');
  }

  @override
  Widget build(BuildContext context) {
    if (_freezeNextBuild) {
      _freezeNextBuild = false;
      final until = DateTime.now().add(const Duration(milliseconds: 800));
      while (DateTime.now().isBefore(until)) {}
    }
    return _scaffold();
  }

  Widget _scaffold() => Scaffold(
        appBar: AppBar(title: const Text('Traceway e2e')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('frame $_frame', style: const TextStyle(fontSize: 40)),
              const SizedBox(height: 16),
              Text(_phase),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: _payTarget,
                child: ElevatedButton(
                  key: const Key('pay'),
                  onPressed: () => setState(() => _paid++),
                  child: Text(_paid == 0 ? 'Pay now' : 'Paid $_paid'),
                ),
              ),
              const SizedBox(height: 16),
              const TracewayPrivacyMask(child: Text('secret 4242 4242')),
              const SizedBox(height: 16),
              SizedBox(
                width: 200,
                child: LinearProgressIndicator(value: (_frame % 50) / 50),
              ),
            ],
          ),
        ),
      );
}
