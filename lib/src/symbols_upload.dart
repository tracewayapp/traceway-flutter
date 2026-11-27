/// The settings of `dart run traceway:upload_symbols` that are not I/O: where
/// each value comes from and where the symbols are sent. Plain Dart, no
/// Flutter, so the command-line tool can import it.
library;

/// Traceway Cloud: where symbols go when no flag, `TRACEWAY_URL` or
/// `traceway.url` names a self-hosted server.
const String symbolsUploadDefaultUrl = 'https://cloud.tracewayapp.com';

const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2', '[::1]'};

/// The first of [values] that is not blank, trimmed; null when all are.
String? firstNonEmpty(Iterable<String?> values) {
  for (final v in values) {
    if (v != null && v.trim().isNotEmpty) {
      return v.trim();
    }
  }
  return null;
}

/// The server the symbols go to: the `--url` flag, then `TRACEWAY_URL`
/// from [env], then `url` of the `traceway:` block of `pubspec.yaml`
/// ([pubspec]), then Traceway Cloud. A blank value counts as unset.
String resolveSymbolsUploadUrl({
  String? flag,
  Map<String, String> env = const {},
  Map<String, String> pubspec = const {},
}) =>
    firstNonEmpty([flag, env['TRACEWAY_URL'], pubspec['url']]) ??
    symbolsUploadDefaultUrl;

/// The upload endpoint of the server at [url], read the way the SDK reads
/// `baseUrl` (CONTRACT §16.1): `https://` added when there is no scheme
/// (`http://` for `localhost`, `127.0.0.1`, `10.0.2.2` and `[::1]`), query,
/// fragment and trailing slashes dropped, then a trailing `/api/report`,
/// else `/api`. A URL that already ends in the endpoint is kept.
String symbolsUploadEndpoint(String url) {
  var u = url.trim();
  if (!RegExp(r'^[a-zA-Z][a-zA-Z\d+.-]*://').hasMatch(u)) {
    final authority = u.split(RegExp(r'[/?#]')).first;
    final host = authority.startsWith('[')
        ? authority.substring(0, authority.indexOf(']') + 1)
        : authority.split(':').first;
    u = '${_localHosts.contains(host.toLowerCase()) ? 'http' : 'https'}://$u';
  }
  u = u.replaceFirst(RegExp(r'[?#].*$'), '').replaceFirst(RegExp(r'/+$'), '');
  if (u.endsWith('/api/symbols/upload')) {
    return u;
  }
  u = u
      .replaceFirst(RegExp(r'/api(/report)?$'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  return '$u/api/symbols/upload';
}

/// The `key: value` pairs of the top-level `traceway:` block of a
/// `pubspec.yaml` ([lines]), unquoted, without comments; blank values left
/// out.
Map<String, String> parsePubspecTracewayBlock(Iterable<String> lines) {
  final out = <String, String>{};
  var inBlock = false;
  for (final raw in lines) {
    final line = raw.replaceAll('\t', '  ');
    if (!inBlock) {
      if (RegExp(r'^traceway\s*:\s*(#.*)?$').hasMatch(line)) {
        inBlock = true;
      }
      continue;
    }
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
      continue;
    }
    if (line.length == line.trimLeft().length) {
      break;
    }
    final m = RegExp(r'^\s+([A-Za-z0-9_]+)\s*:\s*(.*)$').firstMatch(line);
    if (m != null) {
      final value = _unquote(_stripInlineComment(m.group(2)!.trim()));
      if (value.isNotEmpty) {
        out[m.group(1)!] = value;
      }
    }
  }
  return out;
}

String _stripInlineComment(String v) {
  if (v.startsWith('"') || v.startsWith("'")) {
    // A quoted value ends at its closing quote: `"https://host"  # comment`.
    final close = v.indexOf(v[0], 1);
    return close == -1 ? v : v.substring(0, close + 1);
  }
  final i = v.indexOf(' #');
  return i == -1 ? v : v.substring(0, i).trimRight();
}

String _unquote(String v) {
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}
