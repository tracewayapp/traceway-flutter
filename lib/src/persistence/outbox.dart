import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:http/http.dart' as http;

import '../core/endpoints.dart';
import '../otel/events.dart';
import '../sdk_version.dart';

const int _maxBatches = 200;
const Duration _maxAge = Duration(hours: 24);
const int _maxBatchBytes = 4 * 1024 * 1024;

/// Delays between the attempts of a live export, before a batch that keeps
/// failing goes to the [Outbox].
const List<Duration> liveRetryDelays = [
  Duration(milliseconds: 200),
  Duration(seconds: 1),
];

/// Posts one OTLP/HTTP protobuf request to [destination], gzipped, trying
/// again after each of [retryDelays] while the failure may pass. Returns the
/// last status code, 0 when no answer came.
Future<int> postOtlp(
  http.Client client,
  OtlpDestination destination,
  List<int> body, {
  List<Duration> retryDelays = const [],
}) async {
  final compressed = gzip.encode(body);
  var status = 0;
  for (var attempt = 0;; attempt++) {
    try {
      final response = await client
          .post(
            Uri.parse(destination.url),
            headers: {
              'User-Agent': otlpUserAgent,
              ...destination.headers,
              'Content-Type': 'application/x-protobuf',
              'Content-Encoding': 'gzip',
            },
            body: compressed,
          )
          .timeout(const Duration(seconds: 10));
      status = response.statusCode;
    } catch (_) {
      status = 0;
    }
    if (!isTransientFailure(status) || attempt >= retryDelays.length) {
      return status;
    }
    await Future<void>.delayed(retryDelays[attempt]);
  }
}

/// No answer, throttled or a server error: worth sending again later.
bool isTransientFailure(int status) =>
    status == 0 || status == 408 || status == 429 || status >= 500;

/// OTLP batches that could not be delivered, kept on disk as protobuf and
/// sent again later: after start, when connectivity returns, on the next
/// failed-export cycle. Bounded in count and age so an unreachable server
/// cannot fill the device. One outbox per set of destinations, in its own
/// directory, so batches queued for one receiver never go to another.
class Outbox {
  Outbox({
    required this.directory,
    required this.destinations,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Directory? directory;

  /// By kind: `logs`, `traces`.
  final Map<String, OtlpDestination> destinations;
  final http.Client _http;
  int _sequence = 0;
  bool _claimed = false;
  Timer? _timer;
  Future<void>? _draining;
  int _attempts = 0;
  bool _disposed = false;

  /// Identifies where this outbox sends, its credentials included: batches
  /// queued for other destinations or another project's token are dropped,
  /// never sent here.
  late final String destinationKey = destinationDigest([
    for (final kind in destinations.keys.toList()..sort()) ...[
      kind,
      destinations[kind]!.key
    ],
  ]);

  void claim() {
    final dir = directory;
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
      final marker = File('${dir.path}/destination');
      final previous = marker.existsSync() ? marker.readAsStringSync() : null;
      // Older Traceway queues recorded the URL and project credential in
      // their marker. Unmarked queues and old external markers cannot
      // establish who owns their contents.
      final legacyKey = fingerprint([
        for (final kind in destinations.keys.toList()..sort())
          '$kind=${destinations[kind]!.url}#${destinations[kind]!.headers['Authorization']}',
      ].join('|'));
      final adopt = previous == legacyKey &&
          destinations.values.every((d) => !d.external);
      for (final file in dir.listSync(followLinks: false).whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (!name.endsWith('.pb') || name.startsWith('$destinationKey-')) {
          continue;
        }
        if (adopt && RegExp(r'^\d+-\d+\.(logs|traces)\.pb$').hasMatch(name)) {
          file.renameSync('${dir.path}/$destinationKey-$name');
        } else {
          file.deleteSync();
        }
      }
      marker.writeAsStringSync(destinationKey);
      _claimed = true;
    } on FileSystemException {
      // Disk failures fall back to the live exporter.
    }
  }

  bool persistLog(ReadableLogRecord record) {
    try {
      final body = OtlpLogRecordTransformer.transformLogRecords([record])
          .writeToBuffer();
      return add('logs', body);
    } catch (_) {
      return false;
    }
  }

  bool add(String kind, List<int> body) {
    final dir = directory;
    if (!_claimed ||
        _disposed ||
        dir == null ||
        body.isEmpty ||
        body.length > _maxBatchBytes ||
        !destinations.containsKey(kind)) {
      return false;
    }
    try {
      final name =
          '$destinationKey-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}.$kind.pb';
      final file = File('${dir.path}/$name');
      final tmp = File('${file.path}.tmp');
      tmp.writeAsBytesSync(body, flush: true);
      tmp.renameSync(file.path);
    } on FileSystemException {
      return false;
    }
    try {
      _prune();
    } on FileSystemException {
      // The batch is already durable. Pruning also runs on drain.
    }
    schedule(Duration(seconds: _backoffSeconds()));
    return true;
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
        .where((f) =>
            f.uri.pathSegments.last.startsWith('$destinationKey-') &&
            f.path.endsWith('.pb'))
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
    if (_disposed || directory == null || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(drain());
    });
  }

  Future<void> drain() {
    final running = _draining;
    if (running != null) return running;
    final future = _drain().onError<FileSystemException>((error, stack) {
      if (!_disposed) schedule(Duration(seconds: _backoffSeconds()));
    }).whenComplete(() => _draining = null);
    _draining = future;
    return future;
  }

