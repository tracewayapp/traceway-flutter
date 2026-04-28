import 'dart:collection';

import 'traceway_event.dart';

/// Time-windowed FIFO buffer with a hard size cap.
///
/// Drops entries older than [window] and keeps at most [maxSize] entries.
/// Pruning runs on every [add] and [snapshot] so the buffer is self-maintaining
/// without a background timer.
class EventBuffer<T extends TracewayEvent> {
  final Duration window;
  final int maxSize;
  final Queue<T> _q = Queue<T>();

  EventBuffer({
    this.window = const Duration(seconds: 10),
    this.maxSize = 500,
  });

  void add(T event) {
    _q.addLast(event);
    _prune();
  }

  /// Returns events ordered oldest -> newest.
  List<T> snapshot() {
    _prune();
    return List<T>.unmodifiable(_q);
  }

  void clear() => _q.clear();

  int get length => _q.length;

  void _prune() {
    final cutoff = DateTime.now().subtract(window);
    while (_q.isNotEmpty && _q.first.timestamp.isBefore(cutoff)) {
      _q.removeFirst();
    }
    while (_q.length > maxSize) {
      _q.removeFirst();
    }
  }
}
