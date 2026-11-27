import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../guarded.dart';
import '../traceway_client.dart';
import 'traceway_event.dart';

/// Set in the zone of a request `TracewayHttpClient` records: the dart:io
/// layer under it must not record it, or set another `traceparent`, again.
const Object recordedByTracewayHttpClient = #tracewayRecordedRequest;

/// Installs a global [HttpOverrides] that wraps every dart:io [HttpClient] so
/// every HTTP call gets recorded as a [NetworkEvent].
///
/// Captures `package:http`, Dio, Firebase, and any other library that sits on
/// dart:io HttpClient. A request a `TracewayHttpClient` already records is
/// left to it, so it is recorded once. A request is over when its response
/// body is: see [ObservedResponseBody].
///
/// Everything else is the app's previous override's, or dart:io's default:
/// proxies ([findProxyFromEnvironment]), certificates and the client the
/// previous override creates.
class TracewayHttpOverrides extends HttpOverrides {
  TracewayHttpOverrides(this._previous);

  final HttpOverrides? _previous;

  @visibleForTesting
  HttpOverrides? get previousForTest => _previous;

  static bool _installed = false;

  /// Makes this the global override, wrapping the current one; once per
  /// process, so a request is never recorded twice.
  static void install() {
    if (_installed) return;
    _installed = true;
    HttpOverrides.global = TracewayHttpOverrides(HttpOverrides.current);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _TracewayHttpClient(inner);
  }

  /// dart:io asks the current override which proxy a request takes: the
  /// app's previous one still decides.
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    final previous = _previous;
    return previous != null
        ? previous.findProxyFromEnvironment(url, environment)
        : super.findProxyFromEnvironment(url, environment);
  }
}

