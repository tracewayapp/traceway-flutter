import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' show FrameTiming, FramePhase;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'markers.dart';
import 'settings.dart';

/// The in-app probe of 03-MEASUREMENT.md §3.2: build, raster and total time
/// of every frame, from `addTimingsCallback`. It is in every build,
/// including `off`, so its cost cancels out.
///
/// The file is written at `FM_DONE` and whenever the app goes to the
/// background: Linux `~/.local/share/<application id>/fm-probe/<run>.json`,
/// Android `<external files>/fm-probe/<run>.json`.
class Probe with WidgetsBindingObserver {
  Probe(this.settings);

  final LaunchSettings settings;

  /// Engine timestamps are on the monotonic clock `Timeline.now` reads.
  late final int _epochMinusMonotonicUs =
      DateTime.now().microsecondsSinceEpoch - Timeline.now;

  final List<int> _build = [];
  final List<int> _raster = [];
  final List<int> _total = [];
  final List<int> _startMs = [];
  final List<Map<String, Object?>> events = [];
  bool _started = false;
  int _writes = 0;

  void start() {
    if (_started) return;
    _started = true;
    _epochMinusMonotonicUs; // pin the offset now
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _build.add(t.buildDuration.inMicroseconds);
      _raster.add(t.rasterDuration.inMicroseconds);
      _total.add(t.totalSpan.inMicroseconds);
      _startMs.add((t.timestampInMicroseconds(FramePhase.vsyncStart) +
              _epochMinusMonotonicUs) ~/
          1000);
    }
  }

  /// Something worth lining up with the frames, e.g. a lifecycle change.
  void event(String name, [Map<String, Object?> data = const {}]) =>
      events.add({'name': name, 'epochMs': DateTime.now().millisecondsSinceEpoch, ...data});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    event('lifecycle', {'state': state.name});
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      write('background');
    }
  }

  Future<Directory> _dir() async {
    if (settings.probeDir != null) return Directory(settings.probeDir!);
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory() ?? await getApplicationSupportDirectory())
        : await getApplicationSupportDirectory();
    return Directory('${base.path}/fm-probe');
  }

  Map<String, Object?> toJson() => {
        'run': settings.run,
        'variant': settings.variant,
        'scenario': settings.scenario,
        'frameFields': ['build', 'raster', 'total', 'startEpochMs'],
        'frameUnits': 'µs (startEpochMs in ms)',
        'frames': [
          for (var i = 0; i < _total.length; i++)
            {
              'build': _build[i],
              'raster': _raster[i],
              'total': _total[i],
              'startEpochMs': _startMs[i],
            },
        ],
        'longTasks': const [],
        'events': events,
        'vitals': const {},
        'markers': Markers.recorded,
      };

  Future<String?> _last = Future<String?>.value();

  /// Writes the file (the whole list each time) and prints `FM_PROBE <path>`.
  /// Writes queue behind each other: going to the background asks twice.
  Future<String?> write(String reason) => _last = _last.then((_) => _write(reason));

  Future<String?> _write(String reason) async {
    try {
      final dir = await _dir();
      await dir.create(recursive: true);
      final file = File('${dir.path}/${settings.run}.json');
      final tmp = File('${file.path}.$_writes.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      await tmp.rename(file.path);
      _writes++;
      Markers.emit('FM_PROBE $reason ${_total.length} $_writes ${file.path}');
      return file.path;
    } catch (e) {
      Markers.emit('FM_PROBE_ERROR $e');
      return null;
    }
  }
}
