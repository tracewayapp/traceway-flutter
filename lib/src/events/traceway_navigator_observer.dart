import 'package:flutter/widgets.dart';

import '../traceway_client.dart';
import 'traceway_event.dart';

/// A [NavigatorObserver] that records every push/pop/replace/remove as a
/// [NavigationEvent] on [TracewayClient].
///
/// Wire it up via `MaterialApp.navigatorObservers: [Traceway.navigatorObserver]`
/// (or any other Navigator). The observer becomes a no-op when
/// `TracewayOptions.captureNavigation` is false.
class TracewayNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('push', from: previousRoute, to: route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('pop', from: route, to: previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _record('replace', from: oldRoute, to: newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record('remove', from: route, to: previousRoute);
  }

  void _record(String action,
      {Route<dynamic>? from, Route<dynamic>? to}) {
    final client = TracewayClient.instance;
    if (client == null) return;
    if (!client.options.captureNavigation) return;
    try {
      client.recordNavigationEvent(NavigationEvent(
        action: action,
        from: _name(from),
        to: _name(to),
      ));
    } catch (_) {
      // Never let event recording break navigation.
    }
  }

  static String? _name(Route<dynamic>? route) {
    if (route == null) return null;
    return route.settings.name ?? route.runtimeType.toString();
  }
}
