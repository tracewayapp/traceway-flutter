// Round-2 review (FLT2-*): start-up, debug output and the replay pipeline.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/error_handler.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/src/replay/json_size.dart';
import 'package:traceway/src/replay/recordings_transport.dart';
import 'package:traceway/src/sdk_version.dart';
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;
import 'package:traceway/traceway.dart';

import 'support.dart';

NetworkEvent _request(String url) => NetworkEvent(
      method: 'GET',
      url: url,
      statusCode: 200,
      duration: const Duration(milliseconds: 40),
    );

/// What the SDK prints while [body] runs.
Future<List<String>> _printedBy(Future<void> Function() body) async {
  final lines = <String>[];
  final previous = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  try {
    await body();
  } finally {
    debugPrint = previous;
  }
  return lines;
}

void main() {
  tearDown(TracewayClient.resetForTest);

  group('FLT2-8: an interaction started while the SDK starts', () {
    test('is recorded once it is ready, from when it started, with its child '
        'request span and its exception', () async {
      final gate = Completer<void>();
      final spans = InMemorySpanExporter();
      final logs = InMemoryLogExporter();
      final starting = TracewayClient.initializeForTest(
        connectionString,
        const TracewayOptions(remoteConfig: false, captureMetrics: false),
        overrides: TracewayTestOverrides(
          spanExporter: spans,
          logExporter: logs,
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          startGate: gate.future,
        ),
      );
      while (TracewayClient.instance == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final client = TracewayClient.instance!;
      expect(Traceway.tracer, isNull, reason: 'not ready yet');
      final startedAt = DateTime.now();
      final checkout =
          Traceway.startInteraction('checkout', attributes: {'cart.items': 3});
      expect(checkout.traceId, isNull);
      checkout.run(() => client
          .recordNetworkEvent(_request('https://api.shop.test/orders')));
      checkout.setAttribute('payment.method', 'card');
      checkout.captureException(StateError('card declined'));
      checkout.end();
      expect(checkout.isEnded, isTrue);

      gate.complete();
      await starting;
      await Traceway.ready;
      expect(Traceway.tracer, isNotNull);
      await client.flush();

      final interaction = spans.spans.singleWhere((s) => s.name == 'checkout');
      final attrs = interaction.attributes.toMap();
      expect(attrs['traceway.interaction']!.value, isTrue);
      expect(attrs['cart.items']!.value, 3);
      expect(attrs['payment.method']!.value, 'card');
      expect(checkout.traceId, interaction.spanContext.traceId.hexString);
      expect(interaction.startTime.difference(startedAt).inMilliseconds.abs(),
          lessThan(1000));
      final inside = spans.spans.singleWhere((s) =>
          s.attributes.toMap()['url.full']?.value ==
          'https://api.shop.test/orders');
      expect(inside.parentSpanContext?.spanId.hexString, checkout.spanId);
      final declined = logs.records.singleWhere((r) => r.eventName == eventException);
      expect((declined as dynamic).traceId?.hexString, checkout.traceId);
    });
  });

  group('a metric or a count recorded while the SDK starts', () {
    test('is sent once it is ready', () async {
      final dir = await Directory.systemTemp.createTemp('traceway_early');
      final gate = Completer<void>();
      final requests = <http.Request>[];
      final starting = TracewayClient.initializeForTest(
        connectionString,
        const TracewayOptions(remoteConfig: false),
        overrides: TracewayTestOverrides(
          spanExporter: InMemorySpanExporter(),
          logExporter: InMemoryLogExporter(),
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
          stateDirectory: dir,
          startGate: gate.future,
        ),
      );
      while (TracewayClient.instance == null) {
        await Future<void>.delayed(Duration.zero);
      }
      Traceway.count('launch');
      Traceway.metric('config.load', 42, {'source': 'cache'});
      Traceway.metric('Bad Name', 1);

      gate.complete();
      await starting;
      await Traceway.ready;
      await TracewayClient.instance!.flush();

      final sent = <String>{
        for (final request in requests)
          if (request.url.path.endsWith('/api/otel/v1/metrics'))
            for (final rm in proto.ExportMetricsServiceRequest.fromBuffer(
                    otlpBody(request))
                .resourceMetrics)
              for (final sm in rm.scopeMetrics)
                for (final m in sm.metrics) m.name,
      };
      expect(sent, containsAll(['launch', 'config.load']));
      expect(sent, isNot(contains('Bad Name')));
      await TracewayClient.resetForTest();
      await dir.delete(recursive: true);
    });
  });

  group('the installation id while the SDK starts', () {
    test('is null until it is known, then the id on every record', () async {
      final gate = Completer<void>();
      final logs = InMemoryLogExporter();
      final starting = TracewayClient.initializeForTest(
        connectionString,
        const TracewayOptions(remoteConfig: false, captureMetrics: false),
        overrides: TracewayTestOverrides(
          spanExporter: InMemorySpanExporter(),
          logExporter: logs,
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          startGate: gate.future,
        ),
      );
      while (TracewayClient.instance == null) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(Traceway.getInstanceId(), isNull);
      expect(TracewayClient.instance!.getInstanceId(), isNull);

      gate.complete();
      await starting;
      await Traceway.ready;
      final id = Traceway.getInstanceId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')));
      expect(id, isNot('00000000-0000-0000-0000-000000000000'));
      Traceway.captureMessage('hello');
      await TracewayClient.instance!.flush();
      final record =
          logs.records.firstWhere((r) => r.eventName == eventMessage);
      expect(
          (record as dynamic)
              .resource
              .attributes
              .toMap()['service.instance.id']
              .value,
          id);
    });
  });

  group('FLT2-2: no screen', () {
    test('with debug on, the first exception before any navigation says '
        'how to name screens, once', () async {
      final h = await startHarness(
          options: const TracewayOptions(remoteConfig: false, debug: true));
      final lines = await _printedBy(() async {
        h.client.captureException(StateError('one'));
        h.client.captureException(StateError('two'));
      });
      final hints = lines.where((l) => l.contains('no screen is known yet'));
      expect(hints, hasLength(1));
      expect(hints.single, contains('Traceway.navigatorObserver'));
    });
  });

  group('FLT2-11: debug output says why something was left out', () {
    test('an ignored error, beforeCapture and the sample rate', () async {
      final h = await startHarness(
          options: TracewayOptions(
        remoteConfig: false,
        debug: true,
        beforeCapture: (c) => !c.message.contains('drop me'),
      ));
      final lines = await _printedBy(() async {
        h.client.captureException(const SocketException('offline'));
        h.client.captureException(StateError('drop me'));
        await h.client.flush();
      });
      expect(
          lines,
          contains(allOf(contains('not reported: it matches ignoreErrors'),
              contains('"SocketException"'), contains('ignoreErrors: []'))));
      expect(lines, contains(contains('dropped by beforeCapture')));

      await TracewayClient.resetForTest();
      final sampled = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, debug: true, sampleRate: 0));
      final more = await _printedBy(() async {
        sampled.client.captureException(StateError('unlucky'));
        await sampled.client.flush();
      });
      expect(more, contains(contains('not sampled (sampleRate 0.0)')));
    });
  });

  group('FLT2-13: debug output prints an error once', () {
    test('Flutter\'s own handler prints it: no second dump', () async {
      await startHarness(
          options: const TracewayOptions(remoteConfig: false, debug: true));
      final previousOnError = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      FlutterError.onError = FlutterError.presentError;
      final handler = ErrorHandler()..install();
      final lines = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
      try {
        FlutterError.resetErrorCount();
        FlutterError.reportError(
            FlutterErrorDetails(exception: StateError('printed once')));
      } finally {
        debugPrint = previousPrint;
        FlutterError.onError = previousOnError;
        PlatformDispatcher.instance.onError = previousPlatform;
      }
      expect(handler, isNotNull);
      expect(lines.where((l) => l.contains('EXCEPTION CAUGHT')), hasLength(1));
      expect(lines.where((l) => l.contains('Another exception was thrown')),
          isEmpty);
    });
  });

  group('FLT2-15 / FLT2-16: statics and hang options', () {
    test('Traceway.client is the running client', () async {
      expect(Traceway.client, isNull);
      final h = await startHarness();
      expect(Traceway.client, same(h.client));
      await h.client.shutdown();
    });

    test('appHangThresholdMs and captureAppHangs reach the hang watchdog',
        () async {
      var h = await startHarness();
      expect(h.client.vitals.hangThresholdMs, 2000);
      await TracewayClient.resetForTest();
      h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false,
              appHangThresholdMs: 5000,
              reportHangsInDebug: true));
      expect(h.client.vitals.hangThresholdMs, 5000);
      expect(h.client.vitals.reportHangs, isTrue);
      await TracewayClient.resetForTest();
      h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false,
              captureAppHangs: false,
              reportHangsInDebug: true,
              appHangThresholdMs: 10));
      expect(h.client.vitals.reportHangs, isFalse);
      expect(h.client.vitals.hangThresholdMs, 250);
    });
  });

  group('FLT2-9: clips are not encoded on the UI isolate', () {
    test('the clip size is measured without encoding, close to the JSON', () {
      final picture = base64Encode(List.generate(30000, (i) => i % 251));
      final events = [
        {
          'type': 2,
          'data': {
            'node': {
              'type': 2,
              'tagName': 'style',
              'attributes': {
                '_cssText': '.im.p0{background:url(data:image/jpeg;base64,'
                    '$picture) center/cover no-repeat}'
              },
              'childNodes': [],
              'id': 12,
            },
            'initialOffset': {'left': 0, 'top': 0.5},
          },
          'timestamp': 1764250000000,
        },
        {
          'type': 3,
          'data': {'source': 0, 'texts': [], 'removes': [], 'adds': [], 'flag': true},
          'timestamp': 1764250000100,
        },
        {'type': 5, 'data': null, 'timestamp': -1},
      ];
      final exact = jsonEncode(events).length;
      expect(approxJsonLength(events), exact);
      expect(approxJsonLength({'a': 'quote " inside'}),
          closeTo(jsonEncode({'a': 'quote " inside'}).length, 1));
    });

    test('the recorder does not JSON-encode its clips', () {
      final source =
          File('lib/src/wireframe/wireframe_recorder.dart').readAsStringSync();
      expect(source, isNot(contains('jsonEncode(')));
    });

    test('an upload over 16 KiB is encoded in a background isolate, once for '
        'every attempt', () async {
      final bodies = <List<int>>[];
      var status = 503;
      final transport = RecordingsTransport(
        url: 'https://traceway.test/api/recordings',
        token: 'tok',
        retryDelaysMs: const [1, 1],
        httpClient: MockClient((request) async {
          bodies.add(request.bodyBytes);
          return http.Response('', status);
        }),
      );
      final before = RecordingsTransport.backgroundEncodes;
      final big = 'x' * (40 * 1024);
      transport.send([
        RecordingSegment(sessionId: 's', events: [
          {'type': 5, 'data': big}
        ])
      ]);
      await transport.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      status = 200;
      await transport.flush();
      expect(RecordingsTransport.backgroundEncodes, before + 1);
      expect(bodies.length, greaterThanOrEqualTo(2));
      final decoded = jsonDecode(utf8.decode(gzip.decode(bodies.last))) as Map;
      expect((decoded['segments'] as List).single['events'].single['data'], big);

      // A small one stays where it is sent.
      transport.send([
        RecordingSegment(sessionId: 's', events: [
          {'type': 5, 'data': 'small'}
        ])
      ]);
      await transport.flush();
      expect(RecordingsTransport.backgroundEncodes, before + 1);
    });
  });

  group('FLT2-7 / FLT2-17: version and requirements', () {
    test('both packages, the SDK, and their changelogs agree on the version', () {
      final expected = tracewaySdkVersion;
      for (final dir in ['', 'packages/traceway_video/']) {
        final pubspec = File('${dir}pubspec.yaml').readAsLinesSync();
        expect(pubspec, contains('version: $expected'));
        if (dir.isNotEmpty) expect(pubspec, contains('  traceway: ^$expected'));
        final heading = File('${dir}CHANGELOG.md').readAsLinesSync().first;
        expect(heading, matches(RegExp('^## ${RegExp.escape(expected)} — '
            r'(unreleased|\d{4}-\d{2}-\d{2})$')));
      }
    });

    test('stable preparation accepts the untagged package version and the next',
        () async {
      final sandbox = Directory.systemTemp.createTempSync('traceway_release');
      addTearDown(() => sandbox.deleteSync(recursive: true));
      for (final path in ['pubspec.yaml', 'CHANGELOG.md', 'lib/src/sdk_version.dart',
        'packages/traceway_video/pubspec.yaml', 'packages/traceway_video/CHANGELOG.md']) {
        final target = File('${sandbox.path}/$path');
        target.parent.createSync(recursive: true);
        File(path).copySync(target.path);
      }
      await Process.run('git', ['init', '-q'], workingDirectory: sandbox.path);
      final notes = File('${sandbox.path}/notes')..writeAsStringSync('- release notes\n');
      final prepare = File('tool/prepare_release.sh').absolute.path;
      final current = tracewaySdkVersion;
      for (final version in [current, '99.1.2']) {
        final run = await Process.run('bash', [prepare, version, notes.path],
            workingDirectory: sandbox.path);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        for (final dir in ['', 'packages/traceway_video/']) {
          final base = '${sandbox.path}/$dir';
          final changelog = File('${base}CHANGELOG.md').readAsLinesSync();
          expect(changelog.first, startsWith('## $version — '));
          expect(changelog.first, isNot(contains('unreleased')));
          expect(changelog.where((l) => l.startsWith('## $version — ')), hasLength(1));
          final pubspec = File('${base}pubspec.yaml').readAsLinesSync();
          expect(pubspec, contains('version: $version'));
          if (dir.isNotEmpty) expect(pubspec, contains('  traceway: ^$version'));
        }
        expect(File('${sandbox.path}/lib/src/sdk_version.dart').readAsStringSync(),
            contains("tracewaySdkVersion = '$version';"));
      }
      // A tag may already be present even when the package still says unreleased.
      final blob = await Process.run('git', ['hash-object', '-w', 'notes'],
          workingDirectory: sandbox.path);
      final tagged = await Process.run('git',
          ['update-ref', 'refs/tags/v99.1.2', blob.stdout.toString().trim()],
          workingDirectory: sandbox.path);
      expect(tagged.exitCode, 0);
      final duplicate = await Process.run('bash', [prepare, '99.1.2', notes.path],
          workingDirectory: sandbox.path);
      expect(duplicate.exitCode, isNot(0));
      expect(duplicate.stderr, contains('already exists'));
    });

    test('pub says which Flutter it needs', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains("sdk: '>=3.10.0 <4.0.0'"));
      expect(pubspec, contains("flutter: '>=3.38.1'"));
    });

    test('publish.sh turns the unreleased heading into the release, without '
        'a second heading', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_publish');
      addTearDown(() => dir.deleteSync(recursive: true));
      final changelog = File('${dir.path}/CHANGELOG.md')
        ..writeAsStringSync('## 2.1.0 — unreleased\n\n- a change\n\n## 2.0.0\n');
      final notes = File('${dir.path}/notes')..writeAsStringSync('- noted\n');
      for (final script in ['publish.sh', '.github/workflows/release.yml']) {
        expect(File(script).readAsStringSync(), contains('tool/prepare_release.sh'));
      }
      Future<void> run(String version) async {
        final result = await Process.run('bash',
            [File('tool/update_changelog.sh').absolute.path, version, notes.path],
            workingDirectory: dir.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await run('2.1.0');
      var lines = changelog.readAsLinesSync();
      expect(lines.where((l) => l.startsWith('## 2.1.0')), hasLength(1));
      expect(lines.first, matches(RegExp(r'^## 2\.1\.0 — \d{4}-\d{2}-\d{2}$')));
      expect(lines, containsAll(['- a change', '- noted', '## 2.0.0']));

      // The old heading still works, and a changelog with neither gets one.
      changelog.writeAsStringSync('## Unreleased\n\n- b\n');
      await run('2.1.1');
      lines = changelog.readAsLinesSync();
      expect(lines.first, startsWith('## 2.1.1 — '));
      changelog.writeAsStringSync('## 2.1.1 — 2026-01-01\n\n- c\n');
      await run('2.1.2');
      lines = changelog.readAsLinesSync();
      expect(lines.first, startsWith('## 2.1.2 — '));
      expect(lines.where((l) => l.startsWith('## ')), hasLength(2));
    });
  });
}
