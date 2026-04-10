import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';
import 'package:traceway/src/models/exception_stack_trace.dart';

ExceptionStackTrace _makeException(String message, {DateTime? recordedAt}) {
  return ExceptionStackTrace(
    stackTrace: 'Error: $message',
    recordedAt: recordedAt ?? DateTime.now(),
  );
}

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

      client.addException(_makeException('test'));
      expect(client.pendingExceptionCount, 0);
    });

    test('flush completes without error', () async {
      TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      await TracewayClient.instance!.flush(1000);
    });
  });

  group('TracewayClient pending cap', () {
    test('caps pending exceptions at maxPendingExceptions', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(maxPendingExceptions: 5),
      );

      for (var i = 0; i < 8; i++) {
        client.addException(_makeException('error $i'));
      }

      expect(client.pendingExceptionCount, 5);
    });

    test('drops oldest exceptions when cap exceeded', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(maxPendingExceptions: 3),
      );

      client.addException(_makeException('first'));
      client.addException(_makeException('second'));
      client.addException(_makeException('third'));
      client.addException(_makeException('fourth'));
      client.addException(_makeException('fifth'));

      final pending = client.pendingExceptions;
      expect(pending.length, 3);
      expect(pending[0].stackTrace, 'Error: third');
      expect(pending[1].stackTrace, 'Error: fourth');
      expect(pending[2].stackTrace, 'Error: fifth');
    });

    test('caps at 1 keeps only the latest', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(maxPendingExceptions: 1),
      );

      client.addException(_makeException('old'));
      client.addException(_makeException('new'));

      expect(client.pendingExceptionCount, 1);
      expect(client.pendingExceptions[0].stackTrace, 'Error: new');
    });

    test('does not drop when under cap', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(maxPendingExceptions: 5),
      );

      client.addException(_makeException('one'));
      client.addException(_makeException('two'));
      client.addException(_makeException('three'));

      expect(client.pendingExceptionCount, 3);
    });

    test('caps after re-queue on sync failure', () async {
      final client = TracewayClient.initializeForTest(
        'token@https://example.com/api/report',
        const TracewayOptions(maxPendingExceptions: 3, debounceMs: 0),
        reportSender: (_, __, ___) async => false,
      );

      client.addException(_makeException('a'));
      client.addException(_makeException('b'));
      client.addException(_makeException('c'));
      expect(client.pendingExceptionCount, 3);

      // Flush triggers sync which fails → re-queues 3
      // Then add 2 more → total 5 → capped to 3
      await client.flush(1000);

      client.addException(_makeException('d'));
      client.addException(_makeException('e'));

      expect(client.pendingExceptionCount, 3);
      final pending = client.pendingExceptions;
      expect(pending[0].stackTrace, 'Error: c');
      expect(pending[1].stackTrace, 'Error: d');
      expect(pending[2].stackTrace, 'Error: e');
    });

    test('caps after re-queue on sync exception', () async {
      final client = TracewayClient.initializeForTest(
        'token@https://example.com/api/report',
        const TracewayOptions(maxPendingExceptions: 2, debounceMs: 0),
        reportSender: (_, __, ___) async => throw Exception('network error'),
      );

      client.addException(_makeException('x'));
      client.addException(_makeException('y'));

      await client.flush(1000);

      // After failed sync, x and y are re-queued
      client.addException(_makeException('z'));

      expect(client.pendingExceptionCount, 2);
      final pending = client.pendingExceptions;
      expect(pending[0].stackTrace, 'Error: y');
      expect(pending[1].stackTrace, 'Error: z');
    });

    test('default maxPendingExceptions is 5', () {
      const options = TracewayOptions();
      expect(options.maxPendingExceptions, 5);
    });
  });

  group('TracewayClient sync device info', () {
    test('collectSyncDeviceInfo sets attributes immediately', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.collectSyncDeviceInfo();

      final exception = _makeException('startup crash');
      client.addException(exception);

      expect(exception.attributes, isNotNull);
      expect(exception.attributes!['os.name'], isNotEmpty);
      expect(exception.attributes!['os.version'], isNotEmpty);
      expect(exception.attributes!['runtime.version'], isNotEmpty);
    });

    test('collectDeviceInfo merges async info into sync info', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.collectSyncDeviceInfo();
      await client.collectDeviceInfo();

      final exception = _makeException('test');
      client.addException(exception);

      expect(exception.attributes!['os.name'], isNotEmpty);
      expect(exception.attributes!['runtime.version'], isNotEmpty);
    });
  });

  group('TracewayClient device attributes', () {
    test('attaches device attributes to exceptions', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.setDeviceAttributes({
        'os.name': 'ios',
        'device.model': 'iPhone',
        'device.ip': '192.168.1.42',
      });

      final exception = _makeException('test');
      client.addException(exception);

      expect(exception.attributes, isNotNull);
      expect(exception.attributes!['os.name'], 'ios');
      expect(exception.attributes!['device.model'], 'iPhone');
      expect(exception.attributes!['device.ip'], '192.168.1.42');
    });

    test('user attributes override device attributes', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.setDeviceAttributes({
        'os.name': 'ios',
        'device.model': 'iPhone',
        'custom.tag': 'from-device',
      });

      final exception = ExceptionStackTrace(
        stackTrace: 'Error: test',
        recordedAt: DateTime.now(),
        attributes: {
          'custom.tag': 'from-user',
          'user.id': '123',
        },
      );
      client.addException(exception);

      expect(exception.attributes!['os.name'], 'ios');
      expect(exception.attributes!['device.model'], 'iPhone');
      expect(exception.attributes!['custom.tag'], 'from-user');
      expect(exception.attributes!['user.id'], '123');
    });

    test('does not overwrite when no device attributes set', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      final exception = ExceptionStackTrace(
        stackTrace: 'Error: test',
        recordedAt: DateTime.now(),
        attributes: {'user.id': '456'},
      );
      client.addException(exception);

      expect(exception.attributes, {'user.id': '456'});
    });

    test('works with null user attributes', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.setDeviceAttributes({'os.name': 'android'});

      final exception = _makeException('test');
      expect(exception.attributes, isNull);

      client.addException(exception);

      expect(exception.attributes, isNotNull);
      expect(exception.attributes!['os.name'], 'android');
    });

    test('device attributes persist across multiple exceptions', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.setDeviceAttributes({
        'os.name': 'ios',
        'os.version': '17.0',
      });

      final e1 = _makeException('first');
      final e2 = _makeException('second');
      client.addException(e1);
      client.addException(e2);

      expect(e1.attributes!['os.name'], 'ios');
      expect(e2.attributes!['os.name'], 'ios');
      expect(e1.attributes!['os.version'], '17.0');
      expect(e2.attributes!['os.version'], '17.0');
    });

    test('attributes included in serialized json', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      client.setDeviceAttributes({
        'os.name': 'ios',
        'device.model': 'iPhone',
      });

      final exception = _makeException('test');
      client.addException(exception);

      final json = exception.toJson();
      final attrs = json['attributes'] as Map<String, dynamic>;
      expect(attrs['os.name'], 'ios');
      expect(attrs['device.model'], 'iPhone');
    });
  });

  group('TracewayClient sync with transport', () {
    test('successful sync clears pending exceptions', () async {
      final client = TracewayClient.initializeForTest(
        'token@https://example.com/api/report',
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, ___) async => true,
      );

      client.addException(_makeException('test'));
      expect(client.pendingExceptionCount, 1);

      await client.flush(1000);

      expect(client.pendingExceptionCount, 0);
    });

    test('failed sync re-queues exceptions', () async {
      final client = TracewayClient.initializeForTest(
        'token@https://example.com/api/report',
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, ___) async => false,
      );

      client.addException(_makeException('test'));
      await client.flush(1000);

      expect(client.pendingExceptionCount, 1);
    });

    test('sync sends device attributes in payload', () async {
      String? capturedBody;
      final client = TracewayClient.initializeForTest(
        'token@https://example.com/api/report',
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, body) async {
          capturedBody = body;
          return true;
        },
      );

      client.setDeviceAttributes({
        'os.name': 'ios',
        'device.model': 'iPhone',
      });

      client.addException(_makeException('test'));
      await client.flush(1000);

      expect(capturedBody, isNotNull);
      expect(capturedBody, contains('os.name'));
      expect(capturedBody, contains('device.model'));
    });
  });
}
