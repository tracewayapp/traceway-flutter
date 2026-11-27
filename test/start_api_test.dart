// CONTRACT §16: the start API (`token` + `baseUrl`), the deprecated
// connection string, and no request to the 1.x `/api/report` ever.
import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/connection_string.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;
import 'package:traceway/traceway.dart';

import 'support.dart';

/// Records every request, and answers OpAMP as the server does.
class _Wire {
  final List<http.Request> requests = [];
  late final MockClient client = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', 200);
  });
}

void main() {
  setUp(resetStartWarningsForTest);
  tearDown(TracewayClient.resetForTest);

  test('token + baseUrl: Traceway is the server, the token the bearer', () async {
    final wire = _Wire();
    final client = await TracewayClient.initializeForTest(
      null,
      const TracewayOptions(captureMetrics: false),
      token: 'tok',
      baseUrl: 'traceway.test/api/report/',
      overrides: TracewayTestOverrides(httpClient: wire.client),
    );
    client.captureMessage('hello');
    await client.flush();
    final hosts = wire.requests.map((r) => '${r.url.scheme}://${r.url.host}');
    expect(hosts, everyElement('https://traceway.test'));
    final paths = wire.requests.map((r) => r.url.path).toSet();
    expect(paths, containsAll(['/api/otel/v1/opamp', '/api/otel/v1/logs']));
    expect(wire.requests.map((r) => r.headers['Authorization']),
        everyElement('Bearer tok'));
  });

  test('the deprecated connection string sends to the same places, with one '
      'warning', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    final wire = _Wire();
    final client = await TracewayClient.initializeForTest(
      'tok@traceway.test/api',
      const TracewayOptions(captureMetrics: false),
      overrides: TracewayTestOverrides(httpClient: wire.client),
    );
    client.captureMessage('hello');
    await client.flush();
    await client.shutdown();
    await TracewayClient.initializeForTest(
      'tok@https://traceway.test/api/report',
      const TracewayOptions(captureMetrics: false, remoteConfig: false),
      overrides: TracewayTestOverrides(httpClient: wire.client),
    );
    expect(wire.requests.map((r) => r.url.host), everyElement('traceway.test'));
    expect(lines.where((l) => l.contains('connection strings are deprecated')),
        hasLength(1));
  });

  testWidgets('Traceway.run with a connection string it cannot use runs the '
      'app without the SDK, after one warning, and throws nothing',
      (tester) async {
    final lines = <String>[];
    final reported = <FlutterErrorDetails>[];
    final previous = debugPrint;
    final previousOnError = FlutterError.onError;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    FlutterError.onError = reported.add;
    try {
      Traceway.run(
        // ignore: deprecated_member_use_from_same_package
        connectionString: 'tok@ftp://host',
        child: const Directionality(
            textDirection: TextDirection.ltr, child: Text('app')),
      );
      await tester.pump();
    } finally {
      debugPrint = previous;
      FlutterError.onError = previousOnError;
    }
    expect(find.text('app'), findsOneWidget);
    expect(TracewayClient.instance, isNull);
    expect(reported, isEmpty);
    expect(lines.where((l) => l.contains('the SDK is off')), hasLength(1));
  });

  test('TracewayClient.initialize returns null for a baseUrl it cannot use',
      () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    try {
      expect(
          TracewayClient.initialize(token: 'tok', baseUrl: 'ftp://host'), isNull);
    } finally {
      debugPrint = previous;
    }
    expect(TracewayClient.instance, isNull);
    expect(lines.single, contains('baseUrl must be an HTTP(S) URL'));
  });

  test('nothing ever requests /api/report: not the 1.x reports on disk, not '
      'a connection string that names it, not flush, resume or shutdown',
      () async {
    final root = Directory.systemTemp.createTempSync('traceway_no_report');
    addTearDown(() => root.deleteSync(recursive: true));
    final pending = Directory('${root.path}/traceway_pending')..createSync();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final name in ['a', 'b']) {
      File('${pending.path}/$name.json').writeAsStringSync(jsonEncode({
        'createdAt': now,
        'exception': {
          'stackTrace': 'StateError: Bad state: $name\nmain\n    file:///a.dart:1:1',
          'recordedAt': now,
          'isMessage': false,
        },
        'recording': {
          'events': [
            {'type': 'flutter_video'}
          ]
        },
      }));
    }
    final wire = _Wire();
    final logs = InMemoryLogExporter();
    final client = await TracewayClient.initializeForTest(
      'tok@https://traceway.test/api/report',
      const TracewayOptions(screenCapture: true),
      overrides: TracewayTestOverrides(
        httpClient: wire.client,
        logExporter: logs,
        legacyDirectory: pending,
        stateDirectory: Directory('${root.path}/traceway_v2'),
      ),
    );
    client.captureException(StateError('now'), StackTrace.current);
    client.captureMessage('message');
    await client.flush();
    client.didChangeAppLifecycleState(AppLifecycleState.paused);
    client.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await client.flush();
    await client.shutdown();
    expect(wire.requests, isNotEmpty);
    expect(wire.requests.where((r) => r.url.path.contains('/api/report')),
        isEmpty);
    // The 1.x reports were sent, as OTLP exception records.
    final legacy = logs.records
        .where((r) => attr(r, 'traceway.legacy_report') == true)
        .toList();
    expect(legacy.map((r) => r.eventName), [eventException, eventException]);
    expect(pending.existsSync(), isFalse);
  });

  test('no source in lib/ builds a request to /api/report', () {
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (!line.contains('api/report') || line.startsWith('//')) continue;
        // The normalizer drops the suffix of old connection strings.
        expect(line, matches(RegExp(r"endsWith\('/api/report'\)|'/api/report'\.length")),
            reason: '${file.path}:${i + 1}: $line');
      }
    }
  });

  test('the README starts with token: and uses no connection string', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains("Traceway.run(\n    token: "));
    expect(readme, contains('TRACEWAY_TOKEN'));
    expect(readme, contains('navigatorObservers: [Traceway.navigatorObserver]'));
    expect(readme, contains('## Send telemetry to another OpenTelemetry provider'));
    expect(readme, contains('## Video replay (add-on)'));
    expect(readme, isNot(contains('connectionString:')));
    // The options table no longer lists it (the migration notes say it went).
    expect(readme, isNot(contains('| `legacyConnectionString`')));
    expect(readme, isNot(contains('/api/report')));
    expect(readme, isNot(contains(RegExp(r'[A-Za-z_-]+@https?://'))),
        reason: 'no connection string in an example');
    expect(readme, isNot(contains('your-token')));
    expect(readme, isNot(contains('traceway.example.com')));
  });
}
