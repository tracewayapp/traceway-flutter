import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/models/session_recording_payload.dart';

void main() {
  group('SessionRecordingPayload', () {
    test('defaults logs and actions to empty lists', () {
      const payload = SessionRecordingPayload(exceptionId: 'exc-1');
      expect(payload.events, isEmpty);
      expect(payload.logs, isEmpty);
      expect(payload.actions, isEmpty);

      final json = payload.toJson();
      expect(json.containsKey('logs'), false);
      expect(json.containsKey('actions'), false);
    });

    test('logs and actions round-trip through json separately', () {
      final ts = DateTime.utc(2025, 5, 6, 7, 8, 9);
      final original = SessionRecordingPayload(
        exceptionId: 'exc-1',
        events: const [
          {'type': 'flutter_video', 'data': 'base64...'}
        ],
        logs: [
          LogEvent(message: 'log line', level: 'warn', timestamp: ts),
        ],
        actions: [
          NetworkEvent(
            method: 'GET',
            url: 'https://x/',
            duration: const Duration(milliseconds: 12),
            statusCode: 200,
            timestamp: ts,
          ),
          NavigationEvent(
            action: 'push',
            from: '/a',
            to: '/b',
            timestamp: ts,
          ),
          CustomEvent(
            category: 'cart',
            name: 'add',
            data: {'sku': 'A'},
            timestamp: ts,
          ),
        ],
      );

      final encoded = jsonEncode(original.toJson());
      final restored = SessionRecordingPayload.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );

      expect(restored.events, hasLength(1));
      expect(restored.logs, hasLength(1));
      expect(restored.logs.single.message, 'log line');
      expect(restored.actions, hasLength(3));
      expect(restored.actions[0], isA<NetworkEvent>());
      expect((restored.actions[0] as NetworkEvent).statusCode, 200);
      expect(restored.actions[1], isA<NavigationEvent>());
      expect((restored.actions[1] as NavigationEvent).to, '/b');
      expect(restored.actions[2], isA<CustomEvent>());
      expect((restored.actions[2] as CustomEvent).data, {'sku': 'A'});
    });

    test('json without logs/actions rehydrates with empty lists', () {
      final json = {
        'exceptionId': 'exc-1',
        'events': const [
          {'type': 'flutter_video', 'data': 'base64...'}
        ],
      };

      final payload = SessionRecordingPayload.fromJson(json);
      expect(payload.events, hasLength(1));
      expect(payload.logs, isEmpty);
      expect(payload.actions, isEmpty);
    });

    test('startedAt and endedAt round-trip through json', () {
      final start = DateTime.utc(2025, 5, 6, 7, 8, 9);
      final end = DateTime.utc(2025, 5, 6, 7, 8, 19, 250);
      final original = SessionRecordingPayload(
        exceptionId: 'exc-1',
        startedAt: start,
        endedAt: end,
      );

      final json = original.toJson();
      expect(json['startedAt'], '2025-05-06T07:08:09.000Z');
      expect(json['endedAt'], '2025-05-06T07:08:19.250Z');

      final restored = SessionRecordingPayload.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored.startedAt, start);
      expect(restored.endedAt, end);
    });

    test('json without startedAt/endedAt rehydrates as null', () {
      final payload = SessionRecordingPayload.fromJson({
        'exceptionId': 'exc-1',
        'events': const [],
      });
      expect(payload.startedAt, isNull);
      expect(payload.endedAt, isNull);
    });

    test('toJson omits startedAt/endedAt when null', () {
      const payload = SessionRecordingPayload(exceptionId: 'exc-1');
      final json = payload.toJson();
      expect(json.containsKey('startedAt'), false);
      expect(json.containsKey('endedAt'), false);
    });
  });
}
