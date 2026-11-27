// The browser SDK's API the Flutter SDK now has too: the static facade,
// ignored errors and beforeCapture, interactions (manual spans), route
// templates and turning device info off.
import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show OTel, SimpleSpanProcessor, SpanStatusCode;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;
import 'package:traceway/traceway.dart';

import 'support.dart';

Future<void> flushWithError(Harness h) async {
  h.client.captureException(StateError('flush'));
  await h.client.flush();
}

List<String> issueMessages(Harness h) => [
      for (final r in h.named(eventException))
        '${attr(r, 'exception.message')}',
      for (final r in h.named(eventMessage)) '${r.body}',
    ];

/// [startHarness] with device attributes of its own.
Future<Harness> startHarnessWithDevice({
  required bool captureDeviceInfo,
  required Map<String, String> device,
}) async {
  final logs = InMemoryLogExporter();
  final spans = InMemorySpanExporter();
  final requests = <http.Request>[];
  final client = await TracewayClient.initializeForTest(
    connectionString,
    TracewayOptions(remoteConfig: false, captureDeviceInfo: captureDeviceInfo),
    overrides: TracewayTestOverrides(
      logExporter: logs,
      spanExporter: spans,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      deviceAttributes: device,
    ),
  );
  return Harness(client, logs, spans, requests);
}

NetworkEvent request(String url) => NetworkEvent(
      method: 'GET',
      url: url,
      statusCode: 200,
      duration: const Duration(milliseconds: 40),
    );