/// Records a request that ended at [end], now when not given.
void _emit({
  required String method,
  required Uri url,
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
      method: method.toUpperCase(),
      url: url.toString(),
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

/// A response body, unchanged for the app, that tells [onEnd] once when its
/// request is over:
///
/// * read to its end;
/// * failed: the request failed, whatever its status, and the app still gets
///   the error;
/// * cancelled by the app: recorded as completed with the bytes read so far,
///   not as a failure — the app stopped reading, the network did not fail;
/// * never listened to within [unreadTimeout] of its headers: ended at its
///   headers, with its Content-Length, so a body the app ignores is still
///   recorded (as it was before bodies were watched);
/// * or by [end] when its owner knows better (the app took the socket).
///
/// The size is the bytes the app read, or the Content-Length when it read
/// none. A body the client [decoded] keeps its Content-Length: the bytes on
/// the wire, not the decoded ones.
class ObservedResponseBody extends Stream<List<int>> {
  ObservedResponseBody(
    this._source, {
    required int? contentLength,
    required bool decoded,
    required bool dropUnhandledErrors,
    required void Function(DateTime end, int? responseBytes, Object? error)
        onEnd,
  })  : _contentLength = contentLength,
        _decoded = decoded,
        _dropUnhandledErrors = dropUnhandledErrors,
        _onEnd = onEnd {
    _unread = Timer(unreadTimeout, () => end(at: _headersAt));
  }

  /// How long a body may wait for its first listener before its request is
  /// ended at its headers.
  @visibleForTesting
  static Duration unreadTimeout = const Duration(seconds: 10);

  final Stream<List<int>> _source;
  final int? _contentLength;
  final bool _decoded;

  /// What [_source] does with an error the app has no handler for: dart:io's
  /// response drops it, any other stream hands it to its zone.
  final bool _dropUnhandledErrors;
  final void Function(DateTime end, int? responseBytes, Object? error) _onEnd;
  final DateTime _headersAt = DateTime.now();
  Timer? _unread;
  bool _listened = false;
  bool _ended = false;
  int _received = 0;

  @override
  bool get isBroadcast => _source.isBroadcast;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    if (_listened || _ended) {
      // Nothing left to watch: a second listen fails the way the body's own
      // does.
      return _source.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    }
    _listened = true;
    try {
      final subscription =
          _BodySubscription(this, onData, onError, onDone, cancelOnError);
      _unread?.cancel();
      _unread = null;
      return subscription;
    } catch (_) {
      _listened = false;
      rethrow;
    }
  }

  /// Ends the request, at [at] or now; an [error] fails it. Only once.
  void end({DateTime? at, Object? error}) {
    if (_ended) return;
    _ended = true;
    _unread?.cancel();
    _unread = null;
    final contentLength = _contentLength;
    final bytes = !_listened || (_decoded && contentLength != null)
        ? contentLength
        : _received;
    try {
      _onEnd(at ?? DateTime.now(), bytes, error);
    } catch (_) {
      // Never let event recording break the host app's networking.
    }
  }
}

/// The app's subscription to an [ObservedResponseBody]: the body's own,
/// with every event passed through as it came.
class _BodySubscription implements StreamSubscription<List<int>> {
  _BodySubscription(this._observed, this._onData, this._onError, this._onDone,
      bool? cancelOnError)
      : _dropUnhandled = _observed._dropUnhandledErrors {
    _inner = _observed._source.listen(_data,
        onError: _error, onDone: _done, cancelOnError: cancelOnError);
  }

  final ObservedResponseBody _observed;
  late final StreamSubscription<List<int>> _inner;
  void Function(List<int> data)? _onData;
  Function? _onError;
  void Function()? _onDone;
  bool _dropUnhandled;

  void _data(List<int> data) {
    _observed._received += data.length;
    _onData?.call(data);
  }

  void _error(Object error, StackTrace stackTrace) {
    _observed.end(error: error);
    final handler = _onError;
    if (handler == null) {
      if (!_dropUnhandled) Zone.current.handleUncaughtError(error, stackTrace);
    } else if (handler is void Function(Object, StackTrace)) {
      handler(error, stackTrace);
    } else {
      (handler as void Function(Object))(error);
    }
  }

  void _done() {
    _observed.end();
    _onDone?.call();
  }

  @override
  void onData(void Function(List<int> data)? handleData) =>
      _onData = handleData;

  @override
  void onError(Function? handleError) {
    // A handler taken away later leaves the error unhandled, on any stream.
    _dropUnhandled = false;
    _onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) => _onDone = handleDone;

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<void> cancel() {
    _observed.end();
    return _inner.cancel();
  }

  /// As a stream's own: it takes over the done and error handlers, and an
  /// error cancels the subscription.
  @override
  Future<E> asFuture<E>([E? futureValue]) {
    if (futureValue == null && null is! E) {
      throw ArgumentError.notNull('futureValue');
    }
    final result = Completer<E>();
    _onDone = () => result.complete(futureValue as E);
    _onError = (Object error, StackTrace stackTrace) =>
        cancel().whenComplete(() => result.completeError(error, stackTrace));
    return result.future;
  }
}

/// The [HttpClientResponse] dart:io gave, its body an [ObservedResponseBody].
class _ObservedHttpClientResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _ObservedHttpClientResponse(this._inner, ObservedResponseBody body)
      : _body = body,
        super(body);

  final HttpClientResponse _inner;
  final ObservedResponseBody _body;

  @override
  int get statusCode => _inner.statusCode;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  int get contentLength => _inner.contentLength;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);

  @override
  HttpHeaders get headers => _inner.headers;

  /// The app takes the socket: the HTTP exchange is over.
  @override
  Future<Socket> detachSocket() {
    _body.end();
    return _inner.detachSocket();
  }

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
}

