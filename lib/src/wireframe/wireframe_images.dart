import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show RenderImage;

import '../guarded.dart';
import 'vnode.dart';
import 'wireframe_image_codec.dart';

/// How much of its replay image budget a session has left.
abstract interface class ImageBudget {
  /// The session pictures are counted against now.
  String? get sessionId;

  /// Whether [sessionId] may still record a picture.
  bool hasRoom(String? sessionId);

  /// Counts [bytes] of encoded image data against [sessionId]; false when
  /// they do not fit.
  bool admit(String? sessionId, int bytes);
}

/// Encodes a picture's pixels; the default runs [encodeReplayPicture] in a
/// background isolate.
typedef PictureEncoder = Future<EncodedPicture?> Function(
    Uint8List rgba, int width, int height);

Future<EncodedPicture?> _encodeInIsolate(
        Uint8List rgba, int width, int height) =>
    Isolate.run(() => encodeReplayPicture(rgba, width, height),
        debugName: 'traceway replay image');

/// One picture recorded into the wireframe: the class the nodes showing it
/// carry and, once encoded, the rule that draws it.
class WireframePicture {
  WireframePicture._(this.cls, this._source, this.key, this.addedAt);

  final String cls;
  final WeakReference<ui.Image> _source;

  /// What else than the image it depends on: size, part, tint.
  final String key;
  final DateTime addedAt;

  /// `.im.p<N>{background:url(data:…) center/cover no-repeat}` once encoded.
  String? css;

  /// Encoding failed, it was too big or over the budget: the image falls
  /// back to its URL or the placeholder.
  bool failed = false;

  /// Encoded bytes, counted against [session]'s budget.
  int bytes = 0;
  String? session;

  /// The style node that holds [css] in the replay.
  int? styleId;
  VNode? node;
  DateTime? lastShown;
  bool _evicted = false;
}

/// The pictures of the images the app shows, inlined into the wireframe as
/// the replay image policy allows (`replay.images` under
/// `TracewayOptions.replayImages`): the decoded image of a `RenderImage`
/// (network, asset, memory, file), never a screenshot, never under a mask.
///
/// The first frame that shows an image records, on the UI isolate, a
/// picture of what the image paints: the part of the image its fit and
/// alignment show, its tint and mirroring, at its displayed size (one pixel
/// per logical pixel, longest side at most 384, never more pixels than the
/// image has). The raster thread draws it (`Picture.toImage`), and a
/// background isolate encodes it (see [WireframeImageEncoding]). Until then
/// the image shows what it would without pictures (its URL or the `.im`
/// placeholder); then a style node first in the screen holds
/// `.im.p<N>{background:url(data:…) center/cover no-repeat}`, which the
/// image's node names with the classes `im p<N>` and places with an inline
/// `background-size` and `background-position`. The same image at the same
/// size is one picture however many images show it.
///
/// At most [maxPictures] are kept; past that the one shown longest ago
/// makes room. Each picture's bytes count against the session's
/// [ImageBudget] (4 MiB); past it, images fall back.
class WireframeImages {
  WireframeImages({
    this.maxPictures = 128,
    this.maxNewPerFrame = 8,
    this.maxPending = 4,
    PictureEncoder? encoder,
  }) : _encoder = encoder ?? _encodeInIsolate;

  final int maxPictures;

  /// New pictures one frame records at most; others wait for a later one.
  final int maxNewPerFrame;

  /// Pictures being drawn or encoded at most.
  final int maxPending;
  final PictureEncoder _encoder;

  /// How long a picture's style stays on the page after it left the
  /// screen, so one that comes back does not send it again.
  static const linger = Duration(seconds: 30);

  /// Called when a picture is ready, so the next frame can use it.
  void Function()? onReady;

  /// The session's image budget; null records pictures without one.
  ImageBudget? budget;

  final List<WireframePicture> all = [];
  final Set<WireframePicture> shown = {};
  final Expando<List<WireframePicture>> _bySource =
      Expando('traceway replay pictures');
  int _next = 0;
  int _newThisFrame = 0;
  int _pending = 0;
  DateTime _now = DateTime.fromMillisecondsSinceEpoch(0);
  String? _session;

  /// Whether a picture is being drawn or encoded.
  bool get busy => _pending > 0;

  /// Starts a frame captured at [now].
  void beginCapture(DateTime now) {
    _now = now;
    _newThisFrame = 0;
    shown.clear();
    final session = guardedOr('image budget', null, () => budget?.sessionId);
    if (session != _session) {
      // A new session: what failed for the budget may fit in its own. The
      // failed pictures go for good, so the images they were made for are
      // made again, not found failed.
      _session = session;
      for (final p in all) {
        if (p.failed) p._evicted = true;
      }
      all.removeWhere((p) => p.failed);
    }
  }

