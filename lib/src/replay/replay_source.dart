/// What the replay controller needs from a screen recorder: the video
/// recorder (`ScreenRecorder`) or the wireframe recorder
/// (`WireframeRecorder`). Lets tests stand in for both.
abstract class ReplaySource {
  bool get isRunning;
  void start();
  void stop();
  void clearBuffer();

  /// Whether any frame was captured at or after [since] and before [until].
  bool hasFrames({DateTime? since, DateTime? until});

  /// Makes one clip of what was on screen at or after [since] and before
  /// [until]. The frames are chosen when this is called.
  Future<SessionRecordingPayload?> captureRecording(
    String clipId, {
    DateTime? since,
    DateTime? until,
  });
}

/// One screen-recording clip, as a [ReplaySource] hands it to the
/// controller: a video clip or a wireframe recording.
class SessionRecordingPayload {
  /// Names the clip while it is encoded; not sent.
  final String clipId;

  /// A single `flutter_video` event carrying the base64 MP4, or the rrweb
  /// events of a wireframe recording.
  final List<Map<String, dynamic>> events;

  /// About how many bytes the events take as JSON, when the recorder
  /// measured it; otherwise the size of the string data is counted.
  final int? approxBytes;

  /// Wall-clock timestamp of the first frame in this recording.
  final DateTime? startedAt;

  /// Wall-clock time the recording ends: for a video, when its last frame
  /// stops showing (the start plus the video's duration).
  final DateTime? endedAt;

  const SessionRecordingPayload({
    required this.clipId,
    this.events = const [],
    this.startedAt,
    this.endedAt,
    this.approxBytes,
  });
}
