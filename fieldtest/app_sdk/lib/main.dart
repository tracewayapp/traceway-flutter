// The SDK build of Fieldmart. One binary for every SDK variant: the launch
// settings pick the configuration (03-MEASUREMENT.md §1.2).
import 'package:fieldmart_ui/fieldmart_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:traceway/traceway.dart';

void main(List<String> args) {
  // Nothing touches the binding before Traceway.run, as the SDK's docs
  // start it: it sets the binding up in its own zone, which is where it
  // sees `print` lines.
  final settings = LaunchSettings.read(args);
  final idle = settings.sessionIdleMs;
  if (idle != null) {
    // The harness lets a killed app's session expire within the run.
    // ignore: invalid_use_of_visible_for_testing_member
    TracewayClient.sessionInactivityOverride = Duration(milliseconds: idle);
  }
  Traceway.run(
    token: settings.token,
    baseUrl: settings.baseUrl,
    options: optionsFor(settings),
    child: FieldmartApp(settings: settings, telemetry: const TracewayTelemetry()),
  );
}

/// The SDK options of each variant. Everything not listed is the SDK's
/// default, which is the point.
TracewayOptions optionsFor(LaunchSettings s) {
  final images = s.variant == 'stream-noimg' ? 'off' : 'always';
  final capture = switch (s.variant) {
    'buffer' || 'stream-img' || 'stream-noimg' => true,
    _ => false,
  };
  return TracewayOptions(
    version: 'fieldtest-2.1.0',
    environment: 'fieldtest',
    attributes: s.attributes,
    remoteConfig: s.remote,
    debug: s.evidence,
    screenCapture: capture,
    recordAllSessions: s.variant == 'stream-img' || s.variant == 'stream-noimg',
    collection: capture
        ? {
            'replay': {'images': images},
          }
        : null,
    fps: s.fps ?? const TracewayOptions().fps,
    sessions: s.sessions,
  );
}

class TracewayTelemetry extends Telemetry {
  const TracewayTelemetry();

  @override
  String get name => 'traceway';

  @override
  List<NavigatorObserver> get navigatorObservers => [Traceway.navigatorObserver];

  @override
  List<NavigatorObserver> nestedNavigatorObservers() => [TracewayNavigatorObserver()];

  @override
  http.Client httpClient() => TracewayHttpClient(http.Client());

  @override
  Widget mask(Widget child, {MaskMode mode = MaskMode.blur}) => TracewayMask(
        mode: mode == MaskMode.blank ? const TracewayMaskMode.blank() : const TracewayMaskMode.blur(),
        child: child,
      );

  @override
  void screen(String path) => Traceway.recordNavigation(path);

  @override
  void track(String name, Map<String, Object> attributes) => Traceway.track(name, attributes);

  @override
  void metric(String name, double value, [Map<String, Object>? dimensions]) =>
      Traceway.metric(name, value, dimensions);

  @override
  void captureException(Object error, StackTrace stackTrace, [Map<String, String>? attributes]) =>
      Traceway.captureException(error, stackTrace, attributes);

  @override
  void captureMessage(String message, [Map<String, String>? attributes]) =>
      Traceway.captureMessage(message, attributes);

  @override
  void fullyDisplayed() => Traceway.reportFullyDisplayed();

  @override
  String? get sessionId => Traceway.currentSessionId;
}
