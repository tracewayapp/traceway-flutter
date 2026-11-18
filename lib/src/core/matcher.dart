import 'dart:math' as math;

import 'settings.dart';

/// Resolves a matcher key such as `event.name` or
/// `attributes.http.response.status_code` to a value.
typedef FieldLookup = Object? Function(String key);

double? _asNumber(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String && value.trim().isNotEmpty) {
    final n = double.tryParse(value.trim());
    if (n != null && n.isFinite) return n;
  }
  return null;
}

bool _same(Object? actual, Object? expected) {
  if (actual == expected) return true;
  if (actual == null) return false;
  final a = _asNumber(actual);
  final e = _asNumber(expected);
  if (a != null && e != null) return a == e;
  return actual.toString() == expected.toString();
}

final RegExp _versionPattern = RegExp(r'^v?(\d+(?:\.\d+)*)');

List<int>? _versionParts(String version) {
  final match = _versionPattern.firstMatch(version.trim());
  if (match == null) return null;
  return match.group(1)!.split('.').map(int.parse).toList();
}

int? compareVersions(String a, String b) {
  final pa = _versionParts(a);
  final pb = _versionParts(b);
  if (pa == null || pb == null) return null;
  for (var i = 0; i < math.max(pa.length, pb.length); i++) {
    final diff = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (diff != 0) return diff < 0 ? -1 : 1;
  }
  return 0;
}

final RegExp _comparatorPattern = RegExp(r'^(>=|<=|>|<|==|=|!=)?(.+)$');

/// Checks a version against a constraint such as `>=2.1 <3` (comparators
/// separated by spaces or commas, all must hold).
bool satisfiesVersion(String version, String constraint) {
  final comparators =
      constraint.split(RegExp(r'[\s,]+')).where((c) => c.isNotEmpty).toList();
  if (comparators.isEmpty) return false;
  for (final comparator in comparators) {
    final match = _comparatorPattern.firstMatch(comparator);
    if (match == null) return false;
    final cmp = compareVersions(version, match.group(2)!);
    if (cmp == null) return false;
    final ok = switch (match.group(1)) {
      '>=' => cmp >= 0,
      '<=' => cmp <= 0,
      '>' => cmp > 0,
      '<' => cmp < 0,
      '!=' => cmp != 0,
      _ => cmp == 0,
    };
    if (!ok) return false;
  }
  return true;
}

/// Text conditions look at most at this much of a value, so a huge log line
/// cannot stall the app.
const _maxMatchText = 4096;

String _text(Object? value) {
  final s = value is String ? value : value.toString();
  return s.length > _maxMatchText ? s.substring(0, _maxMatchText) : s;
}

/// Case-insensitive wildcard match: `*` is any run of characters, `?` one
/// character, everything else literal. Greedy with a single backtrack point,
/// so it runs in O(text × pattern) at worst.
bool globMatch(String value, String pattern) {
  final t = value.toLowerCase();
  final p = pattern.toLowerCase();
  var ti = 0, pi = 0, star = -1, mark = 0;
  while (ti < t.length) {
    if (pi < p.length && (p[pi] == '?' || p[pi] == t[ti])) {
      ti++;
      pi++;
    } else if (pi < p.length && p[pi] == '*') {
      star = pi++;
      mark = ti;
    } else if (star >= 0) {
      pi = star + 1;
      ti = ++mark;
    } else {
      return false;
    }
  }
  while (pi < p.length && p[pi] == '*') {
    pi++;
  }
  return pi == p.length;
}

bool _evaluate(Condition condition, FieldLookup lookup) {
  final actual = lookup(condition.key);
  final present = actual != null && actual != '';
  final value = condition.value;
  switch (condition.op) {
    case 'exists':
      return present;
    case 'not_exists':
      return !present;
    case 'eq':
      return _same(actual, value);
    case 'neq':
      return !_same(actual, value);
    case 'in':
      return (condition.values ?? const []).any((v) => _same(actual, v));
    case 'not_in':
      return !(condition.values ?? const []).any((v) => _same(actual, v));
    case 'contains':
      return present && value != null && _text(actual).contains('$value');
    case 'icontains':
      return present &&
          value != null &&
          _text(actual).toLowerCase().contains('$value'.toLowerCase());
    case 'starts_with':
      return present && value != null && _text(actual).startsWith('$value');
    case 'glob':
      return present && value != null && globMatch(_text(actual), '$value');
    case 'gt':
    case 'gte':
    case 'lt':
    case 'lte':
      final a = _asNumber(actual);
      final e = _asNumber(value);
      if (a == null || e == null) return false;
      return switch (condition.op) {
        'gt' => a > e,
        'gte' => a >= e,
        'lt' => a < e,
        _ => a <= e,
      };
    case 'version':
      return present && value != null && satisfiesVersion('$actual', '$value');
  }
  return false;
}

/// Lookup keys of the tap and hover events the app feeds to triggers: the
/// action and a function that tests a selector against the widget under the
/// pointer.
const String keyPointerAction = 'browser.action';
const String keyTargetMatches = 'browser.target.matches';

final RegExp _routeParameter = RegExp(r'^\{[A-Za-z_][A-Za-z0-9_]*\}$');
final Uri _pathBase = Uri.parse('https://traceway.invalid/');

String _decoded(String segment) {
  try {
    return Uri.decodeComponent(segment);
  } catch (_) {
    return segment;
  }
}

/// The path part of a navigation target such as `/users/42?tab=1`, as the
/// browser SDK reads `location.pathname`.
String? pathOf(Object? url) {
  if (url == null || url == '') return null;
  try {
    return _pathBase.resolve(url.toString()).path;
  } catch (_) {
    return null;
  }
}

/// `/users/{id}` matches exactly one non-empty segment in that place; other
/// segments compare as written or percent-decoded, case-sensitively.
bool matchesRoute(String pattern, String path) {
  final expected = pattern.split('/');
  final actual = path.split('/');
  if (expected.length != actual.length) return false;
  for (var i = 0; i < expected.length; i++) {
    final part = expected[i];
    if (_routeParameter.hasMatch(part)) {
      if (actual[i].isEmpty) return false;
    } else if (part != actual[i] && part != _decoded(actual[i])) {
      return false;
    }
  }
  return true;
}

bool _matchesEvent(EventMatcher matcher, FieldLookup lookup) {
  switch (matcher.type) {
    case 'click':
    case 'hover':
      final test = lookup(keyTargetMatches);
      return lookup(keyPointerAction) == matcher.type &&
          test is bool Function(String) &&
          test(matcher.value);
    case 'log':
      final name = lookup('event.name');
      final signal = lookup('signal');
      if (name != 'browser.console' &&
          name != 'traceway.message' &&
          signal != 'console' &&
          signal != 'messages') {
        return false;
      }
      var body = lookup('body')?.toString() ?? '';
      if (body.length > _maxMatchText) body = body.substring(0, _maxMatchText);
      return matcher.mode == 'contains'
          ? body.contains(matcher.value)
          : body == matcher.value;
    case 'navigation':
      if (lookup('event.name') != 'browser.navigation') return false;
      final path = pathOf(lookup('attributes.url.full'));
      return path != null && matchesRoute(matcher.value, path);
  }
  return false;
}

bool matches(Matcher matcher, FieldLookup lookup) => switch (matcher) {
      EventMatcher e => _matchesEvent(e, lookup),
      Condition c => _evaluate(c, lookup),
      AllMatcher m => m.items.every((i) => matches(i, lookup)),
      AnyMatcher m => m.items.any((i) => matches(i, lookup)),
      NotMatcher m => !matches(m.inner, lookup),
    };
