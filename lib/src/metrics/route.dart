const int _maxSegments = 6;
const int _maxLength = 64;
const String _id = ':id';

final RegExp _number = RegExp(r'^\d+$');
final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false);
final RegExp _hex = RegExp(r'^[0-9a-f]{8,}$', caseSensitive: false);
final RegExp _token = RegExp(r'^[A-Za-z0-9_\-=.~]{20,}$');
final RegExp _digit = RegExp(r'\d');
// A percent-encoded ASCII character (a space, a slash, a brace) is a value
// somebody typed, never a route literal. Encoded UTF-8 bytes (%C3%A9) stay.
final RegExp _encodedAscii = RegExp(r'%[0-7][0-9a-f]', caseSensitive: false);

bool _isId(String segment) {
  if (_number.hasMatch(segment) || _uuid.hasMatch(segment)) return true;
  if (_encodedAscii.hasMatch(segment)) return true;
  if (!_digit.hasMatch(segment)) return false;
  return _hex.hasMatch(segment) || _token.hasMatch(segment);
}

/// Where the query string or fragment begins, or -1. In a route template a
/// `?` ends an optional parameter (`/:lang?/about`) and is kept.
int _queryStart(String path) {
  for (var i = 0; i < path.length; i++) {
    if (path[i] == '#') return i;
    if (path[i] != '?') continue;
    final segment = i == 0 ? 0 : path.lastIndexOf('/', i - 1) + 1;
    final optionalParam =
        path[segment] == ':' && i + 1 < path.length && path[i + 1] == '/';
    if (!optionalParam) return i;
  }
  return -1;
}

/// Turns a route path into something close to its template, so
/// `/orders/8841` and `/orders/8842` are one series: segments that are
/// numbers, UUIDs, long hex or token strings, or that carry a
/// percent-encoded ASCII character become `:id`. The same rules
/// as the browser SDK and the server (`backend/app/clientmetrics/route.go`).
String normalizePath(String path) {
  final end = _queryStart(path);
  final clean = (end < 0 ? path : path.substring(0, end))
      .replaceFirst(RegExp(r'/+$'), '');
  if (clean.isEmpty) return '/';
  final segments = clean.split('/').where((s) => s.isNotEmpty).toList();
  var truncated = segments.length > _maxSegments;
  final kept = [
    for (final segment in segments.take(_maxSegments))
      _isId(segment) ? _id : segment,
  ];
  var out = '/${kept.join('/')}';
  while (kept.length > 1 && out.length + (truncated ? 2 : 0) > _maxLength) {
    kept.removeLast();
    truncated = true;
    out = '/${kept.join('/')}';
  }
  if (truncated) out += '/*';
  return out.length > _maxLength ? out.substring(0, _maxLength) : out;
}
