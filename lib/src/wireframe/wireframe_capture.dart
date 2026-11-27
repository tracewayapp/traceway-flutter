/// Wireframe capture: what the app paints, as an HTML document rrweb plays.
///
/// Pipeline: roots → walk → convert → VNodes (stable ids, shared unchanged
/// subtrees) → CSS → diff → rrweb events.
///
/// - **roots**: `WireframeRoots` gives the element the walk starts from,
///   the `Traceway` widget's repaint boundary; dialogs and overlays are
///   inside it.
/// - **walk**: [WireframeCapture] visits the element tree in paint order.
/// - **convert**: each render object that draws becomes nodes, by kind:
///   `text`, `field`, `image`, `toggle`, `slider`, `progress`, `segmented`,
///   `nativePlaceholder`, `customDrawing`, `group`, `scroll`, and Flutter's
///   own `table` and `circle`.
/// - **VNodes**: an element keeps its node ids from frame to frame, and an
///   unchanged subtree is the previous frame's very object (`vnode.dart`).
/// - **CSS**: geometry and paint inline on each node, the shared rules in
///   [wireframeCss] (`wireframe_css.dart`).
/// - **diff**: `diffScreens` turns two frames into an rrweb mutation
///   (`wireframe_diff.dart`).
/// - **rrweb events**: `WireframeRecorder` assembles Meta, FullSnapshot,
///   mutations and pointer events into clips.
library;

import 'dart:math' as math;

// The SDK supports Flutter releases from before material_ui and
// cupertino_ui existed.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoCheckbox,
        CupertinoRadio,
        CupertinoSlider,
        CupertinoSwitch;
// ignore: deprecated_member_use
import 'package:flutter/material.dart'
    show
        Checkbox,
        CircularProgressIndicator,
        ColorScheme,
        InputBorder,
        InputDecoration,
        InputDecorator,
        LinearProgressIndicator,
        OutlineInputBorder,
        ProgressIndicator,
        Radio,
        RangeSlider,
        SegmentedButton,
        SegmentedButtonTheme,
        Slider,
        Switch,
        Theme,
        UnderlineInputBorder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, mergeSort;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../traceway_mask_mode.dart';
import '../traceway_privacy_mask.dart';
import 'vnode.dart';
import 'wireframe_css.dart';
import 'wireframe_glyphs.dart';

/// One captured screen: the wireframe DOM of what the app painted.
class WireframeFrame {
  WireframeFrame(this.screen, this.size, this.timestamp, {this.href});

  /// The element holding the screen ([screenNodeId]); null while nothing is
  /// on screen (the app is in the background, the recorder stopped).
  final VNode? screen;

  /// Logical size of the screen.
  final Size size;
  final DateTime timestamp;

  /// The route on top when the frame was taken, the replay's address.
  final String? href;
}

/// Turns what a subtree of the app paints into a wireframe DOM, by walking
/// its elements and reading each render object's geometry and paint
/// properties.
///
/// The element tree is walked rather than the render tree because some of
/// what a wireframe needs is only on widgets: the color of a [ColoredBox],
/// the image provider of an [Image], which toggle a painter belongs to, and
/// where a [TracewayPrivacyMask] starts. Geometry comes from the render
/// objects: each one's paint transform is composed with its parent's, which
/// covers translations, scrolling, scaling and rotation alike.
///
/// Only render objects that paint something, clip, or fade get a DOM node;
/// the many layout-only render objects in between are folded into the
/// transforms. Nodes nest the way they paint, so CSS clips, rounds and fades
/// their contents like Flutter does.
class WireframeCapture {
  /// Text in editable fields is masked, as rrweb's `maskAllInputs` does.
  bool maskAllInputs = true;

  /// Load images that came from the network in the replay, by their URL:
  /// the browser that plays it fetches them. Off (`replay.images = off`),
  /// every image is a placeholder (`.im`). Images from memory, files and
  /// assets are always placeholders: nothing of theirs is uploaded.
  bool networkImages = true;

  /// Draws the shapes of icons; without it every icon is a square.
  WireframeGlyphs? glyphs;

  /// The last error a render object raised while it was captured; it and
  /// its subtree were left out of that frame.
  Object? lastError;

  /// How long a glyph's style stays on the page after its icon left the
  /// screen, so an icon that comes back does not add it again.
  static const glyphLinger = Duration(seconds: 10);

  final Set<Glyph> _shownGlyphs = {};
  final Expando<Map<int, int>> _ids = Expando('traceway wireframe ids');
  int _nextId = firstCapturedNodeId;
  Map<int, VNode> _previous = {};
  Map<int, VNode> _current = {};
  final Matrix4 _scratch = Matrix4.identity();

  late RenderObject _root;
  late List<VNode> _deferred;
  late Rect _screenRect;

  /// The wireframe of what [rootElement] paints, or null when it is not
  /// laid out.
  WireframeFrame? capture(Element rootElement, DateTime timestamp,
      {String? href}) {
    final root = rootElement.renderObject;
    if (root is! RenderBox || !root.attached || !root.hasSize) return null;
    _root = root;
    _deferred = [];
    _current = {};
    _shownGlyphs.clear();
    _screenRect = Offset.zero & root.size;
    final children = <VNode>[];
    try {
      _visit(
        rootElement,
        _Scope(
          out: children,
          origin: _Affine.identity,
          ro: null,
          transform: _Affine.identity,
          clip: _screenRect,
        ),
      );
    } catch (_) {
      _current = {};
      rethrow;
    }
    children.addAll(_deferred);
    children.insertAll(0, _glyphStyles(timestamp));
    final screen = _intern(VNode.element(
      screenNodeId,
      'div',
      {
        'id': 'tw',
        'style': 'width:${px(root.size.width)};height:${px(root.size.height)};'
            'font-family:${wireframeFontStack(defaultTargetPlatform)}',
      },
      children,
    ));
    _previous = _current;
    _current = {};
    return WireframeFrame(screen, root.size, timestamp, href: href);
  }

  /// Forgets the previous frame, so the next capture shares nothing with it.
  void reset() => _previous = {};

  /// A style node for each drawn glyph shown lately, first on the screen
  /// (a style draws nothing), in a stable order.
  List<VNode> _glyphStyles(DateTime timestamp) {
    final glyphs = this.glyphs;
    if (glyphs == null) return const [];
    for (final glyph in _shownGlyphs) {
      glyph.lastShown = timestamp;
    }
    final styles = <VNode>[];
    for (final glyph in glyphs.all) {
      final css = glyph.css;
      final shown = glyph.lastShown;
      if (css == null ||
          shown == null ||
          timestamp.difference(shown) > glyphLinger) {
        continue;
      }
      styles.add(_intern(VNode.element(
          glyph.styleId ??= _nextId++, 'style', {'_cssText': css}, const [])));
    }
    styles.sort((a, b) => a.id.compareTo(b.id));
    return styles;
  }

  /// The id of the node playing [role] for [element]; the same in every
  /// frame while the element lives.
  int _id(Element element, [int role = 0]) {
    final ids = _ids[element] ??= <int, int>{};
    return ids[role] ??= _nextId++;
  }

  VNode _intern(VNode node) {
    final previous = _previous[node.id];
    final kept = previous != null && previous.sameAs(node) ? previous : node;
    _current[node.id] = kept;
    return kept;
  }

  VNode _element(int id, String style, List<VNode> children,
      {String? cls, String tag = 'div', Map<String, String>? extra}) {
    return _intern(VNode.element(
      id,
      tag,
      {
        if (cls != null) 'class': cls,
        ...?extra,
        'style': style,
      },
      children,
    ));
  }

  VNode _textNode(int id, String text) => _intern(VNode.text(id, text));

  // ---- walk -----------------------------------------------------------------

