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
  }) : assert(fps >= 1 && fps < 60, 'fps must be >= 1 and < 60');
}
