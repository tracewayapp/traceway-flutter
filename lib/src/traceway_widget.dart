import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'error_handler.dart';
import 'events/log_capture.dart';
import 'events/network_capture.dart';
import 'events/traceway_event.dart';
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

  /// Records that the app arrived at [path], for routers that do not report
  /// to a [NavigatorObserver] (e.g. a `go_router` listener:
  /// `router.routerDelegate.addListener(() => Traceway.recordNavigation(
  /// router.routerDelegate.currentConfiguration.uri.path))`). Navigation
  /// steps of recording triggers match [path].
  static void recordNavigation(String path, {String? from, String action = 'push'}) {
    final client = TracewayClient.instance;
    if (client == null || !client.options.captureNavigation) return;
    client.recordNavigationEvent(NavigationEvent(
      action: action,
      from: from ?? client.currentScreen,
      to: path,
    ));
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
    if (client != null && client.recordsScreen) {
      _screenRecorder = ScreenRecorder(
        repaintBoundaryKey: _repaintBoundaryKey,
        maxFrames: client.options.maxBufferFrames.clamp(1, 100000),
        pixelRatio: client.options.capturePixelRatio,
        fps: client.options.fps.clamp(1, 59),
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

  /// Pointers that went down and may still become a tap.
  final Map<int, PointerDownEvent> _downs = {};

  void _onPointerDown(PointerDownEvent event) {
    TracewayClient.instance?.markActivity();
    _screenRecorder?.setTouchPosition(event.localPosition);
    final primary = event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryButton != 0;
    if (primary) _downs[event.pointer] = event;
  }

  void _onPointerMove(PointerMoveEvent event) {
    _screenRecorder?.setTouchPosition(event.localPosition);
    final down = _downs[event.pointer];
    if (down != null &&
        (event.position - down.position).distance > _slop(down.kind)) {
      _downs.remove(event.pointer);
    }
  }

  /// A pointer that comes up where it went down is a tap: it is recorded
  /// before the app's own tap handlers run, so the tap comes first in the
  /// session, before whatever it causes.
  void _onPointerUp(PointerUpEvent event) {
    _screenRecorder?.clearTouchPosition();
    final down = _downs.remove(event.pointer);
    if (down == null) return;
    if ((event.position - down.position).distance > _slop(down.kind)) return;
    try {
      TracewayClient.instance?.recordTap(down.position, viewId: down.viewId);
    } catch (_) {
      // Recording a tap must never break the tap.
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _downs.remove(event.pointer);
    _screenRecorder?.clearTouchPosition();
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    try {
      TracewayClient.instance?.recordHover(event.position, viewId: event.viewId);
    } catch (_) {}
  }

  static double _slop(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse ? kPrecisePointerHitSlop * 4 : kTouchSlop;

  @override
  Widget build(BuildContext context) {
    final client = TracewayClient.instance;
    final listener = Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      onPointerHover: _onPointerHover,
      child: widget.child,
    );
    if (client != null && client.recordsScreen) {
      return RepaintBoundary(key: _repaintBoundaryKey, child: listener);
    }
    return listener;
  }
}
