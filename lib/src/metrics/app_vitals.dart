import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'metrics_recorder.dart';

/// A cold start this slow counts the user as affected (Android vitals'
/// "excessive" cold start); a return from the background this slow too.
const double slowColdStartMs = 5000;
const double slowHotStartMs = 1500;

/// A frame on screen this long is frozen (Android vitals, Sentry); between
/// the display's frame budget and this it is slow.
const int frozenFrameUs = 700000;

const int _maxStartMs = 120000;

/// Screen changes kept for frames whose timings have not arrived yet. The
/// engine reports them about once a second: this is many seconds of
/// navigation, and timings that arrive prune it to one entry or two.
const int _maxScreenChanges = 32;

class _Visit {
  _Visit(this.screen, this.startUs);

  /// Renamed when the app names the route by its template.
  String screen;
  final int startUs;
  bool displayed = false;
  bool fullyDisplayed = false;
}

/// The screen in effect from frame [frameNumber] on.
class _ScreenSince {
  _ScreenSince(this.frameNumber, this.screen);
  final int frameNumber;
  String? screen;
}

class _FrameCounts {
  int total = 0, slow = 0, frozen = 0;
}

/// Measures what the dashboard's Flutter Performance charts, from the
/// engine and the framework alone, without native code:
///
/// * cold start: from the process start (`/proc` on Android and Linux;
///   elsewhere from when the SDK was initialized) to the first frame on
///   screen; hot start: from the return to the foreground to the next frame;
/// * time to initial display of a screen: from the navigation to the end of
///   the first frame that built it; time to full display: until the app
///   calls `Traceway.reportFullyDisplayed()`;
/// * slow and frozen frames from the engine's frame timings: slow when the
///   UI or raster thread took longer than the display's frame budget,
///   frozen when the frame took 700 ms or more, each counted under the
///   screen the frame was built on;
/// * hangs: the UI isolate did not run a timer for 2 s or more while the
///   app was in the foreground; not in debug builds, unless asked.
class AppVitals {
  AppVitals(
    this._recorder, {
    required this.currentScreen,
    int Function()? nowUs,
    int Function()? frameNumber,
    this.hangThresholdMs = 2000,
    this.watchdogIntervalMs = 500,
    this.reportHangs = !kDebugMode,
  })  : _nowUs = nowUs ?? (() => DateTime.now().microsecondsSinceEpoch),
        _frameNumber = frameNumber ??
            (() => PlatformDispatcher.instance.frameData.frameNumber);

  final MetricsRecorder _recorder;

  /// The screen being shown, normalized, for the frame and hang dimensions.
  final String? Function() currentScreen;
  final int Function() _nowUs;

  /// The number of the frame being built, as [FrameTiming.frameNumber]
  /// numbers it; -1 when the engine does not say.
  final int Function() _frameNumber;
  final int hangThresholdMs;
  final int watchdogIntervalMs;

  /// Whether the watchdog runs. A breakpoint, a hot reload or a slow JIT
  /// compile stops the isolate just as a hang does, and nothing in the
  /// isolate tells them apart: a debug build reports hangs only when asked.
  final bool reportHangs;

  bool _started = false;
  AppLifecycleState? _state;
  bool _backgrounded = false;
  bool _backgroundedBeforeFirstFrame = false;
  bool _firstFrameDone = false;
  _Visit? _visit;
  Timer? _watchdog;
  final Stopwatch _clock = Stopwatch();
  bool _frameCallbackAdded = false;
  final List<_ScreenSince> _screens = [];

  /// Call as early as possible, when the SDK is initialized: the first
  /// frame usually comes before the SDK has finished starting.
  void watchColdStart({required int sdkStartMs, int? processStartMs}) {
    try {
      _measureColdStart(processStartMs, sdkStartMs);
    } catch (_) {
      // Initialized before the Flutter binding: there is no frame to wait for.
    }
  }

  void start() {
    if (_started) return;
    final WidgetsBinding binding;
    try {
      binding = WidgetsBinding.instance;
    } catch (_) {
      return;
    }
    _started = true;
    _state = binding.lifecycleState;
    binding.addTimingsCallback(onTimings);
    // A persistent callback cannot be removed: it is added once, and does
    // nothing while stopped.
    if (!_frameCallbackAdded) {
      _frameCallbackAdded = true;
      binding.addPersistentFrameCallback(_sampleScreen);
    }
    if (_foreground) _startWatchdog();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    try {
      WidgetsBinding.instance.removeTimingsCallback(onTimings);
    } catch (_) {}
    _screens.clear();
    _stopWatchdog();
  }