  void _visit(Element element, _Scope scope) {
    final widget = element.widget;
    var s = scope;
    if (widget is TracewayPrivacyMask) {
      final mode = widget.mode;
      if (mode is TracewayMaskBlank) {
        _replace(element, s, (box, geometry) {
          return _element(
              _id(element), '$geometry background:${cssColor(mode.color)};', const []);
        });
        return;
      }
      s = s.copy(maskText: true, blockImages: true);
    } else if (widget is Icon) {
      s = s.copy(hint: const _IconHint());
    } else if (widget is Image) {
      s = s.copy(image: widget.image);
    } else if (widget is InputDecorator) {
      s = s.copy(
          hint: _DecoratorHint(
              widget.decoration, widget.isFocused, element, s.out, s.out.length));
    } else if (_toggleKind(widget) case final kind?) {
      s = s.copy(hint: _ToggleHint(kind, widget, element));
    } else if (widget is ProgressIndicator ||
        widget is CupertinoActivityIndicator) {
      _replace(element, s, (box, geometry) => _progress(element, widget, box, geometry));
      return;
    } else if (widget is Slider ||
        widget is RangeSlider ||
        widget is CupertinoSlider) {
      _replace(element, s, (box, geometry) => _slider(element, widget, box, geometry));
      return;
    } else if (widget is SegmentedButton) {
      s = s.copy(hint: _SegmentedHint(widget, element));
    } else if (_viewType(widget) case final viewType?) {
      s = s.copy(hint: _NativeHint(nativeViewLabel(viewType)));
    }

    if (element is RenderObjectElement) {
      try {
        _renderObject(element, s);
      } catch (error) {
        // A widget this does not expect costs its own node, not the frame.
        lastError = error;
      }
    } else {
      element.visitChildElements((child) => _visit(child, s));
    }
  }

  void _visitChildren(Element element, _Scope scope) {
    final ro = element is RenderObjectElement ? element.renderObject : null;
    if (ro is RenderViewportBase) {
      _visitInPaintOrder(element, scope, ro);
      return;
    }
    element.visitChildElements((child) => _visit(child, scope));
  }

  /// A viewport paints its slivers in an order of its own: a pinned header
  /// listed first paints last, above what scrolls under it. DOM order is
  /// paint order, so the children's nodes are placed in that order.
  void _visitInPaintOrder(
      Element element, _Scope scope, RenderViewportBase viewport) {
    final parts = <(RenderObject?, List<VNode>)>[];
    element.visitChildElements((child) {
      final out = <VNode>[];
      _visit(child, scope.copy(out: out));
      if (out.isNotEmpty) parts.add((child.renderObject, out));
    });
    if (parts.length > 1) {
      final List<RenderSliver> order;
      try {
        // ignore: invalid_use_of_protected_member
        order = viewport.childrenInPaintOrder.toList();
      } catch (_) {
        for (final part in parts) {
          scope.out.addAll(part.$2);
        }
        return;
      }
      int rank((RenderObject?, List<VNode>) part) {
        final ro = part.$1;
        return ro is RenderSliver ? order.indexOf(ro) : -1;
      }

      mergeSort(parts, compare: (a, b) => rank(a).compareTo(rank(b)));
    }
    for (final part in parts) {
      scope.out.addAll(part.$2);
    }
  }

  void _renderObject(RenderObjectElement element, _Scope scope) {
    final ro = element.renderObject;
    if (!ro.attached) return;
    var s = scope;
    final _Affine t;
    Matrix4? projective;
    final parent = ro.parent;
    if (identical(ro, _root)) {
      t = _Affine.identity;
    } else if (parent != null && identical(parent, s.ro)) {
      if (!_paints(parent, ro)) return;
      final local = _localTransform(parent, ro);
      if (local == null) return;
      t = s.transform.then(local);
      projective = _projective;
    } else {
      // Painted somewhere else than under its element's parent: an
      // OverlayPortal's child paints in the Overlay, above the page. It is
      // placed on the screen itself, on top.
      if (parent == null || !_paints(parent, ro)) return;
      final deferred = <VNode>[];
      _renderObject(
        element,
        _Scope(
          out: deferred,
          origin: _Affine.identity,
          ro: parent,
          transform: _parentTransform(parent),
          clip: _screenRect,
          maskText: s.maskText,
          blockImages: s.blockImages,
          hint: s.hint,
          image: s.image,
        ),
      );
      _deferred.addAll(deferred);
      return;
    }
    if (t.isDegenerate) return;

    if (ro.isRepaintBoundary && !identical(ro, _root)) {
      // A repaint boundary that was left out of the last frame (a route
      // under an opaque one, an inactive tab) has no layer in the tree.
      // ignore: invalid_use_of_protected_member
      final layer = ro.layer;
      if (layer == null || !layer.attached) return;
    }
    if (projective != null && parent != null) {
      _projected(element, parent, t, projective, s);
      return;
    }
    _paint(element, t, s);
  }

  /// A render object its parent paints with perspective (a 3D card, the
  /// items of a wheel): a node of its own carries the transform as
  /// `matrix3d`, and the render object is drawn inside it in its own
  /// coordinates, exactly. Where it lands on the screen is only
  /// approximated, so nothing under it is culled.
  void _projected(RenderObjectElement element, RenderObject parent, _Affine t,
      Matrix4 local, _Scope s) {
    final ro = element.renderObject;
    final inside = <VNode>[];
    _paint(element, t, s.copy(out: inside, origin: t, clip: Rect.largest));
    if (inside.isEmpty) return;
    // The parent's place in the DOM parent, then the child's in the parent.
    final rel = s.transform.relativeTo(s.origin);
    final m = Matrix4(rel.a, rel.b, 0, 0, rel.c, rel.d, 0, 0, 0, 0, 1, 0,
        rel.tx, rel.ty, 0, 1)
      ..multiply(local);
    final size = ro is RenderBox && ro.hasSize ? ro.size : Size.zero;
    var style = 'transform:matrix3d(${m.storage.map(_num6).join(',')});'
        'transform-origin:0 0;width:${px(size.width)};height:${px(size.height)};';
    // A wheel dims the items off its center.
    if (parent is RenderListWheelViewport &&
        parent.overAndUnderCenterOpacity < 1) {
      final data = ro.parentData;
      final offset = parent.offset;
      if (data is ListWheelParentData &&
          offset.hasPixels &&
          data.index != (offset.pixels / parent.itemExtent).round()) {
        style += 'opacity:${num3(parent.overAndUnderCenterOpacity)};';
      }
    }
    // The element's other nodes are inside, and none has a negative role.
    s.out.add(_element(_id(element, _projectedRole), style, inside));
  }

  /// The role of the node [_projected] wraps an element's own nodes in.
  /// Every other role is zero or more, some of them counting up without
  /// bound (a paragraph's runs, a table's rows), so a negative one is never
  /// taken.
  static const int _projectedRole = -1;

  /// A backdrop's filter. From Flutter 3.41 it is a `filterConfig`, and
  /// the `filter` getter throws for one set that way (Cupertino's dialogs);
  /// before, only `filter` exists.
  static Object? _backdrop(RenderBackdropFilter ro) {
    try {
      return (ro as dynamic).filterConfig;
    } catch (_) {
      try {
        // ignore: deprecated_member_use
        return ro.filter;
      } catch (_) {
        return null;
      }
    }
  }

