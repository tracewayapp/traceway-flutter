import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/endpoints.dart';
import 'package:traceway/src/persistence/legacy_reports.dart';
import 'package:traceway/traceway.dart';
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;

void main() {
  test(
      'legacy errors and their clips retry only against their original project',
      () async {
    final root = Directory.systemTemp.createTempSync('traceway_upgrade');
    addTearDown(() => root.deleteSync(recursive: true));
    final pending = Directory('${root.path}/traceway_pending')..createSync();
    final entry = {
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'exception': {
        'stackTrace': 'legacy error',
        'sessionRecordingId': 'clip-1'
      },
      'recording': {
        'exceptionId': 'clip-1',
        'events': [
          {'type': 'flutter_video'}
        ]
      },
    };
    File('${pending.path}/report.json').writeAsStringSync(jsonEncode(entry));
    final old = File('${pending.path}/expired.json')
      ..writeAsStringSync(jsonEncode(entry));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    const target = OtlpDestination(
        'https://old.test/api/report', {'Authorization': 'Bearer original'});
    var status = 503;
    final requests = <http.Request>[];
    final httpClient = MockClient((req) async {
      requests.add(req);
      return http.Response('', status);
    });
    await LegacyReports(pending, null, httpClient).drain();
    expect(old.existsSync(), isFalse);
    expect(requests, isEmpty);
    await LegacyReports(pending, target, httpClient).drain();
    await LegacyReports(
            pending,
            const OtlpDestination('https://new.test/api/report', {}),
            httpClient)
        .drain();
    expect(requests, hasLength(1));
    status = 200;
    final next = LegacyReports(pending, target, httpClient);
    await Future.wait([next.drain(), next.drain()]);
    await next.drain();
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.url.toString(), target.url);
      expect(request.headers['Authorization'], 'Bearer original');
      final frame = jsonDecode(
              utf8.decode(gzip.decode(request.bodyBytes)))['collectionFrames']
          .single;
      expect(frame['stackTraces'], [entry['exception']]);
      expect(frame['sessionRecordings'], [entry['recording']]);
    }
  });
  test('startup uses the configured 1.x report endpoint on a project change',
      () async {
    final root = Directory.systemTemp.createTempSync('traceway_v1');
    addTearDown(() => root.deleteSync(recursive: true));
    addTearDown(TracewayClient.resetForTest);
    final pending = Directory('${root.path}/traceway_pending')..createSync();
    File('${pending.path}/report.json').writeAsStringSync(jsonEncode({
      'createdAt': DateTime.now().toIso8601String(),
      'exception': {'stackTrace': 'old issue'},
    }));
    final reports = <http.Request>[];
    final client = await TracewayClient.initializeForTest(
      'new@https://new.test',
      const TracewayOptions(
          remoteConfig: false,
          captureMetrics: false,
          legacyConnectionString:
              'original@https://old.test/prefix/api/report'),
      overrides: TracewayTestOverrides(
        stateDirectory: Directory('${root.path}/traceway_v2'),
        legacyDirectory: pending,
        httpClient: MockClient((r) async {
          if (r.url.path.endsWith('/report')) reports.add(r);
          return http.Response('', 200);
        }),
      ),
    );
    await client.flush();
    expect(reports.single.url.toString(), 'https://old.test/prefix/api/report');
    expect(reports.single.headers['Authorization'], 'Bearer original');
  });

  group('the drain', () {
    const target = OtlpDestination(
        'https://old.test/api/report', {'Authorization': 'Bearer original'});
    late Directory pending;
    late List<String> sent;

    setUp(() {
      final root = Directory.systemTemp.createTempSync('traceway_legacy');
      addTearDown(() => root.deleteSync(recursive: true));
      pending = Directory('${root.path}/traceway_pending')..createSync();
      sent = [];
    });

    void report(String name) =>
        File('${pending.path}/$name.json').writeAsStringSync(jsonEncode({
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'exception': {'stackTrace': name},
        }));

    /// Answers each report by its stack trace; 0 is no answer at all.
    LegacyReports reports(int Function(String report) respond) =>
        LegacyReports(pending, target, MockClient((request) async {
          final name = jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))[
                  'collectionFrames']
              .single['stackTraces']
              .single['stackTrace'] as String;
          sent.add(name);
          final status = respond(name);
          if (status == 0) throw const SocketException('offline');
          return http.Response('', status);
        }));

    List<String> left() => [
          for (final file in pending.listSync(recursive: true))
            if (file is File) file.uri.pathSegments.last,
        ];

    test('any 2xx delivers a report, once', () async {
      report('created');
      report('no content');
      final legacy = reports((name) => name == 'created' ? 201 : 204);
      await legacy.drain();
      await legacy.drain();
      expect(sent, unorderedEquals(['created', 'no content']));
      expect(left(), isEmpty);
    });

    test('a report rejected for good is dropped and holds back no other',
        () async {
      const statuses = {
        'bad': 400,
        'unauthorized': 401,
        'forbidden': 403,
        'too large': 413,
        'ok': 200,
      };
      statuses.keys.forEach(report);
      final legacy = reports((name) => statuses[name]!);
      await legacy.drain();
      await legacy.drain();
      expect(sent, unorderedEquals(statuses.keys));
      expect(left(), isEmpty);
    });

    test('a throttled, failing or unreachable server keeps the reports for '
        'the next drain', () async {
      report('first');
      report('second');
      for (final status in [408, 429, 500, 503, 0]) {
        sent.clear();
        await reports((_) => status).drain();
        expect(sent, hasLength(1), reason: '$status');
        expect(left(), unorderedEquals(['first.json', 'second.json']));
      }
      await reports((_) => 200).drain();
      expect(left(), isEmpty);
    });

    test('an unreadable report is dropped and does not stop the drain',
        () async {
      File('${pending.path}/corrupt.json').writeAsBytesSync([0xff, 0xfe, 0xfd]);
      report('ok');
      await reports((_) => 200).drain();
      expect(sent, ['ok']);
      expect(left(), isEmpty);
    });
  });
}
