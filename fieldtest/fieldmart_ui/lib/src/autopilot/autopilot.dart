import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip, DatePickerDialog;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle, SystemChannels;
import 'package:flutter/widgets.dart';

import '../markers.dart';
import '../probe.dart';
import '../settings.dart';
import 'finder.dart';
import 'input.dart';
import 'journey.dart';

/// Plays the scenario's steps from inside the app (AGENT-3 step 2), as
/// `shared/journey.json` describes them (its `rules` block).
///
/// Every step starts at its `t` after T0 (`FM_READY`) and never earlier; a
/// step more than `rules.lateMs` late makes the run `late`. Steps run on
/// their own once started, so a checkpoint can be taken while a drag holds
/// the finger down; only `waitFor` holds back the steps after it.
///
/// Lines it prints (through [Markers]): `FM_JOURNEY`, one `FM_STEP {...}`
/// per step when it ends, `FM_ACTION {...}` per input (taps, flings, drags,
/// typing, on the device clock, with the touch points), `FM_CP name
/// epochMs`, `FM_BOXES {...}` in evidence runs, `FM_REQ what` for what
/// only the harness can do (a fault, a kill, Home on Android), and
/// `FM_DONE epochMs` at the end.
class Autopilot {
  Autopilot({required this.settings, required this.probe, required this.navigator, required this.t0EpochMs});

  final LaunchSettings settings;
  final Probe probe;
  final GlobalKey<NavigatorState> navigator;
  final int t0EpochMs;

  static const _finder = Finder();
  final _input = Input();
  final _clock = Stopwatch();
  int _offsetMs = 0;
  int _maxLateMs = 0;
  int _failures = 0;
  int _lateLimitMs = 1500;
  int _defaultSettleMs = 400;
  int _revealMs = 900;

  /// The finger a `drag` with `hold` left down, for the `release` step.
  (int, Offset)? _held;

  /// The platform name the journey's `platforms` lists use.
  static String get platform => Platform.isAndroid ? 'flutter-android' : 'flutter-linux';

  /// Milliseconds since T0, on a monotonic clock.
  int get _now => _clock.elapsedMilliseconds + _offsetMs;

  static int get _epoch => DateTime.now().millisecondsSinceEpoch;

  Future<Journey> _journey() async {
    final path = settings.journeyPath;
    final source = path != null && File(path).existsSync()
        ? await File(path).readAsString()
        : await rootBundle.loadString('packages/fieldmart_ui/assets/journey.json');
    return Journey.parse(source);
  }

