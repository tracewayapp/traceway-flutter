import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/circular_buffer.dart';

void main() {
  group('CircularBuffer', () {
    test('starts empty', () {
      final buffer = CircularBuffer<int>(5);
      expect(buffer.isEmpty, true);
      expect(buffer.length, 0);
      expect(buffer.readAll(), []);
    });

    test('push and readAll returns items in order', () {
      final buffer = CircularBuffer<int>(5);
      buffer.push(1);
      buffer.push(2);
      buffer.push(3);
      expect(buffer.length, 3);
      expect(buffer.readAll(), [1, 2, 3]);
    });

    test('wraps around when full', () {
      final buffer = CircularBuffer<int>(3);
      buffer.push(1);
      buffer.push(2);
      buffer.push(3);
      buffer.push(4);
      expect(buffer.length, 3);
      expect(buffer.readAll(), [2, 3, 4]);
    });

    test('wraps around multiple times', () {
      final buffer = CircularBuffer<int>(3);
      for (var i = 1; i <= 10; i++) {
        buffer.push(i);
      }
      expect(buffer.length, 3);
      expect(buffer.readAll(), [8, 9, 10]);
    });

    test('clear resets buffer', () {
      final buffer = CircularBuffer<int>(3);
      buffer.push(1);
      buffer.push(2);
      buffer.clear();
      expect(buffer.isEmpty, true);
      expect(buffer.length, 0);
      expect(buffer.readAll(), []);
    });

    test('works after clear', () {
      final buffer = CircularBuffer<int>(3);
      buffer.push(1);
      buffer.push(2);
      buffer.clear();
      buffer.push(10);
      buffer.push(20);
      expect(buffer.readAll(), [10, 20]);
    });

    test('capacity of 1', () {
      final buffer = CircularBuffer<String>(1);
      buffer.push('a');
      expect(buffer.readAll(), ['a']);
      buffer.push('b');
      expect(buffer.readAll(), ['b']);
      expect(buffer.length, 1);
    });
  });
}
