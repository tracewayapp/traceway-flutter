const String tracewaySdkName = 'traceway-flutter';
const String tracewaySdkVersion = '2.0.0-beta.1';

/// Sent with every OTLP request, as the OTLP exporter specification asks.
const String otlpUserAgent =
    'OTel-OTLP-Exporter-Dart/$tracewaySdkVersion $tracewaySdkName';
