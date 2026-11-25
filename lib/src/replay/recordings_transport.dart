import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:http/http.dart' as http;

class RecordingSegment {
  RecordingSegment({
    this.exceptionId,
    this.sessionId,
    this.segmentIndex,
    required this.events,
    this.startedAt,
    this.endedAt,
  });

  /// The `traceway.exception.id` of the exception this segment is a clip of.
  final String? exceptionId;
  final String? sessionId;
  final int? segmentIndex;
  final List<Map<String, dynamic>> events;
  final DateTime? startedAt;
  final DateTime? endedAt;

  Map<String, dynamic> toJson() => {
        if (exceptionId != null) 'exceptionId': exceptionId,
        if (sessionId != null) 'sessionId': sessionId,
        if (segmentIndex != null) 'segmentIndex': segmentIndex,
        'events': events,
        if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
      };
}

class _Batch {
  _Batch(this.segments) {
    for (final segment in segments) {
      for (final event in segment.events) {
        final data = event['data'];
        if (data is String) bytes += data.length;
      }
    }
  }
  final List<RecordingSegment> segments;
  int bytes = 0;
  int attempts = 0;
}

const List<int> _defaultRetryDelaysMs = [5000, 30000, 120000];
const Set<int> _permanentFailures = {400, 401, 403, 404, 413, 422};
const int _defaultMaxQueuedBytes = 10 * 1024 * 1024;

/// Sends replay clips to the dedicated, non-OpenTelemetry recordings
/// endpoint. Failed batches are retried a few times with growing delays and
/// then dropped, so a server that keeps rejecting them cannot grow memory.
/// What waits is bounded by [maxQueuedBytes] too: a device that streams
/// while offline drops its oldest segments.
class RecordingsTransport {
  RecordingsTransport({
    required this.url,
    required this.token,
    http.Client? httpClient,
    List<int>? retryDelaysMs,
    this.maxQueuedBytes = _defaultMaxQueuedBytes,
  })  : _http = httpClient ?? http.Client(),
        _retryDelaysMs = retryDelaysMs ?? _defaultRetryDelaysMs;

  final String url;
  final String token;
  final http.Client _http;
  final List<int> _retryDelaysMs;
  final int maxQueuedBytes;
  final List<_Batch> _queue = [];
  int _queuedBytes = 0;
  Timer? _timer;
  Future<void>? _inFlight;
  int _generation = 0;

  int failedSegments = 0;
  int sentSegments = 0;

  int get pending => _queue.fold(0, (n, b) => n + b.segments.length);

  void send(List<RecordingSegment> segments) {
    if (segments.isEmpty) return;
    final batch = _Batch(segments);
    _queue.add(batch);
    _queuedBytes += batch.bytes;
    while (_queuedBytes > maxQueuedBytes && _queue.length > 1) {
      final dropped = _queue.removeAt(0);
      _queuedBytes -= dropped.bytes;
      failedSegments += dropped.segments.length;
    }
    _schedule(0);
  }

  void discard() {
    _generation++;
    _queue.clear();
    _queuedBytes = 0;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final running = _inFlight;
    if (running != null) await running;
    await _drain();
  }

  void _schedule(int delayMs) {
    if (_timer != null) return;
    _timer = Timer(Duration(milliseconds: delayMs), () {
      _timer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() {
    final running = _inFlight;
    if (running != null) return running;
    final future = () async {
      while (_queue.isNotEmpty) {
        final batch = _queue.removeAt(0);
        _queuedBytes -= batch.bytes;
        final generation = _generation;
        final retryAfterMs = await _post(batch);
        if (generation != _generation) continue;
        if (retryAfterMs != null) {
          _queue.insert(0, batch);
          _queuedBytes += batch.bytes;
          _schedule(retryAfterMs);
          return;
        }
      }
    }()
        .whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// Returns null when the batch is done (sent or given up), else how long to
  /// wait before retrying.
  Future<int?> _post(_Batch batch) async {
    batch.attempts++;
    http.Response response;
    try {
      final body = gzip.encode(utf8.encode(jsonEncode({
        'segments': batch.segments.map((s) => s.toJson()).toList(),
      })));
      response = await _http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Content-Encoding': 'gzip',
              'Authorization': 'Bearer $token',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return _retryDelay(batch, null);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      sentSegments += batch.segments.length;
      return null;
    }
    if (_permanentFailures.contains(response.statusCode)) {
      failedSegments += batch.segments.length;
      return null;
    }
    final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
    return _retryDelay(
        batch, retryAfter != null && retryAfter > 0 ? retryAfter * 1000 : null);
  }

  int? _retryDelay(_Batch batch, int? requested) {
    if (batch.attempts > _retryDelaysMs.length) {
      failedSegments += batch.segments.length;
      return null;
    }
    return requested ?? _retryDelaysMs[batch.attempts - 1];
  }
}
