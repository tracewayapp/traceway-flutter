import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../traceway_client.dart';
import 'traceway_event.dart';

/// A [NavigatorObserver] that records every push/pop/replace/remove as a
/// [NavigationEvent] on [TracewayClient].
///
/// Wire it up via `MaterialApp.navigatorObservers: [Traceway.navigatorObserver]`
/// (or any other Navigator). The observer becomes a no-op when
/// `TracewayOptions.captureNavigation` is false.
///
/// A route is reported by its path, which navigation steps of recording
/// triggers match (`/users/{id}`):
///
/// - its name (`RouteSettings.name`, set by named routes and most routers),
/// - else `/` and the type of the page widget it shows, e.g. `/CheckoutPage`
///   for `MaterialPageRoute(builder: (_) => const CheckoutPage())`. That is
///   only known once the route has built, so such a navigation is recorded
///   after the route's first frame,
/// - else `/` and the route's type, e.g. `/DialogRoute`.
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

  void _record(String action, {Route<dynamic>? from, Route<dynamic>? to}) {
    final client = TracewayClient.instance;
    if (client == null) return;
    if (!client.options.captureNavigation) return;
    try {
      final at = DateTime.now();
      final fromPath = from == null ? null : routePath(from) ?? fallbackPath(from);
      // A popup opening, or closing back to the screen under it.
      final overlay = to is PopupRoute ||
          ((action == 'pop' || action == 'remove') && from is PopupRoute);
      void emit(String? toPath, {required bool displayed}) {
        try {
          client.recordNavigationEvent(NavigationEvent(
            action: action,
            from: fromPath,
            to: toPath,
            overlay: overlay,
            displayed: displayed,
            timestamp: at,
          ));
        } catch (_) {}
      }

      final toPath = to == null ? null : routePath(to);
      if (to == null || toPath != null) {
        emit(toPath, displayed: false);
        return;
      }
      SchedulerBinding.instance.addPostFrameCallback((_) {
        emit(routePath(to) ?? fallbackPath(to), displayed: true);
      });
    } catch (_) {
      // Never let event recording break navigation.
    }
  }

  static final Expando<String> _pages = Expando('traceway.page');

  /// The path [route] is reported as, or null while an unnamed route has not
  /// built yet.
  static String? routePath(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    final cached = _pages[route];
    if (cached != null) return cached;
    if (route is! ModalRoute) return null;
    final page = _pageType(route);
    if (page == null) return null;
    return _pages[route] = '/$page';
  }

  static String fallbackPath(Route<dynamic> route) {
    final cached = _pages[route];
    if (cached != null) return cached;
    return '/${_stripGenerics(route.runtimeType.toString())}';
  }

  static String _stripGenerics(String name) {
    final generic = name.indexOf('<');
    return generic < 0 ? name : name.substring(0, generic);
  }

  static const Set<String> _wrappers = {
    'Builder',
    'DisplayFeatureSubScreen',
    'SafeArea',
    'Align',
    'Center',
    'Padding',
    'Semantics',
    'MediaQuery',
    'Theme',
    'DefaultTextStyle',
    'FocusScope',
    'Focus',
    'Actions',
    'Shortcuts',
    'PrimaryScrollController',
  };

  /// The page widget of a built route: the first widget under the route's
  /// subtree (a repaint boundary around what `buildPage` returns) past
  /// framework wrappers, such as the route's `Semantics(scopesRoute: true)`.
  /// A `PageRouteBuilder` has no such `Semantics`: its page comes first.
  static String? _pageType(ModalRoute<dynamic> route) {
    final context = route.subtreeContext;
    if (context is! Element) return null;
    Element? current = context;
    for (var depth = 0; depth < 48 && current != null; depth++) {
      final widget = current.widget;
      final type = _stripGenerics(widget.runtimeType.toString());
      if (depth > 0 && !type.startsWith('_') && !_wrappers.contains(type)) {
        return type;
      }
      Element? only;
      var count = 0;
      current.visitChildElements((child) {
        count++;
        only = child;
      });
      current = count == 1 ? only : null;
    }
    return null;
  }
}