  Future<void> run() async {
    // T0 is FM_READY; the clock starts at the time already passed since.
    _offsetMs = _epoch - t0EpochMs;
    _clock.start();
    final Journey journey;
    try {
      journey = await _journey();
    } catch (e) {
      Markers.emit('FM_ERROR journey $e');
      return;
    }
    final rules = (journey.raw['rules'] as Map<String, Object?>?) ?? const {};
    _lateLimitMs = (rules['lateMs'] as num?)?.toInt() ?? _lateLimitMs;
    _defaultSettleMs = (rules['defaultSettleMs'] as num?)?.toInt() ?? _defaultSettleMs;
    _revealMs = (rules['revealMs'] as num?)?.toInt() ?? _revealMs;
    final scenario = settings.scenario == null ? null : journey.find(settings.scenario!);
    if (scenario == null) {
      Markers.emit('FM_ERROR no scenario ${settings.scenario} in journey v${journey.version}');
      return;
    }
    final steps = [for (final s in scenario.steps) if (s.platforms == null || s.platforms!.contains(platform)) s];
    Markers.emit('FM_JOURNEY ${jsonEncode({
          'version': journey.version,
          'sharedVersion': journey.raw['sharedVersion'],
          'scenario': scenario.id,
          'steps': steps.length,
          'skippedForPlatform': scenario.steps.length - steps.length,
          'durationMs': scenario.durationMs,
          't0EpochMs': t0EpochMs,
          'clockOffsetMs': _offsetMs,
          'platform': platform,
        })}');

    final running = <Future<void>>[];
    for (final step in steps) {
      final wait = step.t - _now;
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      final startMs = _now;
      final late = startMs - step.t;
      if (late > _maxLateMs) _maxLateMs = late;
      final future = _runStep(step, startMs, late);
      if (step.action == 'waitFor') {
        await future;
      } else {
        running.add(future);
      }
    }
    await Future.wait(running);
    final end = scenario.durationMs - _now;
    if (end > 0) await Future<void>.delayed(Duration(milliseconds: end));
    await probe.write('done');
    Markers.emit('FM_SUMMARY ${jsonEncode({'maxLateMs': _maxLateMs, 'late': _maxLateMs > _lateLimitMs, 'failures': _failures})}');
    Markers.mark('FM_DONE');
  }

  Future<void> _runStep(Step step, int startMs, int late) async {
    String? error;
    Map<String, Object?> extra = const {};
    try {
      extra = await _do(step) ?? const {};
    } catch (e) {
      error = '$e';
    }
    if (error != null) _failures++;
    Markers.json('FM_STEP', jsonEncode({
      'i': step.index,
      't': step.t,
      'do': step.action,
      if (step.id != null) 'id': step.id,
      if (step.name != null) 'name': step.name,
      'startMs': startMs,
      'lateMs': late,
      'endMs': _now,
      'ok': error == null,
      if (error != null) 'error': error,
      ...extra,
    }));
  }

  void _action(Step step, String what, {String? id, required int at, int? end, Offset? point, Offset? to, Map<String, Object?> more = const {}}) {
    Markers.json('FM_ACTION', jsonEncode({
      'step': step.index,
      'do': what,
      if (id != null) 'id': id,
      'epochMs': at,
      if (end != null) 'endEpochMs': end,
      if (point != null) 'x': _r(point.dx),
      if (point != null) 'y': _r(point.dy),
      if (to != null) 'toX': _r(to.dx),
      if (to != null) 'toY': _r(to.dy),
      ...more,
    }));
  }

  static double _r(double v) => (v * 10).roundToDouble() / 10;

  Future<Map<String, Object?>?> _do(Step step) async {
    switch (step.action) {
      case 'waitFor':
        await _waitFor(step.id!, step.timeoutMs);
      case 'tap':
        final revealed = step.reveal ? await _reveal(step) : 0;
        final (at, how) = await _target(step);
        final t = _epoch;
        await _input.tap(at);
        _action(step, 'tap', id: step.id, at: t, end: _epoch, point: at);
        return {'x': _r(at.dx), 'y': _r(at.dy), if (revealed > 0) 'revealDrags': revealed, if (how != null) 'deviation': how};
      case 'longPress':
        final (at, _) = await _target(step);
        final t = _epoch;
        await _input.tap(at, holdMs: step.ms);
        _action(step, 'longPress', id: step.id, at: t, end: _epoch, point: at);
      case 'fling':
        final revealed = step.reveal ? await _reveal(step) : 0;
        await _fling(step);
        return {if (revealed > 0) 'revealDrags': revealed};
      case 'drag':
        final revealed = step.reveal ? await _reveal(step) : 0;
        await _drag(step);
        return {if (revealed > 0) 'revealDrags': revealed};
      case 'release':
        final held = _held;
        if (held == null) throw StateError('release without a held finger');
        _held = null;
        final t = _epoch;
        _input.up(held.$1, held.$2);
        _action(step, 'release', at: t, point: held.$2);
      case 'type':
        return _type(step);
      case 'paste':
        final focusNote = await _focus(step);
        final t = _epoch;
        if (!await _input.insert(step.text ?? '')) throw StateError('no focused field to paste into');
        _action(step, 'paste', id: step.into, at: t, end: _epoch, more: {'into': step.into, 'chars': (step.text ?? '').length});
        return {if (focusNote != null) 'deviation': focusNote};
      case 'key':
        await _key(step.name ?? '');
        _action(step, 'key', at: _epoch, more: {'key': step.name});
      case 'pick':
        return _pick(step);
      case 'idle':
        await Future<void>.delayed(Duration(milliseconds: step.ms));
      case 'background':
        await _background();
      case 'foreground':
        await _foreground();
      case 'checkpoint':
        await _checkpoint(step);
      case 'mark':
        Markers.mark('FM_MARK', extra: step.name);
      case 'fault':
        Markers.emit('FM_REQ fault ${step.mode} ${step.seconds} $_epoch');
      case 'kill':
        Markers.emit('FM_REQ kill $_epoch');
      case 'relaunch':
        Markers.emit('FM_REQ relaunch $_epoch');
      default:
        throw UnsupportedError('step "${step.action}"');
    }
    return null;
  }

  // ---- finding --------------------------------------------------------------

  Future<void> _waitFor(String id, int timeoutMs) async {
    final until = _now + timeoutMs;
    while (_now < until) {
      if (_finder.find(id) != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    throw TimeoutException('waitFor $id', Duration(milliseconds: timeoutMs));
  }

  /// The point to touch: the centre of the element's visible part. An
  /// element that is out of view although the step has no `reveal` is
  /// revealed all the same, and the step says so.
  Future<(Offset, String?)> _target(Step step, {String? id}) async {
    final key = id ?? step.id!;
    final until = _now + 1200;
    String? deviation;
    while (true) {
      final hit = _finder.find(key);
      final ready = hit != null && _fullyVisible(hit.$1, hit.$2) && _finder.hittable(hit.$1, hit.$2.center);
      if (ready) return (hit.$2.center, deviation);
      if (_now >= until || (deviation != null && hit != null)) {
        if (hit != null && _finder.hittable(hit.$1, hit.$2.center)) return (hit.$2.center, deviation ?? 'partly visible');
        throw StateError(hit == null
            ? '$key is not on screen'
            : '$key is covered at its centre ${hit.$2.center}: ${_finder.hitPath(hit.$2.center).join(' < ')}; '
                'its own ${hit.$1.findRenderObject().runtimeType} at ${hit.$2}');
      }
      if (deviation == null && _finder.findAttached(key) != null) {
        if (await _revealId(key, step) > 0) deviation = 'revealed without reveal';
        continue;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  static bool _fullyVisible(Element e, Rect visible) {
    final box = e.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final full = Finder.fullRect(box);
    return visible.width >= full.width - 1 && visible.height >= full.height - 1;
  }

  // ---- reveal: scroll the container with a drag until it shows -------------

  Future<int> _reveal(Step step) => _revealId(step.id!, step);

  /// Makes [id] fully visible the way a person would: the keyboard away if
  /// it covers it, then drags on its scroll container (never a programmatic
  /// scroll) until it is. Returns the number of drags.
  Future<int> _revealId(String id, Step step) async {
    var drags = 0;
    // The journey budgets revealMs; a row far down a lazy list takes more.
    final until = _now + 3 * _revealMs;
    double? lastLead;
    var skip = 0;
    while (_now < until && drags < 12) {
      final hit = _finder.findAttached(id);
      if (hit == null) {
        // Not built yet: a row further down a lazy list. Scroll the list its
        // siblings are in, towards it.
        if (!await _scrollTowardsUnbuilt(id, step)) return drags;
        drags++;
        continue;
      }
      final element = hit.$1;
      final visible = _finder.visibleRect(element);
      if (visible != null && _fullyVisible(element, visible) && _finder.hittable(element, visible.center)) return drags;
      await _hideKeyboardOver(hit.$2);
      final target = _scrollContainer(element);
      if (target == null) return drags;
      final (scrollable, viewport) = target;
      final full = hit.$2;
      final vertical = axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical;
      final lead = vertical ? full.top : full.left;
      final extent = vertical ? full.height : full.width;
      final vpStart = vertical ? viewport.top : viewport.left;
      final vpExtent = vertical ? viewport.height : viewport.width;
      // Bring it to about 40 % of the container, or its start near the top
      // when it is tall.
      final want = extent > 0.55 * vpExtent ? vpStart + 8 : vpStart + 0.4 * vpExtent - extent / 2;
      final reversed = scrollable.axisDirection == AxisDirection.up || scrollable.axisDirection == AxisDirection.left;
      var delta = (lead - want) * (reversed ? -1 : 1); // > 0: the content must move towards the start
      if (delta.abs() < 2) return drags;
      // A drag that moved nothing started on something that kept it: try
      // the next place.
      if (lastLead != null && (lastLead - lead).abs() < 1) skip++;
      lastLead = lead;
      await _dragContainer(scrollable, viewport, vertical, delta, step, id, skip: skip);
      drags++;
    }
    return drags;
  }

  /// The innermost scroll container whose viewport does not hold the whole
  /// of [element], and that viewport's on-screen rect.
  (ScrollableState, Rect)? _scrollContainer(Element element) {
    final box = element.findRenderObject();
    if (box is! RenderBox) return null;
    final full = Finder.fullRect(box);
    (ScrollableState, Rect)? found;
    element.visitAncestorElements((a) {
      if (a is StatefulElement && a.state is ScrollableState) {
        final s = a.state as ScrollableState;
        final ro = s.context.findRenderObject();
        if (ro is RenderBox && ro.hasSize) {
          final vp = Finder.fullRect(ro);
          if (!(vp.contains(full.topLeft + const Offset(0.5, 0.5)) && vp.contains(full.bottomRight - const Offset(0.5, 0.5)))) {
            final shown = _finder.clippedRect(ro, vp);
            if (shown != null) {
              found = (s, shown);
              return false;
            }
          }
        }
      }
      return true;
    });
    return found;
  }

  /// One drag on [scrollable] moving its content by about [delta] logical
  /// pixels, started where no other scroll view of the same axis would take
  /// the gesture, and held still before lifting so it does not fling.
  Future<void> _dragContainer(ScrollableState scrollable, Rect viewport, bool vertical, double delta, Step step, String id,
      {int skip = 0}) async {
    const slop = 20.0; // the touch slop the drag recogniser takes first
    final room = (vertical ? viewport.height : viewport.width) * 0.8;
    final move = math.min(delta.abs() + slop, room) * delta.sign;
    final start = _dragStart(scrollable, viewport, vertical, move, skip: skip);
    final end = vertical ? start + Offset(0, -move) : start + Offset(-move, 0);
    final t = _epoch;
    await _input.path(start, end, 160, holdEndMs: 60);
    _action(step, 'drag', id: id, at: t, end: _epoch, point: start, to: end, more: {'reason': 'reveal'});
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }

  Offset _dragStart(ScrollableState scrollable, Rect viewport, bool vertical, double move, {int skip = 0}) {
    // Scroll views of the same axis inside this one would take the drag.
    final inner = <Rect>[];
    final axis = axisDirectionToAxis(scrollable.axisDirection);
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState && e.state != scrollable) {
        final s = e.state as ScrollableState;
        if (axisDirectionToAxis(s.axisDirection) == axis) {
          final r = _finder.visibleRect(e);
          if (r != null) inner.add(r);
          return;
        }
      }
      e.visitChildElements(visit);
    }

    (scrollable.context as Element).visitChildElements(visit);
    // The finger travels `move` towards the start: begin far enough from it.
    final candidates = <Offset>[];
    for (var f = 0.05; f <= 0.95; f += 0.05) {
      final c = vertical
          ? Offset(viewport.center.dx, move > 0 ? viewport.bottom - viewport.height * f : viewport.top + viewport.height * f)
          : Offset(move > 0 ? viewport.right - viewport.width * f : viewport.left + viewport.width * f, viewport.center.dy);
      final endInside = vertical ? viewport.inflate(-2).contains(c - Offset(0, move)) : viewport.inflate(-2).contains(c - Offset(move, 0));
      if (inner.any((r) => r.contains(c)) || _finder.onTextField(c)) continue;
      candidates.add(c);
      if (endInside && skip-- <= 0) return c;
    }
    return candidates.isNotEmpty ? candidates.first : viewport.center;
  }

  /// A lazy list builds only the rows near the screen: `fm-feed-row-5013`
  /// may not exist yet. Find on-screen elements with the same prefix and a
  /// number, and drag their list towards the wanted one.
  Future<bool> _scrollTowardsUnbuilt(String id, Step step) async {
    final m = RegExp(r'^(.*-)(\d+)$').firstMatch(id);
    if (m == null) return false;
    final prefix = m.group(1)!;
    final wanted = int.parse(m.group(2)!);
    Element? sample;
    var maxSeen = -1;
    var minSeen = 1 << 30;
    _finder.visit((e) {
      final k = e.widget.key;
      if (k is ValueKey && k.value is String && (k.value as String).startsWith(prefix)) {
        final n = int.tryParse((k.value as String).substring(prefix.length));
        if (n != null && _finder.visibleRect(e) != null) {
          sample ??= e;
          maxSeen = math.max(maxSeen, n);
          minSeen = math.min(minSeen, n);
        }
      }
      return true;
    });
    if (sample == null) return false;
    ScrollableState? scrollable;
    sample!.visitAncestorElements((a) {
      if (a is StatefulElement && a.state is ScrollableState) {
        scrollable = a.state as ScrollableState;
        return false;
      }
      return true;
    });
    final s = scrollable;
    if (s == null) return false;
    final ro = s.context.findRenderObject();
    if (ro is! RenderBox) return false;
    final viewport = _finder.clippedRect(ro, Finder.fullRect(ro));
    if (viewport == null) return false;
    final vertical = axisDirectionToAxis(s.axisDirection) == Axis.vertical;
    final forward = wanted > maxSeen;
    final size = vertical ? viewport.height : viewport.width;
    await _dragContainer(s, viewport, vertical, (forward ? 1 : -1) * size * 0.6, step, id);
    return true;
  }

  Future<void> _hideKeyboardOver(Rect rect) async {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    if (inset <= 0) return;
    final screen = _finder.screen;
    if (rect.bottom > screen.height - inset) {
      // What the keyboard's own hide key does.
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  // ---- gestures -------------------------------------------------------------

  /// `dir` is the direction the finger moves: `up` scrolls a list towards
  /// its end, `left` moves a carousel to the next page.
  static Offset _fingerDirection(String dir) => switch (dir) {
        'up' => const Offset(0, -1),
        'down' => const Offset(0, 1),
        'left' => const Offset(-1, 0),
        'right' => const Offset(1, 0),
        _ => throw ArgumentError('fling dir "$dir"'),
      };

  Future<void> _fling(Step step) async {
    final hit = _finder.find(step.id!);
    if (hit == null) throw StateError('${step.id} is not on screen');
    final rect = hit.$2;
    final d = _fingerDirection(step.dir ?? 'up');
    final length = (d.dx != 0 ? rect.width : rect.height) * step.distance;
    final c = rect.center;
    final from = c - d * (length / 2);
    final to = c + d * (length / 2);
    final t = _epoch;
    await _input.path(from, to, step.durationMs);
    _action(step, 'fling', id: step.id, at: t, end: _epoch, point: from, to: to, more: {'dir': step.dir});
  }

  Future<void> _drag(Step step) async {
    final hit = _finder.find(step.id!);
    if (hit == null) throw StateError('${step.id} is not on screen');
    final box = hit.$1.findRenderObject()! as RenderBox;
    final full = Finder.fullRect(box);
    final (fx, fy) = step.point('from') ?? (0.1, 0.5);
    final (tx, ty) = step.point('to') ?? (0.9, 0.5);
    final from = Offset(full.left + full.width * fx, full.top + full.height * fy);
    final to = Offset(full.left + full.width * tx, full.top + full.height * ty);
    final t = _epoch;
    if (step.hold) {
      final pointer = await _input.pressAndMove(from, to, step.durationMs);
      _held = (pointer, to);
      _action(step, 'drag', id: step.id, at: t, end: _epoch, point: from, to: to, more: {'hold': true});
      return;
    }
    // Held still at the end so the release does not fling.
    final hold = step.durationMs > 400 ? 120 : 60;
    await _input.path(from, to, step.durationMs - hold, holdEndMs: hold);
    _action(step, 'drag', id: step.id, at: t, end: _epoch, point: from, to: to);
  }

  // ---- keyboard -------------------------------------------------------------

  /// The focused field must be [Step.into]; when it is not (yet), it is
  /// tapped, which the step reports.
  Future<String?> _focus(Step step) async {
    final into = step.into;
    if (into == null) return null;
    bool focusedInto() {
      final field = _input.focusedField();
      if (field == null) return false;
      var inside = false;
      field.context.visitAncestorElements((a) {
        final k = a.widget.key;
        if (k is ValueKey && k.value == into) {
          inside = true;
          return false;
        }
        return true;
      });
      return inside;
    }

    if (focusedInto()) return null;
    final (at, _) = await _target(step, id: into);
    final t = _epoch;
    await _input.tap(at);
    _action(step, 'tap', id: into, at: t, end: _epoch, point: at, more: {'reason': 'focus'});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return focusedInto() ? 'tapped $into to focus it' : 'could not focus $into';
  }

  Future<Map<String, Object?>?> _type(Step step) async {
    final note = await _focus(step);
    if (_input.focusedField() == null) throw StateError('no focused field to type into');
    final text = step.text ?? '';
    final perCharMs = step.perCharMs;
    final start = _now;
    final t = _epoch;
    for (var i = 0; i < text.length; i++) {
      final due = start + i * perCharMs;
      final wait = due - _now;
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      if (!await _input.insert(text[i])) throw StateError('character $i did not reach the field');
    }
    _action(step, 'type', id: step.into, at: t, end: _epoch, more: {'into': step.into, 'chars': text.length});
    return {if (note != null) 'deviation': note};
  }

  Future<void> _key(String name) async {
    switch (name) {
      case 'enter':
        final field = _input.focusedField();
        if (field != null && field.widget.maxLines != 1) {
          await _input.insert('\n');
        } else if (!await _input.performAction()) {
          throw StateError('no field for enter');
        }
      case 'tab':
        FocusManager.instance.primaryFocus?.nextFocus();
      case 'back' || 'escape':
        await _input.back();
      default:
        throw UnsupportedError('key "$name"');
    }
  }

  // ---- pickers --------------------------------------------------------------

  /// Chooses [Step.value] with the picker's own UI, opening it first when it
  /// is not open: an option in the country list (typed into its search
  /// field when the option is not on screen), or a day in the date picker.
  Future<Map<String, Object?>?> _pick(Step step) async {
    final value = '${step.value}';
    if (_isDate(value)) return _pickDate(step, value);
    (Element, Rect)? option() => _finder.find('fm-picker-option-$value');
    var o = option();
    if (o == null && _finder.find('fm-picker-search') == null) {
      await _tapId(step, step.id!);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      o = option();
    }
    if (o == null && _finder.find('fm-picker-search') != null) {
      await _tapId(step, 'fm-picker-search');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final t = _epoch;
      for (final c in value.split('')) {
        await _input.insert(c);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      _action(step, 'type', id: 'fm-picker-search', at: t, end: _epoch, more: {'into': 'fm-picker-search', 'chars': value.length});
      await Future<void>.delayed(const Duration(milliseconds: 250));
      o = option();
    }
    if (o == null) throw StateError('no option "$value" in the picker');
    await _tapId(step, 'fm-picker-option-$value');
    return {'picked': value};
  }

  Future<void> _tapId(Step step, String id) async {
    final (at, _) = await _target(step, id: id);
    final t = _epoch;
    await _input.tap(at);
    _action(step, 'tap', id: id, at: t, end: _epoch, point: at);
  }

  Future<void> _tapAt(Step step, Offset at, String what) async {
    final t = _epoch;
    await _input.tap(at);
    _action(step, 'tap', id: what, at: t, end: _epoch, point: at);
  }

  static bool _isDate(String v) => RegExp(r'^(\+\d+d|\d{4}-\d{2}-\d{2})$').hasMatch(v);

  bool get _datePickerOpen {
    var open = false;
    _finder.visit((e) {
      if (e.widget is DatePickerDialog) open = true;
      return !open;
    });
    return open;
  }

  Future<Map<String, Object?>?> _pickDate(Step step, String value) async {
    // "+Nd" counts from the run's start on the device clock.
    final start = DateTime.fromMillisecondsSinceEpoch(t0EpochMs);
    final first = DateTime(start.year, start.month, start.day);
    final target = value.startsWith('+')
        ? DateTime(first.year, first.month, first.day + int.parse(value.substring(1, value.length - 1)))
        : DateTime.parse(value);
    if (!_datePickerOpen) {
      await _tapId(step, step.id!);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // The calendar opens on today's month; step forward to the target's.
    final now = DateTime.now();
    var months = (target.year - now.year) * 12 + target.month - now.month;
    while (months-- > 0) {
      final next = _tooltipButton('Next month');
      if (next == null) throw StateError('no next-month button');
      await _tapAt(step, next, 'date-picker-next-month');
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
    final day = _textTarget('${target.day}', exact: true);
    if (day == null) throw StateError('no day ${target.day} in the date picker');
    await _tapAt(step, day.$2.center, 'date-picker-day-${target.day}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final ok = _textTarget('OK', exact: true);
    if (ok == null) throw StateError('no OK in the date picker');
    await _tapAt(step, ok.$2.center, 'date-picker-ok');
    return {'picked': target.toIso8601String().substring(0, 10)};
  }

  /// A visible text equal to (or containing) [text], the last one found
  /// (the topmost route's).
  (Element, Rect)? _textTarget(String text, {bool exact = false}) {
    (Element, Rect)? hit;
    _finder.visit((e) {
      final w = e.widget;
      if (w is RichText) {
        final t = w.text.toPlainText(includeSemanticsLabels: false);
        if (exact ? t == text : t.contains(text)) {
          final r = _finder.visibleRect(e);
          if (r != null) hit = (e, r);
        }
      }
      return true;
    });
    return hit;
  }

  /// An icon button found by its tooltip, as the date picker's arrows are.
  Offset? _tooltipButton(String tooltip) {
    Offset? hit;
    _finder.visit((e) {
      final w = e.widget;
      if (w is Tooltip && w.message == tooltip) {
        final r = _finder.visibleRect(e);
        if (r != null) hit = r.center;
      }
      return true;
    });
    return hit;
  }

  // ---- lifecycle ------------------------------------------------------------

  /// Linux has no app lifecycle of its own: it is simulated the way the
  /// engine reports it. On Android the harness presses Home instead.
  Future<void> _background() async {
    if (Platform.isAndroid) {
      Markers.emit('FM_REQ background $_epoch');
      return;
    }
    Markers.mark('FM_BACKGROUND');
    await _input.lifecycle(AppLifecycleState.paused);
  }

  Future<void> _foreground() async {
    if (Platform.isAndroid) {
      Markers.emit('FM_REQ foreground $_epoch');
      return;
    }
    await _input.lifecycle(AppLifecycleState.resumed);
    Markers.mark('FM_FOREGROUND');
  }

  /// The standard ending on Linux (the harness sends SIGUSR1 at FM_DONE).
  static Future<void> simulatedHome(Probe probe) async {
    Markers.mark('FM_BACKGROUND');
    await Input().lifecycle(AppLifecycleState.paused);
    await probe.write('ending');
  }

  // ---- checkpoints ----------------------------------------------------------

  static const _regions = ['fm-markets-chart', 'fm-home-hero'];

  Future<void> _checkpoint(Step step) async {
    final settle = step.raw['settleMs'] == null ? _defaultSettleMs : step.settleMs;
    await Future<void>.delayed(Duration(milliseconds: settle));
    final at = Markers.mark('FM_CP', extra: step.name);
    if (!settings.evidence) return;
    final boxes = <Map<String, Object?>>[];
    final missing = <String>[];
    for (final s in step.strings('shows')) {
      final b = _finder.textBoxes(s);
      if (b.isEmpty) missing.add(s);
      // The paragraphs that are exactly the text, else those containing it.
      final exact = [for (final x in b) if (x['full'] == s) x];
      boxes.addAll((exact.isNotEmpty ? exact : b).take(3));
    }
    for (final id in step.strings('masked')) {
      final hit = _finder.find(id);
      if (hit != null) boxes.add({'id': id, 'role': 'masked', ..._rect(hit.$2)});
    }
    final list = step.raw['list'] as String?;
    if (list != null) {
      final rows = _rows(list);
      if (rows.isNotEmpty) {
        boxes.add({...rows.first, 'role': 'first-row'});
        boxes.add({...rows.last, 'role': 'last-row'});
      }
    }
    for (final id in _regions) {
      final hit = _finder.find(id);
      if (hit != null) boxes.add({'id': id, 'role': 'region', ..._rect(hit.$2)});
    }
    final hidden = [for (final s in step.strings('hides')) if (_finder.textBoxes(s).isNotEmpty) s];
    Markers.json('FM_BOXES', jsonEncode({
      'name': step.name,
      'epochMs': at,
      'boxes': boxes,
      'missing': missing,
      'hiddenButShown': hidden,
      'during': step.raw['during'],
    }));
  }

  static Map<String, Object> _rect(Rect r) =>
      {'x': _r(r.left), 'y': _r(r.top), 'w': _r(r.width), 'h': _r(r.height)};

  /// The texts fully inside the list's visible part, top to bottom: the
  /// first and last are the first and last visible rows.
  List<Map<String, Object>> _rows(String listId) {
    final list = _finder.find(listId);
    if (list == null) return const [];
    final area = list.$2;
    final out = <Map<String, Object>>[];
    void visit(Element e) {
      if (e is RenderObjectElement && e.renderObject is RenderParagraph) {
        final ro = e.renderObject as RenderParagraph;
        if (ro.attached && ro.hasSize) {
          final text = ro.text.toPlainText(includeSemanticsLabels: false).trim();
          final r = _finder.visibleRect(e);
          final full = Finder.fullRect(ro);
          if (text.length >= 3 && r != null && r.width >= full.width - 1 && r.height >= full.height - 1 && area.contains(full.center)) {
            out.add({'text': text, ..._rect(full)});
          }
        }
      }
      e.visitChildElements(visit);
    }

    list.$1.visitChildElements(visit);
    out.sort((a, b) {
      final dy = (a['y'] as double).compareTo(b['y'] as double);
      return dy != 0 ? dy : (a['x'] as double).compareTo(b['x'] as double);
    });
    return out;
  }
}
