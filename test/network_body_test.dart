import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart' show Span;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:traceway/src/events/network_capture.dart';
import 'package:traceway/src/events/traceway_http_client.dart';
import 'package:traceway/src/otel/router.dart' show SpanItem;
import 'package:traceway/src/traceway_client.dart';

import 'support.dart';

/// How long the tests hold a body back after its headers.
const _slow = Duration(milliseconds: 300);

Object? _attr(Span span, String key) => span.attributes.toMap()[key]?.value;

Duration _duration(Span span) => span.endTime!.difference(span.startTime);

/// The request spans recorded so far: sent, or held in the ring buffer until
/// an error.
Future<List<Span>> _spans(Harness h) async {
  await h.client.flush();
  return [
    ...h.spans.spans,
    for (final entry in h.client.bufferSnapshot)
      if (entry.item case SpanItem(:final span)) span,
  ];
}

Future<List<Span>> _spansTo(Harness h, String path) async => [
      for (final span in await _spans(h))
        if (Uri.parse(_attr(span, 'url.full')! as String).path == path) span,
    ];

/// One turn of the event loop: every pending microtask has run.
Future<void> _turn() => Future<void>.delayed(Duration.zero);

/// dart:io with nothing of the SDK in it.
class _Plain extends HttpOverrides {}

/// A dart:io response the test drives: its body is [body]'s.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({this.contentLength = -1});

  /// What reached the body's controller, and the calls forwarded here.
  final log = <String>[];
  late final body = StreamController<List<int>>(
    onPause: () => log.add('pause'),
    onResume: () => log.add('resume'),
    onCancel: () => log.add('cancel'),
  );
  final socket = Completer<Socket>().future;
  final redirected = Completer<HttpClientResponse>().future;

  @override
  final int contentLength;

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK, fake';

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  bool get persistentConnection => false;

  @override
  bool get isRedirect => false;

  @override
  final List<RedirectInfo> redirects = [];

  @override
  final List<Cookie> cookies = [Cookie('a', 'b')];

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  Future<HttpClientResponse> redirect(
      [String? method, Uri? url, bool? followLoops]) {
    log.add('redirect $method $url $followLoops');
    return redirected;
  }

  @override
  Future<Socket> detachSocket() {
    log.add('detachSocket');
    return socket;
  }

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      body.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
}

class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.response);

  final _FakeResponse response;

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  Future<HttpClientResponse> get done async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements HttpClient {
  _FakeClient(this.response);

  final _FakeResponse response;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(response);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(response);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A dart:io under the SDK whose only response is [response].
class _Fake extends HttpOverrides {
  _Fake(this.response);

  final _FakeResponse response;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeClient(response);
}

/// [fake] as the app gets it through the SDK.
Future<HttpClientResponse> _throughSdk(_FakeResponse fake) =>
    HttpOverrides.runWithHttpOverrides(() async {
      final request =
          await HttpClient().getUrl(Uri.parse('https://api.example.com/fake'));
      return request.close();
    }, TracewayHttpOverrides(_Fake(fake)));

/// A server that answers with 10 of the 100 bytes it announces, then hangs
/// up.
Future<ServerSocket> _cutOffServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    final request = <int>[];
    var answered = false;
    socket.listen((data) {
      request.addAll(data);
      if (answered || !latin1.decode(request).contains('\r\n\r\n')) return;
      answered = true;
      socket.add(utf8
          .encode('HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n0123456789'));
      socket.close();
    }, onError: (Object _) {});
  });
  return server;
}

/// A server whose `/slow` sends `head-`, then `tail` once [release]
/// completes.
Future<HttpServer> _slowServer(Future<void> release) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    if (request.uri.path == '/moved') {
      await response.redirect(Uri.parse('/slow'));
    } else if (request.uri.path == '/slow') {
      response.write('head-');
      await response.flush();
      await release;
      response.write('tail');
      await response.close();
    } else {
      // Other programs on a development machine probe new local ports.
      await response.close();
    }
  });
  return server;
}

