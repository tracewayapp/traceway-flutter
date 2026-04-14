import 'dart:ui' show Color, Rect;

import 'package:flutter/foundation.dart' show Key;

sealed class TracewayMaskMode {
  const TracewayMaskMode();
  const factory TracewayMaskMode.blur({double ratio}) = TracewayMaskBlur;
  const factory TracewayMaskMode.blank({Color color}) = TracewayMaskBlank;
}

class TracewayMaskBlur extends TracewayMaskMode {
  /// Controls pixelation intensity. 0.0 = very light (2px blocks),
  /// 1.0 = heavy (20px blocks). Defaults to 1.0.
  final double ratio;
  const TracewayMaskBlur({this.ratio = 1.0});
}

class TracewayMaskBlank extends TracewayMaskMode {
  /// Solid fill color. Defaults to black.
  final Color color;
  const TracewayMaskBlank({this.color = const Color(0xFF000000)});
}

class MaskRegion {
  final Key key;
  final Rect rect;
  final TracewayMaskMode mode;

  const MaskRegion({
    required this.key,
    required this.rect,
    required this.mode,
  });
}
