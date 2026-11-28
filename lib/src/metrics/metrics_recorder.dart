import 'dart:async';
import 'dart:math';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:fixnum/fixnum.dart';

import '../core/control_state.dart';
import '../core/ids.dart';
import '../guarded.dart';
import '../persistence/state_store.dart';
import 'aggregator.dart';
import 'otlp.dart';
import 'pending_metrics.dart';

const String metricAppStart = 'app.start.duration';
const String metricScreenTtid = 'app.screen.ttid';
const String metricScreenTtfd = 'app.screen.ttfd';
const String metricFramesSlow = 'app.frames.slow';
const String metricFramesFrozen = 'app.frames.frozen';
const String metricHang = 'app.hang';
const String metricHangDuration = 'app.hang.duration';
const String metricCrash = 'app.crash';
const String metricSession = 'app.session';
const String metricUser = 'app.user';
const String metricUserAffected = 'app.user.affected';
const String metricMemoryPeak = 'app.memory.peak';
const String metricRequestDuration = 'app.request.duration';
const String metricRequestBytes = 'app.request.bytes';
const String metricRequestFailed = 'app.request.failed';

/// Things that went wrong for a user, counted once per user and day. The
/// server accepts exactly these (`app.user.affected` in its catalog).
enum UserIssue { crash, hang, slowStart, frozenFrames, failedRequest }

const Map<UserIssue, String> _issueNames = {
  UserIssue.crash: 'crash',
  UserIssue.hang: 'hang',
  UserIssue.slowStart: 'slow_start',
  UserIssue.frozenFrames: 'frozen_frames',
  UserIssue.failedRequest: 'failed_request',
};

/// The device facts the server keeps as dimensions. Nothing that identifies
/// a user or a device.
const List<String> metricResourceKeys = [
  'service.name',
  'service.version',
  'deployment.environment.name',
  'os.name',
  'os.major',
  'device.form_factor',
  'device.class',
  'traceway.sdk.name',
  'traceway.sdk.version',
];

const int _maxBodyBytes = 60 * 1024;
const int _maxHosts = 20;
const int _maxCustomDimensions = 2;
const int _maxDimensionLength = 64;
const String _defaultUserKey = 'metricsUser';
const int _dayMs = 86400000;

/// Rejections a second attempt would get too.
const List<int> _permanentStatuses = [400, 401, 403, 413, 422];
final RegExp _customName = RegExp(r'^[a-z][a-z0-9_.]{0,62}$');
final RegExp _reservedPrefix = RegExp(r'^(browser|app|traceway|custom)\.');
final RegExp _globalDimensionKey = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

/// One attempt to upload a protobuf body. Resolves with the HTTP status, 0
/// when no answer came.
typedef MetricsSend = Future<int> Function(List<int> body);

/// Turns measurements into device histograms and counters and uploads them
/// as one small OTLP payload per flush, like the browser SDK's
/// `MetricsRecorder`. The detailed events of the same measurements still go
/// through the router, where their signal's mode decides what leaves the
/// device: aggregates always travel, events only when asked for.
///
/// A payload gets one more attempt: one that failed, or that was sent as the
/// app went to the background, waits in the state store and is resent once,
/// after the next upload that works or on the next start. The server drops
/// a resend it already has by its batch id.
class MetricsRecorder {
  MetricsRecorder({
    required this.control,
    required this.sessionId,
    required this.installationId,
    required this.resource,
    required this.send,
    required this.store,
    required this.scopeName,
    required this.scopeVersion,
    Map<String, String>? dimensions,
    int Function()? now,
    Random? random,
    bool deferUntilStart = false,
    String storageScope = '',
  })  : _userKey = storageScope.isEmpty
            ? _defaultUserKey
            : '$_defaultUserKey:$storageScope',
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random.secure(),
        _ready = !deferUntilStart {
    _aggregator = MetricAggregator(now: _now);
    _pending = PendingMetrics(store, now: _now, scope: storageScope);
    _batchRate = control.metrics?.sampleRate ?? 0;
    dimensions?.forEach(setDimension);
  }

  final ControlState control;
  final String? Function() sessionId;
  final String Function() installationId;
  final Map<String, String> Function() resource;
  final MetricsSend send;
  final StateStore Function() store;
  final String scopeName;
  final String scopeVersion;

  /// Where the state kept between runs belongs: payloads waiting for a
  /// resend and the users counted today are kept per destination, so a
  /// changed receiver is not sent another's numbers.
  final String _userKey;
  final int Function() _now;
  final Random _random;

