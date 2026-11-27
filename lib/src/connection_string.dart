import 'package:flutter/foundation.dart';

import 'guarded.dart';
import 'traceway_telemetry.dart';

/// Traceway Cloud: where the SDK sends to when no `baseUrl` is given.
const String defaultBaseUrl = 'https://cloud.tracewayapp.com';

/// A 1.x / 2.0 connection string read as the 2.1 start fields.
class ParsedConnectionString {
  final String token;
  final String baseUrl;

  const ParsedConnectionString({required this.token, required this.baseUrl});
}

const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2', '[::1]'};

/// The Traceway server [url] names, in the one form the SDK uses
/// (CONTRACT §16.1), or null when it is not an HTTP(S) URL with a host:
/// trimmed; `https://` added when there is no scheme (`http://` for
/// `localhost`, `127.0.0.1`, `10.0.2.2` and `[::1]`); query, fragment and
/// trailing slashes dropped; then a trailing `/api/report`, else `/api`
/// (once), and the slashes again. Any other path is kept: a server under a
/// sub-path stays reachable.
String? normalizeBaseUrl(String url) {
  var s = url.trim();
  if (s.isEmpty) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z\d+.-]*://').hasMatch(s)) {
    final authority = s.split(RegExp(r'[/?#]')).first;
    final host = authority.startsWith('[')
        ? authority.substring(0, authority.indexOf(']') + 1)
        : authority.split(':').first;
    s = '${_localHosts.contains(host.toLowerCase()) ? 'http' : 'https'}://$s';
  }
  final cut = s.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) s = s.substring(0, cut);
  s = s.replaceFirst(RegExp(r'/+$'), '');
  if (s.endsWith('/api/report')) {
    s = s.substring(0, s.length - '/api/report'.length);
  } else if (s.endsWith('/api')) {
    s = s.substring(0, s.length - '/api'.length);
  }
  s = s.replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(s);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  // In the form request URLs take (lowercase host, no default port), so the
  // SDK recognises its own requests.
  return uri.toString().replaceFirst(RegExp(r'/+$'), '');
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
