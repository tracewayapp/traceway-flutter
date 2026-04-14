import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';

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

  Future<SessionRecordingPayload?> captureRecording(
    String exceptionId,
  ) async {
    final frames = _buffer.readAll();
    if (frames.isEmpty) return null;

    try {
      final first = frames.first;
      final fps = 1000 ~/ captureIntervalMs;
      final durationSeconds = frames.length * captureIntervalMs / 1000.0;

      // Single native call — PNG decoding, touch circles, and H.264 encoding
      // all happen on a native background thread with zero main-thread work.
      final mp4Bytes = await FlutterQuickVideoEncoder.encodeFrames(
        pngFrames: frames.map((f) => f.pngBytes).toList(),
        width: first.width,
        height: first.height,
        fps: fps,
        videoBitrate: 2000000,
        profileLevel: ProfileLevel.baselineAutoLevel,
        touchPositions: frames.map((f) {
          if (f.touchPosition == null) return null;
          return {
            'x': f.touchPosition!.dx * pixelRatio,
            'y': f.touchPosition!.dy * pixelRatio,
          };
        }).toList(),
      );

      final base64Video = base64Encode(mp4Bytes);

      if (debug) {
        final bufferKB = frames.fold<int>(0, (sum, f) => sum + f.pngBytes.length) ~/ 1024;
        print('Traceway: encoded ${frames.length} frames (buffer: ${bufferKB}KB) to ${mp4Bytes.length ~/ 1024}KB MP4 (${durationSeconds.toStringAsFixed(1)}s)');
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
