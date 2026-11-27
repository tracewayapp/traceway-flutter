import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:math' as math;
import 'dart:typed_data';

/// How the wireframe encodes a picture, the same on every Traceway SDK that
/// inlines them: the picture at its displayed size (one pixel per logical
/// pixel, never more pixels than the image has), the longest side at most
/// [maxSide], JPEG at quality [jpegQuality]. A picture with see-through
/// pixels is never JPEG (it would replay as a box over white): it is PNG,
/// its longest side at most [alphaMaxSide]. Dropped when it still takes
/// more than [maxEncodedBytes] once tried again at half the size.
///
/// Pure Dart, no Flutter: it runs in a background isolate. Flutter has no
/// JPEG encoder of its own (the engine encodes PNG only), so the baseline
/// JPEG encoder is here, with the standard tables and 4:2:0 chroma.
abstract final class WireframeImageEncoding {
  static const double pixelsPerLogicalPixel = 1;
  static const int maxSide = 384;
  static const int alphaMaxSide = 192;
  static const double jpegQuality = 0.45;
  static const int maxEncodedBytes = 48 * 1024;

  /// The pixel size a picture shown at [displayedWidth] x [displayedHeight]
  /// logical pixels is encoded at, drawn from [sourceWidth] x [sourceHeight]
  /// pixels of the image; null when there is nothing to draw.
  static (int, int)? pixelSize(double displayedWidth, double displayedHeight,
      double sourceWidth, double sourceHeight) {
    if (!(displayedWidth > 0 &&
        displayedHeight > 0 &&
        displayedWidth.isFinite &&
        displayedHeight.isFinite)) {
      return null;
    }
    var w = displayedWidth * pixelsPerLogicalPixel;
    var h = displayedHeight * pixelsPerLogicalPixel;
    if (sourceWidth > 0 &&
        sourceHeight > 0 &&
        (w > sourceWidth || h > sourceHeight)) {
      final f = math.min(sourceWidth / w, sourceHeight / h);
      w *= f;
      h *= f;
    }
    final longest = math.max(w, h);
    if (longest > maxSide) {
      w *= maxSide / longest;
      h *= maxSide / longest;
    }
    return (math.max(1, w.round()), math.max(1, h.round()));
  }
}

/// An encoded picture: its MIME type and data in base64, ready for a CSS
/// `url(data:…)`.
class EncodedPicture {
  const EncodedPicture(this.mime, this.base64, this.byteLength,
      this.width, this.height);
  final String mime;
  final String base64;

  /// Encoded bytes (before base64).
  final int byteLength;
  final int width, height;
}

/// [rgba] (straight alpha, [width] x [height]) encoded as the wireframe
/// encodes pictures (see [WireframeImageEncoding]), or null when it does
/// not fit in [WireframeImageEncoding.maxEncodedBytes] even at half size.
EncodedPicture? encodeReplayPicture(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return null;
  }
  var data = rgba;
  var w = width, h = height;
  final png = hasAlpha(data, w, h);
  if (png && math.max(w, h) > WireframeImageEncoding.alphaMaxSide) {
    (data, w, h) =
        downscaleToFit(data, w, h, WireframeImageEncoding.alphaMaxSide);
  }
  for (var attempt = 0; attempt < 2; attempt++) {
    final bytes = png
        ? encodePng(data, w, h)
        : encodeJpeg(data, w, h,
            quality: (WireframeImageEncoding.jpegQuality * 100).round());
    if (bytes.length <= WireframeImageEncoding.maxEncodedBytes) {
      return EncodedPicture(png ? 'image/png' : 'image/jpeg',
          base64Encode(bytes), bytes.length, w, h);
    }
    if (attempt > 0 || (w <= 1 && h <= 1)) break;
    (data, w, h) = downscaleHalf(data, w, h);
  }
  return null;
}

/// Whether any pixel of [rgba] is see-through. Edge pixels a scaled draw
/// leaves a shade below opaque do not count.
bool hasAlpha(Uint8List rgba, int width, int height) {
  final n = width * height * 4;
  for (var i = 3; i < n; i += 4) {
    if (rgba[i] < 250) return true;
  }
  return false;
}

