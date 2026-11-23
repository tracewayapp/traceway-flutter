/// One OTLP/HTTP signal endpoint: the complete URL, used as given (nothing
/// is appended), and the headers sent with it.
class TracewayTelemetryEndpoint {
  const TracewayTelemetryEndpoint({required this.url, this.headers = const {}});

  /// The full signal URL, e.g. `https://logs.example.com/v1/logs`.
  final String url;

  /// Override [TracewayTelemetry.headers] key by key.
  final Map<String, String> headers;
}

/// Where logs, spans and metrics go when they should not go to Traceway: any
/// OTLP/HTTP receiver, such as an OpenTelemetry Collector, Grafana Cloud,
/// Honeycomb or a self-hosted backend. The same option as the browser SDK's
/// `telemetry`.
///
/// [url] is a base URL: `/v1/logs`, `/v1/traces` and `/v1/metrics` are
/// appended. [logs], [traces] and [metrics] override it per signal with a
/// complete URL. A signal neither names keeps going to Traceway (with a
/// connection string). URLs must be HTTP(S), without credentials, a query
/// or a fragment. The Traceway token is never sent to these destinations.
///
/// With a connection string, Traceway keeps the control plane: exceptions,
/// `captureMessage` issues and the SDK's session and control records go to
/// Traceway, as do OpAMP and screen recordings. Ordinary logs (console,
/// navigation, taps, custom events), network spans and metrics go to the
/// receivers configured here. Without a connection string the SDK runs
/// standalone and every record goes here.
class TracewayTelemetry {
  const TracewayTelemetry({
    this.url,
    this.headers = const {},
    this.logs,
    this.traces,
    this.metrics,
  });

  /// Base URL; `/v1/logs`, `/v1/traces` and `/v1/metrics` are appended.
  final String? url;

  /// Sent with every request to these destinations, e.g. an ingestion key.
  final Map<String, String> headers;

  final TracewayTelemetryEndpoint? logs;
  final TracewayTelemetryEndpoint? traces;
  final TracewayTelemetryEndpoint? metrics;

  /// [url], when it names something; an empty string counts as unset.
  String? get baseUrl {
    final value = url?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Whether every signal has somewhere to go without Traceway.
  bool get coversAllSignals =>
      baseUrl != null || (logs != null && traces != null && metrics != null);
}
