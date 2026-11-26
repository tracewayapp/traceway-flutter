/// How [TracewayOptions.screenCapture] records the screen.
enum TracewayScreenCaptureMode {
  /// Frames of the screen, encoded as MP4 clips with the device's hardware
  /// video encoder: what the user saw, pixel for pixel. Android, iOS and
  /// macOS; elsewhere the SDK records a [wireframe] instead.
  video,

  /// The widget tree as a wireframe: each screen becomes an HTML document
  /// of boxes, text and images, and what changes becomes rrweb mutations,
  /// replayed in the browser like a web session. Layout, text, colors,
  /// scrolling and taps are kept, custom painting is shown as a
  /// placeholder. Much smaller than video and cheaper to record, and works
  /// on every platform. Text typed into fields is masked unless remote
  /// settings turn `replay.maskAllInputs` off.
  wireframe,
}
