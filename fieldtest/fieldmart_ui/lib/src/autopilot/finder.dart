import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Finds what is on screen right now by walking the element tree: what a
/// person could see, so nothing in a subtree whose tickers are off (a tab
/// that is not selected, a route under an opaque one), offstage, or
/// scrolled out of its viewport.
class Finder {
  const Finder();

  /// The logical size of the view.
  Size get screen {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
    return view.physicalSize / view.devicePixelRatio;
  }

  static bool _hidden(Widget w) =>
      (w is TickerMode && !w.enabled) ||
      (w is Offstage && w.offstage) ||
      (w is Visibility && !w.visible);

  /// Visits every element that is on stage, depth first, top route last.
  void visit(bool Function(Element e) visitor) {
    var stop = false;
    void walk(Element e) {
      if (stop) return;
      if (_hidden(e.widget)) return;
      if (!visitor(e)) {
        stop = true;
        return;
      }
      e.visitChildElements(walk);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(walk);
  }

  /// Every on-stage element keyed `ValueKey(id)`, with its visible rect.
  List<(Element, Rect)> all(String id) {
    final found = <(Element, Rect)>[];
    visit((e) {
      final k = e.widget.key;
      if (k is ValueKey && k.value == id) {
        final r = visibleRect(e);
        if (r != null) found.add((e, r));
      }
      return true;
    });
    return found;
  }

  /// The last on-stage element keyed [id] (the top route's, when two
  /// routes have one) and its visible rect.
  (Element, Rect)? find(String id) {
    final a = all(id);
    return a.isEmpty ? null : a.last;
  }

  /// Like [find], but also an element that exists and is merely scrolled
  /// out of view (it can be scrolled into view), with its full rect.
  (Element, Rect)? findAttached(String id) {
    (Element, Rect)? hit;
    visit((e) {
      final k = e.widget.key;
      if (k is ValueKey && k.value == id) {
        final box = _box(e);
        if (box != null) hit = (e, fullRect(box));
      }
      return true;
    });
    return hit;
  }

  static RenderBox? _box(Element e) {
    final ro = e.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) return ro;
    return null;
  }

  static Rect fullRect(RenderBox box) => MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

  /// The part of [e]'s box that is on screen: clipped by every viewport
  /// and clip above it, and by the screen. Null when nothing shows.
  Rect? visibleRect(Element e) {
    final box = _box(e);
    if (box == null) return null;
    return clippedRect(box, fullRect(box));
  }

  /// [rect] clipped by every ancestor that clips what it paints (scroll
  /// viewports of every kind, clip boxes) and by the screen.
  Rect? clippedRect(RenderObject object, Rect rect) {
    var r = rect.intersect(Offset.zero & screen);
    RenderObject child = object;
    RenderObject? parent = object.parent;
    while (parent != null && r.width > 0 && r.height > 0) {
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        try {
          r = r.intersect(MatrixUtils.transformRect(parent.getTransformTo(null), clip));
        } catch (_) {
          // not in the view's tree any more
        }
      }
      child = parent;
      parent = parent.parent;
    }
    if (r.width <= 0.5 || r.height <= 0.5) return null;
    return r;
  }

  /// Whether a touch at [point] reaches [e]: nothing on top of it (a bar, a
  /// sheet, a pinned header) takes it first.
  /// Whether a touch at [point] would land on a text field: on desktop a
  /// drag there selects text instead of scrolling.
  bool onTextField(Offset point) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, point, view.viewId);
    return result.path.any((e) => e.target is RenderEditable);
  }

  /// The render objects a touch at [point] reaches, top first (for errors).
  List<String> hitPath(Offset point, {int max = 6}) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, point, view.viewId);
    return [for (final e in result.path.take(max)) '${e.target.runtimeType}'];
  }

  bool hittable(Element e, Offset point) {
    final ro = e.findRenderObject();
    if (ro == null) return false;
    final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, point, view.viewId);
    for (final entry in result.path) {
      final t = entry.target;
      if (t is! RenderObject) continue;
      for (RenderObject? n = t; n != null; n = n.parent) {
        if (identical(n, ro)) return true;
      }
    }
    return false;
  }

  /// The boxes of visible text containing [needle], in logical pixels.
  List<Map<String, Object>> textBoxes(String needle) {
    final out = <Map<String, Object>>[];
    visit((e) {
      if (e is RenderObjectElement) {
        final ro = e.renderObject;
        String? text;
        if (ro is RenderParagraph) {
          text = ro.text.toPlainText(includeSemanticsLabels: false);
        } else if (ro is RenderEditable) {
          text = ro.text?.toPlainText(includeSemanticsLabels: false);
        }
        if (text != null && text.contains(needle) && ro is RenderBox && ro.hasSize && ro.attached) {
          final full = fullRect(ro);
          final r = clippedRect(ro, full);
          if (r != null) {
            out.add({
              'text': needle,
              'x': _round(full.left),
              'y': _round(full.top),
              'w': _round(full.width),
              'h': _round(full.height),
              'clipped': r != full,
              'full': text.length > 200 ? '${text.substring(0, 200)}…' : text,
            });
          }
        }
      }
      return true;
    });
    return out;
  }

  static double _round(double v) => (v * 10).roundToDouble() / 10;
}
