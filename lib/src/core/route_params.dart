/// Rebuilds a route template from a path and the parameters a router
/// matched in it, as the browser SDK does: `/orders/8841` with
/// `{'id': '8841'}` is `/orders/:id`. For routers that hand out parameters
/// but not the pattern; go_router's `state.fullPath` already is the
/// template. A value of several segments (a `List<String>`, or a value with
/// a `/`) becomes `:name*`, and `*` stays `*`. A parameter whose value is
/// not found in the path is left out.
///
/// ```dart
/// Traceway.setRoute(routeFromParams(state.uri.path, state.pathParameters));
/// ```
String routeFromParams(String path, Map<String, Object?>? params) {
  final cut = path.indexOf(RegExp('[?#]'));
  final segments = (cut < 0 ? path : path.substring(0, cut))
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  final plain = segments.map(_decoded).toList();
  final taken = List<bool>.filled(segments.length, false, growable: true);

  final entries = <({String key, bool many, List<String> parts, int order})>[];
  var order = 0;
  for (final MapEntry(:key, :value) in (params ?? const {}).entries) {
    final many = value is List;
    final List<String> parts = [
      for (final part in value is List
          ? value.map((v) => '${v ?? ''}')
          : '${value ?? ''}'.split('/'))
        if (part.isNotEmpty) _decoded(part),
    ];
    if (value == null || parts.isEmpty) continue;
    entries.add((key: key, many: many, parts: parts, order: order++));
  }
  // Routers list parameters in path order and the search below runs from
  // the end of the path, so the last parameter goes first: of two equal
  // values each takes its own segment, and a value equal to a static
  // segment names the deeper one. Longest first, so a catch-all is not
  // broken up by a one-segment parameter inside it.
  entries.sort((a, b) {
    final byLength = b.parts.length.compareTo(a.parts.length);
    return byLength != 0 ? byLength : b.order.compareTo(a.order);
  });

  for (final (:key, :many, :parts, order: _) in entries) {
    for (var start = segments.length - parts.length; start >= 0; start--) {
      var fits = true;
      for (var i = 0; i < parts.length; i++) {
        if (taken[start + i] || plain[start + i] != parts[i]) {
          fits = false;
          break;
        }
      }
      if (!fits) continue;
      final name = key == '*'
          ? '*'
          : many || parts.length > 1
              ? ':$key*'
              : ':$key';
      segments.replaceRange(start, start + parts.length, [name]);
      plain.replaceRange(start, start + parts.length, [name]);
      taken.replaceRange(start, start + parts.length, [true]);
      break;
    }
  }
  return '/${segments.join('/')}';
}

String _decoded(String segment) {
  try {
    return Uri.decodeComponent(segment);
  } catch (_) {
    return segment;
  }
}