  /// The picture of [image] for [key] to show in this frame: null while it
  /// is drawn and encoded, or when it cannot be (none yet: [record] draws
  /// it, at [width] x [height] pixels).
  WireframePicture? lookup(ui.Image image, String key, int width, int height,
      ui.Picture Function() record) {
    var picture = _find(image, key);
    if (picture == null) {
      final b = budget;
      if (b != null &&
          !guardedOr('image budget', false, () => b.hasRoom(_session))) {
        return null;
      }
      if (_newThisFrame >= maxNewPerFrame || _pending >= maxPending) {
        return null;
      }
      if (all.length >= maxPictures && !_evictOldest()) return null;
      _newThisFrame++;
      picture = WireframePicture._('p${_next++}', WeakReference(image), key, _now);
      all.add(picture);
      (_bySource[image] ??= []).add(picture);
      final ui.Picture recorded;
      try {
        recorded = record();
      } catch (_) {
        picture.failed = true;
        return null;
      }
      unawaited(_encode(picture, recorded, width, height));
      return null;
    }
    if (picture.failed || picture.css == null) return null;
    final b = budget;
    if (b != null && picture.session != _session) {
      // Shown again in a new session: counted against its budget too.
      if (!guardedOr('image budget', false, () => b.admit(_session, picture!.bytes))) {
        return null;
      }
      picture.session = _session;
    }
    shown.add(picture);
    picture.lastShown = _now;
    return picture;
  }

  WireframePicture? _find(ui.Image image, String key) {
    final own = _bySource[image];
    if (own != null) {
      for (final p in own) {
        if (p.key == key && !p._evicted) return p;
      }
    }
    // Another handle of the same decoded image (the same photo in many
    // cells of a list).
    for (final p in all) {
      if (p.key != key) continue;
      final source = p._source.target;
      if (source != null && !identical(source, image) && source.isCloneOf(image)) {
        (_bySource[image] ??= []).add(p);
        return p;
      }
    }
    return null;
  }

  /// Forgets the picture shown longest ago that is not on screen now, to
  /// make room; false when every picture is on screen.
  bool _evictOldest() {
    WireframePicture? oldest;
    for (final p in all) {
      if (shown.contains(p)) continue;
      final at = p.lastShown ?? p.addedAt;
      if (oldest == null || at.isBefore(oldest.lastShown ?? oldest.addedAt)) {
        oldest = p;
      }
    }
    if (oldest == null) return false;
    oldest._evicted = true;
    all.remove(oldest);
    return true;
  }

  /// The pictures whose styles are on the page in a frame taken at [now]:
  /// ready, and shown in the last [linger].
  Iterable<WireframePicture> lingering(DateTime now) => all.where((p) {
        final shownAt = p.lastShown;
        return p.css != null &&
            !p.failed &&
            shownAt != null &&
            now.difference(shownAt) <= linger;
      });

  Future<void> _encode(
      WireframePicture picture, ui.Picture recorded, int width, int height) async {
    _pending++;
    try {
      final ui.Image raster;
      try {
        raster = await recorded.toImage(width, height);
      } finally {
        recorded.dispose();
      }
      final ByteData? data;
      try {
        data = await raster.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      } finally {
        raster.dispose();
      }
      if (data == null) {
        picture.failed = true;
        return;
      }
      final encoded = await _encoder(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          width,
          height);
      if (encoded == null || picture._evicted) {
        if (encoded == null) {
          debugOnce(
              'picture size',
              () => 'Traceway: replay picture dropped: over '
                  '${WireframeImageEncoding.maxEncodedBytes ~/ 1024} KiB after '
                  'the half-size retry');
        }
        picture.failed = true;
        return;
      }
      final b = budget;
      final session = _session;
      if (b != null && !b.admit(session, encoded.byteLength)) {
        debugOnce(
            'picture budget',
            () => "Traceway: replay picture dropped: the session's "
                '4 MiB of pictures is used up');
        picture.failed = true;
        return;
      }
      picture
        ..session = session
        ..bytes = encoded.byteLength
        ..css = '.im.${picture.cls}{background:url(data:${encoded.mime};'
            'base64,${encoded.base64}) center/cover no-repeat}';
      guarded('image ready', () => onReady?.call());
    } catch (_) {
      // Out of memory, an image the engine cannot draw, an encoder that
      // failed: this image falls back, the frame and the session go on.
      picture.failed = true;
    } finally {
      _pending--;
    }
  }
}

