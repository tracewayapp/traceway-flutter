// The `off` build of Fieldmart: the same app with no SDK at all.
import 'package:fieldmart_ui/fieldmart_ui.dart';
import 'package:flutter/widgets.dart';

void main(List<String> args) {
  final settings = LaunchSettings.read(args);
  runApp(FieldmartApp(settings: settings, telemetry: const NoTelemetry()));
}