  static String _num6(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    var text = v.toStringAsFixed(6);
    while (text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    return text == '-0' ? '0' : text;
  }

  /// What [element]'s render object draws, placed by [t] in [s].
  void _paint(RenderObjectElement element, _Affine t, _Scope s) {
    final ro = element.renderObject;
    if (ro is RenderSliver) {
      final geometry = ro.geometry;
      if (geometry == null || !geometry.visible) return;
      _visitChildren(element, s.copy(ro: ro, transform: t));
      return;
    }
    if (ro is! RenderBox || !ro.hasSize) return;
    final size = ro.size;
    final bounds = t.transformRect(Offset.zero & size);
    if (!size.isEmpty && !bounds.overlaps(s.clip)) return;

    final widget = element.widget;
    final inner = s.copy(ro: ro, transform: t);

    if (ro is PlatformViewRenderBox ||
        ro is RenderDarwinPlatformView ||
        ro is TextureBox) {
      _nativePlaceholder(element, ro, t, s);
      return;
    }
    if (ro is RenderParagraph) {
      _text(element, ro, t, s);
      return;
    }
    if (ro is RenderEditable) {
      _field(element, ro, t, s);
      return;
    }
    if (ro is RenderImage) {
      _image(element, ro, t, s);
      return;
    }
    if (ro is RenderCustomPaint && _customDrawing(element, ro, t, s)) return;
    if (ro is RenderTable) {
      _table(element, ro, t, s);
      return;
    }

    var style = '';
    var clips = false;
    var group = false;
    String? cls;
    if (widget is ColoredBox) {
      group = true;
      if (!isTransparent(widget.color)) {
        style = 'background-color:${cssColor(widget.color)};';
      }
    } else if (ro is RenderDecoratedBox) {
      final direction = ro.configuration.textDirection ?? TextDirection.ltr;
      final decoration = ro.decoration;
      if (decoration is BoxDecoration &&
          decoration.shape == BoxShape.circle &&
          (size.width - size.height).abs() > 0.5) {
        _circle(element, ro, decoration, direction, t, inner, s);
        return;
      }
      final images = _showsImages(s);
      final css = decorationCss(decoration, size, direction, images: images);
      final placeholder =
          decorationImagePlaceholder(decoration, images: images) ? 'im' : null;
      if (ro.position == DecorationPosition.foreground) {
        final children = <VNode>[];
        _visitChildren(element, inner.copy(out: children, origin: t));
        children.add(_element(
            _id(element, 1), 'width:100%;height:100%;$css', const [],
            cls: placeholder));
        s.out.add(_element(_id(element), _geometry(s.origin, t, size), children));
        return;
      }
      group = true;
      style = css;
      cls = placeholder;
    } else if (ro is RenderPhysicalModel) {
      group = true;
      clips = ro.clipBehavior != Clip.none;
      style = _fill(ro.color) +
          (ro.shape == BoxShape.circle
              ? 'border-radius:50%;'
              : radiusCss(ro.borderRadius ?? BorderRadius.zero)) +
          shadowCss(elevationShadows(ro.elevation, ro.shadowColor));
    } else if (ro is RenderPhysicalShape) {
      group = true;
      clips = ro.clipBehavior != Clip.none;
      final clipper = ro.clipper;
      final shape = clipper is ShapeBorderClipper ? clipper.shape : null;
      final direction = clipper is ShapeBorderClipper
          ? clipper.textDirection ?? TextDirection.ltr
          : TextDirection.ltr;
      style = _fill(ro.color) +
          shapeRadiusCss(shape, size, direction) +
          shadowCss([
            ...elevationShadows(ro.elevation, ro.shadowColor),
            ...shapeOutline(shape),
          ]);
    } else if (ro is RenderClipRect) {
      clips = group = ro.clipBehavior != Clip.none;
    } else if (ro is RenderClipRRect) {
      clips = group = ro.clipBehavior != Clip.none;
      if (group) {
        style = radiusCss(ro.borderRadius.resolve(ro.textDirection));
      }
    } else if (ro is RenderClipOval) {
      clips = group = ro.clipBehavior != Clip.none;
      if (group) style = 'border-radius:50%;';
    } else if (ro is RenderClipPath) {
      // A transparent Material clips with its shape and paints its outline.
      final clipper = ro.clipper;
      clips = ro.clipBehavior != Clip.none;
      if (clipper is ShapeBorderClipper) {
        group = true;
        style = shapeRadiusCss(
                clipper.shape, size, clipper.textDirection ?? TextDirection.ltr) +
            shadowCss(shapeOutline(clipper.shape));
      } else {
        group = clips;
        if (clips && clipper != null) {
          try {
            style = clipPathCss(clipper.getClip(size));
          } catch (_) {
            // A clipper that fails here clips nothing in the replay.
          }
        }
      }
    } else if (ro is RenderOpacity) {
      if (ro.opacity < 1) {
        group = true;
        style = 'opacity:${num3(ro.opacity)};';
      }
    } else if (ro is RenderAnimatedOpacity) {
      // Always a node, so the fade ending does not move its subtree.
      group = true;
      final opacity = ro.opacity.value;
      if (opacity < 1) style = 'opacity:${num3(opacity)};';
    } else if (widget is ImageFiltered) {
      final blur = widget.enabled ? blurCss(widget.imageFilter) : null;
      if (blur != null) {
        group = true;
        style = 'filter:$blur;';
      }
    } else if (widget is ColorFiltered) {
      final filter = colorFilterCss(widget.colorFilter);
      if (filter != null) {
        group = true;
        style = 'filter:$filter;';
      }
    } else if (ro is RenderBackdropFilter) {
      // Blurs what was painted under it, like CSS's backdrop filter.
      final blur = ro.enabled ? blurCss(_backdrop(ro)) : null;
      if (blur != null) {
        group = true;
        style = 'backdrop-filter:$blur;-webkit-backdrop-filter:$blur;';
      }
    } else if (ro is RenderAbstractViewport &&
        ro is! RenderListWheelViewport) {
      _scroll(element, t, s, bounds);
      return;
    }
    _group(element, t, s, bounds,
        style: group ? style : null, clips: clips, cls: cls);
  }

  /// A render object with no look of its own. One that paints, clips or
  /// fades its children ([style] not null) is a container node holding
  /// them. One that only lays them out is folded: its children go into the
  /// parent's node, placed by the transforms, so the many layout-only
  /// render objects cost no node.
  void _group(RenderObjectElement element, _Affine t, _Scope s, Rect bounds,
      {String? style, bool clips = false, String? cls}) {
    final ro = element.renderObject as RenderBox;
    final inner = s.copy(ro: ro, transform: t);
    if (style == null) {
      // The render object that lays out a SegmentedButton's segments:
      // the first under it with a child for each.
      final hint = s.hint;
      final segmented = hint is _SegmentedHint &&
              !hint.drawn &&
              ro is ContainerRenderObjectMixin<RenderBox,
                  ContainerBoxParentData<RenderBox>> &&
              (ro as ContainerRenderObjectMixin).childCount ==
                  hint.widget.segments.length
          ? hint
          : null;
      segmented?.drawn = true;
      _visitChildren(element, inner);
      if (segmented != null) {
        _segmented(
            element,
            segmented,
            ro as ContainerRenderObjectMixin<RenderBox,
                ContainerBoxParentData<RenderBox>>,
            t,
            s);
      }
      return;
    }
    final children = <VNode>[];
    _visitChildren(
      element,
      inner.copy(
          out: children,
          origin: t,
          clip: clips ? s.clip.intersect(bounds) : s.clip),
    );
    s.out.add(_element(
        _id(element),
        _geometry(s.origin, t, ro.size) + style + (clips ? 'overflow:hidden;' : ''),
        children,
        cls: cls));
  }

  /// A scrolling viewport: a node that clips, holding a content node
  /// shifted by the scroll offset along the axis. The children keep their
  /// place in the content node while it scrolls, so a scroll changes one
  /// attribute per frame instead of every child's.
  void _scroll(
      RenderObjectElement element, _Affine t, _Scope s, Rect bounds) {
    final ro = element.renderObject as RenderBox;
    final viewport = ro as RenderAbstractViewport;
    final clips =
        viewport is! RenderViewportBase || viewport.clipBehavior != Clip.none;
    final shift = _scrollShift(element, viewport);
    if (shift == null) {
      _group(element, t, s, bounds, style: '', clips: clips);
      return;
    }
    final content = t.translate(shift.dx, shift.dy);
    final contentChildren = <VNode>[];
    _visitChildren(
      element,
      s.copy(
          out: contentChildren,
          ro: ro,
          transform: t,
          origin: content,
          clip: clips ? s.clip.intersect(bounds) : s.clip),
    );
    final offset = content.relativeTo(t);
    final contentNode = _element(
      _id(element, 1),
      'left:${px(offset.tx)};top:${px(offset.ty)};',
      contentChildren,
    );
    s.out.add(_element(
        _id(element),
        _geometry(s.origin, t, ro.size) + (clips ? 'overflow:hidden;' : ''),
        [contentNode]));
  }


  /// A circle decoration on a box that is not square: Flutter draws a
  /// circle as wide as the box is short, in its middle, where CSS would
  /// round the box into an ellipse. The circle is a node of its own.
  void _circle(RenderObjectElement element, RenderDecoratedBox ro,
      BoxDecoration decoration, TextDirection direction, _Affine t,
      _Scope inner, _Scope s) {
    final size = ro.size;
    final side = math.min(size.width, size.height);
    final images = _showsImages(s);
    final circle = _element(
      _id(element, 2),
      'left:${px((size.width - side) / 2)};top:${px((size.height - side) / 2)};'
          'width:${px(side)};height:${px(side)};'
          '${decorationCss(decoration, Size.square(side), direction, images: images)}',
      const [],
      cls: decorationImagePlaceholder(decoration, images: images) ? 'im' : null,
    );
    final children = <VNode>[];
    final foreground = ro.position == DecorationPosition.foreground;
    if (!foreground) children.add(circle);
    _visitChildren(element, inner.copy(out: children, origin: t));
    if (foreground) children.add(circle);
    s.out.add(_element(_id(element), _geometry(s.origin, t, size), children));
  }

  /// A SegmentedButton paints its outline and the lines between its
  /// segments itself, over them: as nodes after them.
  void _segmented(
      Element element,
      _SegmentedHint hint,
      ContainerRenderObjectMixin<RenderBox, ContainerBoxParentData<RenderBox>>
          ro,
      _Affine t,
      _Scope s) {
    final segments = <Rect>[];
    var child = ro.firstChild;
    while (child != null) {
      final data = child.parentData! as ContainerBoxParentData<RenderBox>;
      if (child.hasSize) segments.add(data.offset & child.size);
      child = ro.childAfter(child);
    }
    if (segments.isEmpty || ro is! RenderBox) return;
    // The render object is private, its border and the padding around it
    // for the tap target are not: read them, or else what the theme says.
    var padding = 0.0;
    OutlinedBorder? border;
    try {
      final dynamic any = ro;
      padding = (any.tapTargetVerticalPadding as num).toDouble();
      border = any.enabledBorder as OutlinedBorder;
    } catch (_) {
      // An older Flutter: the theme's border, around the whole box.
    }
    final size = (ro as RenderBox).size;
    final rect = Rect.fromLTWH(0, padding / 2, size.width, size.height - padding);
    final widget = hint.widget;
    final theme = SegmentedButtonTheme.of(hint.element).style;
    final side = border?.side ??
        widget.style?.side?.resolve(const {}) ??
        theme?.side?.resolve(const {}) ??
        BorderSide(
            color: _colors(hint.element)?.outline ?? const Color(0xFF79747E));
    final shape = border ??
        widget.style?.shape?.resolve(const {}) ??
        theme?.shape?.resolve(const {}) ??
        const StadiumBorder();
    final direction = Directionality.maybeOf(element) ?? TextDirection.ltr;
    final color = cssColor(side.color);
    s.out.add(_element(
      _id(element, 3),
      _geometry(s.origin, t.translate(rect.left, rect.top), rect.size) +
          shapeRadiusCss(shape, rect.size, direction) +
          shadowCss(outlineShadows(side)),
      const [],
    ));
    for (var i = 1; i < segments.length; i++) {
      final horizontal = (segments[i].top - segments[0].top).abs() < 0.5;
      final at = horizontal
          ? Rect.fromLTWH(
              direction == TextDirection.ltr
                  ? segments[i].left - side.width / 2
                  : segments[i].right - side.width / 2,
              rect.top,
              side.width,
              rect.height)
          : Rect.fromLTWH(rect.left, segments[i].top - side.width / 2,
              rect.width, side.width);
      s.out.add(_element(
        _id(element, 10 + i),
        '${_geometry(s.origin, t.translate(at.left, at.top), at.size)}'
            'background-color:$color;',
        const [],
      ));
    }
  }

  // ---- leaves ---------------------------------------------------------------

  void _text(
      Element element, RenderParagraph ro, _Affine t, _Scope s) {
    final size = ro.size;
    final span = ro.text;
    final base = (span is TextSpan ? span.style : null) ?? const TextStyle();
    final geometry = _geometry(s.origin, t, size);
    if (s.hint is _IconHint || _isIconFont(base.fontFamily)) {
      final color = base.color ?? const Color(0xFF000000);
      final glyph = glyphs?.lookup(span, size, ro.textDirection, ro.textScaler);
      if (glyph != null) _shownGlyphs.add(glyph);
      s.out.add(_element(_id(element), '${geometry}color:${cssColor(color)};',
          const [], cls: glyph == null ? 'ic' : 'ic ${glyph.cls}'));
      return;
    }
    final runs = <_Run>[];
    _collectRuns(span, null, runs);
    final children = <VNode>[];
    final plain = runs.every((r) => r.style == null || r.style == base);
    final css = _textCss(
      base,
      ro.textSize.height,
      ro.textScaler,
      ro.textAlign,
      ro.textDirection,
      singleLine: ro.maxLines == 1 || !ro.softWrap,
      clipped: ro.didExceedMaxLines ||
          ro.textSize.width > size.width + 0.5 ||
          ro.textSize.height > size.height + 0.5,
      ellipsis: ro.overflow == TextOverflow.ellipsis,
    );
    if (plain) {
      final text = runs.map((r) => r.text).join();
      if (text.isNotEmpty) {
        children.add(_textNode(_id(element, 1), _mask(text, s.maskText)));
      }
    } else {
      for (var i = 0; i < runs.length; i++) {
        final run = runs[i];
        children.add(_element(
          _id(element, 2 + 2 * i),
          _spanCss(run.style ?? base, base, ro.textScaler),
          [_textNode(_id(element, 3 + 2 * i), _mask(run.text, s.maskText))],
          tag: 'span',
        ));
      }
    }
    // Widgets inside the text (WidgetSpan) are children of the paragraph.
    _visitChildren(
        element, s.copy(out: children, origin: t, ro: ro, transform: t));
    s.out.add(_element(_id(element), geometry + css.$1, children, cls: css.$2));
  }

  void _field(Element element, RenderEditable ro, _Affine t, _Scope s) {
    final span = ro.text;
    final base = (span is TextSpan ? span.style : null) ?? const TextStyle();
    var text = span?.toPlainText(includeSemanticsLabels: false) ?? '';
    if (ro.obscureText) {
      text = ro.obscuringCharacter * text.characters.length;
    } else if ((maskAllInputs && !ro.readOnly) || s.maskText) {
      // Read-only text (SelectableText) is shown, not typed.
      text = _mask(text, true);
    }
    final css = _textCss(base, ro.preferredLineHeight, ro.textScaler,
        ro.textAlign, ro.textDirection,
        singleLine: ro.maxLines == 1, lineHeight: ro.preferredLineHeight);
    s.out.add(_element(
      _id(element),
      _geometry(s.origin, t, ro.size) + css.$1,
      [if (text.isNotEmpty) _textNode(_id(element, 1), text)],
      cls: css.$2,
    ));
  }

  void _image(Element element, RenderImage ro, _Affine t, _Scope s) {
    if (ro.image == null) return;
    final geometry = _geometry(s.origin, t, ro.size);
    final opacity = ro.opacity?.value;
    final fade = opacity != null && opacity < 1 ? 'opacity:${num3(opacity)};' : '';
    final provider = s.image;
    final url =
        provider != null && _showsImages(s) ? networkImageUrl(provider) : null;
    if (url != null) {
      s.out.add(_element(
        _id(element, 1),
        '$geometry${fade}object-fit:${objectFit(ro.fit)};',
        const [],
        tag: 'img',
        extra: {'src': url},
      ));
    } else {
      s.out.add(_element(_id(element), geometry + fade, const [], cls: 'im'));
    }
  }

  /// A view the platform draws (a web view, a map, a native control) or a
  /// texture (video, camera): its pixels never pass through Flutter, so it
  /// is a labeled placeholder.
  void _nativePlaceholder(Element element, RenderBox ro, _Affine t, _Scope s) {
    final hint = s.hint;
    final label = hint is _NativeHint
        ? hint.label
        : ro is TextureBox
            ? 'Video'
            : 'Native view';
    s.out.add(_element(
      _id(element),
      _geometry(s.origin, t, ro.size),
      [_textNode(_id(element, 1), label)],
      cls: 'pv',
    ));
  }

  static String? _viewType(Widget widget) => switch (widget) {
        AndroidView(:final viewType) => viewType,
        UiKitView(:final viewType) => viewType,
        AppKitView(:final viewType) => viewType,
        PlatformViewLink(:final viewType) => viewType,
        _ => null,
      };

  /// Draws what a custom painter shows when the wireframe knows it. True
  /// when the subtree is done.
  bool _customDrawing(
      Element element, RenderCustomPaint ro, _Affine t, _Scope s) {
    final painter = ro.painter ?? ro.foregroundPainter;
    final hint = s.hint;
    final size = ro.size;
    final geometry = _geometry(s.origin, t, size);
    if (painter is ToggleablePainter) {
      // Without the widget (a toggle from another library) the shape tells
      // a switch from a box.
      final toggle = hint is _ToggleHint
          ? hint
          : _ToggleHint(
              size.width > size.height * 1.3
                  ? _Toggle.materialSwitch
                  : _Toggle.checkbox,
              element.widget,
              element);
      s.out.add(_toggle(element, toggle, painter, size, geometry));
      return true;
    }
    if (hint is _DecoratorHint && ro.child == null) {
      if (!hint.drawn) {
        hint.drawn = true;
        // The field's fill and border paint under its label and text.
        final node = _element(_id(element), geometry + _inputBorder(hint), const []);
        if (identical(s.out, hint.out) && hint.index <= s.out.length) {
          s.out.insert(hint.index, node);
        } else {
          s.out.add(node);
        }
      }
      return true;
    }
    if (ro.child == null &&
        painter != null &&
        painter is! ScrollbarPainter &&
        size.width >= 2 &&
        size.height >= 2) {
      s.out.add(_element(_id(element), geometry, const [], cls: 'cp'));
      return true;
    }
    return false;
  }

  /// A table paints its rows' decorations under its cells and its border
  /// over them.
  void _table(Element element, RenderTable ro, _Affine t, _Scope s) {
    final size = ro.size;
    final direction = ro.textDirection;
    final children = <VNode>[];
    final decorations = ro.rowDecorations;
    for (var y = 0; y < ro.rows && y < decorations.length; y++) {
      final decoration = decorations[y];
      if (decoration == null) continue;
      final box = ro.getRowBox(y);
      final images = _showsImages(s);
      final css = decorationCss(decoration, box.size, direction, images: images);
      if (css.isEmpty) continue;
      children.add(_element(
          _id(element, 1000000 + y),
          'left:${px(box.left)};top:${px(box.top)};'
          'width:${px(box.width)};height:${px(box.height)};$css',
          const [],
          cls: decorationImagePlaceholder(decoration, images: images)
              ? 'im'
              : null));
    }
    _visitChildren(
        element, s.copy(out: children, origin: t, ro: ro, transform: t));

    final border = ro.border;
    if (border != null && ro.rows > 0) {
      final height = ro.getRowBox(ro.rows - 1).bottom;
      var role = 2000000;
      String line(double left, double top, double w, double h, BorderSide side) =>
          'left:${px(left)};top:${px(top)};width:${px(w)};height:${px(h)};'
          'background-color:${cssColor(side.color)};';
      final inside = border.horizontalInside;
      if (inside.style != BorderStyle.none && !isTransparent(inside.color)) {
        final w = inside.width == 0 ? 1.0 : inside.width;
        for (var y = 1; y < ro.rows; y++) {
          final top = ro.getRowBox(y).top;
          children.add(_element(_id(element, role++),
              line(0, top - w / 2, size.width, w, inside), const []));
        }
      }
      final vertical = border.verticalInside;
      if (vertical.style != BorderStyle.none && !isTransparent(vertical.color)) {
        final w = vertical.width == 0 ? 1.0 : vertical.width;
        final lefts = <double>{
          for (final cell in ro.row(0))
            if (cell.parentData case final BoxParentData data) data.offset.dx,
        }.toList()
          ..sort();
        for (final left in lefts.skip(1)) {
          children.add(_element(_id(element, role++),
              line(left - w / 2, 0, w, height, vertical), const []));
        }
      }
      final outline = shadowCss(borderShadows(
          Border(
              top: border.top,
              right: border.right,
              bottom: border.bottom,
              left: border.left),
          direction));
      if (outline.isNotEmpty) {
        children.add(_element(
            _id(element, role),
            'width:${px(size.width)};height:${px(height)};'
            '${radiusCss(border.borderRadius)}$outline',
            const []));
      }
    }
    s.out.add(_element(_id(element), _geometry(s.origin, t, size), children));
  }

  // ---- widgets drawn from their configuration -----------------------------

  /// Draws [element] (a widget whose look is known) in place of what its
  /// render objects paint.
  void _replace(Element element, _Scope s,
      VNode? Function(RenderBox box, String geometry) build) {
    final ro = element.renderObject;
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    final Matrix4 m;
    try {
      m = ro.getTransformTo(s.ro ?? _root);
    } catch (_) {
      return;
    }
    final t = s.transform.then(_Affine.fromMatrix(m));
    if (t.isDegenerate) return;
    final bounds = t.transformRect(Offset.zero & ro.size);
    if (!ro.size.isEmpty && !bounds.overlaps(s.clip)) return;
    final node = build(ro, _geometry(s.origin, t, ro.size));
    if (node != null) s.out.add(node);
  }

  VNode _toggle(Element element, _ToggleHint hint, ToggleablePainter painter,
      Size size, String geometry) {
    double on;
    Color active, inactive;
    try {
      on = painter.position.value;
      active = painter.activeColor;
      inactive = painter.inactiveColor;
    } catch (_) {
      on = 0;
      active = inactive = const Color(0xFF757575);
    }
    final checked = on >= 0.5;
    final cx = size.width / 2, cy = size.height / 2;
    switch (hint.kind) {
      case _Toggle.checkbox:
        const side = 18.0;
        final box = 'left:${px(cx - side / 2)};top:${px(cy - side / 2)};'
            'width:${px(side)};height:${px(side)};border-radius:2px;';
        return _element(_id(element), geometry, [
          _element(
            _id(element, 1),
            checked
                ? '${box}background-color:${cssColor(active)};'
                : '${box}box-shadow:inset 0 0 0 2px ${cssColor(inactive)};',
            [
              if (checked)
                _element(
                    _id(element, 2),
                    'left:6px;top:2px;width:6px;height:11px;'
                    'border:solid #fff;border-width:0 2px 2px 0;'
                    'transform:rotate(45deg);',
                    const []),
            ],
          ),
        ]);
      case _Toggle.radio:
        const side = 20.0;
        final color = cssColor(checked ? active : inactive);
        return _element(_id(element), geometry, [
          _element(
            _id(element, 1),
            'left:${px(cx - side / 2)};top:${px(cy - side / 2)};'
            'width:${px(side)};height:${px(side)};border-radius:50%;'
            'box-shadow:inset 0 0 0 2px $color;',
            [
              if (checked)
                _element(
                    _id(element, 2),
                    'left:5px;top:5px;width:10px;height:10px;'
                    'border-radius:50%;background-color:$color;',
                    const []),
            ],
          ),
        ]);
      case _Toggle.cupertinoSwitch:
      case _Toggle.materialSwitch:
        final cupertino = hint.kind == _Toggle.cupertinoSwitch;
        final w = cupertino ? 51.0 : 52.0, h = cupertino ? 31.0 : 32.0;
        final track = checked
            ? (cupertino
                ? const Color(0xFF34C759)
                : _colors(hint.element)?.primary ?? active)
            : null;
        final thumb = cupertino
            ? const Color(0xFFFFFFFF)
            : (checked ? active : inactive);
        final knob = cupertino ? 27.0 : (checked ? 24.0 : 16.0);
        final travel = w - h;
        final kx = (h - knob) / 2 + travel * on;
        return _element(_id(element), geometry, [
          _element(
            _id(element, 1),
            'left:${px(cx - w / 2)};top:${px(cy - h / 2)};'
            'width:${px(w)};height:${px(h)};border-radius:${px(h / 2)};'
            '${track != null ? 'background-color:${cssColor(track)};' : cupertino ? 'background-color:rgba(120,120,128,.16);' : 'box-shadow:inset 0 0 0 2px ${cssColor(inactive)};'}',
            [
              _element(
                _id(element, 2),
                'left:${px(kx)};top:${px((h - knob) / 2)};'
                'width:${px(knob)};height:${px(knob)};border-radius:50%;'
                'background-color:${cssColor(thumb)};'
                '${cupertino ? 'box-shadow:0 2px 6px rgba(0,0,0,.2);' : ''}',
                const [],
              ),
            ],
          ),
        ]);
    }
  }

  String _inputBorder(_DecoratorHint hint) {
    final decoration = hint.decoration;
    final colors = _colors(hint.element);
    InputBorder? border = hint.focused
        ? decoration.focusedBorder
        : (decoration.enabled ? decoration.enabledBorder : decoration.disabledBorder);
    if (decoration.errorText != null) {
      border = (hint.focused ? decoration.focusedErrorBorder : decoration.errorBorder) ?? border;
    }
    border ??= decoration.border ?? const UnderlineInputBorder();
    var css = '';
    if (decoration.filled == true) {
      final fill = decoration.fillColor ??
          colors?.surfaceContainerHighest ??
          const Color(0x0A000000);
      css += _fill(fill);
    }
    if (border == InputBorder.none || border.borderSide.style == BorderStyle.none) {
      return css;
    }
    var side = border.borderSide;
    if (side.color == const Color(0xFF000000) && colors != null) {
      side = side.copyWith(
        color: decoration.errorText != null
            ? colors.error
            : hint.focused
                ? colors.primary
                : colors.onSurfaceVariant,
        width: hint.focused ? 2 : side.width,
      );
    }
    if (border is OutlineInputBorder) {
      return css +
          radiusCss(border.borderRadius) +
          shadowCss(outlineShadows(side));
    }
    if (border is UnderlineInputBorder) {
      final radius =
          decoration.filled == true ? radiusCss(border.borderRadius) : '';
      return '$css${radius}box-shadow:inset 0 ${px(-side.width)} 0 0 '
          '${cssColor(side.color)};';
    }
    return css + shadowCss(outlineShadows(side));
  }

  VNode? _progress(Element element, Widget widget, RenderBox box, String geometry) {
    final size = box.size;
    final primary = _colors(element)?.primary ?? const Color(0xFF6750A4);
    if (widget is CupertinoActivityIndicator) {
      final side = math.min(size.width, size.height);
      return _element(_id(element), geometry, [
        _element(
          _id(element, 1),
          'left:${px((size.width - side) / 2)};top:${px((size.height - side) / 2)};'
          'width:${px(side)};height:${px(side)};border-radius:50%;'
          'border:${px(math.max(2, side / 8))} dotted #8e8e93;',
          const [],
        ),
      ]);
    }
    if (widget is! ProgressIndicator) return null;
    final color = widget.color ?? widget.valueColor?.value ?? primary;
    final value = widget.value?.clamp(0.0, 1.0);
    if (widget is LinearProgressIndicator) {
      final track = widget.backgroundColor ?? color.withValues(alpha: 0.24);
      return _element(
        _id(element),
        '${geometry}background-color:${cssColor(track)};overflow:hidden;'
        'border-radius:${px(size.height / 2)};',
        [
          _element(
            _id(element, 1),
            'width:${num1((value ?? 0.4) * 100)}%;height:100%;'
            '${value == null ? 'left:30%;' : ''}'
            'background-color:${cssColor(color)};',
            const [],
          ),
        ],
      );
    }
    if (widget is CircularProgressIndicator) {
      final side = math.min(size.width, size.height);
      const stroke = 4.0;
      final ring = 'left:${px((size.width - side) / 2)};'
          'top:${px((size.height - side) / 2)};'
          'width:${px(side)};height:${px(side)};border-radius:50%;';
      final track = widget.backgroundColor;
      return _element(_id(element), geometry, [
        _element(
          _id(element, 1),
          value == null
              ? '${ring}border:${px(stroke)} solid ${track == null ? 'transparent' : cssColor(track)};'
                  'border-top-color:${cssColor(color)};border-right-color:${cssColor(color)};'
              : '${ring}background-image:conic-gradient(${cssColor(color)} 0 '
                  '${num1(value * 100)}%,${track == null ? 'transparent' : cssColor(track)} '
                  '${num1(value * 100)}% 100%);'
                  '-webkit-mask:radial-gradient(farthest-side,transparent calc(100% - ${px(stroke)}),#000 calc(100% - ${px(stroke)}));'
                  'mask:radial-gradient(farthest-side,transparent calc(100% - ${px(stroke)}),#000 calc(100% - ${px(stroke)}));',
          const [],
        ),
      ]);
    }
    return _element(_id(element), geometry, const [], cls: 'cp');
  }

  VNode? _slider(Element element, Widget widget, RenderBox box, String geometry) {
    final size = box.size;
    final colors = _colors(element);
    double start = 0, end;
    Color active, inactive, thumb;
    if (widget is Slider) {
      end = _fraction(widget.value, widget.min, widget.max);
      active = widget.activeColor ?? colors?.primary ?? const Color(0xFF6750A4);
      inactive = widget.inactiveColor ??
          colors?.secondaryContainer ??
          active.withValues(alpha: 0.3);
      thumb = widget.thumbColor ?? active;
    } else if (widget is RangeSlider) {
      start = _fraction(widget.values.start, widget.min, widget.max);
      end = _fraction(widget.values.end, widget.min, widget.max);
      active = widget.activeColor ?? colors?.primary ?? const Color(0xFF6750A4);
      inactive = widget.inactiveColor ??
          colors?.secondaryContainer ??
          active.withValues(alpha: 0.3);
      thumb = active;
    } else if (widget is CupertinoSlider) {
      end = _fraction(widget.value, widget.min, widget.max);
      active = widget.activeColor ?? const Color(0xFF007AFF);
      inactive = const Color(0x33787880);
      thumb = widget.thumbColor;
    } else {
      return null;
    }
    final pad = math.min(24.0, size.height / 2);
    final width = math.max(0.0, size.width - 2 * pad);
    final cy = size.height / 2;
    const trackHeight = 4.0, knob = 20.0;
    final children = <VNode>[
      _element(
          _id(element, 1),
          'left:${px(pad)};top:${px(cy - trackHeight / 2)};width:${px(width)};'
          'height:${px(trackHeight)};border-radius:2px;'
          'background-color:${cssColor(inactive)};',
          const []),
      _element(
          _id(element, 2),
          'left:${px(pad + width * start)};top:${px(cy - trackHeight / 2)};'
          'width:${px(width * (end - start))};height:${px(trackHeight)};'
          'border-radius:2px;background-color:${cssColor(active)};',
          const []),
      for (final (i, at) in [if (widget is RangeSlider) start, end].indexed)
        _element(
            _id(element, 3 + i),
            'left:${px(pad + width * at - knob / 2)};top:${px(cy - knob / 2)};'
            'width:${px(knob)};height:${px(knob)};border-radius:50%;'
            'background-color:${cssColor(thumb)};'
            'box-shadow:0 1px 3px rgba(0,0,0,.3);',
            const []),
    ];
    return _element(_id(element), geometry, children);
  }

  // ---- helpers --------------------------------------------------------------

  /// Whether an image under [s] is drawn from its URL: images are on and
  /// no privacy mask above blocks them.
  bool _showsImages(_Scope s) => networkImages && !s.blockImages;

  static bool _paints(RenderObject parent, RenderObject child) {
    if (parent is RenderIndexedStack) {
      // Paints only the child at its index, but does not say so in
      // paintsChild.
      final index = parent.index;
      if (index == null) return false;
      var at = parent.firstChild;
      for (var i = 0; i < index && at != null; i++) {
        at = parent.childAfter(at);
      }
      return identical(at, child);
    }
    try {
      return parent.paintsChild(child);
    } catch (_) {
      return true;
    }
  }

  /// The last [_localTransform] when it has perspective, which an affine
  /// transform cannot show.
  Matrix4? _projective;

  /// [child]'s paint transform within [parent], or null when it paints
  /// nowhere (a zero transform).
  _Affine? _localTransform(RenderObject parent, RenderObject child) {
    _projective = null;
    final m = _scratch..setIdentity();
    try {
      parent.applyPaintTransform(child, m);
    } catch (_) {
      return _Affine.identity;
    }
    final s = m.storage;
    if (s[3].abs() > 1e-9 || s[7].abs() > 1e-9 || (s[15] - 1).abs() > 1e-9) {
      // Perspective: the affine part only approximates where it lands.
      _projective = Matrix4.copy(m);
    }
    if (s[0] == 1 && s[1] == 0 && s[4] == 0 && s[5] == 1) {
      if (s[12] == 0 && s[13] == 0) return _Affine.identity;
      return _Affine(1, 0, 0, 1, s[12], s[13]);
    }
    final local = _Affine.fromMatrix(m);
    return local.isDegenerate ? null : local;
  }

  _Affine _parentTransform(RenderObject parent) {
    try {
      return _Affine.fromMatrix(parent.getTransformTo(_root));
    } catch (_) {
      return _Affine.identity;
    }
  }

  /// How far a viewport's content is scrolled, as the offset of a node that
  /// holds the content: its children then keep their place in it while it
  /// scrolls, and one attribute changes per frame instead of every child's.
  Offset? _scrollShift(Element element, RenderAbstractViewport viewport) {
    double pixels;
    AxisDirection direction;
    if (viewport is RenderViewportBase) {
      final offset = viewport.offset;
      if (!offset.hasPixels) return null;
      pixels = offset.pixels;
      direction = viewport.axisDirection;
    } else {
      final scrollable = element.findAncestorStateOfType<ScrollableState>();
      final position = scrollable?.position;
      if (position == null || !position.hasPixels) return null;
      pixels = position.pixels;
      direction = scrollable!.axisDirection;
    }
    return switch (direction) {
      AxisDirection.down => Offset(0, -pixels),
      AxisDirection.up => Offset(0, pixels),
      AxisDirection.right => Offset(-pixels, 0),
      AxisDirection.left => Offset(pixels, 0),
    };
  }

  static ColorScheme? _colors(Element element) =>
      element.findAncestorWidgetOfExactType<Theme>()?.data.colorScheme;

  static double _fraction(double value, double min, double max) =>
      max > min ? ((value - min) / (max - min)).clamp(0.0, 1.0) : 0;

  static String _fill(Color color) =>
      isTransparent(color) ? '' : 'background-color:${cssColor(color)};';

  /// Where a node is inside its DOM parent, whose coordinates [origin]
  /// maps to the screen, and how big it is.
  static String _geometry(_Affine origin, _Affine t, Size size) {
    final rel = t.relativeTo(origin);
    final dims = 'width:${px(size.width)};height:${px(size.height)};';
    if (rel.isTranslation) {
      return 'left:${px(rel.tx)};top:${px(rel.ty)};$dims';
    }
    return 'transform:matrix(${num3(rel.a)},${num3(rel.b)},${num3(rel.c)},'
        '${num3(rel.d)},${num1(rel.tx)},${num1(rel.ty)});'
        'transform-origin:0 0;$dims';
  }

  static bool _isIconFont(String? family) =>
      family != null &&
      (family == 'MaterialIcons' ||
          family.endsWith('/CupertinoIcons') ||
          family == 'CupertinoIcons' ||
          family.contains('FontAwesome') ||
          family.contains('Icons'));

  static String _mask(String text, bool mask) =>
      mask ? text.replaceAll(RegExp(r'\S'), '*') : text;

  static void _collectRuns(InlineSpan? span, TextStyle? parent, List<_Run> out) {
    if (span is! TextSpan) return;
    final own = span.style;
    final style = parent == null ? own : (own == null ? parent : parent.merge(own));
    final text = span.text;
    if (text != null && text.isNotEmpty) out.add(_Run(text, style));
    for (final child in span.children ?? const <InlineSpan>[]) {
      _collectRuns(child, style, out);
    }
  }

  /// The inline style and class of a box of text whose laid out lines are
  /// [textHeight] tall together. Lines are as tall in the browser as in
  /// the app, so the text sits where it did even though the browser's font
  /// is not the app's.
  static (String, String) _textCss(
    TextStyle style,
    double textHeight,
    TextScaler scaler,
    TextAlign align,
    TextDirection direction, {
    required bool singleLine,
    double? lineHeight,
    bool clipped = false,
    bool ellipsis = false,
  }) {
    final fontSize = scaler.scale(style.fontSize ?? 14);
    final nominal = fontSize * (style.height ?? 1.17);
    final lines = singleLine
        ? 1
        : math.max(1, nominal > 0 ? (textHeight / nominal).round() : 1);
    final line = lineHeight ?? (textHeight > 0 ? textHeight / lines : nominal);
    final buffer = StringBuffer()
      ..write('font-size:${px(fontSize)};')
      ..write('line-height:${px(line)};')
      ..write(_fontCss(style));
    final resolved = switch (align) {
      TextAlign.start => direction == TextDirection.ltr ? 'left' : 'right',
      TextAlign.end => direction == TextDirection.ltr ? 'right' : 'left',
      TextAlign.left => 'left',
      TextAlign.right => 'right',
      TextAlign.center => 'center',
      TextAlign.justify => 'justify',
    };
    if (direction == TextDirection.rtl) buffer.write('direction:rtl;');
    // The browser's font is not the app's, and a line it draws wider must
    // not be cut where Flutter's was not: a single line spills out of its
    // box the way it is aligned, and only text Flutter itself cut off is
    // clipped.
    if (lines == 1 && !clipped) {
      if (resolved != 'left') buffer.write('justify-content:$resolved;');
      return (buffer.toString(), 't n');
    }
    if (resolved != 'left') buffer.write('text-align:$resolved;');
    if (!clipped) return (buffer.toString(), 't');
    final cut = ellipsis ? 'e' : 'k';
    return (buffer.toString(), lines == 1 ? 't n $cut' : 't $cut');
  }

  static String _fontCss(TextStyle style) {
    final buffer = StringBuffer();
    final color = style.color ?? style.foreground?.color ?? const Color(0xDD000000);
    buffer.write('color:${cssColor(color)};');
    final weight = style.fontWeight;
    if (weight != null && weight != FontWeight.w400) {
      buffer.write('font-weight:${weight.value};');
    }
    if (style.fontStyle == FontStyle.italic) buffer.write('font-style:italic;');
    final decoration = style.decoration;
    if (decoration != null && decoration != TextDecoration.none) {
      final lines = [
        if (decoration.contains(TextDecoration.underline)) 'underline',
        if (decoration.contains(TextDecoration.lineThrough)) 'line-through',
        if (decoration.contains(TextDecoration.overline)) 'overline',
      ];
      if (lines.isNotEmpty) buffer.write('text-decoration:${lines.join(' ')};');
    }
    final spacing = style.letterSpacing;
    if (spacing != null && spacing != 0) {
      buffer.write('letter-spacing:${px(spacing)};');
    }
    final family = style.fontFamily?.toLowerCase();
    if (family != null &&
        (family.contains('mono') || family.contains('courier'))) {
      buffer.write('font-family:monospace;');
    }
    final background = style.backgroundColor ?? style.background?.color;
    if (!isTransparent(background)) {
      buffer.write('background-color:${cssColor(background!)};');
    }
    return buffer.toString();
  }

  static String _spanCss(TextStyle style, TextStyle base, TextScaler scaler) {
    final out = StringBuffer(_fontCss(style));
    if (style.fontSize != base.fontSize) {
      out.write('font-size:${px(scaler.scale(style.fontSize ?? 14))};');
    }
    return out.toString();
  }

  static _Toggle? _toggleKind(Widget widget) => switch (widget) {
        Checkbox() || CupertinoCheckbox() => _Toggle.checkbox,
        Radio() || CupertinoRadio() => _Toggle.radio,
        Switch() => _Toggle.materialSwitch,
        CupertinoSwitch() => _Toggle.cupertinoSwitch,
        _ => null,
      };
}

class _Run {
  _Run(this.text, this.style);
  final String text;
  final TextStyle? style;
}

enum _Toggle { checkbox, radio, materialSwitch, cupertinoSwitch }

sealed class _Hint {
  const _Hint();
}

class _IconHint extends _Hint {
  const _IconHint();
}

class _SegmentedHint extends _Hint {
  _SegmentedHint(this.widget, this.element);
  final SegmentedButton<Object?> widget;
  final Element element;
  bool drawn = false;
}

class _NativeHint extends _Hint {
  const _NativeHint(this.label);
  final String label;
}

class _ToggleHint extends _Hint {
  _ToggleHint(this.kind, this.widget, this.element);
  final _Toggle kind;
  final Widget widget;
  final Element element;
}

class _DecoratorHint extends _Hint {
  _DecoratorHint(
      this.decoration, this.focused, this.element, this.out, this.index);
  final InputDecoration decoration;
  final bool focused;
  final Element element;

