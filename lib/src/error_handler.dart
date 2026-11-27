import 'dart:ui' show ErrorCallback;

import 'package:flutter/foundation.dart';

import 'guarded.dart';
import 'traceway_client.dart';

class ErrorHandler {
  FlutterExceptionHandler? _previousFlutterErrorHandler;
  ErrorCallback? _previousPlatformErrorHandler;
  bool _installed = false;

  /// The handler [Traceway.run] installed: one per process, however often
  /// `run` is called, so an error is recorded once.
  static ErrorHandler? _current;
  static ErrorHandler get current => _current ??= ErrorHandler();

  /// Uncaught errors of the `Traceway.run` zone handed on to the zone `run`
  /// was called in. From the root zone they come back through
  /// [PlatformDispatcher.onError]: recorded already, they are only passed on
  /// from there.
  final List<Object> _handedOn = [];

  /// Chains onto the app's `FlutterError.onError` and
  /// `PlatformDispatcher.onError`; once only, so a second call cannot make
  /// the handler its own predecessor.
  void install() {
    if (_installed) return;
    _installed = true;
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
    final previous = _previousFlutterErrorHandler;
    // The dump is the exception just reported, not lines the app logged.
    _quietly(() {
      // Flutter's own handlers print it already; a second dump would read
      // "Another exception was thrown".
      if (client != null && client.debug && !_printsErrors(previous)) {
        guarded('FlutterError dump',
            () => FlutterError.dumpErrorToConsole(details));
      }
      previous?.call(details);
    });
  }

  /// Whether [handler] is one of Flutter's, which print the error.
  static bool _printsErrors(FlutterExceptionHandler? handler) =>
      handler == FlutterError.presentError ||
      handler == FlutterError.dumpErrorToConsole;

  bool _handlePlatformError(Object error, StackTrace stackTrace) {
    if (!_wasHandedOn(error)) _captureError(error, stackTrace);
    final previous = _previousPlatformErrorHandler;
    if (previous != null) return previous(error, stackTrace);
    // Unhandled, the engine would have printed it.
    _print(error, stackTrace);
    return true;
  }

  /// The uncaught-error handler of the `Traceway.run` zone: records the
  /// error, then hands the same error and stack to the zone `run` was
  /// called in (rethrown from a `runZonedGuarded` handler, it goes to the
  /// parent zone's handler), so the app's own handling is what it would be
  /// without Traceway: an enclosing `runZonedGuarded` gets it, and from the
  /// root zone `PlatformDispatcher.onError` (Crashlytics, say) does, or the
  /// engine prints it.
  void handleZoneError(Object error, StackTrace stackTrace) {
    if (TracewayClient.instance != null) {
      _captureError(error, stackTrace);
      guarded('zone error', () {
        _handedOn.add(error);
        if (_handedOn.length > 8) _handedOn.removeAt(0);
      });
    }
    Error.throwWithStackTrace(error, stackTrace);
  }

  bool _wasHandedOn(Object error) {
    for (var i = 0; i < _handedOn.length; i++) {
      if (identical(_handedOn[i], error)) {
        _handedOn.removeAt(i);
        return true;
      }
    }
    return false;
  }

  static void _print(Object error, StackTrace stackTrace) {
    guarded('error print', () {
      _quietly(() => FlutterError.dumpErrorToConsole(FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'Traceway',
            context: ErrorDescription('while running the app (uncaught)'),
          )));
    });
  }

  /// Runs [body], the app's handler among it, without recording what it
  /// prints. What [body] throws is the app's: it goes on.
  static void _quietly(void Function() body) {
    final client = TracewayClient.instance;
    if (client == null) {
      body();
    } else {
      client.withoutConsoleCapture(body);
    }
  }

  void _captureError(Object error, StackTrace? stackTrace) {
    // Reporting an error must never raise another one.
    guarded(
        'unhandled error capture',
        () => TracewayClient.instance
            ?.captureUnhandledException(error, stackTrace));
  }
}
