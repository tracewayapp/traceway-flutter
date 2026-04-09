import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:path_provider/path_provider.dart';

import 'circular_buffer.dart';
import 'models/session_recording_payload.dart';

class CapturedFrame {
  final Uint8List rgbaBytes;
  final int width;
  final int height;
  final DateTime timestamp;

  const CapturedFrame({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.timestamp,
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

  ScreenRecorder({
    required this.repaintBoundaryKey,
    required int maxFrames,
    this.pixelRatio = 0.5,
    this.captureIntervalMs = 67,
    this.debug = false,
  }) : _buffer = CircularBuffer<CapturedFrame>(maxFrames);

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
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = image.width;
      final height = image.height;
      image.dispose();

      if (byteData != null) {
        _buffer.push(CapturedFrame(
          rgbaBytes: byteData.buffer.asUint8List(),
          width: width,
          height: height,
          timestamp: DateTime.now(),
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
        videoBitrate: 1000000,
        profileLevel: ProfileLevel.baselineAutoLevel,
        audioChannels: 0,
        audioBitrate: 0,
        sampleRate: 0,
        filepath: outputPath,
      );

      for (final frame in frames) {
        await FlutterQuickVideoEncoder.appendVideoFrame(frame.rgbaBytes);
      }

      await FlutterQuickVideoEncoder.finish();

      final videoFile = File(outputPath);
      final videoBytes = await videoFile.readAsBytes();
      final base64Video = base64Encode(videoBytes);

      await videoFile.delete();

      if (debug) {
        print('Traceway: encoded ${frames.length} frames to ${videoBytes.length ~/ 1024}KB MP4 (${durationSeconds.toStringAsFixed(1)}s)');
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
