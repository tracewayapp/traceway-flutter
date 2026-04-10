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

class CapturedFrame {
  final Uint8List pngBytes;
  final int width;
  final int height;
  final DateTime timestamp;
  final Offset? touchPosition;

  const CapturedFrame({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.timestamp,
    this.touchPosition,
  });
}

class ScreenRecorder with WidgetsBindingObserver {
  final GlobalKey repaintBoundaryKey;
  final double pixelRatio;
  final int captureIntervalMs;
  final CircularBuffer<CapturedFrame> _buffer;
  final bool debug;

  Timer? _captureTimer;
  bool _isCapturing = false;
  bool _isPaused = false;

  // Touch tracking (logical coordinates)
  Offset? _touchPosition;

  ScreenRecorder({
    required this.repaintBoundaryKey,
    required int maxFrames,
    this.pixelRatio = 0.5,
    this.captureIntervalMs = 67,
    this.debug = false,
  }) : _buffer = CircularBuffer<CapturedFrame>(maxFrames);

  void setTouchPosition(Offset position) {
    _touchPosition = position;
  }

  void clearTouchPosition() {
    _touchPosition = null;
  }

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _captureTimer = Timer.periodic(
      Duration(milliseconds: captureIntervalMs),
      (_) => _captureFrame(),
    );
    if (debug) {
      print('Traceway: screen recorder started (${1000 ~/ captureIntervalMs}fps, ${pixelRatio}x)');
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

  Future<SessionRecordingPayload?> captureRecording(
    String exceptionId,
  ) async {
    final frames = _buffer.readAll();
    if (frames.isEmpty) return null;

    try {
      final first = frames.first;
      final width = first.width;
      final height = first.height;
      final fps = 1000 ~/ captureIntervalMs;
      final durationSeconds = frames.length * captureIntervalMs / 1000.0;

      final tempDir = await getTemporaryDirectory();
      final outputPath = '${tempDir.path}/traceway_$exceptionId.mp4';

      await FlutterQuickVideoEncoder.setLogLevel(
        debug ? LogLevel.standard : LogLevel.none,
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
        filepath: outputPath,
      );

      // Decode each PNG → RGBA, draw touch circle if needed, feed to encoder
      for (final frame in frames) {
        final rgba = await _decodePngToRgba(frame.pngBytes, frame.width, frame.height);

        if (frame.touchPosition != null) {
          _drawTouchCircle(rgba, frame.width, frame.height, frame.touchPosition!);
        }

        await FlutterQuickVideoEncoder.appendVideoFrame(rgba);
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
    }
  }
}
