/// Video session replay for the Traceway Flutter SDK: an add-on to
/// `package:traceway`, which records wireframes on its own.
///
/// ```dart
/// import 'package:traceway/traceway.dart';
/// import 'package:traceway_video/traceway_video.dart';
///
/// void main() {
///   TracewayVideo.register();
///   Traceway.run(
///     token: const String.fromEnvironment('TRACEWAY_TOKEN'),
///     options: const TracewayOptions(
///       screenCapture: true,
///       screenCaptureMode: TracewayScreenCaptureMode.video,
///     ),
///     child: const MyApp(),
///   );
/// }
/// ```
library;

import 'package:traceway/video.dart';

import 'src/screen_recorder.dart';

export 'src/screen_recorder.dart' show VideoEncoder;

/// Registers video replay with the Traceway SDK.
abstract final class TracewayVideo {
  /// Makes `TracewayScreenCaptureMode.video` record MP4 clips with the
  /// device's hardware H.264 encoder (Android, iOS and macOS; elsewhere the
  /// SDK still records a wireframe). Call it before `Traceway.run`; calling
  /// it again replaces the registration.
  ///
  /// [encoder] replaces the hardware encoder, which also makes video work
  /// where there is none (e.g. an `ffmpeg` process on desktop Linux).
  static void register({VideoEncoder? encoder}) =>
      registerTracewayVideoBackend(_VideoBackend(encoder));
}

class _VideoBackend implements TracewayVideoBackend {
  const _VideoBackend(this.encoder);

  final VideoEncoder? encoder;

  @override
  bool get isSupported => encoder != null || ScreenRecorder.isVideoSupported;

  @override
  TracewayVideoRecorder createRecorder(TracewayVideoRecorderConfig config) =>
      ScreenRecorder(
        repaintBoundaryKey: config.repaintBoundaryKey,
        maxFrames: config.maxFrames,
        pixelRatio: config.pixelRatio,
        fps: config.fps,
        debug: config.debug,
        encoder: encoder,
      );
}
