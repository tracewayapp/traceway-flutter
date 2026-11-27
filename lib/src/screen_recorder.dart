import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';

import 'circular_buffer.dart';
import 'replay/replay_source.dart';
import 'traceway_mask_mode.dart';
import 'traceway_mask.dart';

class CapturedFrame {
  final Uint8List pngBytes;
  final int width;
  final int height;
  final DateTime timestamp;
  final Offset? touchPosition;
  final List<MaskRegion> maskRegions;

  const CapturedFrame({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.timestamp,
    this.touchPosition,
    this.maskRegions = const [],
  });
}

/// Turns RGBA frames into an MP4 file. The platform implementation uses the
/// device's hardware H.264 encoder.
abstract class VideoEncoder {
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required String filepath,
    required bool debug,
  });
  Future<void> appendFrame(Uint8List rgba);
  Future<void> finish();
}

class PlatformVideoEncoder implements VideoEncoder {
  const PlatformVideoEncoder();

  @override
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required String filepath,
    required bool debug,
  }) async {
    // Standard verbosity prints twice per frame into the app's breadcrumb buffer.
    await FlutterQuickVideoEncoder.setLogLevel(
      debug ? LogLevel.error : LogLevel.none,
    );
    await FlutterQuickVideoEncoder.setup(
      width: width,
      height: height,
      fps: fps,
      videoBitrate: 2000000,
      profileLevel: ProfileLevel.baselineAutoLevel,
      audioChannels: 0,
      audioBitrate: 0,
      sampleRate: 0,
      filepath: filepath,
    );
  }

  @override
  Future<void> appendFrame(Uint8List rgba) =>
      FlutterQuickVideoEncoder.appendVideoFrame(rgba);

  @override
  Future<void> finish() => FlutterQuickVideoEncoder.finish();
}

class ScreenRecorder with WidgetsBindingObserver implements ReplaySource {
  /// Replaces the platform encoder, for platforms it does not support and
  /// for tests.
  @visibleForTesting
  static VideoEncoder? encoderOverride;

