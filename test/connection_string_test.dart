import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/connection_string.dart';
import 'package:traceway/src/core/endpoints.dart';
import 'package:traceway/traceway.dart';

/// Every print of [body], the SDK's warnings among them.
List<String> printed(void Function() body) {
  final lines = <String>[];
  final previous = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  try {
    body();
  } finally {
    debugPrint = previous;
  }
  return lines;
}

void main() {
  setUp(resetStartWarningsForTest);

  // CONTRACT §16.1: the table every SDK's tests share.
  group('parseConnectionString: every variation (§16.1)', () {
    const valid = {
      'tok@http://api': 'http://api',
      'tok@api/': 'https://api',
      'tok@http://api/report': 'http://api/report',
      'tok@http://api/api/report?old=1': 'http://api',
      'tok@http://api/a%2Fb/api': 'http://api/a%2Fb',
      'tok@https://cloud.tracewayapp.com': 'https://cloud.tracewayapp.com',
      'tok@https://cloud.tracewayapp.com/': 'https://cloud.tracewayapp.com',
      'tok@https://cloud.tracewayapp.com/api': 'https://cloud.tracewayapp.com',
      'tok@https://cloud.tracewayapp.com/api/': 'https://cloud.tracewayapp.com',
      'tok@https://cloud.tracewayapp.com/api/report':
          'https://cloud.tracewayapp.com',
      'tok@https://cloud.tracewayapp.com/api/report/':
          'https://cloud.tracewayapp.com',
      'tok@cloud.tracewayapp.com': 'https://cloud.tracewayapp.com',
      'tok@cloud.tracewayapp.com/api/report': 'https://cloud.tracewayapp.com',
      '  tok@https://cloud.tracewayapp.com/api/report  ':
          'https://cloud.tracewayapp.com',
      'tok@http://localhost:8082/api/report': 'http://localhost:8082',
      'tok@localhost:8082': 'http://localhost:8082',
      'tok@https://corp.example/traceway/api/report':
          'https://corp.example/traceway',
      'tok@https://cloud.tracewayapp.com/api/report?x=1':
          'https://cloud.tracewayapp.com',
    };
    for (final MapEntry(key: input, value: baseUrl) in valid.entries) {
      test('"$input"', () {
        final parsed = parseConnectionString(input)!;
        expect(parsed.token, 'tok');
        expect(parsed.baseUrl, baseUrl);
      });
    }

    for (final input in [
      '@https://cloud.tracewayapp.com',
      'tok',
      'tok@',
      'tok@ftp://host',
    ]) {
      test('"$input" is not one', () {
        expect(parseConnectionString(input), isNull);
      });
    }

    test('splits at the first @; the other local hosts are http', () {
      expect(parseConnectionString('tok@https://u@host.test'), isNotNull);
      expect(parseConnectionString('tok@127.0.0.1:8082')!.baseUrl,
          'http://127.0.0.1:8082');
      expect(parseConnectionString('tok@10.0.2.2:8082/api')!.baseUrl,
          'http://10.0.2.2:8082');
      expect(parseConnectionString('tok@[::1]:8082')!.baseUrl,
          'http://[::1]:8082');
      expect(parseConnectionString('tok@https://'), isNull);
    });
  });

  group('baseUrl alone, the same rules', () {
    test('normalized like the URL of a connection string', () {
      expect(normalizeBaseUrl('https://cloud.tracewayapp.com/api/report'),
          'https://cloud.tracewayapp.com');
      expect(normalizeBaseUrl(' cloud.tracewayapp.com/ '),
          'https://cloud.tracewayapp.com');
      expect(normalizeBaseUrl('localhost:8082/api'), 'http://localhost:8082');
      expect(normalizeBaseUrl('https://corp.example/traceway/'),
          'https://corp.example/traceway');
      expect(normalizeBaseUrl('https://Traceway.Test:443'), 'https://traceway.test');
      for (final bad in ['', 'ftp://host', 'https://', '   ']) {
        expect(normalizeBaseUrl(bad), isNull, reason: bad);
      }
    });

    test('a URL without a scheme gets https:// (FLT2-4)', () {
      final e = resolveEndpoints('cloud.tracewayapp.com/api/report');
      expect(e.logs, 'https://cloud.tracewayapp.com/api/otel/v1/logs');
      expect(() => resolveEndpoints('ftp://x'), throwsArgumentError);
      expect(() => resolveEndpoints('https://'), throwsArgumentError);
    });
  });

  group('resolveStart (§16)', () {
    test('a token alone goes to Traceway Cloud, with no warning', () {
      late TracewayStart? start;
      final lines = printed(() => start = resolveStart(token: 'tok'));
      expect(start!.token, 'tok');
      expect(start!.baseUrl, 'https://cloud.tracewayapp.com');
      expect(lines, isEmpty);
    });

    test('a baseUrl names a self-hosted server', () {
      final start = resolveStart(token: ' tok ', baseUrl: 'traceway.test/api');
      expect(start!.token, 'tok');
      expect(start.baseUrl, 'https://traceway.test');
    });

    test('a connection string is read as token + baseUrl, with one '
        'deprecation warning naming the new form and never the token', () {
      final lines = printed(() {
        for (var i = 0; i < 3; i++) {
          final start = resolveStart(
              connectionString: 'secret-token@https://traceway.test/api/report');
          expect(start!.token, 'secret-token');
          expect(start.baseUrl, 'https://traceway.test');
        }
      });
      expect(lines, hasLength(1));
      expect(lines.single, contains('deprecated'));
      expect(lines.single,
          contains("Traceway.run(token: '…', baseUrl: 'https://traceway.test'"));
      expect(lines.single, isNot(contains('secret-token')));
    });

    test('for Traceway Cloud the warning leaves baseUrl out', () {
      final lines = printed(() => resolveStart(
          connectionString: 'tok@https://cloud.tracewayapp.com/api/report'));
      expect(lines.single, contains("Traceway.run(token: '…', child: …)"));
    });

    test('an invalid connection string or baseUrl warns once and leaves the '
        'SDK off, without throwing', () {
      final lines = printed(() {
        for (final bad in [
          '@https://cloud.tracewayapp.com',
          'tok',
          'tok@',
          'tok@ftp://host',
        ]) {
          expect(resolveStart(connectionString: bad), isNull, reason: bad);
        }
        expect(resolveStart(token: 'tok', baseUrl: 'ftp://host'), isNull);
        expect(resolveStart(token: 'tok', baseUrl: 'https://'), isNull);
      });
      expect(lines, hasLength(2));
      expect(lines.first, contains('the SDK is off'));
      expect(lines.last, contains('the SDK is off'));
    });

    test('an empty token (a build without its --dart-define) is none: it '
        'needs telemetry then, and the error says so', () {
      expect(
          () => resolveStart(token: ''),
          throwsA(isA<ArgumentError>().having(
              (e) => '${e.message}', 'message', contains('TRACEWAY_TOKEN'))));
      final standalone = resolveStart(
          token: '', telemetry: const TracewayTelemetry(url: 'https://c.test'));
      expect(standalone!.token, isNull);
    });
  });
}
