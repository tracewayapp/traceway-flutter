class TracewayOptions {
  /// Share of exceptions and messages that are reported (0.0 - 1.0).
  final double sampleRate;

  /// Keep a short screen recording on the device and upload it as a clip
  /// when an exception is captured. Never streamed.
  final bool screenCapture;
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
  /// fps this is about 10 seconds; it is the upper bound of every clip and
  /// cannot be raised remotely.
  final int maxBufferFrames;
  final int fps;

  /// Keep SDK state (instance id, last remote config, session) and telemetry
  /// that failed to send on disk so they survive app restarts.
  final bool persistToDisk;

  /// Capture every `print` / `debugPrint` line as a log record.
  final bool captureLogs;

  /// Install [HttpOverrides] so every dart:io HTTP call is recorded as a
  /// client span. On Flutter web use `TracewayHttpClient` instead.
  final bool captureNetwork;

  /// Record navigation transitions reported by [TracewayNavigatorObserver].
  /// The observer must still be wired into the app's navigator.
  final bool captureNavigation;

  /// Track sessions (`session.start` / `session.end`).
  final bool sessions;

  /// Share of sessions whose breadcrumbs (logs, network, navigation, actions)
  /// are sent continuously instead of only around errors.
  final double baselineSampleRate;

  /// Poll the server over OpAMP for collection settings. The options above
  /// are ceilings: remote settings can lower them but never raise them.
  final bool remoteConfig;

  /// How long finished records wait before they are sent as one batch.
  final int exportDelayMs;

  const TracewayOptions({
    this.sampleRate = 1.0,
    this.screenCapture = false,
    this.debug = false,
    this.version = '',
    this.serviceName,
    this.environment,
    this.attributes = const {},
    this.capturePixelRatio = 0.75,
    this.maxBufferFrames = 150,
    this.fps = 15,
    this.persistToDisk = true,
    this.captureLogs = true,
    this.captureNetwork = true,
    this.captureNavigation = true,
    this.sessions = true,
    this.baselineSampleRate = 0,
    this.remoteConfig = true,
    this.exportDelayMs = 1000,
  }) : assert(fps >= 1 && fps < 60, 'fps must be >= 1 and < 60');
}
