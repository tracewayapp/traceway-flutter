// Replay images (CONTRACT §4, §14.5): the encoder, the network heuristic,
// where a picture sits in its box, and the pictures a wireframe inlines.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/replay/collection_budget.dart';
import 'package:traceway/src/replay/network_state.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_image_policy.dart';
import 'package:traceway/src/traceway_mask.dart';
import 'package:traceway/src/traceway_options.dart';
import 'package:traceway/src/traceway_screen_capture_mode.dart';
import 'package:traceway/src/traceway_widget.dart';
import 'package:traceway/src/wireframe/vnode.dart';
import 'package:traceway/src/wireframe/wireframe_capture.dart';
import 'package:traceway/src/wireframe/wireframe_image_codec.dart';
import 'package:traceway/src/wireframe/wireframe_images.dart';
import 'package:traceway/src/wireframe/wireframe_recorder.dart';

// ---- pixels ---------------------------------------------------------------------

/// An opaque picture: a diagonal gradient with a white disc, smooth enough
/// that JPEG keeps it close.
Uint8List gradient(int w, int h, {int alpha = 255, bool transparentHalf = false}) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final dx = x - w * 0.7, dy = y - h * 0.3;
      final disc = dx * dx + dy * dy < (min(w, h) * 0.18) * (min(w, h) * 0.18);
      out[i] = disc ? 255 : (x * 255 ~/ max(1, w - 1));
      out[i + 1] = disc ? 255 : (y * 255 ~/ max(1, h - 1));
      out[i + 2] = disc ? 255 : 120;
      out[i + 3] = transparentHalf && x < w ~/ 2 ? 0 : alpha;
    }
  }
  return out;
}

Uint8List noise(int w, int h, int seed) {
  final random = Random(seed);
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = i % 4 == 3 ? 255 : random.nextInt(256);
  }
  return out;
}

Future<ui.Image> imageOf(Uint8List rgba, int w, int h) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// [bytes] decoded by the engine, as straight RGBA.
Future<(Uint8List, int, int)> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data =
      (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  final out = (data.buffer.asUint8List(), image.width, image.height);
  image.dispose();
  codec.dispose();
  return out;
}

/// The mean absolute difference of the color channels.
double meanError(Uint8List a, Uint8List b) {
  var sum = 0;
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if (i % 4 == 3) continue;
    sum += (a[i] - b[i]).abs();
    n++;
  }
  return sum / n;
}

// ---- images in widgets --------------------------------------------------------

/// An image provider that hands out [picture] at once, like a cached one.
class _Picture extends ImageProvider<_Picture> {
  _Picture(this.picture, [this.name = 'picture']);
  final ui.Image picture;
  final String name;

  @override
  Future<_Picture> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_Picture>(this);

  @override
  ImageStreamCompleter loadImage(_Picture key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: picture.clone())));
}

/// A network image that hands out [picture] without the network.
class _Network extends ImageProvider<NetworkImage> implements NetworkImage {
  _Network(this.url, this.picture);

  @override
  final String url;
  final ui.Image picture;

  @override
  double get scale => 1;

  @override
  Map<String, String>? get headers => null;

  @override
  WebHtmlElementStrategy get webHtmlElementStrategy =>
      WebHtmlElementStrategy.never;

  @override
  Future<NetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<NetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(NetworkImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: picture.clone())));
}

final _rootKey = GlobalKey();

Widget _screen(List<Widget> children) => RepaintBoundary(
      key: _rootKey,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      ),
    );

Widget _box(Widget child, {double width = 120, double height = 80}) =>
    SizedBox(width: width, height: height, child: child);

Iterable<VNode> allNodes(VNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* allNodes(c);
  }
}

VNode _capture(WireframeCapture capture, [DateTime? at]) => capture
    .capture(_rootKey.currentContext! as Element, at ?? DateTime.now())!
    .screen!;

List<VNode> _pictureNodes(VNode screen) => allNodes(screen)
    .where((n) => (n.attributes['class'] ?? '').startsWith('im p'))
    .toList();

List<String> _styleRules(VNode screen) => [
      for (final n in screen.children)
        if (n.tag == 'style') n.attributes['_cssText']!,
    ];

