import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/traceway.dart';
import 'package:video_player/video_player.dart';

import 'benchmark_harness.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Shared helpers
// ═══════════════════════════════════════════════════════════════════════════

/// When TRACEWAY_DSN is set, use the real backend. Otherwise no-op.
const _dsn = String.fromEnvironment('TRACEWAY_DSN');
final bool _useRealBackend = _dsn.isNotEmpty;

/// Connection string: real DSN if provided, otherwise a dummy one.
final String _connectionString =
    _useRealBackend ? _dsn : 'benchmark-token@http://localhost:9999/noop';

/// When no real DSN, use a no-op sender that includes gzip cost but discards.
/// When a real DSN is set, pass null to use the SDK's default sendReport.
ReportSender? get _reportSender =>
    _useRealBackend ? null : _noOpSender;

Future<bool> _noOpSender(String url, String token, String body) async {
  gzip.encode(utf8.encode(body));
  return true;
}

/// Pumps frames for [duration], driving the engine at ~60 fps.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < duration) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Visual status overlay — shows what the benchmark is doing on screen
// ═══════════════════════════════════════════════════════════════════════════

/// Global notifier that scenario code updates to show status on screen.
final _statusNotifier = ValueNotifier<String>('');

/// Global key for the root scaffold messenger so scenarios can show snackbars.
final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void _showStatus(String message) {
  _statusNotifier.value = message;
}

