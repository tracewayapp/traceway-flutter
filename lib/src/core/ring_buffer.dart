class BufferEntry<T> {
  BufferEntry({
    required this.timeMs,
    required this.signal,
    required this.bytes,
    required this.item,
  });

  final int timeMs;
  final String signal;
  final int bytes;
  final T item;
}

/// Telemetry held on the device until a trigger or capture asks for it.
/// Bounded by total size and by age; the oldest entries go first.
class RingBuffer<T> {
  RingBuffer({
    required int maxBytes,
    required int maxAgeMs,
    int Function()? now,
  })  : _maxBytes = maxBytes,
        _maxAgeMs = maxAgeMs,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  int _maxBytes;
  int _maxAgeMs;
  final int Function() _now;
  List<BufferEntry<T>> _entries = [];
  int _totalBytes = 0;
  int _evicted = 0;

  int get length => _entries.length;
  int get totalBytes => _totalBytes;
  int get evictedCount => _evicted;

  void configure({required int maxBytes, required int maxAgeMs}) {
    _maxBytes = maxBytes;
    _maxAgeMs = maxAgeMs;
    _trim();
  }

  void push(BufferEntry<T> entry) {
    _entries.add(entry);
    _totalBytes += entry.bytes;
    _trim();
  }

  /// Removes and returns the entries inside the window whose signal is
  /// selected, oldest first. `signals == null` selects every signal.
  List<BufferEntry<T>> take(int sinceMs, Set<String>? signals, [int? untilMs]) {
    _trim();
    final taken = <BufferEntry<T>>[];
    final kept = <BufferEntry<T>>[];
    for (final entry in _entries) {
      if (entry.timeMs >= sinceMs &&
          (untilMs == null || entry.timeMs <= untilMs) &&
          (signals == null || signals.contains(entry.signal))) {
        taken.add(entry);
        _totalBytes -= entry.bytes;
      } else {
        kept.add(entry);
      }
    }
    _entries = kept;
    return taken;
  }

  List<BufferEntry<T>> snapshot() {
    _trim();
    return List.of(_entries);
  }

  void retain(bool Function(BufferEntry<T>) keep) {
    final kept = <BufferEntry<T>>[];
    var bytes = 0;
    for (final entry in _entries) {
      if (keep(entry)) {
        kept.add(entry);
        bytes += entry.bytes;
      }
    }
    _entries = kept;
    _totalBytes = bytes;
  }

  void clear() {
    _entries = [];
    _totalBytes = 0;
  }

  void _trim() {
    final cutoff = _now() - _maxAgeMs;
    var drop = 0;
    var bytes = _totalBytes;
    while (drop < _entries.length &&
        (bytes > _maxBytes || _entries[drop].timeMs < cutoff)) {
      bytes -= _entries[drop].bytes;
      drop++;
    }
    if (drop > 0) {
      _entries = _entries.sublist(drop);
      _totalBytes = bytes;
      _evicted += drop;
    }
  }
}
