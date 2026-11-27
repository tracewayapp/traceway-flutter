/// Traceway Cloud: where the SDK sends to when no `baseUrl` is given.
const String defaultBaseUrl = 'https://cloud.tracewayapp.com';

/// Historical destination suffix used in connection strings and queue keys.
const legacyReportPath = '/api/report';

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
  final uri = Uri.tryParse(s);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith(legacyReportPath)) {
    path = path.substring(0, path.length - legacyReportPath.length);
  } else if (path.endsWith('/api')) {
    path = path.substring(0, path.length - '/api'.length);
  }
  return uri.replace(path: path.replaceFirst(RegExp(r'/+$'), '')).toString();
}
