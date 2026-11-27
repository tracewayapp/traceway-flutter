import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/src/persistence/legacy_reports.dart';
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;
import 'package:traceway/traceway.dart';

import 'support.dart';

/// A report as 1.x's ExceptionStore wrote it.
Map<String, Object?> _report(String stackTrace,
        {DateTime? at, bool isMessage = false, Map<String, String>? attributes}) =>
    {
      'createdAt': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'exception': {
        'traceId': null,
        'isTask': false,
        'stackTrace': stackTrace,
        'recordedAt': (at ?? DateTime.now()).toUtc().toIso8601String(),
        'attributes': attributes ?? {},
        'isMessage': isMessage,
        'sessionRecordingId': 'clip-1',
        'distributedTraceId': null,
      },
      'recording': {
        'exceptionId': 'clip-1',
        'events': [
          {'type': 'flutter_video', 'data': 'AAAA'}
        ],
      },
    };

void main() {
  late Directory root;
  late Directory pending;

  setUp(() {
    root = Directory.systemTemp.createTempSync('traceway_legacy');
    pending = Directory('${root.path}/traceway_pending')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  void write(String name, Object? entry, {Directory? dir}) =>
      File('${(dir ?? pending).path}/$name.json')
          .writeAsStringSync(entry is String ? entry : jsonEncode(entry));

  test('fresh 1.x reports become reports; old, damaged and foreign files go, '
      'and so does the directory', () async {
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    write('error', _report('StateError: Bad state: boom\nmain\n    file:///a.dart:3:1',
        at: at, attributes: {'user.id': 'u1'}));
    write('message', _report('checkout done', isMessage: true));
    // 2.0 betas moved reports into a directory per destination.
    final claimed = Directory('${pending.path}/0123abcd')..createSync();
    write('claimed', _report('FormatException: bad\nf\n    file:///b.dart:1:1'),
        dir: claimed);
    write('stale', _report('StateError: Bad state: stale',
        at: DateTime.now().subtract(const Duration(hours: 13))));
    final old = File('${pending.path}/expired.json')
      ..writeAsStringSync(jsonEncode(_report('StateError: Bad state: old')));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    write('corrupt', 'not json {');
    write('other', {'createdAt': DateTime.now().toIso8601String()});
    File('${pending.path}/notes.txt').writeAsStringSync('x');

    final reports = <LegacyReport>[];
    final legacy = LegacyReports(pending, reports.add);
    await Future.wait([legacy.convert(), legacy.convert()]);
    expect(reports.map((r) => r.stackTrace.split('\n').first),
        unorderedEquals([
          'StateError: Bad state: boom',
          'checkout done',
          'FormatException: bad',
        ]));
    final error = reports.firstWhere((r) => r.stackTrace.startsWith('StateError'));
    expect(error.isMessage, isFalse);
    expect(error.attributes, {'user.id': 'u1'});
    expect(error.recordedAt.difference(at).inSeconds.abs(), lessThan(1));
    expect(reports.firstWhere((r) => r.isMessage).stackTrace, 'checkout done');
    expect(pending.existsSync(), isFalse);

    // Nothing left: a second start has nothing to convert.
    await LegacyReports(pending, reports.add).convert();
    expect(reports, hasLength(3));
  });

  test('at start-up they are OTLP records of the running SDK, with their '
      'time, type and message, and fire no trigger', () async {
    final at = DateTime.now().subtract(const Duration(minutes: 30));
    write('error', _report(
        'StateError: Bad state: old issue\nmain\n    file:///a.dart:3:1',
        at: at,
        attributes: {'user.id': 'u1'}));
    write('message', _report('legacy message', isMessage: true, at: at));
    final requests = <http.Request>[];
    final client = await TracewayClient.initializeForTest(
      'new@https://traceway.test',
      const TracewayOptions(remoteConfig: false, captureMetrics: false),
      overrides: TracewayTestOverrides(
        stateDirectory: Directory('${root.path}/traceway_v2'),
        legacyDirectory: pending,
        httpClient: MockClient((r) async {
          requests.add(r);
          return http.Response('', 200);
        }),
      ),
    );
    addTearDown(TracewayClient.resetForTest);
    // A breadcrumb in the buffer: an exception of this run would upload it.
    client.log('breadcrumb before');
    await client.flush();
    expect(requests.where((r) => r.url.path.contains('/api/report')), isEmpty);
    final logs = requests.where((r) => r.url.path == '/api/otel/v1/logs');
    expect(logs, isNotEmpty);
    expect(requests.every((r) => r.headers['Authorization'] == 'Bearer new'),
        isTrue);
    expect(pending.existsSync(), isFalse);
  });

  test('the records: an exception with its type, message and stack, a message '
      'with its text, at the time they happened', () async {
    final at = DateTime.now().subtract(const Duration(minutes: 30));
    write('error', _report(
        'StateError: Bad state: old issue\nmain\n    file:///a.dart:3:1',
        at: at,
        attributes: {'user.id': 'u1'}));
    write('message', _report('legacy message', isMessage: true, at: at));
    final logs = InMemoryLogExporter();
    addTearDown(TracewayClient.resetForTest);
    final client = await TracewayClient.initializeForTest(
      connectionString,
      const TracewayOptions(remoteConfig: false, captureMetrics: false),
      overrides: TracewayTestOverrides(
        logExporter: logs,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        legacyDirectory: pending,
      ),
    );
    client.log('breadcrumb before');
    await client.flush();
    final exception = logs.records.singleWhere((r) => r.eventName == eventException);
    expect(attr(exception, 'exception.type'), 'StateError');
    expect(attr(exception, 'exception.message'), 'Bad state: old issue');
    expect(attr(exception, 'exception.stacktrace'),
        startsWith('StateError: Bad state: old issue\nmain'));
    expect(attr(exception, 'user.id'), 'u1');
    expect(attr(exception, 'traceway.legacy_report'), true);
    expect(attr(exception, attrExceptionId), isNotNull);
    final nanos = exception.timestamp!.toInt();
    expect((nanos ~/ 1000000 - at.millisecondsSinceEpoch).abs(), lessThan(1000));
    final message = logs.records.singleWhere((r) => r.eventName == eventMessage);
    expect(message.body, 'legacy message');
    // Not an error of this run: the buffered breadcrumb stayed on the device.
    expect(logs.records.where((r) => r.body == 'breadcrumb before'), isEmpty);
  });
}
