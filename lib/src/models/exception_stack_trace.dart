class ExceptionStackTrace {
  String? traceId;
  bool isTask;
  String stackTrace;
  DateTime recordedAt;
  Map<String, String>? attributes;
  bool isMessage;
  String? sessionRecordingId;
  String? distributedTraceId;

  /// Transient file ID for disk persistence. Not serialized to the API.
  String? fileId;

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

  factory ExceptionStackTrace.fromJson(Map<String, dynamic> json) {
    return ExceptionStackTrace(
      traceId: json['traceId'] as String?,
      isTask: json['isTask'] as bool? ?? false,
      stackTrace: json['stackTrace'] as String,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
      attributes: (json['attributes'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v.toString())),
      isMessage: json['isMessage'] as bool? ?? false,
      sessionRecordingId: json['sessionRecordingId'] as String?,
      distributedTraceId: json['distributedTraceId'] as String?,
    );
  }
}