  /// Where the decorator's nodes start: its container goes first.
  final List<VNode> out;
  final int index;
  bool drawn = false;
}

/// Where the walk is: the DOM parent being filled and the coordinates of
/// both it and the nearest render object above.
class _Scope {
  const _Scope({
    required this.out,
    required this.origin,
    required this.ro,
    required this.transform,
    required this.clip,
    this.maskText = false,
    this.blockImages = false,
    this.hint,
    this.image,
  });

  /// Children of the DOM node being filled.
  final List<VNode> out;

  /// Maps the coordinates of that DOM node to the screen.
  final _Affine origin;

  /// The nearest render object above, and its paint transform to the screen.
  final RenderObject? ro;
  final _Affine transform;

  /// What clips above leave visible, in screen coordinates.
  final Rect clip;
  final bool maskText;
  final bool blockImages;
  final _Hint? hint;
  final ImageProvider? image;

  _Scope copy({
    List<VNode>? out,
    _Affine? origin,
    RenderObject? ro,
    _Affine? transform,
    Rect? clip,
    bool? maskText,
    bool? blockImages,
    _Hint? hint,
    ImageProvider? image,
  }) =>
      _Scope(
        out: out ?? this.out,
        origin: origin ?? this.origin,
        ro: ro ?? this.ro,
        transform: transform ?? this.transform,
        clip: clip ?? this.clip,
        maskText: maskText ?? this.maskText,
        blockImages: blockImages ?? this.blockImages,
        hint: hint ?? this.hint,
        image: image ?? this.image,
      );
}

/// A 2D affine transform: x' = a·x + c·y + tx, y' = b·x + d·y + ty. The
/// perspective part of a 3D transform is dropped.
class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const identity = _Affine(1, 0, 0, 1, 0, 0);

