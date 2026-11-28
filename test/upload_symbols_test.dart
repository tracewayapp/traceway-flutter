import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/symbols_upload.dart';

/// `dart run traceway:upload_symbols`: where its settings come from and where
/// it sends (bin/upload_symbols.dart).
void main() {
  group('resolveSymbolsUploadUrl', () {
    test('defaults to Traceway Cloud when nothing names a server', () {
      expect(resolveSymbolsUploadUrl(), 'https://cloud.tracewayapp.com');
      expect(resolveSymbolsUploadUrl(), symbolsUploadDefaultUrl);
      expect(
        symbolsUploadEndpoint(resolveSymbolsUploadUrl()),
        'https://cloud.tracewayapp.com/api/symbols/upload',
      );
    });

    test('treats blank values (an unset CI secret) as unset', () {
      expect(
        resolveSymbolsUploadUrl(
          flag: '',
          env: {'TRACEWAY_URL': '  '},
          pubspec: {'url': ''},
        ),
        symbolsUploadDefaultUrl,
      );
    });

    test('takes the flag, then TRACEWAY_URL, then pubspec.yaml', () {
      const env = {'TRACEWAY_URL': 'https://env.example.com'};
      const pubspec = {'url': 'https://pubspec.example.com'};
      expect(
        resolveSymbolsUploadUrl(
            flag: 'https://flag.example.com', env: env, pubspec: pubspec),
        'https://flag.example.com',
      );
      expect(resolveSymbolsUploadUrl(env: env, pubspec: pubspec),
          'https://env.example.com');
      expect(resolveSymbolsUploadUrl(pubspec: pubspec),
          'https://pubspec.example.com');
    });
  });

  group('symbolsUploadEndpoint', () {
    const cases = {
      'http://api': 'http://api/api/symbols/upload',
      'api/': 'https://api/api/symbols/upload',
      'http://api/report': 'http://api/report/api/symbols/upload',
      'http://api/symbols/upload': 'http://api/symbols/upload/api/symbols/upload',
      'https://cloud.tracewayapp.com':
          'https://cloud.tracewayapp.com/api/symbols/upload',
      'https://cloud.tracewayapp.com/':
          'https://cloud.tracewayapp.com/api/symbols/upload',
      'https://cloud.tracewayapp.com/api':
          'https://cloud.tracewayapp.com/api/symbols/upload',
      'https://cloud.tracewayapp.com/api/report/':
          'https://cloud.tracewayapp.com/api/symbols/upload',
      '  https://cloud.tracewayapp.com?x=1  ':
          'https://cloud.tracewayapp.com/api/symbols/upload',
      'cloud.tracewayapp.com':
          'https://cloud.tracewayapp.com/api/symbols/upload',
      'localhost:8082': 'http://localhost:8082/api/symbols/upload',
      'http://127.0.0.1:8082/api/report':
          'http://127.0.0.1:8082/api/symbols/upload',
      'https://corp.example/traceway':
          'https://corp.example/traceway/api/symbols/upload',
      'https://corp.example/traceway/api/symbols/upload':
          'https://corp.example/traceway/api/symbols/upload',
    };
    test('rejects unusable server URLs before attempting an upload', () {
      for (final url in ['', 'ftp://api', 'http://']) {
        expect(() => symbolsUploadEndpoint(url), throwsArgumentError);
      }
    });

    cases.forEach((url, endpoint) {
      test('$url -> $endpoint', () {
        expect(symbolsUploadEndpoint(url), endpoint);
      });
    });
  });

  group('parsePubspecTracewayBlock', () {
    test('reads the traceway: block, unquoted and without comments', () {
      final cfg = parsePubspecTracewayBlock('''
name: my_app
dependencies:
  traceway: ^2.1.0

traceway:
  # a comment
  url: "https://traceway.example.com"   # the server
  symbols_dir: build/symbols # where they are
  upload_token:

flutter:
  uses-material-design: true
'''
          .split('\n'));
      expect(cfg, {
        'url': 'https://traceway.example.com',
        'symbols_dir': 'build/symbols',
      });
    });

    test('a pubspec without a traceway: block names no server', () {
      final cfg = parsePubspecTracewayBlock(
          ['name: my_app', 'dependencies:', '  traceway: ^2.1.0']);
      expect(cfg, isEmpty);
      expect(resolveSymbolsUploadUrl(pubspec: cfg), symbolsUploadDefaultUrl);
    });
  });
}
