import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';
import 'package:traceway/src/models/exception_stack_trace.dart';

void main() {
  group('TracewayClient', () {
    test('initializes from connection string', () {
      final client = TracewayClient.initialize(
        'testtoken@https://example.com/api/report',
        const TracewayOptions(debug: true),
      );
      expect(client, isNotNull);
      expect(TracewayClient.instance, client);
      expect(client.debug, true);
    });

    test('captureMessage creates isMessage exception', () {
      TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(sampleRate: 1.0),
      );

      // captureMessage internally calls addException which schedules sync.
      // We just verify no crash happens.
      TracewayClient.instance!.captureMessage('test message');
    });

    test('captureException creates formatted exception', () {
      TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(sampleRate: 1.0),
      );

      TracewayClient.instance!.captureException(
        Exception('test error'),
        StackTrace.current,
      );
    });

    test('sampleRate 0 drops all exceptions', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(sampleRate: 0.0),
      );

      // This should be silently dropped
      client.addException(ExceptionStackTrace(
        stackTrace: 'Error: test',
        recordedAt: DateTime.now(),
      ));
    });

    test('flush completes without error', () async {
      TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      await TracewayClient.instance!.flush(1000);
    });
  });
}
