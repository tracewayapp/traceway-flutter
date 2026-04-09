class CircularBuffer<T> {
  final int capacity;
  final List<T?> _buffer;
  int _head = 0;
  int _length = 0;

  CircularBuffer(this.capacity) : _buffer = List<T?>.filled(capacity, null);

  int get length => _length;

  bool get isEmpty => _length == 0;

  void push(T value) {
    _buffer[_head] = value;
    _head = (_head + 1) % capacity;
    if (_length < capacity) {
      _length++;
    }
  }

  List<T> readAll() {
    if (_length == 0) return [];
    final result = <T>[];
    final start = (_head - _length + capacity) % capacity;
    for (var i = 0; i < _length; i++) {
      result.add(_buffer[(start + i) % capacity] as T);
    }
    return result;
  }

  void clear() {
    for (var i = 0; i < capacity; i++) {
      _buffer[i] = null;
    }
    _head = 0;
    _length = 0;
  }
}
