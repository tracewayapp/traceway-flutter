import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// How serious a log line is, from [Traceway.log] or a `package:logging`
/// record. The session timeline shows it, and the console's minimum
/// severity in the remote settings filters by it. A printed line is [info].
enum TracewayLogLevel { trace, debug, info, warn, error, fatal }

extension TracewayLogLevelSeverity on TracewayLogLevel {
  Severity get severity => switch (this) {
        TracewayLogLevel.trace => Severity.TRACE,
        TracewayLogLevel.debug => Severity.DEBUG,
        TracewayLogLevel.info => Severity.INFO,
        TracewayLogLevel.warn => Severity.WARN,
        TracewayLogLevel.error => Severity.ERROR,
        TracewayLogLevel.fatal => Severity.FATAL,
      };

  String get severityText => name.toUpperCase();
}
