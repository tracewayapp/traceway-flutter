import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// How a masked widget is hidden in a replay.
enum MaskMode { blur, blank }

/// The one seam between Fieldmart and an observability SDK
/// (02-APP-SPEC.md §1.5). `app_off` links [NoTelemetry] and does not depend
/// on the SDK; `app_sdk` implements it with Traceway.
abstract class Telemetry {
  const Telemetry();

  /// A short name for logs: `none` or the SDK's.
  String get name;

  /// Observers for the app's root navigator.
  List<NavigatorObserver> get navigatorObservers;

  /// New observers for a nested navigator (the More tab's): an observer
  /// watches one navigator only.
  List<NavigatorObserver> nestedNavigatorObservers();

  /// The HTTP client the data layer uses.
  http.Client httpClient();

  /// Hides [child] in screen recordings.
  Widget mask(Widget child, {MaskMode mode = MaskMode.blur});

  /// A screen that is not a route became visible (a bottom-navigation tab).
  void screen(String path);

  /// A named product event.
  void track(String name, Map<String, Object> attributes);

  /// An app-defined metric observation.
  void metric(String name, double value, [Map<String, Object>? dimensions]);

  void captureException(Object error, StackTrace stackTrace,
      [Map<String, String>? attributes]);

  void captureMessage(String message, [Map<String, String>? attributes]);

  /// The first screen shows everything it loads.
  void fullyDisplayed();

  /// The SDK's session id, when it has one.
  String? get sessionId;
}

/// The `off` build: no SDK at all.
class NoTelemetry extends Telemetry {
  const NoTelemetry();

  @override
  String get name => 'none';

  @override
  List<NavigatorObserver> get navigatorObservers => const [];

  @override
  List<NavigatorObserver> nestedNavigatorObservers() => const [];

  @override
  http.Client httpClient() => http.Client();

  @override
  Widget mask(Widget child, {MaskMode mode = MaskMode.blur}) => child;

  @override
  void screen(String path) {}

  @override
  void track(String name, Map<String, Object> attributes) {}

  @override
  void metric(String name, double value, [Map<String, Object>? dimensions]) {}

  @override
  void captureException(Object error, StackTrace stackTrace,
      [Map<String, String>? attributes]) {}

  @override
  void captureMessage(String message, [Map<String, String>? attributes]) {}

  @override
  void fullyDisplayed() {}

  @override
  String? get sessionId => null;
}