/// [rgba] made smaller so its longest side is [maxSide] (the shape kept),
/// each pixel the alpha-weighted average of the source pixels it covers;
/// as it is when it already fits.
(Uint8List, int, int) downscaleToFit(
    Uint8List rgba, int width, int height, int maxSide) {
  final longest = math.max(width, height);
  if (longest <= maxSide) return (rgba, width, height);
  final f = maxSide / longest;
  final w = math.max(1, (width * f).round()), h = math.max(1, (height * f).round());
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final sy0 = y * height ~/ h;
    final sy1 = math.max(sy0 + 1, (y + 1) * height ~/ h);
    for (var x = 0; x < w; x++) {
      final sx0 = x * width ~/ w;
      final sx1 = math.max(sx0 + 1, (x + 1) * width ~/ w);
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var sy = sy0; sy < sy1; sy++) {
        for (var sx = sx0; sx < sx1; sx++) {
          final i = (sy * width + sx) * 4;
          final pa = rgba[i + 3];
          r += rgba[i] * pa;
          g += rgba[i + 1] * pa;
          b += rgba[i + 2] * pa;
          a += pa;
          n++;
        }
      }
      final o = (y * w + x) * 4;
      if (a > 0) {
        out[o] = (r / a).round();
        out[o + 1] = (g / a).round();
        out[o + 2] = (b / a).round();
      }
      out[o + 3] = (a / n).round();
    }
  }
  return (out, w, h);
}

/// [rgba] at half its size (rounded up), each pixel the alpha-weighted
/// average of the 2x2 it covers.
(Uint8List, int, int) downscaleHalf(Uint8List rgba, int width, int height) {
  final w = math.max(1, (width + 1) ~/ 2), h = math.max(1, (height + 1) ~/ 2);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var dy = 0; dy < 2; dy++) {
        final sy = math.min(height - 1, 2 * y + dy);
        for (var dx = 0; dx < 2; dx++) {
          final sx = math.min(width - 1, 2 * x + dx);
          final i = (sy * width + sx) * 4;
          final pa = rgba[i + 3];
          r += rgba[i] * pa;
          g += rgba[i + 1] * pa;
          b += rgba[i + 2] * pa;
          a += pa;
          n++;
        }
      }
      final o = (y * w + x) * 4;
      if (a > 0) {
        out[o] = (r / a).round();
        out[o + 1] = (g / a).round();
        out[o + 2] = (b / a).round();
      }
      out[o + 3] = (a / n).round();
    }
  }
  return (out, w, h);
}

// ---- PNG ----------------------------------------------------------------------

/// [rgba] (straight alpha) as an 8-bit RGBA PNG, each row with the filter
/// that leaves the smallest sum of residuals.
Uint8List encodePng(Uint8List rgba, int width, int height) {
  final stride = width * 4;
  final raw = Uint8List(height * (stride + 1));
  final candidate = Uint8List(stride);
  final best = Uint8List(stride);
  var o = 0;
  for (var y = 0; y < height; y++) {
    final row = y * stride;
    final up = row - stride;
    var bestType = 0;
    var bestSum = -1;
    for (var type = 0; type < 5; type++) {
      var sum = 0;
      for (var i = 0; i < stride; i++) {
        final x = rgba[row + i];
        final a = i >= 4 ? rgba[row + i - 4] : 0;
        final b = y > 0 ? rgba[up + i] : 0;
        final c = i >= 4 && y > 0 ? rgba[up + i - 4] : 0;
        final int v;
        switch (type) {
          case 0:
            v = x;
          case 1:
            v = x - a;
          case 2:
            v = x - b;
          case 3:
            v = x - ((a + b) >> 1);
          default:
            v = x - _paeth(a, b, c);
        }
        final byte = v & 0xFF;
        candidate[i] = byte;
        sum += byte < 128 ? byte : 256 - byte;
      }
      if (bestSum < 0 || sum < bestSum) {
        bestSum = sum;
        bestType = type;
        best.setRange(0, stride, candidate);
      }
    }
    raw[o++] = bestType;
    raw.setRange(o, o + stride, best);
    o += stride;
  }
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = Uint8List(4 + data.length)
      ..setRange(0, 4, ascii.encode(type))
      ..setRange(4, 4 + data.length, data);
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(body)
      ..add((ByteData(4)..setUint32(0, crc32(body))).buffer.asUint8List());
  }

  chunk('IHDR', [
    ...(ByteData(8)
          ..setUint32(0, width)
          ..setUint32(4, height))
        .buffer
        .asUint8List(),
    8, 6, 0, 0, 0, // 8 bits, RGBA, deflate, adaptive filters, no interlace
  ]);
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw));
  chunk('IEND', const []);
  return out.takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

