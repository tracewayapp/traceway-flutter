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

  test('navigator observer is silent when navigation capture is off', () async {
    final h = await startHarness(
        options: const TracewayOptions(
            remoteConfig: false, captureNavigation: false));
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

  test('HttpOverrides records dart:io requests, including failures', () async {
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
    expect(
        byUrl['/refused']!.containsKey('http.response.status_code'), isFalse);
  });

  group('trace context propagation', () {
    String hex(Object id) => (id as dynamic).hexString as String;

    test('TracewayHttpClient sends traceparent to selected URLs only',
        () async {
      final h = await startHarness(
        options: TracewayOptions(
          remoteConfig: false,
          propagateTraceHeaderUrls: [
            'https://api.example.com/',
            RegExp(r'^https://[a-z]+\.internal\.test/'),
          ],
        ),
      );
      final seen = <String, String?>{};
      final client = TracewayHttpClient(MockClient((request) async {
        seen[request.url.toString()] = request.headers['traceparent'];
        return http.Response('ok', 200);
      }));
      await client.get(Uri.parse('https://api.example.com/cart'));
      await client.get(Uri.parse('https://billing.internal.test/pay'));
      await client.get(Uri.parse('https://cdn.other.test/logo.png'));
      await client.get(Uri.parse('https://traceway.test/api/otel/v1/logs'));
      await flushWithError(h);

      final header = RegExp(r'^00-([0-9a-f]{32})-([0-9a-f]{16})-01$');
      expect(seen['https://api.example.com/cart'], matches(header));
      expect(seen['https://billing.internal.test/pay'], matches(header));
      expect(seen['https://cdn.other.test/logo.png'], isNull);
      expect(seen['https://traceway.test/api/otel/v1/logs'], isNull,
          reason: 'the SDK\'s own requests never carry it');

      // The recorded span is the one the header names.
      final spans = {
        for (final s in h.spans.spans)
          s.attributes.toMap()['url.full']!.value as String: s,
      };
      for (final url in [
        'https://api.example.com/cart',
        'https://billing.internal.test/pay'
      ]) {
        final match = header.firstMatch(seen[url]!)!;
        final span = spans[url]!;
        expect(hex(span.spanContext.traceId), match.group(1));
        expect(hex(span.spanContext.spanId), match.group(2));
        expect(
            span.attributes.toMap()['http.response.status_code']!.value, 200);
      }
      expect(spans.keys, contains('https://cdn.other.test/logo.png'));
      expect(spans, hasLength(3));
    });

    test('dart:io requests carry it too, failures included', () async {
      final headers = <String, String?>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        headers[request.uri.path] = request.headers.value('traceparent');
        request.response
          ..statusCode = request.uri.path == '/boom' ? 500 : 200
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final h = await startHarness(
        options: TracewayOptions(
          remoteConfig: false,
          propagateTraceHeaderUrls: ['$base/'],
        ),
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        for (final path in ['/fine', '/boom']) {
          final request = await client.getUrl(Uri.parse('$base$path'));
          await (await request.close()).drain<void>();
        }
        client.close(force: true);
      }, TracewayHttpOverrides(null));
      await flushWithError(h);

      for (final path in ['/fine', '/boom']) {
        final value = headers[path];
        expect(value, isNotNull, reason: path);
        final span = h.spans.spans.singleWhere(
            (s) => s.attributes.toMap()['url.full']!.value == '$base$path');
        expect(value, contains(hex(span.spanContext.spanId)));
        expect(value, startsWith('00-${hex(span.spanContext.traceId)}-'));
      }
      final boom = h.spans.spans.singleWhere(
          (s) => s.attributes.toMap()['url.full']!.value == '$base/boom');
      expect(boom.status.name, 'Error');
    });

    test('TracewayHttpClient over dart:io records a request once', () async {
      final headers = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        headers.add(request.headers.value('traceparent'));
        request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final h = await startHarness(
        options: TracewayOptions(
          remoteConfig: false,
          propagateTraceHeaderUrls: ['$base/'],
        ),
      );
      await HttpOverrides.runWithHttpOverrides(() async {
        // The default inner client sits on dart:io, which the overrides
        // also record.
        final client = TracewayHttpClient();
        await client.get(Uri.parse('$base/once'));
        client.close();
      }, TracewayHttpOverrides(null));
      await flushWithError(h);

      final span = h.spans.spans.single;
      expect(span.attributes.toMap()['url.full']!.value, '$base/once');
      expect(headers.single,
          '00-${hex(span.spanContext.traceId)}-${hex(span.spanContext.spanId)}-01');
    });

    test('a traceparent the app set is left alone', () async {
      final h = await startHarness(
        options: TracewayOptions(
          remoteConfig: false,
          propagateTraceHeaderUrls: ['https://api.example.com/'],
        ),
      );
      const own = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
      String? sent;
      final client = TracewayHttpClient(MockClient((request) async {
        sent = request.headers['traceparent'];
        return http.Response('ok', 200);
      }));
      final request =
          http.Request('GET', Uri.parse('https://api.example.com/cart'))
            ..headers['traceparent'] = own;
      await (await client.send(request)).stream.drain<void>();
      await flushWithError(h);
      expect(sent, own);
      expect(h.spans.spans, hasLength(1));
    });

    test('nothing is propagated by default', () async {
      final h = await startHarness();
      String? sent;
      final client = TracewayHttpClient(MockClient((request) async {
        sent = request.headers['traceparent'];
        return http.Response('ok', 200);
      }));
      await client.get(Uri.parse('https://api.example.com/cart'));
      await flushWithError(h);
      expect(sent, isNull);
      expect(h.spans.spans, hasLength(1));
    });
  });
}
