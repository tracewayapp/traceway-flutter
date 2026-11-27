import 'traceway_captured_error.dart';
import 'traceway_image_policy.dart';
import 'traceway_screen_capture_mode.dart';
import 'traceway_telemetry.dart';

class TracewayOptions {
  /// Share of exceptions and messages that are reported (0.0 - 1.0).
  final double sampleRate;

  /// Record the screen. By default the last frames stay on the device and
  /// leave only as the clip of an exception; a capture or trigger that asks
  /// for replay, or a rule, streams the session as segments while it lasts.
  /// [screenCaptureMode] picks video or a wireframe.
  final bool screenCapture;

  /// How [screenCapture] records: [TracewayScreenCaptureMode.video] (the
  /// default) or [TracewayScreenCaptureMode.wireframe], the widget tree
  /// replayed as HTML.
  ///
  /// Video needs a video encoder (Android, iOS and macOS); elsewhere the
  /// screen is recorded as a wireframe instead. `replay.captureMode`
  /// (`video` or `wireframe`) in the remote settings overrides this. A
  /// change applies at once, unless the session has already uploaded replay
  /// in the other mode: then it applies from the next session, so one
  /// session's replay is all video or all wireframe.
  final TracewayScreenCaptureMode screenCaptureMode;

  /// The most images a wireframe replay may show: the ceiling of the
  /// `replay.images` setting (`off`, `wifi` by default, `always`), which
  /// remote settings can lower but not raise. [TracewayImagePolicy.off]
  /// draws every image as a placeholder. Flutter shows a network image by
  /// its URL and uploads no pixels, so `wifi` and `always` are the same
  /// here. Video recordings are not affected.
  final TracewayImagePolicy replayImages;
  final bool debug;

  /// App version, sent as `service.version`.
  final String version;

  /// Sent as `service.name`. Defaults to `flutter-app`.
  final String? serviceName;

  /// Sent as `deployment.environment.name`.
  final String? environment;

  /// Extra attributes attached to every record, and reported to the server
  /// for remote-config targeting (e.g. `user.id`).
  final Map<String, String> attributes;

  final double capturePixelRatio;

  /// Size of the screen-recording ring buffer in frames. With the default 15
  /// fps this is about 10 seconds of video; it is the upper bound of every
  /// clip and cannot be raised remotely. A wireframe takes a frame only when
  /// the screen changed, so its buffer covers at least as long.
  final int maxBufferFrames;
  final int fps;

  /// Keep SDK state (instance id, last remote config, session) and telemetry
  /// that failed to send on disk so they survive app restarts.
  final bool persistToDisk;

  /// The previous 1.x project's connection string. Set during an upgrade to
  /// drain its pending errors and clips. Those files contain no project ID.
  final String? legacyConnectionString;

  /// Capture every `print` / `debugPrint` line as a log record (level
  /// info), every `package:logging` record with its level, and
  /// [Traceway.log]. `dart:developer`'s `log` cannot be captured: it does
  /// not go through the app's zone.
  final bool captureLogs;

  /// Install [HttpOverrides] so every dart:io HTTP call is recorded as a
  /// client span. Clients that bypass dart:io (`cupertino_http`,
  /// `cronet_http`) are recorded by wrapping them in `TracewayHttpClient`.
  final bool captureNetwork;

  /// Record navigation transitions reported by [TracewayNavigatorObserver].
  /// The observer must still be wired into the app's navigator.
  final bool captureNavigation;

  /// Record taps (`browser.user_action.click`) with a selector naming the
  /// widget, and let recording triggers match taps and mouse hovers. The
  /// shown text of a widget inside a `TracewayPrivacyMask` is never sent.
  final bool captureUserActions;

  /// Measure the app's performance on the device and upload it as metrics:
  /// app start, screen display times, slow and frozen frames, hangs,
  /// unhandled errors, sessions, users, peak memory and HTTP requests. The
  /// numbers are histograms and counters, one small payload every few
  /// minutes, never an event per observation; they fill the Flutter
  /// Performance dashboard. Remote settings can switch them off or sample
  /// them (`metrics`), never on when this is false.
  final bool captureMetrics;

  /// Up to two app-defined dimensions on every metric, e.g. `{'plan': 'pro'}`
  /// (sent as `custom.plan`). Keys are lowercase letters, digits and `_`.
  final Map<String, String> metricDimensions;

  /// Stream breadcrumbs (logs, network, navigation, taps, app events) and the
  /// screen recording all the time instead of keeping them for errors.
  final bool recordAllSessions;

