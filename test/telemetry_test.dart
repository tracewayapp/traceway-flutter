import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/endpoints.dart';
import 'package:traceway/src/error_handler.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/opamp/messages.dart';
import 'package:traceway/src/persistence/outbox.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';
import 'package:traceway/src/traceway_telemetry.dart';
import 'package:traceway/src/traceway_widget.dart';

import 'support.dart';

/// Every request the SDK made, with the log records and spans it carried.
class Wire {
  final List<http.Request> requests = [];

  /// Status answered for the external collector; Traceway always says 200.
  int collectorStatus = 200;

  /// Statuses answered to the collector before [collectorStatus], one each.
  final List<int> collectorQueue = [];

  /// How long every answer takes.
  Duration delay = Duration.zero;

  /// Paths of the requests answered so far.
  final List<String> answered = [];

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    answered.add('${request.url.host}${request.url.path}');
    if (request.url.path.endsWith('/opamp')) {
      return http.Response.bytes(
          encodeServerToAgent(heartbeatIntervalSeconds: 300), 200);
    }
    if (request.url.host == 'collector.test') {
      return http.Response(
          '',
          collectorQueue.isNotEmpty
              ? collectorQueue.removeAt(0)
              : collectorStatus);
    }
    return http.Response('{}', 200);
  });

  List<http.Request> to(String host, [String? path]) => [
        for (final r in requests)
          if (r.url.host == host && (path == null || r.url.path == path)) r,
      ];

  List<proto.LogRecord> logs(String host, [String? path]) => [
        for (final r in to(host, path))
          if (r.url.path.endsWith('/logs') || r.url.path.endsWith('/ingest'))
            for (final rl
                in proto.ExportLogsServiceRequest.fromBuffer(otlpBody(r))
                    .resourceLogs)
              for (final sl in rl.scopeLogs) ...sl.logRecords,
      ];

  List<proto.Span> spans(String host, [String? path]) => [
        for (final r in to(host, path))
          if (r.url.path.endsWith('/traces'))
            for (final rs
                in proto.ExportTraceServiceRequest.fromBuffer(otlpBody(r))
                    .resourceSpans)
              for (final ss in rs.scopeSpans) ...ss.spans,
      ];
}

String? attrOf(proto.LogRecord record, String key) {
  for (final a in record.attributes) {
    if (a.key == key) return a.value.stringValue;
  }
  return null;
}

Future<TracewayClient> start(
  Wire wire,
  TracewayOptions options, {
  String? connection = connectionString,
  Directory? dir,
}) =>
    TracewayClient.initializeForTest(
      connection,
      options,
      overrides: TracewayTestOverrides(
        httpClient: wire.client,
        stateDirectory: dir,
        appVitals: false,
      ),
    );

