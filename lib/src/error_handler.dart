import 'dart:ui' show ErrorCallback;

import 'package:flutter/foundation.dart';

import 'traceway_client.dart';

class ErrorHandler {
  FlutterExceptionHandler? _previousFlutterErrorHandler;
  ErrorCallback? _previousPlatformErrorHandler;

  void install() {
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = _handleFlutterError;

    _previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
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
    return _previousPlatformErrorHandler?.call(error, stackTrace) ?? true;
  }

  void handleZoneError(Object error, StackTrace stackTrace) {
    if (TracewayClient.instance == null) {
      // The SDK did not start (or was shut down): the app's zone still
      // guards its errors, and they must not vanish.
      FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stackTrace));
      return;
    }
    _captureError(error, stackTrace);
  }

  void _captureError(Object error, StackTrace? stackTrace) {
    try {
      TracewayClient.instance?.captureUnhandledException(error, stackTrace);
    } catch (_) {
      // Reporting an error must never raise another one.
    }
  }
}