  /// Collection settings that apply without the server: the same document a
  /// remote-config rule holds (`signals`, `replay`, `buffer`, `triggers`,
  /// ...), laid over the built-in defaults. With [remoteConfig] the server's
  /// rules are laid over these; with it off they are the whole policy. The
  /// `capture*` options and [screenCapture] stay the ceiling either way.
  ///
  /// ```dart
  /// collection: {
  ///   'signals': {'network': {'mode': 'stream'}},
  ///   'triggers': [
  ///     {
  ///       'id': 'checkout-journey',
  ///       'steps': [
  ///         {'match': {'event': {'type': 'navigation', 'value': '/cart'}}},
  ///         {'match': {'event': {'type': 'click', 'value': '#pay'}}, 'withinSeconds': 60},
  ///       ],
  ///       'actions': [
  ///         {'type': 'capture', 'durationSeconds': 120, 'lookbackSeconds': 30, 'replay': true},
  ///       ],
  ///     },
  ///   ],
  /// }
  /// ```
  final Map<String, Object?>? collection;

  /// Track sessions (`session.start` / `session.end`).
  final bool sessions;

  /// Share of sessions whose breadcrumbs (logs, network, navigation, actions)
  /// are sent continuously instead of only around errors.
  final double baselineSampleRate;

  /// Poll the server over OpAMP for collection settings. The `capture*`
  /// options, [screenCapture] and [sessions] are ceilings: remote settings
  /// can lower them but never raise them. [sampleRate], [baselineSampleRate]
  /// and [recordAllSessions] are defaults a rule can change either way.
  final bool remoteConfig;

  /// How long finished records wait before they are sent as one batch.
  final int exportDelayMs;

  /// Send logs, spans and metrics to another OpenTelemetry backend (an
  /// OTLP/HTTP receiver such as an OpenTelemetry Collector) instead of
  /// Traceway. With a connection string, exceptions, messages, sessions,
  /// OpAMP and screen recordings stay on Traceway; without one the SDK runs
  /// standalone and this receives everything. See [TracewayTelemetry].
  ///
  /// ```dart
  /// telemetry: TracewayTelemetry(
  ///   url: 'https://collector.example.com',
  ///   headers: {'x-api-key': '...'},
  /// ),
  /// ```
  final TracewayTelemetry? telemetry;

  /// Requests that carry a W3C `traceparent` header naming their client
  /// span, so the backend's spans join the app's trace in Traceway or any
  /// OpenTelemetry backend. A [String] matches URLs that start with it, a
  /// [RegExp] URLs it matches. Empty by default: a header a server does not
  /// expect can break a strict CORS or signature check.
  ///
  /// ```dart
  /// propagateTraceHeaderUrls: ['https://api.example.com/', RegExp(r'^https://[a-z]+\.example\.com/')],
  /// ```
  final List<Pattern> propagateTraceHeaderUrls;

  /// Exceptions and messages not to report, matched against the first line
  /// of their `Type: message` (never the stack, so a frame named like a
  /// pattern silences nothing): a [String] if it occurs in it, a [RegExp]
  /// if it matches. An ignored unhandled error is not counted as a crash. Null (the default) ignores [defaultIgnoreErrors], network
  /// failures such as a `SocketException` or a timeout; an empty list
  /// reports everything.
  ///
  /// ```dart
  /// ignoreErrors: [...defaultIgnoreErrors, 'PlatformException(camera_denied'],
  /// ```
  final List<Pattern>? ignoreErrors;

  /// Called for every exception and message that is not ignored, before it
  /// is recorded: return false to drop it. An exception it throws is
  /// ignored and the record kept.
  final bool Function(TracewayCapturedError captured)? beforeCapture;

  /// Describe the device on every record: model, manufacturer, name, local
  /// IP address, locale, screen and Dart runtime (`device.*`, `screen.*`,
  /// `runtime.version`). False keeps only the operating system (`os.name`,
  /// `os.version`).
  final bool captureDeviceInfo;

  /// Report hangs (`app.hang`) in debug builds too. Off by default: a
  /// breakpoint, a hot reload or a slow first compile stops the app exactly
  /// like a hang does, and there is no telling them apart. Turn it on to
  /// test hang reporting with a debug build.
  final bool reportHangsInDebug;

  const TracewayOptions({
    this.sampleRate = 1.0,
    this.screenCapture = false,
    this.screenCaptureMode = TracewayScreenCaptureMode.video,
    this.replayImages = TracewayImagePolicy.always,
    this.debug = false,
    this.version = '',
    this.serviceName,
    this.environment,
    this.attributes = const {},
    this.capturePixelRatio = 0.75,
    this.maxBufferFrames = 150,
    this.fps = 15,
    this.persistToDisk = true,
    this.legacyConnectionString,
    this.captureLogs = true,
    this.captureNetwork = true,
    this.captureNavigation = true,
    this.captureUserActions = true,
    this.captureMetrics = true,
    this.metricDimensions = const {},
    this.recordAllSessions = false,
    this.collection,
    this.sessions = true,
    this.baselineSampleRate = 0,
    this.remoteConfig = true,
    this.exportDelayMs = 1000,
    this.telemetry,
    this.propagateTraceHeaderUrls = const [],
    this.ignoreErrors,
    this.beforeCapture,
    this.captureDeviceInfo = true,
    this.reportHangsInDebug = false,
  }) : assert(fps >= 1 && fps < 60, 'fps must be >= 1 and < 60');
}