/// Captures in the real event loop, where the pictures are made, and
/// waits there until [images] has nothing left to make.
Future<VNode> _captureSettled(
        WidgetTester tester, WireframeCapture capture, WireframeImages images,
        [DateTime? at]) async =>
    (await tester.runAsync(() async {
      final screen = _capture(capture, at);
      for (var i = 0; i < 500 && images.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(images.busy, isFalse, reason: 'pictures still being made');
      return screen;
    }))!;

/// The picture a rule inlines, decoded.
Future<(Uint8List, int, int)> _decodeRule(WidgetTester tester, String rule) async {
  final match =
      RegExp(r'url\(data:image/(jpeg|png);base64,([^)]+)\)').firstMatch(rule)!;
  return (await tester.runAsync(() => decode(base64Decode(match.group(2)!))))!;
}

class _Budget implements ImageBudget {
  _Budget(this.max);
  int max;
  String? session = 's1';
  final Map<String?, int> used = {};

  @override
  String? get sessionId => session;

  @override
  bool hasRoom(String? sessionId) => (used[sessionId] ?? 0) < max;

  @override
  bool admit(String? sessionId, int bytes) {
    final now = used[sessionId] ?? 0;
    if (now + bytes > max) return false;
    used[sessionId] = now + bytes;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encoding', () {
    test('the size: displayed x1, never more pixels than the image, at most 384',
        () {
      expect(WireframeImageEncoding.pixelSize(120, 80, 480, 300), (120, 80));
      // Never larger than what the image has.
      expect(WireframeImageEncoding.pixelSize(400, 250, 160, 100), (160, 100));
      // The longest side at most 384, the shape kept.
      expect(WireframeImageEncoding.pixelSize(800, 400, 4000, 2000), (384, 192));
      expect(WireframeImageEncoding.pixelSize(0.4, 0.4, 10, 10), (1, 1));
      for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
        expect(WireframeImageEncoding.pixelSize(bad, 10, 10, 10), isNull);
      }
      expect(WireframeImageEncoding.maxSide, 384);
      expect(WireframeImageEncoding.alphaMaxSide, 192);
      expect(WireframeImageEncoding.jpegQuality, 0.45);
      expect(WireframeImageEncoding.maxEncodedBytes, 48 * 1024);
      expect(WireframeImageEncoding.pixelsPerLogicalPixel, 1);
    });

    test('JPEG decodes to the picture it encodes, at any size', () async {
      for (final (w, h) in [(64, 40), (17, 9), (1, 1), (384, 256), (33, 130)]) {
        final rgba = gradient(w, h);
        final jpeg = encodeJpeg(rgba, w, h, quality: 45);
        expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
        expect(jpeg.sublist(jpeg.length - 2), [0xFF, 0xD9]);
        final (pixels, dw, dh) = await decode(jpeg);
        expect((dw, dh), (w, h));
        expect(meanError(pixels, rgba), lessThan(w * h < 1000 ? 24 : 10),
            reason: '${w}x$h');
      }
    });

    test('JPEG quality trades size for fidelity', () async {
      final rgba = noise(96, 96, 1);
      final low = encodeJpeg(rgba, 96, 96, quality: 20);
      final mid = encodeJpeg(rgba, 96, 96, quality: 45);
      final high = encodeJpeg(rgba, 96, 96, quality: 90);
      expect(low.length, lessThan(mid.length));
      expect(mid.length, lessThan(high.length));
      final (a, _, _) = await decode(high);
      final (b, _, _) = await decode(low);
      expect(meanError(a, rgba), lessThan(meanError(b, rgba)));
    });

    test('PNG is lossless and keeps alpha', () async {
      final rgba = gradient(40, 24, alpha: 255, transparentHalf: true);
      // Straight alpha: a fully transparent pixel has no color to keep.
      for (var i = 0; i < rgba.length; i += 4) {
        if (rgba[i + 3] == 0) rgba.fillRange(i, i + 3, 0);
      }
      final png = encodePng(rgba, 40, 24);
      final (pixels, w, h) = await decode(png);
      expect((w, h), (40, 24));
      expect(pixels, rgba);
    });

    test('an image with transparency is PNG, at most 192 px, never JPEG',
        () async {
      // 300x200 with alpha: PNG at 192x128, its transparency kept.
      final wide = gradient(300, 200, transparentHalf: true);
      final encoded = encodeReplayPicture(wide, 300, 200)!;
      expect(encoded.mime, 'image/png');
      expect((encoded.width, encoded.height), (192, 128));
      final (pixels, w, h) = await decode(base64Decode(encoded.base64));
      expect((w, h), (192, 128));
      expect(hasAlpha(pixels, w, h), isTrue);
      // Small ones are PNG as they are; big ones too, never over white.
      for (final (w, h) in [(64, 64), (97, 40), (192, 30), (384, 384)]) {
        final picture =
            encodeReplayPicture(gradient(w, h, transparentHalf: true), w, h);
        if (picture == null) continue;
        expect(picture.mime, 'image/png', reason: '${w}x$h');
        expect(max(picture.width, picture.height),
            lessThanOrEqualTo(192), reason: '${w}x$h');
      }
      expect(encodeReplayPicture(gradient(64, 64, transparentHalf: true), 64, 64)!
          .width, 64);
    });

    test('an opaque image is JPEG at any size', () {
      for (final (w, h) in [(8, 8), (64, 40), (300, 200), (384, 256)]) {
        final encoded = encodeReplayPicture(gradient(w, h), w, h)!;
        expect(encoded.mime, 'image/jpeg', reason: '${w}x$h');
        expect((encoded.width, encoded.height), (w, h));
        expect(base64Decode(encoded.base64).length, encoded.byteLength);
      }
      // A shade below opaque from scaling at an edge is not alpha.
      expect(encodeReplayPicture(gradient(8, 8, alpha: 252), 8, 8)!.mime,
          'image/jpeg');
    });

    test('downscaling to fit keeps the shape and weighs color by alpha', () {
      final (out, w, h) = downscaleToFit(gradient(300, 200), 300, 200, 192);
      expect((w, h), (192, 128));
      expect(out.length, 192 * 128 * 4);
      final same = gradient(40, 20);
      expect(downscaleToFit(same, 40, 20, 192).$1, same);
      // A transparent pixel lends no color to its neighbour.
      final two = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 0]);
      final (one, ow, oh) = downscaleToFit(two, 2, 1, 1);
      expect((ow, oh), (1, 1));
      expect(one, [255, 0, 0, 128]);
    });

    test('a picture over 48 KiB is tried once at half size, then dropped', () {
      final big = noise(384, 384, 7);
      expect(encodeJpeg(big, 384, 384, quality: 45).length,
          greaterThan(WireframeImageEncoding.maxEncodedBytes));
      final retried = encodeReplayPicture(big, 384, 384);
      if (retried != null) {
        expect((retried.width, retried.height), (192, 192));
        expect(retried.byteLength,
            lessThanOrEqualTo(WireframeImageEncoding.maxEncodedBytes));
      }
      // Noise that is too big even at half size goes.
      final huge = noise(384, 384, 9);
      final (half, hw, hh) = downscaleHalf(huge, 384, 384);
      if (encodeJpeg(half, hw, hh, quality: 45).length >
          WireframeImageEncoding.maxEncodedBytes) {
        expect(encodeReplayPicture(huge, 384, 384), isNull);
      }
      expect(encodeReplayPicture(Uint8List(3), 1, 1), isNull);
      expect(encodeReplayPicture(Uint8List(0), 0, 0), isNull);
    });

    test('half size averages each 2x2 by alpha, odd sides rounded up', () {
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 255, //
        0, 0, 0, 0, 255, 255, 255, 255, 10, 10, 10, 255,
      ]);
      final (out, w, h) = downscaleHalf(rgba, 3, 2);
      expect((w, h), (2, 1));
      // Red, blue and white, the transparent one left out of the color.
      expect(out.sublist(0, 4), [170, 85, 170, 191]);
      expect(out.sublist(4, 8), [5, 133, 5, 255]);
      expect(hasAlpha(out, 2, 1), isTrue);
      expect(hasAlpha(gradient(4, 4), 4, 4), isFalse);
    });
  });

  group('network', () {
    test('Wi-Fi and Ethernet interfaces are unmetered, cellular ones are not',
        () {
      expect(unmeteredInterfaces(['rmnet_data0', 'wlan0'], 'android'), isTrue);
      expect(unmeteredInterfaces(['eth0'], 'android'), isTrue);
      expect(unmeteredInterfaces(['rmnet_data0', 'ccmni1', 'tun0'], 'android'),
          isFalse);
      expect(unmeteredInterfaces(['pdp_ip0', 'en0'], 'ios'), isTrue);
      expect(unmeteredInterfaces(['pdp_ip0', 'utun3', 'en2'], 'ios'), isFalse);
      expect(unmeteredInterfaces(['en1'], 'macos'), isTrue);
      expect(unmeteredInterfaces(['wlp2s0'], 'linux'), isTrue);
      expect(unmeteredInterfaces(['enp3s0'], 'linux'), isTrue);
      expect(unmeteredInterfaces(['wwan0'], 'linux'), isFalse);
      expect(unmeteredInterfaces(['Wi-Fi'], 'windows'), isTrue);
      expect(unmeteredInterfaces(['Cellular'], 'windows'), isFalse);
      expect(unmeteredInterfaces(['wlan0'], 'fuchsia'), isFalse);
      expect(unmeteredInterfaces(const [], 'android'), isFalse);
    });

    test('metered until known, then the interfaces; stale answers are '
        'looked at again', () async {
      var now = DateTime.utc(2026);
      var up = <String>[];
      var lists = 0;
      final state = NetworkState(
        operatingSystem: 'android',
        interfaces: () async {
          lists++;
          return up;
        },
        now: () => now,
      );
      up = ['wlan0'];
      // Never waits: the first answer is metered, the look is under way.
      expect(state.unmetered(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(state.unmetered(), isTrue);
      expect(lists, 1);
      up = ['rmnet0'];
      now = now.add(const Duration(seconds: 1));
      expect(state.unmetered(), isTrue, reason: 'still fresh');
      expect(lists, 1);
      now = now.add(const Duration(seconds: 2));
      state.unmetered();
      await Future<void>.delayed(Duration.zero);
      expect(state.unmetered(), isFalse);
      expect(lists, 2);
    });

    test('the app\'s callback overrides the interfaces, sync or async', () async {
      var answer = true;
      final sync = NetworkState(
          isUnmetered: () => answer,
          interfaces: () async => ['wlan0'],
          operatingSystem: 'android',
          maxAge: Duration.zero);
      expect(sync.unmetered(), isTrue);
      answer = false;
      expect(sync.unmetered(), isFalse);

      final later = Completer<bool>();
      final async = NetworkState(isUnmetered: () => later.future);
      expect(async.unmetered(), isFalse);
      later.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(async.unmetered(), isTrue);
    });
  });

  group('placement', () {
    // What paintImage itself draws, for every fit and alignment.
    Future<void> check(WidgetTester tester, BoxFit? fit, Alignment alignment,
        {Size box = const Size(120, 80)}) async {
      final picture = (await tester.runAsync(() => imageOf(gradient(48, 30), 48, 30)))!;
      final ro = RenderImage(
          image: picture, fit: fit, alignment: alignment,
          textDirection: TextDirection.ltr);
      ro.layout(BoxConstraints.tight(box));
      final placement = ImagePlacement.of(ro)!;
      final canvas = _DrawSpy();
      paintImage(
          canvas: canvas,
          rect: Offset.zero & box,
          image: picture,
          fit: fit,
          alignment: alignment);
      expect(placement.source, canvas.source, reason: '$fit $alignment');
      expect(placement.destination, canvas.destination, reason: '$fit $alignment');
      ro.dispose();
    }

    testWidgets('is where paintImage draws the image', (tester) async {
      for (final fit in [null, ...BoxFit.values]) {
        for (final alignment in [
          Alignment.center,
          Alignment.topLeft,
          Alignment.bottomRight,
          const Alignment(0.3, -0.6),
        ]) {
          await check(tester, fit, alignment);
          await check(tester, fit, alignment, box: const Size(30, 90));
          await check(tester, fit, alignment, box: const Size(20, 10));
        }
      }
    });

    testWidgets('mirrored in right-to-left, repeated, nothing for no box',
        (tester) async {
      final picture = (await tester.runAsync(() => imageOf(gradient(48, 30), 48, 30)))!;
      final mirrored = RenderImage(
          image: picture.clone(),
          fit: BoxFit.none,
          alignment: AlignmentDirectional.centerStart,
          matchTextDirection: true,
          textDirection: TextDirection.rtl)
        ..layout(BoxConstraints.tight(const Size(100, 30)));
      final m = ImagePlacement.of(mirrored)!;
      expect(m.flip, isTrue);
      // Start is the right in right-to-left.
      expect(m.destination, const Rect.fromLTWH(52, 0, 48, 30));
      final repeated = RenderImage(
          image: picture.clone(),
          repeat: ImageRepeat.repeatX,
          textDirection: TextDirection.ltr)
        ..layout(BoxConstraints.tight(const Size(200, 30)));
      expect(ImagePlacement.of(repeated)!.repeat, ImageRepeat.repeatX);
      final empty = RenderImage(image: picture.clone())
        ..layout(BoxConstraints.tight(Size.zero));
      expect(ImagePlacement.of(empty), isNull);
      for (final ro in [mirrored, repeated, empty]) {
        ro.dispose();
      }
    });
  });

  group('pictures in the wireframe', () {
    late ui.Image photo;

    Future<void> load(WidgetTester tester, {int w = 160, int h = 100}) async {
      photo = (await tester.runAsync(() => imageOf(gradient(w, h), w, h)))!;
    }

    testWidgets(
        'images are inlined when the policy is always: placeholder first, '
        'then the picture as a data:image rule the node names', (tester) async {
      await load(tester);
      await tester.pumpWidget(_screen([
        _box(Image(image: _Picture(photo), fit: BoxFit.cover)),
      ]));
      final images = WireframeImages();
      var ready = 0;
      images.onReady = () => ready++;
      final capture = WireframeCapture()..images = images;
      // The first frame shows the placeholder while the picture is made.
      var screen = await _captureSettled(tester, capture, images);
      expect(allNodes(screen).where((n) => n.attributes['class'] == 'im'),
          hasLength(1));
      expect(_pictureNodes(screen), isEmpty);
      expect(ready, 1);

      screen = _capture(capture);
      final node = _pictureNodes(screen).single;
      expect(node.attributes['class'], 'im p0');
      expect(node.attributes['style'],
          'left:0px;top:0px;width:120px;height:80px;'
          'background-size:120px 80px;background-position:0px 0px;');
      // The picture's id stays: placeholder and picture are one node.
      final rules = _styleRules(screen);
      expect(rules.single,
          startsWith('.im.p0{background:url(data:image/jpeg;base64,'));
      expect(rules.single, endsWith(') center/cover no-repeat}'));
      expect(screen.children.first.tag, 'style');
      // Cover: the middle of the 160x100 image at its displayed size.
      final (pixels, w, h) = await _decodeRule(tester, rules.single);
      expect((w, h), (120, 80));
      expect(pixels.length, 120 * 80 * 4);
    });

    testWidgets('each fit places the picture where Flutter paints it',
        (tester) async {
      await load(tester, w: 48, h: 30);
      await tester.pumpWidget(_screen([
        _box(Image(image: _Picture(photo), fit: BoxFit.contain)),
        _box(Image(image: _Picture(photo), fit: BoxFit.none,
            alignment: Alignment.topLeft)),
        _box(Image(image: _Picture(photo), fit: BoxFit.fill,
            repeat: ImageRepeat.noRepeat), width: 60, height: 20),
        _box(Image(image: _Picture(photo), width: 20,
            repeat: ImageRepeat.repeatX, fit: BoxFit.contain),
            width: 200, height: 20),
      ]));
      final images = WireframeImages();
      final capture = WireframeCapture()..images = images;
      await _captureSettled(tester, capture, images);
      final nodes = _pictureNodes(_capture(capture));
      expect(nodes, hasLength(4));
      String placement(VNode n) => n.attributes['style']!.split(';height:')[1];
      expect(placement(nodes[0]),
          '80px;background-size:120px 75px;background-position:0px 2.5px;');
      expect(placement(nodes[1]),
          '80px;background-size:48px 30px;background-position:0px 0px;');
      expect(placement(nodes[2]),
          '20px;background-size:60px 20px;background-position:0px 0px;');
      // A repeated image tiles from where it sits.
      expect(nodes[3].attributes['style'],
          contains('background-repeat:repeat-x;'));
    });

    testWidgets(
        'wifi on a metered network keeps URL references and placeholders; '
        'unmetered, or always, inlines', (tester) async {
      await load(tester);
      await tester.pumpWidget(_screen([
        _box(Image(image: _Network('https://cdn.test/photo.png', photo))),
        _box(Image(image: _Picture(photo))),
      ]));
      var unmetered = false;
      final images = WireframeImages();
      final capture = WireframeCapture()
        ..images = images
        ..imagePolicy = TracewayImagePolicy.wifi
        ..unmetered = () => unmetered;
      var screen = _capture(capture);
      expect(allNodes(screen).singleWhere((n) => n.tag == 'img').attributes['src'],
          'https://cdn.test/photo.png');
      expect(allNodes(screen).where((n) => n.attributes['class'] == 'im'),
          hasLength(1));
      expect(images.all, isEmpty, reason: 'nothing is made on a metered network');
      expect(jsonEncode(serializeDocument(screen)), isNot(contains('data:image')));

      unmetered = true;
      await _captureSettled(tester, capture, images);
      screen = _capture(capture);
      expect(_pictureNodes(screen), hasLength(2));
      expect(allNodes(screen).where((n) => n.tag == 'img'), isEmpty);
      // The same image at the same size is one picture.
      expect(images.all, hasLength(1));
      expect(_styleRules(screen), hasLength(1));

      // Off: placeholders, no URL, and no picture data left on the page.
      capture.imagePolicy = TracewayImagePolicy.off;
      screen = _capture(capture);
      final json = jsonEncode(serializeDocument(screen));
      expect(json, isNot(contains('data:image')));
      expect(json, isNot(contains('cdn.test')));
      expect(allNodes(screen).where((n) => n.attributes['class'] == 'im'),
          hasLength(2));
    });

    testWidgets('never under a mask', (tester) async {
      await load(tester);
      await tester.pumpWidget(_screen([
        TracewayMask(child: _box(Image(image: _Picture(photo)))),
        KeyedSubtree(
            key: const ValueKey('traceway-mask'),
            child: _box(Image(image: _Network('https://cdn.test/a.png', photo)))),
      ]));
      final images = WireframeImages();
      final capture = WireframeCapture()..images = images;
      await _captureSettled(tester, capture, images);
      final screen = _capture(capture);
      expect(images.all, isEmpty);
      final json = jsonEncode(serializeDocument(screen));
      expect(json, isNot(contains('data:image')));
      expect(json, isNot(contains('cdn.test')));
    });

    testWidgets(
        'one picture per image and size across widgets, the per-session '
        'budget, and a new session', (tester) async {
      await load(tester);
      final budget = _Budget(1 << 20);
      await tester.pumpWidget(_screen([
        _box(Image(image: _Picture(photo, 'a'))),
        _box(Image(image: _Picture(photo, 'b'))),
        _box(Image(image: _Picture(photo, 'c')), width: 60, height: 40),
      ]));
      final images = WireframeImages()..budget = budget;
      final capture = WireframeCapture()..images = images;
      await _captureSettled(tester, capture, images);
      var screen = _capture(capture);
      final classes = _pictureNodes(screen).map((n) => n.attributes['class']);
      // Clones of one decoded image share a picture; another size is another.
      expect(classes, ['im p0', 'im p0', 'im p1']);
      final spent = budget.used['s1']!;
      expect(spent, images.all.fold<int>(0, (sum, p) => sum + p.bytes));

      // A new session counts the pictures it shows again.
      budget.session = 's2';
      screen = _capture(capture);
      expect(_pictureNodes(screen), hasLength(3));
      expect(budget.used['s2'], spent);

      // Past the budget, images fall back.
      budget
        ..session = 's3'
        ..max = 10;
      screen = _capture(capture);
      expect(_pictureNodes(screen), isEmpty);
      expect(allNodes(screen).where((n) => n.attributes['class'] == 'im'),
          hasLength(3));
    });

    testWidgets(
        'a picture that failed for one session\'s budget is made again in the '
        'next session (FLT2-12)', (tester) async {
      await load(tester);
      final budget = _Budget(10);
      await tester.pumpWidget(_screen([_box(Image(image: _Picture(photo, 'a')))]));
      final images = WireframeImages()..budget = budget;
      final capture = WireframeCapture()..images = images;
      await _captureSettled(tester, capture, images);
      var screen = _capture(capture);
      expect(_pictureNodes(screen), isEmpty, reason: 'over the budget of s1');
      expect(images.all.single.failed, isTrue);

      budget
        ..session = 's2'
        ..max = 1 << 20;
      await _captureSettled(tester, capture, images);
      screen = _capture(capture);
      expect(_pictureNodes(screen), hasLength(1),
          reason: 'the same image, still on screen, gets its picture');
      expect(budget.used['s2'], greaterThan(0));
    });

    testWidgets(
        'at most maxPictures: the one shown longest ago makes room, and '
        'styles linger 30 s after their image left', (tester) async {
      final pictures = [
        for (var i = 0; i < 3; i++)
          (await tester.runAsync(() => imageOf(gradient(20 + i, 20), 20 + i, 20)))!,
      ];
      var now = DateTime.utc(2026, 1, 1, 12);
      final images = WireframeImages(maxPictures: 2);
      final capture = WireframeCapture()..images = images;
      Future<VNode> show(int i) async {
        await tester.pumpWidget(_screen([
          _box(Image(image: _Picture(pictures[i], 'p$i')), width: 20, height: 20),
        ]));
        await _captureSettled(tester, capture, images, now);
        now = now.add(const Duration(seconds: 1));
        return _capture(capture, now);
      }

      var screen = await show(0);
      expect(_pictureNodes(screen).single.attributes['class'], 'im p0');
      screen = await show(1);
      // p0 left the screen a second ago: its style is still there.
      expect(_styleRules(screen), hasLength(2));
      screen = await show(2);
      expect(_pictureNodes(screen).single.attributes['class'], 'im p2');
      expect(images.all.map((p) => p.cls), ['p1', 'p2']);
      // Not a permanent stop: the first one comes back as a new picture.
      screen = await show(0);
      expect(_pictureNodes(screen).single.attributes['class'], 'im p3');
      now = now.add(const Duration(seconds: 31));
      screen = _capture(capture, now);
      expect(_styleRules(screen), hasLength(1), reason: 'only the one on screen');
    });

    testWidgets('an image that fails to encode falls back to its URL',
        (tester) async {
      await load(tester);
      await tester.pumpWidget(_screen([
        _box(Image(image: _Network('https://cdn.test/photo.png', photo))),
        _box(Image(image: _Picture(photo, 'memory')), width: 30, height: 30),
      ]));
      final images = WireframeImages(
          encoder: (rgba, w, h) async => throw StateError('encoder'));
      final capture = WireframeCapture()..images = images;
      await _captureSettled(tester, capture, images);
      final screen = _capture(capture);
      expect(images.all.every((p) => p.failed), isTrue);
      expect(allNodes(screen).singleWhere((n) => n.tag == 'img').attributes['src'],
          'https://cdn.test/photo.png');
      expect(allNodes(screen).where((n) => n.attributes['class'] == 'im'),
          hasLength(1));
      expect(capture.lastError, isNull);
    });

    testWidgets('an animated image is not recorded frame by frame',
        (tester) async {
      final frames = [
        for (var i = 0; i < 6; i++)
          (await tester.runAsync(() => imageOf(gradient(16, 16 + i), 16, 16 + i)))!,
      ];
      final images = WireframeImages(encoder: (rgba, w, h) async => null);
      final capture = WireframeCapture()..images = images;
      var now = DateTime.utc(2026);
      for (final frame in frames) {
        await tester.pumpWidget(_screen([
          _box(RawImage(image: frame.clone()), width: 16, height: 16),
        ]));
        _capture(capture, now);
        now = now.add(const Duration(milliseconds: 100));
      }
      expect(images.all.length, lessThanOrEqualTo(4));
      expect(images.all.length, greaterThanOrEqualTo(3));
    });

    testWidgets('a frame starts at most maxNewPerFrame new pictures',
        (tester) async {
      final pictures = [
        for (var i = 0; i < 5; i++)
          (await tester.runAsync(() => imageOf(gradient(10, 10 + i), 10, 10 + i)))!,
      ];
      await tester.pumpWidget(_screen([
        for (final (i, p) in pictures.indexed)
          _box(Image(image: _Picture(p, '$i')), width: 10, height: 10),
      ]));
      final images = WireframeImages(maxNewPerFrame: 2, maxPending: 10);
      final capture = WireframeCapture()..images = images;
      await tester.runAsync(() async {
        _capture(capture);
        expect(images.all, hasLength(2));
        _capture(capture);
        expect(images.all, hasLength(4));
      });
      await _captureSettled(tester, capture, images);
      expect(images.all, hasLength(5));
    });
  });

  group('recorder and client', () {
    testWidgets(
        'a picture that becomes ready is a new frame, and turning images off '
        'drops every frame that showed one', (tester) async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final photo = (await tester.runAsync(() => imageOf(gradient(64, 40), 64, 40)))!;
      await tester.pumpWidget(_screen([_box(Image(image: _Picture(photo)))]));
      final recorder =
          WireframeRecorder(rootKey: _rootKey, maxFrames: 50, now: () => now);
      expect(recorder.imagePolicy, TracewayImagePolicy.wifi);
      recorder.imagePolicy = TracewayImagePolicy.always;
      final start = now;
      await tester.runAsync(() async {
        // Its timers and the pictures run in the real event loop here.
        recorder.start();
        expect(recorder.isSettled, isFalse);
        for (var i = 0; i < 500 && !recorder.isSettled; i++) {
          now = now.add(const Duration(milliseconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      // Taken again once the picture was ready, though the app drew nothing.
      expect(recorder.bufferedFrameCount, 2);
      now = now.add(const Duration(seconds: 1));
      final clip =
          (await recorder.captureRecording('c', since: start, until: now))!;
      expect(jsonEncode(clip.events), contains('data:image/jpeg;base64,'));

      recorder.imagePolicy = TracewayImagePolicy.off;
      await tester.pump(const Duration(milliseconds: 1));
      expect(recorder.bufferedFrameCount, 1);
      now = now.add(const Duration(seconds: 1));
      final off = (await recorder.captureRecording('d', until: now))!;
      expect(jsonEncode(off.events), isNot(contains('data:image')));
      recorder.stop();
    });

    test('the image budget: 4 MiB per session, kept with the replay budget',
        () {
      final budget = CollectionBudget();
      expect(budget.maxImageBytes, 4 * 1024 * 1024);
      expect(budget.hasImageRoom('s1'), isTrue);
      expect(budget.admitImage('s1', 4 * 1024 * 1024 - 10), isTrue);
      expect(budget.admitImage('s1', 11), isFalse);
      expect(budget.admitImage('s1', 10), isTrue);
      expect(budget.hasImageRoom('s1'), isFalse);
      expect(budget.snapshot('s1')['traceway.replay.image_bytes'],
          4 * 1024 * 1024);
      expect(budget.hasImageRoom('s2'), isTrue);
      expect(budget.snapshot('s2')['traceway.replay.image_bytes'], 0);
    });

    testWidgets(
        'the client inlines under wifi when isUnmeteredNetwork says so, and '
        'sessions count the bytes', (tester) async {
      var unmetered = false;
      final app = (await tester.runAsync(() => TracewayClient.initializeForTest(
            'token@https://traceway.test',
            TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              screenCaptureMode: TracewayScreenCaptureMode.wireframe,
              isUnmeteredNetwork: () => unmetered,
            ),
            overrides: TracewayTestOverrides(
              httpClient: MockClient((_) async => http.Response('{}', 200)),
            ),
          )))!;
      final photo = (await tester.runAsync(() => imageOf(gradient(64, 40), 64, 40)))!;
      await tester.pumpWidget(Traceway(
          child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                  alignment: Alignment.topLeft,
                  child: _box(Image(image: _Picture(photo)))))));
      await tester.pump();
      final recorder = app.screenRecorder! as WireframeRecorder;
      expect(recorder.imagePolicy, TracewayImagePolicy.wifi);
      final session = app.currentSessionId;
      // The recorder's timers are the test's; the pictures are made in the
      // real event loop: both are given their turn, and the app draws.
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          tester.binding.scheduleFrame();
          await tester.pump(const Duration(milliseconds: 120));
          if (recorder.isSettled && i > 5) break;
        }
      }
      await settle();
      expect(app.replay.budget.snapshot(session)['traceway.replay.image_bytes'],
          0);
      unmetered = true;
      // The answer is looked at again after 2 s.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2100)));
      await settle();
      final clip = (await tester.runAsync(() => recorder.captureRecording('c')))!;
      expect(jsonEncode(clip.events), contains('data:image/jpeg;base64,'));
      expect(app.replay.budget.snapshot(session)['traceway.replay.image_bytes'],
          greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    });
  });
}

/// A canvas that keeps the image rectangle paintImage draws.
class _DrawSpy implements Canvas {
  Rect? source, destination;

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    source = src;
    destination = dst;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
