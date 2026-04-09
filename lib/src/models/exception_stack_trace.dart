class ExceptionStackTrace {
  String? traceId;
  bool isTask;
  String stackTrace;
  DateTime recordedAt;
  Map<String, String>? attributes;
  bool isMessage;
  String? sessionRecordingId;
  String? distributedTraceId;

  ExceptionStackTrace({
    this.traceId,
    this.isTask = false,
    required this.stackTrace,
    required this.recordedAt,
    this.attributes,
    this.isMessage = false,
    this.sessionRecordingId,
    this.distributedTraceId,
  });

  Map<String, dynamic> toJson() => {
    'traceId': traceId,
    'isTask': isTask,
    'stackTrace': stackTrace,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'attributes': attributes ?? {},
    'isMessage': isMessage,
    'sessionRecordingId': sessionRecordingId,
    'distributedTraceId': distributedTraceId,
  };
}
