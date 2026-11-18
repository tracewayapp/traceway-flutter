import 'dart:convert';

import '../persistence/state_store.dart';

const String _key = 'metricsPending';
const int _maxPayloads = 3;
const int _maxChars = 96 * 1024;
const int _maxAgeMs = 24 * 60 * 60 * 1000;

class PendingPayload {
  PendingPayload(this.id, this.timeMs, this.body);
  final String id;
  final int timeMs;

  /// The OTLP request as protobuf, so a resend can restamp its resource.
  final List<int> body;
}

/// Metrics payloads whose upload failed or whose app went to the background
/// before the answer. Small and short-lived on purpose, like the browser
/// SDK's: a device that stays offline loses its oldest numbers, it never
/// builds a backlog.
class PendingMetrics {
  PendingMetrics(this._store, {int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final StateStore Function() _store;
  final int Function() _now;

  List<Map<String, dynamic>> _read() {
    final raw = _store().get(_key);
    if (raw is! List) return [];
    final oldest = _now() - _maxAgeMs;
    return [
      for (final e in raw)
        if (e is Map &&
            e['id'] is String &&
            e['t'] is int &&
            (e['t'] as int) > oldest &&
            e['p'] is String)
          e.cast<String, dynamic>(),
    ];
  }

  void _write(List<Map<String, dynamic>> list) {
    var size = jsonEncode(list).length;
    while (
        list.isNotEmpty && (list.length > _maxPayloads || size > _maxChars)) {
      list.removeAt(0);
      size = jsonEncode(list).length;
    }
    _store().set(_key, list.isEmpty ? null : list);
  }

  void add(String id, List<int> body) {
    final list = _read()..removeWhere((e) => e['id'] == id);
    list.add({'id': id, 't': _now(), 'p': base64Encode(body)});
    _write(list);
  }

  void remove(String id) {
    final list = _read();
    if (list.any((e) => e['id'] == id)) {
      _write(list..removeWhere((e) => e['id'] == id));
    }
  }

  /// Hands over everything except [skip] and forgets it: a payload gets one
  /// more attempt, never a third.
  List<PendingPayload> take(Set<String> skip) {
    final list = _read();
    final taken = list.where((e) => !skip.contains(e['id'])).toList();
    if (taken.isNotEmpty) {
      _write(list.where((e) => skip.contains(e['id'])).toList());
    }
    return [
      for (final e in taken)
        PendingPayload(
            e['id'] as String, e['t'] as int, base64Decode(e['p'] as String)),
    ];
  }
}
