import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:dartastic_opentelemetry/testing.dart' show InMemoryLogExporter;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/persistence/buffer_persistence.dart';
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

    test('a full buffer is flushed whole, its newest records included',
        () async {
      // More than the batch processors queue (2048): they drop what does
      // not fit, which was the breadcrumbs right before the error, and the
      // error itself where it is not written to disk first.
      final h = await startHarness();
      for (var i = 0; i < 3000; i++) {
        h.client.recordLog('line $i');
      }
      expect(h.client.bufferedCount, 3000);
      h.client.captureException(StateError('boom'), StackTrace.current);
      await h.client.flush();
      expect(h.named(null).map((r) => r.body),
          [for (var i = 0; i < 3000; i++) 'line $i']);
      expect(h.named('exception'), hasLength(1));

      for (var i = 0; i < 2500; i++) {
        h.client.recordNetworkEvent(NetworkEvent(
          method: 'GET',
          url: 'https://api.example.com/$i',
          duration: const Duration(milliseconds: 5),
          statusCode: 200,
        ));
      }
      expect(h.client.bufferedCount, 2500);
      h.client.captureException(StateError('again'), StackTrace.current);
      await h.client.flush();
      expect(h.spans.spans, hasLength(2500));
      expect(h.named('exception'), hasLength(2));
      expect(h.client.bufferedCount, 0);
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
      expect(attr(record, 'traceway.session.started_at'), isNull,
          reason: 'only session events carry the start, as in the browser SDK');
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

    test('an error that is not sampled uploads no breadcrumbs and no clip',
        () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, sampleRate: 0, screenCapture: true));
      final source = FakeReplaySource();
      h.client.replaySource = source;
      breadcrumbs(h.client);
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.named('exception'), isEmpty);
      expect(h.named('traceway.action'), isEmpty);
      expect(h.named('traceway.trigger.fired'), isEmpty);
      expect(source.captures, isEmpty);
      expect(h.client.bufferedCount, greaterThan(0));
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

    test('the buffer survives a restart within the session', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_buffer');
      addTearDown(() => dir.deleteSync(recursive: true));
      var h = await startHarness(stateDirectory: dir);
      final session = h.client.currentSessionId;
      h.client.recordLog('before the restart');
      h.client.recordNetworkEvent(NetworkEvent(
        method: 'GET',
        url: 'https://api.example.com/cart',
        duration: const Duration(milliseconds: 80),
        statusCode: 200,
      ));
      await h.client.flush();
      expect(h.named(null), isEmpty);
      expect(File('${dir.path}/buffer.json').existsSync(), isTrue);

      await TracewayClient.resetForTest();
      h = await startHarness(stateDirectory: dir);
      expect(h.client.currentSessionId, session);
      expect(File('${dir.path}/buffer.json').existsSync(), isFalse);
      h.client.captureException(StateError('after the restart'));
      await h.client.flush();

      final logs = [
        for (final request in h.requestsTo('/api/otel/v1/logs'))
          proto.ExportLogsServiceRequest.fromBuffer(otlpBody(request)),
      ];
      final bodies = [
        for (final request in logs)
          for (final resourceLogs in request.resourceLogs)
            for (final scope in resourceLogs.scopeLogs)
              for (final record in scope.logRecords) record.body.stringValue,
      ];
      expect(bodies, ['before the restart']);
      final resource = logs.single.resourceLogs.single.resource.attributes
          .map((a) => a.key);
      expect(resource, contains('service.instance.id'));
      final spans = [
        for (final request in h.requestsTo('/api/otel/v1/traces'))
          proto.ExportTraceServiceRequest.fromBuffer(otlpBody(request)),
      ];
      expect(spans.single.resourceSpans.single.scopeSpans.single.spans.single.name,
          'GET');
      // Uploaded once: the next flush sends nothing restored again.
      h.client.captureException(StateError('again'));
      await h.client.flush();
      expect(h.requestsTo('/api/otel/v1/logs'), hasLength(1));
    });

    test('restored records keep the version they were recorded with',
        () async {
      final dir = Directory.systemTemp.createTempSync('traceway_buffer');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<Harness> run(String version) => startHarness(
          stateDirectory: dir,
          options: TracewayOptions(remoteConfig: false, version: version));
      var h = await run('1.0.0');
      h.client.recordLog('from 1.0.0');
      await TracewayClient.resetForTest();
      h = await run('2.0.0');
      h.client.recordLog('from 2.0.0');
      await TracewayClient.resetForTest();
      h = await run('3.0.0');
      h.client.captureException(StateError('in 3.0.0'));
      await h.client.flush();
      final request = proto.ExportLogsServiceRequest.fromBuffer(
          otlpBody(h.requestsTo('/api/otel/v1/logs').single));
      final byVersion = {
        for (final resourceLogs in request.resourceLogs)
          resourceLogs.resource.attributes
                  .firstWhere((a) => a.key == 'service.version')
                  .value
                  .stringValue:
              [
            for (final scope in resourceLogs.scopeLogs)
              for (final record in scope.logRecords) record.body.stringValue
          ],
      };
      expect(byVersion, {
        '1.0.0': ['from 1.0.0'],
        '2.0.0': ['from 2.0.0'],
      });
    });

    test('a restored buffer belongs to its session only', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_buffer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = BufferPersistence(dir);
      final h = await startHarness();
      h.client.recordLog('kept');
      await store.save('session-a', h.client.bufferSnapshot);
      final other = BufferPersistence(dir);
      await other.load('session-b', maxAgeMs: 600000, maxBytes: 1 << 20);
      expect(other.restored, isEmpty);
      expect(File('${dir.path}/buffer.json').existsSync(), isFalse);
    });

    test('a large restored buffer is uploaded as several requests', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_buffer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final h = await startHarness();
      for (var i = 0; i < 40; i++) {
        h.client.recordLog('restored line $i ${'x' * 200}');
      }
      await BufferPersistence(dir).save('session-a', h.client.bufferSnapshot);
      final restored = BufferPersistence(dir);
      await restored.load('session-a', maxAgeMs: 600000, maxBytes: 1 << 20);
      expect(restored.restored, hasLength(40));

      final now = DateTime.now().millisecondsSinceEpoch;
      final bodies = restored.take(0, null, now, (_) => true,
          maxBodyBytes: 2000)['logs']!;
      expect(bodies.length, greaterThan(3));
      expect(bodies.every((b) => b.length < 4000), isTrue);
      final lines = [
        for (final body in bodies)
          for (final rl
              in proto.ExportLogsServiceRequest.fromBuffer(body).resourceLogs)
            for (final sl in rl.scopeLogs)
              for (final record in sl.logRecords)
                record.body.stringValue.split(' ')[2],
      ];
      expect(lines, [for (var i = 0; i < 40; i++) '$i']);
      expect(restored.restored, isEmpty);
    });

    test('buffer.persist false keeps nothing on disk', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_buffer');
      addTearDown(() => dir.deleteSync(recursive: true));
      final h = await startHarness(
        stateDirectory: dir,
        options: const TracewayOptions(remoteConfig: false, collection: {
          'buffer': {'persist': false}
        }),
      );
      h.client.recordLog('memory only');
      await h.client.flush();
      expect(File('${dir.path}/buffer.json').existsSync(), isFalse);
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

    test('session events say whether replay may show images', () async {
      Future<Object?> imagesOn(TracewayOptions options) async {
        final h = await startHarness(options: options);
        await h.client.flush();
        final value =
            attr(h.named('session.start').single, 'traceway.replay.images');
        await TracewayClient.resetForTest();
        return value;
      }

      expect(await imagesOn(withReplay), 'wifi');
      expect(
          await imagesOn(const TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              collection: {
                'replay': {'images': 'always'}
              })),
          'always');
      // The option is a ceiling the settings cannot raise.
      expect(
          await imagesOn(const TracewayOptions(
              remoteConfig: false,
              screenCapture: true,
              replayImages: TracewayImagePolicy.off,
              collection: {
                'replay': {'images': 'always'}
              })),
          'off');
      expect(await imagesOn(const TracewayOptions(remoteConfig: false)), 'off');
    });

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
      expect(source.captures.single.clipId, exceptionId);

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

    test('an emit action next to the clip does not mislabel its status',
        () async {
      final h = await startHarness(
        options: const TracewayOptions(
          remoteConfig: false,
          screenCapture: true,
          collection: {
            'triggers': [
              {
                'id': 'default-exception',
                'actions': [
                  {
                    'type': 'flush',
                    'lookbackSeconds': 30,
                    'signals': [],
                    'replay': true
                  },
                  {'type': 'emit', 'eventName': 'clip_requested'},
                ],
                'steps': [
                  {
                    'match': {
                      'key': 'event.name',
                      'op': 'eq',
                      'value': 'exception'
                    }
                  }
                ],
              }
            ],
          },
        ),
      );
      h.client.replaySource = FakeReplaySource();
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      expect(attr(h.named('exception').single, 'traceway.replay.status'),
          'requested');
      expect(h.requestsTo('/api/recordings'), hasLength(1));
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

    test('a trigger that asks for replay streams it, then goes back to buffering',
        () async {
      var polls = 0;
      final h = await startHarness(
        options: const TracewayOptions(screenCapture: true),
        handler: (request) async {
          if (!request.url.path.endsWith('/opamp')) return null;
          return polls++ == 0
              ? opampConfig({
                  'schemaVersion': 1,
                  'triggers': [
                    {
                      'id': 'start-replay',
                      'name': 'Watch checkout',
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
                        {'type': 'startReplay', 'durationSeconds': 1},
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
      expect(h.client.replay.mode, Mode.buffer);

      h.client.track('go');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.client.replay.mode, Mode.stream);
      final fired = h.named('traceway.trigger.fired');
      await h.client.flush();
      final firedRecord = h.named('traceway.trigger.fired').single;
      expect(fired, isNotNull);
      expect(attr(firedRecord, 'traceway.trigger.replay'), 'true');
      expect(jsonDecode(attr(firedRecord, 'traceway.trigger.steps') as String),
          isA<List>());

      // The startReplay window ends: what was recorded leaves as the last
      // segment of the session and recording goes back to buffering.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(h.client.replay.mode, Mode.buffer);
      await h.client.flush();
      final segments = [
        for (final body in h.recordingBodies) ...body['segments'] as List
      ];
      expect(segments, isNotEmpty);
      for (final segment in segments.cast<Map>()) {
        expect(segment['sessionId'], isNotNull);
        expect(segment.containsKey('exceptionId'), isFalse);
      }
    });

    test('a dashboard capture with replay uploads its video lookback, then streams',
        () async {
      var polls = 0;
      final until = DateTime.now().add(const Duration(minutes: 5));
      final h = await startHarness(
        options: const TracewayOptions(screenCapture: true),
        handler: (request) async {
          if (!request.url.path.endsWith('/opamp')) return null;
          polls++;
          return polls == 2
              ? opampConfig({
                  'captures': [
                    {
                      'id': 'cap-video',
                      'until': until.toUtc().toIso8601String(),
                      'lookbackSeconds': 60,
                      'signals': ['*'],
                      'replay': true,
                    }
                  ]
                }, [9])
              : null;
        },
      );
      final source = FakeReplaySource();
      h.client.replaySource = source;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      h.client.recordLog('before capture');
      expect(h.client.replay.mode, Mode.buffer);

      await h.client.refreshConfig();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.client.replay.mode, Mode.stream);
      h.client.recordLog('during capture');
      await h.client.flush();

      expect(h.named(null).map((r) => r.body),
          ['before capture', 'during capture']);
      expect(h.named('traceway.capture.started').map(
          (r) => attr(r, 'traceway.capture.id')), ['cap-video']);
      final lookback = (h.recordingBodies.first['segments'] as List).single as Map;
      expect(lookback['sessionId'], isNotNull);
      expect(lookback['segmentIndex'], 0);
      expect(source.captures.first.until!.difference(source.captures.first.since!).inSeconds,
          60);
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
    test('attribute values are clipped to the bytes the server keeps', () async {
      final h = await startHarness(options: const TracewayOptions());
      h.client.setAttribute('note', 'é' * 600);
      await h.client.refreshConfig();
      final body = h.requestsTo('/opamp').last.bodyBytes;
      bool contains(List<int> needle) {
        for (var i = 0; i + needle.length <= body.length; i++) {
          var j = 0;
          while (j < needle.length && body[i + j] == needle[j]) {
            j++;
          }
          if (j == needle.length) return true;
        }
        return false;
      }

      expect(contains(utf8.encode('é' * 512)), isTrue);
      expect(contains(utf8.encode('é' * 513)), isFalse);
    });

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
      final instanceId = h.client.getInstanceId()!;
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
      // The lookback is marked as the capture's when it goes up.
      expect(h.named(null).map((r) => attr(r, 'traceway.capture.ids')),
          ['["cap-1"]', '["cap-1"]']);
    });
  });

  group('triggers that emit', () {
    Map<String, Object?> emits(String id, String on, String emit) => {
          'id': id,
          'steps': [
            {
              'match': {'key': 'event.name', 'op': 'eq', 'value': on}
            }
          ],
          'actions': [
            {'type': 'emit', 'eventName': emit}
          ],
        };

    test('a rule can answer the event another rule emitted', () async {
      final h = await startHarness(
        options: TracewayOptions(remoteConfig: false, collection: {
          'signals': {
            'custom': {'mode': 'stream'}
          },
          'triggers': [emits('a', 'first', 'second'), emits('b', 'second', 'third')],
        }),
      );
      h.client.track('first');
      await h.client.flush();
      expect(h.named('second'), hasLength(1));
      expect(h.named('third'), hasLength(1));
    });

    test('a rule that emits what it matches stops after a few rounds',
        () async {
      final h = await startHarness(
        options: TracewayOptions(remoteConfig: false, collection: {
          'signals': {
            'custom': {'mode': 'stream'}
          },
          'triggers': [emits('loop', 'loop', 'loop')],
        }),
      );
      h.client.track('loop');
      await h.client.flush();
      expect(h.named('loop'), hasLength(4));
      // The SDK goes on working.
      h.client.track('after');
      await h.client.flush();
      expect(h.named('after'), hasLength(1));
    });
  });

  group('collection health', () {
    test('errors the flood guard holds back are reported, and again later',
        () async {
      final h = await startHarness(collectionHealthDelayMs: 50);
      await h.client.flush();
      for (var i = 0; i < 3; i++) {
        h.client.captureException(StateError('same'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await h.client.flush();
      final health = h.named('traceway.collection.health').single;
      expect(attr(health, 'traceway.error.suppressed_total'), 2);
      expect(attr(health, 'traceway.collection.max_events'), 10000);
      expect(attr(health, 'traceway.collection.dropped'), 0);
      expect(attr(health, 'traceway.replay.failed_segments'), 0);
      expect(attr(health, 'traceway.context.evicted'), 0);
      // The session row learns once that data was dropped.
      expect(h.named('traceway.session.update'), hasLength(1));

      // The next report waits twice as long, and the row is not told again.
      h.client.captureException(StateError('same'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await h.client.flush();
      expect(
          h.named('traceway.collection.health')
              .map((r) => attr(r, 'traceway.error.suppressed_total')),
          [2, 3]);
      expect(h.named('traceway.session.update'), hasLength(1));
    });

    test('session events carry the errors held back so far', () async {
      final h = await startHarness(collectionHealthDelayMs: 50);
      await h.client.flush();
      expect(
          attr(h.named('session.start').single,
              'traceway.error.suppressed_total'),
          0);
      for (var i = 0; i < 3; i++) {
        h.client.captureException(StateError('same'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await h.client.flush();
      expect(
          attr(h.named('traceway.session.update').single,
              'traceway.error.suppressed_total'),
          2);
      await h.client.shutdown();
      expect(
          attr(h.named('session.end').single,
              'traceway.error.suppressed_total'),
          2);
    });

    test('replay segments the server refuses are reported', () async {
      final h = await startHarness(
        options: const TracewayOptions(remoteConfig: false, screenCapture: true),
        collectionHealthDelayMs: 20,
        handler: (request) async => request.url.path.endsWith('/api/recordings')
            ? http.Response('no', 400)
            : null,
      );
      h.client.replaySource = FakeReplaySource();
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await h.client.flush();
      final health = h.named('traceway.collection.health').single;
      expect(attr(health, 'traceway.replay.failed_segments'), 1);
      expect(attr(health, 'traceway.error.suppressed_total'), 0);
    });
  });

  group('lifecycle', () {
    test('initialize returns the running client', () async {
      final h = await startHarness();
      final again = TracewayClient.initialize(
          token: 'test-token',
          baseUrl: 'https://traceway.test',
          options: const TracewayOptions(remoteConfig: false));
      expect(again, same(h.client));
    });

    test('records from before the start keep the session start and errors',
        () async {
      final dir = Directory.systemTemp.createTempSync('traceway_early');
      addTearDown(() => dir.deleteSync(recursive: true));
      final logs = InMemoryLogExporter();
      final starting = TracewayClient.initializeForTest(
        connectionString,
        const TracewayOptions(remoteConfig: false, captureMetrics: false),
        overrides: TracewayTestOverrides(
          logExporter: logs,
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          stateDirectory: dir,
        ),
      );
      TracewayClient? client;
      while ((client = TracewayClient.instance) == null) {
        await Future<void>.delayed(Duration.zero);
      }
      for (var i = 0; i < 600; i++) {
        client!.recordLog('chatty startup line $i');
      }
      client!.captureException(StateError('early'));
      await starting;
      await client.flush();
      final names = logs.records.map((r) => r.eventName).toList();
      expect(names, contains('session.start'));
      expect(names, contains('exception'));
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