/// Where a `RenderImage` paints its image inside its box, as `paintImage`
/// computes it: [destination] in the box (logical pixels), [source] in the
/// image (pixels), whether it is mirrored and how it repeats.
class ImagePlacement {
  ImagePlacement._(this.destination, this.source, this.flip, this.repeat,
      this.centerSlice, this.scale);

  final Rect destination;
  final Rect source;
  final bool flip;
  final ImageRepeat repeat;
  final Rect? centerSlice;
  final double scale;

  /// The placement of [ro]'s image, or null when it paints nothing.
  static ImagePlacement? of(RenderImage ro) {
    final image = ro.image;
    if (image == null || !ro.hasSize) return null;
    final size = ro.size;
    if (size.isEmpty) return null;
    final scale = ro.scale;
    final centerSlice = ro.centerSlice;
    final direction = ro.textDirection;
    final alignment = ro.alignment.resolve(direction);
    final flip = ro.matchTextDirection && direction == TextDirection.rtl;
    var outputSize = size;
    var inputSize = Size(image.width.toDouble(), image.height.toDouble());
    Offset? sliceBorder;
    if (centerSlice != null) {
      sliceBorder = inputSize / scale - centerSlice.size as Offset;
      outputSize = outputSize - sliceBorder as Size;
      inputSize = inputSize - sliceBorder * scale as Size;
      if (outputSize.width <= 0 || outputSize.height <= 0) return null;
    }
    final fit = ro.fit ?? (centerSlice == null ? BoxFit.scaleDown : BoxFit.fill);
    final fitted = applyBoxFit(fit, inputSize / scale, outputSize);
    final sourceSize = fitted.source * scale;
    var destinationSize = fitted.destination;
    if (centerSlice != null) {
      outputSize += sliceBorder!;
      destinationSize += sliceBorder;
    }
    var repeat = ro.repeat;
    if (repeat != ImageRepeat.noRepeat && destinationSize == outputSize) {
      repeat = ImageRepeat.noRepeat;
    }
    // Mirrored, paintImage aligns the other way and flips the canvas: on
    // screen the image is where the alignment says, mirrored.
    final halfWidth = (outputSize.width - destinationSize.width) / 2;
    final halfHeight = (outputSize.height - destinationSize.height) / 2;
    final destination = Offset(halfWidth + alignment.x * halfWidth,
            halfHeight + alignment.y * halfHeight) &
        destinationSize;
    final source = centerSlice == null
        ? alignment.inscribe(sourceSize, Offset.zero & inputSize)
        : Offset.zero & Size(image.width.toDouble(), image.height.toDouble());
    if (destination.isEmpty || source.isEmpty) return null;
    return ImagePlacement._(
        destination, source, flip, repeat, centerSlice, scale);
  }

  /// What the picture depends on besides the image, at [width] x [height].
  String key(int width, int height, RenderImage ro) =>
      '${width}x$height|${_r(source)}|$flip|${ro.color?.toARGB32()}|'
      '${ro.colorBlendMode?.index}|${ro.invertColors}|${centerSlice == null ? '' : _r(centerSlice!)}';

  static String _r(Rect r) => '${r.left.toStringAsFixed(1)},'
      '${r.top.toStringAsFixed(1)},${r.width.toStringAsFixed(1)},'
      '${r.height.toStringAsFixed(1)}';

  /// A picture of what [ro] paints of [image] in [destination], at
  /// [width] x [height] pixels: recorded now, drawn later.
  ui.Picture record(RenderImage ro, ui.Image image, int width, int height) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..invertColors = ro.invertColors;
    final color = ro.color;
    if (color != null) {
      paint.colorFilter =
          ColorFilter.mode(color, ro.colorBlendMode ?? BlendMode.srcIn);
    }
    if (flip) {
      canvas
        ..translate(width.toDouble(), 0)
        ..scale(-1, 1);
    }
    final out = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final slice = centerSlice;
    if (slice == null) {
      canvas.drawImageRect(image, source, out, paint);
    } else {
      // Nine-patch: the edges keep their size relative to the box.
      canvas
        ..scale(width / destination.width, height / destination.height)
        ..scale(1 / scale);
      canvas.drawImageNine(
          image,
          Rect.fromLTRB(slice.left * scale, slice.top * scale,
              slice.right * scale, slice.bottom * scale),
          Rect.fromLTWH(0, 0, destination.width * scale,
              destination.height * scale),
          paint);
    }
    return recorder.endRecording();
  }
}
