import 'package:flutter/widgets.dart';

import '../traceway_mask.dart';

/// How the SDK names a widget for click and hover triggers, with the CSS
/// selector syntax the dashboard already accepts for the browser SDK. Flutter
/// has no DOM, so a selector runs over the element tree under the pointer:
///
/// | Selector | Matches an element whose |
/// |---|---|
/// | `ElevatedButton` | widget is of that type (generic arguments ignored, any case) |
/// | `#checkout` | widget has `Key('checkout')` (a `ValueKey<String>`), or is `Semantics(identifier: 'checkout')` |
/// | `.button` | widget is a `Semantics` with that role: `button`, `link`, `header`, `image`, `textField`, `slider`, `checkbox`, `toggle`, `selected` |
/// | `[key="42"]` | widget's `ValueKey` value reads `42` |
/// | `[identifier="..."]` | `Semantics.identifier` |
/// | `[label="Delete"]` | semantics label or tooltip: its own for a `Semantics`, else the first one below it (an `IconButton`'s tooltip, an `Icon`'s semantic label) |
/// | `[text="Pay"]` | shown text: a `Text`'s own, or the text of the `Text` widgets under it (inputs excluded) |
/// | `[type="_Private"]` | runtime type, for a type that cannot be written as a tag |
///
/// Attribute values support `=`, `~=`, `|=`, `^=`, `$=` and `*=`. A
/// descendant (space), child (`>`), adjacent (`+`) or general (`~`) sibling
/// combinator relates elements of the element tree, where a widget such as
/// `ElevatedButton` sits several elements above the `Text` it shows: prefer
/// the descendant combinator.
///
/// A tap matches a selector when the element under the finger or one of its
/// ancestors does, as a browser click matches its target or an ancestor.
///
/// Type names are minified in `--obfuscate` and web release builds; keys,
/// identifiers, roles, labels and text keep working there.
class WidgetSelector {
  WidgetSelector._(this._compounds, this._combinators);

  final List<_Compound> _compounds;

  /// `_combinators[i]` joins `_compounds[i]` and `_compounds[i + 1]`.
  final List<String> _combinators;

  static final Map<String, WidgetSelector?> _cache = {};

  /// Parses [text], or returns null for a selector this SDK cannot run.
  /// Pseudo-classes, selector lists and escapes are not supported, the same
  /// as for the browser SDK.
  static WidgetSelector? parse(String text) {
    if (_cache.containsKey(text)) return _cache[text];
    WidgetSelector? parsed;
    try {
      parsed = _Parser(text).parse();
    } catch (_) {
      parsed = null;
    }
    if (_cache.length > 200) _cache.clear();
    _cache[text] = parsed;
    return parsed;
  }

  /// Index of the deepest element of [path] the selector matches, or null.
  int? firstMatch(ElementPath path) {
    final budget = _Budget();
    for (var i = 0; i < path.length; i++) {
      if (_matchesNode(path, path[i], i + 1, budget)) return i;
      if (budget.exhausted) return null;
    }
    return null;
  }

  bool matches(ElementPath path) => firstMatch(path) != null;

  /// Like [firstMatch], among the elements [accept] allows.
  int? firstMatchWhere(ElementPath path, bool Function(Element) accept) {
    final budget = _Budget();
    for (var i = 0; i < path.length; i++) {
      if (accept(path[i]) && _matchesNode(path, path[i], i + 1, budget)) {
        return i;
      }
      if (budget.exhausted) return null;
    }
    return null;
  }

  bool _matchesNode(
      ElementPath path, Element element, int parentIndex, _Budget budget) {
    final last = _compounds.length - 1;
    return _compounds[last].test(path, element, budget) &&
        _matchLeft(path, last, element, parentIndex, budget);
  }