  /// Observations made before [start], while there is no session, no
  /// settings from disk and no installation id yet: the cold start, the
  /// first screen, an early error. They are recorded once it starts.
  bool _ready;
  final List<void Function()> _early = [];
  static const int _maxEarly = 64;

  late final MetricAggregator _aggregator;
  late final PendingMetrics _pending;
  final Set<String> _hosts = {};
  final Set<String> _inFlight = {};
  final Map<String, String> _dimensions = {};
  final Set<Future<void>> _uploads = {};
  Timer? _timer;
  String? _countedSession;
  String? _lastSession;

  /// The sample rate the cells collected so far were recorded under: a
  /// payload states one rate.
  late double _batchRate;
  ({int day, List<String> seen})? _userDay;

  /// Exposed for tests.
  MetricAggregator get aggregator => _aggregator;

  void start() {
    _ready = true;
    final early = List.of(_early);
    _early.clear();
    for (final observe in early) {
      observe();
    }
    _schedule();
    _resend();
    _user();
  }

  /// True when [observe] was kept for [start].
  bool _defer(void Function() observe) {
    if (_ready) return false;
    if (_early.length < _maxEarly) _early.add(observe);
    return true;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Remote settings changed: the flush interval may have, and the sample
  /// rate. What was recorded under the old rate is uploaded with it first,
  /// since the server weights a whole payload by the rate it states.
  void configure() {
    final rate = control.metrics?.sampleRate ?? 0;
    if (rate != _batchRate) {
      // Switched off means nothing more is sent, including what was measured.
      if (rate > 0) {
        _track(_upload(false));
      } else {
        _aggregator.drain();
      }
      _batchRate = rate;
    }
    if (_timer != null) _schedule();
  }

  /// The session's sample rate when it records metrics, else 0.
  double _rate([String? session]) {
    final settings = control.metrics;
    final id = session ?? (_lastSession = sessionId() ?? _lastSession);
    if (settings == null || id == null) return 0;
    return unitHash(id) < settings.sampleRate ? settings.sampleRate : 0;
  }

  bool get active => _rate() > 0;

  String? _exemplar(bool worthOpening) =>
      worthOpening ? (sessionId() ?? _lastSession) : null;

  /// An app-defined dimension on every metric from now on; null removes it.
  /// A third key is ignored.
  void setDimension(String key, String? value) {
    if (value == null) {
      _dimensions.remove(key);
      return;
    }
    if (!_globalDimensionKey.hasMatch(key) ||
        (!_dimensions.containsKey(key) &&
            _dimensions.length >= _maxCustomDimensions)) {
      return;
    }
    _dimensions[key] = _clip(value);
  }

  static String _clip(String value) => value.length > _maxDimensionLength
      ? value.substring(0, _maxDimensionLength)
      : value;

  /// Counts this installation once per UTC day, and once per day for each
  /// thing that went wrong for it, so "users affected" is a ratio of two
  /// counters and no id leaves the device. Without storage that outlives
  /// the run nothing is counted: every start would count the user again.
  /// Sampled by installation, not by session, so a user with many sessions
  /// is not more likely to be counted.
  void _user([UserIssue? issue]) {
    final settings = control.metrics;
    final storage = store();
    if (settings == null || !storage.persistent) return;
    if (unitHash(installationId()) >= settings.sampleRate) return;
    final day = _now() ~/ _dayMs;
    final wanted = [metricUser, if (issue != null) _issueNames[issue]!];
    final known = _userDay;
    if (known != null &&
        known.day == day &&
        wanted.every(known.seen.contains)) {
      return;
    }
    var seen = <String>[];
    final record = storage.get(_userKey);
    if (record is Map && record['d'] == day && record['i'] is List) {
      seen = [for (final i in record['i'] as List) '$i'];
    }
    final added = wanted.where((w) => !seen.contains(w)).toList();
    seen = [...seen, ...added];
    if (added.isNotEmpty) storage.set(_userKey, {'d': day, 'i': seen});
    _userDay = (day: day, seen: seen);
    for (final name in added) {
      if (name == metricUser) {
        _aggregator.count(metricUser);
      } else {
        _aggregator.count(metricUserAffected, 1, {'issue': name});
      }
    }
  }

  void sessionStarted(String id, {bool resumed = false}) {
    if (_defer(() => sessionStarted(id, resumed: resumed))) return;
    _user();
    if (_countedSession == id) return;
    if (resumed) {
      // An earlier run of the app counted it.
      _countedSession = id;
      return;
    }
    if (_rate(id) <= 0) return;
    _countedSession = id;
    _aggregator.count(metricSession);
  }

  /// [type] is `cold` or `hot`.
  void appStart(double ms, String type, {required bool slow}) {
    if (_defer(() => appStart(ms, type, slow: slow))) return;
    if (slow) _user(UserIssue.slowStart);
    if (!active) return;
    _aggregator.observe(metricAppStart, ms,
        dims: {'start_type': type},
        unit: 'ms',
        exemplarSession: _exemplar(slow || ms > _exemplarStartMs(type)));
  }

  static double _exemplarStartMs(String type) => type == 'cold' ? 2000 : 1000;

  void screenDisplayed(String screen, double ms) {
    if (_defer(() => screenDisplayed(screen, ms))) return;
    if (!active) return;
    _aggregator.observe(metricScreenTtid, ms,
        dims: {'screen': screen},
        unit: 'ms',
        exemplarSession: _exemplar(ms > 1000));
  }

  void screenFullyDisplayed(String screen, double ms) {
    if (_defer(() => screenFullyDisplayed(screen, ms))) return;
    if (!active) return;
    _aggregator.observe(metricScreenTtfd, ms,
        dims: {'screen': screen},
        unit: 'ms',
        exemplarSession: _exemplar(ms > 2000));
  }

  void frames(String? screen, int total, int slow, int frozen) {
    if (frozen > 0) _user(UserIssue.frozenFrames);
    if (total <= 0 || !active) return;
    final dims = {if (screen != null) 'screen': screen};
    _aggregator.ratio(
        metricFramesSlow, slow.toDouble(), total.toDouble(), dims);
    _aggregator.ratio(
        metricFramesFrozen, frozen.toDouble(), total.toDouble(), dims);
  }

  void hang(double ms, String? screen) {
    _user(UserIssue.hang);
    if (!active) return;
    final dims = {if (screen != null) 'screen': screen};
    _aggregator.count(metricHang, 1, dims);
    _aggregator.observe(metricHangDuration, ms,
        dims: dims, unit: 'ms', exemplarSession: _exemplar(true));
  }

  /// An error nothing caught. In Flutter that does not end the process, so
  /// it is what the dashboard calls an unhandled error.
  void crash() {
    if (_defer(crash)) return;
    _user(UserIssue.crash);
    if (!active) return;
    _aggregator.count(metricCrash);
  }

  /// A finished HTTP request the SDK saw.
  void request(String url, double ms,
      {required bool failed, int? responseBytes}) {
    if (_defer(
        () => request(url, ms, failed: failed, responseBytes: responseBytes))) {
      return;
    }
    if (failed) _user(UserIssue.failedRequest);
    if (!active) return;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return;
    var host = uri.hasPort && uri.port != _defaultPort(uri.scheme)
        ? '${uri.host}:${uri.port}'
        : uri.host;
    if (!_hosts.contains(host)) {
      if (_hosts.length >= _maxHosts) {
        host = overflowValue;
      } else {
        _hosts.add(host);
      }
    }
    final dims = {'host': _clip(host)};
    _aggregator.observe(metricRequestDuration, ms, dims: dims, unit: 'ms');
    _aggregator.ratio(metricRequestFailed, failed ? 1 : 0, 1, dims);
    if (responseBytes != null && responseBytes >= 0) {
      _aggregator.observe(metricRequestBytes, responseBytes.toDouble(),
          dims: dims, unit: 'By');
    }
  }

  static int _defaultPort(String scheme) => scheme == 'https' ? 443 : 80;

  /// The highest memory the process used, once per session.
  void memoryPeak(String session, int bytes) {
    if (_defer(() => memoryPeak(session, bytes))) return;
    if (bytes <= 0 || _rate(session) <= 0) return;
    _aggregator.observe(metricMemoryPeak, bytes.toDouble(), unit: 'By');
  }

  static bool _isCustomName(String name) =>
      _customName.hasMatch(name) && !_reservedPrefix.hasMatch(name);

  MetricDims _customDims(Map<String, Object>? dims) {
    if (dims == null) return const {};
    final keys = dims.keys.toList()..sort();
    return {
      for (final key in keys.take(_maxCustomDimensions))
        _clip(key): _clip(safeToString(dims[key])),
    };
  }

  /// An app-defined distribution, e.g. `checkout.duration`.
  void metric(String name, double value, [Map<String, Object>? dims]) {
    if (!_isCustomName(name)) return;
    if (_defer(() => metric(name, value, dims))) return;
    if (!active) return;
    _aggregator.observe(name, value, dims: _customDims(dims));
  }

  /// An app-defined counter.
  void count(String name, [double n = 1, Map<String, Object>? dims]) {
    if (!_isCustomName(name)) return;
    if (_defer(() => count(name, n, dims))) return;
    if (!active) return;
    _aggregator.count(name, n, _customDims(dims));
  }

  /// Uploads what was collected. [final_] when the app is going to the
  /// background: the payload is stored first, since the process may be
  /// killed before the answer.
  Future<void> flush({bool final_ = false}) {
    _track(_upload(final_));
    return Future.wait(List.of(_uploads));
  }

  /// What fails in an upload stays in it: nothing else awaits it.
  void _track(Future<void> upload) {
    final contained = guardedAsync('metrics upload', () => upload);
    _uploads.add(contained);
    contained.whenComplete(() => _uploads.remove(contained));
  }

  Future<void> _upload(bool final_) async {
    final batch = _aggregator.drain();
    if (batch == null || control.metrics == null || !(_batchRate > 0)) return;
    await _sendBatch(batch, final_);
  }

  String _batchId() =>
      bytesToHex(List<int>.generate(16, (_) => _random.nextInt(256)));

  /// A payload over the server's body limit is sent as two; only a single
  /// cell that is too large is dropped.
  Future<void> _sendBatch(MetricBatch batch, bool final_) async {
    final all = resource();
    final id = _batchId();
    final attrs = <String, Object>{
      'traceway.metrics': 'aggregated',
      'traceway.sample_rate': _batchRate,
      'traceway.sent_at': _now(),
      'traceway.batch_id': id,
    };
    for (final key in metricResourceKeys) {
      final value = all[key];
      if (value != null && value.isNotEmpty) attrs[key] = value;
    }
    _dimensions.forEach((key, value) => attrs['custom.$key'] = value);
    final body = encodeMetrics(batch, attrs,
            scopeName: scopeName, scopeVersion: scopeVersion)
        .writeToBuffer();
    if (body.length > _maxBodyBytes) {
      if (batch.cells < 2) return;
      final half = (batch.cells / 2).ceil();
      final cut = min(half, batch.histograms.length);
      await Future.wait([
        _sendBatch(
            MetricBatch(
                batch.startMs,
                batch.endMs,
                batch.histograms.sublist(0, cut),
                batch.sums.sublist(0, half - cut)),
            final_),
        _sendBatch(
            MetricBatch(batch.startMs, batch.endMs,
                batch.histograms.sublist(cut), batch.sums.sublist(half - cut)),
            final_),
      ]);
      return;
    }
    if (final_) _pending.add(id, body);
    _inFlight.add(id);
    final status = await _attempt(body);
    _inFlight.remove(id);
    final failed = status == 0 || status == 429 || status >= 500;
    if (final_) {
      if (!failed) _pending.remove(id);
    } else if (failed) {
      _pending.add(id, body);
    } else if (!_permanentStatuses.contains(status)) {
      _resend();
    }
  }

  Future<int> _attempt(List<int> body) async {
    try {
      return await send(body);
    } catch (_) {
      return 0;
    }
  }

  /// The one retry of each waiting payload. It is forgotten before it is
  /// sent, whatever the answer will be.
  void _resend() {
    if (control.metrics == null) return;
    final pending =
        guardedOr('metrics resend', const <PendingPayload>[],
            () => _pending.take(_inFlight));
    for (final entry in pending) {
      try {
        final request =
            proto.ExportMetricsServiceRequest.fromBuffer(entry.body);
        for (final rm in request.resourceMetrics) {
          final attrs = rm.resource.attributes;
          // The server corrects the device clock from the send time, so a
          // resend states its own.
          for (final attr in attrs) {
            if (attr.key == 'traceway.sent_at') {
              attr.value = proto.AnyValue(intValue: Int64(_now()));
            }
          }
          attrs.add(proto.KeyValue(
              key: 'traceway.retry', value: proto.AnyValue(boolValue: true)));
        }
        _track(_attempt(request.writeToBuffer()).then((_) {}));
      } catch (_) {
        // A payload this run cannot read is dropped.
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    final seconds = control.settings.metrics.flushSeconds;
    _timer = Timer(Duration(milliseconds: (seconds * 1000).round()), () {
      _timer = null;
      unawaited(flush());
      _schedule();
    });
  }
}
