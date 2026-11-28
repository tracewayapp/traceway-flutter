import 'dart:io';

import 'package:flutter/services.dart';

/// The marker lines of 02-APP-SPEC.md §7 (`FM_READY <epochMs>`, ...).
///
/// They never go through `print`: the SDK records every printed line as a
/// log, and markers are the harness's, not the app's. Linux writes them to
/// stdout; Android to logcat with tag `FM` through `MainActivity`.
class Markers {
  Markers._();

  static const _channel = MethodChannel('fieldmart/markers');

  /// Named markers with their times, for the probe file.
  static final List<Map<String, Object>> recorded = [];

  static void emit(String line) {
    if (Platform.isAndroid) {
      // Fire and forget: the line carries its own time.
      _channel.invokeMethod<void>('log', line).catchError((Object _) {});
    } else {
      stdout.writeln(line);
    }
  }

  /// `<NAME> <epochMs>` (plus [extra]), remembered for the probe.
  static int mark(String name, {String? extra, int? epochMs}) {
    final at = epochMs ?? DateTime.now().millisecondsSinceEpoch;
    recorded.add({'name': extra == null ? name : '$name $extra', 'epochMs': at});
    emit(extra == null ? '$name $at' : '$name $extra $at');
    return at;
  }

  /// A JSON payload line, e.g. `FM_BOXES {...}`.
  static void json(String name, String payload) => emit('$name $payload');
}
