import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/event_buffer.dart';
import 'package:traceway/src/events/traceway_event.dart';

LogEvent _log(String message, DateTime ts) =>
    LogEvent(message: message, timestamp: ts);

void main() {
  group('EventBuffer', () {
    test('starts empty', () {
      final buf = EventBuffer<LogEvent>();
      expect(buf.length, 0);
      expect(buf.snapshot(), isEmpty);
    });

    test('preserves insertion order in snapshot', () {
      final buf = EventBuffer<LogEvent>();
      final now = DateTime.now();
      buf.add(_log('a', now.subtract(const Duration(seconds: 3))));
      buf.add(_log('b', now.subtract(const Duration(seconds: 2))));
      buf.add(_log('c', now.subtract(const Duration(seconds: 1))));

      final events = buf.snapshot().cast<LogEvent>();
      expect(events.map((e) => e.message).toList(), ['a', 'b', 'c']);
    });

    test('drops events older than the time window', () {
      final buf = EventBuffer<LogEvent>(window: const Duration(seconds: 10));
      final now = DateTime.now();
      buf.add(_log('old', now.subtract(const Duration(seconds: 30))));
      buf.add(_log('stale', now.subtract(const Duration(seconds: 11))));
      buf.add(_log('fresh', now.subtract(const Duration(seconds: 2))));

      final events = buf.snapshot().cast<LogEvent>();
      expect(events.map((e) => e.message).toList(), ['fresh']);
    });

    test('enforces hard size cap even within the window', () {
      final buf = EventBuffer<LogEvent>(
        window: const Duration(hours: 1),
        maxSize: 3,
      );
      final now = DateTime.now();
      for (var i = 0; i < 6; i++) {
        buf.add(_log('m$i', now.subtract(Duration(milliseconds: 100 - i))));
      }
      final events = buf.snapshot().cast<LogEvent>();
      expect(events.length, 3);
      // Oldest three should have been dropped, newest three kept.
      expect(events.map((e) => e.message).toList(), ['m3', 'm4', 'm5']);
    });

    test('snapshot is unmodifiable', () {
      final buf = EventBuffer<LogEvent>();
      buf.add(_log('a', DateTime.now()));
      final snap = buf.snapshot();
      expect(() => snap.add(_log('b', DateTime.now())), throwsUnsupportedError);
    });

    test('clear empties the buffer', () {
      final buf = EventBuffer<LogEvent>();
      buf.add(_log('a', DateTime.now()));
      buf.add(_log('b', DateTime.now()));
      buf.clear();
      expect(buf.length, 0);
      expect(buf.snapshot(), isEmpty);
    });
  });
}
