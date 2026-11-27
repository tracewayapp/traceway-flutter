import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'widget_selector.dart';

/// The elements under [position] (global, logical pixels), deepest first.
///
/// Hit testing yields render objects; their elements are found by walking
/// down from the root along the children whose render object was hit, which
/// works in release builds (where `debugCreator` is not available).
ElementPath? elementPathAt(Offset position, {int? viewId}) {
  final binding = WidgetsBinding.instance;
  final root = binding.rootElement;
  if (root == null) return null;
  final view = viewId ?? binding.platformDispatcher.implicitView?.viewId;
  if (view == null) return null;
  final result = HitTestResult();
  binding.hitTestInView(result, position, view);
  final order = <RenderObject, int>{};
  var index = 0;
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderObject) order.putIfAbsent(target, () => index);
    index++;
  }
  if (order.isEmpty) return null;

  // Some render objects hit-test their child without entering the path
  // themselves (a SlideTransition's translation): an element counts as hit
  // when a render object at or a few levels below its own was.
  int? rankOf(RenderObject renderObject) {
    var budget = 256;
    int? visit(RenderObject node, int depth) {
      final direct = order[node];
      if (direct != null) return direct;
      if (depth == 0 || --budget <= 0) return null;
      int? best;
      node.visitChildren((child) {
        final rank = visit(child, depth - 1);
        if (rank != null && (best == null || rank < best!)) best = rank;
      });
      return best;
    }

    return visit(renderObject, 6);
  }

  final chain = <Element>[root];
  var current = root;
  for (var depth = 0; depth < 4096; depth++) {
    Element? best;
    var bestRank = 1 << 30;
    current.visitChildElements((child) {
      RenderObject? renderObject;
      try {
        renderObject = child.renderObject;
      } catch (_) {
        renderObject = null;
      }
      final rank = renderObject == null ? null : rankOf(renderObject);
      if (rank != null && rank < bestRank) {
        best = child;
        bestRank = rank;
      }
    });
    final next = best;
    if (next == null) break;
    chain.add(next);
    current = next;
  }
  return ElementPath(chain.reversed.toList());
}

/// The deepest render object under [position], or null.
RenderObject? hitLeaf(Offset position, {int? viewId}) {
  final binding = WidgetsBinding.instance;
  final view = viewId ?? binding.platformDispatcher.implicitView?.viewId;
  if (view == null) return null;
  final result = HitTestResult();
  binding.hitTestInView(result, position, view);
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderObject) return target;
  }
  return null;
}

/// What a tap is reported as: a selector that matches the tapped widget,
/// usable as is in a click step of a recording trigger, and the parts it is
/// made of.
class TapTarget {
  TapTarget({
    required this.selector,
    required this.tag,
    this.id,
    this.text,
    this.label,
  });

  final String selector;

  /// The widget type of the tapped control, e.g. `ElevatedButton`.
  final String tag;
  final String? id;

  /// Not set for a widget inside a `TracewayPrivacyMask`.
  final String? text;
  final String? label;
}

const Set<Type> _tapRecognizers = {
  TapGestureRecognizer,
  DoubleTapGestureRecognizer,
  LongPressGestureRecognizer,
  TapAndPanGestureRecognizer,
  TapAndHorizontalDragGestureRecognizer,
  SerialTapGestureRecognizer,
};

/// A widget that handles taps itself, without a control around it.
bool _isTapHandler(Widget widget) =>
    (widget is RawGestureDetector &&
        widget.gestures.keys.any(_tapRecognizers.contains)) ||
    widget is EditableText ||
    _selfHandling.contains(typeName(widget));

const Set<String> _selfHandling = {'Slider', 'RangeSlider', 'CupertinoSlider'};

bool _isPrimitive(Widget widget) =>
    widget is GestureDetector ||
    widget is RawGestureDetector ||
    _primitiveNames.contains(typeName(widget));

const Set<String> _primitiveNames = {'InkWell', 'InkResponse'};

/// The controls users name a tap by, e.g. the `ElevatedButton` around the
/// `InkWell` that handled it. By name, so they are found whether the app
/// uses Flutter's Material and Cupertino libraries or the `material_ui` and
/// `cupertino_ui` packages; not in an obfuscated build.
bool _isControl(Widget widget) => _controlNames.contains(typeName(widget));

const Set<String> _controlNames = {
  'ElevatedButton',
  'FilledButton',
  'OutlinedButton',
  'TextButton',
  'IconButton',
  'FloatingActionButton',
  'BackButton',
  'CloseButton',
  'DrawerButton',
  'EndDrawerButton',
  'ListTile',
  'CheckboxListTile',
  'SwitchListTile',
  'RadioListTile',
  'ExpansionTile',
  'Checkbox',
  'Switch',
  'Radio',
  'Slider',
  'RangeSlider',
  'Chip',
  'ActionChip',
  'ChoiceChip',
  'FilterChip',
  'InputChip',
  'RawChip',
  'PopupMenuButton',
  'PopupMenuItem',
  'CheckedPopupMenuItem',
  'DropdownButton',
  'DropdownMenuItem',
  'DropdownButtonFormField',
  'DropdownMenu',
  'MenuItemButton',
  'SubmenuButton',
  'SegmentedButton',
  'ToggleButtons',
  'SearchBar',
  'TextField',
  'TextFormField',
  'Tab',
  'NavigationDestination',
  'BottomNavigationBar',
  'CupertinoButton',
  'CupertinoSwitch',
  'CupertinoCheckbox',
  'CupertinoRadio',
  'CupertinoSlider',
  'CupertinoTextField',
  'CupertinoListTile',
  'CupertinoDialogAction',
  'CupertinoActionSheetAction',
  'CupertinoContextMenuAction',
};

