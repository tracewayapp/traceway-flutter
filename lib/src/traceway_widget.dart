import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show Tracer;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'error_handler.dart';
import 'events/log_capture.dart';
import 'events/network_capture.dart';
import 'events/traceway_event.dart';
import 'events/traceway_navigator_observer.dart';
import 'guarded.dart';
import 'replay/replay_source.dart';
import 'replay/video_recorder.dart';
import 'traceway_client.dart';
import 'traceway_interaction.dart';
import 'traceway_log_level.dart';
import 'traceway_options.dart';
import 'traceway_screen_capture_mode.dart';
import 'wireframe/wireframe_recorder.dart';

class Traceway extends StatefulWidget {
  final Widget child;

  const Traceway({super.key, required this.child});

  /// A [NavigatorObserver] that records navigation transitions into the
  /// rolling action buffer. Attach it to your `MaterialApp.navigatorObservers`
  /// (or the app's one root Navigator) to enable navigation capture.
  ///
  /// An observer can watch one Navigator at a time (Flutter asserts it):
  /// give each further Navigator (a nested one, a go_router `ShellRoute`)
  /// its own `TracewayNavigatorObserver()`.
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
  /// can aim a capture at; null before the SDK has started and while it
  /// starts (`await Traceway.ready` first).
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
  ///
  /// With `captureNavigation: false` the screen is still named (issues carry
  /// it, screen metrics group by it); only the navigation record is left
  /// out.
  static void recordNavigation(String path,
      {String? from, String action = 'push', String? route}) {
    guarded('recordNavigation', () {
      final client = TracewayClient.instance;
      if (client == null) return;
      client.recordNavigationEvent(NavigationEvent(
        action: action,
        from: from ?? client.currentScreen,
        to: path,
        route: route,
      ));
    });
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

  /// Whether the app set the Flutter binding up before [run], in its own
  /// zone (to await plugins first).
  static bool _bindingExists() {
    try {
      WidgetsBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
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

  /// The SDK's OpenTelemetry tracer, for spans of the app's own; null until
  /// the SDK has started and after [shutdown]. See [TracewayClient.tracer].
  ///
  /// ```dart
  /// final span = Traceway.tracer?.startSpan('load-catalog');
  /// try {
  ///   await loadCatalog();
  /// } finally {
  ///   span?.end();
  /// }
  /// ```
  static Tracer? get tracer => TracewayClient.instance?.tracer;

  /// The running client, or null before [run] and after [shutdown]; the
  /// same as [TracewayClient.instance].
  static TracewayClient? get client => TracewayClient.instance;

  /// Completes when the SDK has started (it reads its state from disk
  /// first), at once when it is not running. [tracer] is null until then.
  static Future<void> get ready =>
      TracewayClient.instance?.ready ?? Future<void>.value();

  /// Starts the SDK and runs [child] inside the [Traceway] widget.
  ///
  /// [token] is the project token from the dashboard's Connection page;
  /// [baseUrl] is the Traceway server, needed only when it is not Traceway
  /// Cloud (`https://cloud.tracewayapp.com`). Without a token the SDK runs
  /// standalone, with [TracewayOptions.telemetry] as the only destination.
  ///
  /// ```dart
  /// Traceway.run(
  ///   token: const String.fromEnvironment('TRACEWAY_TOKEN'),
  ///   child: const MyApp(),
  /// );
  /// ```
  ///
  /// [connectionString] (`YOUR_TOKEN@https://cloud.tracewayapp.com`) is
  /// deprecated: it is read as [token] and [baseUrl], with one warning, and
  /// replaces both when they are given too.
  /// With a connection string or [baseUrl] it cannot use, the SDK prints
  /// one warning and the app runs without it; other settings it cannot use
  /// (no token and no telemetry destination, a malformed telemetry URL) are
  /// reported as a [FlutterError], and the app runs without it too. On the
  /// web the app runs without it.
  static void run({
    String? token,
    String? baseUrl,
    @Deprecated('Pass token: (and baseUrl: for a self-hosted server) instead')
    String? connectionString,
    required Widget child,
    TracewayOptions options = const TracewayOptions(),
  }) {
    if (kIsWeb) {
      debugPrint(TracewayClient.webUnsupportedMessage);
      runApp(child);
      return;
    }
    // One handler and one HTTP override per process, however often `run`
    // is called (an integration test runs `main` per test): an error or a
    // request is recorded once.
    final errorHandler = ErrorHandler.current;
    if (options.captureNetwork) {
      // Unavailable on some platforms (the web).
      guarded('HttpOverrides', TracewayHttpOverrides.install);
    }

    void start() {
      try {
        final client = TracewayClient.initialize(
          token: token,
          baseUrl: baseUrl,
          options: options,
          // ignore: deprecated_member_use_from_same_package
          connectionString: connectionString,
        );
        // An unusable connection string or server URL, already warned
        // about: the app runs without the SDK.
        if (client == null) {
          runApp(child);
          return;
        }
      } catch (error, stack) {
        // A missing token or a malformed telemetry destination must not
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
      guarded('error handlers', errorHandler.install);
      runApp(Traceway(child: child));
    }

    // `runApp` must run in the zone the binding was set up in, or Flutter
    // reports a zone mismatch. An app that set it up before `run` keeps its
    // zone: its uncaught async errors reach `PlatformDispatcher.onError`,
    // where the SDK records them, and only `print` lines are not captured.
    if (_bindingExists()) {
      start();
      return;
    }
    runZonedGuarded(
      () {
        WidgetsFlutterBinding.ensureInitialized();
        start();
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

  /// Keeps the app's subtree, and its state, when the boundary around it
  /// comes or goes with the client.
  final GlobalKey _appKey = GlobalKey();

  /// The client this widget records for: the running one, followed when it
  /// is shut down or another starts.
  TracewayClient? _client;
  TracewayVideoRecorder? _screenRecorder;
  WireframeRecorder? _wireframeRecorder;
  ValueListenable<TracewayScreenCaptureMode?>? _captureMode;

  @override
  void initState() {
    super.initState();
    guarded('Traceway widget', () {
      tracewayClientChanges.addListener(_onClientChanged);
      _bind(TracewayClient.instance);
    });
  }

  void _bind(TracewayClient? client) {
    _unbind();
    _client = client;
    if (client == null) return;
    _captureMode = client.captureMode..addListener(_onCaptureModeChanged);
    final recorder = _createRecorder(client);
    if (recorder != null) {
      // The client starts and stops the recorder as the replay mode allows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        guarded('recorder attach', () {
          if (mounted &&
              identical(client, _client) &&
              identical(recorder, _recorder)) {
            client.screenRecorder = recorder;
          }
        });
      });
    }
  }

  void _unbind() {
    _captureMode?.removeListener(_onCaptureModeChanged);
    _captureMode = null;
    final recorder = _recorder;
    _screenRecorder?.stop();
    _wireframeRecorder?.stop();
    _screenRecorder = null;
    _wireframeRecorder = null;
    final client = _client;
    _client = null;
    if (client != null &&
        (recorder == null || identical(client.screenRecorder, recorder))) {
      client.screenRecorder = null;
    }
  }

  /// Another client started, or this one was shut down: the widget records
  /// for the one running now, keeping the app's state.
  void _onClientChanged() {
    guarded('Traceway widget', () {
      if (!mounted || identical(TracewayClient.instance, _client)) return;
      void rebind() => guarded('Traceway widget', () {
            final client = TracewayClient.instance;
            if (!mounted || identical(client, _client)) return;
            setState(() => _bind(client));
          });
      // Not in the middle of a build.
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) => rebind());
      } else {
        rebind();
      }
    });
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
        // The client asks for video only with the add-on registered.
        final backend = tracewayVideoBackend;
        _screenRecorder = backend == null
            ? null
            : guardedOr<TracewayVideoRecorder?>(
                'video recorder',
                null,
                () => backend.createRecorder(TracewayVideoRecorderConfig(
                      repaintBoundaryKey: _repaintBoundaryKey,
                      maxFrames:
                          client.options.maxBufferFrames.clamp(1, 100000),
                      pixelRatio: client.options.capturePixelRatio,
                      fps: client.options.fps.clamp(1, 59),
                      debug: client.debug,
                    )));
      case null:
    }
    return _recorder;
  }

  /// Remote settings switched between video and wireframe: the new recorder
  /// replaces the old one, whose frames are dropped.
  void _onCaptureModeChanged() {
    guarded('capture mode', () {
      final client = _client;
      if (!mounted || client == null) return;
      client.screenRecorder = _createRecorder(client);
    });
  }

  @override
  void dispose() {
    guarded('Traceway widget', () {
      tracewayClientChanges.removeListener(_onClientChanged);
      _unbind();
    });
    super.dispose();
  }

  /// Pointers that went down and may still become a tap.
  final Map<int, PointerDownEvent> _downs = {};

  // The pointer callbacks only watch: the app's own gestures get every
  // event whatever happens in them.

  void _onPointerDown(PointerDownEvent event) =>
      guarded('pointer down', () => _pointerDown(event));

  void _pointerDown(PointerDownEvent event) {
    final primary = event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryButton != 0;
    if (primary) _downs[event.pointer] = event;
    TracewayClient.instance?.markActivity();
    _screenRecorder?.setTouchPosition(event.localPosition);
    _wireframeRecorder?.pointerDown(event.pointer, event.localPosition,
        touch: _isTouch(event.kind));
  }

  void _onPointerMove(PointerMoveEvent event) =>
      guarded('pointer move', () => _pointerMove(event));

  void _pointerMove(PointerMoveEvent event) {
    final down = _downs[event.pointer];
    if (down != null &&
        (event.position - down.position).distance > _slop(down.kind)) {
      _downs.remove(event.pointer);
    }
    _screenRecorder?.setTouchPosition(event.localPosition);
    _wireframeRecorder?.pointerMove(event.pointer, event.localPosition,
        touch: _isTouch(event.kind));
  }

  /// A pointer that comes up where it went down, before a long press
  /// would, is a tap: it is recorded before the app's own tap handlers run,
  /// so the tap comes first in the session, before whatever it causes. A
  /// long press is not one: what it opened (a menu under the finger) is on
  /// screen by the time it comes up, and would be taken for its target.
  void _onPointerUp(PointerUpEvent event) =>
      guarded('pointer up', () => _pointerUp(event));

  void _pointerUp(PointerUpEvent event) {
    final down = _downs.remove(event.pointer);
    final tap = down != null &&
        (event.position - down.position).distance <= _slop(down.kind) &&
        event.timeStamp - down.timeStamp < kLongPressTimeout;
    guarded('pointer up', () {
      _screenRecorder?.clearTouchPosition();
      _wireframeRecorder?.pointerUp(event.pointer, event.localPosition,
          touch: _isTouch(event.kind), tap: tap);
    });
    if (down == null || !tap) return;
    // Recording a tap must never break the tap.
    TracewayClient.instance?.recordTap(down.position, viewId: down.viewId);
  }

  void _onPointerCancel(PointerCancelEvent event) =>
      guarded('pointer cancel', () {
        _downs.remove(event.pointer);
        _screenRecorder?.clearTouchPosition();
        _wireframeRecorder?.pointerCancel(event.pointer, event.localPosition,
            touch: _isTouch(event.kind));
      });

  void _onPointerHover(PointerHoverEvent event) =>
      guarded('pointer hover', () {
        if (event.kind != PointerDeviceKind.mouse) return;
        _wireframeRecorder?.pointerMove(event.pointer, event.localPosition,
            touch: false);
        TracewayClient.instance
            ?.recordHover(event.position, viewId: event.viewId);
      });

  static bool _isTouch(PointerDeviceKind kind) =>
      kind != PointerDeviceKind.mouse && kind != PointerDeviceKind.trackpad;

  static double _slop(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse ? kPrecisePointerHitSlop * 4 : kTouchSlop;

  @override
  Widget build(BuildContext context) {
    final client = _client;
    final listener = Listener(
      key: _appKey,
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
