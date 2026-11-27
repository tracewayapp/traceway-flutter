const String tracewaySdkName = 'traceway-flutter';
const String tracewaySdkVersion = '2.1.0';

/// Sent with every OTLP request, as the OTLP exporter specification asks.
const String otlpUserAgent =
    'OTel-OTLP-Exporter-Dart/$tracewaySdkVersion $tracewaySdkName';
