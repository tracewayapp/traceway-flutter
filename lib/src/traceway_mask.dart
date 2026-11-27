import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/widgets.dart';

import 'traceway_mask_mode.dart';

/// Hides [child] in screen recordings, and keeps what it shows out of tap
/// records: its text, its semantics label and the keys inside it.
///
/// With [TracewayMaskMode.blur] (the default) the layout stays: a wireframe
/// shows the text as `*` and images as placeholders, a video pixelates the
/// area. With [TracewayMaskMode.blank] the subtree is recorded as a box of
/// the mode's color.
///
/// A widget keyed `ValueKey('traceway-mask')` is masked like a blur
/// [TracewayMask] without wrapping it, and one keyed
/// `ValueKey('traceway-blank')` like a blank one. Such a key is not
/// reported as the widget's id.
class TracewayMask extends StatelessWidget {
  final Widget child;
  final TracewayMaskMode mode;

  const TracewayMask({
    super.key,
    required this.child,
    this.mode = const TracewayMaskBlur(),
  });

  @override
  Widget build(BuildContext context) => child;
}

@Deprecated('Use TracewayMask')
typedef TracewayPrivacyMask = TracewayMask;

const _maskMarker = 'traceway-mask';
const _blankMarker = 'traceway-blank';

/// How [widget] is masked: by being a [TracewayMask] or by a marker key.
/// Null when it is not a mask.
TracewayMaskMode? maskModeOf(Widget widget) {
  if (widget is TracewayMask) return widget.mode;
  final key = widget.key;
  if (key is! ValueKey) return null;
  return switch (key.value) {
    _maskMarker => const TracewayMaskBlur(),
    _blankMarker => const TracewayMaskBlank(),
    _ => null,
  };
}

bool isMask(Widget widget) => maskModeOf(widget) != null;

/// Whether [key] is `ValueKey('traceway-mask')` or `ValueKey('traceway-blank')`,
/// which say how to record a widget and are not its id.
bool isMaskMarker(Key? key) =>
    key is ValueKey && (key.value == _maskMarker || key.value == _blankMarker);

/// Where every mask under [root] is right now, in the coordinates of the
/// render box [root] paints into: [TracewayMask] widgets and widgets with a
/// marker key, obscured fields (blanked), and with [maskAllInputs] every field the
/// user types into (blurred). Read from the render tree when a frame is
/// captured, so a mask stays on its widget while that scrolls, animates or
/// is transformed: the rectangle is the bounds of the widget as it was last
/// painted. Nothing under a blank mask is listed, its box already covers it.
List<MaskRegion> maskRegionsIn(BuildContext root,
    {bool maskAllInputs = false}) {
  final boundary = root.findRenderObject();
  if (boundary is! RenderBox) return const [];
  final regions = <MaskRegion>[];
  void add(RenderObject? box, TracewayMaskMode mode) {
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    try {
      final transform = box.getTransformTo(boundary);
      regions.add(MaskRegion(
        rect: MatrixUtils.transformRect(transform, Offset.zero & box.size),
        mode: mode,
      ));
    } catch (_) {
      // In another view: not part of what [boundary] paints.
    }
  }

  void visit(Element element) {
    final mode = maskModeOf(element.widget);
    if (mode != null) {
      add(element.findRenderObject(), mode);
      if (mode is TracewayMaskBlank) return;
    }
    if (element is RenderObjectElement && element.renderObject is RenderEditable) {
      final editable = element.renderObject as RenderEditable;
      if (editable.obscureText) {
        // A mobile password field can briefly paint the last typed character.
        add(editable, const TracewayMaskBlank());
      } else if (maskAllInputs && !editable.readOnly) {
        add(editable, const TracewayMaskBlur());
      }
    }
    element.visitChildElements(visit);
  }

  root.visitChildElements(visit);
  return regions;
}
