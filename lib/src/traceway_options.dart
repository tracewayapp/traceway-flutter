class TracewayOptions {
  final double sampleRate;
  final bool screenCapture;
  final bool debug;
  final String version;
  final int debounceMs;
  final int retryDelayMs;
  final double capturePixelRatio;
  final int maxBufferFrames;
  final int fps;
  final int maxPendingExceptions;

  /// Whether to persist pending exceptions to disk so they survive app restarts.
  final bool persistToDisk;

  /// Maximum number of exception files stored on disk awaiting sync.
  final int maxLocalFiles;

  /// Hours after which unsynced local files are deleted.
  final int localFileMaxAgeHours;

  /// Capture every `print` / `debugPrint` line as a log event.
  final bool captureLogs;

  /// Install [HttpOverrides] so every dart:io HTTP call is recorded.
  /// On Flutter web use `TracewayHttpClient` instead.
  final bool captureNetwork;

  /// Record navigation transitions reported by [TracewayNavigatorObserver].
  /// The observer must still be wired into the app's navigator.
  final bool captureNavigation;

  /// Length of the rolling log/action window snapshotted with each exception.
  final Duration eventsWindow;

  /// Hard cap applied independently to the rolling log buffer and the rolling
  /// action buffer. Protects against noisy apps regardless of [eventsWindow].
  final int eventsMaxCount;

  const TracewayOptions({
    this.sampleRate = 1.0,
    this.screenCapture = false,
    this.debug = false,
    this.version = '',
    this.debounceMs = 1500,
    this.retryDelayMs = 10000,
    this.capturePixelRatio = 0.75,
    this.maxBufferFrames = 150,
    this.fps = 15,
    this.maxPendingExceptions = 5,
    this.persistToDisk = true,
    this.maxLocalFiles = 5,
    this.localFileMaxAgeHours = 12,
    this.captureLogs = true,
    this.captureNetwork = true,
    this.captureNavigation = true,
    this.eventsWindow = const Duration(seconds: 10),
    this.eventsMaxCount = 200,
  }) : assert(fps >= 1 && fps < 60, 'fps must be >= 1 and < 60');
}
