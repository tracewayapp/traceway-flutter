import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../traceway_telemetry.dart';

String destinationDigest(List<String> parts) =>
    sha256.convert(utf8.encode(jsonEncode(parts))).toString();

/// Where one OTLP signal is sent, and with which headers.
class OtlpDestination {
  const OtlpDestination(this.url, this.headers, {this.external = false});

  final String url;
  final Map<String, String> headers;

  /// Not Traceway: a receiver from [TracewayTelemetry].
  final bool external;

  /// Identifies the destination, for state kept per destination (queued
  /// batches, pending metrics), so a changed receiver is never sent what
  /// was meant for the previous one.
  String get key {
    final normalized = {
      for (final e in headers.entries) e.key.toLowerCase(): e.value
    };
    return destinationDigest([
      external ? 'collector' : 'traceway',
      url,
      for (final name in normalized.keys.toList()..sort()) ...[
        name,
        normalized[name]!
      ],
    ]);
  }
}

class TracewayEndpoints {
  const TracewayEndpoints({
    required this.base,
    required this.logs,
    required this.traces,
    required this.metrics,
    required this.opamp,
    required this.recordings,
  });

  /// Where the Traceway server is reachable, without a trailing slash. Empty
  /// when the SDK runs standalone.
  final String base;
  final String logs;
  final String traces;
  final String metrics;
  final String opamp;
  final String recordings;

  /// True for the SDK's own requests, which must not be recorded as network
  /// telemetry.
  bool isOwn(String url) =>
      base.isNotEmpty &&
      (url.startsWith('$base/api/otel/') || url.startsWith(recordings));
}

/// Derives every endpoint the SDK talks to from the URL half of the
/// connection string. Accepts the bare server URL as well as the 1.x form
/// that ended in `/api/report`, so existing connection strings keep working.
TracewayEndpoints resolveEndpoints(String apiUrl) {
  final trimmed = apiUrl
      .trim()
      .replaceFirst(RegExp(r'/+$'), '')
      .replaceFirst(RegExp(r'/api/report$'), '')
      .replaceFirst(RegExp(r'/api$'), '');
  // In the form request URLs take (lowercase host, no default port), so
  // [TracewayEndpoints.isOwn] recognises the SDK's own requests.
  final base = trimmed.isEmpty ? trimmed : Uri.parse(trimmed).toString();
  return TracewayEndpoints(
    base: base,
    logs: '$base/api/otel/v1/logs',
    traces: '$base/api/otel/v1/traces',
    metrics: '$base/api/otel/v1/metrics',
    opamp: '$base/api/otel/v1/opamp',
    recordings: '$base/api/recordings',
  );
}

/// The destination of every OTLP signal: Traceway's, or the receiver the
/// app configured in [TracewayTelemetry].
class TelemetryRoutes {
  TelemetryRoutes._(this.logs, this.traces, this.metrics, this.traceway);

  final OtlpDestination logs;
  final OtlpDestination traces;
  final OtlpDestination metrics;

  /// Traceway's own log endpoint, for exceptions, messages and the SDK's
  /// control records when ordinary logs go elsewhere. Null when the SDK runs
  /// standalone.
  final OtlpDestination? traceway;

  /// Whether logs go somewhere other than Traceway while Traceway still
  /// receives issues and session records.
  bool get splitsLogs => logs.external && traceway != null;

  /// True for requests to any destination of the SDK.
  bool isOwn(String url) =>
      (logs.external && url.startsWith(logs.url)) ||
      (traces.external && url.startsWith(traces.url)) ||
      (metrics.external && url.startsWith(metrics.url));

  /// [endpoints] and [token] are null when the SDK runs standalone; then
  /// [telemetry] must name a destination for every signal.
  static TelemetryRoutes resolve(
    TracewayEndpoints? endpoints,
    String? token,
    TracewayTelemetry? telemetry,
  ) {
    final auth = <String, String>{
      if (token != null) 'Authorization': 'Bearer $token',
    };
    OtlpDestination route(
      String kind,
      TracewayTelemetryEndpoint? endpoint,
      String? tracewayUrl,
    ) {
      final base = telemetry?.baseUrl;
      if (endpoint == null && base == null) {
        if (tracewayUrl == null) {
          throw ArgumentError(
              'TracewayTelemetry has no destination for $kind: standalone '
              'telemetry needs a base url or all three signal endpoints');
        }
        return OtlpDestination(tracewayUrl, auth);
      }
      final url = _checkedUrl(endpoint?.url ?? base!);
      return OtlpDestination(
        endpoint != null
            ? url
            : '${url.replaceFirst(RegExp(r'/+$'), '')}/v1/$kind',
        {...?telemetry?.headers, ...?endpoint?.headers},
        external: true,
      );
    }

    return TelemetryRoutes._(
      route('logs', telemetry?.logs, endpoints?.logs),
      route('traces', telemetry?.traces, endpoints?.traces),
      route('metrics', telemetry?.metrics, endpoints?.metrics),
      endpoints == null ? null : OtlpDestination(endpoints.logs, auth),
    );
  }

  static String _checkedUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError('TracewayTelemetry url must be an HTTP(S) URL '
          'without credentials, query, or fragment: $raw');
    }
    return uri.toString();
  }
}
