import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;

import '../core/ring_buffer.dart';
import '../guarded.dart';
import '../otel/router.dart';

/// A record of the ring buffer as it was saved: one OTLP `ResourceLogs` or
/// `ResourceSpans` holding it, without the resource, which is saved once.
class RestoredEntry {
  RestoredEntry(this.timeMs, this.signal, this.kind, this.bytes, this.resource);
  final int timeMs;
  final String signal;

  /// `logs` or `traces`.
  final String kind;
  final Uint8List bytes;

  /// The resource the record was made under: a restart after an app update
  /// keeps the version the record was recorded with.
  final Uint8List? resource;
}

/// The ring buffer on disk, so an app the system killed in the background
/// still has its breadcrumbs when the same session goes on after a restart,
/// like the browser SDK's buffer survives a reload. It is written when the
/// app goes to the background and on `flush()`, never on a timer: encoding
/// the whole buffer is work a phone should not do every few seconds.
///
/// What a restart restores is only uploaded by a trigger or capture, like
/// the rest of the buffer, and only within the current session.
class BufferPersistence {
  BufferPersistence(this.directory, {this.destination = ''});

  final Directory? directory;

  /// Where restored records would be sent. A file saved for other
  /// destinations is dropped: a changed receiver is never sent what was
  /// meant for the previous one.
  final String destination;
  final List<RestoredEntry> restored = [];

  /// This run's resource, by kind.
  final Map<String, Uint8List> _resources = {};
  Future<void> _saving = Future.value();

  File? get _file {
    final dir = directory;
    return dir == null
        ? null
        : File('${dir.path}${Platform.pathSeparator}buffer.json');
  }

