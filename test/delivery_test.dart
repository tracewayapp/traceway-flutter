import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/control_state.dart';
import 'package:traceway/src/core/endpoints.dart';
import 'package:traceway/src/core/merge.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/src/otel/router.dart' show canExportLog;
import 'package:traceway/src/persistence/outbox.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

import 'support.dart';

const _logs = OtlpDestination('https://traceway.test/api/otel/v1/logs', {});

class _Queue {
  _Queue(this.outbox, this.sent);

  final Outbox outbox;

  /// The batches posted, by their text, in order.
  final List<String> sent;

  void add(String batch) => outbox.add('logs', utf8.encode(batch));

  /// The batches still on disk.
  List<String> get left => [
        for (final file in outbox.directory!.listSync().whereType<File>())
          if (file.path.endsWith('.pb')) utf8.decode(file.readAsBytesSync()),
      ];
}

/// An outbox in a directory of its own, whose requests [respond] answers by
/// the text of the batch; 0 is no answer at all.
_Queue _queue(FutureOr<int> Function(String batch) respond) {
  final dir = Directory.systemTemp.createTempSync('traceway_delivery');
  addTearDown(() => dir.deleteSync(recursive: true));
  final sent = <String>[];
  final outbox = Outbox(
    directory: dir,
    destinations: {'logs': _logs},
    httpClient: MockClient((request) async {
      final batch = utf8.decode(otlpBody(request));
      sent.add(batch);
      final status = await respond(batch);
      if (status == 0) throw const SocketException('offline');
      return http.Response('', status);
    }),
  )..claim();
  addTearDown(outbox.dispose);
  return _Queue(outbox, sent);
}

ReadableLogRecord _record(String? eventName) => SDKLogRecord(
      instrumentationScope: OTel.instrumentationScope(name: 'test'),
      eventName: eventName,
      body: eventName ?? 'console line',
    );

const _traces =
    OtlpDestination('https://traceway.test/api/otel/v1/traces', {});

/// An outbox for logs and traces whose stored batches [control] gates as
/// the client does, and the requests it posted.
(Outbox, List<http.Request>) _gated(ControlState control) {
  final dir = Directory.systemTemp.createTempSync('traceway_delivery');
  addTearDown(() => dir.deleteSync(recursive: true));
  final requests = <http.Request>[];
  final outbox = Outbox(
    directory: dir,
    destinations: {'logs': _logs, 'traces': _traces},
    httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response('', 200);
    }),
    admitLog: (eventName) => canExportLog(control, eventName),
    admitSpans: () => control.canExport('network'),
  )..claim();
  addTearDown(outbox.dispose);
  return (outbox, requests);
}

/// A stored logs batch with a scope for each list of records. A record is
/// named by the `eventName` field, or with an `attr:` prefix by the
/// `event.name` attribute; null is a console line. Its body is its name.
List<int> _storedLogs(List<List<String?>> scopes) =>
    proto.ExportLogsServiceRequest(resourceLogs: [
      proto.ResourceLogs(
        resource: proto.Resource(attributes: [
          proto.KeyValue(
              key: 'service.name', value: proto.AnyValue(stringValue: 'app')),
        ]),
        scopeLogs: [
          for (final (i, names) in scopes.indexed)
            proto.ScopeLogs(
              scope: proto.InstrumentationScope(name: 'scope $i'),
              logRecords: [for (final name in names) _storedRecord(name)],
            ),
        ],
      ),
    ]).writeToBuffer();

proto.LogRecord _storedRecord(String? name) {
  final attribute = name != null && name.startsWith('attr:');
  final eventName = attribute ? name.substring(5) : name;
  return proto.LogRecord(
    eventName: attribute ? null : eventName,
    body: proto.AnyValue(stringValue: name ?? 'console line'),
    attributes: [
      if (attribute)
        proto.KeyValue(
            key: 'event.name', value: proto.AnyValue(stringValue: eventName)),
    ],
  );
}

List<int> _storedSpans() => proto.ExportTraceServiceRequest(resourceSpans: [
      proto.ResourceSpans(scopeSpans: [
        proto.ScopeSpans(spans: [
          proto.Span(
              name: 'GET',
              traceId: List.filled(16, 1),
              spanId: List.filled(8, 2)),
        ]),
      ]),
    ]).writeToBuffer();

/// The bodies of the log records [request] posted, by scope.
List<List<String>> _postedLogs(http.Request request) => [
      for (final resourceLogs in proto.ExportLogsServiceRequest.fromBuffer(
              otlpBody(request))
          .resourceLogs)
        for (final scopeLogs in resourceLogs.scopeLogs)
          [for (final record in scopeLogs.logRecords) record.body.stringValue],
    ];

