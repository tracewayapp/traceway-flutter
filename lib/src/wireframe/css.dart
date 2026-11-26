import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// A length in CSS pixels, rounded to a tenth so sub-pixel animation noise
/// does not turn into a mutation on every frame.
String px(double value) => '${num1(value)}px';

String num1(double value) {
  if (!value.isFinite) return '0';
  final rounded = (value * 10).round();
  if (rounded % 10 == 0) return '${rounded ~/ 10}';
  return (rounded / 10).toString();
}

String num3(double value) {
  if (!value.isFinite) return '0';
  final rounded = (value * 1000).round() / 1000;
  return rounded == rounded.roundToDouble()
      ? '${rounded.round()}'
      : rounded.toString();
}

String cssColor(Color color) {
  final argb = color.toARGB32();
  final a = (argb >> 24) & 0xff;
  final r = (argb >> 16) & 0xff;
  final g = (argb >> 8) & 0xff;
  final b = argb & 0xff;
  if (a == 0xff) {
    return '#${_hex(r)}${_hex(g)}${_hex(b)}';
  }
  return 'rgba($r,$g,$b,${num3(a / 255)})';
}

String _hex(int v) => v.toRadixString(16).padLeft(2, '0');

bool isTransparent(Color? color) =>
    color == null || (color.toARGB32() >> 24) == 0;

/// `border-radius` for the four corners, or empty when all are square.
String radiusCss(BorderRadius radius) {
  final tl = radius.topLeft, tr = radius.topRight;
  final br = radius.bottomRight, bl = radius.bottomLeft;
  if (_zero(tl) && _zero(tr) && _zero(br) && _zero(bl)) return '';
  if (tl == tr && tr == br && br == bl) {
    return tl.x == tl.y
        ? 'border-radius:${px(tl.x)};'
        : 'border-radius:${px(tl.x)}/${px(tl.y)};';
  }
  bool elliptic(Radius r) => r.x != r.y;
  if (!elliptic(tl) && !elliptic(tr) && !elliptic(br) && !elliptic(bl)) {
    return 'border-radius:${px(tl.x)} ${px(tr.x)} ${px(br.x)} ${px(bl.x)};';
  }
  return 'border-radius:${px(tl.x)} ${px(tr.x)} ${px(br.x)} ${px(bl.x)}/'
      '${px(tl.y)} ${px(tr.y)} ${px(br.y)} ${px(bl.y)};';
}

bool _zero(Radius r) => r.x <= 0 || r.y <= 0;

/// Borders are drawn as inset box shadows: like Flutter's, they paint
/// inside the box, and unlike CSS borders they do not move the children,
/// which are placed from the box's corner.
String? _inset(BorderSide side, double dx, double dy) {
  if (side.style == BorderStyle.none || side.width < 0) return null;
  if (isTransparent(side.color)) return null;
  // Width 0 is a hairline: one device pixel.
  final w = side.width == 0 ? 1.0 : side.width;
  String offset(double d) => d == 0 ? '0' : px(d * w);
  return 'inset ${offset(dx)} ${offset(dy)} 0 ${dx == 0 && dy == 0 ? px(w) : '0'} '
      '${cssColor(side.color)}';
}

List<String> borderShadows(BoxBorder? border, TextDirection direction) {
  if (border == null) return const [];
  BorderSide top, right, bottom, left;
  if (border is Border) {
    top = border.top;
    right = border.right;
    bottom = border.bottom;
    left = border.left;
  } else if (border is BorderDirectional) {
    final ltr = direction == TextDirection.ltr;
    top = border.top;
    right = ltr ? border.end : border.start;
    bottom = border.bottom;
    left = ltr ? border.start : border.end;
  } else {
    return const [];
  }
  if (border.isUniform) {
    final all = _inset(top, 0, 0);
    return all == null ? const [] : [all];
  }
  return [
    _inset(top, 0, 1),
    _inset(right, -1, 0),
    _inset(bottom, 0, -1),
    _inset(left, 1, 0),
  ].whereType<String>().toList();
}

List<String> outlineShadows(BorderSide side) {
  final all = _inset(side, 0, 0);
  return all == null ? const [] : [all];
}

List<String> boxShadows(List<BoxShadow>? shadows) => [
      for (final s in shadows ?? const <BoxShadow>[])
        if (!isTransparent(s.color))
          '${px(s.offset.dx)} ${px(s.offset.dy)} ${px(s.blurRadius)} '
              '${px(s.spreadRadius)} ${cssColor(s.color)}',
    ];

String shadowCss(List<String> parts) =>
    parts.isEmpty ? '' : 'box-shadow:${parts.join(',')};';

