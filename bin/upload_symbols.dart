import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('token',
        help: 'Upload token. Defaults to \$TRACEWAY_UPLOAD_TOKEN, then the '
            'traceway.upload_token field in pubspec.yaml.')
    ..addOption('url',
        help: 'Traceway base URL or report URL. Defaults to \$TRACEWAY_URL, '
            'then traceway.url in pubspec.yaml, then Traceway Cloud.')
    ..addOption('symbols-dir',
        help: 'Directory passed to --split-debug-info. Defaults to '
            'traceway.symbols_dir in pubspec.yaml, then build/symbols.')
    ..addOption('app',
        help: 'Path to the built .app (or App.framework/App) for Apple builds, '
            'whose Mach-O UUID is the debug id. Auto-discovered under build/ '
            'when omitted; not needed for Android.')
    ..addFlag('dry-run',
        negatable: false,
        help: 'Resolve config and list what would be uploaded, without sending.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(2);
  }

  if (args['help'] == true) {
    stdout.writeln('Upload Dart/Flutter debug symbols to Traceway.\n');
    stdout.writeln(parser.usage);
    return;
  }

  final cfg = _readPubspecConfig();
  final env = Platform.environment;

  final token = _firstNonEmpty([
    args['token'] as String?,
    env['TRACEWAY_UPLOAD_TOKEN'],
    cfg['upload_token'],
  ]);
  final url = _firstNonEmpty([
        args['url'] as String?,
        env['TRACEWAY_URL'],
        cfg['url'],
      ]) ??
      'https://cloud.tracewayapp.com';
  final symbolsDir = _firstNonEmpty([
        args['symbols-dir'] as String?,
        cfg['symbols_dir'],
      ]) ??
      'build/symbols';
  final appPath = _firstNonEmpty([args['app'] as String?, cfg['app']]);

  if (token == null) {
    stderr.writeln(
        'No upload token. Set TRACEWAY_UPLOAD_TOKEN, pass --token, or add '
        'traceway.upload_token to pubspec.yaml.');
    exit(2);
  }

  final dir = Directory(symbolsDir);
  if (!dir.existsSync()) {
    stderr.writeln('symbols-dir not found: $symbolsDir\n'
        'Build with --split-debug-info=$symbolsDir first.');
    exit(1);
  }

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.symbols'))
      .toList();
  if (files.isEmpty) {
    stderr.writeln('no .symbols files found in $symbolsDir');
    exit(1);
  }

  final uploadUrl = _deriveUploadUrl(url);

  if (args['dry-run'] == true) {
    stdout.writeln('dry run — would upload to $uploadUrl');
    for (final file in files) {
      final arch = _archFromFilename(file.path);
      final debugId = _debugIdFor(file, arch, appPath) ?? '<unknown>';
      stdout.writeln('  ${file.uri.pathSegments.last} (arch=$arch debug_id=$debugId)');
    }
    return;
  }

  var uploaded = 0;
  for (final file in files) {
    final arch = _archFromFilename(file.path);
    final name = file.uri.pathSegments.last;

    final debugId = _debugIdFor(file, arch, appPath);
    if (debugId == null) {
      stderr.writeln('skipping $name: could not determine its debug id. The '
          'file has no build-id note (Apple builds), so point --app at your '
          'built .app so its Mach-O UUID can be read.');
      continue;
    }

    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl))
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['arch'] = arch
      ..fields['debug_id'] = debugId
      ..files.add(await http.MultipartFile.fromPath('files', file.path));

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode == 200) {
      stdout.writeln('uploaded $name (arch=$arch debug_id=$debugId)');
      uploaded++;
    } else {
      stderr.writeln('failed $name: HTTP ${response.statusCode} $body');
    }
  }

  stdout.writeln('done: $uploaded/${files.length} uploaded -> $uploadUrl');
  if (uploaded != files.length) {
    exit(1);
  }
}

String? _debugIdFor(File file, String arch, String? appPath) {
  final fromNote = _elfBuildId(file);
  if (fromNote != null) {
    return fromNote;
  }
  return _machoUuid(arch, appPath);
}

