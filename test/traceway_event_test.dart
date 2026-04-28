import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/traceway_event.dart';

void main() {
  group('TracewayEvent JSON', () {
    test('LogEvent round-trips', () {
      final ts = DateTime.utc(2025, 1, 2, 3, 4, 5);
      final src = LogEvent(message: 'hello', level: 'warn', timestamp: ts);
      final restored = TracewayEvent.fromJson(src.toJson());
      expect(restored, isA<LogEvent>());
      final log = restored as LogEvent;
      expect(log.message, 'hello');
      expect(log.level, 'warn');
      expect(log.timestamp.toUtc(), ts);
    });

    test('NetworkEvent round-trips', () {
      final ts = DateTime.utc(2025, 1, 2, 3, 4, 5);
      final src = NetworkEvent(
        method: 'POST',
        url: 'https://api.example.com/v1/items',
        duration: const Duration(milliseconds: 234),
        statusCode: 201,
        requestBytes: 42,
        responseBytes: 87,
        timestamp: ts,
      );
      final restored =
          TracewayEvent.fromJson(src.toJson()) as NetworkEvent;
      expect(restored.method, 'POST');
      expect(restored.url, 'https://api.example.com/v1/items');
      expect(restored.duration, const Duration(milliseconds: 234));
      expect(restored.statusCode, 201);
      expect(restored.requestBytes, 42);
      expect(restored.responseBytes, 87);
      expect(restored.error, isNull);
      expect(restored.timestamp.toUtc(), ts);
    });

    test('NetworkEvent serializes error and skips null fields', () {
      final src = NetworkEvent(
        method: 'GET',
        url: 'https://x.test/',
        duration: const Duration(milliseconds: 0),
        error: 'SocketException: no route',
      );
      final json = src.toJson();
      expect(json.containsKey('statusCode'), false);
      expect(json.containsKey('requestBytes'), false);
      expect(json['error'], 'SocketException: no route');
      final restored = TracewayEvent.fromJson(json) as NetworkEvent;
      expect(restored.error, 'SocketException: no route');
      expect(restored.statusCode, isNull);
    });

    test('NavigationEvent round-trips', () {
      final src = NavigationEvent(action: 'push', from: '/a', to: '/b');
      final restored =
          TracewayEvent.fromJson(src.toJson()) as NavigationEvent;
      expect(restored.action, 'push');
      expect(restored.from, '/a');
      expect(restored.to, '/b');
    });

    test('CustomEvent round-trips with data', () {
      final src = CustomEvent(
        category: 'cart',
        name: 'add_item',
        data: {'sku': 'SKU-1', 'qty': 2},
      );
      final restored =
          TracewayEvent.fromJson(src.toJson()) as CustomEvent;
      expect(restored.category, 'cart');
      expect(restored.name, 'add_item');
      expect(restored.data, {'sku': 'SKU-1', 'qty': 2});
    });

    test('fromJson rejects unknown types', () {
      expect(
        () => TracewayEvent.fromJson({
          'type': 'unknown',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
        throwsFormatException,
      );
    });
  });
}
