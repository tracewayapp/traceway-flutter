import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;

const int _maxBatches = 200;
const Duration _maxAge = Duration(hours: 24);
const int _maxBatchBytes = 4 * 1024 * 1024;

/// OTLP batches the exporter could not deliver, kept on disk as protobuf and
/// sent again later: after start, when connectivity returns, on the next
/// failed-export cycle. Bounded in count and age so an unreachable server
/// cannot fill the device.
class Outbox {
  Outbox({
    required this.directory,
    required this.logsUrl,
    required this.tracesUrl,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Directory? directory;
  final String logsUrl;
  final String tracesUrl;
  final String token;
  final http.Client _http;
  int _sequence = 0;
  Timer? _timer;
  Future<void>? _draining;
  int _attempts = 0;

  void add(String kind, List<int> body) {
    final dir = directory;
    if (dir == null || body.isEmpty || body.length > _maxBatchBytes) return;
    try {
      dir.createSync(recursive: true);
      final name =
          '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}.$kind.pb';
      File('${dir.path}${Platform.pathSeparator}$name').writeAsBytesSync(body);
      _prune();
    } catch (_) {
      // Best effort.
    }
    schedule(Duration(seconds: _backoffSeconds()));
  }

  int _backoffSeconds() {
    final seconds = 5 * (1 << _attempts.clamp(0, 6));
    return seconds > 300 ? 300 : seconds;
  }

  List<File> _files() {
    final dir = directory;
    if (dir == null || !dir.existsSync()) return [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.pb'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  void _prune() {
    final files = _files();
    final cutoff = DateTime.now().subtract(_maxAge);
    final keep = <File>[];
    for (final file in files) {
      try {
        if (file.lastModifiedSync().isBefore(cutoff)) {
          file.deleteSync();
        } else {
          keep.add(file);
        }
      } catch (_) {}
    }
    for (var i = 0; i < keep.length - _maxBatches; i++) {
      try {
        keep[i].deleteSync();
      } catch (_) {}
    }
  }

  void schedule(Duration delay) {
    if (directory == null || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(drain());
    });
  }

  Future<void> drain() {
    final running = _draining;
    if (running != null) return running;
    final future = _drain().whenComplete(() => _draining = null);
    _draining = future;
    return future;
  }

  Future<void> _drain() async {
    _prune();
    for (final file in _files()) {
      final url = file.path.endsWith('.traces.pb') ? tracesUrl : logsUrl;
      int status;
      try {
        final response = await _http
            .post(
              Uri.parse(url),
              headers: {
                'Content-Type': 'application/x-protobuf',
                'Authorization': 'Bearer $token',
              },
              body: await file.readAsBytes(),
            )
            .timeout(const Duration(seconds: 10));
        status = response.statusCode;
      } catch (_) {
        status = 0;
      }
      if (status == 0 || status == 429 || status >= 500) {
        _attempts++;
        schedule(Duration(seconds: _backoffSeconds()));
        return;
      }
      // Delivered, or rejected for good: either way it is done.
      try {
        await file.delete();
      } catch (_) {}
    }
    _attempts = 0;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Wraps the OTLP log exporter: a batch it fails to deliver goes to the
/// [Outbox] instead of being lost.
class PersistingLogExporter implements LogRecordExporter {
  PersistingLogExporter(this._inner, this._outbox);

  final LogRecordExporter _inner;
  final Outbox _outbox;

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    if (logRecords.isEmpty) return ExportResult.success;
    var result = ExportResult.failure;
    try {
      result = await _inner.export(logRecords);
    } catch (_) {
      result = ExportResult.failure;
    }
    if (result == ExportResult.failure) {
      try {
        _outbox.add(
          'logs',
          OtlpLogRecordTransformer.transformLogRecords(logRecords)
              .writeToBuffer(),
        );
      } catch (_) {}
    }
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() => _inner.forceFlush();

  @override
  Future<void> shutdown() => _inner.shutdown();
}

class PersistingSpanExporter implements SpanExporter {
  PersistingSpanExporter(this._inner, this._outbox);

  final SpanExporter _inner;
  final Outbox _outbox;

  @override
  Future<void> export(List<Span> spans) async {
    if (spans.isEmpty) return;
    try {
      await _inner.export(spans);
    } catch (_) {
      try {
        _outbox.add(
          'traces',
          OtlpSpanTransformer.transformSpans(spans).writeToBuffer(),
        );
      } catch (_) {}
    }
  }

  @override
  Future<void> forceFlush() => _inner.forceFlush();

  @override
  Future<void> shutdown() => _inner.shutdown();
}
