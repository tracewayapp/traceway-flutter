import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';

import 'circular_buffer.dart';
import 'models/session_recording_payload.dart';
import 'traceway_mask_mode.dart';

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

class ScreenRecorder with WidgetsBindingObserver {
  final GlobalKey repaintBoundaryKey;
  final double pixelRatio;
  final int fps;
  final CircularBuffer<CapturedFrame> _buffer;
  final bool debug;

  late final int _captureIntervalMs = 1000 ~/ fps;

  Timer? _captureTimer;
  bool _isCapturing = false;
  bool _isPaused = false;

  // Serializes encoding — FlutterQuickVideoEncoder is a singleton native
  // resource, so concurrent captureRecording calls must wait their turn.
  Future<void> _encodingLock = Future.value();

  // Touch tracking (logical coordinates)
  Offset? _touchPosition;

  // Privacy mask tracking (logical coordinates, relative to RepaintBoundary)
  final Map<Key, MaskRegion> _maskRegions = {};

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

  void addMaskRegion(Key key, Rect rect, TracewayMaskMode mode) {
    _maskRegions[key] = MaskRegion(key: key, rect: rect, mode: mode);
  }

  void removeMaskRegion(Key key) {
    _maskRegions.remove(key);
  }

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _captureTimer = Timer.periodic(
      Duration(milliseconds: _captureIntervalMs),
      (_) => _captureFrame(),
    );
    if (debug) {
      print('Traceway: screen recorder started (${fps}fps, ${pixelRatio}x)');
    }
  }

  void stop() {
    _captureTimer?.cancel();
    _captureTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isPaused = state != AppLifecycleState.resumed;
  }

  Future<void> _captureFrame() async {
    if (_isCapturing || _isPaused) return;

    final context = repaintBoundaryKey.currentContext;
    if (context == null) return;

    final boundary = context.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;

    _isCapturing = true;
    try {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final width = image.width;
      final height = image.height;
      image.dispose();

      if (byteData != null) {
        _buffer.push(CapturedFrame(
          pngBytes: byteData.buffer.asUint8List(),
          width: width,
          height: height,
          timestamp: DateTime.now(),
          touchPosition: _touchPosition,
          maskRegions: _maskRegions.values.toList(),
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
    final frameInfo = await codec.getNextFrame();
    final image = frameInfo.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    return byteData!.buffer.asUint8List();
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

  /// Pixelates a rectangular region by averaging NxN blocks of pixels.
  void _applyPixelation(
    Uint8List pixels, int width, int height, Rect logicalRect, double ratio,
  ) {
    final left = (logicalRect.left * pixelRatio).round().clamp(0, width - 1);
    final top = (logicalRect.top * pixelRatio).round().clamp(0, height - 1);
    final right = (logicalRect.right * pixelRatio).round().clamp(0, width);
    final bottom = (logicalRect.bottom * pixelRatio).round().clamp(0, height);

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
    final left = (logicalRect.left * pixelRatio).round().clamp(0, width - 1);
    final top = (logicalRect.top * pixelRatio).round().clamp(0, height - 1);
    final right = (logicalRect.right * pixelRatio).round().clamp(0, width);
    final bottom = (logicalRect.bottom * pixelRatio).round().clamp(0, height);

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

  Future<SessionRecordingPayload?> captureRecording(
    String exceptionId,
  ) async {
    final frames = _buffer.readAll();
    if (frames.isEmpty) return null;

    final previous = _encodingLock;
    final completer = Completer<void>();
    _encodingLock = completer.future;
    await previous;

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

      final durationSeconds = frames.length * _captureIntervalMs / 1000.0;

      final tempDir = await getTemporaryDirectory();
      final outputPath = '${tempDir.path}/traceway_$exceptionId.mp4';

      await FlutterQuickVideoEncoder.setLogLevel(
        debug ? LogLevel.standard : LogLevel.none,
      );

      await FlutterQuickVideoEncoder.setup(
        width: maxWidth,
        height: maxHeight,
        fps: fps,
        videoBitrate: 2000000,
        profileLevel: ProfileLevel.baselineAutoLevel,
        audioChannels: 0,
        audioBitrate: 0,
        sampleRate: 0,
        filepath: outputPath,
      );

      // Decode each PNG → RGBA, apply masks, draw touch circle, feed to encoder.
      // Frames smaller than maxWidth×maxHeight are padded with dark grey.
      final canvasSize = maxWidth * maxHeight * 4;
      for (final frame in frames) {
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

        await FlutterQuickVideoEncoder.appendVideoFrame(output);
      }

      await FlutterQuickVideoEncoder.finish();

      final videoFile = File(outputPath);
      final videoBytes = await videoFile.readAsBytes();
      final base64Video = base64Encode(videoBytes);

      await videoFile.delete();

      if (debug) {
        final bufferKB = frames.fold<int>(0, (sum, f) => sum + f.pngBytes.length) ~/ 1024;
        print('Traceway: encoded ${frames.length} frames (buffer: ${bufferKB}KB) to ${videoBytes.length ~/ 1024}KB MP4 (${durationSeconds.toStringAsFixed(1)}s)');
      }

      return SessionRecordingPayload(
        exceptionId: exceptionId,
        events: [
          {
            'type': 'flutter_video',
            'data': base64Video,
            'format': 'mp4',
            'fps': fps,
            'durationSeconds': durationSeconds,
          }
        ],
      );
    } catch (e) {
      if (debug) {
        print('Traceway: recording encoding error: $e');
      }
      return null;
    } finally {
      completer.complete();
    }
  }
}