final RegExp _identPattern = RegExp(r'^(?:-?[A-Za-z_]|--)[A-Za-z0-9_-]*$');
final RegExp _tagPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$');
final RegExp _unsafe = RegExp('[:,\\\\"\\r\\n]');

/// A quoted attribute value the dashboard accepts, or null.
String? _quoted(String value) =>
    value.isEmpty || _unsafe.hasMatch(value) ? null : '"$value"';

/// Names the widget a tap landed on. The target is the control that handled
/// it (the `IconButton` rather than the `InkResponse` inside it), or the
/// shown text when nothing handles taps there. The selector prefers, in
/// order: an id (key or Semantics identifier) on or right around the
/// target, its key, its text, its label, and the type alone with the
/// nearest ancestor id as context. It is checked to match [path] before it
/// is returned.
TapTarget? describeTap(ElementPath path, {bool includeText = true}) {
  if (path.length == 0) return null;
  var limit = path.length;
  for (var i = 0; i < path.length; i++) {
    final widget = path[i].widget;
    if (widget is Overlay || widget is Navigator) {
      limit = i;
      break;
    }
  }
  if (limit == 0) limit = path.length;

  var owner = -1;
  for (var i = 0; i < limit; i++) {
    if (_isControl(path[i].widget)) {
      owner = i;
      break;
    }
    if (!_isTapHandler(path[i].widget)) continue;
    // A control above the handler owns it, unless another handler comes
    // first: then this one belongs to something without a known control.
    var outermostPrimitive = i;
    for (var j = i + 1; j < limit && j <= i + 96; j++) {
      final widget = path[j].widget;
      if (_isControl(widget)) {
        owner = j;
        break;
      }
      if (_isTapHandler(widget) && j > i + 1) break;
      if (_isPrimitive(widget) && j <= i + 16) outermostPrimitive = j;
    }
    if (owner < 0) owner = outermostPrimitive;
    break;
  }
  if (owner < 0) {
    for (var i = 0; i < limit; i++) {
      final widget = path[i].widget;
      if (widget is Text || widget is Icon || widget is Image) {
        owner = i;
        break;
      }
      // A RichText built by a Text is named as the Text.
      if (widget is RichText &&
          !(i + 1 < limit && path[i + 1].widget is Text)) {
        owner = i;
        break;
      }
    }
  }
  if (owner < 0) owner = 0;

  final info = path.info(path[owner]);
  final masked = path.isMasked(owner);
  final text =
      includeText && !masked ? shownText(path[owner], includeMasked: false) : null;

  // An id on the target, on a wrapper right above it (the app's own widget
  // with a key) or inside it. Not one under a privacy mask: a key is often
  // made of what the widget shows (`ValueKey(contact.name)`).
  int? idIndex;
  for (final i in [
    owner,
    for (var j = owner + 1; j < limit && j <= owner + 6; j++) j,
    for (var j = owner - 1; j >= 0; j--) j,
  ]) {
    if (!path.isMasked(i) && path.info(path[i]).ids.isNotEmpty) {
      idIndex = i;
      break;
    }
  }

  String tagOf(int i) {
    final type = path.info(path[i]).type;
    if (typeNamesMinified) return '*';
    if (_tagPattern.hasMatch(type)) return type;
    final quoted = _quoted(type);
    return quoted == null ? '*' : '[type=$quoted]';
  }

  final candidates = <String>[];
  String? id;
  String withTag(String tag, String rest) => tag == '*' ? rest : '$tag$rest';
  if (idIndex != null) {
    final idInfo = path.info(path[idIndex]);
    id = idInfo.ids.first;
    final tag = tagOf(idIndex);
    if (_identPattern.hasMatch(id)) {
      candidates.add(withTag(tag, '#$id'));
    } else {
      final name = idInfo.identifier == id ? 'identifier' : 'key';
      final quoted = _quoted(id);
      if (quoted != null) candidates.add(withTag(tag, '[$name=$quoted]'));
    }
  }
  final tag = tagOf(owner);
  final key = masked ? null : info.key;
  if (key != null && key != id) {
    final quoted = _quoted(key);
    if (quoted != null) candidates.add(withTag(tag, '[key=$quoted]'));
  }
  if (text != null && text.length <= 40) {
    final quoted = _quoted(text);
    if (quoted != null) {
      candidates.add(withTag(tag, '[text=$quoted]'));
    } else {
      final prefix = text.split(_unsafe).first.trim();
      if (prefix.length >= 2) candidates.add(withTag(tag, '[text^="$prefix"]'));
    }
  }
  final label = masked ? null : info.label;
  if (label != null && label.length <= 60) {
    final quoted = _quoted(label);
    if (quoted != null) candidates.add(withTag(tag, '[label=$quoted]'));
  }
  for (final role in info.roles) {
    if (tag == '*') candidates.add('.$role');
  }
  for (var j = owner + 1; j < limit; j++) {
    final ancestor = path.info(path[j]);
    if (!path.isMasked(j) &&
        ancestor.ids.isNotEmpty &&
        _identPattern.hasMatch(ancestor.ids.first)) {
      candidates.add('#${ancestor.ids.first} $tag');
      break;
    }
  }
  candidates.add(tag);

  var selector = tag;
  for (final candidate in candidates) {
    if (candidate.length > 256) continue;
    final parsed = WidgetSelector.parse(candidate);
    if (parsed != null && parsed.matches(path)) {
      selector = candidate;
      break;
    }
  }
  return TapTarget(
    selector: selector,
    tag: info.type,
    id: id,
    text: text,
    label: label,
  );
}