  /// [element] matched compound [ci]; checks the compounds to its left.
  /// [parentIndex] is where [element]'s ancestors start in [path].
  bool _matchLeft(ElementPath path, int ci, Element element, int parentIndex,
      _Budget budget) {
    if (ci == 0) return true;
    if (budget.exhausted) return false;
    final left = _compounds[ci - 1];
    switch (_combinators[ci - 1]) {
      case '>':
        if (parentIndex >= path.length) return false;
        final parent = path[parentIndex];
        return left.test(path, parent, budget) &&
            _matchLeft(path, ci - 1, parent, parentIndex + 1, budget);
      case '+':
      case '~':
        if (parentIndex >= path.length) return false;
        final siblings = path.childrenOf(path[parentIndex]);
        final index = siblings.indexOf(element);
        if (index <= 0) return false;
        final adjacent = _combinators[ci - 1] == '+';
        for (var k = index - 1; k >= (adjacent ? index - 1 : 0); k--) {
          final sibling = siblings[k];
          if (left.test(path, sibling, budget) &&
              _matchLeft(path, ci - 1, sibling, parentIndex, budget)) {
            return true;
          }
        }
        return false;
      default:
        for (var j = parentIndex; j < path.length; j++) {
          final ancestor = path[j];
          if (left.test(path, ancestor, budget) &&
              _matchLeft(path, ci - 1, ancestor, j + 1, budget)) {
            return true;
          }
          if (budget.exhausted) return false;
        }
        return false;
    }
  }
}

/// Bounds the work of one match, so a selector with many descendant
/// combinators cannot stall a tap on a deep tree.
class _Budget {
  int remaining = 20000;
  bool get exhausted => remaining <= 0;
}

class _AttributeTest {
  _AttributeTest(this.name, this.op, this.value);
  final String name;
  final String? op;
  final String? value;

  bool test(String? actual) {
    if (actual == null) return false;
    final value = this.value;
    if (op == null || value == null) return true;
    switch (op) {
      case '=':
        return actual == value;
      case '~=':
        return value.isNotEmpty && actual.split(RegExp(r'\s+')).contains(value);
      case '|=':
        return actual == value || actual.startsWith('$value-');
      case '^=':
        return value.isNotEmpty && actual.startsWith(value);
      case r'$=':
        return value.isNotEmpty && actual.endsWith(value);
      case '*=':
        return value.isNotEmpty && actual.contains(value);
    }
    return false;
  }
}

class _Compound {
  String? tag;
  final List<String> ids = [];
  final List<String> classes = [];
  final List<_AttributeTest> attributes = [];

  bool get isEmpty =>
      tag == null && ids.isEmpty && classes.isEmpty && attributes.isEmpty;

  bool test(ElementPath path, Element element, _Budget budget) {
    budget.remaining--;
    final info = path.info(element);
    final tag = this.tag;
    if (tag != null && tag != '*' && info.type.toLowerCase() != tag.toLowerCase()) {
      return false;
    }
    for (final id in ids) {
      if (!info.ids.contains(id)) return false;
    }
    for (final role in classes) {
      if (!info.roles.contains(role)) return false;
    }
    for (final attribute in attributes) {
      if (!attribute.test(info.attribute(attribute.name))) return false;
    }
    return true;
  }
}

class _Parser {
  _Parser(this.text);
  final String text;
  int i = 0;

  static final RegExp _ident = RegExp(r'(?:-?[A-Za-z_]|--)[A-Za-z0-9_-]*');
  static final RegExp _tag = RegExp(r'[A-Za-z][A-Za-z0-9_-]*');

  bool get done => i >= text.length;
  String get char => text[i];

  void skipSpace() {
    while (!done && _isSpace(char)) {
      i++;
    }
  }

  static bool _isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';

  String? readPattern(RegExp pattern) {
    final match = pattern.matchAsPrefix(text, i);
    if (match == null || match.end == i) return null;
    i = match.end;
    return match.group(0);
  }

