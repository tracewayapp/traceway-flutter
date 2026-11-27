import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'guarded.dart';

/// Where [TracewayInteraction.run] keeps the interaction for the code it
/// runs, async continuations included.
const Symbol interactionZoneKey = #traceway.interaction;

/// The interaction the code running now belongs to, if any.
TracewayInteraction? get currentInteraction {
  final value = Zone.current[interactionZoneKey];
  return value is TracewayInteraction ? value : null;
}

/// One user action traced from start to end, e.g. a checkout: a span named
/// after it (`traceway.interaction: true`) that the requests made in [run]
/// are children of, and that the exceptions and logs recorded in [run]
/// point to. Start one with `Traceway.startInteraction('checkout')` and
/// [end] it when the action is over.
///
/// ```dart
/// final checkout = Traceway.startInteraction('checkout');
/// try {
///   await checkout.run(() => api.placeOrder(cart));
/// } catch (e, st) {
///   checkout.captureException(e, st);
/// } finally {
///   checkout.end();
/// }
/// ```
///
/// One started in the first moments after `Traceway.run`, while the SDK
/// reads its state, is recorded once the SDK is ready, with the time it
/// started; its [traceId] and [spanId] are null until then. Once the SDK
/// has shut down, an interaction records nothing; [run] still runs its
/// code.
class TracewayInteraction {
  /// Made by the SDK. [onReady] defers the span of an interaction started
  /// before the SDK was ready: the SDK calls the function it is given with
  /// its tracer once it is.
  TracewayInteraction.internal(
    Span? span, {
    required void Function(Object error, StackTrace? stackTrace,
            Map<String, String>? attributes)
        captureException,
    String? name,
    Map<String, Object>? attributes,
    void Function(void Function(Tracer? tracer) bind)? onReady,
  })  : _span = span,
        _capture = captureException,
        _context = span == null ? null : Context.current.withSpan(span) {
    if (span == null && onReady != null && name != null && name.isNotEmpty) {
      _pending = _PendingSpan(
          name, {...?attributes}, DateTime.now(), currentInteraction);
      onReady(_bind);
    }
  }

  Span? _span;
  Context? _context;
  _PendingSpan? _pending;
  final void Function(Object, StackTrace?, Map<String, String>?) _capture;
  bool _failed = false;

  /// The SDK is ready: the span of an interaction started before is made
  /// now, from when it started, and ended if it already was.
  void _bind(Tracer? tracer) => guarded('interaction start', () {
        final pending = _pending;
        _pending = null;
        if (pending == null || tracer == null) return;
        final parent = pending.parent?.context;
        final span = tracer.startSpan(
          pending.name,
          kind: SpanKind.internal,
          context: parent,
          root: parent == null,
          startTime: pending.startedAt,
          attributes: OTel.attributesFromMap(
              {...pending.attributes, 'traceway.interaction': true}),
        );
        _span = span;
        _context = Context.current.withSpan(span);
        final endedAt = pending.endedAt;
        if (endedAt != null) {
          span.end(
            endTime: endedAt,
            spanStatus: _failed || pending.failed
                ? SpanStatusCode.Error
                : SpanStatusCode.Ok,
          );
        }
      });

  /// The trace this interaction starts (32 hex digits), or null when it
  /// records nothing. Look it up in a trace view, or log it.
  String? get traceId => _span?.spanContext.traceId.hexString;

  /// The interaction's own span id (16 hex digits), or null.
  String? get spanId => _span?.spanContext.spanId.hexString;

  /// Whether [end] was called.
  bool get isEnded => _span?.isEnded ?? _ended;
  bool _ended = false;

  /// The OpenTelemetry context with this interaction's span, for spans and
  /// records made inside it.
  Context? get context => _context;

  /// Runs [body] as part of this interaction: requests it makes are child
  /// spans of it, and exceptions, messages and logs it records carry its
  /// trace. An async [body] stays part of it until its future completes.
  T run<T>(T Function() body) {
    T inside() => runZoned(body, zoneValues: {interactionZoneKey: this});
    final context = _context;
    return context == null ? inside() : context.runSync(inside);
  }

  /// Sets an attribute on the interaction's span.
  void setAttribute(String key, Object value) => guarded('setAttribute', () {
        if (key.isEmpty) return;
        final pending = _pending;
        if (pending != null) {
          if (!_ended) pending.attributes[key] = value;
          return;
        }
        final span = _span;
        if (span == null || span.isEnded) return;
        switch (value) {
          case bool():
            span.setBoolAttribute(key, value);
          case int():
            span.setIntAttribute(key, value);
          case double():
            span.setDoubleAttribute(key, value);
          default:
            span.setStringAttribute(key, safeToString(value));
        }
      });

  /// Reports [error] as an exception of this interaction and marks the
  /// interaction failed: the exception carries its trace, and the span is
  /// sent with it.
  void captureException(Object error,
      [StackTrace? stackTrace, Map<String, String>? attributes]) {
    _failed = true;
    run(() => _capture(error, stackTrace, attributes));
  }

  /// Ends the interaction; only the first call counts. [failed] marks it
  /// failed even without a [captureException].
  void end({bool failed = false}) {
    if (isEnded) return;
    _ended = true;
    final pending = _pending;
    if (pending != null) {
      pending
        ..endedAt = DateTime.now()
        ..failed = _failed || failed;
      return;
    }
    final span = _span;
    if (span == null) return;
    // Ending a span must never break the app.
    guarded(
        'interaction end',
        () => span.end(
              spanStatus:
                  _failed || failed ? SpanStatusCode.Error : SpanStatusCode.Ok,
            ));
  }
}

/// An interaction started before the SDK was ready, until it is.
class _PendingSpan {
  _PendingSpan(this.name, this.attributes, this.startedAt, this.parent);

  final String name;
  final Map<String, Object> attributes;
  final DateTime startedAt;
  final TracewayInteraction? parent;
  DateTime? endedAt;
  bool failed = false;
}
