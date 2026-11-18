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

bool _isId(String segment) {
  if (_number.hasMatch(segment) || _uuid.hasMatch(segment)) return true;
  if (!_digit.hasMatch(segment)) return false;
  return _hex.hasMatch(segment) || _token.hasMatch(segment);
}

/// Turns a route path into something close to its template, so
/// `/orders/8841` and `/orders/8842` are one series: segments that are
/// numbers, UUIDs, or long hex or token strings become `:id`. The same rules
/// as the browser SDK and the server (`backend/app/clientmetrics/route.go`).
String normalizePath(String path) {
  final clean =
      path.split(RegExp('[?#]')).first.replaceFirst(RegExp(r'/+$'), '');
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