void main() {
  tearDown(TracewayClient.resetForTest);

  test(
      'a captured exception is durable before capture returns and is sent once',
      () async {
    final dir = Directory.systemTemp.createTempSync('traceway_crash');
    addTearDown(() => dir.deleteSync(recursive: true));
    final wire = Wire();
    final client = await start(
        wire, const TracewayOptions(remoteConfig: false, captureMetrics: false),
        dir: dir);
    client.captureUnhandledException(StateError('last error'));
    final saved = dir
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.logs.pb'));
    final record =
        proto.ExportLogsServiceRequest.fromBuffer(saved.readAsBytesSync())
            .resourceLogs
            .single
            .scopeLogs
            .single
            .logRecords
            .single;
    expect(record.eventName, 'exception');
    expect(attrOf(record, 'exception.message'), contains('last error'));
    await client.flush();
    await client.flush();
    expect(wire.logs('traceway.test').where((r) => r.eventName == 'exception'),
        hasLength(1));
    expect(saved.existsSync(), isFalse);
  });

  test('disabled errors are never written to the durable queue', () async {
    final dir = Directory.systemTemp.createTempSync('traceway_sampling');
    addTearDown(() => dir.deleteSync(recursive: true));
    final wire = Wire();
    final client = await start(
        wire, const TracewayOptions(remoteConfig: false, sampleRate: 0),
        dir: dir);
    client.captureUnhandledException(StateError('filtered'));
    expect(dir.listSync(recursive: true).where((f) => f.path.endsWith('.pb')),
        isEmpty);
    await client.flush();
    expect(wire.logs('traceway.test').where((r) => r.eventName == 'exception'),
        isEmpty);
  });

  test('the project identity scopes buffered records and the saved session',
      () async {
    final dir = Directory.systemTemp.createTempSync('traceway_project');
    addTearDown(() => dir.deleteSync(recursive: true));
    const options = TracewayOptions(remoteConfig: false);
    final first = await start(Wire(), options, dir: dir);
    final previousSession = first.currentSessionId;
    first.recordLog('first project breadcrumb');
    await first.shutdown();
    final nextWire = Wire();
    final second = await start(nextWire, options,
        connection: 'next@https://traceway.test', dir: dir);
    expect(second.currentSessionId, isNot(previousSession));
    second.captureException(StateError('second project'));
    await second.flush();
    expect(nextWire.logs('traceway.test').map((r) => r.body.stringValue),
        isNot(contains('first project breadcrumb')));
  });

  test(
      'collector identity includes tenant headers and canonicalizes their order and names',
      () {
    const url = 'https://collector.test/v1/logs';
    const current = OtlpDestination(
        url, {'Authorization': 'one', 'X-Tenant': 'a'},
        external: true);
    expect(
        current.key,
        const OtlpDestination(url, {'x-tenant': 'a', 'authorization': 'one'},
                external: true)
            .key);
    expect(
        current.key,
        isNot(const OtlpDestination(
                url, {'Authorization': 'one', 'X-Tenant': 'b'},
                external: true)
            .key));
  });

  group('TelemetryRoutes', () {
    final traceway = resolveEndpoints('https://traceway.test/api/report');

    test('without telemetry every signal goes to Traceway with the token', () {
      final routes = TelemetryRoutes.resolve(traceway, 'tok', null);
      expect(routes.logs.url, 'https://traceway.test/api/otel/v1/logs');
      expect(routes.traces.url, 'https://traceway.test/api/otel/v1/traces');
      expect(routes.metrics.url, 'https://traceway.test/api/otel/v1/metrics');
      expect(routes.logs.headers, {'Authorization': 'Bearer tok'});
      expect(routes.splitsLogs, isFalse);
      expect(routes.isOwn('https://traceway.test/api/otel/v1/logs'), isFalse,
          reason: 'Traceway requests are recognised by TracewayEndpoints');
    });

    test('a base url appends the signal paths and never sends the token', () {
      final routes = TelemetryRoutes.resolve(
        traceway,
        'tok',
        const TracewayTelemetry(
          url: 'https://collector.test/otlp/',
          headers: {'x-key': 'k'},
        ),
      );
      expect(routes.logs.url, 'https://collector.test/otlp/v1/logs');
      expect(routes.traces.url, 'https://collector.test/otlp/v1/traces');
      expect(routes.metrics.url, 'https://collector.test/otlp/v1/metrics');
      for (final d in [routes.logs, routes.traces, routes.metrics]) {
        expect(d.headers, {'x-key': 'k'});
        expect(d.external, isTrue);
      }
      expect(routes.splitsLogs, isTrue);
      expect(routes.traceway!.headers, {'Authorization': 'Bearer tok'});
      expect(routes.isOwn('https://collector.test/otlp/v1/traces'), isTrue);
      expect(routes.isOwn('https://api.example.com/cart'), isFalse);
    });

    test('a signal endpoint is used as given and overrides headers', () {
      final routes = TelemetryRoutes.resolve(
        traceway,
        'tok',
        const TracewayTelemetry(
          headers: {'x-key': 'shared', 'x-team': 'app'},
          metrics: TracewayTelemetryEndpoint(
            url: 'https://metrics.test/ingest',
            headers: {'x-key': 'metrics'},
          ),
        ),
      );
      expect(routes.metrics.url, 'https://metrics.test/ingest');
      expect(routes.metrics.headers, {'x-key': 'metrics', 'x-team': 'app'});
      // Signals without a destination stay on Traceway.
      expect(routes.logs.url, 'https://traceway.test/api/otel/v1/logs');
      expect(routes.traces.external, isFalse);
      expect(routes.splitsLogs, isFalse);
    });

    test('rejects URLs that are not plain HTTP(S)', () {
      for (final url in [
        'ftp://collector.test',
        'https://user:pw@collector.test',
        'https://collector.test/?key=1',
        'https://collector.test/#x',
        'collector.test',
      ]) {
        expect(
          () => TelemetryRoutes.resolve(
              traceway, 'tok', TracewayTelemetry(url: url)),
          throwsArgumentError,
          reason: url,
        );
      }
    });

    test('standalone needs a destination for every signal', () {
      expect(
        () => TelemetryRoutes.resolve(
          null,
          null,
          const TracewayTelemetry(
            logs: TracewayTelemetryEndpoint(url: 'https://c.test/v1/logs'),
          ),
        ),
        throwsArgumentError,
      );
      final routes = TelemetryRoutes.resolve(
          null, null, const TracewayTelemetry(url: 'https://c.test'));
      expect(routes.traceway, isNull);
      expect(routes.splitsLogs, isFalse);
      expect(routes.logs.headers, isEmpty);
    });
  });

  test('splitLogsRequest keeps issues and control records for Traceway', () {
    proto.LogRecord record(String name) => proto.LogRecord(eventName: name);
    final request = proto.ExportLogsServiceRequest(resourceLogs: [
      proto.ResourceLogs(scopeLogs: [
        proto.ScopeLogs(logRecords: [
          record('exception'),
          record(''),
          record('session.start'),
          record('checkout_failed'),
          record('traceway.message'),
        ]),
      ]),
    ]);
    final (own, rest) = splitLogsRequest(request.writeToBuffer());
    List<String> names(List<int>? body) => [
          for (final rl
              in proto.ExportLogsServiceRequest.fromBuffer(body!).resourceLogs)
            for (final sl in rl.scopeLogs)
              for (final r in sl.logRecords) r.eventName,
        ];
    expect(names(own), ['exception', 'session.start', 'traceway.message']);
    expect(names(rest), ['', 'checkout_failed']);
    final (none, all) = splitLogsRequest(proto.ExportLogsServiceRequest(
      resourceLogs: [
        proto.ResourceLogs(scopeLogs: [
          proto.ScopeLogs(logRecords: [record('')]),
        ]),
      ],
    ).writeToBuffer());
    expect(none, isNull);
    expect(all, isNotNull);
  });

  group('Traceway plus another OpenTelemetry backend', () {
    const options = TracewayOptions(
      remoteConfig: true,
      telemetry: TracewayTelemetry(
        url: 'https://collector.test',
        headers: {'x-api-key': 'collector-key'},
      ),
      collection: {
        'signals': {
          'console': {'mode': 'stream'},
          'custom': {'mode': 'stream'},
          'network': {'mode': 'stream'},
        },
      },
    );

    test('issues and sessions go to Traceway, the rest to the collector',
        () async {
      final wire = Wire();
      final client = await start(wire, options);
      client.recordLog('hello');
      client.track('checkout_failed', {'reason': 'declined'});
      client.captureException(StateError('boom'));
      client.captureMessage('note');
      client.recordNetworkEvent(NetworkEvent(
        method: 'GET',
        url: 'https://api.example.com/cart',
        duration: const Duration(milliseconds: 30),
        statusCode: 200,
      ));
      client.recordCount('cart.add');
      await client.flush();
      await client.shutdown();

      final collectorLogs = wire.logs('collector.test', '/v1/logs');
      final tracewayLogs = wire.logs('traceway.test', '/api/otel/v1/logs');
      expect(collectorLogs.map((r) => r.eventName),
          unorderedEquals(['', 'checkout_failed']));
      expect(collectorLogs.map((r) => r.body.stringValue), contains('hello'));
      final tracewayNames = tracewayLogs.map((r) => r.eventName).toSet();
      expect(tracewayNames,
          containsAll(['exception', 'traceway.message', 'session.start']));
      expect(tracewayNames.intersection({'', 'checkout_failed'}), isEmpty);
      // One session id correlates both sides.
      final session = attrOf(tracewayLogs.first, 'session.id');
      expect(session, isNotNull);
      expect(collectorLogs.map((r) => attrOf(r, 'session.id')),
          everyElement(session));

      expect(wire.spans('collector.test', '/v1/traces').single.name, 'GET');
      expect(wire.to('traceway.test', '/api/otel/v1/traces'), isEmpty);
      expect(wire.to('collector.test', '/v1/metrics'), isNotEmpty);
      expect(wire.to('traceway.test', '/api/otel/v1/metrics'), isEmpty);
      // OpAMP stays on Traceway.
      expect(wire.to('traceway.test', '/api/otel/v1/opamp'), isNotEmpty);

      for (final r in wire.to('collector.test')) {
        expect(r.headers['x-api-key'], 'collector-key');
        expect(r.headers.containsKey('Authorization'), isFalse);
        expect(r.headers.containsKey('authorization'), isFalse);
      }
      for (final r in wire.to('traceway.test')) {
        expect(r.headers['Authorization'], 'Bearer test-token');
      }
    });

    test('requests to the collector are not recorded as network telemetry',
        () async {
      final wire = Wire();
      final client = await start(wire, options);
      client.recordNetworkEvent(NetworkEvent(
        method: 'POST',
        url: 'https://collector.test/v1/logs',
        duration: Duration.zero,
        statusCode: 200,
      ));
      await client.flush();
      expect(wire.spans('collector.test'), isEmpty);
    });

    test('a failed collector batch waits in its own outbox, never Traceway\'s',
        () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final wire = Wire()..collectorStatus = 503;
      final client = await start(wire, options, dir: dir);
      client.recordLog('queued for the collector');
      await client.flush();
      final outboxes = dir
          .listSync()
          .whereType<Directory>()
          .where((d) =>
              d.path.split(Platform.pathSeparator).last.startsWith('outbox'))
          .toList();
      final external = outboxes.where((d) => d.path.contains('outbox-'));
      expect(external, hasLength(1));
      expect(
          external.single.listSync().where((f) => f.path.endsWith('.logs.pb')),
          isNotEmpty);
      final tracewayDir = Directory('${dir.path}/outbox');
      expect(
          tracewayDir.existsSync()
              ? tracewayDir.listSync().where((f) => f.path.endsWith('.pb'))
              : const [],
          isEmpty);

      // The collector recovers: the queued batch goes there.
      wire.collectorStatus = 200;
      wire.requests.clear();
      await client.flush();
      expect(
          wire
              .logs('collector.test', '/v1/logs')
              .map((r) => r.body.stringValue),
          contains('queued for the collector'));
      expect(wire.logs('traceway.test').map((r) => r.body.stringValue),
          isNot(contains('queued for the collector')));
    });

    test('what an earlier run queued for Traceway still goes to Traceway',
        () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      // A batch the last run could not deliver to Traceway.
      final queued = Directory('${dir.path}/outbox')..createSync();
      File('${queued.path}/destination').writeAsStringSync(fingerprint(
        'logs=https://traceway.test/api/otel/v1/logs#Bearer test-token|'
        'traces=https://traceway.test/api/otel/v1/traces#Bearer test-token',
      ));
      File('${queued.path}/1-0.logs.pb').writeAsBytesSync(
        proto.ExportLogsServiceRequest(resourceLogs: [
          proto.ResourceLogs(scopeLogs: [
            proto.ScopeLogs(logRecords: [
              proto.LogRecord(
                  body: proto.AnyValue(stringValue: 'queued earlier')),
            ]),
          ]),
        ]).writeToBuffer(),
      );
      final wire = Wire();
      // Only spans move: the live queue is not Traceway's any more.
      final client = await start(
        wire,
        const TracewayOptions(
          remoteConfig: false,
          telemetry: TracewayTelemetry(
            traces: TracewayTelemetryEndpoint(
                url: 'https://collector.test/v1/traces'),
          ),
        ),
        dir: dir,
      );
      await client.flush();
      expect(
          wire
              .logs('traceway.test', '/api/otel/v1/logs')
              .map((r) => r.body.stringValue),
          contains('queued earlier'));
      expect(queued.listSync().where((f) => f.path.endsWith('.pb')), isEmpty);
    });

    test('a buffer restored after a restart is split the same way', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      const buffered = TracewayOptions(
        remoteConfig: false,
        telemetry: TracewayTelemetry(url: 'https://collector.test'),
      );
      var wire = Wire();
      var client = await start(wire, buffered, dir: dir);
      client.recordLog('before the restart');
      await client.flush();
      expect(wire.logs('collector.test'), isEmpty);
      await TracewayClient.resetForTest();

      wire = Wire();
      client = await start(wire, buffered, dir: dir);
      client.captureException(StateError('after the restart'));
      await client.flush();
      expect(wire.logs('collector.test').map((r) => r.body.stringValue),
          contains('before the restart'));
      expect(wire.logs('traceway.test').map((r) => r.eventName),
          contains('exception'));
      expect(wire.logs('traceway.test').map((r) => r.body.stringValue),
          isNot(contains('before the restart')));
    });
  });

  group('standalone', () {
    const options = TracewayOptions(
      screenCapture: true,
      remoteConfig: true,
      telemetry: TracewayTelemetry(url: 'https://collector.test'),
      collection: {
        'signals': {
          'console': {'mode': 'stream'},
        },
      },
    );

    test('everything goes to the collector, nothing to Traceway', () async {
      final wire = Wire();
      final client = await start(wire, options, connection: null);
      client.recordLog('standalone line');
      client.captureException(StateError('standalone error'));
      client.recordCount('cart.add');
      await client.flush();
      await client.shutdown();

      final logs = wire.logs('collector.test', '/v1/logs');
      expect(logs.map((r) => r.eventName), containsAll(['', 'exception']));
      // No Traceway session rows, but a session id for correlation.
      expect(logs.map((r) => r.eventName),
          isNot(anyOf(contains('session.start'), contains('session.end'))));
      expect(attrOf(logs.first, 'session.id'), isNotNull);
      expect(wire.to('collector.test', '/v1/metrics'), isNotEmpty);
      expect(
          wire.requests.where((r) => r.url.host != 'collector.test'), isEmpty,
          reason: 'no OpAMP, no recordings, no Traceway OTLP');
      expect(client.recordsScreen, isFalse);
    });

    test('needs a destination for every signal', () async {
      expect(
        () => TracewayClient.initializeForTest(
          null,
          const TracewayOptions(),
          overrides: TracewayTestOverrides(httpClient: Wire().client),
        ),
        throwsArgumentError,
      );
    });
  });

  testWidgets('a bad telemetry destination does not keep the app from running',
      (tester) async {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    try {
      Traceway.run(
        options: const TracewayOptions(
          telemetry: TracewayTelemetry(url: 'not a url'),
        ),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('app is up'),
        ),
      );
      await tester.pump();
    } finally {
      FlutterError.onError = previous;
    }
    expect(find.text('app is up'), findsOneWidget);
    expect(reported.single.exception, isArgumentError);
    expect(reported.single.library, 'traceway');
    expect(TracewayClient.instance, isNull);
  });

  group('delivery', () {
    const streamed = TracewayOptions(
      remoteConfig: false,
      exportDelayMs: 50,
      telemetry: TracewayTelemetry(url: 'https://collector.test'),
      collection: {
        'signals': {
          'console': {'mode': 'stream'},
        },
      },
    );

    List<File> queued(Directory dir) => [
          for (final d in dir.listSync().whereType<Directory>())
            ...d
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.pb')),
        ];

    test('flush waits for an export already on its way', () async {
      final wire = Wire();
      // No metrics upload, whose own request would give the log export time
      // to finish anyway.
      final client = await start(
        wire,
        const TracewayOptions(
          remoteConfig: false,
          exportDelayMs: 50,
          captureMetrics: false,
          telemetry: TracewayTelemetry(url: 'https://collector.test'),
          collection: {
            'signals': {
              'console': {'mode': 'stream'},
            },
          },
        ),
      );
      wire.delay = const Duration(milliseconds: 800);
      client.recordLog('in flight');
      // The batch timer hands the record to the exporter, whose request is
      // still running when the app flushes.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(wire.to('collector.test', '/v1/logs'), hasLength(1),
          reason: 'the request is on its way');
      expect(wire.answered, isNot(contains('collector.test/v1/logs')));
      await client.flush();
      expect(wire.answered, contains('collector.test/v1/logs'));
      expect(wire.logs('collector.test').map((r) => r.body.stringValue),
          contains('in flight'));
    });

    test('a passing failure is retried before the batch is queued', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final wire = Wire()..collectorQueue.addAll([503, 429]);
      final client = await start(wire, streamed, dir: dir);
      client.recordLog('retried');
      await client.flush();
      expect(wire.to('collector.test', '/v1/logs'), hasLength(3));
      expect(queued(dir), isEmpty);
    });

    test('a rejected batch is dropped, not queued', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final wire = Wire()..collectorStatus = 400;
      final client = await start(wire, streamed, dir: dir);
      client.recordLog('rejected');
      await client.flush();
      expect(wire.to('collector.test', '/v1/logs'), hasLength(1));
      expect(queued(dir), isEmpty);
    });

    test('requests name the exporter', () async {
      final wire = Wire();
      final client = await start(wire, streamed);
      client.recordLog('agent');
      await client.flush();
      expect(wire.to('collector.test', '/v1/logs').first.headers['User-Agent'],
          startsWith('OTel-OTLP-Exporter-Dart/'));
    });

    test('unmarked batches are discarded on upgrade', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_queue');
      addTearDown(() => dir.deleteSync(recursive: true));
      final queue = Directory('${dir.path}/outbox')..createSync();
      final file = File('${queue.path}/1-0.logs.pb')..writeAsBytesSync([1]);
      final client = await start(
          Wire(), const TracewayOptions(remoteConfig: false),
          dir: dir);
      await client.flush();
      expect(file.existsSync(), isFalse);
    });

    test('a batch a crash left half written is removed', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final queue = Directory('${dir.path}/outbox')..createSync();
      final outbox = Outbox(
        directory: queue,
        destinations: {
          'logs': const OtlpDestination(
              'https://traceway.test/api/otel/v1/logs', {}),
        },
      );
      final partial =
          File('${queue.path}/${outbox.destinationKey}-1-0.logs.pb.tmp')
            ..writeAsBytesSync([1, 2, 3]);
      outbox.claim();
      outbox.dispose();
      expect(partial.existsSync(), isFalse);
    });

    test('a queue for another project\'s token is dropped, not sent', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final queue = Directory('${dir.path}/outbox')..createSync();
      final outbox = Outbox(
        directory: queue,
        destinations: {
          'logs': const OtlpDestination(
              'https://traceway.test/api/otel/v1/logs',
              {'Authorization': 'Bearer other-token'}),
        },
      )..claim();
      outbox.add(
          'logs',
          proto.ExportLogsServiceRequest(resourceLogs: [
            proto.ResourceLogs(scopeLogs: [
              proto.ScopeLogs(logRecords: [
                proto.LogRecord(
                    body: proto.AnyValue(stringValue: 'other project')),
              ]),
            ]),
          ]).writeToBuffer());
      outbox.dispose();
      expect(queue.listSync().where((f) => f.path.endsWith('.pb')), isNotEmpty);

      final wire = Wire();
      final client = await start(
          wire, const TracewayOptions(remoteConfig: false),
          dir: dir);
      await client.flush();
      expect(wire.logs('traceway.test').map((r) => r.body.stringValue),
          isNot(contains('other project')));
      expect(queue.listSync().where((f) => f.path.endsWith('.pb')), isEmpty);
    });

    test('queues of receivers no longer configured are removed', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      final stale = Directory('${dir.path}/outbox-0badc0de')..createSync();
      File('${stale.path}/1-0.logs.pb').writeAsBytesSync([1, 2, 3]);
      await start(Wire(), streamed, dir: dir);
      expect(stale.existsSync(), isFalse);
    });

    test('a buffer saved for Traceway is not sent to a new receiver', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_telemetry');
      addTearDown(() => dir.deleteSync(recursive: true));
      var wire = Wire();
      var client = await start(wire, const TracewayOptions(remoteConfig: false),
          dir: dir);
      client.recordLog('meant for Traceway');
      await client.flush();
      await TracewayClient.resetForTest();

      wire = Wire();
      client = await start(
        wire,
        const TracewayOptions(
          remoteConfig: false,
          telemetry: TracewayTelemetry(url: 'https://collector.test'),
        ),
        dir: dir,
      );
      client.captureException(StateError('after the change'));
      await client.flush();
      final sent = [
        ...wire.logs('collector.test'),
        ...wire.logs('traceway.test'),
      ].map((r) => r.body.stringValue);
      expect(sent, isNot(contains('meant for Traceway')));
      expect(wire.logs('traceway.test').map((r) => r.eventName),
          contains('exception'));
    });

    test('sessions false keeps the session id, without session records',
        () async {
      final wire = Wire();
      final client = await start(
          wire,
          const TracewayOptions(
            remoteConfig: false,
            sessions: false,
            collection: {
              'signals': {
                'console': {'mode': 'stream'},
              },
            },
          ));
      expect(client.currentSessionId, isNotNull);
      client.recordLog('with a session');
      await client.flush();
      await client.shutdown();
      final logs = wire.logs('traceway.test');
      expect(logs.map((r) => r.eventName),
          isNot(anyOf(contains('session.start'), contains('session.end'))));
      final line =
          logs.firstWhere((r) => r.body.stringValue == 'with a session');
      expect(attrOf(line, 'session.id'), isNotNull);
    });
  });

  test('an empty base url counts as unset', () {
    expect(const TracewayTelemetry(url: '').coversAllSignals, isFalse);
    final routes = TelemetryRoutes.resolve(
        resolveEndpoints('https://traceway.test'),
        'tok',
        const TracewayTelemetry(url: ' '));
    expect(routes.logs.external, isFalse);
  });

  test('errors in the app zone still reach the zone around it without the SDK',
      () async {
    final host = <Object>[];
    runZonedGuarded(
      () => runZonedGuarded(
          () => scheduleMicrotask(() => throw StateError('lost?')),
          ErrorHandler().handleZoneError),
      (error, stack) => host.add(error),
    );
    await Future<void>.delayed(Duration.zero);
    expect(host.single, isStateError);
  });

  test('the app\'s own platform error handler keeps running', () {
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    final previousFlutter = FlutterError.onError;
    addTearDown(() {
      dispatcher.onError = previousPlatform;
      FlutterError.onError = previousFlutter;
    });
    final seen = <Object>[];
    dispatcher.onError = (error, stack) {
      seen.add(error);
      return false;
    };
    ErrorHandler().install();
    final handled = dispatcher.onError!(StateError('platform'), StackTrace.current);
    expect(seen.single, isStateError);
    expect(handled, isFalse);
  });
}