  factory _Affine.fromMatrix(Matrix4 m) {
    final s = m.storage;
    return _Affine(s[0], s[1], s[4], s[5], s[12], s[13]);
  }

  final double a, b, c, d, tx, ty;

  static const double _epsilon = 1e-6;

  bool get isTranslation =>
      (a - 1).abs() < _epsilon &&
      b.abs() < _epsilon &&
      c.abs() < _epsilon &&
      (d - 1).abs() < _epsilon;

  bool get isDegenerate => (a * d - b * c).abs() < 1e-9;

  _Affine translate(double x, double y) =>
      _Affine(a, b, c, d, tx + a * x + c * y, ty + b * x + d * y);

  /// This transform applied after [local]: maps [local]'s space to the
  /// screen.
  _Affine then(_Affine local) {
    if (identical(local, identity)) return this;
    if (local.isTranslation) return translate(local.tx, local.ty);
    return _Affine(
      a * local.a + c * local.b,
      b * local.a + d * local.b,
      a * local.c + c * local.d,
      b * local.c + d * local.d,
      a * local.tx + c * local.ty + tx,
      b * local.tx + d * local.ty + ty,
    );
  }

  /// This transform in the coordinates of [origin]: origin⁻¹ · this.
  _Affine relativeTo(_Affine origin) {
    if (origin.isTranslation) {
      return _Affine(a, b, c, d, tx - origin.tx, ty - origin.ty);
    }
    final det = origin.a * origin.d - origin.b * origin.c;
    if (det.abs() < 1e-12) return this;
    final ia = origin.d / det, ib = -origin.b / det;
    final ic = -origin.c / det, id = origin.a / det;
    final itx = -(ia * origin.tx + ic * origin.ty);
    final ity = -(ib * origin.tx + id * origin.ty);
    return _Affine(
      ia * a + ic * b,
      ib * a + id * b,
      ia * c + ic * d,
      ib * c + id * d,
      ia * tx + ic * ty + itx,
      ib * tx + id * ty + ity,
    );
  }

  Rect transformRect(Rect r) {
    if (isTranslation) return r.shift(Offset(tx, ty));
    double x(double px, double py) => a * px + c * py + tx;
    double y(double px, double py) => b * px + d * py + ty;
    final xs = [x(r.left, r.top), x(r.right, r.top), x(r.left, r.bottom), x(r.right, r.bottom)];
    final ys = [y(r.left, r.top), y(r.right, r.top), y(r.left, r.bottom), y(r.right, r.bottom)];
    return Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min),
        xs.reduce(math.max), ys.reduce(math.max));
  }
}

/// What a platform view of [viewType] shows, as its placeholder says:
/// view types name their plugin (`plugins.flutter.io/webview`,
/// `plugins.flutter.dev/google_maps_android`).
String nativeViewLabel(String viewType) {
  final name = viewType.toLowerCase();
  if (name.contains('webview') ||
      name.contains('web_view') ||
      name.contains('browser')) {
    return 'Web view';
  }
  if (name.contains('map')) return 'Map';
  if (name.contains('video') || name.contains('player')) return 'Video';
  if (name.contains('camera') || name.contains('scanner')) return 'Camera';
  return 'Native view';
}
