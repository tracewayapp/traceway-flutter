import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import '../core/control_state.dart';
import '../core/ids.dart';
import '../core/matcher.dart';
import '../core/ring_buffer.dart';
import '../core/settings.dart';
import 'events.dart';

/// A record waiting in the ring buffer or on its way to an exporter.
sealed class TelemetryItem {
  const TelemetryItem();
}

class LogItem extends TelemetryItem {
  const LogItem(this.record);
  final ReadWriteLogRecord record;
}

class SpanItem extends TelemetryItem {
  const SpanItem(this.span);
  final Span span;
}

enum Routed { stream, buffer, off, filtered }

class ObservedRecord {
  ObservedRecord({
    required this.signal,
    required this.timeMs,
    required this.lookup,
    required this.item,
    required this.routed,
  });

  final String signal;
  final int timeMs;
  final FieldLookup lookup;
  final TelemetryItem item;

  /// Whether the record was sent, buffered or dropped. Triggers still see
  /// dropped records.
  final Routed routed;
}

abstract class RouterHooks {
  String? get sessionId;
  String? globalAttribute(String key);

  /// Adds what the SDK knows to a record; returning false drops it.
  bool enrichLog(ReadWriteLogRecord record, String signal);
  void observe(ObservedRecord record);
}

const _spanStatus = ['unset', 'ok', 'error'];

/// Records per export of a buffer flush, as many as a batch processor sends.
const _flushBatchSize = 512;
const _baselineSignals = {
  'network',
  'console',
  'navigation',
  'userActions',
  'custom',
};

Object? _attr(Attributes? attributes, String key) =>
    attributes?.toMap()[key]?.value;

int _logTimeMs(ReadableLogRecord record) {
  final nanos = record.timestamp ?? record.observedTimestamp;
  return nanos == null
      ? DateTime.now().millisecondsSinceEpoch
      : (nanos ~/ 1000000).toInt();
}

int _estimateBytes(Attributes? attributes, Object? body) {
  var size = 200;
  if (body != null) size += 2 * body.toString().length;
  if (attributes != null) {
    for (final attr in attributes.toList()) {
      size += 2 * (attr.key.length + attr.value.toString().length) + 16;
    }
  }
  return size;
}

/// Whether a log record may still be exported, checked again when it reaches
/// the exporter: the kill switch or a rule may have turned its signal off
/// since it was routed. Control records follow only the kill switch, as when
/// they are routed: a session's end goes with its start.
bool canExportLog(ControlState control, String? eventName) {
  final signal = classifyLog(eventName);
  return signal == signalControl ? control.enabled : control.canExport(signal);
}

/// Decides for every log record and span whether it is sent now, kept in the
/// ring buffer or dropped, according to the [ControlState]. Triggers are
/// observed after routing so a triggered flush includes the record that
/// caused it.
class TelemetryRouter {
  TelemetryRouter({
    required this.control,
    required this.buffer,
    required this.logSink,
    required this.spanSink,
    required this.logExporter,
    required this.spanExporter,
    required this.hooks,
    this.persistIssue,
    double Function()? random,
  }) : _random = random ?? Random().nextDouble;

  final ControlState control;
  final RingBuffer<TelemetryItem> buffer;
  final LogRecordProcessor logSink;
  final SpanProcessor spanSink;

  /// The exporters behind [logSink] and [spanSink], for [flushBuffered].
  final LogRecordExporter logExporter;
  final SpanExporter spanExporter;
  final RouterHooks hooks;
  final bool Function(ReadableLogRecord)? persistIssue;
  final double Function() _random;

  List<String> _activeCaptureIds() {
    final now = DateTime.now();
    return [
      for (final capture in control.settings.captures)
        if (capture.until.isAfter(now)) capture.id,
    ];
  }

  void routeLog(ReadWriteLogRecord record) {
    final signal = classifyLog(record.eventName);
    final sessionId = hooks.sessionId;
    if (sessionId != null && _attr(record.attributes, attrSessionId) == null) {
      record.addAttribute(OTel.attributeString(attrSessionId, sessionId));
    }
    if (signal != signalControl) {
      final captureIds = _activeCaptureIds();
      if (captureIds.isNotEmpty) {
        record.addAttribute(OTel.attributeString(
            'traceway.capture.ids', jsonEncode(captureIds)));
      }
    }
    if (!hooks.enrichLog(record, signal)) return;

    final item = LogItem(record);
    final timeMs = _logTimeMs(record);
    final minSeverity = control.settings.signals['console']!.minSeverity;
    final routed = _decide(signal, item, timeMs, () {
      if (signal != 'console' || minSeverity == null) return true;
      final severity = record.severityNumber;
      return severity == null ||
          severity.severityNumber >= severityNumberOf(minSeverity);
    });
    _observeAndSend(ObservedRecord(
      signal: signal,
      timeMs: timeMs,
      lookup: _logLookup(record, signal),
      item: item,
      routed: routed,
    ));
  }