/// The batches still on disk.
List<File> _stored(Outbox outbox) => [
      for (final file in outbox.directory!.listSync().whereType<File>())
        if (file.path.endsWith('.pb')) file,
    ];

void main() {
  group('outbox', () {
    test('a batch that keeps failing does not hold back the ones after it',
        () async {
      final q = _queue((batch) => batch == 'stuck' ? 500 : 200);
      for (final batch in ['stuck', 'error 1', 'error 2']) {
        q.add(batch);
      }
      await q.outbox.drain();
      // Nothing went through: it could as well be the network.
      expect(q.sent, ['stuck']);
      await q.outbox.drain();
      expect(q.sent, ['stuck', 'error 1', 'error 2', 'stuck']);
      expect(q.left, ['stuck']);
    });

    test('two batches that keep failing do not hold back a third', () async {
      final q = _queue((batch) => batch.startsWith('stuck') ? 503 : 200);
      for (final batch in ['stuck 1', 'stuck 2', 'error']) {
        q.add(batch);
      }
      for (var i = 0; i < 3; i++) {
        await q.outbox.drain();
      }
      expect(q.sent, ['stuck 1', 'stuck 2', 'error', 'stuck 1', 'stuck 2']);
      expect(q.left, unorderedEquals(['stuck 1', 'stuck 2']));
    });

    test('a batch is given up after ten failures while others go through',
        () async {
      final q = _queue((batch) => batch == 'stuck' ? 500 : 200);
      q.add('stuck');
      // Alone, its failure may be the network's: it does not count.
      await q.outbox.drain();
      for (var i = 0; i < 10; i++) {
        expect(q.left, contains('stuck'));
        q.add('batch $i');
        await q.outbox.drain();
      }
      expect(q.sent.where((batch) => batch == 'stuck'), hasLength(11));
      expect(q.left, isEmpty);
    });

    test('an outage stops every drain at its first batch and drops nothing',
        () async {
      var offline = true;
      final q = _queue((_) => offline ? 0 : 200);
      for (var i = 0; i < 5; i++) {
        q.add('batch $i');
      }
      for (var i = 0; i < 30; i++) {
        await q.outbox.drain();
      }
      expect(q.sent, hasLength(30));
      expect(q.left, hasLength(5));
      offline = false;
      await q.outbox.drain();
      expect(q.sent, hasLength(35));
      expect(q.left, isEmpty);
    });

    test('a batch added while a drain runs is sent before a drain asked for '
        'then completes', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final q = _queue((batch) async {
        if (batch == 'first') {
          started.complete();
          await release.future;
        }
        return 200;
      });
      q.add('first');
      final running = q.outbox.drain();
      await started.future;
      q.add('error');
      final asked = q.outbox.drain();
      release.complete();
      await asked;
      expect(q.sent, ['first', 'error']);
      expect(q.left, isEmpty);
      await running;
    });

    test('a drain asked for while one meets an outage leaves the retry to the '
        'backoff', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final q = _queue((batch) async {
        if (batch == 'first') {
          started.complete();
          await release.future;
        }
        return 0;
      });
      q.add('first');
      final running = q.outbox.drain();
      await started.future;
      q.add('error');
      final asked = q.outbox.drain();
      release.complete();
      await asked;
      await running;
      expect(q.sent, ['first']);
      expect(q.left, unorderedEquals(['first', 'error']));
    });
  });

  group('export gate', () {
    setUp(() async {
      await TracewayClient.resetForTest();
      await OTel.initialize(
        serviceName: 'delivery-test',
        enableMetrics: false,
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(InMemorySpanExporter()),
        logRecordProcessor: SimpleLogRecordProcessor(InMemoryLogExporter()),
      );
    });
    tearDown(TracewayClient.resetForTest);

    test('records queued before a rule or the kill switch turned them off '
        'are not sent', () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final sent = <String>[];
      final exporter = OtlpLogExporter(
        _logs,
        Outbox(directory: null, destinations: const {}),
        MockClient((request) async {
          final body =
              proto.ExportLogsServiceRequest.fromBuffer(otlpBody(request));
          for (final resourceLogs in body.resourceLogs) {
            for (final scopeLogs in resourceLogs.scopeLogs) {
              for (final record in scopeLogs.logRecords) {
                sent.add(record.body.stringValue);
              }
            }
          }
          return http.Response('', 200);
        }),
        admit: (eventName) => canExportLog(control, eventName),
      );
      final queued = [
        _record(eventException),
        _record(eventMessage),
        _record(eventSessionEnd),
        _record(null),
      ];
      await exporter.export(queued);
      expect(sent,
          [eventException, eventMessage, eventSessionEnd, 'console line']);

      sent.clear();
      control.applyRemote(
          parseSettingsDocument('{"signals":{"console":{"mode":"off"}}}'));
      await exporter.export(queued);
      expect(sent, [eventException, eventMessage, eventSessionEnd]);

      sent.clear();
      control.applyRemote(parseSettingsDocument('{"enabled":false}'));
      expect(await exporter.export(queued), ExportResult.success);
      expect(sent, isEmpty);
    });

    test('spans queued before the kill switch are not sent', () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final requests = <http.Request>[];
      final exporter = OtlpSpanExporter(
        const OtlpDestination('https://traceway.test/api/otel/v1/traces', {}),
        Outbox(directory: null, destinations: const {}),
        MockClient((request) async {
          requests.add(request);
          return http.Response('', 200);
        }),
        admit: () => control.canExport('network'),
      );
      final span = OTel.tracerProvider()
          .getTracer('delivery-test')
          .startSpan('GET', root: true)
        ..end();
      await exporter.export([span]);
      expect(requests, hasLength(1));
      control.applyRemote(parseSettingsDocument('{"enabled":false}'));
      await exporter.export([span]);
      expect(requests, hasLength(1));
    });
  });

  group('stored batches', () {
    test('a stored logs batch sends only the records a rule still lets leave',
        () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final (outbox, requests) = _gated(control);
      expect(
          outbox.add(
              'logs',
              _storedLogs([
                [eventException, null, 'attr:$eventMessage'],
                ['attr:browser.console', null],
              ])),
          isTrue);
      control.applyRemote(
          parseSettingsDocument('{"signals":{"console":{"mode":"off"}}}'));
      await outbox.drain();
      expect(_postedLogs(requests.single), [
        [eventException, 'attr:$eventMessage'],
      ]);
      final posted = proto.ExportLogsServiceRequest.fromBuffer(
          otlpBody(requests.single));
      expect(posted.resourceLogs.single.resource.attributes.single.key,
          'service.name');
      expect(posted.resourceLogs.single.scopeLogs.single.scope.name, 'scope 0');
      expect(_stored(outbox), isEmpty);
    });

    test('a stored logs batch with nothing left to send is deleted unsent',
        () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final (outbox, requests) = _gated(control);
      // An issue written before it was sent, and a session's control record.
      outbox.add('logs', _storedLogs([[eventException]]));
      outbox.add('logs', _storedLogs([[eventSessionEnd, null]]));
      control.applyRemote(parseSettingsDocument('{"enabled":false}'));
      await outbox.drain();
      expect(requests, isEmpty);
      expect(_stored(outbox), isEmpty);
    });

    test('a stored traces batch is deleted unsent while network is off',
        () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final (outbox, requests) = _gated(control);
      outbox.add('traces', _storedSpans());
      outbox.add('logs', _storedLogs([[eventException]]));
      control.applyRemote(
          parseSettingsDocument('{"signals":{"network":{"mode":"off"}}}'));
      await outbox.drain();
      expect(requests.map((r) => r.url.path), ['/api/otel/v1/logs']);
      expect(_stored(outbox), isEmpty);
    });

    test('a stored batch the gate lets through whole goes out as stored',
        () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final (outbox, requests) = _gated(control);
      final logs = _storedLogs([
        [eventException, null],
        ['attr:browser.console'],
      ]);
      final spans = _storedSpans();
      outbox.add('logs', logs);
      outbox.add('traces', spans);
      await outbox.drain();
      expect(requests.map((r) => r.url.path),
          ['/api/otel/v1/logs', '/api/otel/v1/traces']);
      expect(otlpBody(requests[0]), logs);
      expect(otlpBody(requests[1]), spans);
      expect(_stored(outbox), isEmpty);
    });

    test('a stored logs batch that does not decode is dropped unsent',
        () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final (outbox, requests) = _gated(control);
      // Says it holds five bytes and has one.
      outbox.add('logs', [0x0a, 0x05, 0x01]);
      outbox.add('logs', _storedLogs([[eventException]]));
      await outbox.drain();
      expect(_postedLogs(requests.single), [
        [eventException],
      ]);
      expect(_stored(outbox), isEmpty);
    });
  });

  group('baseline sampling', () {
    tearDown(TracewayClient.resetForTest);

    test('streams nothing past a plan limit that only lets a signal buffer',
        () async {
      final h = await startHarness(
          options:
              const TracewayOptions(remoteConfig: false, baselineSampleRate: 1));
      h.client.control.applyRemote(parseSettingsDocument(
          '{"limits":{"signals":{"console":"buffer"}}}'));
      expect(h.client.settings.baselineSampleRate, 1);
      h.client.recordLog('kept on the device');
      await h.client.flush();
      expect(h.named(null), isEmpty);
      expect(h.client.bufferedCount, 1);
    });
  });
}
