import 'dart:async';

import 'package:http/http.dart' as http;

import '../traceway_client.dart';
import 'network_capture.dart' show recordedByTracewayHttpClient;
import 'traceway_event.dart';

/// A drop-in [http.Client] that records every request as a [NetworkEvent].
///
/// Use this for clients that do not go through dart:io (`cupertino_http`,
/// `cronet_http`), or whenever
/// you want to wire the SDK into an explicit `http.Client` instance — e.g.
/// `Dio()..httpClientAdapter = ...` or libraries that take a custom client.
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
    try {
      // A dart:io client underneath is not recorded a second time.
      final response = await runZoned(() => _inner.send(request),
          zoneValues: {recordedByTracewayHttpClient: true});
      _emit(
        request: request,
        start: start,
        statusCode: response.statusCode,
        requestBytes: requestBytes,
        responseBytes: response.contentLength,
        traceparent: traceparent,
      );
      return response;
    } catch (e) {
      _emit(
        request: request,
        start: start,
        requestBytes: requestBytes,
        error: e.toString(),
        traceparent: traceparent,
      );
      rethrow;
    }
  }

  void _emit({
    required http.BaseRequest request,
    required DateTime start,
    int? statusCode,
    int? requestBytes,
    int? responseBytes,
    String? error,
    String? traceparent,
  }) {
    try {
      TracewayClient.instance?.recordNetworkEvent(NetworkEvent(
        method: request.method.toUpperCase(),
        url: request.url.toString(),
        duration: DateTime.now().difference(start),
        statusCode: statusCode,
        requestBytes: requestBytes,
        responseBytes: responseBytes,
        error: error,
        traceparent: traceparent,
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
