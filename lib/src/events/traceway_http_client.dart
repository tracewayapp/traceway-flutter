import 'package:http/http.dart' as http;

import '../traceway_client.dart';
import 'traceway_event.dart';

/// A drop-in [http.Client] that records every request as a [NetworkEvent].
///
/// Use this on Flutter web (where [HttpOverrides] does not apply) or whenever
/// you want to wire the SDK into an explicit `http.Client` instance — e.g.
/// `Dio()..httpClientAdapter = ...` or libraries that take a custom client.
class TracewayHttpClient extends http.BaseClient {
  TracewayHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final start = DateTime.now();
    final requestBytes = request.contentLength;
    try {
      final response = await _inner.send(request);
      _emit(
        request: request,
        start: start,
        statusCode: response.statusCode,
        requestBytes: requestBytes,
        responseBytes: response.contentLength,
      );
      return response;
    } catch (e) {
      _emit(
        request: request,
        start: start,
        requestBytes: requestBytes,
        error: e.toString(),
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