  bool get _foreground => _state == null || _state == AppLifecycleState.resumed;

  // ------------------------------------------------------------ app start

  /// The process start on Android and Linux, from `/proc`, as Unix ms.
  static int? readProcessStartMs() {
    if (!(Platform.isAndroid || Platform.isLinux)) return null;
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      // The command name can hold spaces and parentheses: fields are counted
      // after the last `)`, where field 3 (the state) begins.
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      final startTicks = int.parse(fields[19]);
      final uptime = double.parse(
          File('/proc/uptime').readAsStringSync().split(' ').first);
      // USER_HZ is 100 on every Linux and Android ABI.
      final ageMs = (uptime - startTicks / 100) * 1000;
      if (ageMs < 0) return null;
      return DateTime.now().millisecondsSinceEpoch - ageMs.round();
    } catch (_) {
      return null;
    }
  }

  /// Whether a start whose first frame came in [state] is one somebody
  /// waited for. Launched into the background, or left before the first
  /// frame, it is not. `inactive` is still on screen: an unfocused desktop
  /// window, iOS during its launch transition, a system overlay.
  @visibleForTesting
  static bool coldStartCounts(
          bool backgroundedBeforeFirstFrame, AppLifecycleState? state) =>
      !backgroundedBeforeFirstFrame &&
      state != AppLifecycleState.hidden &&
      state != AppLifecycleState.paused &&
      state != AppLifecycleState.detached;

  void _measureColdStart(int? processStartMs, int sdkStartMs) {
    final binding = WidgetsBinding.instance;
    // Started after the first frame: there is no start left to measure.
    if (binding.firstFrameRasterized) {
      _firstFrameDone = true;
      return;
    }
    // A process the system started long before the app was opened (for a
    // service or a broadcast) measures from the SDK instead.
    final startMs = processStartMs != null &&
            processStartMs <= sdkStartMs &&
            sdkStartMs - processStartMs < 30000
        ? processStartMs
        : sdkStartMs;
    unawaited(binding.waitUntilFirstFrameRasterized.then((_) {
      _firstFrameDone = true;
      if (!coldStartCounts(
          _backgroundedBeforeFirstFrame, binding.lifecycleState)) {
        return;
      }
      final ms = _nowUs() / 1000 - startMs;
      if (ms <= 0 || ms > _maxStartMs) return;
      _recorder.appStart(ms, 'cold', slow: ms >= slowColdStartMs);
    }));
  }

  void _measureHotStart() {
    final atUs = _nowUs();
    try {
      final scheduler = SchedulerBinding.instance;
      scheduler.addPostFrameCallback((_) {
        if (!_started) return;
        final ms = (_nowUs() - atUs) / 1000;
        if (ms < 0 || ms > _maxStartMs) return;
        _recorder.appStart(ms, 'hot', slow: ms >= slowHotStartMs);
      });
      scheduler.ensureVisualUpdate();
    } catch (_) {}
  }

  void lifecycleChanged(AppLifecycleState state) {
    _state = state;
    if (state == AppLifecycleState.resumed) {
      _startWatchdog();
      if (_backgrounded) {
        _backgrounded = false;
        if (_started) _measureHotStart();
      }
      return;
    }
    _stopWatchdog();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (!_firstFrameDone) _backgroundedBeforeFirstFrame = true;
      // A screen still loading when the user left is not displayed later.
      _visit = null;
    }
    if (state == AppLifecycleState.paused) _backgrounded = true;
  }

  // -------------------------------------------------------------- screens

  /// A navigation to [screen] (normalized) at [at]. Only a route that is
  /// new on the stack is built and displayed; returning to one is not.
  /// [displayed]: the route already drew its first frame (the navigator
  /// observer waited for it to learn its name), so its time to initial
  /// display ends now.
  void navigated(String? screen, String action, DateTime at,
      {bool displayed = false}) {
    if (screen == null || (action != 'push' && action != 'replace')) {
      if (action != 'remove') _visit = null;
      return;
    }
    if (!_foreground) {
      _visit = null;
      return;
    }
    final visit = _Visit(screen, at.microsecondsSinceEpoch);
    _visit = visit;
    void done() {
      if (visit.displayed) return;
      visit.displayed = true;
      final ms = (_nowUs() - visit.startUs) / 1000;
      if (ms >= 0 && ms <= _maxStartMs) {
        _recorder.screenDisplayed(visit.screen, ms);
      }
    }

    if (displayed) {
      done();
      return;
    }
    try {
      final scheduler = SchedulerBinding.instance;
      // Reported during a frame's post-frame callbacks (a splash screen
      // replacing itself once drawn), the route is built by the next frame:
      // a callback added now runs after that one.
      scheduler.addPostFrameCallback((_) => done());
      // A navigation always rebuilds; this only makes sure a router that
      // reports before scheduling its frame is not measured against some
      // later, unrelated one.
      scheduler.ensureVisualUpdate();
    } catch (_) {
      // No binding (a plain Dart test): there are no frames to wait for.
    }
  }

  /// The current screen shows everything it loads.
  void fullyDisplayed() {
    final visit = _visit;
    if (visit == null || visit.fullyDisplayed) return;
    visit.fullyDisplayed = true;
    final ms = (_nowUs() - visit.startUs) / 1000;
    if (ms >= 0 && ms <= _maxStartMs) {
      _recorder.screenFullyDisplayed(visit.screen, ms);
    }
  }

  /// The app named the current screen by its route template after
  /// navigating (`/orders/:id`): a screen not yet fully displayed records
  /// its times to initial (if still to come) and full display under it, and
  /// the frames it drew so far count under it too.
  void routeNamed(String screen) {
    final visit = _visit;
    if (visit == null || visit.fullyDisplayed) return;
    if (_screens.isNotEmpty && _screens.last.screen == visit.screen) {
      _screens.last.screen = screen;
    }
    visit.screen = screen;
  }

  // --------------------------------------------------------------- frames

  int _frameBudgetUs() {
    var rate = 60.0;
    try {
      final displays = PlatformDispatcher.instance.displays;
      if (displays.isNotEmpty) {
        final r = displays.first.refreshRate;
        if (r >= 24 && r <= 500) rate = r;
      }
    } catch (_) {}
    return (1000000 / rate).round();
  }

  /// Notes, during each frame, the screen it is built on when that changed:
  /// the engine reports a frame's timings later, in release builds in
  /// batches about once a second, by when the app may show another screen.
  void _sampleScreen(Duration _) {
    if (!_started) return;
    final frame = _frameNumber();
    if (frame < 0) return;
    final screen = currentScreen();
    if (_screens.isNotEmpty) {
      final last = _screens.last;
      if (last.screen == screen) return;
      // The same frame built again (a warm-up frame) under another screen.
      if (last.frameNumber >= frame) _screens.removeLast();
    }
    _screens.add(_ScreenSince(frame, screen));
    if (_screens.length > _maxScreenChanges) _screens.removeAt(0);
  }

  /// The screen [frame] was built on: the current one when the engine did
  /// not number it, or it was built before the changes kept.
  String? _screenOf(int frame, String? current) {
    if (frame < 0) return current;
    for (var i = _screens.length - 1; i >= 0; i--) {
      if (_screens[i].frameNumber <= frame) return _screens[i].screen;
    }
    return current;
  }

  @visibleForTesting
  void onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    final budget = _frameBudgetUs();
    final current = currentScreen();
    final byScreen = <String?, _FrameCounts>{};
    var latest = -1;
    for (final timing in timings) {
      final frame = timing.frameNumber;
      if (frame > latest) latest = frame;
      final counts =
          byScreen.putIfAbsent(_screenOf(frame, current), _FrameCounts.new);
      counts.total++;
      if (timing.totalSpan.inMicroseconds >= frozenFrameUs) {
        counts.frozen++;
      } else if (timing.buildDuration.inMicroseconds > budget ||
          timing.rasterDuration.inMicroseconds > budget) {
        counts.slow++;
      }
    }
    byScreen.forEach((screen, counts) =>
        _recorder.frames(screen, counts.total, counts.slow, counts.frozen));
    // Timings come in frame order: no frame before [latest] is still to
    // come, so only the screen in effect for it, and what changed since,
    // is kept.
    var superseded = 0;
    while (superseded + 1 < _screens.length &&
        _screens[superseded + 1].frameNumber <= latest) {
      superseded++;
    }
    if (superseded > 0) _screens.removeRange(0, superseded);
  }

  // ---------------------------------------------------------------- hangs

  void _startWatchdog() {
    if (!_started || !reportHangs || _watchdog != null) return;
    _clock
      ..reset()
      ..start();
    _tick(0);
  }

  void _tick(int previousMs) {
    _watchdog = Timer(Duration(milliseconds: watchdogIntervalMs), () {
      final elapsed = _clock.elapsedMilliseconds;
      final blocked = elapsed - previousMs - watchdogIntervalMs;
      if (blocked >= hangThresholdMs && _foreground) {
        _recorder.hang(blocked.toDouble(), currentScreen());
      }
      if (_watchdog != null) _tick(elapsed);
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
    _clock.stop();
  }
}
