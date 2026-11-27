import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../guarded.dart';
import '../replay/json_size.dart';
import '../replay/replay_source.dart';
import '../traceway_image_policy.dart';
import 'vnode.dart';
import 'wireframe_capture.dart';
import 'wireframe_css.dart';
import 'wireframe_diff.dart';
import 'wireframe_glyphs.dart';
import 'wireframe_images.dart';
import 'wireframe_roots.dart';

/// Records the screen as a wireframe in rrweb's format instead of as
/// video: the app's widget tree becomes an HTML document, and what changes
/// from frame to frame becomes rrweb mutations. The dashboard replays it
/// with the same player as a browser session.
///
/// The screen is captured after frames the app draws, at most [fps] times a
/// second, and not at all while nothing changes on screen. Frames share the
/// nodes that did not change, so the ring of the last [maxFrames] frames
/// stays small. A clip is assembled when it is asked for: a full snapshot
/// of the screen as it was when the clip starts, then the mutations and
/// touches up to its end, so every clip and segment plays on its own.
class WireframeRecorder with WidgetsBindingObserver implements ReplaySource {
  WireframeRecorder({
    required this.rootKey,
    required int maxFrames,
    this.fps = 15,
    this.debug = false,
    this.screenName,
    DateTime Function()? now,
  })  : _roots = WireframeRoots(rootKey),
        _maxFrames = maxFrames < 2 ? 2 : maxFrames,
        _now = now ?? DateTime.now {
    // An icon's or an image's picture that becomes ready changes the
    // screen.
    _capture.glyphs = _glyphs..onReady = () => _schedule(immediately: true);
    _capture
      ..images = _images
      ..imagePolicy = TracewayImagePolicy.wifi;
    _images.onReady = () => _schedule(immediately: true);
  }

  final WireframeGlyphs _glyphs = WireframeGlyphs();
  final WireframeImages _images = WireframeImages();

  /// The key of the widget whose subtree is recorded.
  final GlobalKey rootKey;
  final WireframeRoots _roots;
  final int fps;
  final bool debug;

  /// The route on top, shown as the replay's address.
  final String? Function()? screenName;
  final DateTime Function() _now;
  final int _maxFrames;
  final WireframeCapture _capture = WireframeCapture();
  final List<WireframeFrame> _frames = [];
  final List<WireframePointer> _pointers = [];
  static const int _maxPointers = 4000;
  static const int _moveIntervalMs = 50;

  /// rrweb sends the positions a pointer moved through together, in one
  /// event about every 500 ms (its `mousemoveCallback`), not one event per
  /// position: the per-session budget counts events.
  static const int _moveBatchMs = 500;

  late final int _intervalMs = 1000 ~/ (fps < 1 ? 1 : fps);
  bool _running = false;
  bool _paused = false;
  bool _armed = false;
  Timer? _timer;
  int _lastCaptureMs = 0;

  /// The last widget error logged, so it is logged once.
  String? _lastErrorMessage;

  /// Time spent walking the tree, for the debug log.
  final Stopwatch _captureTime = Stopwatch();
  int _captures = 0;
  final Map<int, int> _lastMoveMs = {};

  /// Masks what is typed into text fields, as rrweb's `maskAllInputs`
  /// does. On by default; remote settings can switch it off
  /// (`replay.maskAllInputs`).
  bool get maskAllInputs => _capture.maskAllInputs;
  set maskAllInputs(bool value) {
    if (value == _capture.maskAllInputs) return;
    _capture.maskAllInputs = value;
    _capture.reset();
    if (value) {
      // The frames held show what was typed: none of them may go up now.
      // The screen is captured again at once, masked.
      _frames.clear();
      _timer?.cancel();
      _timer = null;
      _schedule(immediately: true);
    }
  }

  /// What the replay may show of the app's images: the effective
  /// `replay.images` policy, `wifi` until the client sets it (see
  /// [WireframeCapture.imagePolicy]). Whether a frame inlines pictures is
  /// decided when it is captured, so a picture recorded on Wi-Fi stays in
  /// its clip; `off` drops the frames held, which may show images, and
  /// takes the screen again at once.
  TracewayImagePolicy get imagePolicy => _capture.imagePolicy;
  set imagePolicy(TracewayImagePolicy value) {
    if (value == _capture.imagePolicy) return;
    _capture.imagePolicy = value;
    _capture.reset();
    _timer?.cancel();
    _timer = null;
    // The frames held show the images: none of them may go up now.
    if (value == TracewayImagePolicy.off) _frames.clear();
    _schedule(immediately: true);
  }

  /// Whether images are drawn at all (the policy is not `off`).
  bool get networkImages => imagePolicy != TracewayImagePolicy.off;

