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

  /// A dialog, bottom sheet, menu or other popup shown over the screen, or
  /// one closing: the screen under it stays the current screen.
  final bool overlay;

  /// The route template of [to] (`/orders/:id`) when the router knows it,
  /// e.g. go_router's `state.fullPath`: metrics group by it, and issues on
  /// the screen carry it (`app.screen.route`).
  final String? route;

  /// The route [to] had already drawn its first frame when this was
  /// reported, so its time to initial display ends now. Otherwise it ends
  /// with the next frame.
  final bool displayed;

  NavigationEvent({
    required this.action,
    this.from,
    this.to,
    this.overlay = false,
    this.displayed = false,
    this.route,
    super.timestamp,
  });
}
