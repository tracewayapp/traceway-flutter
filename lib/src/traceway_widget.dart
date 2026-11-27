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
import 'replay/replay_source.dart';
import 'screen_recorder.dart';
import 'traceway_client.dart';
import 'traceway_interaction.dart';
import 'traceway_log_level.dart';
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

  /// Reports [error] as an issue, with its [stackTrace] (pass the one
  /// `catch (e, st)` gives; without it the issue has no frames) and extra
  /// [attributes]. Errors nobody catches are reported without this. Before
  /// the SDK has started it does nothing.
  static void captureException(Object error,
          [StackTrace? stackTrace, Map<String, String>? attributes]) =>
      TracewayClient.instance?.captureException(error, stackTrace, attributes);

  /// Reports [message] as an issue of its own, without an exception.
  static void captureMessage(String message,
          [Map<String, String>? attributes]) =>
      TracewayClient.instance?.captureMessage(message, attributes);

  /// Sets an attribute attached to every later record, e.g. `user.id`.
  static void setAttribute(String key, String value) {
    TracewayClient.instance?.setAttribute(key, value);
  }

  /// Sets several attributes at once, like [setAttribute] for each.
  static void setAttributes(Map<String, String> attributes) =>
      TracewayClient.instance?.setAttributes(attributes);

  /// Stops attaching the attribute [key] to later records.
  static void removeAttribute(String key) =>
      TracewayClient.instance?.removeAttribute(key);

  /// Stops attaching every attribute set with [setAttribute]; the ones in
  /// [TracewayOptions.attributes] go too.
  static void clearAttributes() => TracewayClient.instance?.clearAttributes();

  /// Sends what is waiting to be sent: records, replay clips and metrics.
  /// Completes when they are sent, or after [timeoutMs] when given.
  static Future<void> flush([int? timeoutMs]) async =>
      TracewayClient.instance?.flush(timeoutMs);

  /// Ends the session, sends what is waiting and stops the SDK. Calling it
  /// again, or before the SDK has started, does nothing.
  static Future<void> shutdown() async => TracewayClient.instance?.shutdown();

  /// Asks the server for collection settings now instead of at the next
  /// poll, e.g. right after sign-in set `user.id` for a rule that targets
  /// it.
  static Future<void> refreshConfig() async =>
      TracewayClient.instance?.refreshConfig();

  /// This installation's id (`service.instance.id`), which the dashboard
  /// can aim a capture at; null before the SDK has started.
  static String? getInstanceId() => TracewayClient.instance?.getInstanceId();

  /// The current session's id (`session.id`); null before the SDK has
  /// started or with sessions off.
  static String? get currentSessionId =>
      TracewayClient.instance?.currentSessionId;

  /// Records [message] as a log line at [level], e.g.
  /// `Traceway.log('payment declined', level: TracewayLogLevel.warn)`.
  /// Printed lines are info; `package:logging` records keep their level.
  static void log(
    String message, {
    TracewayLogLevel level = TracewayLogLevel.info,
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  }) =>
      TracewayClient.instance?.log(message,
          level: level,
          error: error,
          stackTrace: stackTrace,
          attributes: attributes);

  /// Records that the app arrived at [path], for routers that do not report
  /// to a [NavigatorObserver]. [route] is its route template when the
  /// router knows it, so metrics group by route and issues carry it. With
  /// `go_router`:
  ///
  /// ```dart
  /// router.routerDelegate.addListener(() {
  ///   final match = router.routerDelegate.currentConfiguration;
  ///   Traceway.recordNavigation(match.uri.path, route: match.fullPath);
  /// });
  /// ```
  ///
  /// Navigation steps of recording triggers match [path].
  static void recordNavigation(String path,
      {String? from, String action = 'push', String? route}) {
    final client = TracewayClient.instance;
    if (client == null || !client.options.captureNavigation) return;
    client.recordNavigationEvent(NavigationEvent(
      action: action,
      from: from ?? client.currentScreen,
      to: path,
      route: route,
    ));
  }

  /// Names the current screen by its route template (`/orders/:id`), so
  /// metrics group by route and issues carry it (`app.screen.route`), until
  /// the next screen. For a router that names its routes by path, e.g.
  /// `Traceway.setRoute(routeFromParams(path, params))`.
  static void setRoute(String? template) =>
      TracewayClient.instance?.setRoute(template);

  /// Starts an interaction: one user action traced from start to end. See
  /// [TracewayInteraction]. Before the SDK has started it records nothing.
  static TracewayInteraction startInteraction(String name,
          {Map<String, Object>? attributes}) =>
      TracewayClient.instance
          ?.startInteraction(name, attributes: attributes) ??
      TracewayInteraction.internal(null,
          captureException: (error, stackTrace, attributes) {});

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

  /// A pointer that comes up where it went down, before a long press
  /// would, is a tap: it is recorded before the app's own tap handlers run,
  /// so the tap comes first in the session, before whatever it causes. A
  /// long press is not one: what it opened (a menu under the finger) is on
  /// screen by the time it comes up, and would be taken for its target.
  void _onPointerUp(PointerUpEvent event) {
    _screenRecorder?.clearTouchPosition();
    final down = _downs.remove(event.pointer);
    final tap = down != null &&
        (event.position - down.position).distance <= _slop(down.kind) &&
        event.timeStamp - down.timeStamp < kLongPressTimeout;
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
