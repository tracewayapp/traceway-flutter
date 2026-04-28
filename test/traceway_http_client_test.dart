import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/events/traceway_http_client.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

void main() {
  group('TracewayHttpClient', () {
    test('records a NetworkEvent on a successful request', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        return http.Response('ok', 200,
            headers: {'content-length': '2'});
      });

      final wrapped = TracewayHttpClient(mock);
      final res = await wrapped.get(Uri.parse('https://api.test/users/1'));
      expect(res.statusCode, 200);

      final events = client.bufferedEvents.whereType<NetworkEvent>().toList();
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.method, 'GET');
      expect(e.url, 'https://api.test/users/1');
      expect(e.statusCode, 200);
      expect(e.responseBytes, 2);
      expect(e.error, isNull);
    });

    test('records request bytes and method for POST', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      final mock = MockClient((req) async {
        return http.Response('{}', 201);
      });

      final wrapped = TracewayHttpClient(mock);
      await wrapped.post(
        Uri.parse('https://api.test/items'),
        body: 'hello world',
      );

      final e = client.bufferedEvents.whereType<NetworkEvent>().single;
      expect(e.method, 'POST');
      expect(e.statusCode, 201);
      expect(e.requestBytes, 'hello world'.length);
    });

    test('records error and rethrows when the inner client throws', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );

      final mock = MockClient((req) async {
        throw Exception('boom');
      });

      final wrapped = TracewayHttpClient(mock);

      await expectLater(
        wrapped.get(Uri.parse('https://api.test/fail')),
        throwsException,
      );

      final e = client.bufferedEvents.whereType<NetworkEvent>().single;
      expect(e.method, 'GET');
      expect(e.url, 'https://api.test/fail');
      expect(e.statusCode, isNull);
      expect(e.error, contains('boom'));
    });

    test('does not record when captureNetwork is disabled', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureNetwork: false),
      );

      final mock = MockClient((req) async => http.Response('', 204));
      final wrapped = TracewayHttpClient(mock);
      await wrapped.get(Uri.parse('https://api.test/'));

      expect(client.bufferedEvents.whereType<NetworkEvent>(), isEmpty);
    });
  });
}
