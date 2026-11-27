import 'package:flutter/widgets.dart';

import 'replay_source.dart';

/// A recorder of video replay, which the `traceway_video` add-on provides:
/// the core package records wireframes only and has no native code.
abstract class TracewayVideoRecorder implements ReplaySource {
  /// Whether what is typed into text fields is hidden in the video, as the
  /// wireframe masks it; the settings turn it off (`replay.maskAllInputs`).
  set maskAllInputs(bool value);

  /// Where a finger or the mouse is on the screen, in logical pixels, so the
  /// video can show the touch.
  void setTouchPosition(Offset position);

  /// No finger is on the screen any more.
  void clearTouchPosition();
}

/// What the `Traceway` widget hands a video recorder it creates.
class TracewayVideoRecorderConfig {
  const TracewayVideoRecorderConfig({
    required this.repaintBoundaryKey,
    required this.maxFrames,
    required this.pixelRatio,
    required this.fps,
    required this.debug,
  });

  /// The `RepaintBoundary` around the app whose frames are recorded.
  final GlobalKey repaintBoundaryKey;

  /// `TracewayOptions.maxBufferFrames`: the frames the ring holds.
  final int maxFrames;

  /// `TracewayOptions.capturePixelRatio`.
  final double pixelRatio;

  /// `TracewayOptions.fps`.
  final int fps;

  /// `TracewayOptions.debug`.
  final bool debug;
}

/// What an add-on registers to record video replay (see
/// [registerTracewayVideoBackend]).
abstract interface class TracewayVideoBackend {
  /// Whether video can be encoded on this platform. Where it cannot, the SDK
  /// records a wireframe.
  bool get isSupported;

  /// A recorder for the `Traceway` widget; the SDK starts and stops it.
  TracewayVideoRecorder createRecorder(TracewayVideoRecorderConfig config);
}

TracewayVideoBackend? _backend;

/// The registered video backend, or null without the `traceway_video`
/// add-on.
TracewayVideoBackend? get tracewayVideoBackend => _backend;

/// Registers [backend] as the recorder of
/// `TracewayScreenCaptureMode.video`; `TracewayVideo.register()` of the
/// `traceway_video` package calls it. Call it before `Traceway.run`. Null
/// unregisters it (tests).
void registerTracewayVideoBackend(TracewayVideoBackend? backend) {
  _backend = backend;
}
