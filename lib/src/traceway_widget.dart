import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'error_handler.dart';
import 'events/log_capture.dart';
import 'events/network_capture.dart';
import 'events/traceway_event.dart';
import 'events/traceway_navigator_observer.dart';
import 'replay/replay_controller.dart';
import 'screen_recorder.dart';
import 'traceway_client.dart';
import 'traceway_options.dart';
import 'traceway_screen_capture_mode.dart';
import 'wireframe/wireframe_recorder.dart';

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
  static void recordNavigation(String path,
      {String? from, String action = 'push'}) {
    final client = TracewayClient.instance;
    if (client == null || !client.options.captureNavigation) return;
    client.recordNavigationEvent(NavigationEvent(
      action: action,
      from: from ?? client.currentScreen,
      to: path,
    ));
  }

  /// The screen on top shows everything it loads (data fetched, images
  /// decoded): ends its time to full display, charted next to the time to
  /// its first frame.
  static void reportFullyDisplayed() =>
      TracewayClient.instance?.reportFullyDisplayed();

  /// Observes [value] of an app-defined metric, e.g.
  /// `Traceway.metric('checkout.duration', ms, {'plan': 'pro'})`. Charted as
  /// percentiles; see [TracewayClient.recordMetric] for the naming rules.
  static void metric(String name, double value, [Map<String, Object>? dims]) =>
      TracewayClient.instance?.recordMetric(name, value, dims);

  /// Adds [n] to an app-defined counter, e.g. `Traceway.count('cart.add')`.
  static void count(String name, [double n = 1, Map<String, Object>? dims]) =>
      TracewayClient.instance?.recordCount(name, n, dims);

  /// Sets a dimension on every metric from now on, e.g. an experiment arm;
  /// null removes it. At most two.
  static void setMetricDimension(String key, String? value) =>
      TracewayClient.instance?.setMetricDimension(key, value);

  /// Starts the SDK and runs [child]. [connectionString]
  /// (`<token>@<server>`) connects it to Traceway; leave it out to run
  /// standalone with [TracewayOptions.telemetry] as the only destination.
  static void run({
    String? connectionString,
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
        try {
          TracewayClient.initialize(connectionString, options);
        } catch (error, stack) {
          // A malformed connection string or telemetry destination must not
          // take the app down with it: report it and run without the SDK.
          FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'traceway',
            context: ErrorDescription('while starting the Traceway SDK; '
                'the app runs without it'),
          ));
          runApp(child);
          return;
        }
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
  WireframeRecorder? _wireframeRecorder;
  ValueListenable<TracewayScreenCaptureMode?>? _captureMode;

  @override
  void initState() {
    super.initState();
    final client = TracewayClient.instance;
    if (client == null) return;
    _captureMode = client.captureMode..addListener(_onCaptureModeChanged);
    final recorder = _createRecorder(client);
    if (recorder != null) {
      // The client starts and stops the recorder as the replay mode allows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(recorder, _recorder)) {
          client.screenRecorder = recorder;
        }
      });
    }
  }

  ReplaySource? get _recorder {
    final ReplaySource? wireframe = _wireframeRecorder;
    return wireframe ?? _screenRecorder;
  }

  ReplaySource? _createRecorder(TracewayClient client) {
    _screenRecorder = null;
    _wireframeRecorder = null;
    switch (client.captureMode.value) {
      case TracewayScreenCaptureMode.wireframe:
        _wireframeRecorder = WireframeRecorder(
          rootKey: _repaintBoundaryKey,
          maxFrames: client.options.maxBufferFrames.clamp(2, 100000),
          fps: client.options.fps.clamp(1, 59),
          debug: client.debug,
          screenName: () => client.currentScreen,
        );
      case TracewayScreenCaptureMode.video:
        _screenRecorder = ScreenRecorder(
          repaintBoundaryKey: _repaintBoundaryKey,
          maxFrames: client.options.maxBufferFrames.clamp(1, 100000),
          pixelRatio: client.options.capturePixelRatio,
          fps: client.options.fps.clamp(1, 59),
          debug: client.debug,
        );
      case null:
    }
    return _recorder;
  }

  /// Remote settings switched between video and wireframe: the new recorder
  /// replaces the old one, whose frames are dropped.
  void _onCaptureModeChanged() {
    final client = TracewayClient.instance;
    if (!mounted || client == null) return;
    client.screenRecorder = _createRecorder(client);
  }

  @override
  void dispose() {
    _captureMode?.removeListener(_onCaptureModeChanged);
    _screenRecorder?.stop();
    _wireframeRecorder?.stop();
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
    _wireframeRecorder?.pointerDown(event.pointer, event.localPosition,
        touch: _isTouch(event.kind));
    final primary = event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryButton != 0;
    if (primary) _downs[event.pointer] = event;
  }

  void _onPointerMove(PointerMoveEvent event) {
    _screenRecorder?.setTouchPosition(event.localPosition);
    _wireframeRecorder?.pointerMove(event.pointer, event.localPosition,
        touch: _isTouch(event.kind));
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
    final tap = down != null &&
        (event.position - down.position).distance <= _slop(down.kind);
    _wireframeRecorder?.pointerUp(event.pointer, event.localPosition,
        touch: _isTouch(event.kind), tap: tap);
    if (down == null || !tap) return;
    try {
      TracewayClient.instance?.recordTap(down.position, viewId: down.viewId);
    } catch (_) {
      // Recording a tap must never break the tap.
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _downs.remove(event.pointer);
    _screenRecorder?.clearTouchPosition();
    _wireframeRecorder?.pointerCancel(event.pointer, event.localPosition,
        touch: _isTouch(event.kind));
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _wireframeRecorder?.pointerMove(event.pointer, event.localPosition,
        touch: false);
    try {
      TracewayClient.instance
          ?.recordHover(event.position, viewId: event.viewId);
    } catch (_) {}
  }

  static bool _isTouch(PointerDeviceKind kind) =>
      kind != PointerDeviceKind.mouse && kind != PointerDeviceKind.trackpad;

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