  /// Reads what the last run saved for [sessionId], within [maxAgeMs] and
  /// [maxBytes]; anything else is dropped.
  Future<void> load(String? sessionId,
      {required int maxAgeMs, required int maxBytes}) async {
    final file = _file;
    if (file == null || sessionId == null) return;
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['v'] != 1 ||
          decoded['sessionId'] != sessionId ||
          (decoded['d'] ?? '') != destination) {
        return;
      }
      final resources = <Uint8List>[
        if (decoded['resources'] is List)
          for (final r in decoded['resources'] as List)
            r is String ? base64Decode(r) : Uint8List(0),
      ];
      final cutoff = DateTime.now().millisecondsSinceEpoch - maxAgeMs;
      final entries = <RestoredEntry>[];
      final raw = decoded['entries'];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final t = item['t'], s = item['s'], k = item['k'], b = item['b'];
          final r = item['r'];
          if (t is! int || s is! String || b is! String) continue;
          if ((k != 'logs' && k != 'traces') || t < cutoff) continue;
          entries.add(RestoredEntry(
              t,
              s,
              k as String,
              base64Decode(b),
              r is int && r >= 0 && r < resources.length
                  ? resources[r]
                  : null));
        }
      }
      // The newest records win when the saved buffer is larger than the
      // current one may be.
      var bytes = 0;
      for (var i = entries.length - 1; i >= 0; i--) {
        bytes += entries[i].bytes.length;
        if (bytes > maxBytes) {
          entries.removeRange(0, i + 1);
          break;
        }
      }
      restored.addAll(entries);
    } catch (_) {
      // A file this run cannot read only costs the breadcrumbs it held.
    } finally {
      await clear(keepRestored: true);
    }
  }

  /// Writes the restored records still held and the buffer's [entries].
  /// Saves run one after the other, each with what is held when it starts.
  Future<void> save(
      String? sessionId, List<BufferEntry<TelemetryItem>> entries) {
    final file = _file;
    if (file == null || sessionId == null) return _saving;
    final body = _serialize(sessionId, entries);
    return _saving = _saving.then((_) async {
      try {
        if (body == null) {
          if (await file.exists()) await file.delete();
          return;
        }
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.$destination.tmp');
        await tmp.writeAsString(body);
        await tmp.rename(file.path);
      } catch (_) {
        // Best effort.
      }
    });
  }

  String? _serialize(
      String sessionId, List<BufferEntry<TelemetryItem>> entries) {
    if (entries.isEmpty && restored.isEmpty) return null;
    final resources = <String>[];
    int resourceIndex(Uint8List? bytes) {
      if (bytes == null) return -1;
      final encoded = base64Encode(bytes);
      final index = resources.indexOf(encoded);
      if (index >= 0) return index;
      resources.add(encoded);
      return resources.length - 1;
    }

    final out = <Map<String, Object>>[
      for (final entry in restored)
        {
          't': entry.timeMs,
          's': entry.signal,
          'k': entry.kind,
          'b': base64Encode(entry.bytes),
          'r': resourceIndex(entry.resource),
        },
    ];
    for (final entry in entries) {
      final encoded = _encode(entry.item);
      if (encoded == null) continue;
      out.add({
        't': entry.timeMs,
        's': entry.signal,
        'k': encoded.$1,
        'b': base64Encode(encoded.$2),
        'r': resourceIndex(_resources[encoded.$1]),
      });
    }
    return jsonEncode({
      'v': 1,
      if (destination.isNotEmpty) 'd': destination,
      'sessionId': sessionId,
      'resources': resources,
      'entries': out,
    });
  }

  (String, Uint8List)? _encode(TelemetryItem item) {
    try {
      switch (item) {
        case LogItem(:final record):
          final request =
              OtlpLogRecordTransformer.transformLogRecords([record]);
          if (request.resourceLogs.isEmpty) return null;
          final resourceLogs = request.resourceLogs.first;
          _resources['logs'] ??= resourceLogs.resource.writeToBuffer();
          resourceLogs.clearResource();
          return ('logs', resourceLogs.writeToBuffer());
        case SpanItem(:final span):
          final request = OtlpSpanTransformer.transformSpans([span]);
          if (request.resourceSpans.isEmpty) return null;
          final resourceSpans = request.resourceSpans.first;
          _resources['traces'] ??= resourceSpans.resource.writeToBuffer();
          resourceSpans.clearResource();
          return ('traces', resourceSpans.writeToBuffer());
      }
    } catch (_) {
      return null;
    }
  }

  /// Removes the restored records in the window whose signal is selected
  /// and returns them as OTLP request bodies, by kind (`logs`, `traces`).
  /// `signals == null` selects every signal. A body holds about
  /// [maxBodyBytes] of records at most, so a large buffer is several
  /// requests, each small enough to be queued and accepted.
  Map<String, List<List<int>>> take(
    int sinceMs,
    Set<String>? signals,
    int untilMs,
    bool Function(String signal) canExport, {
    int maxBodyBytes = 1024 * 1024,
  }) {
    if (restored.isEmpty) return const {};
    final taken = <String, List<List<RestoredEntry>>>{};
    final sizes = <String, int>{};
    restored.removeWhere((entry) {
      final selected = entry.timeMs >= sinceMs &&
          entry.timeMs <= untilMs &&
          (signals == null || signals.contains(entry.signal));
      if (!selected) return false;
      if (canExport(entry.signal)) {
        final chunks = taken.putIfAbsent(entry.kind, () => [[]]);
        final size = (sizes[entry.kind] ?? 0) + entry.bytes.length;
        if (size > maxBodyBytes && chunks.last.isNotEmpty) {
          chunks.add([]);
          sizes[entry.kind] = entry.bytes.length;
        } else {
          sizes[entry.kind] = size;
        }
        chunks.last.add(entry);
      }
      return true;
    });
    final bodies = <String, List<List<int>>>{};
    for (final kind in taken.keys) {
      for (final chunk in taken[kind]!) {
        final body =
            kind == 'logs' ? _logsRequest(chunk) : _tracesRequest(chunk);
        if (body.isNotEmpty) bodies.putIfAbsent(kind, () => []).add(body);
      }
    }
    return bodies;
  }

  /// The bytes come from disk: a record that does not parse (a damaged
  /// file) is left out, not the others.
  static List<int> _logsRequest(List<RestoredEntry> entries) {
    final request = proto.ExportLogsServiceRequest();
    for (final group in _byResource(entries).entries) {
      final merged = proto.ResourceLogs();
      if (group.key.isNotEmpty) {
        guarded('restored resource', () {
          merged.resource =
              proto.Resource.fromBuffer(base64Decode(group.key));
        });
      }
      for (final entry in group.value) {
        guarded('restored record', () {
          merged.scopeLogs
              .addAll(proto.ResourceLogs.fromBuffer(entry.bytes).scopeLogs);
        });
      }
      if (merged.scopeLogs.isNotEmpty) request.resourceLogs.add(merged);
    }
    return request.writeToBuffer();
  }

  static List<int> _tracesRequest(List<RestoredEntry> entries) {
    final request = proto.ExportTraceServiceRequest();
    for (final group in _byResource(entries).entries) {
      final merged = proto.ResourceSpans();
      if (group.key.isNotEmpty) {
        guarded('restored resource', () {
          merged.resource =
              proto.Resource.fromBuffer(base64Decode(group.key));
        });
      }
      for (final entry in group.value) {
        guarded('restored record', () {
          merged.scopeSpans
              .addAll(proto.ResourceSpans.fromBuffer(entry.bytes).scopeSpans);
        });
      }
      if (merged.scopeSpans.isNotEmpty) request.resourceSpans.add(merged);
    }
    return request.writeToBuffer();
  }

  static Map<String, List<RestoredEntry>> _byResource(
      List<RestoredEntry> entries) {
    final out = <String, List<RestoredEntry>>{};
    for (final entry in entries) {
      final key = entry.resource == null ? '' : base64Encode(entry.resource!);
      out.putIfAbsent(key, () => []).add(entry);
    }
    return out;
  }

  /// Drops restored records whose signal may not leave the device any more.
  void retain(bool Function(String signal) keep) =>
      restored.removeWhere((entry) => !keep(entry.signal));

  Future<void> clear({bool keepRestored = false}) {
    if (!keepRestored) restored.clear();
    final file = _file;
    if (file == null) return _saving;
    return _saving = _saving.then((_) async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });
  }
}