  /// Triggers see a record before it is handed to the exporter, because the
  /// batch processor copies it there and later attributes would be lost. A
  /// buffered record is already in the buffer at that point, so a flush it
  /// triggers includes it; a streamed one follows the flushed breadcrumbs.
  void _observeAndSend(ObservedRecord observed) {
    hooks.observe(observed);
    if (observed.routed == Routed.stream) _send(observed.item);
  }

  void stampSpan(Span span) {
    final sessionId = hooks.sessionId;
    if (sessionId != null) span.setStringAttribute(attrSessionId, sessionId);
    final captureIds = _activeCaptureIds();
    if (captureIds.isNotEmpty) {
      span.setStringAttribute('traceway.capture.ids', jsonEncode(captureIds));
    }
    final baselineRate = control.settings.baselineSampleRate;
    span.setStringAttribute(
      'traceway.collection.source',
      sessionId != null && unitHash(sessionId) < baselineRate
          ? 'baseline'
          : 'diagnostic',
    );
    span.setDoubleAttribute('traceway.collection.baseline_rate', baselineRate);
  }

  void routeSpan(Span span) {
    final item = SpanItem(span);
    final timeMs = (span.endTime ?? DateTime.now()).millisecondsSinceEpoch;
    // A failed interaction goes with the exception that failed it, as the
    // browser SDK sends it, so the issue links to its trace.
    final failedInteraction =
        span.attributes.toMap()['traceway.interaction']?.value == true &&
            span.status == SpanStatusCode.Error;
    final routed = _decide('network', item, timeMs, () => true,
        forceStream: failedInteraction);
    _observeAndSend(ObservedRecord(
      signal: 'network',
      timeMs: timeMs,
      lookup: _spanLookup(span),
      item: item,
      routed: routed,
    ));
  }

  /// Sends a record that was dropped when it arrived but whose signal streams
  /// now, because the trigger it fired started a capture.
  void sendIfStreaming(ObservedRecord observed) {
    if (observed.routed != Routed.off || observed.signal == signalControl) {
      return;
    }
    if (control.modeFor(observed.signal) == Mode.stream) _send(observed.item);
  }

  final List<ReadableLogRecord> _flushedLogs = [];
  final List<Span> _flushedSpans = [];

  /// Sends what the buffer holds in the window. `signals == null` selects
  /// every signal. Returns the number of records taken.
  ///
  /// They go straight to the exporters, a batch after the other: the batch
  /// processors' queues are bounded and drop what does not fit, and a full
  /// buffer holds more than they do. The newest breadcrumbs, the ones right
  /// before the error, would be the ones lost.
  int flushBuffered(int sinceMs, Set<String>? signals, [int? untilMs]) {
    final entries = buffer.take(sinceMs, signals, untilMs);
    for (final entry in entries) {
      if (!control.canExport(entry.signal)) continue;
      switch (entry.item) {
        case LogItem(:final record):
          if (!_persistIssue(record)) _flushedLogs.add(record);
        case SpanItem(:final span):
          _flushedSpans.add(span);
      }
    }
    unawaited(settle());
    return entries.length;
  }

  /// Exports what [flushBuffered] took; completes when none of it is left.
  /// The requests of the last batches may still be on their way: the
  /// exporters' own `forceFlush` waits for those.
  Future<void> settle() async {
    while (_flushedLogs.isNotEmpty) {
      final batch = _takeBatch(_flushedLogs);
      try {
        await logExporter.export(batch);
      } catch (_) {
        // An exporter that throws loses its batch, not the rest.
      }
    }
    while (_flushedSpans.isNotEmpty) {
      final batch = _takeBatch(_flushedSpans);
      try {
        await spanExporter.export(batch);
      } catch (_) {}
    }
  }

  static List<T> _takeBatch<T>(List<T> from) {
    final count = min(_flushBatchSize, from.length);
    final batch = from.sublist(0, count);
    from.removeRange(0, count);
    return batch;
  }