/// The shadow of a Material surface lifted by [elevation].
List<String> elevationShadows(double elevation, Color shadowColor) {
  if (elevation <= 0 || isTransparent(shadowColor)) return const [];
  final alpha = (shadowColor.toARGB32() >> 24) / 255;
  final color = shadowColor.withValues(alpha: (alpha * 0.28).clamp(0.0, 1.0));
  return ['0 ${px(elevation * 0.5)} ${px(elevation * 1.6)} 0 ${cssColor(color)}'];
}

String _stops(List<Color> colors, List<double>? stops) {
  final parts = <String>[];
  for (var i = 0; i < colors.length; i++) {
    final at = stops != null && i < stops.length
        ? ' ${num1(stops[i] * 100)}%'
        : '';
    parts.add('${cssColor(colors[i])}$at');
  }
  return parts.join(',');
}

String gradientCss(Gradient? gradient, Size size, TextDirection direction) {
  if (gradient == null) return '';
  if (gradient is LinearGradient) {
    final begin = gradient.begin.resolve(direction);
    final end = gradient.end.resolve(direction);
    // CSS angles run clockwise from "to top".
    final dx = (end.x - begin.x) * size.width;
    final dy = (end.y - begin.y) * size.height;
    final degrees = (math.atan2(dx, -dy) * 180 / math.pi) % 360;
    return 'background-image:linear-gradient(${num1(degrees)}deg,'
        '${_stops(gradient.colors, gradient.stops)});';
  }
  if (gradient is RadialGradient) {
    final c = gradient.center.resolve(direction);
    return 'background-image:radial-gradient(circle at '
        '${num1((c.x + 1) * 50)}% ${num1((c.y + 1) * 50)}%,'
        '${_stops(gradient.colors, gradient.stops)});';
  }
  if (gradient is SweepGradient) {
    final c = gradient.center.resolve(direction);
    return 'background-image:conic-gradient(from 90deg at '
        '${num1((c.x + 1) * 50)}% ${num1((c.y + 1) * 50)}%,'
        '${_stops(gradient.colors, gradient.stops)});';
  }
  return '';
}

/// The corner rounding of a [ShapeBorder].
String shapeRadiusCss(ShapeBorder? shape, Size size, TextDirection direction) {
  if (shape == null) return '';
  var out = '';
  if (shape is CircleBorder) {
    out = 'border-radius:50%;';
  } else if (shape is StadiumBorder) {
    out = 'border-radius:${px(math.min(size.width, size.height) / 2)};';
  } else if (shape is RoundedRectangleBorder) {
    out = radiusCss(shape.borderRadius.resolve(direction));
  } else if (shape is ContinuousRectangleBorder) {
    // A squircle: about half its nominal radius as a circular corner.
    final r = shape.borderRadius.resolve(direction);
    out = radiusCss(BorderRadius.only(
      topLeft: r.topLeft / 2.2,
      topRight: r.topRight / 2.2,
      bottomLeft: r.bottomLeft / 2.2,
      bottomRight: r.bottomRight / 2.2,
    ));
  } else if (shape is OvalBorder) {
    out = 'border-radius:50%;';
  } else {
    // Beveled corners, stars, custom shapes: their outline as a path.
    try {
      out = clipPathCss(
          shape.getOuterPath(Offset.zero & size, textDirection: direction));
    } catch (_) {
      out = '';
    }
  }
  return out;
}

/// [path] as a CSS clip path, its outline sampled every few pixels: CSS
/// has no shape for beveled corners, stars or custom clippers.
String clipPathCss(Path path) {
  final out = StringBuffer();
  var points = 0;
  for (final metric in path.computeMetrics()) {
    final length = metric.length;
    if (length <= 0) continue;
    final n = (length / 3).clamp(4, 160).round();
    for (var i = 0; i <= n; i++) {
      final at = metric.getTangentForOffset(length * i / n)?.position;
      if (at == null) continue;
      out.write(i == 0 ? 'M' : 'L');
      out.write('${num1(at.dx)} ${num1(at.dy)}');
      points++;
    }
    if (metric.isClosed) out.write('Z');
    if (points > 640) break;
  }
  return out.isEmpty ? '' : "clip-path:path('$out');";
}

/// The outline a [ShapeBorder] paints, as inset shadows.
List<String> shapeOutline(ShapeBorder? shape,
        [TextDirection direction = TextDirection.ltr]) =>
    switch (shape) {
      OutlinedBorder() => outlineShadows(shape.side),
      BoxBorder() => borderShadows(shape, direction),
      _ => const [],
    };

