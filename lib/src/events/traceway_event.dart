/// Something the app did that the SDK records: an HTTP request or a
/// navigation, reported by the SDK's own capture or by the app.
sealed class TracewayEvent {
  /// When it happened; for a request, when it ended.
  final DateTime timestamp;

  TracewayEvent({DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

class NetworkEvent extends TracewayEvent {
  final String method;
  final String url;
  final int? statusCode;
  final Duration duration;
  final int? requestBytes;
  final int? responseBytes;
  final String? error;

  /// The W3C `traceparent` sent with the request, from
  /// [TracewayClient.traceparentFor]: the recorded span is the one it names.
  final String? traceparent;

  NetworkEvent({
    required this.method,
    required this.url,
    required this.duration,
    this.statusCode,
    this.requestBytes,
    this.responseBytes,
    this.error,
    this.traceparent,
    super.timestamp,
  });
}

class NavigationEvent extends TracewayEvent {
  /// One of: push, pop, replace, remove.
  final String action;
  final String? from;
  final String? to;

  NavigationEvent({
    required this.action,
    this.from,
    this.to,
    super.timestamp,
  });
}
