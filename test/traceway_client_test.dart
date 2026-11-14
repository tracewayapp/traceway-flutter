import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

import 'support.dart';

final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

void breadcrumbs(TracewayClient client) {
  client.recordLog('loading cart');
  client.recordNavigationEvent(
      NavigationEvent(action: 'push', from: '/', to: '/cart'));
  client.recordAction(category: 'cart', name: 'add', data: {'sku': 'a1'});
  client.track('checkout_opened', {'items': 2});
  client.recordNetworkEvent(NetworkEvent(
    method: 'GET',
    url: 'https://api.example.com/cart',
    duration: const Duration(milliseconds: 120),
    statusCode: 200,
  ));
}

void main() {
  tearDown(TracewayClient.resetForTest);

  group('ring buffer', () {
    test('breadcrumbs stay on the device until an exception flushes them',
        () async {
      final h = await startHarness();
      breadcrumbs(h.client);
      await h.client.flush();

      expect(h.eventNames, ['session.start']);
      expect(h.spans.spans, isEmpty);
      expect(h.client.bufferedCount, 5);

      h.client.captureException(StateError('boom'), StackTrace.current);
      await h.client.flush();

      expect(h.client.bufferedCount, 0);
      expect(
        h.eventNames,
        containsAll([
          'exception',
          null,
          'browser.navigation',
          'traceway.action',
          'checkout_opened',
          'traceway.trigger.fired',
        ]),
      );
      expect(h.named(null).single.body, 'loading cart');
      expect(attr(h.named('browser.navigation').single, 'url.full'), '/cart');
      expect(attr(h.named('traceway.action').single, 'traceway.action.data'),
          '{"sku":"a1"}');

      final span = h.spans.spans.single;
      expect(span.kind.name, 'client');
      final spanAttrs = span.attributes.toMap();
      expect(spanAttrs['http.request.method']!.value, 'GET');
      expect(spanAttrs['url.full']!.value, 'https://api.example.com/cart');
      expect(spanAttrs['http.response.status_code']!.value, 200);
      expect(spanAttrs['session.id']!.value, matches(_uuid));
    });

    test('the exception record carries what the server needs', () async {
      final h = await startHarness(
          options: const TracewayOptions(remoteConfig: false, version: '1.2.3'));
      h.client.setAttribute('user.id', 'u-42');
      h.client.captureException(
          const FormatException('bad input'), StackTrace.current, {'k': 'v'});
      await h.client.flush();

      final record = h.named('exception').single;
      expect(record.severityNumber!.severityNumber, 17);
      expect(attr(record, 'exception.type'), 'FormatException');
      expect(attr(record, 'exception.message'), contains('bad input'));
      expect(attr(record, 'exception.stacktrace'),
          startsWith('FormatException: '));
      expect(attr(record, 'traceway.exception.id'), matches(_uuid));
      expect(attr(record, 'session.id'), matches(_uuid));
      expect(attr(record, 'traceway.session.started_at'), isA<int>());
      expect(attr(record, 'user.id'), 'u-42');
      expect(attr(record, 'k'), 'v');
      expect(attr(record, 'traceway.replay.status'), 'disabled');

      final start = h.named('session.start').single;
      expect(attr(start, 'session.id'), attr(record, 'session.id'));
    });

    test('messages are sent at once and do not flush the buffer', () async {
      final h = await startHarness();
      h.client.recordLog('kept');
      h.client.captureMessage('hello');
      await h.client.flush();
      final message = h.named('traceway.message').single;
      expect(message.body, 'hello');
      expect(message.severityNumber!.severityNumber, 9);
      expect(h.named(null), isEmpty);
      expect(h.client.bufferedCount, 1);
    });

    test('repeated identical errors collapse and are counted', () async {
      final h = await startHarness();
      for (var i = 0; i < 3; i++) {
        h.client.captureException(StateError('same'));
      }
      h.client.captureException(StateError('other'));
      await h.client.flush();
      final errors = h.named('exception').toList();
      expect(errors, hasLength(2));
      expect(attr(errors[1], 'traceway.error.suppressed_count'), 2);
    });

    test('sampleRate 0 drops errors', () async {
      final h = await startHarness(
          options: const TracewayOptions(remoteConfig: false, sampleRate: 0));
      h.client.captureException(StateError('x'));
      h.client.captureMessage('y');
      await h.client.flush();
      expect(h.named('exception'), isEmpty);
      expect(h.named('traceway.message'), isEmpty);
    });

    test('capture flags are ceilings', () async {
      final h = await startHarness(
        options: const TracewayOptions(
          remoteConfig: false,
          captureLogs: false,
          captureNetwork: false,
          captureNavigation: false,
        ),
      );
      breadcrumbs(h.client);
      expect(h.client.bufferedCount, 2); // the action and the tracked event
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      expect(h.named(null), isEmpty);
      expect(h.named('browser.navigation'), isEmpty);
      expect(h.spans.spans, isEmpty);
    });

    test('the SDK own requests are not recorded as network telemetry',
        () async {
      final h = await startHarness();
      h.client.recordNetworkEvent(NetworkEvent(
        method: 'POST',
        url: 'https://traceway.test/api/otel/v1/logs',
        duration: Duration.zero,
        statusCode: 200,
      ));
      h.client.recordNetworkEvent(NetworkEvent(
        method: 'POST',
        url: 'https://traceway.test/api/recordings',
        duration: Duration.zero,
        statusCode: 200,
      ));
      expect(h.client.bufferedCount, 0);
    });

    test('baseline-sampled sessions stream their breadcrumbs', () async {
      final h = await startHarness(
          options:
              const TracewayOptions(remoteConfig: false, baselineSampleRate: 1));
      h.client.recordLog('streamed');
      await h.client.flush();
      expect(h.named(null).single.body, 'streamed');
      expect(h.client.bufferedCount, 0);
    });
  });

  group('session replay', () {
    const withReplay = TracewayOptions(remoteConfig: false, screenCapture: true);

    test('a clip is uploaded only for an exception, linked by its id',
        () async {
      final h = await startHarness(options: withReplay);
      final source = FakeReplaySource();
      h.client.replaySource = source;
      expect(source.running, isTrue);

      breadcrumbs(h.client);
      h.client.captureMessage('not an error');
      await h.client.flush();
      expect(source.captures, isEmpty);
      expect(h.requestsTo('/api/recordings'), isEmpty);

      h.client.captureException(StateError('boom'), StackTrace.current);
      await h.client.flush();

      final record = h.named('exception').single;
      final exceptionId = attr(record, 'traceway.exception.id');
      expect(attr(record, 'traceway.replay.status'), 'requested');
      expect(source.captures.single.exceptionId, exceptionId);

      final request = h.requestsTo('/api/recordings').single;
      expect(request.headers['Authorization'], 'Bearer test-token');
      expect(request.headers['Content-Encoding'], 'gzip');
      final segment =
          (h.recordingBodies.single['segments'] as List).single as Map;
      expect(segment['exceptionId'], exceptionId);
      expect(segment['sessionId'], attr(record, 'session.id'));
      expect(segment['segmentIndex'], 0);
      final event = (segment['events'] as List).single as Map;
      expect(event['type'], 'flutter_video');
      expect(event['format'], 'mp4');
      expect(segment['startedAt'], isNotNull);
      expect(segment['endedAt'], isNotNull);
    });

    test('the lookback never exceeds what a trigger or the buffer allows',
        () async {
      final h = await startHarness(options: withReplay);
      final source = FakeReplaySource();
      h.client.replaySource = source;
      final before = DateTime.now();
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      final since = source.captures.single.since!;
      // The default clip asks for 30 s; the recorder's 150-frame ring buffer
      // is what actually bounds it.
      expect(before.difference(since).inSeconds,
          lessThanOrEqualTo(defaultReplayLookbackSeconds.toInt()));
    });

    test('a second error inside the cooldown gets breadcrumbs but no clip',
        () async {
      final h = await startHarness(options: withReplay);
      final source = FakeReplaySource();
      h.client.replaySource = source;
      h.client.captureException(StateError('first'));
      h.client.recordLog('between');
      h.client.captureException(StateError('second'));
      await h.client.flush();
      expect(source.captures, hasLength(1));
      expect(h.requestsTo('/api/recordings'), hasLength(1));
      final second = h.named('exception').last;
      expect(attr(second, 'traceway.replay.status'), 'cooldown');
      expect(h.named(null).single.body, 'between');
    });

    test('without screenCapture nothing is recorded or uploaded', () async {
      final h = await startHarness();
      final source = FakeReplaySource();
      h.client.replaySource = source;
      expect(source.running, isFalse);
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      expect(source.captures, isEmpty);
      expect(h.requestsTo('/api/recordings'), isEmpty);
    });

    test('an empty frame buffer uploads nothing', () async {
      final h = await startHarness(options: withReplay);
      h.client.replaySource = FakeReplaySource()..empty = true;
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      expect(h.requestsTo('/api/recordings'), isEmpty);
    });

    test('remote stream settings and stream actions never upload replay',
        () async {
      var polls = 0;
      final h = await startHarness(
        options: const TracewayOptions(screenCapture: true),
        handler: (request) async {
          if (!request.url.path.endsWith('/opamp')) return null;
          return polls++ == 0
              ? opampConfig({
                  'schemaVersion': 1,
                  'signals': {
                    'console': {'mode': 'stream'},
                    'custom': {'mode': 'stream'},
                  },
                  'replay': {'mode': 'stream', 'sessionSampleRate': 1},
                  'triggers': [
                    {
                      'id': 'start-replay',
                      'steps': [
                        {
                          'match': {
                            'key': 'event.name',
                            'op': 'eq',
                            'value': 'go'
                          }
                        }
                      ],
                      'actions': [
                        {'type': 'startReplay', 'durationSeconds': 60},
                        {
                          'type': 'stream',
                          'durationSeconds': 60,
                          'replay': true
                        },
                        {
                          'type': 'capture',
                          'durationSeconds': 60,
                          'replay': true
                        },
                        {
                          'type': 'flush',
                          'lookbackSeconds': 600,
                          'replay': true
                        },
                      ],
                    }
                  ],
                }, [1])
              : null;
        },
      );
      final source = FakeReplaySource();
      h.client.replaySource = source;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(h.client.settings.signals['console']!.mode, Mode.stream);
      expect(h.client.settings.replayMode, Mode.buffer);
      expect(h.client.replay.mode, Mode.buffer);

      h.client.recordLog('streamed now');
      h.client.track('go');
      await h.client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await h.client.flush();

      expect(h.named(null).map((r) => r.body), contains('streamed now'));
      expect(h.named('traceway.trigger.fired'), isNotEmpty);
      expect(source.captures, isEmpty);
      expect(h.requestsTo('/api/recordings'), isEmpty);
    });

    test('replay switched off remotely stops the recorder and drops frames',
        () async {
      var polls = 0;
      final h = await startHarness(
        options: const TracewayOptions(screenCapture: true),
        handler: (request) async =>
            request.url.path.endsWith('/opamp') && polls++ == 0
                ? opampConfig({
                    'replay': {'mode': 'off'}
                  }, [2])
                : null,
      );
      final source = FakeReplaySource();
      h.client.replaySource = source;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(source.running, isFalse);
      expect(source.clears, greaterThan(0));
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      expect(source.captures, isEmpty);
      expect(attr(h.named('exception').single, 'traceway.replay.status'),
          'disabled');
    });
  });

  group('remote config', () {
    test('is applied, reported back and cached for the next start', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<http.Response?> handler(http.Request request) async =>
          request.url.path.endsWith('/opamp')
              ? opampConfig({
                  'schemaVersion': 1,
                  'signals': {
                    'custom': {'mode': 'stream'}
                  },
                }, [0xab, 0xcd])
              : null;

      var h = await startHarness(
          options: const TracewayOptions(), handler: handler, stateDirectory: dir);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final instanceId = h.client.getInstanceId();
      expect(instanceId, matches(_uuid));
      expect(instanceId[14], '7');
      expect(h.client.settings.signals['custom']!.mode, Mode.stream);

      h.client.track('streamed');
      await h.client.flush();
      expect(h.named('streamed'), hasLength(1));
      expect(attr(h.named('traceway.config.applied').single,
          'traceway.config.hash'), 'abcd');

      final opamp = h.requestsTo('/opamp');
      expect(opamp.length, greaterThanOrEqualTo(2));
      expect(opamp.first.headers['OpAMP-Instance-UID'], instanceId);
      expect(opamp.first.headers['Authorization'], 'Bearer test-token');
      final first = utf8.decode(opamp.first.bodyBytes, allowMalformed: true);
      expect(first, contains('service.instance.id'));
      expect(first, contains('test-os'));
      expect(first, contains('io.traceway.sdk.buffer/v1'));

      // The next start applies the cached config before the first poll and
      // keeps the same instance id.
      await TracewayClient.resetForTest();
      h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async => request.url.path.endsWith('/opamp')
            ? http.Response('', 503)
            : null,
        stateDirectory: dir,
      );
      expect(h.client.getInstanceId(), instanceId);
      expect(h.client.settings.signals['custom']!.mode, Mode.stream);
    });

    test('an invalid document is rejected and the defaults stay', () async {
      final h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async => request.url.path.endsWith('/opamp')
            ? opampConfig({'schemaVersion': 99}, [7])
            : null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.client.settings.signals['custom']!.mode, Mode.buffer);
      final report = h.requestsTo('/opamp')[1].bodyBytes;
      expect(utf8.decode(report, allowMalformed: true),
          contains('unsupported settings schemaVersion 99'));
    });

    test('a 403 stops polling and leaves collection on the defaults',
        () async {
      final h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async => request.url.path.endsWith('/opamp')
            ? http.Response('', 403)
            : null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await h.client.refreshConfig();
      expect(h.requestsTo('/opamp'), hasLength(1));
      h.client.captureException(StateError('still reported'));
      await h.client.flush();
      expect(h.named('exception'), hasLength(1));
    });

    test('the kill switch stops everything but the poll', () async {
      final h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async => request.url.path.endsWith('/opamp')
            ? opampConfig({'enabled': false}, [5])
            : null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await h.client.flush();
      h.logs.clear();
      h.client.captureException(StateError('x'));
      h.client.recordLog('y');
      await h.client.flush();
      expect(h.logs.records, isEmpty);
      expect(h.client.bufferedCount, 0);
    });

    test('a dashboard capture uploads its lookback and then streams',
        () async {
      var polls = 0;
      final h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async {
          if (!request.url.path.endsWith('/opamp')) return null;
          polls++;
          return polls == 2
              ? opampConfig({
                  'captures': [
                    {
                      'id': 'cap-1',
                      'until': DateTime.now()
                          .add(const Duration(minutes: 5))
                          .toUtc()
                          .toIso8601String(),
                      'lookbackSeconds': 600,
                      'signals': ['*'],
                    }
                  ]
                }, [3])
              : null;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      h.client.recordLog('before capture');
      await h.client.flush();
      expect(h.named(null), isEmpty);

      await h.client.refreshConfig();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      h.client.recordLog('during capture');
      await h.client.flush();
      expect(h.named(null).map((r) => r.body),
          ['before capture', 'during capture']);
      expect(attr(h.named(null).last, 'traceway.capture.ids'), '["cap-1"]');
    });
  });

  group('lifecycle', () {
    test('initialize returns the running client', () async {
      final h = await startHarness();
      final again = TracewayClient.initialize(
          connectionString, const TracewayOptions(remoteConfig: false));
      expect(again, same(h.client));
    });

    test('shutdown ends the session and allows a fresh start', () async {
      final h = await startHarness();
      await h.client.shutdown();
      expect(h.eventNames, containsAllInOrder(['session.start', 'session.end']));
      expect(TracewayClient.instance, isNull);
      h.client.captureException(StateError('after shutdown'));
    });
  });
}
