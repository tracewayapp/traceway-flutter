// Drives the wireframe suite app with real pointer events: they go through
// hit testing, the gesture arena and scroll physics like a user's.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
// The suite waits for the recorder: a test harness may look inside.
// ignore: implementation_imports
import 'package:traceway/src/wireframe/wireframe_recorder.dart';
import 'package:traceway/traceway.dart';

/// The height of the soft keyboard the suite shows, 0 while it is down.
///
/// A desktop engine has no soft keyboard, so the suite's binding puts a
/// `MediaQuery` with this bottom inset between the view and the app (see
/// `SuiteBinding` in main.dart): the app lays out above it as above a real
/// keyboard, and the recorder reads the same inset the view would report.
final simulatedKeyboard = ValueNotifier<double>(0);

/// Wraps the app so its view reports [simulatedKeyboard] as its bottom
/// inset.
class SimulatedKeyboard extends StatelessWidget {
  const SimulatedKeyboard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: simulatedKeyboard,
        child: child,
        builder: (context, height, child) {
          final data = MediaQuery.of(context);
          return MediaQuery(
            data: data.copyWith(
                viewInsets: data.viewInsets.copyWith(bottom: height)),
            child: child!,
          );
        },
      );
}

/// Thrown when a step of a scenario cannot be done: what it needed was not
/// on screen.
class DriverError implements Exception {
  DriverError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A pointer that is down until [up].
class Held {
  Held._(this._driver, this.pointer, this.at, this.kind, this.device);

  final Driver _driver;
  final int pointer;
  final PointerDeviceKind kind;
  final int device;
  Offset at;

  /// Moves in [steps] events [stepMs] apart, as a finger would.
  Future<void> moveTo(Offset to, {int steps = 16, int stepMs = 16}) async {
    final from = at;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(Duration(milliseconds: stepMs));
      final next = Offset.lerp(from, to, i / steps)!;
      _driver._send(PointerMoveEvent(
        pointer: pointer,
        device: device,
        position: next,
        delta: next - at,
        kind: kind,
        buttons: kPrimaryButton,
        viewId: _driver._viewId,
        timeStamp: _driver._stamp,
      ));
      at = next;
    }
  }

  Future<void> moveBy(Offset delta, {int steps = 16, int stepMs = 16}) =>
      moveTo(at + delta, steps: steps, stepMs: stepMs);

  Future<void> up() async {
    _driver._send(PointerUpEvent(
      pointer: pointer,
      device: device,
      position: at,
      kind: kind,
      viewId: _driver._viewId,
      timeStamp: _driver._stamp,
    ));
    await Future<void>.delayed(Duration.zero);
  }
}

class Driver {
  Driver({required this.shotKey, required this.navigator, this.shotsDir});

  /// The repaint boundary around the whole app, as the screenshots show it.
  final GlobalKey shotKey;
  final GlobalKey<NavigatorState> navigator;

  /// Where the app's own pictures of the checkpoints are saved.
  final String? shotsDir;

  /// The scenario running, named in its checkpoints.
  String scenario = '';

  var _pointer = 1000;
  final _clock = Stopwatch()..start();
  int _lastFrameUs = 0;
  bool _mouseAdded = false;
  final Set<String> _names = {};

  static const _mouse = 77;

