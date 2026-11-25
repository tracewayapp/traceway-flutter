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
}
