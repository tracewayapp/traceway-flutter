// Parses BENCHMARK_RESULT JSONL files and generates a markdown summary.
//
// Expects scenario names in the format: {workload}__{config}
// e.g. "scroll__sdk_capture", "exception_burst__no_sdk"
//
// Usage: dart run parse_benchmark_results.dart <results_dir> [branch] [commit] [run_id]

import 'dart:convert';
import 'dart:io';

const workloadOrder = [
  'idle',
  'scroll',
  'navigation',
  'fullInteraction',
  'exceptionBurst',
  'videoPlayback',
];

const configOrder = [
  'noSdk',
  'sdkNoCapture',
  'sdkCapture',
  'sdkCaptureDisk',
];

const workloadLabels = {
  'idle': 'Idle Rendering',
  'scroll': 'Scroll Stress',
  'navigation': 'Navigation',
  'fullInteraction': 'Full Interaction',
  'exceptionBurst': 'Exception Burst',
  'videoPlayback': 'Video Playback',
};

const configLabels = {
  'noSdk': 'No Traceway',
  'sdkNoCapture': 'SDK (no capture)',
  'sdkCapture': 'SDK + capture',
  'sdkCaptureDisk': 'SDK + capture + disk',
};

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Usage: parse_benchmark_results.dart <results_dir> '
        '[branch] [commit] [run_id]');
    exit(1);
  }

  final resultsDir = Directory(args[0]);
  final branch = args.length > 1 ? args[1] : 'unknown';
  final commit = args.length > 2 ? args[2] : 'unknown';
  final runId = args.length > 3 ? args[3] : '0';

  if (!resultsDir.existsSync()) {
    stderr.writeln('Results directory not found: ${resultsDir.path}');
    _writeEmptyReport(branch, commit, runId);
    exit(0);
  }

  // Collect all JSONL files.
  final jsonlFiles = resultsDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.jsonl'))
      .toList();

  if (jsonlFiles.isEmpty) {
    stderr.writeln('No .jsonl files found in ${resultsDir.path}');
    _writeEmptyReport(branch, commit, runId);
    exit(0);
  }

  // Parse all result lines.
  final results = <Map<String, dynamic>>[];
  for (final file in jsonlFiles) {
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        results.add(jsonDecode(trimmed) as Map<String, dynamic>);
      } catch (e) {
        stderr.writeln('Skipping malformed line: $trimmed');
      }
    }
  }

  if (results.isEmpty) {
    _writeEmptyReport(branch, commit, runId);
    exit(0);
  }

  // Group by: platform -> workload -> config -> device_label -> {metric: value}
  final grouped =
      <String, Map<String, Map<String, Map<String, Map<String, double>>>>>{};

  for (final r in results) {
    final platform = r['platform']?.toString() ?? 'unknown';
    final scenarioRaw = r['scenario']?.toString() ?? 'unknown';
    final deviceLabel =
        r['device_label']?.toString() ?? r['device']?.toString() ?? 'unknown';
    final metric = r['metric']?.toString() ?? 'unknown';
    final value = (r['value'] as num?)?.toDouble() ?? 0;

    // Parse workload__config from scenario name.
    String workload, config;
    final parts = scenarioRaw.split('__');
    if (parts.length == 2) {
      workload = parts[0];
      config = parts[1];
    } else {
      workload = scenarioRaw;
      config = 'unknown';
    }

    grouped
        .putIfAbsent(platform, () => {})
        .putIfAbsent(workload, () => {})
        .putIfAbsent(config, () => {})
        .putIfAbsent(deviceLabel, () => {})[metric] = value;
  }

  // Build the markdown report.
  final buf = StringBuffer();
  buf.writeln('## Traceway SDK - Performance Benchmark Results');
  buf.writeln();
  final shortCommit = commit.length > 7 ? commit.substring(0, 7) : commit;
  final today = DateTime.now().toUtc().toIso8601String().split('T')[0];
  buf.writeln(
      '**Branch:** `$branch` | **Commit:** `$shortCommit` '
      '| **Run:** #$runId | **Date:** $today');
  buf.writeln();

  for (final platform in ['android', 'ios']) {
    final workloads = grouped[platform];
    if (workloads == null || workloads.isEmpty) continue;

    final platformLabel = platform == 'android' ? 'Android' : 'iOS';
    buf.writeln('### $platformLabel');
    buf.writeln();

    // Collect all device labels across this platform.
    final deviceLabels = <String>{};
    for (final wlData in workloads.values) {
      for (final cfgData in wlData.values) {
        deviceLabels.addAll(cfgData.keys);
      }
    }
    final sortedDevices = deviceLabels.toList()..sort();

    for (final wl in workloadOrder) {
      final wlData = workloads[wl];
      if (wlData == null) continue;

      buf.writeln('#### ${workloadLabels[wl] ?? wl}');
      buf.writeln();

      _writeMemoryTable(buf, wlData, sortedDevices);
      _writeFrameTimingTable(buf, wlData, sortedDevices);
      _writeJankTable(buf, wlData, sortedDevices);
      _writePayloadSizeTable(buf, wlData, sortedDevices);

      if (wl == 'exceptionBurst') {
        _writeExceptionCostTable(buf, wlData, sortedDevices);
      }
    }
  }

  // ── Raw data (collapsed) ─────────────────────────────────────────────
  buf.writeln('<details><summary>Raw JSON data</summary>');
  buf.writeln();
  buf.writeln('```json');
  for (final r in results) {
    buf.writeln(jsonEncode(r));
  }
  buf.writeln('```');
  buf.writeln();
  buf.writeln('</details>');

  // Write output file.
  File('benchmark_summary.md').writeAsStringSync(buf.toString());
  stdout.writeln(
      'Generated benchmark_summary.md with ${results.length} data points.');
}

