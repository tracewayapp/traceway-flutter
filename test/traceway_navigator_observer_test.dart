import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/events/traceway_navigator_observer.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

MaterialPageRoute<void> _route(String name) => MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => const SizedBox.shrink(),
    );

void main() {
  group('TracewayNavigatorObserver', () {
    test('records didPush as a push NavigationEvent', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      final obs = TracewayNavigatorObserver();
      obs.didPush(_route('/detail'), _route('/'));

      final e = client.bufferedEvents.whereType<NavigationEvent>().single;
      expect(e.action, 'push');
      expect(e.from, '/');
      expect(e.to, '/detail');
    });

    test('records didPop as a pop NavigationEvent (reversed direction)', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      final obs = TracewayNavigatorObserver();
      obs.didPop(_route('/detail'), _route('/'));

      final e = client.bufferedEvents.whereType<NavigationEvent>().single;
      expect(e.action, 'pop');
      expect(e.from, '/detail');
      expect(e.to, '/');
    });

    test('records didReplace and didRemove', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      final obs = TracewayNavigatorObserver();
      obs.didReplace(oldRoute: _route('/a'), newRoute: _route('/b'));
      obs.didRemove(_route('/c'), _route('/b'));

      final events =
          client.bufferedEvents.whereType<NavigationEvent>().toList();
      expect(events, hasLength(2));
      expect(events[0].action, 'replace');
      expect(events[0].from, '/a');
      expect(events[0].to, '/b');
      expect(events[1].action, 'remove');
      expect(events[1].from, '/c');
      expect(events[1].to, '/b');
    });

    test('falls back to runtimeType when route name is null', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      final obs = TracewayNavigatorObserver();
      final unnamed = MaterialPageRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      obs.didPush(unnamed, null);

      final e = client.bufferedEvents.whereType<NavigationEvent>().single;
      expect(e.action, 'push');
      expect(e.from, isNull);
      expect(e.to, contains('MaterialPageRoute'));
    });

    test('is a no-op when captureNavigation is disabled', () {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureNavigation: false),
      );
      final obs = TracewayNavigatorObserver();
      obs.didPush(_route('/x'), _route('/'));

      expect(client.bufferedEvents.whereType<NavigationEvent>(), isEmpty);
    });
  });
}