final Uint32List _crcTable = Uint32List.fromList(List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
}));

/// The CRC-32 of [bytes], as PNG chunks carry it.
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

// ---- JPEG ---------------------------------------------------------------------

/// [rgba] (straight alpha) as a baseline JPEG of [quality] (1-100, as
/// libjpeg counts it), 4:2:0 chroma. Pixels a shade below opaque (the edges
/// of a scaled draw) go over white; [encodeReplayPicture] never gives it a
/// picture with see-through pixels.
Uint8List encodeJpeg(Uint8List rgba, int width, int height,
    {int quality = 45}) {
  return _JpegEncoder(quality.clamp(1, 100)).encode(rgba, width, height);
}

/// Natural (row-major) position of a coefficient → its zigzag position.
const List<int> _zigzag = [
  0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, //
  3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18, 24, 31, 40, 44, 53,
  10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60,
  21, 34, 37, 47, 50, 56, 59, 61, 35, 36, 48, 49, 57, 58, 62, 63,
];

// The example tables of the JPEG standard (ITU T.81, Annex K).
const List<int> _lumaQuant = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, //
  14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];
const List<int> _chromaQuant = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, //
  24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
];

/// Code counts per length 1-16, then the symbols, of the four tables.
const List<int> _dcLumaCounts = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const List<int> _dcChromaCounts = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const List<int> _dcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _acLumaCounts = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const List<int> _acLumaValues = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, //
  0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
  0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
  0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
  0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
  0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
  0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
  0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
  0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4,
  0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
];
const List<int> _acChromaCounts = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const List<int> _acChromaValues = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, //
  0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
  0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
  0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
  0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
  0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
  0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
  0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
  0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4,
  0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
];

/// A Huffman table: code and length per symbol.
class _Huffman {
  _Huffman(List<int> counts, List<int> values) {
    var code = 0, k = 0;
    for (var length = 1; length <= 16; length++) {
      for (var j = 0; j < counts[length - 1]; j++) {
        codes[values[k]] = code;
        lengths[values[k]] = length;
        k++;
        code++;
      }
      code <<= 1;
    }
  }

  final Int32List codes = Int32List(256);
  final Int32List lengths = Int32List(256);
}

