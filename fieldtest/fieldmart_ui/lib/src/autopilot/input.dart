import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Real input, delivered where the engine delivers it: pointer events into
/// `GestureBinding.handlePointerEvent` (hit testing, the gesture arena,
/// scroll physics), and keyboard text as `flutter/textinput` messages to
/// the focused field, one character at a time.
class Input {
  static int _nextPointer = 5000;
  static const int _touchDevice = 1;
  static const int _frameUs = 16000;

  int get _viewId => WidgetsBinding.instance.platformDispatcher.implicitView!.viewId;

  static Duration get _stamp => Duration(microseconds: Timeline.now);

  void _send(PointerEvent event) => GestureBinding.instance.handlePointerEvent(event);

  Future<void> _sleepUs(int us) => Future<void>.delayed(Duration(microseconds: us));

  /// Finger down at [at]; returns the pointer id.
  int down(Offset at) {
    final pointer = _nextPointer++;
    _send(PointerAddedEvent(
        pointer: pointer, device: _touchDevice, position: at, kind: PointerDeviceKind.touch, viewId: _viewId, timeStamp: _stamp));
    _send(PointerDownEvent(
        pointer: pointer,
        device: _touchDevice,
        position: at,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        viewId: _viewId,
        timeStamp: _stamp));
    return pointer;
  }

  void move(int pointer, Offset from, Offset to) => _send(PointerMoveEvent(
      pointer: pointer,
      device: _touchDevice,
      position: to,
      delta: to - from,
      kind: PointerDeviceKind.touch,
      buttons: kPrimaryButton,
      viewId: _viewId,
      timeStamp: _stamp));

  void up(int pointer, Offset at) {
    _send(PointerUpEvent(
        pointer: pointer, device: _touchDevice, position: at, kind: PointerDeviceKind.touch, viewId: _viewId, timeStamp: _stamp));
    _send(PointerRemovedEvent(
        pointer: pointer, device: _touchDevice, position: at, kind: PointerDeviceKind.touch, viewId: _viewId, timeStamp: _stamp));
  }

  Future<void> tap(Offset at, {int holdMs = 50}) async {
    final p = down(at);
    await Future<void>.delayed(Duration(milliseconds: holdMs));
    up(p, at);
  }

  /// Puts a finger down at [from] and moves it to [to] in [durationMs], a
  /// move every frame, leaving it down. Returns the pointer.
  Future<int> pressAndMove(Offset from, Offset to, int durationMs) async {
    final p = down(from);
    final steps = (durationMs * 1000 / _frameUs).ceil().clamp(2, 100000);
    final clock = Stopwatch()..start();
    var at = from;
    for (var i = 1; i <= steps; i++) {
      // On the clock, not on the sum of the sleeps: late steps catch up.
      final due = i * durationMs * 1000 ~/ steps;
      final wait = due - clock.elapsedMicroseconds;
      if (wait > 0) await _sleepUs(wait);
      final next = Offset.lerp(from, to, i / steps)!;
      move(p, at, next);
      at = next;
    }
    return p;
  }

  /// [pressAndMove], then lifts the finger: right away for a fling (the
  /// scroll view keeps the speed), or after [holdEndMs] still, so the
  /// release does not fling.
  Future<void> path(Offset from, Offset to, int durationMs, {int holdEndMs = 0}) async {
    final p = await pressAndMove(from, to, durationMs);
    if (holdEndMs > 0) await Future<void>.delayed(Duration(milliseconds: holdEndMs));
    up(p, to);
  }

  // ---- keyboard ---------------------------------------------------------------

  static const _codec = JSONMethodCodec();
  int _client = 0;

  /// The field that has keyboard focus.
  EditableTextState? focusedField() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }
    return context.findAncestorStateOfType<EditableTextState>();
  }

  Future<void> _deliver(String channel, ByteData data) {
    final done = Completer<void>();
    // The engine's own path into the framework's handlers.
    ui.channelBuffers.push(channel, data, (ByteData? _) {
      if (!done.isCompleted) done.complete();
    });
    return done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  Future<void> _editingState(int client, TextEditingValue value) => _deliver(
      'flutter/textinput',
      _codec.encodeMethodCall(MethodCall('TextInputClient.updateEditingState', [client, value.toJSON()])));

  /// Sends [value] to the focused field as the engine would. The framework
  /// ignores a message for another client id; ids are not public, so the
  /// current one is found once per focus by trying ids after the last.
  Future<bool> sendEditingValue(TextEditingValue value) async {
    final field = focusedField();
    if (field == null) return false;
    bool landed() => field.textEditingValue.text == value.text;
    if (_client > 0) {
      await _editingState(_client, value);
      if (landed()) return true;
    }
    for (var id = _client + 1; id <= _client + 64; id++) {
      await _editingState(id, value);
      if (landed()) {
        _client = id;
        return true;
      }
    }
    for (var id = 1; id < _client; id++) {
      await _editingState(id, value);
      if (landed()) {
        _client = id;
        return true;
      }
    }
    return false;
  }

  /// Inserts [text] at the focused field's selection, replacing it.
  Future<bool> insert(String text) async {
    final field = focusedField();
    if (field == null) return false;
    final v = field.textEditingValue;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final next = v.text.replaceRange(sel.start, sel.end, text);
    return sendEditingValue(TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    ));
  }

  /// The keyboard's action key (done, search, ...) for the focused field.
  Future<bool> performAction() async {
    final field = focusedField();
    if (field == null || _client == 0) return false;
    final action = field.widget.textInputAction ?? TextInputAction.done;
    await _deliver('flutter/textinput',
        _codec.encodeMethodCall(MethodCall('TextInputClient.performAction', [_client, action.toString()])));
    return true;
  }

  /// The system back button: `popRoute` on `flutter/navigation`.
  Future<void> back() =>
      _deliver('flutter/navigation', _codec.encodeMethodCall(const MethodCall('popRoute')));

  /// An app lifecycle change as the engine reports it on `flutter/lifecycle`;
  /// the framework walks the states in between.
  Future<void> lifecycle(AppLifecycleState state) =>
      _deliver('flutter/lifecycle', const StringCodec().encodeMessage(state.toString())!);
}