class _TracewayHttpClient implements HttpClient {
  _TracewayHttpClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (Zone.current[recordedByTracewayHttpClient] == true) {
      return _inner.openUrl(method, url);
    }
    final start = DateTime.now();
    try {
      final req = await _inner.openUrl(method, url);
      String? traceparent;
      try {
        // The app's own trace context wins.
        if (req.headers.value('traceparent') == null) {
          traceparent = TracewayClient.instance
              ?.traceparentFor(method, url, startTime: start);
          if (traceparent != null) req.headers.set('traceparent', traceparent);
        }
      } catch (_) {
        traceparent = null;
      }
      return _TracewayHttpClientRequest(req, method, url, start, traceparent);
    } catch (e) {
      _emit(method: method, url: url, start: start, error: safeToString(e));
      rethrow;
    }
  }

  /// [path] may carry a query and a fragment, read the way dart:io's own
  /// `open` reads them.
  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) {
    var fragmentStart = path.length;
    var queryStart = path.length;
    for (var i = path.length - 1; i >= 0; i--) {
      final char = path.codeUnitAt(i);
      if (char == 0x23 /* # */) {
        fragmentStart = i;
        queryStart = i;
      } else if (char == 0x3f /* ? */) {
        queryStart = i;
      }
    }
    String? query;
    if (queryStart < fragmentStart) {
      query = path.substring(queryStart + 1, fragmentStart);
      path = path.substring(0, queryStart);
    }
    return openUrl(
        method,
        Uri(scheme: 'http', host: host, port: port, path: path, query: query));
  }

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
  _TracewayHttpClientRequest(
      this._inner, this._method, this._url, this._start, this._traceparent);

  final HttpClientRequest _inner;
  final String _method;
  final Uri _url;
  final DateTime _start;
  String? _traceparent;
  int _bytesWritten = 0;
  bool _emitted = false;

  /// The app may set its own `traceparent` after the request was opened:
  /// its trace context wins, and the request's span is recorded as if none
  /// had been sent.
  void _yieldToAppTraceparent() {
    final ours = _traceparent;
    if (ours == null) return;
    try {
      final values = _inner.headers['traceparent'];
      if (values == null || (values.length == 1 && values.single == ours)) {
        return;
      }
      final theirs = values.where((v) => v != ours).toList();
      if (theirs.isEmpty) {
        _inner.headers.removeAll('traceparent');
      } else {
        _inner.headers.set('traceparent', theirs.first);
      }
      TracewayClient.instance?.forgetRequestSpan(ours);
      _traceparent = null;
    } catch (_) {}
  }

  void _emitOnce({
    DateTime? end,
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
      end: end,
      traceparent: _traceparent,
      statusCode: statusCode,
      requestBytes: _bytesWritten > 0 ? _bytesWritten : null,
      responseBytes: responseBytes,
      error: error,
    );
  }

  /// The response [close] gave, which [done] gives too.
  Future<HttpClientResponse>? _response;

  @override
  Future<HttpClientResponse> close() {
    _yieldToAppTraceparent();
    final response = _inner.close();
    final observed = _response;
    if (observed != null) {
      // Closed again: the response is the one already given.
      response.ignore();
      return observed;
    }
    return _response = _observe(response);
  }

  /// The request ends with its response body, not its headers.
  Future<HttpClientResponse> _observe(
      Future<HttpClientResponse> response) async {
    try {
      final res = await response;
      return _ObservedHttpClientResponse(
        res,
        ObservedResponseBody(
          res,
          contentLength: res.contentLength >= 0 ? res.contentLength : null,
          decoded: res.compressionState ==
              HttpClientResponseCompressionState.decompressed,
          dropUnhandledErrors: true,
          onEnd: (end, responseBytes, error) => _emitOnce(
            end: end,
            statusCode: res.statusCode,
            responseBytes: responseBytes,
            error: error == null ? null : safeToString(error),
          ),
        ),
      );
    } catch (e) {
      _emitOnce(error: safeToString(e));
      rethrow;
    }
  }

  @override
  Future<HttpClientResponse> get done => _response ?? _inner.done;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _emitOnce(error: safeToString(exception ?? 'aborted'));
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
