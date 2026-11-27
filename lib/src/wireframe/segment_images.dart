/// The serialized ASCII data URLs in one independently playable rrweb segment.
/// A repeated stylesheet costs its full length every time it is emitted.
const int _maxRasterUrlChars = 128 * 1024;

// The recorder generates one rule per raster picture or rasterized icon.
// Other CSS and text shown by the app are not encoded pictures.
int _rasterChars(String rule) {
  const prefix = 'url(data:image/';
  var total = 0;
  var from = 0;
  while (true) {
    final url = rule.indexOf(prefix, from);
    if (url < 0) return total;
    final close = rule.indexOf(')', url + prefix.length);
    if (close < 0) return total;
    total += close - (url + 4); // Exclude the CSS “url(” and “)”.
    from = close + 1;
  }
}

/// Walk the rrweb nodes and attribute mutations actually emitted. A UI frame
/// that reuses a style without serializing it costs nothing.
Iterable<Map<String, Object?>> _serializedNodes(
  List<Map<String, Object?>> events,
) sync* {
  for (final event in events) {
    final data = event['data'];
    if (data is! Map) continue;
    if (event['type'] == 2) {
      final stack = [data['node'] as Map<String, Object?>];
      while (stack.isNotEmpty) {
        final node = stack.removeLast();
        yield node;
        final children = node['childNodes'];
        if (children is List && children.isNotEmpty) {
          stack.addAll(children.reversed.cast<Map<String, Object?>>());
        }
      }
    } else if (event['type'] == 3 && data['source'] == 0) {
      for (final addition in data['adds'] as List) {
        yield addition['node'] as Map<String, Object?>;
      }
      yield* (data['attributes'] as List).cast<Map<String, Object?>>();
    }
  }
}

final _remoteBackground = RegExp(r'background-image:url\("[^"]*"\);');

/// Keep the recorded layout and event sequence when the pictures in this
/// segment would exceed the allowance. Attribute maps can be shared with the
/// frame ring and other exports, so replace them only in this serialization.
void limitWireframeSegmentImages(List<Map<String, Object?>> events) {
  var chars = 0;
  for (final node in _serializedNodes(events)) {
    final attrs = node['attributes'];
    if (attrs is! Map || attrs['_cssText'] is! String) continue;
    chars += _rasterChars(attrs['_cssText'] as String);
    if (chars > _maxRasterUrlChars) break;
  }
  if (chars <= _maxRasterUrlChars) return;

  final remoteImageIds = <int>{};
  for (final node in _serializedNodes(events)) {
    final attrs = node['attributes'];
    if (attrs is! Map<String, Object?>) continue;
    final changes = <String, Object?>{};
    final css = attrs['_cssText'];
    if (css is String && _rasterChars(css) > 0) {
      // The image and icon classes have layout-only placeholders in the
      // shared stylesheet. Keep the style node ID for subsequent mutations.
      changes['_cssText'] = '';
    }
    final id = node['id'] as int;
    final tag = node['tagName'];
    if (tag == 'img') {
      node['tagName'] = 'div';
      remoteImageIds.add(id);
    } else if (tag != null) {
      remoteImageIds.remove(id);
    }
    final remoteImage = remoteImageIds.contains(id);
    if (remoteImage && (tag == 'img' || attrs.containsKey('class'))) {
      changes['class'] = '${attrs['class'] ?? ''} im'.trim();
    }
    final style = attrs['style'];
    if (style is String && style.contains('background-image:url("')) {
      changes['style'] = style.replaceAll(
        _remoteBackground,
        'background-color:rgba(158,158,158,.22);',
      );
    }
    if (changes.isNotEmpty || remoteImage && attrs.containsKey('src')) {
      final updated = {...attrs, ...changes};
      if (remoteImage) updated.remove('src');
      node['attributes'] = updated;
    }
  }
}
