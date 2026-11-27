import 'package:flutter/foundation.dart';

/// Whether a failure [guarded] contains is printed, one line per place.
/// The running client sets it from `TracewayOptions.debug`.
bool guardedDebugLogging = false;

/// The places that already printed a failure.
final Set<String> _reported = {};

/// Runs [body], code of the SDK that runs inside the app (a hook, a public
/// call, a timer), and contains any failure in it: the app never sees it,
/// and the SDK keeps working. Never for the app's own code, whose errors are
/// the app's.
///
/// [where] names the place; with debug output on, its first failure is
/// printed. A failure is never reported through Traceway itself.
void guarded(String where, void Function() body) {
  try {
    body();
  } catch (error) {
    _contained(where, error);
  }
}

/// Like [guarded], returning what [body] returns, or [fallback] when it
/// failed.
T guardedOr<T>(String where, T fallback, T Function() body) {
  try {
    return body();
  } catch (error) {
    _contained(where, error);
    return fallback;
  }
}

/// Like [guarded] for asynchronous work: completes when [body]'s future
/// does, normally even when it failed. For SDK futures nothing awaits
/// (`unawaited(guardedAsync('outbox.drain', outbox.drain))`), which would
/// otherwise reach the app's zone as an uncaught error.
Future<void> guardedAsync(String where, Future<void>? Function() body) async {
  try {
    await body();
  } catch (error) {
    _contained(where, error);
  }
}

/// `'$value'`, or its type when its `toString` throws: an object of the app
/// the SDK describes must not fail the call that describes it.
String safeToString(Object? value) {
  try {
    return '$value';
  } catch (_) {
    try {
      return "Instance of '${value.runtimeType}'";
    } catch (_) {
      return 'Instance of unknown type';
    }
  }
}

void _contained(String where, Object error) {
  if (!guardedDebugLogging || !_reported.add(where)) return;
  try {
    debugPrint('Traceway: $where failed: ${safeToString(error)}');
  } catch (_) {}
}

/// The reasons [debugOnce] already printed.
final Set<String> _explained = {};

/// Prints [message] once per [reason] when debug output is on: why the SDK
/// left something out (an ignored or sampled error, a dropped picture),
/// which the app would otherwise never see.
void debugOnce(String reason, String Function() message) {
  if (!guardedDebugLogging || !_explained.add(reason)) return;
  try {
    debugPrint(message());
  } catch (_) {}
}
