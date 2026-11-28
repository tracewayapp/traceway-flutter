import 'dart:convert';
import 'dart:io';

import '../base_url.dart' show legacyReportPath;
import '../core/endpoints.dart';
import '../core/ids.dart';

/// One exception or message a 1.x build saved and never delivered.
class LegacyReport {
  const LegacyReport({
    required this.id,
    required this.stackTrace,
    required this.recordedAt,
    required this.attributes,
    required this.isMessage,
  });

  final String id;

  /// `Type: message` and the formatted frames (a message: its text).
  final String stackTrace;
  final DateTime recordedAt;
  final Map<String, String> attributes;
  final bool isMessage;
}

/// 1.x saved reports without an owner. 2.0 betas moved some into a directory
/// named for the exact legacy URL and credentials. Only a matching Traceway
/// project may convert those reports. Other files expire after 12 hours.
class LegacyReports {
  LegacyReports(this.pending, this.destinationKeys, this.deliver);

  final Directory pending;
  final Set<String> destinationKeys;
  final Future<bool> Function(LegacyReport report) deliver;
  Future<void>? _running;

  static const Duration maxAge = Duration(hours: 12);

  /// Old clients hashed the URL as supplied, before base URL normalization.
  static Set<String> keysFor(String base, String token) => {
        for (final suffix in ['', '/', '/api', '/api/', legacyReportPath, '$legacyReportPath/'])
          OtlpDestination('$base$suffix', {'Authorization': 'Bearer $token'}).key,
      };

  Future<void> convert() =>
      _running ??= _convert().whenComplete(() => _running = null);

  Future<void> _convert() async {
    final cutoff = DateTime.now().subtract(maxAge);
    try {
      if (!await pending.exists()) return;
      await for (final entry in pending.list(followLinks: false)) {
        if (entry is File) {
          if ((await entry.lastModified()).isBefore(cutoff)) await _delete(entry);
        } else if (entry is Directory) {
          final key = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
          await for (final file in entry.list(followLinks: false)) {
            if (file is! File || !file.path.endsWith('.json')) continue;
            if ((await file.lastModified()).isBefore(cutoff)) {
              await _delete(file);
            } else if (destinationKeys.contains(key)) {
              final report = await _read(file, cutoff);
              if (report == null || await deliver(report)) await _delete(file);
            }
          }
          if (await entry.list().isEmpty) await entry.delete();
        }
      }
      if (await pending.list().isEmpty) await pending.delete();
    } on FileSystemException {
      // A concurrent startup or interrupted cleanup is retried on flush.
    }
  }

  /// The report in [file], or null when it is too old, damaged or not a
  /// 1.x report.
  static Future<LegacyReport?> _read(File file, DateTime cutoff) async {
    try {
      if ((await file.lastModified()).isBefore(cutoff)) return null;
      final entry = jsonDecode(await file.readAsString());
      if (entry is! Map) return null;
      final createdAt = DateTime.tryParse('${entry['createdAt']}');
      final exception = entry['exception'];
      if (createdAt == null || !createdAt.isAfter(cutoff) || exception is! Map) {
        return null;
      }
      final stackTrace = exception['stackTrace'];
      if (stackTrace is! String || stackTrace.trim().isEmpty) return null;
      final recordedAt =
          DateTime.tryParse('${exception['recordedAt']}') ?? createdAt;
      final attributes = exception['attributes'];
      // A retry after a lost acknowledgment must carry the same exception ID.
      final digest = destinationDigest([
        file.parent.path.split(Platform.pathSeparator).last,
        file.uri.pathSegments.last,
        createdAt.toIso8601String(),
      ]);
      final id = hexToBytes(digest.substring(0, 32))!;
      id[6] = (id[6] & 0x0f) | 0x80;
      id[8] = (id[8] & 0x3f) | 0x80;
      return LegacyReport(
        id: bytesToUuid(id),
        stackTrace: stackTrace,
        recordedAt: recordedAt,
        attributes: {
          if (attributes is Map)
            for (final MapEntry(:key, :value) in attributes.entries)
              if (value != null) '$key': '$value',
        },
        isMessage: exception['isMessage'] == true,
      );
    } catch (_) {
      // Unreadable or not JSON: dropped with the file.
      return null;
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Gone already, or stuck: either way the conversion goes on.
    }
  }
}