String decorationCss(Decoration decoration, Size size, TextDirection direction,
    {required bool images}) {
  if (decoration is BoxDecoration) {
    final buffer = StringBuffer();
    final color = decoration.color;
    if (!isTransparent(color)) {
      buffer.write('background-color:${cssColor(color!)};');
    }
    buffer.write(gradientCss(decoration.gradient, size, direction));
    final image = decoration.image;
    if (image != null && decoration.gradient == null) {
      final url = images ? networkImageUrl(image.image) : null;
      buffer.write(url != null
          ? 'background-image:url("${cssUrl(url)}");'
              'background-size:${backgroundSize(image.fit)};'
              'background-position:center;background-repeat:no-repeat;'
          : 'background-color:rgba(158,158,158,.22);');
    }
    if (decoration.shape == BoxShape.circle) {
      buffer.write('border-radius:50%;');
    } else if (decoration.borderRadius != null) {
      buffer.write(radiusCss(decoration.borderRadius!.resolve(direction)));
    }
    buffer.write(shadowCss([
      ...boxShadows(decoration.boxShadow),
      ...borderShadows(decoration.border, direction),
    ]));
    return buffer.toString();
  }
  if (decoration is ShapeDecoration) {
    final buffer = StringBuffer();
    final color = decoration.color;
    if (!isTransparent(color)) {
      buffer.write('background-color:${cssColor(color!)};');
    }
    buffer.write(gradientCss(decoration.gradient, size, direction));
    buffer.write(shapeRadiusCss(decoration.shape, size, direction));
    buffer.write(shadowCss([
      ...boxShadows(decoration.shadows),
      ...shapeOutline(decoration.shape, direction),
    ]));
    return buffer.toString();
  }
  return '';
}

/// The address of an image that came from the network, through the
/// providers that wrap another one.
String? networkImageUrl(ImageProvider provider) {
  var p = provider;
  for (var i = 0; i < 4 && p is ResizeImage; i++) {
    p = p.imageProvider;
  }
  if (p is NetworkImage) {
    final url = p.url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
  }
  return null;
}

String cssUrl(String url) =>
    url.replaceAll('\\', '%5C').replaceAll('"', '%22').replaceAll('\n', '');

String objectFit(BoxFit? fit) => switch (fit) {
      BoxFit.fill => 'fill',
      BoxFit.cover || BoxFit.fitWidth || BoxFit.fitHeight => 'cover',
      BoxFit.none => 'none',
      BoxFit.scaleDown => 'scale-down',
      _ => 'contain',
    };

String backgroundSize(BoxFit? fit) => switch (fit) {
      BoxFit.fill => '100% 100%',
      BoxFit.cover || BoxFit.fitWidth || BoxFit.fitHeight => 'cover',
      BoxFit.none => 'auto',
      _ => 'contain',
    };

/// The CSS for a blur [filter] (an `ImageFilter.blur` or an
/// `ImageFilterConfig.blur`), or null for any other filter. Filters show
/// their parameters only in their description.
String? blurCss(Object? filter) {
  final text = '$filter';
  if (!text.startsWith('ImageFilter')) return null;
  // ImageFilter.blur(3.0, 3.0, clamp), ImageFilterConfig.blur(...) or
  // ImageFilterConfig(blur(...)).
  final match = RegExp(r'blur\(([\d.]+), ([\d.]+)').firstMatch(text);
  if (match == null) return null;
  final sigma = (double.parse(match[1]!) + double.parse(match[2]!)) / 2;
  return sigma > 0.05 ? 'blur(${num1(sigma)}px)' : null;
}

/// The CSS for a [ColorFilter] that turns colors gray (the saturation of a
/// color, or a matrix that mixes every channel alike), or null.
String? colorFilterCss(ColorFilter filter) {
  final text = filter.toString();
  if (text.startsWith('ColorFilter.mode(') &&
      text.endsWith('BlendMode.saturation)')) {
    return 'grayscale(1)';
  }
  final match = RegExp(r'ColorFilter\.matrix\(\[(.*)\]\)').firstMatch(text);
  if (match == null) return null;
  final m = [for (final v in match[1]!.split(',')) double.tryParse(v.trim())];
  if (m.length != 20 || m.contains(null)) return null;
  bool same(int a, int b) => (m[a]! - m[b]!).abs() < 1e-3;
  final gray = [0, 1, 2, 4].every((c) => same(c, 5 + c) && same(c, 10 + c)) &&
      m[3]!.abs() < 1e-3 &&
      (m[18]! - 1).abs() < 1e-3;
  return gray ? 'grayscale(1)' : null;
}
