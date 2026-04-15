import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/exception_store.dart';
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

/// Tracks which scenario is running so the no-op sender can tag payload metrics.
String _currentScenario = '';

/// When no real DSN, use a no-op sender that includes gzip cost but discards.
/// When a real DSN is set, pass null to use the SDK's default sendReport.
ReportSender? get _reportSender =>
    _useRealBackend ? null : _noOpSender;

Future<bool> _noOpSender(String url, String token, String body) async {
  final raw = utf8.encode(body);
  final compressed = gzip.encode(raw);
  final ts = DateTime.now().toUtc().toIso8601String();
  for (final entry in [
    {'metric': 'payload_raw_bytes', 'value': raw.length, 'unit': 'bytes'},
    {'metric': 'payload_gzip_bytes', 'value': compressed.length, 'unit': 'bytes'},
  ]) {
    final line = 'BENCHMARK_RESULT:${jsonEncode({
      'scenario': _currentScenario,
      ...entry,
      'ts': ts,
    })}';
    print(line);
  }
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
                builder: (_, status, _) => Column(
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
// Test App 1: Stress Test App
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

// ═══════════════════════════════════════════════════════════════════════════
// Test App 2: Video Playback Content
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
// Interaction helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Fling scroll down and back up.
Future<void> _scrollInteraction(WidgetTester tester) async {
  _showStatus('Fling scrolling down...');
  final listFinder = find.byKey(const Key('stressList'));
  if (listFinder.evaluate().isNotEmpty) {
    await tester.fling(listFinder, const Offset(0, -3000), 2000);
    await _pumpFor(tester, const Duration(seconds: 1));

    _showStatus('Fling scrolling back up...');
    await tester.fling(listFinder, const Offset(0, 3000), 2000);
    await _pumpFor(tester, const Duration(milliseconds: 500));
  }
}

/// Tap first ListTile, navigate to detail page, navigate back.
Future<void> _navInteraction(WidgetTester tester) async {
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

/// Combined scroll + navigation stress test.
Future<void> _stressInteractions(WidgetTester tester) async {
  await _scrollInteraction(tester);
  await _navInteraction(tester);
}

// ═══════════════════════════════════════════════════════════════════════════
// Exception firing helper with visual feedback
// ═══════════════════════════════════════════════════════════════════════════

/// Fires an exception, shows a snackbar, and returns the capture time in us.
/// If TracewayClient is not initialized (no_sdk config), just measures
/// throw+catch time without calling captureException.
int _fireException(String label, Object error, StackTrace st) {
  final capSw = Stopwatch()..start();
  if (TracewayClient.instance != null) {
    TracewayClient.instance!.captureException(error, st);
  }
  final elapsed = capSw.elapsedMicroseconds;
  _showStatus('EXCEPTION CAPTURED: $label (${elapsed}us)');
  _showSnackbar('Exception: $label');
  return elapsed;
}

// ═══════════════════════════════════════════════════════════════════════════
// Workload x SDK Config matrix
// ═══════════════════════════════════════════════════════════════════════════

enum Workload {
  idle,
  scroll,
  navigation,
  fullInteraction,
  exceptionBurst,
  videoPlayback,
}

enum SdkConfig {
  noSdk,
  sdkNoCapture,
  sdkCapture,
  sdkCaptureDisk,
}

const _workloadLabels = {
  Workload.idle: 'Idle Rendering',
  Workload.scroll: 'Scroll Stress',
  Workload.navigation: 'Navigation',
  Workload.fullInteraction: 'Full Interaction',
  Workload.exceptionBurst: 'Exception Burst',
  Workload.videoPlayback: 'Video Playback',
};

const _configLabels = {
  SdkConfig.noSdk: 'No SDK',
  SdkConfig.sdkNoCapture: 'SDK (no capture)',
  SdkConfig.sdkCapture: 'SDK + capture',
  SdkConfig.sdkCaptureDisk: 'SDK + capture + disk',
};

// ═══════════════════════════════════════════════════════════════════════════
// Unified scenario runner
// ═══════════════════════════════════════════════════════════════════════════

Future<List<BenchmarkMetric>> runScenario({
  required WidgetTester tester,
  required String workload,
  required String config,
}) async {
  final wl = Workload.values.byName(workload);
  final cfg = SdkConfig.values.byName(config);
  final scenario = '${workload}__$config';
  final displayName = '${_workloadLabels[wl]} | ${_configLabels[cfg]}';

  final hasCapture = cfg == SdkConfig.sdkCapture || cfg == SdkConfig.sdkCaptureDisk;
  final hasSdk = cfg != SdkConfig.noSdk;
  _currentScenario = scenario;

  // ── Phase 1: SDK setup ──────────────────────────────────────────────
  Directory? storeDir;

  switch (cfg) {
    case SdkConfig.noSdk:
      break;

    case SdkConfig.sdkNoCapture:
      _showStatus('Initializing SDK (no capture)...');
      TracewayClient.initializeForTest(
        _connectionString,
        const TracewayOptions(screenCapture: false, debug: false),
        reportSender: _reportSender,
      );
      _showSnackbar('SDK initialized (capture OFF)', color: Colors.blue);
      break;

    case SdkConfig.sdkCapture:
      _showStatus('Initializing SDK (screen capture ON)...');
      TracewayClient.initializeForTest(
        _connectionString,
        const TracewayOptions(
          screenCapture: true,
          debug: false,
          fps: 15,
          maxBufferFrames: 150,
          capturePixelRatio: 0.75,
          maxPendingExceptions: 10,
        ),
        reportSender: _reportSender,
      );
      _showSnackbar('SDK initialized (capture ON)', color: Colors.orange);
      break;

    case SdkConfig.sdkCaptureDisk:
      storeDir = await Directory.systemTemp.createTemp('traceway_bench_');
      final store = ExceptionStore(
        maxLocalFiles: 30,
        maxAgeHours: 48,
        testDir: storeDir,
      );
      await store.init();
      _showStatus('Initializing SDK (capture + disk)...');
      TracewayClient.initializeForTest(
        _connectionString,
        const TracewayOptions(
          screenCapture: true,
          debug: false,
          fps: 15,
          maxBufferFrames: 150,
          capturePixelRatio: 0.75,
          persistToDisk: true,
          maxPendingExceptions: 10,
        ),
        reportSender: _reportSender,
        store: store,
      );
      _showSnackbar('SDK initialized (capture + disk)', color: Colors.orange);
      break;
  }

  // ── Phase 2: Render widget tree ─────────────────────────────────────
  VideoPlayerController? videoController;
  Widget content;

  if (wl == Workload.videoPlayback) {
    _showStatus('Loading video...');
    videoController = VideoPlayerController.asset(
      'assets/videos/BigBuckBunny_15snonSeg.mp4',
    );
    await videoController.initialize();
    await videoController.setLooping(false);
    content = _VideoContent(controller: videoController);
  } else {
    content = const _StressContent();
  }

  final shell = _BenchmarkShell(scenarioName: displayName, child: content);
  final rootWidget = hasSdk ? Traceway(child: shell) : shell;

  final collector = BenchmarkCollector();
  final sw = Stopwatch()..start();
  collector.snapshotMemoryStart();
  collector.startFrameTiming();

  await tester.pumpWidget(rootWidget);
  await _pumpFor(tester, const Duration(milliseconds: 500));

  // ── Phase 3: Execute workload ───────────────────────────────────────
  var captureTimes = <int>[];

  try {
    switch (wl) {
      case Workload.idle:
        _showStatus('Idle rendering...');
        await _pumpFor(tester, const Duration(seconds: 5));
        break;

      case Workload.scroll:
        await _scrollInteraction(tester);
        _showStatus('Settling...');
        await _pumpFor(tester, const Duration(seconds: 3));
        break;

      case Workload.navigation:
        await _navInteraction(tester);
        _showStatus('Settling...');
        await _pumpFor(tester, const Duration(seconds: 3));
        break;

      case Workload.fullInteraction:
        await _stressInteractions(tester);
        _showStatus('Settling...');
        await _pumpFor(tester, const Duration(seconds: 3));
        break;

      case Workload.exceptionBurst:
        await _stressInteractions(tester);
        if (hasCapture) {
          _showStatus('Filling capture buffer...');
          await _pumpFor(tester, const Duration(seconds: 8));
        }
        _showStatus('Firing 5 exceptions...');
        await tester.pump();
        for (var i = 0; i < 5; i++) {
          try {
            throw StateError('Benchmark exception #$i');
          } catch (e, st) {
            captureTimes.add(_fireException('#${i + 1}/5', e, st));
          }
          await _pumpFor(tester, const Duration(seconds: 2));
        }
        _showStatus('Settling after exceptions...');
        await _pumpFor(tester, const Duration(seconds: 10));
        break;

      case Workload.videoPlayback:
        await videoController!.play();
        _showStatus('Video playing...');
        await _pumpFor(tester, const Duration(seconds: 10));
        _showStatus('Settling...');
        await _pumpFor(tester, const Duration(seconds: 3));
        break;
    }

    // ── Phase 4: Collect metrics ──────────────────────────────────────
    _showStatus('Collecting metrics...');
    await tester.pump();

    final metrics = <BenchmarkMetric>[
      ...collector.stopFrameTiming(scenario),
      ...collector.snapshotMemory(scenario),
      collector.wallClock(scenario, sw..stop()),
    ];

    if (wl == Workload.exceptionBurst) {
      metrics.add(collector.exceptionCaptureAvg(scenario, captureTimes));
    }

    return metrics;
  } finally {
    // ── Phase 5: Cleanup ──────────────────────────────────────────────
    if (videoController != null) {
      await videoController.pause();
      await videoController.dispose();
    }

    if (hasSdk && TracewayClient.instance != null) {
      try {
        await TracewayClient.instance!.flush(3000);
      } catch (_) {}
      await TracewayClient.resetForTest();
    }

    if (storeDir != null && storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  }
}