// ═══════════════════════════════════════════════════════════════════════════
// Table helpers
// ═══════════════════════════════════════════════════════════════════════════

void _writeMemoryTable(
  StringBuffer buf,
  Map<String, Map<String, Map<String, double>>> wlData,
  List<String> devices,
) {
  buf.writeln('**Memory Impact (RSS)**');
  buf.writeln();
  buf.write('| Config |');
  for (final d in devices) { buf.write(' $d |'); }
  buf.writeln();
  buf.write('|--------|');
  for (final _ in devices) { buf.write('---------|'); }
  buf.writeln();

  // Baseline RSS per device from no_sdk config.
  final baselineRss = <String, double>{};
  for (final d in devices) {
    baselineRss[d] = wlData['noSdk']?[d]?['rss_bytes'] ?? 0;
  }

  for (final cfg in configOrder) {
    final cfgData = wlData[cfg];
    if (cfgData == null) continue;
    final label = configLabels[cfg] ?? cfg;
    buf.write('| $label |');
    for (final d in devices) {
      final rss = cfgData[d]?['rss_bytes'];
      if (rss == null) {
        buf.write(' - |');
      } else {
        final mb = (rss / 1024 / 1024).toStringAsFixed(1);
        if (cfg == 'noSdk') {
          buf.write(' $mb MB |');
        } else {
          final delta = rss - (baselineRss[d] ?? 0);
          final deltaMb = (delta / 1024 / 1024).toStringAsFixed(1);
          final sign = delta >= 0 ? '+' : '';
          buf.write(' $mb MB ($sign$deltaMb) |');
        }
      }
    }
    buf.writeln();
  }
  buf.writeln();
}

void _writeFrameTimingTable(
  StringBuffer buf,
  Map<String, Map<String, Map<String, double>>> wlData,
  List<String> devices,
) {
  buf.writeln('**Frame Timing (build duration)**');
  buf.writeln();
  buf.write('| Config |');
  for (final d in devices) { buf.write(' $d p50 / p99 |'); }
  buf.writeln();
  buf.write('|--------|');
  for (final _ in devices) { buf.write('-------------|'); }
  buf.writeln();

  for (final cfg in configOrder) {
    final cfgData = wlData[cfg];
    if (cfgData == null) continue;
    final label = configLabels[cfg] ?? cfg;
    buf.write('| $label |');
    for (final d in devices) {
      final p50 = cfgData[d]?['frame_build_p50_us'];
      final p99 = cfgData[d]?['frame_build_p99_us'];
      if (p50 == null || p99 == null) {
        buf.write(' - |');
      } else {
        final p50Ms = (p50 / 1000).toStringAsFixed(1);
        final p99Ms = (p99 / 1000).toStringAsFixed(1);
        buf.write(' ${p50Ms}ms / ${p99Ms}ms |');
      }
    }
    buf.writeln();
  }
  buf.writeln();
}

