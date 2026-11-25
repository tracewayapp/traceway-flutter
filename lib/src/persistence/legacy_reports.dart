import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/endpoints.dart';

/// 1.x saved each exception together with its clip, without saving its project.
class LegacyReports {
  LegacyReports(this.pending, this.destination, this.httpClient);

  final Directory pending;
  final OtlpDestination? destination;
  final http.Client httpClient;
  Future<void>? _running;

  Future<void> drain() =>
      _running ??= _drain().whenComplete(() => _running = null);

  Future<void> _drain() async {
    final target = destination;
    final claimed =
        target == null ? null : Directory('${pending.path}/${target.key}');
    final cutoff = DateTime.now().subtract(const Duration(hours: 12));
    try {
      if (await pending.exists()) {
        await for (final file in pending.list(followLinks: false)) {
          if (file is Directory && file.path != claimed?.path) {
            await for (final old in file.list(followLinks: false)) {
              if (old is File &&
                  old.path.endsWith('.json') &&
                  (await old.lastModified()).isBefore(cutoff)) {
                await old.delete();
              }
            }
            if (await file.list().isEmpty) await file.delete();
          }
          if (file is! File || !file.path.endsWith('.json')) continue;
          if ((await file.lastModified()).isBefore(cutoff)) {
            await file.delete();
          } else if (claimed != null) {
            await claimed.create(recursive: true);
            await file.rename('${claimed.path}/${file.uri.pathSegments.last}');
          }
        }
      }
      if (target == null || claimed == null || !await claimed.exists()) return;
      await for (final file in claimed.list(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.json')) continue;
        if ((await file.lastModified()).isBefore(cutoff)) {
          await file.delete();
          continue;
        }
        final dynamic entry;
        try {
          entry = jsonDecode(await file.readAsString());
        } on FormatException {
          await file.delete();
          continue;
        }
        if (entry is! Map ||
            entry['exception'] is! Map ||
            (DateTime.tryParse(entry['createdAt'].toString())
                    ?.isAfter(cutoff) !=
                true)) {
          await file.delete();
          continue;
        }
        final body = jsonEncode({
          'collectionFrames': [
            {
              'stackTraces': [entry['exception']],
              if (entry['recording'] is Map)
                'sessionRecordings': [entry['recording']],
            }
          ],
        });
        final response = await httpClient
            .post(
              Uri.parse(target.url),
              headers: {
                ...target.headers,
                'Content-Type': 'application/json',
                'Content-Encoding': 'gzip'
              },
              body: gzip.encode(utf8.encode(body)),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) return;
        await file.delete();
      }
    } catch (_) {
      // A concurrent migration or interrupted upload can be retried on resume.
    }
  }
}