void _showSnackbar(String message, {Color color = Colors.red}) {
  _scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
      backgroundColor: color,
      duration: const Duration(milliseconds: 800),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Wraps any app content with a persistent status banner at the top and
/// hooks into the ScaffoldMessenger for snackbar notifications.
class _BenchmarkShell extends StatelessWidget {
  final String scenarioName;
  final Widget child;

  const _BenchmarkShell({
    required this.scenarioName,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      home: Scaffold(
        body: Column(
          children: [
            // Status banner — always visible at top.
            Container(
              width: double.infinity,
              color: Colors.black87,
              padding: const EdgeInsets.only(
                  top: 48, bottom: 8, left: 12, right: 12),
              child: ValueListenableBuilder<String>(
                valueListenable: _statusNotifier,
                builder: (_, status, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SCENARIO: $scenarioName',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (status.isNotEmpty)
                      Text(
                        status,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Actual app content fills the rest.
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Test App 1: Stress Test App (scenarios A–E)
// ═══════════════════════════════════════════════════════════════════════════

class _StressContent extends StatefulWidget {
  const _StressContent();

  @override
  State<_StressContent> createState() => _StressContentState();
}

class _StressContentState extends State<_StressContent> {
  static const _colors = [
    [Color(0xFF1A237E), Color(0xFF42A5F5)],
    [Color(0xFFB71C1C), Color(0xFFEF5350)],
    [Color(0xFF1B5E20), Color(0xFF66BB6A)],
    [Color(0xFF4A148C), Color(0xFFAB47BC)],
    [Color(0xFFE65100), Color(0xFFFF9800)],
  ];

  int _colorIndex = 0;
  Timer? _colorTimer;

  @override
  void initState() {
    super.initState();
    _colorTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        setState(() => _colorIndex = (_colorIndex + 1) % _colors.length);
      }
    });
  }

  @override
  void dispose() {
    _colorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gradientColors = _colors[_colorIndex];
    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeInOut,
          height: 100,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Center(
            child: Text(
              'Stress Test',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: const Key('stressList'),
            itemCount: 200,
            itemBuilder: (context, i) {
              final hue = (i * 7.0) % 360;
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        HSVColor.fromAHSV(1, hue, 0.6, 0.9).toColor(),
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text('Item ${i + 1}'),
                  subtitle: Text('Subtitle for benchmark item ${i + 1}'),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: HSVColor.fromAHSV(1, hue, 0.4, 0.7).toColor(),
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _DetailPage(index: i),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DetailPage extends StatelessWidget {
  final int index;
  const _DetailPage({required this.index});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Detail $index')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.info_outline, size: 80, color: Colors.indigo.shade300),
            const SizedBox(height: 16),
            Text(
              'Detail page for item $index',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Performs scroll fling + page navigation to stress the rendering pipeline.
Future<void> _stressInteractions(WidgetTester tester) async {
  _showStatus('Fling scrolling down...');
  final listFinder = find.byKey(const Key('stressList'));
  if (listFinder.evaluate().isNotEmpty) {
    await tester.fling(listFinder, const Offset(0, -3000), 2000);
    await _pumpFor(tester, const Duration(seconds: 1));

    _showStatus('Fling scrolling back up...');
    await tester.fling(listFinder, const Offset(0, 3000), 2000);
    await _pumpFor(tester, const Duration(milliseconds: 500));
  }

  _showStatus('Navigating to detail page...');
  final firstTile = find.byType(ListTile).first;
  if (firstTile.evaluate().isNotEmpty) {
    await tester.tap(firstTile);
    await _pumpFor(tester, const Duration(milliseconds: 500));

    _showStatus('Navigating back...');
    final backButton = find.byType(BackButton);
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await _pumpFor(tester, const Duration(milliseconds: 500));
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Test App 2: Video Playback Content (scenario F)
// ═══════════════════════════════════════════════════════════════════════════

class _VideoContent extends StatelessWidget {
  final VideoPlayerController controller;
  const _VideoContent({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: controller.value.isInitialized
            ? AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              )
            : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Exception firing helper with visual feedback
// ═══════════════════════════════════════════════════════════════════════════

/// Fires an exception, shows a snackbar, and returns the capture time in us.
int _fireException(String label, Object error, StackTrace st) {
  final capSw = Stopwatch()..start();
  TracewayClient.instance!.captureException(error, st);
  final elapsed = capSw.elapsedMicroseconds;
  _showStatus('EXCEPTION CAPTURED: $label (${elapsed}us)');
  _showSnackbar('Exception: $label');
  return elapsed;
}

// ═══════════════════════════════════════════════════════════════════════════
// Scenarios
// ═══════════════════════════════════════════════════════════════════════════

// ── Scenario A: Baseline (no SDK) ────────────────────────────────────────

Future<List<BenchmarkMetric>> runBaseline(WidgetTester tester) async {
  const scenario = 'baseline';
  final collector = BenchmarkCollector();
  final sw = Stopwatch()..start();

  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  _showStatus('Rendering stress app (no SDK)...');
  await tester.pumpWidget(
    _BenchmarkShell(
      scenarioName: 'A: Baseline (no SDK)',
      child: const _StressContent(),
    ),
  );
  await tester.pumpAndSettle();

  await _stressInteractions(tester);

  _showStatus('Idle rendering...');
  await _pumpFor(tester, const Duration(seconds: 3));

  _showStatus('Collecting metrics...');
  await tester.pump();

  final metrics = <BenchmarkMetric>[
    ...collector.stopFrameTiming(scenario),
    ...collector.snapshotMemory(scenario),
    collector.wallClock(scenario, sw..stop()),
  ];
  return metrics;
}

// ── Scenario B: SDK idle, no screen capture ──────────────────────────────

Future<List<BenchmarkMetric>> runSdkIdleNoCapture(
    WidgetTester tester) async {
  const scenario = 'sdk_idle_no_capture';
  final collector = BenchmarkCollector();

  _showStatus('Initializing SDK (no capture)...');
  TracewayClient.initializeForTest(
    _connectionString,
    const TracewayOptions(screenCapture: false, debug: false),
    reportSender: _reportSender,
  );
  _showSnackbar('SDK initialized (capture OFF)', color: Colors.blue);

  final sw = Stopwatch()..start();
  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  await tester.pumpWidget(
    Traceway(
      child: _BenchmarkShell(
        scenarioName: 'B: SDK idle (no capture)',
        child: const _StressContent(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await _stressInteractions(tester);

  _showStatus('Idle rendering with SDK...');
  await _pumpFor(tester, const Duration(seconds: 3));

  _showStatus('Collecting metrics...');
  await tester.pump();

  final metrics = <BenchmarkMetric>[
    ...collector.stopFrameTiming(scenario),
    ...collector.snapshotMemory(scenario),
    collector.wallClock(scenario, sw..stop()),
  ];

  await TracewayClient.resetForTest();
  return metrics;
}

// ── Scenario C: SDK burst exceptions, no screen capture ──────────────────

Future<List<BenchmarkMetric>> runSdkBurstNoCapture(
    WidgetTester tester) async {
  const scenario = 'sdk_burst_no_capture';
  final collector = BenchmarkCollector();

  _showStatus('Initializing SDK (no capture, burst mode)...');
  TracewayClient.initializeForTest(
    _connectionString,
    const TracewayOptions(
      screenCapture: false,
      debug: false,
      maxPendingExceptions: 25,
    ),
    reportSender: _reportSender,
  );
  _showSnackbar('SDK initialized (burst test)', color: Colors.blue);

  final sw = Stopwatch()..start();
  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  await tester.pumpWidget(
    Traceway(
      child: _BenchmarkShell(
        scenarioName: 'C: SDK + 20 exceptions',
        child: const _StressContent(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await _stressInteractions(tester);

  // Fire 20 exceptions with visual feedback.
  _showStatus('Firing 20 exceptions...');
  await tester.pump();
  final captureTimes = <int>[];
  for (var i = 0; i < 20; i++) {
    try {
      throw FormatException('Benchmark exception #$i');
    } catch (e, st) {
      captureTimes.add(_fireException('#${i + 1}/20', e, st));
    }
    // Pump a frame so the snackbar is visible.
    await tester.pump(const Duration(milliseconds: 50));
  }

  _showStatus('Waiting for sync to settle...');
  await _pumpFor(tester, const Duration(seconds: 3));
  await TracewayClient.instance!.flush(3000);

  _showSnackbar('Flush complete', color: Colors.green);
  _showStatus('Collecting metrics...');
  await tester.pump();

  final metrics = <BenchmarkMetric>[
    ...collector.stopFrameTiming(scenario),
    ...collector.snapshotMemory(scenario),
    collector.wallClock(scenario, sw..stop()),
    collector.exceptionCaptureAvg(scenario, captureTimes),
  ];

  await TracewayClient.resetForTest();
  return metrics;
}

// ── Scenario D: SDK idle, with screen capture ────────────────────────────

Future<List<BenchmarkMetric>> runSdkIdleWithCapture(
    WidgetTester tester) async {
  const scenario = 'sdk_idle_with_capture';
  final collector = BenchmarkCollector();

  _showStatus('Initializing SDK (screen capture ON)...');
  TracewayClient.initializeForTest(
    _connectionString,
    const TracewayOptions(
      screenCapture: true,
      debug: false,
      captureIntervalMs: 67,
      maxBufferFrames: 150,
      capturePixelRatio: 0.75,
    ),
    reportSender: _reportSender,
  );
  _showSnackbar('SDK initialized (capture ON)', color: Colors.orange);

  final sw = Stopwatch()..start();
  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  await tester.pumpWidget(
    Traceway(
      child: _BenchmarkShell(
        scenarioName: 'D: SDK + screen capture (idle)',
        child: const _StressContent(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await _stressInteractions(tester);

  _showStatus('Screen capture running — filling frame buffer...');
  await _pumpFor(tester, const Duration(seconds: 8));

  _showStatus('Collecting metrics...');
  await tester.pump();

  final metrics = <BenchmarkMetric>[
    ...collector.stopFrameTiming(scenario),
    ...collector.snapshotMemory(scenario),
    collector.wallClock(scenario, sw..stop()),
  ];

  await TracewayClient.resetForTest();
  return metrics;
}

// ── Scenario E: SDK burst exceptions, with screen capture ────────────────

Future<List<BenchmarkMetric>> runSdkBurstWithCapture(
    WidgetTester tester) async {
  const scenario = 'sdk_burst_with_capture';
  final collector = BenchmarkCollector();

  _showStatus('Initializing SDK (capture + exceptions)...');
  TracewayClient.initializeForTest(
    _connectionString,
    const TracewayOptions(
      screenCapture: true,
      debug: false,
      captureIntervalMs: 67,
      maxBufferFrames: 150,
      capturePixelRatio: 0.75,
      maxPendingExceptions: 10,
    ),
    reportSender: _reportSender,
  );
  _showSnackbar('SDK initialized (capture + burst)', color: Colors.orange);

  final sw = Stopwatch()..start();
  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  await tester.pumpWidget(
    Traceway(
      child: _BenchmarkShell(
        scenarioName: 'E: SDK + capture + 5 exceptions',
        child: const _StressContent(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await _stressInteractions(tester);

  _showStatus('Screen capture running — filling frame buffer...');
  await _pumpFor(tester, const Duration(seconds: 8));

  // Fire 5 exceptions — each triggers MP4 video encoding from the frame
  // buffer. The SDK's debounce timer handles sync AFTER each recording
  // completes, so we just need to keep pumping long enough for all
  // encodings to finish and the SDK to sync on its own.
  _showStatus('Firing 5 exceptions (triggers MP4 encoding)...');
  await tester.pump();
  final captureTimes = <int>[];
  for (var i = 0; i < 5; i++) {
    try {
      throw StateError('Benchmark capture exception #$i');
    } catch (e, st) {
      captureTimes.add(_fireException('#${i + 1}/5 (MP4 encode)', e, st));
    }
    await _pumpFor(tester, const Duration(seconds: 2));
  }

  // Keep pumping so the SDK can encode recordings and sync naturally.
  _showStatus('Waiting for MP4 encoding + auto-sync...');
  await _pumpFor(tester, const Duration(seconds: 10));

  _showSnackbar('Done', color: Colors.green);
  _showStatus('Collecting metrics...');
  await tester.pump();

  final metrics = <BenchmarkMetric>[
    ...collector.stopFrameTiming(scenario),
    ...collector.snapshotMemory(scenario),
    collector.wallClock(scenario, sw..stop()),
    collector.exceptionCaptureAvg(scenario, captureTimes),
  ];

  await TracewayClient.resetForTest();
  return metrics;
}

// ── Scenario F: Video playback + screen capture + exception burst ────────

Future<List<BenchmarkMetric>> runVideoBurstWithCapture(
    WidgetTester tester) async {
  const scenario = 'video_burst_with_capture';
  final collector = BenchmarkCollector();

  _showStatus('Initializing SDK (capture + video)...');
  TracewayClient.initializeForTest(
    _connectionString,
    const TracewayOptions(
      screenCapture: true,
      debug: false,
      captureIntervalMs: 67,
      maxBufferFrames: 150,
      capturePixelRatio: 0.75,
      maxPendingExceptions: 10,
    ),
    reportSender: _reportSender,
  );

  _showStatus('Loading video...');
  final videoController = VideoPlayerController.asset(
    'assets/videos/BigBuckBunny_15snonSeg.mp4',
  );
  await videoController.initialize();
  await videoController.setLooping(false);
  _showSnackbar('Video loaded, starting playback', color: Colors.orange);

  final sw = Stopwatch()..start();
  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  await tester.pumpWidget(
    Traceway(
      child: _BenchmarkShell(
        scenarioName: 'F: Video + capture + 5 exceptions',
        child: _VideoContent(controller: videoController),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // Start playback.
  await videoController.play();
  _showStatus('Video playing — screen capture recording...');

  // Let video play for 10 seconds.
  await _pumpFor(tester, const Duration(seconds: 10));

  // Fire 5 consecutive exceptions while video is still playing.
  // Each triggers MP4 encoding from the screen recording buffer.
  // Let the SDK sync naturally after each recording completes.
  _showStatus('Firing 5 exceptions during video playback...');
  await tester.pump();
  final captureTimes = <int>[];
  for (var i = 0; i < 5; i++) {
    try {
      throw StateError('Video benchmark exception #$i');
    } catch (e, st) {
      captureTimes.add(
          _fireException('#${i + 1}/5 (video + MP4 encode)', e, st));
    }
    await _pumpFor(tester, const Duration(seconds: 2));
  }

  // Keep pumping so the SDK can encode recordings and sync naturally.
  _showStatus('Waiting for MP4 encoding + auto-sync...');
  await _pumpFor(tester, const Duration(seconds: 10));

  _showSnackbar('Done', color: Colors.green);
  _showStatus('Collecting metrics...');
  await tester.pump();

  await videoController.pause();
  await videoController.dispose();

  final metrics = <BenchmarkMetric>[
    ...collector.stopFrameTiming(scenario),
    ...collector.snapshotMemory(scenario),
    collector.wallClock(scenario, sw..stop()),
    collector.exceptionCaptureAvg(scenario, captureTimes),
  ];

  await TracewayClient.resetForTest();
  return metrics;
}
