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

  /// Emits a named product event; see [TracewayClient.track].
  static void track(String eventName, [Map<String, Object>? attributes]) {
    TracewayClient.instance?.track(eventName, attributes);
  }

  /// Sets an attribute attached to every later record, e.g. `user.id`.
  static void setAttribute(String key, String value) {
    TracewayClient.instance?.setAttribute(key, value);
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
        TracewayClient.initialize(connectionString, options);
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
      // The client starts and stops the recorder as the replay mode allows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) client.screenRecorder = _screenRecorder;
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
    TracewayClient.instance?.markActivity();
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
    final listener = Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: widget.child,
    );
    if (client != null && client.options.screenCapture) {
      return RepaintBoundary(key: _repaintBoundaryKey, child: listener);
    }
    return listener;
  }
}
