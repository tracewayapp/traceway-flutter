// The SDK's wireframe recognises Flutter's own Material library, which every
// Flutter release still ships; the app uses it on purpose.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

/// `Image.network` with `cacheWidth` set to the displayed width times the
/// device pixel ratio, a neutral box while loading, and an optional
/// callback when the first frame is decoded.
class NetImage extends StatelessWidget {
  const NetImage(
    this.url, {
    super.key,
    required this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.onDecoded,
    this.radius = 0,
  });

  final String url;
  final double width;
  final double? height;
  final BoxFit fit;
  final VoidCallback? onDecoded;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scheme = Theme.of(context).colorScheme;
    Widget image = Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      cacheWidth: (width * dpr).round(),
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame == null) {
          return Container(width: width, height: height, color: scheme.surfaceContainerHighest);
        }
        if (onDecoded != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onDecoded!());
        }
        return child;
      },
      errorBuilder: (context, error, stack) => Container(
        width: width,
        height: height,
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.image_not_supported_outlined, color: scheme.outline),
      ),
    );
    if (radius > 0) {
      image = ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
    }
    return image;
  }
}

/// Five stars for a rating out of five.
class Stars extends StatelessWidget {
  const Stars(this.rating, {super.key, this.size = 14});

  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFE0A100);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        Icon(
          rating >= i
              ? Icons.star
              : rating >= i - 0.5
                  ? Icons.star_half
                  : Icons.star_border,
          size: size,
          color: color,
        ),
    ]);
  }
}

/// A small line chart drawn with `CustomPaint`, as the watchlist and the
/// feed's price alerts show it.
class Sparkline extends StatelessWidget {
  const Sparkline(this.points, {super.key, this.width = 64, this.height = 24, this.up = true});

  final List<int> points;
  final double width;
  final double height;
  final bool up;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, height),
        painter: _SparkPainter(points, up ? const Color(0xFF1B8A3A) : const Color(0xFFC62828)),
      );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.points, this.color);

  final List<int> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var lo = points.first, hi = points.first;
    for (final p in points) {
      if (p < lo) lo = p;
      if (p > hi) hi = p;
    }
    final span = (hi - lo) == 0 ? 1 : hi - lo;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = size.width * i / (points.length - 1);
      final y = size.height - size.height * (points[i] - lo) / span;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.points != points || old.color != color;
}
