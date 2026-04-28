import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'error_handler.dart';
import 'events/log_capture.dart';
import 'events/network_capture.dart';
import 'events/traceway_navigator_observer.dart';
import 'screen_recorder.dart';
import 'traceway_client.dart';
import 'traceway_options.dart';

class Traceway extends StatefulWidget {
  final Widget child;

  const Traceway({super.key, required this.child});

  /// A shared [NavigatorObserver] that records navigation transitions into the
  /// rolling action buffer. Attach it to your `MaterialApp.navigatorObservers`
  /// (or any custom Navigator) to enable navigation capture.
  static final TracewayNavigatorObserver navigatorObserver =
      TracewayNavigatorObserver();

  /// Records a custom user-defined breadcrumb. Convenience pass-through to
  /// `TracewayClient.instance?.recordAction(...)`.
  static void recordAction({
    required String category,
    required String name,
    Map<String, dynamic>? data,
  }) {
    TracewayClient.instance?.recordAction(
      category: category,
      name: name,
      data: data,
    );
  }

  static void run({
    required String connectionString,
    required Widget child,
    TracewayOptions options = const TracewayOptions(),
  }) {
    final errorHandler = ErrorHandler();

    if (options.captureNetwork) {
      try {
        HttpOverrides.global = TracewayHttpOverrides(HttpOverrides.current);
      } catch (_) {
        // Ignore — overrides may be unavailable on some platforms (e.g. web).
      }
    }

    runZonedGuarded(
      () {
        WidgetsFlutterBinding.ensureInitialized();
        final client = TracewayClient.initialize(connectionString, options);
        client.collectSyncDeviceInfo();
        client.collectDeviceInfo();
        client.loadPendingFromDisk();
        errorHandler.install();
        runApp(Traceway(child: child));
      },
      errorHandler.handleZoneError,
      zoneSpecification: options.captureLogs ? buildLogZoneSpec() : null,
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
