import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../traceway_client.dart';
import 'traceway_event.dart';

/// Installs a global [HttpOverrides] that wraps every dart:io [HttpClient] so
/// every HTTP call gets recorded as a [NetworkEvent].
///
/// Captures `package:http`, Dio, Firebase, and any other library that sits on
/// dart:io HttpClient on native platforms. Has no effect on Flutter web —
/// use [TracewayHttpClient] there.
class TracewayHttpOverrides extends HttpOverrides {
  TracewayHttpOverrides(this._previous);

  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _TracewayHttpClient(inner);
  }
}

void _emit({
  required String method,
  required Uri url,
  required DateTime start,
  int? statusCode,
  int? requestBytes,
  int? responseBytes,
  String? error,
}) {
  try {
    TracewayClient.instance?.recordNetworkEvent(NetworkEvent(
      method: method.toUpperCase(),
      url: url.toString(),
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

class _TracewayHttpClient implements HttpClient {
  _TracewayHttpClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final start = DateTime.now();
    try {
      final req = await _inner.openUrl(method, url);
      return _TracewayHttpClientRequest(req, method, url, start);
    } catch (e) {
      _emit(method: method, url: url, start: start, error: e.toString());
      rethrow;
    }
  }

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _TracewayHttpClientRequest implements HttpClientRequest {
  _TracewayHttpClientRequest(this._inner, this._method, this._url, this._start);

  final HttpClientRequest _inner;
  final String _method;
  final Uri _url;
  final DateTime _start;
  int _bytesWritten = 0;
  bool _emitted = false;

  void _emitOnce({
    int? statusCode,
    int? responseBytes,
    String? error,
  }) {
    if (_emitted) return;
    _emitted = true;
    _emit(
      method: _method,
      url: _url,
      start: _start,
      statusCode: statusCode,
      requestBytes: _bytesWritten > 0 ? _bytesWritten : null,
      responseBytes: responseBytes,
      error: error,
    );
  }

  @override
  Future<HttpClientResponse> close() async {
    try {
      final res = await _inner.close();
      final responseBytes = res.contentLength >= 0 ? res.contentLength : null;
      _emitOnce(statusCode: res.statusCode, responseBytes: responseBytes);
      return res;
    } catch (e) {
      _emitOnce(error: e.toString());
      rethrow;
    }
  }

  @override
  Future<HttpClientResponse> get done => _inner.done;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _emitOnce(error: (exception ?? 'aborted').toString());
    _inner.abort(exception, stackTrace);
  }

  @override
  void add(List<int> data) {
    _bytesWritten += data.length;
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    return _inner.addStream(stream.map((chunk) {
      _bytesWritten += chunk.length;
      return chunk;
    }));
  }

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) {
    final s = object?.toString() ?? '';
    _bytesWritten += utf8.encode(s).length;
    _inner.write(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    final s = objects.map((o) => o.toString()).join(separator);
    _bytesWritten += utf8.encode(s).length;
    _inner.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _bytesWritten += 1;
    _inner.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    final s = '${object?.toString() ?? ''}\n';
    _bytesWritten += utf8.encode(s).length;
    _inner.writeln(object);
  }

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;
}
