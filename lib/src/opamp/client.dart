import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/ids.dart';
import 'messages.dart';

/// Result of applying a remote config; `null` [errorMessage] means applied.
class ApplyResult {
  const ApplyResult.applied() : errorMessage = null;
  const ApplyResult.failed(String this.errorMessage);
  final String? errorMessage;
  bool get applied => errorMessage == null;
}

const int _minPollIntervalMs = 30000;
const int _maxBackoffMs = 30 * 60000;
const int _firstBackoffMs = 30000;

bool _sameBytes(Uint8List? a, Uint8List? b) {
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// An OpAMP client for the plain-HTTP transport: it polls, applies the remote
/// config the server offers and reports the result on the next poll. Polling
/// follows the server's heartbeat interval, backs off on errors and honours
/// Retry-After; a 413 is not retried and a 401/403/404 stops the client.
class OpampHttpClient {
  OpampHttpClient({
    required this.endpoint,
    this.headers = const {},
    required Uint8List instanceUid,
    required this.capabilities,
    this.customCapabilities = const [],
    required this.describe,
    required this.onRemoteConfig,
    Uint8List? appliedConfigHash,
    this.onInstanceUidChange,
    this.onStopped,
    int defaultPollIntervalMs = 300000,
    int minPollIntervalMs = _minPollIntervalMs,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 10),
  })  : _uid = instanceUid,
        _minIntervalMs = minPollIntervalMs,
        _intervalMs = defaultPollIntervalMs < minPollIntervalMs
            ? minPollIntervalMs
            : defaultPollIntervalMs,
        _http = httpClient ?? http.Client() {
    if (appliedConfigHash != null && appliedConfigHash.isNotEmpty) {
      _status = RemoteConfigStatus(
        lastRemoteConfigHash: appliedConfigHash,
        status: RemoteConfigStatuses.applied,
      );
    }
  }

  /// The server's OpAMP endpoint, e.g. https://host/api/otel/v1/opamp.
  final String endpoint;
  final Map<String, String> headers;
  final int capabilities;
  final List<String> customCapabilities;

  /// Read on every poll: the client sends its full state each time, so a
  /// stateless server can answer.
  final AgentDescription Function() describe;
  final ApplyResult Function(RemoteConfig config) onRemoteConfig;
  final void Function(Uint8List uid)? onInstanceUidChange;

  /// Called once with the HTTP status when the server rejects the client for
  /// good (bad credentials or no OpAMP support).
  final void Function(int statusCode)? onStopped;
  final Duration requestTimeout;

  final http.Client _http;
  final int _minIntervalMs;
  Uint8List _uid;
  int _sequenceNum = 0;
  RemoteConfigStatus? _status;
  int _intervalMs;
  int _backoffMs = 0;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _stopped = true;

  int get pollIntervalMs => _intervalMs;
  bool get isRunning => !_stopped;
  Uint8List get instanceUid => _uid;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    unawaited(poll());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Polls now unless a poll is running or the client is backing off after
  /// an error.
  Future<void> poll() {
    if (_stopped) return Future.value();
    final running = _inFlight;
    if (running != null) return running;
    if (_backoffMs > 0 && _timer != null) return Future.value();
    _timer?.cancel();
    _timer = null;
    final future = _exchange().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// Polls with the current description even if a poll is under way, e.g.
  /// right after a targeting attribute changed.
  Future<void> refresh() async {
    final running = _inFlight;
    if (running != null) await running;
    await poll();
  }

  void _schedule(int delayMs) {
    if (_stopped) return;
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: delayMs), () {
      _timer = null;
      unawaited(poll());
    });
  }

  Future<void> _exchange() async {
    http.Response response;
    try {
      final body = encodeAgentToServer(AgentToServer(
        instanceUid: _uid,
        sequenceNum: _sequenceNum++,
        agentDescription: describe(),
        capabilities: capabilities,
        remoteConfigStatus: _status,
        customCapabilities: customCapabilities,
      ));
      response = await _http
          .post(
            Uri.parse(endpoint),
            headers: {
              ...headers,
              'Content-Type': 'application/x-protobuf',
              'OpAMP-Instance-UID': bytesToUuid(_uid),
            },
            body: body,
          )
          .timeout(requestTimeout);
    } catch (_) {
      _backOff(null);
      return;
    }

    final code = response.statusCode;
    if (code == 401 || code == 403 || code == 404 || code == 405 || code == 501) {
      stop();
      onStopped?.call(code);
      return;
    }
    if (code == 413) {
      _backoffMs = 0;
      _schedule(_intervalMs);
      return;
    }
    ServerToAgent? message;
    try {
      message = decodeServerToAgent(response.bodyBytes);
    } catch (_) {
      message = null;
    }
    if (code == 429 ||
        code >= 500 ||
        message?.errorResponse?.type == ServerErrorTypes.unavailable) {
      final header = int.tryParse(response.headers['retry-after'] ?? '');
      final retryAfter = header != null && header > 0
          ? header * 1000
          : message?.errorResponse?.retryAfterMs;
      _backOff(retryAfter);
      return;
    }
    if (code < 200 || code >= 300 || message == null) {
      _backOff(null);
      return;
    }
    if (_stopped) return;
    _backoffMs = 0;
    _handle(message);
  }

  void _handle(ServerToAgent message) {
    final newUid = message.newInstanceUid;
    if (newUid != null && newUid.length == 16) {
      _uid = newUid;
      onInstanceUidChange?.call(newUid);
    }
    final heartbeat = message.heartbeatIntervalSeconds;
    if (heartbeat != null && heartbeat > 0) {
      final next = heartbeat * 1000;
      _intervalMs = next < _minIntervalMs ? _minIntervalMs : next;
    }

    var reportNow = false;
    final config = message.remoteConfig;
    if (config != null &&
        !_sameBytes(config.configHash, _status?.lastRemoteConfigHash)) {
      ApplyResult result;
      try {
        result = onRemoteConfig(config);
      } catch (e) {
        result = ApplyResult.failed('$e');
      }
      _status = RemoteConfigStatus(
        lastRemoteConfigHash: config.configHash,
        status: result.applied
            ? RemoteConfigStatuses.applied
            : RemoteConfigStatuses.failed,
        errorMessage: result.errorMessage,
      );
      reportNow = true;
    }
    // The server answers a poll it cannot evaluate with ReportFullState; this
    // client always sends its full state, so it only needs to poll again. A
    // freshly applied config is reported straight away for the same reason.
    if (reportNow || (message.flags & serverFlagReportFullState) != 0) {
      _schedule(0);
      return;
    }
    _schedule(_intervalMs);
  }

  void _backOff(int? retryAfterMs) {
    _backoffMs = retryAfterMs ??
        (_backoffMs > 0
            ? (_backoffMs * 2 > _maxBackoffMs ? _maxBackoffMs : _backoffMs * 2)
            : _firstBackoffMs);
    _schedule(_backoffMs < 1000 ? 1000 : _backoffMs);
  }
}