  /// Whether the device is on an unmetered network, for the `wifi` policy;
  /// metered until the client says otherwise.
  set unmetered(bool Function() value) => _capture.unmetered = value;

  /// The session's replay image budget.
  set imageBudget(ImageBudget? value) => _images.budget = value;

  /// Whether nothing is left to do for the screen as it is: no capture is
  /// due and no glyph or image picture is being made. The wireframe suite
  /// waits for it before a checkpoint.
  bool get isSettled => _timer == null && !_images.busy && !_glyphs.busy;

  /// Number of distinct screens held; never more than the ring's capacity.
  @visibleForTesting
  int get bufferedFrameCount => _frames.length;

  /// Number of pointers whose last move is remembered, for the throttle.
  @visibleForTesting
  int get trackedPointerCount => _lastMoveMs.length;

  @override
  bool get isRunning => _running;

  @override
  void start() {
    if (_running) return;
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    _paused = _away(WidgetsBinding.instance.lifecycleState);
    _arm();
    _schedule(immediately: true);
    if (debug) {
      print('Traceway: wireframe recorder started (up to ${fps}fps)');
    }
  }

  @override
  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _pushBlank();
  }

  @override
  void clearBuffer() {
    _frames.clear();
    _pointers.clear();
    _capture.reset();
  }

  /// Whether the app cannot be seen. An inactive app (a desktop window
  /// without focus, an iOS app under the control center) is still on
  /// screen and keeps being recorded.
  static bool _away(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      guarded('wireframe lifecycle', () {
        final paused = _away(state);
        if (paused == _paused) return;
        _paused = paused;
        if (paused) {
          _timer?.cancel();
          _timer = null;
          _pushBlank();
        } else {
          _schedule(immediately: true);
        }
      });

  // ---- capturing ----------------------------------------------------------

  /// Runs after every frame the app draws while recording.
  void _arm() {
    if (_armed || !_running) return;
    _armed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _armed = false;
      if (!_running) return;
      guarded('wireframe schedule', _schedule);
      _arm();
    });
  }

  void _schedule({bool immediately = false}) {
    if (_timer != null || !_running || _paused) return;
    final now = _now().millisecondsSinceEpoch;
    final wait = immediately ? 0 : _lastCaptureMs + _intervalMs - now;
    _timer = Timer(Duration(milliseconds: wait < 0 ? 0 : wait),
        () => guarded('wireframe capture', _captureNow));
  }

  void _captureNow() {
    _timer = null;
    if (!_running || _paused) return;
    final root = _roots.root;
    if (root == null) return;
    final now = _now();
    _lastCaptureMs = now.millisecondsSinceEpoch;
    try {
      _captureTime.start();
      final frame = _capture.capture(root, now, href: screenName?.call());
      _captureTime.stop();
      _captures++;
      if (frame != null) _push(frame);
      final error = _capture.lastError;
      if (error != null) {
        _capture.lastError = null;
        final message = '$error';
        if (debug && message != _lastErrorMessage) {
          print('Traceway: wireframe left out a widget: $message');
        }
        _lastErrorMessage = message;
      }
    } catch (e) {
      _captureTime.stop();
      // A widget the walk does not expect costs this frame, never the app.
      _capture.reset();
      if (debug) print('Traceway: wireframe capture error: $e');
    }
  }

  void _push(WireframeFrame frame) {
    final last = _frames.isEmpty ? null : _frames.last;
    if (last != null &&
        identical(last.screen, frame.screen) &&
        last.size == frame.size) {
      return;
    }
    _frames.add(frame);
    if (_frames.length > _maxFrames) _frames.removeAt(0);
  }

  /// Nothing is on screen from now on: the app went to the background or
  /// the recorder stopped.
  void _pushBlank() {
    if (_frames.isEmpty || _frames.last.screen == null) return;
    final last = _frames.last;
    _frames.add(WireframeFrame(null, last.size, _now(), href: last.href));
    if (_frames.length > _maxFrames) _frames.removeAt(0);
  }

  // ---- pointers -----------------------------------------------------------

  void pointerDown(int pointer, Offset position, {required bool touch}) {
    // A mouse hovers with the id of its last press, after the press came
    // up, and each press has a new one: forgotten here, or one id would be
    // kept per click. A pointer still down only loses its throttle once.
    _lastMoveMs.clear();
    _addPointer(
        WireframePointer(WireframePointerKind.down, position, _now(), touch));
  }

  void pointerMove(int pointer, Offset position, {required bool touch}) {
    final now = _now();
    final ms = now.millisecondsSinceEpoch;
    final last = _lastMoveMs[pointer];
    if (last != null && ms - last < _moveIntervalMs) return;
    _lastMoveMs[pointer] = ms;
    _addPointer(
        WireframePointer(WireframePointerKind.move, position, now, touch));
  }

  void pointerUp(int pointer, Offset position,
      {required bool touch, required bool tap}) {
    _lastMoveMs.remove(pointer);
    _addPointer(WireframePointer(
        tap ? WireframePointerKind.tap : WireframePointerKind.up,
        position,
        _now(),
        touch));
  }

  void pointerCancel(int pointer, Offset position, {required bool touch}) {
    _lastMoveMs.remove(pointer);
    _addPointer(
        WireframePointer(WireframePointerKind.cancel, position, _now(), touch));
  }

  void _addPointer(WireframePointer pointer) {
    if (!_running || _paused) return;
    _pointers.add(pointer);
    if (_pointers.length > _maxPointers) {
      _pointers.removeRange(0, _pointers.length - _maxPointers);
    }
  }

  // ---- clips --------------------------------------------------------------

  @override
  bool hasFrames({DateTime? since, DateTime? until}) {
    if (since != null && until != null && !since.isBefore(until)) return false;
    if (since != null) {
      final at = _frameAtIn(_frames, since);
      if (at >= 0 && _frames[at].screen != null) return true;
    }
    return _frames.any((f) =>
        f.screen != null &&
        (since == null || !f.timestamp.isBefore(since)) &&
        (until == null || f.timestamp.isBefore(until)));
  }

  @override
  Future<SessionRecordingPayload?> captureRecording(
    String clipId, {
    DateTime? since,
    DateTime? until,
  }) async {
    final frames = List.of(_frames);
    final end = until ?? _now();
    var index = since == null ? -1 : _frameAtIn(frames, since);
    DateTime start;
    if (index >= 0 && frames[index].screen != null) {
      start = since!;
    } else {
      index = -1;
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        if (f.screen == null) continue;
        if (since != null && f.timestamp.isBefore(since)) continue;
        if (!f.timestamp.isBefore(end)) break;
        index = i;
        break;
      }
      if (index < 0) return null;
      start = frames[index].timestamp;
    }

    final screenEvents = <Map<String, Object?>>[];
    void meta(WireframeFrame frame, DateTime at) => screenEvents.add({
          'type': 4,
          'data': {
            'href': frame.href ?? '/',
            'width': frame.size.width.round(),
            'height': frame.size.height.round(),
          },
          'timestamp': at.millisecondsSinceEpoch,
        });
    void snapshot(WireframeFrame frame, DateTime at) {
      meta(frame, at);
      screenEvents.add({
        'type': 2,
        'data': {
          'node': serializeDocument(frame.screen ?? _awayScreen(frame.size)),
          'initialOffset': const {'left': 0, 'top': 0},
        },
        'timestamp': at.millisecondsSinceEpoch,
      });
    }

    var previous = frames[index];
    snapshot(previous, start);
    for (var i = index + 1; i < frames.length; i++) {
      final frame = frames[i];
      if (!frame.timestamp.isBefore(end)) break;
      final before = previous.screen, after = frame.screen;
      // A Meta event only ever comes with a full snapshot: rrweb's player
      // seeks from the last Meta before the time it seeks to and takes the
      // snapshot after it as the screen, so a Meta alone (to change the
      // address on a route change) would drop the screen the next mutations
      // apply to. Another route is a mutation; the address stays the clip's
      // first, which is the one the dashboard shows.
      if (before == null || after == null || previous.size != frame.size) {
        snapshot(frame, frame.timestamp);
      } else {
        final mutation = diffScreens(before, after);
        if (mutation != null) {
          screenEvents.add({
            'type': 3,
            'data': mutation,
            'timestamp': frame.timestamp.millisecondsSinceEpoch,
          });
        }
      }
      previous = frame;
    }

    final pointerEvents = <Map<String, Object?>>[];
    final moves = <WireframePointer>[];
    void flushMoves() {
      if (moves.isEmpty) return;
      pointerEvents.add(_moveEvent(moves));
      moves.clear();
    }

    for (final p in _pointers) {
      if (p.timestamp.isBefore(start) || !p.timestamp.isBefore(end)) continue;
      if (p.kind != WireframePointerKind.move) {
        // A press or release stays between the moves before and after it.
        flushMoves();
        pointerEvents.addAll(_pointerEvents(p));
        continue;
      }
      if (moves.isNotEmpty &&
          (moves.first.touch != p.touch ||
              p.timestamp.difference(moves.first.timestamp).inMilliseconds >
                  _moveBatchMs)) {
        flushMoves();
      }
      moves.add(p);
    }
    flushMoves();
    final events = _merge(screenEvents, pointerEvents);
    final endMs = end.millisecondsSinceEpoch;
    if ((events.last['timestamp'] as int) < endMs) {
      // The screen stayed as it was until the clip ends: the replay's
      // timeline runs to then.
      events.add({
        'type': 5,
        'data': {'tag': 'traceway.end', 'payload': const {}},
        'timestamp': endMs,
      });
    }
    // Measured, not encoded: a clip with pictures carries their base64,
    // and the upload encodes it once, off the UI isolate.
    final bytes = approxJsonLength(events);
    if (debug) {
      final average = _captures == 0
          ? 0
          : _captureTime.elapsedMicroseconds / _captures / 1000;
      print('Traceway: wireframe clip of ${events.length} events, '
          '${bytes ~/ 1024}KB, ${(endMs - start.millisecondsSinceEpoch) / 1000}s '
          '(${average.toStringAsFixed(2)} ms per capture over $_captures)');
    }
    return SessionRecordingPayload(
      clipId: clipId,
      events: events,
      startedAt: start,
      endedAt: end,
      approxBytes: bytes,
    );
  }

  /// The index of the frame showing at [at]: the last one taken at or
  /// before it, or -1.
  static int _frameAtIn(List<WireframeFrame> frames, DateTime at) {
    for (var i = frames.length - 1; i >= 0; i--) {
      if (!frames[i].timestamp.isAfter(at)) return i;
    }
    return -1;
  }

  static List<Map<String, Object?>> _merge(
      List<Map<String, Object?>> a, List<Map<String, Object?>> b) {
    final out = <Map<String, Object?>>[];
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      if (j >= b.length ||
          (i < a.length && (a[i]['timestamp'] as int) <= (b[j]['timestamp'] as int))) {
        out.add(a[i++]);
      } else {
        out.add(b[j++]);
      }
    }
    return out;
  }

  static List<Map<String, Object?>> _pointerEvents(WireframePointer p) {
    final ms = p.timestamp.millisecondsSinceEpoch;
    final x = p.position.dx.round(), y = p.position.dy.round();
    Map<String, Object?> interaction(int type) => {
          'type': 3,
          'data': {
            'source': 2,
            'type': type,
            'id': screenNodeId,
            'x': x,
            'y': y,
            'pointerType': p.touch ? 2 : 0,
          },
          'timestamp': ms,
        };
    switch (p.kind) {
      case WireframePointerKind.down:
        return [interaction(p.touch ? 7 : 1)];
      case WireframePointerKind.move:
        return [_moveEvent([p])];
      case WireframePointerKind.up:
        return [interaction(p.touch ? 9 : 0)];
      case WireframePointerKind.tap:
        return [interaction(p.touch ? 9 : 0), interaction(2)];
      case WireframePointerKind.cancel:
        return [interaction(p.touch ? 10 : 0)];
    }
  }

  /// One rrweb MouseMove or TouchMove event for [moves], all of one kind,
  /// as rrweb records it: stamped when the last position was reached, each
  /// position with its time before then as a negative `timeOffset`. The
  /// replayer moves the pointer to each at the event's time plus its offset.
  static Map<String, Object?> _moveEvent(List<WireframePointer> moves) {
    final ms = moves.last.timestamp.millisecondsSinceEpoch;
    return {
      'type': 3,
      'data': {
        'source': moves.first.touch ? 6 : 1,
        'positions': [
          for (final p in moves)
            {
              'x': p.position.dx.round(),
              'y': p.position.dy.round(),
              'id': screenNodeId,
              'timeOffset': p.timestamp.millisecondsSinceEpoch - ms,
            },
        ],
      },
      'timestamp': ms,
    };
  }

  /// What the replay shows while the app is in the background.
  static VNode _awayScreen(Size size) => VNode.element(
        screenNodeId,
        'div',
        {
          'id': 'tw',
          'style': 'width:${size.width.round()}px;height:${size.height.round()}px;'
              'font-family:${wireframeFontStack(defaultTargetPlatform)};'
              'background:#1e1e1e',
        },
        [
          VNode.element(
            awayScreenTextBoxId,
            'div',
            const {
              'style': 'left:0;top:45%;width:100%;text-align:center;'
                  'color:#9e9e9e;font-size:14px',
            },
            [VNode.text(awayScreenTextId, 'App in the background')],
          ),
        ],
      );
}

/// What a pointer did. A tap is an up that the `Traceway` widget saw
/// within the touch slop and before the long-press timeout; it also
/// becomes rrweb's Click.
enum WireframePointerKind { down, move, up, tap, cancel }

/// One entry of the recorder's pointer log, in logical pixels of the
/// screen. Moves are already throttled to one per 50 ms per pointer.
class WireframePointer {
  WireframePointer(this.kind, this.position, this.timestamp, this.touch);
  final WireframePointerKind kind;
  final Offset position;
  final DateTime timestamp;

  /// A finger or stylus (rrweb touch events) rather than a mouse.
  final bool touch;
}