void _writeJankTable(
  StringBuffer buf,
  Map<String, Map<String, Map<String, double>>> wlData,
  List<String> devices,
) {
  buf.writeln('**Jank Frames (> 16.67ms)**');
  buf.writeln();
  buf.write('| Config |');
  for (final d in devices) { buf.write(' $d |'); }
  buf.writeln();
  buf.write('|--------|');
  for (final _ in devices) { buf.write('---------|'); }
  buf.writeln();

  for (final cfg in configOrder) {
    final cfgData = wlData[cfg];
    if (cfgData == null) continue;
    final label = configLabels[cfg] ?? cfg;
    buf.write('| $label |');
    for (final d in devices) {
      final jank = cfgData[d]?['jank_frame_count'];
      final total = cfgData[d]?['total_frame_count'];
      if (jank == null) {
        buf.write(' - |');
      } else {
        final totalStr = total != null ? ' / ${total.toInt()}' : '';
        buf.write(' ${jank.toInt()}$totalStr |');
      }
    }
    buf.writeln();
  }
  buf.writeln();
}

void _writeExceptionCostTable(
  StringBuffer buf,
  Map<String, Map<String, Map<String, double>>> wlData,
  List<String> devices,
) {
  buf.writeln('**Exception Capture Cost**');
  buf.writeln();
  buf.write('| Config |');
  for (final d in devices) { buf.write(' $d avg |'); }
  buf.writeln();
  buf.write('|--------|');
  for (final _ in devices) { buf.write('---------|'); }
  buf.writeln();

  for (final cfg in configOrder) {
    final cfgData = wlData[cfg];
    if (cfgData == null) continue;
    final label = configLabels[cfg] ?? cfg;
    buf.write('| $label |');
    for (final d in devices) {
      final avg = cfgData[d]?['exception_capture_avg_us'];
      if (avg == null) {
        buf.write(' - |');
      } else {
        buf.write(' ${(avg / 1000).toStringAsFixed(2)}ms |');
      }
    }
    buf.writeln();
  }
  buf.writeln();
}

void _writePayloadSizeTable(
  StringBuffer buf,
  Map<String, Map<String, Map<String, double>>> wlData,
  List<String> devices,
) {
  // Only render if any config has payload data.
  final hasData = wlData.values.any((cfgData) =>
      cfgData.values.any((devData) => devData.containsKey('payload_raw_bytes')));
  if (!hasData) return;

  buf.writeln('**Payload Size**');
  buf.writeln();
  buf.write('| Config |');
  for (final d in devices) { buf.write(' $d raw / gzip |'); }
  buf.writeln();
  buf.write('|--------|');
  for (final _ in devices) { buf.write('---------------|'); }
  buf.writeln();

  for (final cfg in configOrder) {
    final cfgData = wlData[cfg];
    if (cfgData == null) continue;
    final label = configLabels[cfg] ?? cfg;
    buf.write('| $label |');
    for (final d in devices) {
      final raw = cfgData[d]?['payload_raw_bytes'];
      final gz = cfgData[d]?['payload_gzip_bytes'];
      if (raw == null) {
        buf.write(' - |');
      } else {
        final rawKb = (raw / 1024).toStringAsFixed(1);
        final gzKb = (gz! / 1024).toStringAsFixed(1);
        buf.write(' ${rawKb}KB / ${gzKb}KB |');
      }
    }
    buf.writeln();
  }
  buf.writeln();
}

// ═══════════════════════════════════════════════════════════════════════════
// Empty report fallback
// ═══════════════════════════════════════════════════════════════════════════

void _writeEmptyReport(String branch, String commit, String runId) {
  final buf = StringBuffer();
  buf.writeln('## Traceway SDK - Performance Benchmark Results');
  buf.writeln();
  final shortCommit = commit.length > 7 ? commit.substring(0, 7) : commit;
  buf.writeln(
      '**Branch:** `$branch` | **Commit:** `$shortCommit` '
      '| **Run:** #$runId');
  buf.writeln();
  buf.writeln('> No benchmark results were collected. '
      'Check individual job logs for errors.');
  File('benchmark_summary.md').writeAsStringSync(buf.toString());
}
