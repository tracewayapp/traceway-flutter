import 'package:flutter/foundation.dart';

import 'base_url.dart';
import 'guarded.dart';
import 'traceway_telemetry.dart';

export 'base_url.dart' show defaultBaseUrl, normalizeBaseUrl;

/// A 1.x / 2.0 connection string read as the 2.1 start fields.
class ParsedConnectionString {
  final String token;
  final String baseUrl;

  const ParsedConnectionString({required this.token, required this.baseUrl});
}

/// `token@url` as its token and normalized [normalizeBaseUrl] server, or
/// null when it is not one: split at the first `@`, both halves trimmed, a
/// token that is not empty and a URL the normalizer takes.
ParsedConnectionString? parseConnectionString(String connectionString) {
  final s = connectionString.trim();
  final at = s.indexOf('@');
  if (at <= 0) return null;
  final token = s.substring(0, at).trim();
  final baseUrl = normalizeBaseUrl(s.substring(at + 1));
  if (token.isEmpty || baseUrl == null) return null;
  return ParsedConnectionString(token: token, baseUrl: baseUrl);
}

/// Where the SDK sends: the project token and the Traceway server, or no
/// token when it runs standalone (only [TracewayOptions.telemetry]).
class TracewayStart {
  const TracewayStart(this.token, this.baseUrl);

  /// Null: standalone.
  final String? token;
  final String baseUrl;
}

final Set<String> _warned = {};

@visibleForTesting
void resetStartWarningsForTest() => _warned.clear();

/// Printed once per [kind] per process, debug output or not: the app asked
/// for something it does not get.
void _warnOnce(String kind, String message) {
  if (!_warned.add(kind)) return;
  guarded('start warning', () => debugPrint(message));
}

/// What `Traceway.run` / `TracewayClient.initialize` were given, resolved
/// (CONTRACT §16): [token] and [baseUrl] (Traceway Cloud by default), or the
/// deprecated [connectionString], read as `token` + `baseUrl` with one
/// deprecation warning per process that names the new form (never the
/// token). An empty token, a build without its `--dart-define`, counts as
/// none.
///
/// Null, after one warning, when the connection string or [baseUrl] is not
/// one the SDK can use: the SDK stays off, nothing throws. Throws an
/// [ArgumentError] that says what to pass when there is neither a token nor
/// a [telemetry] destination for every signal.
TracewayStart? resolveStart({
  String? token,
  String? baseUrl,
  String? connectionString,
  TracewayTelemetry? telemetry,
}) {
  String? resolvedToken =
      token == null || token.trim().isEmpty ? null : token.trim();
  String? resolvedBase;
  if (baseUrl != null && baseUrl.trim().isNotEmpty) {
    resolvedBase = normalizeBaseUrl(baseUrl);
    if (resolvedBase == null) {
      _warnOnce(
          'baseUrl',
          'Traceway: baseUrl must be an HTTP(S) URL such as '
              'https://cloud.tracewayapp.com, got "${baseUrl.trim()}"; the '
              'SDK is off.');
      return null;
    }
  }
  if (connectionString != null && connectionString.trim().isNotEmpty) {
    final parsed = parseConnectionString(connectionString);
    if (parsed == null) {
      _warnOnce(
          'connectionString',
          'Traceway: the connection string is not valid (expected '
              'YOUR_TOKEN@https://cloud.tracewayapp.com); the SDK is off. '
              "Connection strings are deprecated: use Traceway.run(token: "
              "'YOUR_TOKEN', child: …).");
      return null;
    }
    resolvedToken ??= parsed.token;
    resolvedBase ??= parsed.baseUrl;
    final named =
        resolvedBase == defaultBaseUrl ? '' : ", baseUrl: '$resolvedBase'";
    _warnOnce(
        'deprecated',
        'Traceway: connection strings are deprecated: use '
            "Traceway.run(token: '…'$named, child: …).");
  }
  if (resolvedToken == null && telemetry?.coversAllSignals != true) {
    throw ArgumentError("Traceway needs a token, as in Traceway.run(token: "
        "'YOUR_TOKEN', child: …): is --dart-define=TRACEWAY_TOKEN set in this "
        'build? Without a token, TracewayOptions.telemetry (a url, or all '
        'three of logs, traces and metrics) sends to another OpenTelemetry '
        'provider.');
  }
  return TracewayStart(resolvedToken, resolvedBase ?? defaultBaseUrl);
}