  void install() {
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      _lastFrameUs = _clock.elapsedMicroseconds;
    });
  }

  ui.FlutterView get _view => ui.PlatformDispatcher.instance.implicitView!;
  int get _viewId => _view.viewId;
  Size get screen => _view.physicalSize / _view.devicePixelRatio;
  Duration get _stamp => Duration(microseconds: _clock.elapsedMicroseconds);

  void _send(PointerEvent event) =>
      GestureBinding.instance.handlePointerEvent(event);

  Future<void> pause([int ms = 600]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // ---- finding ------------------------------------------------------------

  /// The painted elements showing [text], last painted last.
  List<Element> findAllText(String text) {
    final found = <Element>[];
    void visit(Element e) {
      final w = e.widget;
      final matches = (w is Text &&
              (w.data == text || w.textSpan?.toPlainText() == text)) ||
          (w is RichText && w.text.toPlainText() == text) ||
          (w is EditableText && w.controller.text == text);
      if (matches) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.attached && ro.hasSize) found.add(e);
      }
      e.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(visit);
    return found;
  }

  Element? findText(String text) {
    final all = findAllText(text);
    return all.isEmpty ? null : all.last;
  }

  bool shows(String text) => findText(text) != null;

  Rect rectOf(Element element) {
    final box = element.renderObject! as RenderBox;
    return MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
  }

  Rect keyRect(GlobalKey key) {
    final element = key.currentContext as Element?;
    if (element == null || element.renderObject is! RenderBox) {
      throw DriverError('$key is not on screen');
    }
    return rectOf(element);
  }

  Offset textCenter(String text) {
    final element = findText(text);
    if (element == null) throw DriverError('no "$text" on screen');
    return rectOf(element).center;
  }

  Offset keyCenter(GlobalKey key) => keyRect(key).center;

  // ---- gestures -----------------------------------------------------------

  Future<Held> press(Offset at,
      {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
    final device = kind == PointerDeviceKind.mouse ? _mouse : 0;
    if (kind == PointerDeviceKind.mouse) await hover(at);
    final held = Held._(this, _pointer++, at, kind, device);
    _send(PointerDownEvent(
      pointer: held.pointer,
      device: device,
      position: at,
      kind: kind,
      buttons: kPrimaryButton,
      viewId: _viewId,
      timeStamp: _stamp,
    ));
    await Future<void>.delayed(Duration.zero);
    return held;
  }

  /// A point a finger can touch: on the screen. A tap anywhere else would
  /// silently hit nothing.
  Offset _onScreen(Offset at, String what) {
    if (at.dx < 0 || at.dy < 0 || at.dx >= screen.width || at.dy >= screen.height) {
      throw DriverError('$what is off the screen at $at');
    }
    return at;
  }

  Future<void> tapAt(Offset at, {int holdMs = 60}) async {
    final held = await press(_onScreen(at, 'the tap'));
    await pause(holdMs);
    await held.up();
  }

  Future<void> tap(String text) async =>
      tapAt(_onScreen(textCenter(text), '"$text"'));
  Future<void> tapKey(GlobalKey key) async =>
      tapAt(_onScreen(keyCenter(key), '$key'));

  Future<void> doubleTapAt(Offset at) async {
    await tapAt(at, holdMs: 40);
    await pause(90);
    await tapAt(at, holdMs: 40);
  }

  Future<void> longPressAt(Offset at, {int ms = 800}) async {
    final held = await press(_onScreen(at, 'the long press'));
    await pause(ms);
    await held.up();
  }

  /// A finger moving from [from] by [delta]; with [hold] it rests before it
  /// lifts, so a scroll stops where the finger did instead of flinging.
  Future<void> drag(Offset from, Offset delta,
      {int steps = 24, int stepMs = 16, bool hold = true}) async {
    final held = await press(_onScreen(from, 'the drag'));
    await held.moveBy(delta, steps: steps, stepMs: stepMs);
    if (hold) await pause(250);
    await held.up();
  }

  /// Drags the page until [text] is in the middle of the screen, up or
  /// down as it lies.
  Future<void> scrollTo(String text, {Offset? from, int tries = 10}) async {
    for (var i = 0; i < tries; i++) {
      final element = findText(text);
      final y = element == null ? null : rectOf(element).center.dy;
      if (y != null && y > 90 && y < screen.height - 90) return;
      final down = y == null || y >= screen.height - 90;
      await drag(from ?? Offset(screen.width / 2, screen.height * 0.6),
          Offset(0, (down ? -1 : 1) * screen.height * 0.3));
      await settle();
    }
    throw DriverError('cannot scroll "$text" onto the screen');
  }

  /// A quick swipe that lifts while moving: scrollables go on ballistically.
  Future<void> fling(Offset from, Offset delta) =>
      drag(from, delta, steps: 6, stepMs: 12, hold: false);

  /// Presses, waits for a long press to start a drag, moves to [to] and
  /// drops there.
  Future<void> dragAndDrop(Offset from, Offset to,
      {bool longPress = true}) async {
    final held = await press(from);
    if (longPress) await pause(700);
    await held.moveTo(to, steps: 24);
    await pause(300);
    await held.up();
  }

  Future<void> _ensureMouse(Offset at) async {
    if (_mouseAdded) return;
    _mouseAdded = true;
    _send(PointerAddedEvent(
        device: _mouse,
        position: at,
        kind: PointerDeviceKind.mouse,
        viewId: _viewId,
        timeStamp: _stamp));
    await Future<void>.delayed(Duration.zero);
  }

  /// Moves the mouse to [at] without a button down.
  Future<void> hover(Offset at) async {
    await _ensureMouse(at);
    _send(PointerHoverEvent(
        device: _mouse,
        position: at,
        kind: PointerDeviceKind.mouse,
        viewId: _viewId,
        timeStamp: _stamp));
    await Future<void>.delayed(Duration.zero);
  }

  /// Turns the mouse wheel over [at], [notches] times by [delta].
  Future<void> wheel(Offset at, Offset delta, {int notches = 1}) async {
    await hover(at);
    for (var i = 0; i < notches; i++) {
      _send(PointerScrollEvent(
          device: _mouse,
          position: at,
          scrollDelta: delta,
          kind: PointerDeviceKind.mouse,
          viewId: _viewId,
          timeStamp: _stamp));
      await pause(60);
    }
  }

  /// Two fingers around [center], from [fromSpan] apart to [toSpan] apart.
  Future<void> pinch(Offset center, double fromSpan, double toSpan,
      {int steps = 20, Offset pan = Offset.zero}) async {
    final a = await press(center - Offset(fromSpan / 2, 0));
    final b = await press(center + Offset(fromSpan / 2, 0));
    for (var i = 1; i <= steps; i++) {
      await pause(16);
      final span = fromSpan + (toSpan - fromSpan) * i / steps;
      final c = center + pan * (i / steps);
      for (final (held, sign) in [(a, -1.0), (b, 1.0)]) {
        final next = c + Offset(sign * span / 2, 0);
        _send(PointerMoveEvent(
            pointer: held.pointer,
            position: next,
            delta: next - held.at,
            kind: PointerDeviceKind.touch,
            buttons: kPrimaryButton,
            viewId: _viewId,
            timeStamp: _stamp));
        held.at = next;
      }
    }
    await pause(200);
    await a.up();
    await b.up();
  }

  /// Types [text] into [controller] a character at a time, as a keyboard
  /// would.
  Future<void> type(TextEditingController controller, String text,
      {int ms = 50}) async {
    for (final c in text.split('')) {
      controller.value = TextEditingValue(
        text: controller.text + c,
        selection: TextSelection.collapsed(offset: controller.text.length + 1),
      );
      await pause(ms);
    }
  }

  /// Waits until no frame was drawn for [quietMs] and none is scheduled,
  /// and the wireframe recorder has taken the screen as it is: no capture
  /// due and no icon or image picture being made.
  Future<bool> settle({int quietMs = 300, int timeoutMs = 6000}) async {
    final deadline = _clock.elapsedMilliseconds + timeoutMs;
    while (_clock.elapsedMilliseconds < deadline) {
      await pause(50);
      final quiet = (_clock.elapsedMicroseconds - _lastFrameUs) ~/ 1000;
      final recorder = TracewayClient.instance?.screenRecorder;
      if (quiet >= quietMs &&
          !SchedulerBinding.instance.hasScheduledFrame &&
          (recorder is! WireframeRecorder || recorder.isSettled)) {
        return true;
      }
    }
    return false;
  }

  /// Shows the soft keyboard [height] logical pixels tall, or hides it
  /// (0), and waits for the screen to settle.
  Future<void> keyboard(double height) async {
    simulatedKeyboard.value = height;
    await pause(300);
    await settle();
  }

  // ---- checkpoints --------------------------------------------------------

  /// The areas on screen now, as [left, top, width, height]; a key whose
  /// widget is not mounted (scrolled away) has none.
  List<List<double>> _rects(List<Object> areas) {
    final rects = <List<double>>[];
    for (final area in areas) {
      final Rect? rect = switch (area) {
        final GlobalKey key => key.currentContext == null ? null : keyRect(key),
        final Rect rect => rect,
        final String text => rectOf(
            findText(text) ?? (throw DriverError('no "$text" to ignore'))),
        _ => throw ArgumentError(area),
      };
      if (rect != null) rects.add(_round(rect));
    }
    return rects;
  }

  static List<double> _round(Rect r) => [
        for (final v in [r.left, r.top, r.width, r.height])
          (v * 10).roundToDouble() / 10,
      ];

  /// The screen is in a state worth comparing: what the app drew is saved
  /// and the moment printed for the harness, which compares the replay at
  /// that moment with it.
  ///
  /// - [shows] / [hides]: text the replayed page must and must not show.
  /// - [ignore]: areas (keys, rects or text) left out of every comparison,
  ///   such as a spinner that never stops.
  /// - [appIgnore]: areas left out only of the comparison with the app's
  ///   picture, for what the app cannot draw itself (a platform view).
  /// - [settle]: false for a screen that keeps animating.
  /// - [maxChange]: the share of pixels the replay may differ from its
  ///   baseline by.
  /// - [minMutations]: how many rrweb mutations must have been recorded
  ///   since the previous checkpoint, e.g. for a running animation.
  Future<void> checkpoint(
    String name, {
    List<String> shows = const [],
    List<String> hides = const [],
    List<Object> ignore = const [],
    List<Object> appIgnore = const [],
    bool settle = true,
    double? maxChange,
    int? minMutations,
  }) async {
    if (!_names.add(name)) throw DriverError('checkpoint $name twice');
    final settled = settle ? await this.settle() : true;
    if (!settle) await pause(400);
    final at = DateTime.now().millisecondsSinceEpoch;
    final dir = shotsDir;
    if (dir != null) {
      final boundary =
          shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
    }
    Traceway.recordAction(category: 'e2e', name: 'checkpoint $name');
    print('E2E_CHECKPOINT ${jsonEncode({
          'name': name,
          'scenario': scenario,
          'at': at,
          'settled': settled,
          'animating': !settle,
          'shows': shows,
          'hides': hides,
          'ignore': _rects(ignore),
          'appIgnore': _rects(appIgnore),
          'maxChange': ?maxChange,
          'minMutations': ?minMutations,
        })}');
    // The screen stays as it is while the harness samples the replay.
    await pause(450);
  }

  /// Text the recording must never contain.
  void secret(String text) => print('E2E_SECRET ${jsonEncode(text)}');

  Future<void> back() async {
    navigator.currentState!.pop();
    await pause(500);
    await settle();
  }

  Future<void> home() async {
    navigator.currentState!.popUntil((route) => route.isFirst);
    await pause(500);
    await settle();
  }
}