  /// Decides what happens to a record; a buffered one is stored here, a
  /// streamed one is sent by the caller once triggers have seen it.
  Routed _decide(
    String signal,
    TelemetryItem item,
    int timeMs,
    bool Function() accept, {
    bool forceStream = false,
  }) {
    if (signal == signalControl) {
      return control.enabled ? Routed.stream : Routed.off;
    }
    final mode = control.modeFor(signal);
    final sampleRate = control.sampleRate(signal);
    if (!accept() || (sampleRate < 1 && _random() >= sampleRate)) {
      return Routed.filtered;
    }
    if (mode == Mode.off) return Routed.off;
    final sessionId = hooks.sessionId;
    // Within the plan's limits: a signal they only let buffer stays here.
    final baselineSampled = _baselineSignals.contains(signal) &&
        sessionId != null &&
        unitHash(sessionId) < control.settings.baselineSampleRate &&
        control.canExport(signal);
    final forced = forceStream && control.canExport(signal);
    if (mode == Mode.stream || baselineSampled || forced) return Routed.stream;
    buffer.push(BufferEntry(
      timeMs: timeMs,
      signal: signal,
      bytes: switch (item) {
        LogItem(:final record) =>
          _estimateBytes(record.attributes, record.body),
        SpanItem(:final span) => _estimateBytes(span.attributes, span.name),
      },
      item: item,
    ));
    return Routed.buffer;
  }

  /// An issue is written to disk before it is sent, when there is a disk:
  /// the app may not live to see the answer.
  bool _persistIssue(ReadableLogRecord record) =>
      (record.eventName == eventException ||
          record.eventName == eventMessage) &&
      persistIssue?.call(record) == true;

  void _send(TelemetryItem item) {
    switch (item) {
      case LogItem(:final record):
        if (!_persistIssue(record)) logSink.onEmit(record, null);
      case SpanItem(:final span):
        spanSink.onEnd(span);
    }
  }

  FieldLookup _logLookup(ReadableLogRecord record, String signal) {
    return (key) {
      switch (key) {
        case 'event.name':
          return record.eventName;
        case 'signal':
          return signal;
        case 'severity':
          return record.severityNumber?.severityNumber;
        case 'severity.text':
          return record.severityText;
        case 'body':
          final body = record.body;
          return body == null || body is String ? body : jsonEncode(body);
      }
      return _prefixed(key, record.attributes, record.resource?.attributes);
    };
  }

  FieldLookup _spanLookup(Span span) {
    return (key) {
      switch (key) {
        case 'signal':
          return 'network';
        case 'span.name':
          return span.name;
        case 'span.kind':
          return span.kind.name;
        case 'span.status':
          return _spanStatus[span.status.index];
        case 'duration_ms':
          final end = span.endTime;
          return end?.difference(span.startTime).inMicroseconds == null
              ? null
              : end!.difference(span.startTime).inMicroseconds / 1000;
      }
      return _prefixed(key, span.attributes, span.resource?.attributes);
    };
  }

  Object? _prefixed(String key, Attributes? attributes, Attributes? resource) {
    if (key.startsWith('attributes.')) {
      return _attr(attributes, key.substring('attributes.'.length));
    }
    if (key.startsWith('resource.')) {
      return _attr(resource, key.substring('resource.'.length));
    }
    if (key.startsWith('global.')) {
      return hooks.globalAttribute(key.substring('global.'.length));
    }
    if (key == attrSessionId) {
      return _attr(attributes, attrSessionId) ?? hooks.sessionId;
    }
    return null;
  }
}

/// The only log processor on the provider: hands every record to the router,
/// which owns the real batch processor.
class ControlLogProcessor implements LogRecordProcessor {
  ControlLogProcessor(this._router, this._sink);

  final TelemetryRouter? Function() _router;
  final LogRecordProcessor _sink;

  @override
  Future<void> onEmit(ReadWriteLogRecord logRecord, Context? context) async {
    try {
      _router()?.routeLog(logRecord);
    } catch (_) {
      // Telemetry must never break the app that produced it.
    }
  }

  @override
  bool enabled({
    Context? context,
    InstrumentationScope? instrumentationScope,
    Severity? severityNumber,
    String? eventName,
  }) =>
      true;

  @override
  Future<void> forceFlush() => _sink.forceFlush();

  @override
  Future<void> shutdown() => _sink.shutdown();
}

class ControlSpanProcessor implements SpanProcessor {
  ControlSpanProcessor(this._router, this._sink);

  final TelemetryRouter? Function() _router;
  final SpanProcessor _sink;

  @override
  Future<void> onStart(Span span, Context? parentContext) async {
    try {
      _router()?.stampSpan(span);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> onEnd(Span span) async {
    try {
      _router()?.routeSpan(span);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> onNameUpdate(Span span, String newName) async {}

  @override
  Future<void> forceFlush() => _sink.forceFlush();

  @override
  Future<void> shutdown() => _sink.shutdown();
}
