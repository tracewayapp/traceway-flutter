import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/connection_string.dart';

void main() {
  group('parseConnectionString', () {
    test('parses valid connection string', () {
      final result = parseConnectionString(
        'mytoken@https://traceway.example.com/api/report',
      );
      expect(result.token, 'mytoken');
      expect(result.apiUrl, 'https://traceway.example.com/api/report');
    });

    test('handles token with special characters', () {
      final result = parseConnectionString(
        'abc-123_def@https://api.example.com/report',
      );
      expect(result.token, 'abc-123_def');
      expect(result.apiUrl, 'https://api.example.com/report');
    });

    test('uses first @ as delimiter', () {
      final result = parseConnectionString(
        'token@https://user@host.com/api',
      );
      expect(result.token, 'token');
      expect(result.apiUrl, 'https://user@host.com/api');
    });

    test('throws on missing @', () {
      expect(
        () => parseConnectionString('notokenhere'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on empty token', () {
      expect(
        () => parseConnectionString('@https://example.com'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on empty apiUrl', () {
      expect(
        () => parseConnectionString('token@'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