  WidgetSelector? parse() {
    if (text.length > 256 || RegExp(r'[:,\\]').hasMatch(text)) return null;
    final compounds = <_Compound>[];
    final combinators = <String>[];
    skipSpace();
    while (true) {
      final compound = readCompound();
      if (compound == null) return null;
      compounds.add(compound);
      final before = i;
      skipSpace();
      if (done) break;
      if (char == '>' || char == '+' || char == '~') {
        combinators.add(char);
        i++;
        skipSpace();
      } else if (i > before) {
        combinators.add(' ');
      } else {
        return null;
      }
    }
    if (compounds.isEmpty) return null;
    return WidgetSelector._(compounds, combinators);
  }

  _Compound? readCompound() {
    final compound = _Compound();
    if (!done && char == '*') {
      compound.tag = '*';
      i++;
    } else {
      compound.tag = readPattern(_tag);
    }
    while (!done) {
      final c = char;
      if (c == '#' || c == '.') {
        i++;
        final name = readPattern(_ident);
        if (name == null) return null;
        (c == '#' ? compound.ids : compound.classes).add(name);
      } else if (c == '[') {
        i++;
        final attribute = readAttribute();
        if (attribute == null) return null;
        compound.attributes.add(attribute);
      } else {
        break;
      }
    }
    return compound.isEmpty ? null : compound;
  }

  _AttributeTest? readAttribute() {
    skipSpace();
    final name = readPattern(_ident);
    if (name == null) return null;
    skipSpace();
    if (done) return null;
    if (char == ']') {
      i++;
      return _AttributeTest(name, null, null);
    }
    String op;
    if (char == '=') {
      op = '=';
      i++;
    } else if (i + 1 < text.length &&
        '~|^\$*'.contains(char) &&
        text[i + 1] == '=') {
      op = '$char=';
      i += 2;
    } else {
      return null;
    }
    skipSpace();
    if (done) return null;
    String? value;
    if (char == '"' || char == "'") {
      final quote = char;
      final end = text.indexOf(quote, i + 1);
      if (end < 0) return null;
      value = text.substring(i + 1, end);
      if (value.contains('\n') || value.contains('\r')) return null;
      i = end + 1;
    } else {
      value = readPattern(_ident);
      if (value == null) return null;
    }
    skipSpace();
    if (done || char != ']') return null;
    i++;
    return _AttributeTest(name, op, value);
  }
}

/// What a selector can see of one element.
class ElementInfo {
  ElementInfo._(this.element, this.type, this.ids, this.roles, this._values);

  final Element element;

  /// The widget's runtime type without generic arguments.
  final String type;
  final List<String> ids;
  final Set<String> roles;
  final Map<String, String> _values;
  String? _text;
  bool _textRead = false;

  String? attribute(String name) {
    switch (name) {
      case 'text':
        return text;
      case 'type':
        return type;
      case 'id':
        return ids.isEmpty ? null : ids.first;
      case 'label':
        return label;
    }
    return _values[name];
  }

  String? get key => _values['key'];
  String? get identifier => _values['identifier'];

  String? _label;
  bool _labelRead = false;

  /// The semantics label or tooltip of this element if it is a `Semantics`,
  /// else of the first `Semantics` below it that has one, as long as the
  /// tree does not branch.
  String? get label {
    if (!_labelRead) {
      _labelRead = true;
      _label = _values['label'] ?? _labelBelow(element);
    }
    return _label;
  }

  /// The text this element shows, including masked parts; never the content
  /// of an input field.
  String? get text {
    if (!_textRead) {
      _textRead = true;
      _text = shownText(element, includeMasked: true);
    }
    return _text;
  }

