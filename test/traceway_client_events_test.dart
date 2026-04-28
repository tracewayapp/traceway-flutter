import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/models/exception_stack_trace.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

ExceptionStackTrace _makeException(String message) => ExceptionStackTrace(
    stackTrace: 'Error: $message', recordedAt: DateTime.now());

void main() {
  group('TracewayClient event capture', () {
    test('recordLog buffers a LogEvent', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      client.recordLog('hello world');
      final logs = client.bufferedLogs;
      expect(logs, hasLength(1));
      expect(logs.single.message, 'hello world');
      expect(client.bufferedActions, isEmpty);
    });

    test('recordLog is a no-op when captureLogs is disabled', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureLogs: false),
      );
      client.recordLog('ignored');
      expect(client.bufferedLogs, isEmpty);
    });

    test('recordNetworkEvent is gated by captureNetwork', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureNetwork: false),
      );
      client.recordNetworkEvent(NetworkEvent(
        method: 'GET',
        url: 'https://x/',
        duration: const Duration(milliseconds: 1),
      ));
      expect(client.bufferedActions, isEmpty);
    });

    test('recordNavigationEvent is gated by captureNavigation', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureNavigation: false),
      );
      client.recordNavigationEvent(
          NavigationEvent(action: 'push', from: '/a', to: '/b'));
      expect(client.bufferedActions, isEmpty);
    });

    test('recordAction is always captured', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(
          captureLogs: false,
          captureNetwork: false,
          captureNavigation: false,
        ),
      );
      client.recordAction(category: 'cart', name: 'add', data: {'sku': 'X'});
      final actions = client.bufferedActions;
      expect(actions, hasLength(1));
      final custom = actions.single as CustomEvent;
      expect(custom.category, 'cart');
      expect(custom.name, 'add');
      expect(custom.data, {'sku': 'X'});
      expect(client.bufferedLogs, isEmpty);
    });

    test('addException snapshots logs and actions into session recordings', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      client.recordLog('first');
      client.recordAction(category: 'flow', name: 'started');
      final exception = _makeException('boom');
      client.addException(exception);

      expect(exception.sessionRecordingId, isNotNull);
      expect(client.pendingRecordings, hasLength(1));

      final recording = client.pendingRecordings.single;
      expect(recording.exceptionId, exception.sessionRecordingId);
      expect(recording.logs.map((e) => e.message).toList(), ['first']);
      expect(recording.actions, hasLength(1));
      expect(recording.actions.single, isA<CustomEvent>());
    });

    test('session recording json stores logs and actions separately', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      client.recordLog('serialized');
      client.recordAction(category: 'flow', name: 'started');
      final exception = _makeException('boom');
      client.addException(exception);

      final json = client.pendingRecordings.single.toJson();
      expect(json['logs'], isA<List>());
      expect(json['actions'], isA<List>());

      final logs = json['logs'] as List;
      expect(logs, hasLength(1));
      expect(logs.first['type'], 'log');
      expect(logs.first['message'], 'serialized');

      final actions = json['actions'] as List;
      expect(actions, hasLength(1));
      expect(actions.first['type'], 'custom');
      expect(actions.first['name'], 'started');
    });

    test('session recording without video falls back to event timestamp range',
        () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      final before = DateTime.now().toUtc();
      client.recordLog('first');
      client.recordAction(category: 'flow', name: 'mid');
      client.recordLog('last');
      final exception = _makeException('boom');
      client.addException(exception);
      final after = DateTime.now().toUtc();

      final recording = client.pendingRecordings.single;
      expect(recording.startedAt, isNotNull);
      expect(recording.endedAt, isNotNull);

      // The interval must cover all buffered events and stay inside the
      // wall-clock window we observed around the captures.
      expect(recording.startedAt!.isBefore(recording.endedAt!), isTrue);
      expect(
        recording.startedAt!
            .isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        recording.endedAt!.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('logs and actions are independently capped at 200 entries', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      for (var i = 0; i < 250; i++) {
        client.recordLog('log-$i');
        client.recordAction(category: 'flow', name: 'action-$i');
      }

      expect(client.bufferedLogs, hasLength(200));
      expect(client.bufferedLogs.first.message, 'log-50');
      expect(client.bufferedLogs.last.message, 'log-249');

      expect(client.bufferedActions, hasLength(200));
      final first = client.bufferedActions.first as CustomEvent;
      final last = client.bufferedActions.last as CustomEvent;
      expect(first.name, 'action-50');
      expect(last.name, 'action-249');
    });
  });
}
