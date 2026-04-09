import 'exception_stack_trace.dart';
import 'metric_record.dart';
import 'trace_model.dart';
import 'session_recording_payload.dart';

class CollectionFrame {
  final List<ExceptionStackTrace> stackTraces;
  final List<MetricRecord> metrics;
  final List<Trace> traces;
  final List<SessionRecordingPayload>? sessionRecordings;

  const CollectionFrame({
    required this.stackTraces,
    this.metrics = const [],
    this.traces = const [],
    this.sessionRecordings,
  });

  Map<String, dynamic> toJson() => {
    'stackTraces': stackTraces.map((e) => e.toJson()).toList(),
    'metrics': metrics.map((e) => e.toJson()).toList(),
    'traces': traces.map((e) => e.toJson()).toList(),
    if (sessionRecordings != null)
      'sessionRecordings':
          sessionRecordings!.map((e) => e.toJson()).toList(),
  };
}