  static ElementInfo of(Element element) {
    final widget = element.widget;
    final ids = <String>[];
    final roles = <String>{};
    final values = <String, String>{};
    final key = widget.key;
    if (key is ValueKey && !isMaskMarker(key)) {
      final value = key.value;
      values['key'] = '$value';
      if (value is String && value.isNotEmpty) ids.add(value);
    }
    if (widget is Semantics) {
      final p = widget.properties;
      final identifier = p.identifier;
      if (identifier != null && identifier.isNotEmpty) {
        values['identifier'] = identifier;
        ids.add(identifier);
      }
      final label = _semanticLabel(widget);
      if (label != null) values['label'] = label;
      if (p.button == true) roles.add('button');
      if (p.link == true) roles.add('link');
      if (p.header == true) roles.add('header');
      if (p.image == true) roles.add('image');
      if (p.textField == true) roles.add('textField');
      if (p.slider == true) roles.add('slider');
      // ignore: deprecated_member_use
      if (p.checked != null) roles.add('checkbox');
      if (p.toggled != null) roles.add('toggle');
      if (p.selected == true) roles.add('selected');
    }
    return ElementInfo._(element, typeName(widget), ids, roles, values);
  }
}

String? _semanticLabel(Semantics widget) {
  final p = widget.properties;
  final label = p.label;
  if (label != null && label.trim().isNotEmpty) return label;
  final tooltip = p.tooltip;
  if (tooltip != null && tooltip.trim().isNotEmpty) return tooltip;
  return null;
}

String? _labelBelow(Element element) {
  Element? current = element;
  for (var depth = 0; depth < 32 && current != null; depth++) {
    Element? only;
    var count = 0;
    current.visitChildElements((child) {
      count++;
      only = child;
    });
    if (count != 1) return null;
    current = only;
    final widget = current!.widget;
    if (isMask(widget)) return null;
    if (widget is Semantics) {
      final label = _semanticLabel(widget);
      if (label != null) return label;
    }
  }
  return null;
}

/// Whether type names were minified (`--obfuscate`, web release): then a
/// selector should not name widget types.
final bool typeNamesMinified = '$RawGestureDetector' != 'RawGestureDetector';

String typeName(Widget widget) {
  final name = widget.runtimeType.toString();
  final generic = name.indexOf('<');
  return generic < 0 ? name : name.substring(0, generic);
}

String? _ownText(Widget widget) => switch (widget) {
      Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(),
      RichText(:final text) => text.toPlainText(),
      _ => null,
    };

/// The text [element] shows: its own for a `Text`, else that of the `Text`
/// widgets under it, at most three, joined by a space. Input fields are
/// skipped, and so are masks unless [includeMasked].
String? shownText(Element element, {required bool includeMasked}) {
  if (element.widget is Icon) return null;
  final own = _ownText(element.widget);
  if (own != null) return _clean(own);
  final parts = <String>[];
  var visited = 0;
  void visit(Element e) {
    if (parts.length >= 3 || visited++ > 400) return;
    final widget = e.widget;
    // An icon is a glyph of its font, not text anyone reads.
    if (widget is EditableText || widget is Icon) return;
    if (!includeMasked && isMask(widget)) return;
    final text = _ownText(widget);
    if (text != null) {
      final cleaned = _clean(text);
      if (cleaned != null) parts.add(cleaned);
      return;
    }
    e.visitChildElements(visit);
  }

  element.visitChildElements(visit);
  return parts.isEmpty ? null : parts.join(' ');
}

String? _clean(String text) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return null;
  return collapsed.length > 256 ? collapsed.substring(0, 256) : collapsed;
}

/// The element under the pointer and its ancestors, deepest first.
class ElementPath {
  ElementPath(this.elements);

  final List<Element> elements;
  final Map<Element, ElementInfo> _info = {};
  final Map<Element, List<Element>> _children = {};

  int get length => elements.length;
  Element operator [](int index) => elements[index];

  ElementInfo info(Element element) =>
      _info.putIfAbsent(element, () => ElementInfo.of(element));

  List<Element> childrenOf(Element element) =>
      _children.putIfAbsent(element, () {
        final out = <Element>[];
        element.visitChildElements(out.add);
        return out;
      });

  bool isMasked(int index) {
    for (var i = index; i < elements.length; i++) {
      if (isMask(elements[i].widget)) return true;
    }
    return false;
  }
}
