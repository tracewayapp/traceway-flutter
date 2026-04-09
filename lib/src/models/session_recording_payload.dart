class SessionRecordingPayload {
  final String exceptionId;
  final dynamic events;

  const SessionRecordingPayload({
    required this.exceptionId,
    required this.events,
  });

  Map<String, dynamic> toJson() => {
    'exceptionId': exceptionId,
    'events': events,
  };
}
