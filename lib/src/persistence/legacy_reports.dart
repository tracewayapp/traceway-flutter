import 'dart:convert';
import 'dart:io';

/// One exception or message a 1.x build saved and never delivered.
class LegacyReport {
  const LegacyReport({
    required this.stackTrace,
    required this.recordedAt,
    required this.attributes,
    required this.isMessage,
  });

  /// `Type: message` and the formatted frames (a message: its text).
  final String stackTrace;
  final DateTime recordedAt;
  final Map<String, String> attributes;
  final bool isMessage;
}

/// 1.x saved each exception, with its video clip, as a JSON file in
/// `traceway_pending`, without its project (2.0 betas moved some into a
/// directory per destination there). Nothing is sent to the 1.x
/// `/api/report` endpoint any more: every report still within 1.x's
/// 12 hours becomes a record of the running SDK, through its normal path
/// ([emit]: OTLP, the current project), and every file goes, read or not.
/// The clips are not converted: 1.x video is not a replay segment.
class LegacyReports {
  LegacyReports(this.pending, this.emit);

  final Directory pending;
  final void Function(LegacyReport report) emit;
  Future<void>? _running;

  static const Duration maxAge = Duration(hours: 12);

  Future<void> convert() =>
      _running ??= _convert().whenComplete(() => _running = null);

  Future<void> _convert() async {
    try {
      if (!await pending.exists()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      final directories = <Directory>[];
      await for (final entry in pending.list(recursive: true, followLinks: false)) {
        if (entry is Directory) {
          directories.add(entry);
          continue;
        }
        if (entry is! File) continue;
        if (entry.path.endsWith('.json')) {
          final report = await _read(entry, cutoff);
          if (report != null) emit(report);
        }
        await _delete(entry);
      }
      // Deepest first, then the directory itself, when nothing is left.
      directories.sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final dir in [...directories, pending]) {
        try {
          if (await dir.list().isEmpty) await dir.delete();
        } on FileSystemException {
          // Not empty after all, or gone: the next start looks again.
        }
      }
    } catch (_) {
      // Unreadable storage: the next start tries again.
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
      return LegacyReport(
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