void main() {
  tearDown(TracewayClient.resetForTest);

  group('the Traceway facade', () {
    test('does nothing before the SDK has started', () async {
      expect(TracewayClient.instance, isNull);
      Traceway.captureException(StateError('early'), StackTrace.current);
      Traceway.captureMessage('early');
      Traceway.setAttributes({'a': '1'});
      Traceway.removeAttribute('a');
      Traceway.clearAttributes();
      await Traceway.flush(10);
      await Traceway.refreshConfig();
      await Traceway.shutdown();
      expect(Traceway.getInstanceId(), isNull);
      expect(Traceway.currentSessionId, isNull);
    });

    test('passes through to the running client', () async {
      final h = await startHarness();
      await h.client.flush();
      Traceway.setAttributes({'user.id': 'u1', 'team': 'acme', 'plan': 'pro'});
      Traceway.removeAttribute('team');
      Traceway.captureException(
          StateError('static'), StackTrace.current, {'step': 'pay'});
      Traceway.captureMessage('static message', {'step': 'done'});
      await Traceway.flush(5000);

      final exception = h.named(eventException).single;
      expect(attr(exception, 'exception.message'), 'Bad state: static');
      expect(attr(exception, 'step'), 'pay');
      expect(attr(exception, 'user.id'), 'u1');
      expect(attr(exception, 'plan'), 'pro');
      expect(attr(exception, 'team'), isNull);
      expect(attr(exception, 'exception.stacktrace'), isNotNull);
      final message = h.named(eventMessage).single;
      expect(message.body, 'static message');
      expect(attr(message, 'step'), 'done');

      Traceway.clearAttributes();
      Traceway.captureMessage('after clear');
      await Traceway.flush();
      expect(attr(h.named(eventMessage).last, 'user.id'), isNull);

      expect(Traceway.getInstanceId(), h.client.getInstanceId());
      expect(Traceway.currentSessionId, h.client.currentSessionId);
      expect(Traceway.currentSessionId, isNotNull);
      await Traceway.refreshConfig();
      await Traceway.shutdown();
      expect(TracewayClient.instance, isNull);
      expect(h.named('session.end'), hasLength(1));
    });
  });

  group('ignoreErrors', () {
    test('network failures are ignored by default, bugs are not', () async {
      final h = await startHarness();
      h.client.captureException(
          const SocketException('Failed host lookup: api.shop.test'));
      h.client.captureException(TimeoutException('no answer in 10s'));
      h.client.captureException(
          const HttpException('Connection closed before full header was '
              'received'));
      h.client.captureException(StateError('cart is empty'));
      h.client.captureMessage('Request failed with status code 404');
      h.client.captureMessage('checkout finished');
      await h.client.flush();
      expect(issueMessages(h),
          unorderedEquals(['Bad state: cart is empty', 'checkout finished']));
    });

    test('a list of its own replaces the defaults; an empty one reports all',
        () async {
      var h = await startHarness(
          options: TracewayOptions(
              remoteConfig: false,
              ignoreErrors: ['PaymentDeclined', RegExp(r'^StateError: .*42')]));
      h.client.captureException(const SocketException('offline'));
      h.client.captureException(Exception('PaymentDeclined: card 1'));
      h.client.captureException(StateError('order 42 gone'));
      h.client.captureException(StateError('order 7 gone'));
      await h.client.flush();
      expect(issueMessages(h),
          unorderedEquals(['SocketException: offline', 'Bad state: order 7 gone']));

      await TracewayClient.resetForTest();
      h = await startHarness(
          options: const TracewayOptions(remoteConfig: false, ignoreErrors: []));
      h.client.captureException(const SocketException('offline'));
      await h.client.flush();
      expect(issueMessages(h), ['SocketException: offline']);
    });

    test('only the first line is matched, never the stack', () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, ignoreErrors: ['handleTimeout']));
      h.client.captureException(
          StateError('render failed\ninside handleTimeout'),
          StackTrace.fromString('#0      handleTimeout (package:a/b.dart:1:1)'));
      await h.client.flush();
      expect(issueMessages(h), hasLength(1));
    });
  });

  group('beforeCapture', () {
    test('sees the error, its type, message and attributes, and can drop it',
        () async {
      final seen = <TracewayCapturedError>[];
      final h = await startHarness(
        options: TracewayOptions(
          remoteConfig: false,
          beforeCapture: (captured) {
            seen.add(captured);
            return !captured.message.contains('drop me');
          },
        ),
      );
      final error = StateError('drop me');
      final stack = StackTrace.current;
      h.client.captureException(error, stack, {'order.id': '42'});
      h.client.captureException(StateError('keep me'));
      h.client.captureMessage('drop me too', {'step': 'pay'});
      await h.client.flush();

      expect(issueMessages(h), ['Bad state: keep me']);
      expect(seen, hasLength(3));
      expect(identical(seen[0].error, error), isTrue);
      expect(identical(seen[0].stackTrace, stack), isTrue);
      expect(seen[0].type, 'StateError');
      expect(seen[0].message, 'Bad state: drop me');
      expect(seen[0].isMessage, isFalse);
      expect(seen[0].attributes['order.id'], '42');
      expect(() => seen[0].attributes['x'] = 'y', throwsUnsupportedError);
      expect(seen[2].isMessage, isTrue);
      expect(seen[2].error, isNull);
      expect(seen[2].attributes['step'], 'pay');
    });

    test('one that throws keeps the record', () async {
      final h = await startHarness(
        options: TracewayOptions(
            remoteConfig: false,
            beforeCapture: (_) => throw StateError('bug in the callback')),
      );
      h.client.captureException(StateError('still reported'));
      await h.client.flush();
      expect(issueMessages(h), ['Bad state: still reported']);
    });
  });

  group('interactions', () {
    test('requests and issues inside run join its trace; a failed one is sent '
        'with its exception', () async {
      final h = await startHarness();
      final checkout = Traceway.startInteraction('checkout',
          attributes: {'cart.items': 3});
      expect(checkout.traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(checkout.spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
      await checkout.run(() async {
        await Future<void>.delayed(Duration.zero);
        h.client.recordNetworkEvent(request('https://api.shop.test/orders'));
        Traceway.log('placing the order', level: TracewayLogLevel.warn);
      });
      checkout.setAttribute('payment.method', 'card');
      checkout.captureException(StateError('card declined'));
      checkout.end();
      checkout.end();
      h.client.recordNetworkEvent(request('https://api.shop.test/outside'));
      // The failed interaction went with its exception; the request after it
      // waits in the buffer for the next one.
      await h.client.flush();
      expect(h.spans.spans.where((s) => s.name == 'checkout'), hasLength(1));
      await flushWithError(h);

      final spans = h.spans.spans;
      final interaction = spans.singleWhere((s) => s.name == 'checkout');
      final attrs = interaction.attributes.toMap();
      expect(attrs['traceway.interaction']!.value, isTrue);
      expect(attrs['cart.items']!.value, 3);
      expect(attrs['payment.method']!.value, 'card');
      expect(attrs['session.id']!.value, h.client.currentSessionId);
      expect(interaction.status, SpanStatusCode.Error);
      expect(interaction.spanContext.traceId.hexString, checkout.traceId);

      final inside = spans.singleWhere(
          (s) => s.attributes.toMap()['url.full']?.value ==
              'https://api.shop.test/orders');
      expect(inside.spanContext.traceId.hexString, checkout.traceId);
      expect(inside.parentSpanContext?.spanId.hexString, checkout.spanId);
      final outside = spans.singleWhere(
          (s) => s.attributes.toMap()['url.full']?.value ==
              'https://api.shop.test/outside');
      expect(outside.spanContext.traceId.hexString, isNot(checkout.traceId));

      final declined = h.named(eventException).singleWhere(
          (r) => '${attr(r, 'exception.message')}'.contains('declined'));
      // The exported records are the SDK's, which know their trace.
      expect((declined as dynamic).traceId?.hexString, checkout.traceId);
      expect((declined as dynamic).spanId?.hexString, checkout.spanId);
      final log =
          h.named(null).singleWhere((r) => r.body == 'placing the order');
      expect((log as dynamic).traceId?.hexString, checkout.traceId);
    });

    test('one that succeeds waits in the buffer like other spans', () async {
      final h = await startHarness();
      Traceway.startInteraction('search').end();
      await h.client.flush();
      expect(h.spans.spans.where((s) => s.name == 'search'), isEmpty);
      await flushWithError(h);
      final search = h.spans.spans.singleWhere((s) => s.name == 'search');
      expect(search.status, SpanStatusCode.Ok);
    });

    test('one started inside another is its child', () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, recordAllSessions: true));
      final outer = Traceway.startInteraction('checkout');
      final inner = outer.run(() => Traceway.startInteraction('pay'));
      inner.end();
      outer.end();
      await h.client.flush();
      final pay = h.spans.spans.singleWhere((s) => s.name == 'pay');
      expect(pay.spanContext.traceId.hexString, outer.traceId);
      expect(pay.parentSpanContext?.spanId.hexString, outer.spanId);
    });

    test('without the SDK an interaction records nothing and still runs',
        () async {
      await TracewayClient.resetForTest();
      final idle = Traceway.startInteraction('checkout');
      expect(idle.traceId, isNull);
      expect(idle.run(() => 42), 42);
      idle.captureException(StateError('nowhere to go'));
      idle.end();
      expect(idle.isEnded, isTrue);
    });
  });

  group('tracer', () {
    const streaming = TracewayOptions(
        remoteConfig: false,
        collection: {
          'signals': {
            'network': {'mode': 'stream'}
          }
        });

    test('is null before the SDK starts and after it stops', () async {
      await TracewayClient.resetForTest();
      expect(Traceway.tracer, isNull);
      final h = await startHarness();
      expect(Traceway.tracer, isNotNull);
      expect(Traceway.tracer, same(h.client.tracer));
      await h.client.shutdown();
      expect(Traceway.tracer, isNull);
      expect(h.client.tracer, isNull);
    });

    test(
        'the app\'s spans go through Traceway with the session id, and nest '
        'under the interaction they are made in', () async {
      final h = await startHarness(options: streaming);
      final tracer = Traceway.tracer!;
      tracer.startSpan('load-catalog').end();
      final checkout = Traceway.startInteraction('checkout');
      await checkout.run(() async {
        await Future<void>.delayed(Duration.zero);
        // After an await too: the interaction is the active context.
        tracer.startSpan('price-cart').end();
      });
      checkout.end();
      await h.client.flush();
      final spans = h.spans.spans;
      final own = spans.singleWhere((s) => s.name == 'load-catalog');
      expect(own.attributes.toMap()['session.id']!.value,
          h.client.currentSessionId);
      expect(own.parentSpanContext?.isValid ?? false, isFalse);
      final inner = spans.singleWhere((s) => s.name == 'price-cart');
      expect(inner.spanContext.traceId.hexString, checkout.traceId);
      expect(inner.parentSpanContext?.spanId.hexString, checkout.spanId);
      expect(inner.attributes.toMap()['session.id']!.value,
          h.client.currentSessionId);
    });

    test('is not the app\'s OpenTelemetry, and leaves it alone', () async {
      final h = await startHarness(options: streaming);
      // The app sets its own OpenTelemetry up after Traceway started (the
      // other order is in host_otel_test).
      final hostSpans = InMemorySpanExporter();
      await OTel.initialize(
        serviceName: 'host',
        enableMetrics: false,
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(hostSpans),
      );
      Traceway.tracer!.startSpan('ours').end();
      OTel.tracerProvider()
          .getTracer('host')
          .startSpan('theirs', root: true)
          .end();
      await h.client.flush();
      await Future<void>.delayed(Duration.zero);
      expect(h.spans.spans.map((s) => s.name), contains('ours'));
      expect(h.spans.spans.map((s) => s.name), isNot(contains('theirs')));
      expect(hostSpans.spans.map((s) => s.name), ['theirs']);
      expect(Traceway.tracer, isNot(same(OTel.tracer())));
    });
  });

  group('route templates', () {
    for (final (path, params, expected) in <(String, Map<String, Object?>?, String)>[
      ('/orders/8841', {'id': '8841'}, '/orders/:id'),
      ('/orders/8841/', {'id': '8841'}, '/orders/:id'),
      ('/orders/8841?tab=items#top', {'id': '8841'}, '/orders/:id'),
      ('/', {}, '/'),
      ('/pricing', null, '/pricing'),
      ('/teams/acme/users/42', {'team': 'acme', 'id': '42'},
          '/teams/:team/users/:id'),
      ('/files/a/b/c', {'*': 'a/b/c'}, '/files/*'),
      ('/docs/guides/setup', {'slug': ['guides', 'setup']}, '/docs/:slug*'),
      ('/docs/intro', {'slug': ['intro']}, '/docs/:slug*'),
      ('/search/hello%20world', {'q': 'hello world'}, '/search/:q'),
      ('/search/hello%20world', {'q': 'hello%20world'}, '/search/:q'),
      ('/users/users', {'name': 'users'}, '/users/:name'),
      ('/compare/7/7', {'left': '7', 'right': '7'}, '/compare/:left/:right'),
      ('/orders/8841', {'id': '9999'}, '/orders/8841'),
      ('/orders/8841', {'id': null}, '/orders/8841'),
    ]) {
      test('routeFromParams($path, $params) is $expected', () {
        expect(routeFromParams(path, params), expected);
      });
    }

    test('a navigation with a template names the screen until the next one',
        () async {
      final h = await startHarness();
      Traceway.recordNavigation('/orders/8841', route: '/orders/:id');
      expect(h.client.currentRoute, '/orders/:id');
      h.client.captureException(StateError('order failed'));
      Traceway.recordNavigation('/orders/8841/items');
      expect(h.client.currentRoute, isNull);
      Traceway.setRoute(routeFromParams('/orders/8841/items', {'id': '8841'}));
      expect(h.client.currentRoute, '/orders/:id/items');
      h.client.captureMessage('items shown');
      Traceway.setRoute(null);
      expect(h.client.currentRoute, isNull);
      await h.client.flush();

      final error = h.named(eventException).single;
      expect(attr(error, 'app.screen.name'), '/orders/8841');
      expect(attr(error, 'app.screen.route'), '/orders/:id');
      expect(attr(h.named(eventMessage).single, 'app.screen.route'),
          '/orders/:id/items');
      final navigations = h.named(eventNavigation).toList();
      expect(attr(navigations.first, 'app.screen.route'), '/orders/:id');
      expect(attr(navigations.first, 'url.full'), '/orders/8841');
    });
  });

  group('captureDeviceInfo', () {
    test('off, records carry the operating system and nothing else of the '
        'device', () async {
      final h = await startHarnessWithDevice(
        captureDeviceInfo: false,
        device: const {
          'os.name': 'android',
          'os.version': '14',
          'device.model': 'Pixel 8',
          'device.name': "Ann's phone",
          'device.ip': '192.168.1.20',
          'screen.resolution': '1080x2400',
          'runtime.version': '3.14',
        },
      );
      h.client.captureException(StateError('x'));
      await h.client.flush();
      final resource = ((h.named(eventException).single as dynamic)
              .resource
              .attributes
              .toMap() as Map)
          .keys
          .cast<String>()
          .toSet();
      expect(resource, containsAll(['os.name', 'os.version']));
      expect(
          resource.where((k) =>
              k.startsWith('device.') ||
              k.startsWith('screen.') ||
              k == 'runtime.version'),
          isEmpty);
    });
  });
}
