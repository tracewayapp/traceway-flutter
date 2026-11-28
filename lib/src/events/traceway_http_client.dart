import 'dart:async';
import 'dart:io' show Socket;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOStreamedResponse;

import '../guarded.dart';
import '../traceway_client.dart';
import 'network_capture.dart'
    show ObservedResponseBody, recordedByTracewayHttpClient;
import 'traceway_event.dart';

/// A drop-in [http.Client] that records every request as a [NetworkEvent].
///
/// Use this for clients that do not go through dart:io (`cupertino_http`,
/// `cronet_http`), or whenever
/// you want to wire the SDK into an explicit `http.Client` instance — e.g.
/// `Dio()..httpClientAdapter = ...` or libraries that take a custom client.
///
/// A request is over when its response body is: see [ObservedResponseBody].
class TracewayHttpClient extends http.BaseClient {
  TracewayHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final start = DateTime.now();
    final requestBytes = request.contentLength;
    String? traceparent;
    try {
      // The app's own trace context wins.
      if (!request.headers.keys.any((k) => k.toLowerCase() == 'traceparent')) {
        traceparent = TracewayClient.instance
            ?.traceparentFor(request.method, request.url, startTime: start);
        if (traceparent != null) request.headers['traceparent'] = traceparent;
      }
    } catch (_) {
      traceparent = null;
    }
    final http.StreamedResponse response;
    try {
      // A dart:io client underneath is not recorded a second time.
      response = await runZoned(() => _inner.send(request),
          zoneValues: {recordedByTracewayHttpClient: true});
    } catch (e) {
      _emit(
        request: request,
        start: start,
        requestBytes: requestBytes,
        error: safeToString(e),
        traceparent: traceparent,
      );
      rethrow;
    }
    final body = ObservedResponseBody(
      response.stream,
      contentLength: response.contentLength,
      decoded: response.headers.entries.any((h) =>
          h.key.toLowerCase() == 'content-encoding' &&
          h.value.trim().toLowerCase() != 'identity'),
      dropUnhandledErrors: false,
      onEnd: (end, responseBytes, error) => _emit(
        request: request,
        start: start,
        end: end,
        statusCode: response.statusCode,
        requestBytes: requestBytes,
        responseBytes: responseBytes,
        error: error == null ? null : safeToString(error),
        traceparent: traceparent,
      ),
    );
    final url = switch (response) {
      http.BaseResponseWithUrl(:final url) => url,
      _ => null,
    };
    if (response is IOStreamedResponse) {
      return url == null
          ? _ObservedIOResponse(body, response)
          : _ObservedIOResponseWithUrl(body, response, url);
    }
    return url == null
        ? _ObservedResponse(body, response)
        : _ObservedResponseWithUrl(body, response, url);
  }

  void _emit({
    required http.BaseRequest request,
    required DateTime start,
    DateTime? end,
    int? statusCode,
    int? requestBytes,
    int? responseBytes,
    String? error,
    String? traceparent,
  }) {
    try {
      final at = end ?? DateTime.now();
      TracewayClient.instance?.recordNetworkEvent(NetworkEvent(
        method: request.method.toUpperCase(),
        url: request.url.toString(),
        duration: at.difference(start),
        statusCode: statusCode,
        requestBytes: requestBytes,
        responseBytes: responseBytes,
        error: error,
        traceparent: traceparent,
        timestamp: at,
      ));
    } catch (_) {
      // Never let event recording break the host app's networking.
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

// The response the inner client gave, its body observed. The same kind:
// with its final `url` when it had one, its socket when it was dart:io's.

class _ObservedResponse extends http.StreamedResponse {
  _ObservedResponse(ObservedResponseBody body, http.StreamedResponse response)
      : super(body, response.statusCode,
            contentLength: response.contentLength,
            request: response.request,
            headers: response.headers,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase);
}

class _ObservedResponseWithUrl extends _ObservedResponse
    implements http.BaseResponseWithUrl {
  _ObservedResponseWithUrl(super.body, super.response, this.url);

  @override
  final Uri url;
}

class _ObservedIOResponse extends IOStreamedResponse {
  _ObservedIOResponse(this._body, this._response)
      : super(_body, _response.statusCode,
            contentLength: _response.contentLength,
            request: _response.request,
            headers: _response.headers,
            isRedirect: _response.isRedirect,
            persistentConnection: _response.persistentConnection,
            reasonPhrase: _response.reasonPhrase);

  final ObservedResponseBody _body;
  final IOStreamedResponse _response;

  /// The app takes the socket: the HTTP exchange is over.
  @override
  Future<Socket> detachSocket() {
    _body.end();
    return _response.detachSocket();
  }
}

class _ObservedIOResponseWithUrl extends _ObservedIOResponse
    implements http.BaseResponseWithUrl {
  _ObservedIOResponseWithUrl(super.body, super.response, this.url);

  @override
  final Uri url;
}
