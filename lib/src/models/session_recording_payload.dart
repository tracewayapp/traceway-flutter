/// One encoded screen-recording clip, as produced by the screen recorder.
class SessionRecordingPayload {
  /// Names the clip while it is encoded; not sent.
  final String clipId;

  /// A single `flutter_video` event carrying the base64 MP4.
  final List<Map<String, dynamic>> events;

  /// Wall-clock timestamp of the first frame in this recording.
  final DateTime? startedAt;

  /// Wall-clock timestamp of the last frame in this recording.
  final DateTime? endedAt;

  const SessionRecordingPayload({
    required this.clipId,
    this.events = const [],
    this.startedAt,
    this.endedAt,
  });
}