  Future<void> _drain() async {
    if (!_claimed || _disposed) return;
    _prune();
    for (final file in _files()) {
      if (_disposed) return;
      final List<int> body;
      try {
        body = await file.readAsBytes();
      } on PathNotFoundException {
        continue;
      }
      final kind = file.path.endsWith('.traces.pb') ? 'traces' : 'logs';
      final destination = destinations[kind];
      final status =
          destination == null ? 400 : await postOtlp(_http, destination, body);
      if (isTransientFailure(status)) {
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
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// FNV-1a as hex: stable across runs and platforms, for names and markers
/// that must not hold a credential in the clear.
String fingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Tracks an exporter's requests still on their way, so a flush can wait
/// for them: the batch processor hands a batch over and forgets it.
mixin _InFlight {
  final Set<Future<void>> _inFlight = {};

  Future<T> _track<T>(Future<T> work) {
    final done = work.then((_) {}, onError: (_) {});
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
    return work;
  }

  Future<void> _settle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(List.of(_inFlight));
    }
  }
}

/// Sends log records as OTLP/HTTP protobuf to one destination, at exactly
/// its URL. A batch that fails for a reason that may pass goes to the
/// [Outbox] instead of being lost.
class OtlpLogExporter with _InFlight implements LogRecordExporter {
  OtlpLogExporter(this._destination, this._outbox, this._http);

  final OtlpDestination _destination;
  final Outbox _outbox;
  final http.Client _http;

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    if (logRecords.isEmpty) return ExportResult.success;
    final List<int> body;
    try {
      body = OtlpLogRecordTransformer.transformLogRecords(logRecords)
          .writeToBuffer();
    } catch (_) {
      return ExportResult.failure;
    }
    return _track(() async {
      final status = await postOtlp(_http, _destination, body,
          retryDelays: liveRetryDelays);
      if (isTransientFailure(status)) _outbox.add('logs', body);
      return ExportResult.success;
    }());
  }

  @override
  Future<void> forceFlush() => _settle();

  @override
  Future<void> shutdown() => _settle();
}

/// The span counterpart of [OtlpLogExporter].
class OtlpSpanExporter with _InFlight implements SpanExporter {
  OtlpSpanExporter(this._destination, this._outbox, this._http);

  final OtlpDestination _destination;
  final Outbox _outbox;
  final http.Client _http;

  @override
  Future<void> export(List<Span> spans) async {
    if (spans.isEmpty) return;
    final List<int> body;
    try {
      body = OtlpSpanTransformer.transformSpans(spans).writeToBuffer();
    } catch (_) {
      return;
    }
    await _track(() async {
      final status = await postOtlp(_http, _destination, body,
          retryDelays: liveRetryDelays);
      if (isTransientFailure(status)) _outbox.add('traces', body);
    }());
  }

  @override
  Future<void> forceFlush() => _settle();

  @override
  Future<void> shutdown() => _settle();
}

/// Whether a log record belongs to Traceway even when ordinary logs go to
/// another receiver: exceptions and messages (the issues), and the SDK's
/// control records (sessions, triggers, captures, config).
bool isTracewayLog(String? eventName) {
  final signal = classifyLog(eventName);
  return signal == 'errors' || signal == 'messages' || signal == signalControl;
}

/// Sends what [isTracewayLog] selects to [traceway], everything else to
/// [inner]. Runs after the ring buffer, so a record flushed by a trigger is
/// routed the same as one streamed live.
class RoutingLogExporter implements LogRecordExporter {
  RoutingLogExporter(this.inner, this.traceway);

  final LogRecordExporter inner;
  final LogRecordExporter traceway;

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    final own = <ReadableLogRecord>[];
    final rest = <ReadableLogRecord>[];
    for (final record in logRecords) {
      (isTracewayLog(record.eventName) ? own : rest).add(record);
    }
    final results = await Future.wait([
      if (own.isNotEmpty) traceway.export(own),
      if (rest.isNotEmpty) inner.export(rest),
    ]);
    return results.contains(ExportResult.failure)
        ? ExportResult.failure
        : ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {
    await traceway.forceFlush();
    await inner.forceFlush();
  }

  @override
  Future<void> shutdown() async {
    await traceway.shutdown();
    await inner.shutdown();
  }
}

/// Splits an OTLP logs request in two: the records [isTracewayLog] selects
/// and the rest. Either side is null when it holds no record.
(List<int>?, List<int>?) splitLogsRequest(List<int> body) {
  final request = proto.ExportLogsServiceRequest.fromBuffer(body);
  final own = proto.ExportLogsServiceRequest();
  final rest = proto.ExportLogsServiceRequest();
  var ownCount = 0, restCount = 0;
  for (final resourceLogs in request.resourceLogs) {
    final ownResource = proto.ResourceLogs(resource: resourceLogs.resource);
    final restResource = proto.ResourceLogs(resource: resourceLogs.resource);
    for (final scopeLogs in resourceLogs.scopeLogs) {
      final ownScope = proto.ScopeLogs(scope: scopeLogs.scope);
      final restScope = proto.ScopeLogs(scope: scopeLogs.scope);
      for (final record in scopeLogs.logRecords) {
        if (isTracewayLog(record.eventName)) {
          ownScope.logRecords.add(record);
          ownCount++;
        } else {
          restScope.logRecords.add(record);
          restCount++;
        }
      }
      if (ownScope.logRecords.isNotEmpty) ownResource.scopeLogs.add(ownScope);
      if (restScope.logRecords.isNotEmpty) {
        restResource.scopeLogs.add(restScope);
      }
    }
    if (ownResource.scopeLogs.isNotEmpty) own.resourceLogs.add(ownResource);
    if (restResource.scopeLogs.isNotEmpty) rest.resourceLogs.add(restResource);
  }
  return (
    ownCount == 0 ? null : own.writeToBuffer(),
    restCount == 0 ? null : rest.writeToBuffer(),
  );
}
