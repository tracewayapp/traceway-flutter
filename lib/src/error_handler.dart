import 'package:flutter/foundation.dart';

import 'models/exception_stack_trace.dart';
import 'stack_trace_formatter.dart';
import 'traceway_client.dart';

class ErrorHandler {
  FlutterExceptionHandler? _previousFlutterErrorHandler;

  void install() {
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = _handleFlutterError;

    PlatformDispatcher.instance.onError = _handlePlatformError;
  }

  void _handleFlutterError(FlutterErrorDetails details) {
    _captureError(details.exception, details.stack);

    final client = TracewayClient.instance;
    if (client != null && client.debug) {
      FlutterError.dumpErrorToConsole(details);
    }

    _previousFlutterErrorHandler?.call(details);
  }

  bool _handlePlatformError(Object error, StackTrace stackTrace) {
    _captureError(error, stackTrace);
    return true;
  }

  void handleZoneError(Object error, StackTrace stackTrace) {
    _captureError(error, stackTrace);
  }

  void _captureError(Object error, StackTrace? stackTrace) {
    final client = TracewayClient.instance;
    if (client == null) return;

    final formatted = formatFlutterError(error, stackTrace);
    client.addException(ExceptionStackTrace(
      stackTrace: formatted,
      recordedAt: DateTime.now(),
      isMessage: false,
    ));
  }
}
