import 'package:flutter/widgets.dart';

import 'traceway_mask_mode.dart';

/// Hides [child] in screen recordings, and keeps the text it shows out of
/// tap records.
class TracewayPrivacyMask extends StatefulWidget {
  final Widget child;
  final TracewayMaskMode mode;

  const TracewayPrivacyMask({
    super.key,
    required this.child,
    this.mode = const TracewayMaskBlur(),
  });

  @override
  State<TracewayPrivacyMask> createState() => _TracewayPrivacyMaskState();
}

class _TracewayPrivacyMaskState extends State<TracewayPrivacyMask> {
  static final Set<_TracewayPrivacyMaskState> _mounted = {};

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
  }

  @override
  void dispose() {
    _mounted.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Where every mask on screen is right now, in the coordinates of
/// [boundary]. Read from the render tree when a frame is captured, so a mask
/// stays on its widget while that scrolls, animates or is transformed: the
/// rectangle is the bounds of the widget as it was last painted.
List<MaskRegion> maskRegionsIn(RenderBox boundary) {
  final regions = <MaskRegion>[];
  for (final mask in _TracewayPrivacyMaskState._mounted) {
    final box = mask.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    final Matrix4 transform;
    try {
      transform = box.getTransformTo(boundary);
    } catch (_) {
      // In another view: not part of what [boundary] paints.
      continue;
    }
    regions.add(MaskRegion(
      rect: MatrixUtils.transformRect(transform, Offset.zero & box.size),
      mode: mask.widget.mode,
    ));
  }
  return regions;
}
