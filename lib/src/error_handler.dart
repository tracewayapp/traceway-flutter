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
    // The framework marks some errors silent: not the app's to report, such
    // as an image that failed to load where nothing asked to be told (no
    // errorBuilder). It still prints them in debug builds.
    if (!details.silent) _captureError(details.exception, details.stack);

    final client = TracewayClient.instance;
    // The dump is the exception just reported, not lines the app logged.
    _quietly(() {
      if (client != null && client.debug) {
        FlutterError.dumpErrorToConsole(details);
      }
      _previousFlutterErrorHandler?.call(details);
    });
  }

  bool _handlePlatformError(Object error, StackTrace stackTrace) {
    _captureError(error, stackTrace);
    final previous = _previousPlatformErrorHandler;
    if (previous != null) return previous(error, stackTrace);
    // Unhandled, the engine would have printed it.
    _print(error, stackTrace);
    return true;
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
    // Outside the zone the error would be printed: in `flutter run`, and in
    // the device log, whether or not it could be sent.
    _print(error, stackTrace);
  }

  static void _print(Object error, StackTrace stackTrace) {
    try {
      _quietly(() => FlutterError.dumpErrorToConsole(FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Traceway',
            context: ErrorDescription('while running the app (uncaught)'),
          )));
    } catch (_) {}
  }

  static void _quietly(void Function() body) {
    final client = TracewayClient.instance;
    if (client == null) {
      body();
    } else {
      client.withoutConsoleCapture(body);
    }
  }

  void _captureError(Object error, StackTrace? stackTrace) {
    try {
      TracewayClient.instance?.captureUnhandledException(error, stackTrace);
    } catch (_) {
      // Reporting an error must never raise another one.
    }
  }
}
