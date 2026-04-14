import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';

/// Environment metadata injected via --dart-define at build time.
const _device = String.fromEnvironment('BENCH_DEVICE', defaultValue: 'local');
const _apiLevel = String.fromEnvironment('BENCH_API', defaultValue: 'unknown');
const _branch = String.fromEnvironment('BENCH_BRANCH', defaultValue: 'local');
const _commit = String.fromEnvironment('BENCH_COMMIT', defaultValue: 'unknown');
const _runId = String.fromEnvironment('BENCH_RUN_ID', defaultValue: '0');

/// A single benchmark measurement.
class BenchmarkMetric {
  final String scenario;
  final String metric;
  final double value;
  final String unit;
  final DateTime timestamp;

  BenchmarkMetric({
    required this.scenario,
    required this.metric,
    required this.value,
    required this.unit,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'scenario': scenario,
        'metric': metric,
        'value': value,
        'unit': unit,
        'device': _device,
        'api_level': _apiLevel,
        'branch': _branch,
        'commit': _commit,
        'run_id': _runId,
        'ts': timestamp.toUtc().toIso8601String(),
      };
}

/// Collects RAM, frame timing, and wall-clock metrics during a benchmark run.
class BenchmarkCollector {
  final List<int> _frameBuildDurations = [];
  final List<int> _frameRasterDurations = [];
  final List<int> _frameTotalDurations = [];
  bool _collectingFrames = false;

  int _rssAtStart = 0;

  // ── Memory ──────────────────────────────────────────────────────────

  void snapshotMemoryStart() {
    _rssAtStart = ProcessInfo.currentRss;
  }

  List<BenchmarkMetric> snapshotMemory(String scenario) {
    final rssNow = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    return [
      BenchmarkMetric(
        scenario: scenario,
        metric: 'rss_bytes',
        value: rssNow.toDouble(),
        unit: 'bytes',
      ),
      BenchmarkMetric(
        scenario: scenario,
        metric: 'max_rss_bytes',
        value: maxRss.toDouble(),
        unit: 'bytes',
      ),
      BenchmarkMetric(
        scenario: scenario,
        metric: 'rss_delta_bytes',
        value: (rssNow - _rssAtStart).toDouble(),
        unit: 'bytes',
      ),
    ];
  }

  // ── Frame Timing ────────────────────────────────────────────────────

  void startFrameTiming() {
    _frameBuildDurations.clear();
    _frameRasterDurations.clear();
    _frameTotalDurations.clear();
    _collectingFrames = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_collectingFrames) return;
    for (final t in timings) {
      _frameBuildDurations.add(t.buildDuration.inMicroseconds);
      _frameRasterDurations.add(t.rasterDuration.inMicroseconds);
      _frameTotalDurations.add(t.totalSpan.inMicroseconds);
    }
  }

  List<BenchmarkMetric> stopFrameTiming(String scenario) {
    _collectingFrames = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);

    final metrics = <BenchmarkMetric>[];

    if (_frameBuildDurations.isEmpty) return metrics;

    _frameBuildDurations.sort();
    _frameRasterDurations.sort();
    _frameTotalDurations.sort();

    metrics.addAll([
      _percentileMetric(scenario, 'frame_build', _frameBuildDurations, 50),
      _percentileMetric(scenario, 'frame_build', _frameBuildDurations, 90),
      _percentileMetric(scenario, 'frame_build', _frameBuildDurations, 99),
      BenchmarkMetric(
        scenario: scenario,
        metric: 'frame_build_max_us',
        value: _frameBuildDurations.last.toDouble(),
        unit: 'microseconds',
      ),
      _percentileMetric(scenario, 'frame_raster', _frameRasterDurations, 50),
      _percentileMetric(scenario, 'frame_raster', _frameRasterDurations, 90),
      _percentileMetric(scenario, 'frame_raster', _frameRasterDurations, 99),
      _percentileMetric(scenario, 'frame_total', _frameTotalDurations, 50),
      _percentileMetric(scenario, 'frame_total', _frameTotalDurations, 99),
      BenchmarkMetric(
        scenario: scenario,
        metric: 'jank_frame_count',
        value: _frameTotalDurations.where((d) => d > 16667).length.toDouble(),
        unit: 'count',
      ),
      BenchmarkMetric(
        scenario: scenario,
        metric: 'total_frame_count',
        value: _frameTotalDurations.length.toDouble(),
        unit: 'count',
      ),
    ]);

    return metrics;
  }

  BenchmarkMetric _percentileMetric(
    String scenario,
    String prefix,
    List<int> sorted,
    int p,
  ) {
    final idx = ((p / 100.0) * (sorted.length - 1)).round();
    return BenchmarkMetric(
      scenario: scenario,
      metric: '${prefix}_p${p}_us',
      value: sorted[idx].toDouble(),
      unit: 'microseconds',
    );
  }

  // ── Wall Clock ──────────────────────────────────────────────────────

  BenchmarkMetric wallClock(String scenario, Stopwatch sw) {
    return BenchmarkMetric(
      scenario: scenario,
      metric: 'wall_clock_ms',
      value: sw.elapsedMilliseconds.toDouble(),
      unit: 'milliseconds',
    );
  }

  // ── Exception Capture Timing ────────────────────────────────────────

  BenchmarkMetric exceptionCaptureAvg(
    String scenario,
    List<int> captureTimesUs,
  ) {
    if (captureTimesUs.isEmpty) {
      return BenchmarkMetric(
        scenario: scenario,
        metric: 'exception_capture_avg_us',
        value: 0,
        unit: 'microseconds',
      );
    }
    final avg = captureTimesUs.reduce((a, b) => a + b) / captureTimesUs.length;
    return BenchmarkMetric(
      scenario: scenario,
      metric: 'exception_capture_avg_us',
      value: avg,
      unit: 'microseconds',
    );
  }

  // ── Output ──────────────────────────────────────────────────────────

  /// File path on device where results are written as a backup to logcat.
  /// Firebase Test Lab pulls this via --directories-to-pull=/sdcard/Download.
  static const _resultsFilePath = '/sdcard/Download/benchmark_results.jsonl';

  static Future<void> emitResults(List<BenchmarkMetric> metrics) async {
    final file = File(_resultsFilePath);
    final sink = file.openWrite(mode: FileMode.append);
    for (final m in metrics) {
      final line = 'BENCHMARK_RESULT:${jsonEncode(m.toJson())}';
      sink.writeln(line);
      // Keep print() for local development visibility and logcat fallback.
      print(line);
    }
    await sink.flush();
    await sink.close();
  }
}
