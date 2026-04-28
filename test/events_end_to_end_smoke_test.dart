import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:traceway/src/events/log_capture.dart';
import 'package:traceway/src/events/network_capture.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/events/traceway_navigator_observer.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

MaterialPageRoute<void> _route(String name) => MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => const SizedBox.shrink(),
    );

/// End-to-end smoke test that wires the same hooks `Traceway.run` installs
/// (log Zone spec, HttpOverrides, NavigatorObserver) and verifies a captured
/// exception carries logs and actions in separate recording buffers.
void main() {
  group('events end-to-end smoke', () {
    late HttpServer server;
    late Uri baseUri;
    HttpOverrides? previousOverrides;

    setUp(() async {
      previousOverrides = HttpOverrides.current;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        await req.drain<void>();
        req.response.write('ok');
        await req.response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
    });

    test('captureException attaches log + network + nav + custom events',
        () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);
      final observer = TracewayNavigatorObserver();

      // Drive the four channels inside the log Zone spec, mirroring what
      // `Traceway.run` sets up for the host app.
      await runZoned(() async {
        // ignore: avoid_print
        print('user tapped pay');
        await http.get(baseUri.replace(path: '/checkout'));
        observer.didPush(_route('/cart'), _route('/'));
        client.recordAction(
          category: 'cart',
          name: 'add_item',
          data: {'sku': 'SKU-1'},
        );

        try {
          throw StateError('checkout failed');
        } catch (e, st) {
          client.captureException(e, st);
        }
      }, zoneSpecification: buildLogZoneSpec());

      expect(client.pendingExceptions, hasLength(1));
      expect(client.pendingRecordings, hasLength(1));

      final recording = client.pendingRecordings.single;
      final actionTypes = recording.actions.map((e) => e.type).toList();

      expect(
          recording.logs.map((e) => e.message).toList(), ['user tapped pay']);
      expect(actionTypes, containsAll(['network', 'navigation', 'custom']));

      final network = recording.actions.whereType<NetworkEvent>().single;
      expect(network.method, 'GET');
      expect(network.statusCode, 200);
      expect(network.url, '$baseUri/checkout');

      final nav = recording.actions.whereType<NavigationEvent>().single;
      expect(nav.action, 'push');
      expect(nav.to, '/cart');

      final custom = recording.actions.whereType<CustomEvent>().single;
      expect(custom.category, 'cart');
      expect(custom.name, 'add_item');
      expect(custom.data, {'sku': 'SKU-1'});

      final timestamps = recording.actions.map((e) => e.timestamp).toList();
      final sorted = [...timestamps]..sort();
      expect(timestamps, sorted);

      // startedAt/endedAt must bracket every recorded event so the backend
      // can compute offsets into the (eventually attached) video timeline.
      expect(recording.startedAt, isNotNull);
      expect(recording.endedAt, isNotNull);
      final allTimestamps = [
        ...recording.logs.map((e) => e.timestamp),
        ...recording.actions.map((e) => e.timestamp),
      ];
      for (final ts in allTimestamps) {
        expect(
          !ts.isBefore(recording.startedAt!) &&
              !ts.isAfter(recording.endedAt!),
          isTrue,
          reason: 'event $ts outside [${recording.startedAt}, ${recording.endedAt}]',
        );
      }
    });

    test('events older than the window are not snapshotted', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(eventsWindow: Duration(milliseconds: 100)),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);

      await runZoned(() async {
        // ignore: avoid_print
        print('older-than-window');
        // Wait past the window before capturing.
        await Future.delayed(const Duration(milliseconds: 200));
        // ignore: avoid_print
        print('within-window');

        try {
          throw StateError('boom');
        } catch (e, st) {
          client.captureException(e, st);
        }
      }, zoneSpecification: buildLogZoneSpec());

      final logs =
          client.pendingRecordings.single.logs.map((e) => e.message).toList();
      expect(logs, ['within-window']);
    });

    test('per-channel disable flags suppress only that channel', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(
          captureLogs: true,
          captureNetwork: false,
          captureNavigation: false,
        ),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);
      final observer = TracewayNavigatorObserver();

      await runZoned(() async {
        // ignore: avoid_print
        print('still recorded');
        await http.get(baseUri.replace(path: '/skipped'));
        observer.didPush(_route('/skipped'), _route('/'));
        client.recordAction(category: 'flow', name: 'still_recorded');

        try {
          throw StateError('boom');
        } catch (e, st) {
          client.captureException(e, st);
        }
      }, zoneSpecification: buildLogZoneSpec());

      final recording = client.pendingRecordings.single;
      expect(recording.logs.map((e) => e.message).toList(), ['still recorded']);

      final actionTypes = recording.actions.map((e) => e.type).toSet();
      expect(actionTypes, contains('custom'));
      expect(actionTypes.contains('network'), false);
      expect(actionTypes.contains('navigation'), false);
    });
  });
}
