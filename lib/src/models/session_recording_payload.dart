import '../events/traceway_event.dart';

class SessionRecordingPayload {
  final String exceptionId;
  final List<Map<String, dynamic>> events;
  final List<LogEvent> logs;
  final List<TracewayEvent> actions;

  /// Wall-clock timestamp of the first frame / first event in this recording.
  /// Combined with [endedAt] this lets the backend align logs and actions
  /// (which carry their own absolute timestamps) onto the video timeline:
  /// `offsetIntoVideoMs = event.timestamp.difference(startedAt)`.
  final DateTime? startedAt;

  /// Wall-clock timestamp of the last frame / last event in this recording.
  final DateTime? endedAt;

  const SessionRecordingPayload({
    required this.exceptionId,
    this.events = const [],
    this.logs = const [],
    this.actions = const [],
    this.startedAt,
    this.endedAt,
  });

  Map<String, dynamic> toJson() => {
        'exceptionId': exceptionId,
        'events': events,
        if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
        if (logs.isNotEmpty)
          'logs': logs.map((e) => e.toJson()).toList(growable: false),
        if (actions.isNotEmpty)
          'actions': actions.map((e) => e.toJson()).toList(growable: false),
      };

  factory SessionRecordingPayload.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'] as List? ?? const [];
    final rawLogs = json['logs'] as List? ?? const [];
    final rawActions = json['actions'] as List? ?? const [];

    return SessionRecordingPayload(
      exceptionId: json['exceptionId'] as String,
      events: rawEvents
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList(growable: false),
      logs: rawLogs
          .map((e) => LogEvent.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false),
      actions: rawActions
          .map(
              (e) => TracewayEvent.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false),
      startedAt: json['startedAt'] != null
          ? DateTime.parse(json['startedAt'] as String)
          : null,
      endedAt: json['endedAt'] != null
          ? DateTime.parse(json['endedAt'] as String)
          : null,
    );
  }
}