  /// Whether clips can be encoded here: the hardware encoder exists on
  /// Android, iOS and macOS. Elsewhere the SDK records no frames at all.
  static bool get isVideoSupported {
    if (encoderOverride != null) return true;
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  final GlobalKey repaintBoundaryKey;
  final double pixelRatio;
  final int fps;
  final CircularBuffer<CapturedFrame> _buffer;
  final bool debug;

  late final int _captureIntervalMs = 1000 ~/ fps;

  /// The longest video a clip makes, in seconds. Every frame is shown for
  /// as long as it was on screen, so frames captured slowly, or minutes in
  /// the background between two of them, make a clip longer than the ring
  /// buffer's nominal length, and every encoder frame, a repeat too, costs
  /// a copy of the whole picture. Past this the clip keeps its end; see
  /// [_holds].
  static const int maxClipSeconds = 60;

  /// Encoder frames a clip has at most: never fewer than the ring holds, so
  /// frames captured on time always fit.
  late final int _maxEncodedFrames = max(_buffer.capacity, maxClipSeconds * fps);

  Timer? _captureTimer;
  bool _isCapturing = false;
  bool _isPaused = false;

  // Serializes encoding — FlutterQuickVideoEncoder is a singleton native
  // resource, so concurrent captureRecording calls must wait their turn.
  Future<void> _encodingLock = Future.value();

  // Touch tracking (logical coordinates)
  Offset? _touchPosition;

  ScreenRecorder({
    required this.repaintBoundaryKey,
    required int maxFrames,
    this.pixelRatio = 0.5,
    this.fps = 15,
    this.debug = false,
  }) : _buffer = CircularBuffer<CapturedFrame>(maxFrames);

  void setTouchPosition(Offset position) {
    _touchPosition = position;
  }

  void clearTouchPosition() {
    _touchPosition = null;
  }

  @override
  bool get isRunning => _captureTimer != null;

  /// Forgets every buffered frame, e.g. when replay is switched off remotely.
  @override
  void clearBuffer() => _buffer.clear();

  @override
  void start() {
    if (_captureTimer != null) return;
    WidgetsBinding.instance.addObserver(this);
    // Changes while stopped were not observed: the app may have gone to
    // the background, or come back, since.
    _isPaused = _pausedIn(WidgetsBinding.instance.lifecycleState);
    _captureTimer = Timer.periodic(
      Duration(milliseconds: _captureIntervalMs),
      (_) => _captureFrame(),
    );
    if (debug) {
      print('Traceway: screen recorder started (${fps}fps, ${pixelRatio}x)');
    }
  }

  @override
  void stop() {
    _captureTimer?.cancel();
    _captureTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isPaused = _pausedIn(state);
  }

  /// Whether no frames are captured in [state]: whenever the app is not in
  /// the foreground. Before the platform reports a state there is none,
  /// and the app is on screen.
  static bool _pausedIn(AppLifecycleState? state) =>
      state != null && state != AppLifecycleState.resumed;

  Future<void> _captureFrame() async {
    if (_isCapturing || _isPaused) return;

    final context = repaintBoundaryKey.currentContext;
    if (context == null) return;

    final boundary = context.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;

    _isCapturing = true;
    try {
      // Read in the same turn as the picture is taken, so every mask is
      // where its widget is in this frame.
      final maskRegions = maskRegionsIn(context);
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final width = image.width;
      final height = image.height;
      ByteData? byteData;
      try {
        byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }

      if (byteData != null) {
        _buffer.push(CapturedFrame(
          pngBytes: byteData.buffer.asUint8List(),
          width: width,
          height: height,
          timestamp: DateTime.now(),
          touchPosition: _touchPosition,
          maskRegions: maskRegions,
        ));
      }
    } catch (e) {
      if (debug) {
        print('Traceway: frame capture error: $e');
      }
    } finally {
      _isCapturing = false;
    }
  }

  /// Decodes a PNG frame to raw RGBA pixels.
  Future<Uint8List> _decodePngToRgba(Uint8List pngBytes, int width, int height) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return byteData!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// Draws a blue (#4ba3f7) circle onto raw RGBA pixel data at the touch position.
  void _drawTouchCircle(Uint8List pixels, int width, int height, Offset logicalPos) {
    final cx = (logicalPos.dx * pixelRatio).round();
    final cy = (logicalPos.dy * pixelRatio).round();

    const radius = 18;
    const borderWidth = 3;
    const innerRadius = radius - borderWidth;

    // #4ba3f7 = R:75, G:163, B:247
    const int circleR = 75;
    const int circleG = 163;
    const int circleB = 247;

    final minX = max(0, cx - radius);
    final maxX = min(width - 1, cx + radius);
    final minY = max(0, cy - radius);
    final maxY = min(height - 1, cy + radius);

    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final dx = x - cx;
        final dy = y - cy;
        final distSq = dx * dx + dy * dy;

        if (distSq > radius * radius) continue;

        final offset = (y * width + x) * 4;

        int alpha;
        if (distSq > innerRadius * innerRadius) {
          alpha = 200;
        } else {
          alpha = 80;
        }

        final a = alpha / 255.0;
        final invA = 1.0 - a;
        pixels[offset + 0] = (circleR * a + pixels[offset + 0] * invA).round();
        pixels[offset + 1] = (circleG * a + pixels[offset + 1] * invA).round();
        pixels[offset + 2] = (circleB * a + pixels[offset + 2] * invA).round();
      }
    }
  }

  /// The pixels of a frame a logical rectangle covers: left, top, right and
  /// bottom, the last two exclusive. Rounded outwards, so a mask never ends
  /// short of its widget; empty when the rectangle is outside the frame.
  (int, int, int, int) _pixelRect(Rect logicalRect, int width, int height) => (
        (logicalRect.left * pixelRatio).floor().clamp(0, width),
        (logicalRect.top * pixelRatio).floor().clamp(0, height),
        (logicalRect.right * pixelRatio).ceil().clamp(0, width),
        (logicalRect.bottom * pixelRatio).ceil().clamp(0, height),
      );

  /// Pixelates a rectangular region by averaging NxN blocks of pixels.
  void _applyPixelation(
    Uint8List pixels, int width, int height, Rect logicalRect, double ratio,
  ) {
    final (left, top, right, bottom) = _pixelRect(logicalRect, width, height);

    final blockSize = max(2, (ratio * 20).round());

    for (var by = top; by < bottom; by += blockSize) {
      for (var bx = left; bx < right; bx += blockSize) {
        final bw = min(blockSize, right - bx);
        final bh = min(blockSize, bottom - by);
        final count = bw * bh;
        if (count == 0) continue;

        int sumR = 0, sumG = 0, sumB = 0, sumA = 0;
        for (var y = by; y < by + bh; y++) {
          for (var x = bx; x < bx + bw; x++) {
            final offset = (y * width + x) * 4;
            sumR += pixels[offset];
            sumG += pixels[offset + 1];
            sumB += pixels[offset + 2];
            sumA += pixels[offset + 3];
          }
        }

        final avgR = sumR ~/ count;
        final avgG = sumG ~/ count;
        final avgB = sumB ~/ count;
        final avgA = sumA ~/ count;

        for (var y = by; y < by + bh; y++) {
          for (var x = bx; x < bx + bw; x++) {
            final offset = (y * width + x) * 4;
            pixels[offset] = avgR;
            pixels[offset + 1] = avgG;
            pixels[offset + 2] = avgB;
            pixels[offset + 3] = avgA;
          }
        }
      }
    }
  }

  /// Fills a rectangular region with a solid color.
  void _applyBlank(
    Uint8List pixels, int width, int height, Rect logicalRect, ui.Color color,
  ) {
    final (left, top, right, bottom) = _pixelRect(logicalRect, width, height);

    final r = (color.r * 255.0).round().clamp(0, 255);
    final g = (color.g * 255.0).round().clamp(0, 255);
    final b = (color.b * 255.0).round().clamp(0, 255);
    final a = (color.a * 255.0).round().clamp(0, 255);

    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final offset = (y * width + x) * 4;
        pixels[offset] = r;
        pixels[offset + 1] = g;
        pixels[offset + 2] = b;
        pixels[offset + 3] = a;
      }
    }
  }

  /// Number of frames currently held; never more than the buffer capacity.
  int get bufferedFrameCount => _buffer.length;

  /// Adds [frame] to the ring as if it had been captured.
  @visibleForTesting
  void addFrame(CapturedFrame frame) => _buffer.push(frame);

  /// How many encoder frames each of [frames] is shown for, so the video
  /// plays at the app's speed: a frame until the next one was taken, the
  /// last one until [end], each at least once. Counted from the first
  /// frame, so rounding does not add up along the clip.
  ///
  /// A clip is at most [_maxEncodedFrames] long. Over that, the last frame
  /// is held for less, then the earliest frames are left out: the frames
  /// captured last, nearest to what asked for the clip, are kept. Returns
  /// the index of the first frame encoded and the holds of it and of every
  /// frame after it.
  (int, List<int>) _holds(List<CapturedFrame> frames, DateTime end) {
    final frameMs = 1000 / fps;
    final origin = frames.first.timestamp;
    final holds = <int>[];
    var encoded = 0;
    for (var i = 0; i < frames.length; i++) {
      final shownUntil =
          i + 1 < frames.length ? frames[i + 1].timestamp : end;
      final at = (shownUntil.difference(origin).inMilliseconds / frameMs).round();
      final hold = max(1, at - encoded);
      holds.add(hold);
      encoded += hold;
    }
    var first = 0;
    var beforeLast = encoded - holds.last;
    while (first < frames.length - 1 && beforeLast + 1 > _maxEncodedFrames) {
      beforeLast -= holds[first++];
    }
    holds.last = min(holds.last, _maxEncodedFrames - beforeLast);
    return (first, holds.sublist(first));
  }

  static bool _inWindow(CapturedFrame frame, DateTime? since, DateTime? until) =>
      (since == null || !frame.timestamp.isBefore(since)) &&
      (until == null || frame.timestamp.isBefore(until));

  @override
  bool hasFrames({DateTime? since, DateTime? until}) =>
      _buffer.readAll().any((f) => _inWindow(f, since, until));

  /// Encodes the buffered frames captured at or after [since] and before
  /// [until] to MP4. The clip can never hold more frames than the frame
  /// ring buffer; each is shown for as long as it was on screen, the last
  /// one until [until], so the video keeps the session's time.
  /// The frames are chosen when this is called, before it waits for an
  /// earlier encode to finish.
  @override
  Future<SessionRecordingPayload?> captureRecording(
    String clipId, {
    DateTime? since,
    DateTime? until,
  }) async {
    final window =
        _buffer.readAll().where((f) => _inWindow(f, since, until)).toList();
    if (window.isEmpty) return null;
    final (first, holds) = _holds(window, until ?? window.last.timestamp);
    final frames = window.sublist(first);
    final encodedFrames = holds.fold<int>(0, (sum, n) => sum + n);
    final durationSeconds = encodedFrames / fps;
    final startedAt = frames.first.timestamp;
    final endedAt = startedAt
        .add(Duration(microseconds: (durationSeconds * 1000000).round()));

    final previous = _encodingLock;
    final completer = Completer<void>();
    _encodingLock = completer.future;
    await previous;

    File? videoFile;
    try {
      // Find max dimensions across all frames so the encoder can handle
      // screen size changes (rotation, keyboard, navigation bar).
      int maxWidth = 0;
      int maxHeight = 0;
      for (final f in frames) {
        if (f.width > maxWidth) maxWidth = f.width;
        if (f.height > maxHeight) maxHeight = f.height;
      }

      // H.264 requires even dimensions. Round up to nearest even number.
      if (maxWidth.isOdd) maxWidth++;
      if (maxHeight.isOdd) maxHeight++;

      final tempDir = await getTemporaryDirectory();
      final outputPath = '${tempDir.path}/traceway_$clipId.mp4';
      videoFile = File(outputPath);

      final encoder = encoderOverride ?? const PlatformVideoEncoder();
      await encoder.setup(
        width: maxWidth,
        height: maxHeight,
        fps: fps,
        filepath: outputPath,
        debug: debug,
      );

      // Decode each PNG → RGBA, apply masks, draw touch circle, feed to encoder.
      // Frames smaller than maxWidth×maxHeight are padded with dark grey.
      final canvasSize = maxWidth * maxHeight * 4;
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        final rgba = await _decodePngToRgba(frame.pngBytes, frame.width, frame.height);

        for (final region in frame.maskRegions) {
          switch (region.mode) {
            case TracewayMaskBlur(:final ratio):
              _applyPixelation(rgba, frame.width, frame.height, region.rect, ratio);
            case TracewayMaskBlank(:final color):
              _applyBlank(rgba, frame.width, frame.height, region.rect, color);
          }
        }

        if (frame.touchPosition != null) {
          _drawTouchCircle(rgba, frame.width, frame.height, frame.touchPosition!);
        }

        // Pad to encoder dimensions if this frame is smaller.
        Uint8List output;
        if (frame.width == maxWidth && frame.height == maxHeight) {
          output = rgba;
        } else {
          // Dark grey background (30, 30, 30, 255).
          output = Uint8List(canvasSize);
          for (var i = 0; i < canvasSize; i += 4) {
            output[i] = 30;
            output[i + 1] = 30;
            output[i + 2] = 30;
            output[i + 3] = 255;
          }
          // Copy original frame rows into top-left corner.
          for (var y = 0; y < frame.height; y++) {
            final srcOffset = y * frame.width * 4;
            final dstOffset = y * maxWidth * 4;
            output.setRange(dstOffset, dstOffset + frame.width * 4,
                rgba, srcOffset);
          }
        }

        // A frame on screen for longer is the same picture again, built
        // once.
        for (var n = 0; n < holds[i]; n++) {
          await encoder.appendFrame(output);
        }
      }

      await encoder.finish();

      final videoBytes = await videoFile.readAsBytes();
      final base64Video = base64Encode(videoBytes);

      if (debug) {
        final bufferKB = frames.fold<int>(0, (sum, f) => sum + f.pngBytes.length) ~/ 1024;
        print('Traceway: encoded ${frames.length} frames as $encodedFrames (buffer: ${bufferKB}KB) to ${videoBytes.length ~/ 1024}KB MP4 (${durationSeconds.toStringAsFixed(1)}s)');
      }

      return SessionRecordingPayload(
        clipId: clipId,
        events: [
          {
            'type': 'flutter_video',
            'data': base64Video,
            'format': 'mp4',
            'fps': fps,
            'durationSeconds': durationSeconds,
          }
        ],
        // The span the video plays: from its first frame for as long as it
        // runs.
        startedAt: startedAt,
        endedAt: endedAt,
      );
    } catch (e) {
      if (debug) {
        print('Traceway: recording encoding error: $e');
      }
      return null;
    } finally {
      // Also after an encode that failed half way: the file is not left in
      // the app's temporary directory.
      try {
        if (videoFile != null && await videoFile.exists()) {
          await videoFile.delete();
        }
      } catch (_) {}
      completer.complete();
    }
  }
}
