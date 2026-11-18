class TracewayEndpoints {
  const TracewayEndpoints({
    required this.base,
    required this.logs,
    required this.traces,
    required this.metrics,
    required this.opamp,
    required this.recordings,
  });

  /// Where the Traceway server is reachable, without a trailing slash.
  final String base;
  final String logs;
  final String traces;
  final String metrics;
  final String opamp;
  final String recordings;

  /// True for the SDK's own requests, which must not be recorded as network
  /// telemetry.
  bool isOwn(String url) =>
      url.startsWith('$base/api/otel/') || url.startsWith(recordings);
}

/// Derives every endpoint the SDK talks to from the URL half of the
/// connection string. Accepts the bare server URL as well as the 1.x form
/// that ended in `/api/report`, so existing connection strings keep working.
TracewayEndpoints resolveEndpoints(String apiUrl) {
  final base = apiUrl
      .trim()
      .replaceFirst(RegExp(r'/+$'), '')
      .replaceFirst(RegExp(r'/api/report$'), '')
      .replaceFirst(RegExp(r'/api$'), '');
  return TracewayEndpoints(
    base: base,
    logs: '$base/api/otel/v1/logs',
    traces: '$base/api/otel/v1/traces',
    metrics: '$base/api/otel/v1/metrics',
    opamp: '$base/api/otel/v1/opamp',
    recordings: '$base/api/recordings',
  );
}
