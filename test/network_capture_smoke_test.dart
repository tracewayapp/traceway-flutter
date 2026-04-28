import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:traceway/src/events/network_capture.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

/// End-to-end smoke test for [TracewayHttpOverrides]. Spins up a real local
/// HttpServer, installs the overrides globally, and verifies that traffic
/// going through the wrapped dart:io HttpClient is recorded as a NetworkEvent.
void main() {
  group('TracewayHttpOverrides smoke', () {
    late HttpServer server;
    late Uri baseUri;
    HttpOverrides? previousOverrides;

    setUp(() async {
      previousOverrides = HttpOverrides.current;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        if (req.uri.path == '/boom') {
          req.response.statusCode = 500;
          await req.response.close();
          return;
        }
        // Drain request body so contentLength is observable on our side.
        await req.drain<void>();
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': true}));
        await req.response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
    });

    test('records NetworkEvent for a dart:io HttpClient request', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);

      final httpClient = HttpClient();
      try {
        final req = await httpClient.getUrl(baseUri.replace(path: '/hello'));
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, 200);
      } finally {
        httpClient.close();
      }

      final e = client.bufferedEvents.whereType<NetworkEvent>().single;
      expect(e.method, 'GET');
      expect(e.url, '$baseUri/hello');
      expect(e.statusCode, 200);
    });

    test('records NetworkEvent for package:http through HttpOverrides',
        () async {
      // package:http on native uses IOClient -> dart:io HttpClient, which is
      // exactly what HttpOverrides wraps. This is the realistic path most apps
      // hit, so it earns its own smoke pass.
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);

      final res = await http.post(
        baseUri.replace(path: '/items'),
        body: 'payload',
      );
      expect(res.statusCode, 200);

      final e = client.bufferedEvents.whereType<NetworkEvent>().single;
      expect(e.method, 'POST');
      expect(e.url, '$baseUri/items');
      expect(e.statusCode, 200);
      // Body bytes flow through the wrapper's `add`/`addStream` overrides.
      expect(e.requestBytes, isNotNull);
      expect(e.requestBytes! >= 'payload'.length, true);
    });

    test('records error and rethrows when the connection fails', () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);

      // Bind another socket on a free port, immediately close it, and try to
      // reach it — guarantees a connect-time failure regardless of host firewall.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);

      await expectLater(
        () async {
          final req = await httpClient
              .getUrl(Uri.parse('http://127.0.0.1:$deadPort/'));
          await req.close();
        }(),
        throwsA(anything),
      );
      httpClient.close();

      final events = client.bufferedEvents.whereType<NetworkEvent>().toList();
      expect(events, hasLength(1));
      expect(events.single.error, isNotNull);
    });

    test('captureNetwork:false suppresses HttpOverrides-recorded events',
        () async {
      final client = TracewayClient.initialize(
        'token@https://example.com/api/report',
        const TracewayOptions(captureNetwork: false),
      );
      HttpOverrides.global = TracewayHttpOverrides(previousOverrides);

      final res = await http.get(baseUri.replace(path: '/hello'));
      expect(res.statusCode, 200);

      // Wrapper still emits, but the client gates the buffer write.
      expect(client.bufferedEvents.whereType<NetworkEvent>(), isEmpty);
    });
  });
}