void main() {
  final unreadTimeout = ObservedResponseBody.unreadTimeout;
  tearDown(() async {
    ObservedResponseBody.unreadTimeout = unreadTimeout;
    await TracewayClient.resetForTest();
  });

  group('dart:io', () {
    test('a request lasts until its body is read', () async {
      final release = Completer<void>();
      final server = await _slowServer(release.future);
      addTearDown(() => server.close(force: true));
      final h = await startHarness();
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${server.port}/slow'));
        final response = await request.close();
        final bytes = <int>[];
        final read = response.listen(bytes.addAll).asFuture<void>();
        await Future<void>.delayed(_slow);
        expect(await _spansTo(h, '/slow'), isEmpty,
            reason: 'not over at its headers');
        release.complete();
        await read;
        expect(utf8.decode(bytes), 'head-tail');
        client.close(force: true);
      }, TracewayHttpOverrides(null));
      final span = (await _spansTo(h, '/slow')).single;
      expect(_duration(span), greaterThanOrEqualTo(_slow));
      expect(_attr(span, 'http.response.status_code'), 200);
      // Chunked: no Content-Length, the bytes read.
      expect(_attr(span, 'http.response.body.size'), 9);
      expect(_attr(span, 'error.type'), isNull);
    });

    test('a connection lost mid-body fails the request', () async {
      final server = await _cutOffServer();
      addTearDown(server.close);
      final h = await startHarness();
      Object? error;
      var received = 0;
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${server.port}/cut'));
        final response = await request.close();
        expect(response.statusCode, 200);
        final over = Completer<void>();
        response.listen((data) => received += data.length, onError: (Object e) {
          error = e;
          if (!over.isCompleted) over.complete();
        }, onDone: () {
          if (!over.isCompleted) over.complete();
        });
        await over.future;
        client.close(force: true);
      }, TracewayHttpOverrides(null));
      expect(error, isA<IOException>());
      expect(received, 10);
      final span = (await _spansTo(h, '/cut')).single;
      expect(span.status.name, 'Error');
      expect(_attr(span, 'error.type'), '$error');
      expect(_attr(span, 'http.response.status_code'), 200);
      expect(_attr(span, 'http.response.body.size'), 10);
    });

    test('the app sees the same data, errors, timing and back-pressure',
        () async {
      final h = await startHarness();
      final chunks = [
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3]),
        Uint8List.fromList([4, 5, 6]),
      ];
      final error = const SocketException('Connection reset by peer');
      final trace = StackTrace.current;

      /// What the app sees of [response] while the test drives [fake].
      Future<List<Object?>> watch(
          HttpClientResponse response, _FakeResponse fake) async {
        final seen = <Object?>[];
        final done = Completer<void>();
        final subscription = response.listen(seen.add,
            onError: (Object e, StackTrace s) => seen
              ..add(e)
              ..add(s),
            onDone: () {
              seen.add('done');
              done.complete();
            });
        fake.body.add(chunks[0]);
        await _turn();
        seen.add('|');
        subscription.pause();
        seen.add(subscription.isPaused);
        fake.body.add(chunks[1]);
        await _turn();
        seen.add('|');
        subscription.resume();
        seen.add(subscription.isPaused);
        await _turn();
        seen.add('|');
        fake.body
          ..addError(error, trace)
          ..add(chunks[2]);
        unawaited(fake.body.close());
        await done.future;
        return seen;
      }

      final plain = _FakeResponse();
      final expected = await watch(plain, plain);
      final fake = _FakeResponse();
      final seen = await watch(await _throughSdk(fake), fake);
      expect(seen, hasLength(expected.length));
      for (var i = 0; i < seen.length; i++) {
        expect(seen[i], same(expected[i]), reason: 'event $i');
      }
      expect(fake.log, plain.log);
      expect(fake.log, containsAllInOrder(['pause', 'resume']));
      final span = (await _spans(h)).single;
      expect(span.status.name, 'Error');
      expect(_attr(span, 'error.type'), '$error');
      expect(_attr(span, 'http.response.status_code'), 200);
      // What came before the error.
      expect(_attr(span, 'http.response.body.size'), 3);
    });

    test('an error the app has no handler for goes where it would have',
        () async {
      final server = await _cutOffServer();
      addTearDown(server.close);
      final h = await startHarness();
      final url = Uri.parse('http://127.0.0.1:${server.port}/unhandled');

      /// The errors left to the zone while [url] is read with no handler.
      Future<List<Object>> unhandled(HttpOverrides overrides) async {
        final errors = <Object>[];
        final done = Completer<void>();
        final client =
            HttpOverrides.runWithHttpOverrides(HttpClient.new, overrides);
        runZonedGuarded(() async {
          final response = await (await client.getUrl(url)).close();
          response.listen(null, onDone: done.complete);
        }, (error, _) => errors.add(error));
        await done.future.timeout(const Duration(seconds: 10));
        await _turn();
        client.close(force: true);
        return errors;
      }

      // dart:io's response drops it.
      expect(await unhandled(_Plain()), isEmpty);
      expect(await unhandled(TracewayHttpOverrides(null)), isEmpty);
      expect((await _spansTo(h, '/unhandled')).single.status.name, 'Error');
    });

    test('cancelling the body ends the request once, as completed', () async {
      final h = await startHarness();
      final fake = _FakeResponse(contentLength: 100);
      final response = await _throughSdk(fake);
      final subscription = response.listen((_) {});
      fake.body.add([1, 2, 3]);
      await _turn();
      await subscription.cancel();
      await subscription.cancel();
      expect(fake.log, ['cancel']);
      final span = (await _spans(h)).single;
      expect(span.status.name, isNot('Error'));
      expect(_attr(span, 'error.type'), isNull);
      expect(_attr(span, 'http.response.body.size'), 3);
    });

    test('a body nobody reads still ends, at its headers', () async {
      ObservedResponseBody.unreadTimeout = const Duration(milliseconds: 500);
      final h = await startHarness();
      final fake = _FakeResponse(contentLength: 42);
      final response = await _throughSdk(fake);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await _spans(h), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final span = (await _spans(h)).single;
      expect(_duration(span), lessThan(const Duration(milliseconds: 500)));
      expect(_attr(span, 'http.response.body.size'), 42);
      // Read late, the body is all there, and not recorded again.
      final read = response.toList();
      fake.body
        ..add([7])
        ..close();
      expect(await read, [
        [7]
      ]);
      expect(await _spans(h), hasLength(1));
    });

    test('the response is the one dart:io gave, member for member', () async {
      final h = await startHarness();
      final fake = _FakeResponse(contentLength: 12);
      late HttpClientRequest request;
      final response = await HttpOverrides.runWithHttpOverrides(() async {
        request = await HttpClient()
            .getUrl(Uri.parse('https://api.example.com/fake'));
        return request.close();
      }, TracewayHttpOverrides(_Fake(fake)));
      expect(response, isNot(same(fake)));
      expect(await request.done, same(response));
      expect(response.statusCode, 200);
      expect(response.reasonPhrase, 'OK, fake');
      expect(response.contentLength, 12);
      expect(response.compressionState,
          HttpClientResponseCompressionState.notCompressed);
      expect(response.persistentConnection, isFalse);
      expect(response.isRedirect, isFalse);
      expect(response.redirects, same(fake.redirects));
      expect(response.headers, same(fake.headers));
      expect(response.cookies, same(fake.cookies));
      expect(response.certificate, isNull);
      expect(response.connectionInfo, isNull);
      expect(response.isBroadcast, isFalse);
      final next = Uri.parse('https://api.example.com/next');
      expect(response.redirect('POST', next, true), same(fake.redirected));
      expect(response.detachSocket(), same(fake.socket));
      expect(fake.log, ['redirect POST $next true', 'detachSocket']);
      // Taking the socket ends the request.
      expect(_attr((await _spans(h)).single, 'http.response.body.size'), 12);
    });
  });

  group('package:http', () {
    test('get is measured to the end of the body it reads', () async {
      final h = await startHarness();
      final body = StreamController<List<int>>();
      final client = TracewayHttpClient(MockClient.streaming(
          (request, _) async => request.url.path == '/slow'
              ? http.StreamedResponse(body.stream, 200, contentLength: 9)
              : http.StreamedResponse(Stream.value(utf8.encode('{}')), 200)));
      final got = client.get(Uri.parse('https://api.example.com/slow'));
      body.add(utf8.encode('head-'));
      await Future<void>.delayed(_slow);
      expect(await _spans(h), isEmpty, reason: 'not over at its headers');
      body
        ..add(utf8.encode('tail'))
        ..close();
      expect((await got).body, 'head-tail');
      // The SDK's own requests are still left out.
      await client.get(Uri.parse('https://traceway.test/api/otel/v1/logs'));
      final span = (await _spans(h)).single;
      expect(_attr(span, 'url.full'), 'https://api.example.com/slow');
      expect(_duration(span), greaterThanOrEqualTo(_slow));
      expect(_attr(span, 'http.response.status_code'), 200);
      expect(_attr(span, 'http.response.body.size'), 9);
    });

    test('send is measured to the end of the stream it gives', () async {
      final release = Completer<void>();
      final server = await _slowServer(release.future);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final h = await startHarness();
      await HttpOverrides.runWithHttpOverrides(() async {
        // Over dart:io, which the overrides would record too.
        final client = TracewayHttpClient();
        final response =
            await client.send(http.Request('GET', Uri.parse('$base/moved')));
        // As the inner client gave it.
        expect(response, isA<IOStreamedResponse>());
        expect((response as http.BaseResponseWithUrl).url.path, '/slow');
        expect(response.statusCode, 200);
        expect(response.request?.url.path, '/moved');
        expect(response.headers['transfer-encoding'], 'chunked');
        final text = response.stream.bytesToString();
        await Future<void>.delayed(_slow);
        expect(await _spans(h), isEmpty, reason: 'not over at its headers');
        release.complete();
        expect(await text, 'head-tail');
        client.close();
      }, TracewayHttpOverrides(null));
      final span = (await _spans(h)).single;
      expect(_attr(span, 'url.full'), '$base/moved');
      expect(_duration(span), greaterThanOrEqualTo(_slow));
      expect(_attr(span, 'http.response.body.size'), 9);
    });

    test('a body that fails fails the request; the app gets the error',
        () async {
      final h = await startHarness();
      final body = StreamController<List<int>>();
      final client = TracewayHttpClient(MockClient.streaming(
          (request, _) async => http.StreamedResponse(body.stream, 200)));
      final response = await client
          .send(http.Request('GET', Uri.parse('https://api.example.com/cut')));
      final error = http.ClientException('Connection reset by peer');
      final trace = StackTrace.current;
      final seen = <Object>[];
      final done = Completer<void>();
      response.stream.listen(seen.add,
          onError: (Object e, StackTrace s) => seen
            ..add(e)
            ..add(s),
          onDone: done.complete);
      body
        ..add([1, 2, 3])
        ..addError(error, trace)
        ..close();
      await done.future;
      expect(seen, hasLength(3));
      expect(seen[1], same(error));
      expect(seen[2], same(trace));
      final span = (await _spans(h)).single;
      expect(span.status.name, 'Error');
      expect(_attr(span, 'error.type'), '$error');
      expect(_attr(span, 'http.response.status_code'), 200);
      expect(_attr(span, 'http.response.body.size'), 3);
    });

    test('an error the app has no handler for goes where it would have',
        () async {
      final h = await startHarness();
      final error = http.ClientException('Connection reset by peer');
      http.Client failing() => MockClient.streaming((request, _) async =>
          http.StreamedResponse(Stream<List<int>>.error(error), 200));

      /// The errors left to the zone while [client] reads with no handler.
      Future<List<Object>> unhandled(http.Client client) async {
        final errors = <Object>[];
        final done = Completer<void>();
        runZonedGuarded(() async {
          final response = await client.send(
              http.Request('GET', Uri.parse('https://api.example.com/fails')));
          response.stream.listen(null, onDone: done.complete);
        }, (error, _) => errors.add(error));
        await done.future;
        await _turn();
        return errors;
      }

      // A plain stream hands it to its zone.
      expect(await unhandled(failing()), [same(error)]);
      expect(await unhandled(TracewayHttpClient(failing())), [same(error)]);
      expect((await _spans(h)).single.status.name, 'Error');
    });

    test('a body nobody reads still ends, at its headers', () async {
      ObservedResponseBody.unreadTimeout = const Duration(milliseconds: 500);
      final h = await startHarness();
      final client = TracewayHttpClient(MockClient.streaming(
          (request, _) async => http.StreamedResponse(
              const Stream<List<int>>.empty(), 200,
              contentLength: 5)));
      await client.send(
          http.Request('GET', Uri.parse('https://api.example.com/unread')));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final span = (await _spans(h)).single;
      expect(_duration(span), lessThan(const Duration(milliseconds: 500)));
      expect(_attr(span, 'http.response.body.size'), 5);
    });
  });
}