class _JpegEncoder {
  _JpegEncoder(int quality) {
    final scale = quality < 50 ? 5000 ~/ quality : 200 - quality * 2;
    for (var i = 0; i < 64; i++) {
      _lumaTable[_zigzag[i]] = ((_lumaQuant[i] * scale + 50) ~/ 100).clamp(1, 255);
      _chromaTable[_zigzag[i]] =
          ((_chromaQuant[i] * scale + 50) ~/ 100).clamp(1, 255);
    }
    const aan = [
      1.0, 1.387039845, 1.306562965, 1.175875602, //
      1.0, 0.785694958, 0.541196100, 0.275899379,
    ];
    var k = 0;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        _lumaDivisors[k] =
            1 / (_lumaTable[_zigzag[k]] * aan[row] * aan[col] * 8);
        _chromaDivisors[k] =
            1 / (_chromaTable[_zigzag[k]] * aan[row] * aan[col] * 8);
        k++;
      }
    }
  }

  final Uint8List _lumaTable = Uint8List(64);
  final Uint8List _chromaTable = Uint8List(64);
  final Float64List _lumaDivisors = Float64List(64);
  final Float64List _chromaDivisors = Float64List(64);
  final _Huffman _dcLuma = _Huffman(_dcLumaCounts, _dcValues);
  final _Huffman _acLuma = _Huffman(_acLumaCounts, _acLumaValues);
  final _Huffman _dcChroma = _Huffman(_dcChromaCounts, _dcValues);
  final _Huffman _acChroma = _Huffman(_acChromaCounts, _acChromaValues);

  final BytesBuilder _out = BytesBuilder(copy: false);
  Uint8List _buf = Uint8List(1 << 14);
  int _len = 0;
  int _bits = 0;
  int _bitCount = 0;

  final Float64List _block = Float64List(64);
  final Int32List _quantized = Int32List(64);
  final Int32List _zz = Int32List(64);

  void _byte(int b) {
    if (_len == _buf.length) {
      _out.add(_buf);
      _buf = Uint8List(_buf.length);
      _len = 0;
    }
    _buf[_len++] = b;
  }

  void _word(int w) {
    _byte((w >> 8) & 0xFF);
    _byte(w & 0xFF);
  }

  void _writeBits(int value, int length) {
    for (var i = length - 1; i >= 0; i--) {
      _bits = (_bits << 1) | ((value >> i) & 1);
      if (++_bitCount == 8) {
        _byte(_bits);
        // A 0xFF in the entropy-coded data is followed by a stuffed zero.
        if (_bits == 0xFF) _byte(0);
        _bits = 0;
        _bitCount = 0;
      }
    }
  }

  Uint8List encode(Uint8List rgba, int width, int height) {
    _word(0xFFD8); // SOI
    // APP0 JFIF 1.1, no density, no thumbnail.
    _word(0xFFE0);
    _word(16);
    for (final c in const [0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]) {
      _byte(c);
    }
    // DQT: both tables, in zigzag order.
    _word(0xFFDB);
    _word(132);
    _byte(0);
    for (final v in _lumaTable) {
      _byte(v);
    }
    _byte(1);
    for (final v in _chromaTable) {
      _byte(v);
    }
    // SOF0: 8 bits, three components, luma sampled 2x2.
    _word(0xFFC0);
    _word(17);
    _byte(8);
    _word(height);
    _word(width);
    _byte(3);
    for (final c in const [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]) {
      _byte(c);
    }
    // DHT: the four standard tables.
    _word(0xFFC4);
    _word(0x01A2);
    for (final (id, counts, values) in [
      (0x00, _dcLumaCounts, _dcValues),
      (0x10, _acLumaCounts, _acLumaValues),
      (0x01, _dcChromaCounts, _dcValues),
      (0x11, _acChromaCounts, _acChromaValues),
    ]) {
      _byte(id);
      for (final c in counts) {
        _byte(c);
      }
      for (final v in values) {
        _byte(v);
      }
    }
    // SOS
    _word(0xFFDA);
    _word(12);
    for (final c in const [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 0x3F, 0]) {
      _byte(c);
    }

    final y = Float64List(256), cb = Float64List(256), cr = Float64List(256);
    final sub = Float64List(64);
    var dcY = 0, dcCb = 0, dcCr = 0;
    for (var my = 0; my < height; my += 16) {
      for (var mx = 0; mx < width; mx += 16) {
        // The 16x16 macro block, edge pixels repeated past the image.
        for (var py = 0; py < 16; py++) {
          final sy = math.min(height - 1, my + py);
          for (var px = 0; px < 16; px++) {
            final sx = math.min(width - 1, mx + px);
            final i = (sy * width + sx) * 4;
            var r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
            final a = rgba[i + 3];
            if (a < 255) {
              // Over white.
              final rest = 255 - a;
              r = (r * a + 255 * rest) ~/ 255;
              g = (g * a + 255 * rest) ~/ 255;
              b = (b * a + 255 * rest) ~/ 255;
            }
            final o = py * 16 + px;
            y[o] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
            cb[o] = -0.168736 * r - 0.331264 * g + 0.5 * b;
            cr[o] = 0.5 * r - 0.418688 * g - 0.081312 * b;
          }
        }
        for (final (bx, by) in const [(0, 0), (8, 0), (0, 8), (8, 8)]) {
          for (var row = 0; row < 8; row++) {
            for (var col = 0; col < 8; col++) {
              _block[row * 8 + col] = y[(by + row) * 16 + bx + col];
            }
          }
          dcY = _unit(_lumaDivisors, dcY, _dcLuma, _acLuma);
        }
        for (final (plane, isCb) in [(cb, true), (cr, false)]) {
          for (var row = 0; row < 8; row++) {
            for (var col = 0; col < 8; col++) {
              final o = row * 32 + col * 2;
              sub[row * 8 + col] =
                  (plane[o] + plane[o + 1] + plane[o + 16] + plane[o + 17]) / 4;
            }
          }
          _block.setAll(0, sub);
          if (isCb) {
            dcCb = _unit(_chromaDivisors, dcCb, _dcChroma, _acChroma);
          } else {
            dcCr = _unit(_chromaDivisors, dcCr, _dcChroma, _acChroma);
          }
        }
      }
    }
    // The last byte is padded with ones.
    if (_bitCount > 0) _writeBits((1 << (8 - _bitCount)) - 1, 8 - _bitCount);
    _word(0xFFD9); // EOI
    _out.add(Uint8List.sublistView(_buf, 0, _len));
    return _out.takeBytes();
  }

  /// Codes the 8x8 data unit in [_block]; returns its DC value.
  int _unit(Float64List divisors, int previousDc, _Huffman dc, _Huffman ac) {
    _fdct(_block);
    for (var i = 0; i < 64; i++) {
      final v = _block[i] * divisors[i];
      _quantized[i] = v > 0 ? (v + 0.5).toInt() : (v - 0.5).toInt();
    }
    for (var i = 0; i < 64; i++) {
      _zz[_zigzag[i]] = _quantized[i];
    }
    final diff = _zz[0] - previousDc;
    if (diff == 0) {
      _writeBits(dc.codes[0], dc.lengths[0]);
    } else {
      final category = _category(diff);
      _writeBits(dc.codes[category], dc.lengths[category]);
      _writeBits(_amplitude(diff, category), category);
    }
    var end = 63;
    while (end > 0 && _zz[end] == 0) {
      end--;
    }
    if (end == 0) {
      _writeBits(ac.codes[0x00], ac.lengths[0x00]);
      return _zz[0];
    }
    var i = 1;
    while (i <= end) {
      final start = i;
      while (_zz[i] == 0 && i <= end) {
        i++;
      }
      var zeros = i - start;
      while (zeros >= 16) {
        _writeBits(ac.codes[0xF0], ac.lengths[0xF0]);
        zeros -= 16;
      }
      final value = _zz[i];
      final category = _category(value);
      final symbol = (zeros << 4) + category;
      _writeBits(ac.codes[symbol], ac.lengths[symbol]);
      _writeBits(_amplitude(value, category), category);
      i++;
    }
    if (end != 63) _writeBits(ac.codes[0x00], ac.lengths[0x00]);
    return _zz[0];
  }

  static int _category(int v) {
    var a = v.abs(), n = 0;
    while (a > 0) {
      a >>= 1;
      n++;
    }
    return n;
  }

  static int _amplitude(int v, int category) =>
      v > 0 ? v : v + (1 << category) - 1;

  /// The forward DCT of [d] in place (Arai, Agui and Nakajima), scaled as
  /// the divisors expect.
  static void _fdct(Float64List d) {
    for (var off = 0; off < 64; off += 8) {
      _fdct1(d, off, 1);
    }
    for (var off = 0; off < 8; off++) {
      _fdct1(d, off, 8);
    }
  }

  static void _fdct1(Float64List d, int o, int s) {
    final d0 = d[o], d1 = d[o + s], d2 = d[o + 2 * s], d3 = d[o + 3 * s];
    final d4 = d[o + 4 * s], d5 = d[o + 5 * s], d6 = d[o + 6 * s];
    final d7 = d[o + 7 * s];
    final tmp0 = d0 + d7, tmp7 = d0 - d7;
    final tmp1 = d1 + d6, tmp6 = d1 - d6;
    final tmp2 = d2 + d5, tmp5 = d2 - d5;
    final tmp3 = d3 + d4, tmp4 = d3 - d4;
    // Even part.
    var tmp10 = tmp0 + tmp3;
    final tmp13 = tmp0 - tmp3;
    var tmp11 = tmp1 + tmp2;
    var tmp12 = tmp1 - tmp2;
    d[o] = tmp10 + tmp11;
    d[o + 4 * s] = tmp10 - tmp11;
    final z1 = (tmp12 + tmp13) * 0.707106781;
    d[o + 2 * s] = tmp13 + z1;
    d[o + 6 * s] = tmp13 - z1;
    // Odd part.
    tmp10 = tmp4 + tmp5;
    tmp11 = tmp5 + tmp6;
    tmp12 = tmp6 + tmp7;
    final z5 = (tmp10 - tmp12) * 0.382683433;
    final z2 = 0.541196100 * tmp10 + z5;
    final z4 = 1.306562965 * tmp12 + z5;
    final z3 = tmp11 * 0.707106781;
    final z11 = tmp7 + z3, z13 = tmp7 - z3;
    d[o + 5 * s] = z13 + z2;
    d[o + 3 * s] = z13 - z2;
    d[o + s] = z11 + z4;
    d[o + 7 * s] = z11 - z4;
  }
}
