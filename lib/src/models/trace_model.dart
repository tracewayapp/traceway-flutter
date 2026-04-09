import 'span.dart';

class Trace {
  final String id;
  final String endpoint;
  final int duration;
  final DateTime recordedAt;
  final int statusCode;
  final int bodySize;
  final String clientIP;
  final Map<String, String>? attributes;
  final List<Span>? spans;
  final bool isTask;
  final String? distributedTraceId;

  const Trace({
    required this.id,
    required this.endpoint,
    required this.duration,
    required this.recordedAt,
    this.statusCode = 0,
    this.bodySize = 0,
    this.clientIP = '',
    this.attributes,
    this.spans,
    this.isTask = false,
    this.distributedTraceId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'endpoint': endpoint,
    'duration': duration,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'statusCode': statusCode,
    'bodySize': bodySize,
    'clientIP': clientIP,
    'attributes': attributes ?? {},
    'spans': spans?.map((s) => s.toJson()).toList() ?? [],
    'isTask': isTask,
    'distributedTraceId': distributedTraceId ?? '',
  };
}
