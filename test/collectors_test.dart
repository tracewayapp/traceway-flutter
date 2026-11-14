import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/events/log_capture.dart';
import 'package:traceway/src/events/network_capture.dart';
import 'package:traceway/src/events/traceway_http_client.dart';
import 'package:traceway/src/events/traceway_navigator_observer.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

import 'support.dart';

Route<void> _route(String name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, __, ___) => const SizedBox(),
    );

void main() {
  tearDown(TracewayClient.resetForTest);

  /// Breadcrumbs only leave the device with an error, so each test ends by
  /// capturing one and reading what was flushed with it.
  Future<void> flushWithError(Harness h) async {
    h.client.captureException(StateError('flush'));
    await h.client.flush();
  }

  test('print inside the log zone becomes a console record', () async {
    final h = await startHarness();
    final forwarded = <String>[];
    runZoned(
      () => runZoned(() {
        // ignore: avoid_print
        print('hello from zone');
        // ignore: avoid_print
        print('Traceway: internal debug line');
      }, zoneSpecification: buildLogZoneSpec()),
      zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => forwarded.add(line)),
    );
    await flushWithError(h);
    expect(h.named(null).map((r) => r.body), ['hello from zone']);
    expect(forwarded, ['hello from zone', 'Traceway: internal debug line']);
  });

  test('navigator observer records transitions', () async {
    final h = await startHarness();
    final observer = TracewayNavigatorObserver();
    observer.didPush(_route('/cart'), _route('/'));
    observer.didPop(_route('/cart'), _route('/'));
    await flushWithError(h);
    final nav = h.named('browser.navigation').toList();
    expect(nav.map((r) => attr(r, 'navigation.action')), ['push', 'pop']);
    expect(attr(nav[0], 'navigation.from'), '/');
    expect(attr(nav[0], 'url.full'), '/cart');
    expect(attr(nav[1], 'url.full'), '/');
  });

  test('navigator observer is silent when navigation capture is off',
      () async {
    final h = await startHarness(
        options:
            const TracewayOptions(remoteConfig: false, captureNavigation: false));
    TracewayNavigatorObserver().didPush(_route('/cart'), null);
    await flushWithError(h);
    expect(h.named('browser.navigation'), isEmpty);
  });

  test('TracewayHttpClient records a client span per request', () async {
    final h = await startHarness();
    final client = TracewayHttpClient(MockClient((request) async =>
        http.Response('nope', request.url.path == '/missing' ? 404 : 200)));
    await client.get(Uri.parse('https://api.example.com/ok?q=1'));
    await client.post(Uri.parse('https://api.example.com/missing'), body: 'x');
    await flushWithError(h);

    final spans = h.spans.spans;
    expect(spans.map((s) => s.name), ['GET', 'POST']);
    final ok = spans[0].attributes.toMap();
    expect(ok['url.full']!.value, 'https://api.example.com/ok?q=1');
    expect(ok['http.response.status_code']!.value, 200);
    expect(ok.containsKey('error.type'), isFalse);
    final missing = spans[1].attributes.toMap();
    expect(missing['http.response.status_code']!.value, 404);
    expect(missing['error.type']!.value, '404');
    expect(spans[1].status.name, 'Error');
    expect(spans[0].endTime!.isBefore(spans[0].startTime), isFalse);
  });

  test('HttpOverrides records dart:io requests, including failures',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = request.uri.path == '/boom' ? 500 : 200
        ..write('ok')
        ..close();
    });
    addTearDown(() => server.close(force: true));
    final h = await startHarness();

    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      for (final path in ['/fine', '/boom']) {
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${server.port}$path'));
        await (await request.close()).drain<void>();
      }
      try {
        final request =
            await client.getUrl(Uri.parse('http://127.0.0.1:1/refused'));
        await request.close();
      } catch (_) {}
      client.close(force: true);
    }, TracewayHttpOverrides(null));
    await flushWithError(h);

    final byUrl = {
      for (final s in h.spans.spans)
        Uri.parse(s.attributes.toMap()['url.full']!.value as String).path:
            s.attributes.toMap(),
    };
    expect(byUrl['/fine']!['http.response.status_code']!.value, 200);
    expect(byUrl['/boom']!['http.response.status_code']!.value, 500);
    expect(byUrl['/boom']!['error.type']!.value, '500');
    expect(byUrl['/refused']!.containsKey('error.type'), isTrue);
    expect(byUrl['/refused']!.containsKey('http.response.status_code'), isFalse);
  });
}
