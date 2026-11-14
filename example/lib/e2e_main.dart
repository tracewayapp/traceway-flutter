// A scripted run of the SDK against a real Traceway server, used to verify
// the whole pipeline end to end. It needs no taps: it leaves breadcrumbs,
// waits, throws, and then keeps emitting events while remote config changes.
//
//   flutter run -t lib/e2e_main.dart --dart-define=TRACEWAY_DSN=token@http://host:8082
//
// Progress is printed as `E2E_PHASE <name>` lines.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
// ignore: implementation_imports
import 'package:traceway/src/screen_recorder.dart';
import 'package:traceway/traceway.dart';

const _dsn = String.fromEnvironment('TRACEWAY_DSN');
const _quietSeconds = int.fromEnvironment('E2E_QUIET_SECONDS', defaultValue: 25);
const _tickCount = int.fromEnvironment('E2E_TICKS', defaultValue: 24);

String get _base => _dsn
    .substring(_dsn.indexOf('@') + 1)
    .replaceFirst(RegExp(r'/api/report$'), '');

/// The hardware encoder plugin has no desktop Linux build, so there the
/// clip is encoded by the `ffmpeg` binary instead. Frames, masks and upload
/// are the SDK's own.
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

void main() {
  if (_dsn.isEmpty) {
    stderr.writeln('Set --dart-define=TRACEWAY_DSN=token@http://host:port');
    exit(64);
  }
  if (Platform.isLinux) {
    // ignore: invalid_use_of_visible_for_testing_member
    ScreenRecorder.encoderOverride = FfmpegVideoEncoder();
  }
  Traceway.run(
    connectionString: _dsn,
    options: const TracewayOptions(
      screenCapture: true,
      debug: true,
      version: 'e2e-1.0.0',
      serviceName: 'traceway-flutter-e2e',
      environment: 'e2e',
      attributes: {'user.id': 'e2e-user'},
    ),
    child: const E2eApp(),
  );
}

final _navigatorKey = GlobalKey<NavigatorState>();

class E2eApp extends StatelessWidget {
  const E2eApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [Traceway.navigatorObserver],
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int _frame = 0;
  String _phase = 'starting';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Something has to move, or every frame of the clip is the same picture.
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      // The recorder only captures while the app is in the foreground. A
      // desktop window that does not hold keyboard focus reports `inactive`,
      // so an unattended desktop run would record nothing: keep it `resumed`
      // rather than stealing focus on the machine running the test.
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        WidgetsBinding.instance
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      setState(() => _frame++);
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

  Future<void> _script() async {
    final client = TracewayClient.instance!;
    await Future<void>.delayed(const Duration(seconds: 3));
    _setPhase('start instance=${client.getInstanceId()}');

    debugPrint('e2e breadcrumb log');
    Traceway.recordAction(category: 'e2e', name: 'tap', data: {'step': 1});
    Traceway.track('e2e_event', {'n': 1});
    try {
      final response = await http.get(Uri.parse('$_base/api/has-organizations'));
      debugPrint('e2e http ${response.statusCode}');
    } catch (e) {
      debugPrint('e2e http failed: $e');
    }
    unawaited(_navigatorKey.currentState!.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/e2e-detail'),
      builder: (_) => const Scaffold(body: Center(child: Text('detail'))),
    )));
    await Future<void>.delayed(const Duration(seconds: 1));
    _navigatorKey.currentState!.pop();
    await client.flush(5000);
    _setPhase('breadcrumbs_done');

    // Nothing above may have reached the server: it is all in the ring
    // buffer. The harness checks that during this pause.
    await Future<void>.delayed(const Duration(seconds: _quietSeconds));

    _setPhase('exception');
    unawaited(Future<void>.microtask(() => throw StateError('e2e boom')));
    await Future<void>.delayed(const Duration(seconds: 12));
    await client.flush(15000);
    _setPhase('exception_sent');

    // Remote config: the harness changes the project's rules now. Poll often
    // so the test does not wait for a heartbeat, and keep emitting events
    // that only leave the device if the new settings stream them.
    for (var i = 0; i < _tickCount; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      await client.refreshConfig();
      Traceway.track('e2e_tick', {'i': i});
      debugPrint('e2e tick $i');
    }
    await client.flush(10000);
    _setPhase('done');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Traceway e2e')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('frame $_frame', style: const TextStyle(fontSize: 40)),
              const SizedBox(height: 16),
              Text(_phase),
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
