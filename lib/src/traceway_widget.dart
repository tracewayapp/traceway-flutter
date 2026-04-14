import 'dart:async';

import 'package:flutter/widgets.dart';

import 'error_handler.dart';
import 'screen_recorder.dart';
import 'traceway_client.dart';
import 'traceway_options.dart';

class Traceway extends StatefulWidget {
  final Widget child;

  const Traceway({super.key, required this.child});

  static void run({
    required String connectionString,
    required Widget child,
    TracewayOptions options = const TracewayOptions(),
  }) {
    final errorHandler = ErrorHandler();

    runZonedGuarded(
      () {
        WidgetsFlutterBinding.ensureInitialized();
        final client = TracewayClient.initialize(connectionString, options);
        client.collectSyncDeviceInfo();
        client.collectDeviceInfo();
        errorHandler.install();
        runApp(Traceway(child: child));
      },
      errorHandler.handleZoneError,
    );
  }

  @override
  State<Traceway> createState() => _TracewayState();
}

class _TracewayState extends State<Traceway> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();
  ScreenRecorder? _screenRecorder;

  @override
  void initState() {
    super.initState();
    final client = TracewayClient.instance;
    if (client != null && client.options.screenCapture) {
      _screenRecorder = ScreenRecorder(
        repaintBoundaryKey: _repaintBoundaryKey,
        maxFrames: client.options.maxBufferFrames,
        pixelRatio: client.options.capturePixelRatio,
        fps: client.options.fps,
        debug: client.debug,
      );
      client.screenRecorder = _screenRecorder;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _screenRecorder!.start();
      });
    }
  }

  @override
  void dispose() {
    _screenRecorder?.stop();
    final client = TracewayClient.instance;
    if (client != null) {
      client.screenRecorder = null;
    }
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    _screenRecorder?.setTouchPosition(event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    _screenRecorder?.setTouchPosition(event.localPosition);
  }

  void _onPointerUp(PointerUpEvent event) {
    _screenRecorder?.clearTouchPosition();
  }

  @override
  Widget build(BuildContext context) {
    final client = TracewayClient.instance;
    if (client != null && client.options.screenCapture) {
      return RepaintBoundary(
        key: _repaintBoundaryKey,
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: widget.child,
        ),
      );
    }
    return widget.child;
  }
}
