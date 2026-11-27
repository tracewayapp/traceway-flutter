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
/// Before the SDK has started, or once it has shut down, an interaction
/// records nothing; [run] still runs its code.
class TracewayInteraction {
  TracewayInteraction.internal(
    this._span, {
    required void Function(Object error, StackTrace? stackTrace,
            Map<String, String>? attributes)
        captureException,
  })  : _capture = captureException,
        _context = _span == null ? null : Context.current.withSpan(_span);

  final Span? _span;
  final Context? _context;
  final void Function(Object, StackTrace?, Map<String, String>?) _capture;
  bool _failed = false;

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
        final span = _span;
        if (span == null || span.isEnded || key.isEmpty) return;
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