String? _elfBuildId(File file) {
  final b = file.readAsBytesSync();
  if (b.length < 4 || b[0] != 0x7f || b[1] != 0x45 || b[2] != 0x4c || b[3] != 0x46) {
    return null;
  }
  for (var i = 0; i + 16 <= b.length; i++) {
    if (b[i] == 0x04 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 0 &&
        b[i + 8] == 0x03 && b[i + 9] == 0 && b[i + 10] == 0 && b[i + 11] == 0 &&
        b[i + 12] == 0x47 && b[i + 13] == 0x4e && b[i + 14] == 0x55 && b[i + 15] == 0x00) {
      final descsz = b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
      final start = i + 16;
      if (descsz > 0 && start + descsz <= b.length) {
        final sb = StringBuffer();
        for (var j = 0; j < descsz; j++) {
          sb.write(b[start + j].toRadixString(16).padLeft(2, '0'));
        }
        return sb.toString();
      }
    }
  }
  return null;
}

String? _machoUuid(String arch, String? appPath) {
  final binary = _findAppBinary(appPath);
  if (binary == null) {
    return null;
  }
  ProcessResult res;
  try {
    res = Process.runSync('dwarfdump', ['--uuid', binary]);
  } catch (_) {
    return null;
  }
  if (res.exitCode != 0) {
    return null;
  }
  final want = _normArch(arch);
  final re = RegExp(r'UUID:\s*([0-9A-Fa-f-]+)\s*\(([^)]+)\)');
  for (final line in (res.stdout as String).split('\n')) {
    final m = re.firstMatch(line);
    if (m != null && _normArch(m.group(2)!) == want) {
      return m.group(1)!.replaceAll('-', '').toLowerCase();
    }
  }
  return null;
}

String _normArch(String a) {
  a = a.trim().toLowerCase();
  if (a == 'x86_64' || a == 'amd64') return 'x64';
  if (a == 'aarch64') return 'arm64';
  return a;
}

String? _findAppBinary(String? appPath) {
  if (appPath != null && appPath.isNotEmpty) {
    return _resolveAppBinary(appPath);
  }
  for (final base in [
    'build/macos/Build/Products/Release',
    'build/ios/iphoneos',
    'build/ios/Release-iphoneos',
  ]) {
    final d = Directory(base);
    if (!d.existsSync()) continue;
    for (final e in d.listSync()) {
      if (e.path.endsWith('.app')) {
        final bin = _resolveAppBinary(e.path);
        if (bin != null) return bin;
      }
    }
  }
  return null;
}

String? _resolveAppBinary(String p) {
  if (FileSystemEntity.typeSync(p) == FileSystemEntityType.file) {
    return p;
  }
  for (final rel in [
    'Contents/Frameworks/App.framework/App',
    'Frameworks/App.framework/App',
  ]) {
    final candidate = '${p.replaceAll(RegExp(r'/+$'), '')}/$rel';
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

String? _firstNonEmpty(List<String?> values) {
  for (final v in values) {
    if (v != null && v.trim().isNotEmpty) {
      return v.trim();
    }
  }
  return null;
}

Map<String, String> _readPubspecConfig() {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    return {};
  }
  final out = <String, String>{};
  var inBlock = false;
  for (final raw in file.readAsLinesSync()) {
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
    return v;
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

String _deriveUploadUrl(String url) {
  var u = url.trim();
  if (u.contains('/api/report')) {
    return u.replaceFirst('/api/report', '/api/symbols/upload');
  }
  if (u.endsWith('/api/symbols/upload')) {
    return u;
  }
  u = u.replaceAll(RegExp(r'/+$'), '');
  return '$u/api/symbols/upload';
}

String _archFromFilename(String path) {
  final base = path.split(RegExp(r'[/\\]')).last;
  final stem =
      base.endsWith('.symbols') ? base.substring(0, base.length - 8) : base;
  final dash = stem.lastIndexOf('-');
  return dash == -1 ? '' : stem.substring(dash + 1);
}
