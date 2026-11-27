import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Pictures of the icons the app shows, so the replay draws each icon's
/// shape instead of a square.
///
/// An icon is a glyph of an icon font, which the browser does not have.
/// The first time a glyph shows (its font, size and box), it is drawn once,
/// off the capture, into a small PNG; the replay uses it as a CSS mask over
/// the icon's color, so one picture serves every color the icon takes.
/// Until it is ready the icon is a square.
///
/// Every full snapshot carries the pictures of the icons on screen, so they
/// are kept small: the glyph's coverage as 16 levels of gray, a luminance
/// mask, about 250 bytes for a 24 px icon.
class WireframeGlyphs {
  WireframeGlyphs({this.pixelRatio = 1.5, this.maxGlyphs = 300});

  /// Pixels per logical pixel of the pictures.
  final double pixelRatio;

  /// Glyphs drawn at most; others stay squares.
  final int maxGlyphs;

  /// Called when a picture is ready, so the next frame can use it.
  void Function()? onReady;

  final Map<String, Glyph> _glyphs = {};
  int _next = 0;

  /// The glyph [span] draws in a box of [size], drawn now if it is new;
  /// null when too many have been drawn.
  Glyph? lookup(InlineSpan span, Size size, TextDirection direction,
      TextScaler scaler) {
    final style = span is TextSpan ? span.style : null;
    final key = '${style?.fontFamily}|'
        '${style?.fontSize?.toStringAsFixed(1)}|${style?.fontWeight?.value}|'
        '${style?.fontVariations}|${span.toPlainText()}|'
        '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}';
    var glyph = _glyphs[key];
    if (glyph == null) {
      if (_glyphs.length >= maxGlyphs) return null;
      glyph = _glyphs[key] = Glyph._('g${_next++}');
      _draw(glyph, span, size, direction, scaler);
    }
    return glyph;
  }

  /// Every glyph seen so far.
  Iterable<Glyph> get all => _glyphs.values;

  /// Nothing awaits it: whatever fails in it (a box of no finite size, a
  /// style the painter rejects) stays in it.
  Future<void> _draw(Glyph glyph, InlineSpan span, Size size,
      TextDirection direction, TextScaler scaler) async {
    final TextPainter painter;
    final int width, height;
    try {
      if (!size.isFinite) return;
      width = (size.width * pixelRatio).ceil();
      height = (size.height * pixelRatio).ceil();
      if (width <= 0 || height <= 0 || width > 512 || height > 512) return;
      // Only the shape matters, opaque: the color comes from the page. An
      // icon's style does not inherit, so the color is replaced on it.
      final opaque = span is TextSpan && span.style?.foreground == null
          ? TextSpan(
              text: span.text,
              children: span.children,
              style: (span.style ?? const TextStyle())
                  .copyWith(color: const Color(0xFF000000)),
            )
          : span;
      painter = TextPainter(
        text: opaque,
        textDirection: direction,
        textScaler: scaler,
      );
    } catch (_) {
      return;
    }
    try {
      painter.layout();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(pixelRatio);
      painter.paint(canvas, Offset.zero);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (rgba == null) return;
      glyph.css = '.ic.${glyph.cls}::before{inset:0;border-radius:0;'
          'opacity:1;mask:url(data:image/png;base64,'
          '${base64Encode(maskPng(rgba, width, height))}) 0 0/100% 100% '
          'no-repeat luminance}';
      onReady?.call();
    } catch (_) {
      // Without its picture the icon stays a square.
    } finally {
      painter.dispose();
    }
  }
}

/// A PNG of how much [rgba] covers each pixel (its alpha), as 4-bit gray:
/// white where the glyph is, black where it is not.
Uint8List maskPng(ByteData rgba, int width, int height) {
  final rowBytes = (width + 1) ~/ 2;
  final raw = Uint8List(height * (rowBytes + 1));
  var o = 0;
  for (var y = 0; y < height; y++) {
    raw[o++] = 0; // no filter
    for (var x = 0; x < width; x += 2) {
      final a = rgba.getUint8((y * width + x) * 4 + 3) >> 4;
      final b =
          x + 1 < width ? rgba.getUint8((y * width + x + 1) * 4 + 3) >> 4 : 0;
      raw[o++] = a << 4 | b;
    }
  }
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = Uint8List.fromList([...ascii.encode(type), ...data]);
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List());
  }

  // Width, height, 4 bits per pixel, grayscale, no interlace.
  chunk('IHDR', [
    ...(ByteData(8)
          ..setUint32(0, width)
          ..setUint32(4, height))
        .buffer
        .asUint8List(),
    4, 0, 0, 0, 0,
  ]);
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw));
  chunk('IEND', const []);
  return out.takeBytes();
}

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// One icon glyph: the class its icons carry and, once drawn, the CSS rule
/// that shows it.
class Glyph {
  Glyph._(this.cls);

  final String cls;
  String? css;

  /// The style node that holds [css] in the replay.
  int? styleId;

  /// When a frame last showed the glyph.
  DateTime? lastShown;
}
