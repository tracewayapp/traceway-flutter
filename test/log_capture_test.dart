import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/log_capture.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

void main() {
  group('buildLogZoneSpec', () {
    test('print inside the zone is buffered as a LogEvent', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      runZoned(() {
        // Suppress stdout during the test by overriding parent print too.
        // ignore: avoid_print
        print('hello from zone');
      }, zoneSpecification: buildLogZoneSpec());

      final logs = client.bufferedEvents.whereType<LogEvent>().toList();
      expect(logs, hasLength(1));
      expect(logs.single.message, 'hello from zone');
    });

    test('print is forwarded to the parent zone', () {
      TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      final captured = <String>[];
      final outerSpec = ZoneSpecification(
        print: (self, parent, zone, line) => captured.add(line),
      );

      runZoned(() {
        runZoned(() {
          // ignore: avoid_print
          print('forwarded');
        }, zoneSpecification: buildLogZoneSpec());
      }, zoneSpecification: outerSpec);

      expect(captured, ['forwarded']);
    });

    test('does not buffer when captureLogs is disabled', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureLogs: false),
      );

      runZoned(() {
        // ignore: avoid_print
        print('ignored');
      }, zoneSpecification: buildLogZoneSpec());

      expect(client.bufferedEvents.whereType<LogEvent>(), isEmpty);
    });
  });
}
