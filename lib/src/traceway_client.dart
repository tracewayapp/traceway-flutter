import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'connection_string.dart';
import 'core/control_state.dart';
import 'core/endpoints.dart';
import 'core/ids.dart';
import 'core/merge.dart';
import 'core/ring_buffer.dart';
import 'core/settings.dart';
import 'core/trigger_engine.dart';
import 'device_info_collector.dart';
import 'events/traceway_event.dart';
import 'opamp/client.dart';
import 'opamp/messages.dart';
import 'otel/events.dart';
import 'otel/router.dart';
import 'persistence/outbox.dart';
import 'persistence/state_store.dart';
import 'replay/recordings_transport.dart';
import 'replay/replay_controller.dart';
import 'screen_recorder.dart';
import 'session/session_manager.dart';
import 'stack_trace_formatter.dart';
import 'traceway_options.dart';

const String tracewaySdkName = 'traceway-flutter';
const String tracewaySdkVersion = '2.0.0-beta.1';

const int _maxPendingBeforeReady = 500;
const int _maxErrorsPerMinute = 60;
const int _duplicateErrorWindowMs = 1000;
const int _maxGlobalAttributes = 64;

/// Replaces the parts of the SDK that touch the platform or the network, so
/// tests can run it against in-memory exporters and a fake server.
@visibleForTesting
class TracewayTestOverrides {
  TracewayTestOverrides({
    this.logExporter,
    this.spanExporter,
    this.httpClient,
    this.stateDirectory,
    this.deviceAttributes = const {},
    this.random,
    this.opampMinPollIntervalMs,
  });

  final LogRecordExporter? logExporter;
  final SpanExporter? spanExporter;
  final http.Client? httpClient;

  /// `null` keeps state in memory only.
  final Directory? stateDirectory;
  final Map<String, String> deviceAttributes;
  final double Function()? random;
  final int? opampMinPollIntervalMs;
}

class TracewayClient with WidgetsBindingObserver implements RouterHooks {
  TracewayClient._(
    String connectionString,
    this._options,
    this._overrides,
  ) {
    final parsed = parseConnectionString(connectionString);
    _token = parsed.token;
    _endpoints = resolveEndpoints(parsed.apiUrl);
    _globalAttributes.addAll(_options.attributes);

    final defaults =
        defaultSettings(baselineSampleRate: _options.baselineSampleRate);
    final errorRate = _options.sampleRate.clamp(0.0, 1.0).toDouble();
    defaults.signals['errors']!.sampleRate = errorRate;
    defaults.signals['messages']!.sampleRate = errorRate;
    _control = ControlState(
      defaults,
      ceilingsFrom(
        screenCapture: _options.screenCapture,
        captureLogs: _options.captureLogs,
        captureNetwork: _options.captureNetwork,
        captureNavigation: _options.captureNavigation,
        sessions: _options.sessions,
      ),
    );
    final settings = _control.settings;
    _buffer = RingBuffer<TelemetryItem>(
      maxBytes: settings.bufferMaxBytes,
      maxAgeMs: (settings.bufferMaxAgeSeconds * 1000).round(),
    );
    _triggers = TriggerEngine(random: _overrides?.random);
    _triggers.setTriggers(settings.triggers);
    _http = _overrides?.httpClient ?? http.Client();
    _recordings = RecordingsTransport(
      url: _endpoints.recordings,
      token: _token,
      httpClient: _http,
    );
    _replay = ReplayController(
      transport: _recordings,
      sessionId: () => _sessions?.currentId,
      nextSegmentIndex: () => _sessions?.nextSegmentIndex() ?? 0,
    );
    _replay.apply(_control.replayMode,
        maxAgeMs: (settings.bufferMaxAgeSeconds * 1000).round());
    _control.onChange(_onSettingsChanged);
  }

  static TracewayClient? _instance;
  static TracewayClient? get instance => _instance;

  final TracewayOptions _options;
  final TracewayTestOverrides? _overrides;
  late final String _token;
  late final TracewayEndpoints _endpoints;
  late final ControlState _control;
  late final RingBuffer<TelemetryItem> _buffer;
  late final TriggerEngine _triggers;
  late final http.Client _http;
  late final RecordingsTransport _recordings;
  late final ReplayController _replay;

  final Map<String, String> _globalAttributes = {};
  final Map<String, String> _resourceAttributes = {};
  final List<void Function()> _pending = [];
  final Completer<void> _readyCompleter = Completer<void>();
  final Map<String, int> _localCaptures = {};
  final List<int> _errorTimes = [];
  String? _lastErrorKey;
  int _lastErrorMs = 0;
  int _suppressedErrors = 0;

  StateStore _store = StateStore(null);
  Outbox? _outbox;
  SessionManager? _sessions;
  TelemetryRouter? _router;
  LogRecordProcessor? _logSink;
  SpanProcessor? _spanSink;
  OTelLogger? _logger;
  Tracer? _tracer;
  OpampHttpClient? _opamp;
  Uint8List _instanceUid = Uint8List(16);
  ScreenRecorder? _screenRecorder;
  Timer? _flushTimer;
  Timer? _refreshTimer;
  bool _ready = false;
  bool _shutdown = false;
  bool _ownsOTel = false;
  bool _replayFlushedForCurrentRecord = false;

  bool get debug => _options.debug;
  TracewayOptions get options => _options;

  /// Completes when the SDK has finished starting and queued records have
  /// been emitted.
  Future<void> get ready => _readyCompleter.future;

  /// The effective collection settings after remote config and ceilings.
  @visibleForTesting
  Settings get settings => _control.settings;

  @visibleForTesting
  int get bufferedCount => _buffer.length;

  @visibleForTesting
  ReplayController get replay => _replay;

  /// The screen recorder of the mounted [Traceway] widget, if any.
  ScreenRecorder? get screenRecorder => _screenRecorder;
  set screenRecorder(ScreenRecorder? recorder) {
    _screenRecorder = recorder;
    _replay.attach(recorder);
  }

  /// Uses [source] instead of the screen recorder as the origin of clips.
  @visibleForTesting
  set replaySource(ReplaySource? source) {
    _replay.attach(source);
  }

  static TracewayClient initialize(
    String connectionString,
    TracewayOptions options,
  ) {
    final existing = _instance;
    if (existing != null && !existing._shutdown) return existing;
    final client = TracewayClient._(connectionString, options, null);
    _instance = client;
    unawaited(client._start());
    return client;
  }

  @visibleForTesting
  static Future<TracewayClient> initializeForTest(
    String connectionString,
    TracewayOptions options, {
    TracewayTestOverrides? overrides,
  }) async {
    await resetForTest();
    final client = TracewayClient._(
        connectionString, options, overrides ?? TracewayTestOverrides());
    _instance = client;
    await client._start();
    return client;
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    final existing = _instance;
    _instance = null;
    if (existing != null) await existing.shutdown();
    // ignore: invalid_use_of_visible_for_testing_member
    await OTel.reset();
  }

  // ---------------------------------------------------------------- startup

  Future<void> _start() async {
    try {
      await _startUnguarded();
    } catch (e) {
      _log('failed to start: $e');
    } finally {
      _ready = true;
      final queued = List.of(_pending);
      _pending.clear();
      for (final emit in queued) {
        try {
          emit();
        } catch (_) {}
      }
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  Future<void> _startUnguarded() async {
    final stateDir = await _stateDirectory();
    _store = StateStore(stateDir);
    await _store.load();

    final storedUid = _store.get('instanceUid');
    final uid = storedUid is String ? uuidToBytes(storedUid) : null;
    if (uid != null) {
      _instanceUid = uid;
    } else {
      _instanceUid = uuidToBytes(uuidv7())!;
      _store.set('instanceUid', bytesToUuid(_instanceUid));
    }

    Uint8List? appliedHash;
    final cached = _store.get('config');
    if (_options.remoteConfig && cached is Map) {
      try {
        final body = cached['body'];
        final hash = cached['hash'];
        if (body is String && hash is String) {
          _control.applyRemote(parseSettingsDocument(body));
          appliedHash = _hexToBytes(hash);
        }
      } catch (_) {
        appliedHash = null;
      }
    }

    await _buildResource();
    await _setUpOTel(stateDir);

    if (_control.settings.sessionsEnabled) {
      _sessions = SessionManager(
        store: _store,
        onStart: _onSessionStart,
        onEnd: _onSessionEnd,
      )..start();
    }

    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}

    if (_options.remoteConfig) {
      _opamp = OpampHttpClient(
        endpoint: _endpoints.opamp,
        headers: {'Authorization': 'Bearer $_token'},
        instanceUid: _instanceUid,
        capabilities: AgentCapabilities.reportsStatus |
            AgentCapabilities.acceptsRemoteConfig |
            AgentCapabilities.reportsRemoteConfig |
            AgentCapabilities.reportsHeartbeat,
        customCapabilities: const [
          'io.traceway.sdk.buffer/v1',
          'io.traceway.sdk.capture/v1',
        ],
        describe: _describe,
        onRemoteConfig: _applyRemoteConfig,
        appliedConfigHash: appliedHash,
        onInstanceUidChange: (uid) {
          _instanceUid = uid;
          _store.set('instanceUid', bytesToUuid(uid));
        },
        onStopped: (code) => _log('remote config stopped (HTTP $code)'),
        httpClient: _http,
        minPollIntervalMs: _overrides?.opampMinPollIntervalMs ?? 30000,
      )..start();
    }
    _outbox?.schedule(const Duration(seconds: 2));
    _log('started, instance ${bytesToUuid(_instanceUid)}');
  }

  Future<Directory?> _stateDirectory() async {
    final overrides = _overrides;
    if (overrides != null) return overrides.stateDirectory;
    if (!_options.persistToDisk) return null;
    try {
      final base = await getApplicationSupportDirectory();
      return Directory('${base.path}${Platform.pathSeparator}traceway_v2');
    } catch (_) {
      return null;
    }
  }

  Future<void> _buildResource() async {
    final attrs = _resourceAttributes;
    final overrides = _overrides;
    if (overrides != null) {
      attrs.addAll(overrides.deviceAttributes);
    } else {
      try {
        attrs.addAll(DeviceInfoCollector.collectSync());
        attrs.addAll(await DeviceInfoCollector.collectAsync()
            .timeout(const Duration(seconds: 2), onTimeout: () => {}));
      } catch (_) {}
    }
    attrs['service.name'] = _serviceName;
    attrs['service.version'] = _serviceVersion;
    attrs['service.instance.id'] = bytesToUuid(_instanceUid);
    attrs['telemetry.sdk.language'] = 'dart';
    attrs['traceway.sdk.name'] = tracewaySdkName;
    attrs['traceway.sdk.version'] = tracewaySdkVersion;
    final environment = _options.environment;
    if (environment != null && environment.isNotEmpty) {
      attrs['deployment.environment.name'] = environment;
    }
  }

  String get _serviceName {
    final name = _options.serviceName;
    return name == null || name.isEmpty ? 'flutter-app' : name;
  }

  String get _serviceVersion =>
      _options.version.isEmpty ? 'unknown' : _options.version;

  Future<void> _setUpOTel(Directory? stateDir) async {
    final outbox = Outbox(
      directory: stateDir == null
          ? null
          : Directory('${stateDir.path}${Platform.pathSeparator}outbox'),
      logsUrl: _endpoints.logs,
      tracesUrl: _endpoints.traces,
      token: _token,
      httpClient: _http,
    );
    _outbox = outbox;
    final headers = {'authorization': 'Bearer $_token'};
    final delay = Duration(
        milliseconds: _options.exportDelayMs < 50 ? 50 : _options.exportDelayMs);

    final logExporter = _overrides?.logExporter ??
        PersistingLogExporter(
          OtlpHttpLogRecordExporter(OtlpHttpLogRecordExporterConfig(
            endpoint: _endpoints.logs,
            headers: headers,
            compression: true,
          )),
          outbox,
        );
    final spanExporter = _overrides?.spanExporter ??
        PersistingSpanExporter(
          OtlpHttpSpanExporter(OtlpHttpExporterConfig(
            endpoint: _endpoints.traces,
            headers: headers,
            compression: true,
          )),
          outbox,
        );
    final logSink = BatchLogRecordProcessor(
        logExporter, BatchLogRecordProcessorConfig(scheduleDelay: delay));
    final spanSink = BatchSpanProcessor(
        spanExporter, BatchSpanProcessorConfig(scheduleDelay: delay));
    _logSink = logSink;
    _spanSink = spanSink;
    _router = TelemetryRouter(
      control: _control,
      buffer: _buffer,
      logSink: logSink,
      spanSink: spanSink,
      hooks: this,
      random: _overrides?.random,
    );

    final logProcessor = ControlLogProcessor(() => _router, logSink);
    final spanProcessor = ControlSpanProcessor(() => _router, spanSink);
    // The OpenTelemetry SDK prints its own diagnostics, export failures
    // included; an app should only see them when it asked for debug output.
    final previousLog = OTelLog.logFunction;
    OTelLog.logFunction =
        _options.debug ? (message) => debugPrint('Traceway: $message') : null;
    try {
      await OTel.initialize(
        serviceName: _serviceName,
        serviceVersion: _serviceVersion,
        tracerName: tracewaySdkName,
        tracerVersion: tracewaySdkVersion,
        resourceAttributes: OTel.attributesFromMap(
            Map<String, Object>.from(_resourceAttributes)),
        spanProcessor: spanProcessor,
        logRecordProcessor: logProcessor,
        enableMetrics: false,
        detectPlatformResources: false,
        spanKind: SpanKind.client,
      );
      _ownsOTel = true;
    } on StateError {
      // The app already runs the OpenTelemetry SDK: join its providers
      // instead of replacing them.
      OTelLog.logFunction = previousLog;
      OTel.tracerProvider().addSpanProcessor(spanProcessor);
      OTel.loggerProvider().addLogRecordProcessor(logProcessor);
    }
    _logger = OTel.loggerProvider()
        .getLogger(tracewaySdkName, version: tracewaySdkVersion);
    _tracer = OTel.tracerProvider()
        .getTracer(tracewaySdkName, version: tracewaySdkVersion);
  }

  // ------------------------------------------------------------- public API

  /// The id this installation reports to the server (`service.instance.id`),
  /// usable to target it from the dashboard.
  String getInstanceId() => bytesToUuid(_instanceUid);

  void captureException(
    Object error, [
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  ]) {
    final attrs = <String, Object>{...?attributes};
    final message = error.toString();
    final raw = stackTrace?.toString();
    final obfuscated = raw != null && isNonSymbolicTrace(raw);
    // An obfuscated build renames classes on every build, so its type name
    // would split one issue into many: the message alone heads the trace,
    // and the raw frames go to the server to be symbolicated. A readable
    // trace is normalized so issues group the same on every platform.
    if (!obfuscated) attrs['exception.type'] = error.runtimeType.toString();
    attrs['exception.message'] = message;
    if (raw != null) {
      attrs['exception.stacktrace'] =
          obfuscated ? raw : formatException(error, stackTrace!);
      final buildId = extractBuildId(raw);
      if (buildId != null) attrs['flutter.build_id'] = buildId;
    }
    attrs[attrExceptionId] = uuidv4();
    _emit(
      eventName: eventException,
      severity: Severity.ERROR,
      severityText: 'ERROR',
      attributes: attrs,
    );
  }

  void captureMessage(String message, [Map<String, String>? attributes]) {
    _emit(
      eventName: eventMessage,
      severity: Severity.INFO,
      severityText: 'INFO',
      body: message,
      attributes: {...?attributes, attrExceptionId: uuidv4()},
    );
  }

  /// Records a custom breadcrumb, shown on the session timeline.
  void recordAction({
    required String category,
    required String name,
    Map<String, dynamic>? data,
  }) {
    _sessions?.markActivity();
    String? encoded;
    if (data != null && data.isNotEmpty) {
      try {
        encoded = jsonEncode(data);
      } catch (_) {
        encoded = data.toString();
      }
    }
    _emit(
      eventName: eventAction,
      severity: Severity.INFO,
      attributes: {
        'traceway.action.category': category,
        'traceway.action.name': name,
        if (encoded != null) 'traceway.action.data': encoded,
      },
    );
  }

  /// Emits a named product event, e.g. `checkout_failed`. Triggers can match
  /// it by `event.name`.
  void track(String eventName, [Map<String, Object>? attributes]) {
    if (eventName.isEmpty) return;
    _emit(
      eventName: eventName,
      severity: Severity.INFO,
      attributes: {...?attributes},
    );
  }

  /// Sets an attribute attached to every later record and reported to the
  /// server for remote-config targeting.
  void setAttribute(String key, String value) {
    if (key.isEmpty) return;
    if (!_globalAttributes.containsKey(key) &&
        _globalAttributes.length >= _maxGlobalAttributes) {
      return;
    }
    _globalAttributes[key] = value;
    _scheduleRefresh();
  }

  void setAttributes(Map<String, String> attributes) =>
      attributes.forEach(setAttribute);

  void removeAttribute(String key) {
    if (_globalAttributes.remove(key) != null) _scheduleRefresh();
  }

  void clearAttributes() {
    if (_globalAttributes.isEmpty) return;
    _globalAttributes.clear();
    _scheduleRefresh();
  }

  /// Asks the server for collection settings now instead of at the next poll.
  Future<void> refreshConfig() async {
    await ready;
    await _opamp?.refresh();
  }

  void recordLog(String line) {
    // The SDK's own debug output is not app telemetry.
    if (line.startsWith('Traceway: ')) return;
    _emit(severity: Severity.INFO, severityText: 'INFO', body: line);
  }

  void recordNavigationEvent(NavigationEvent event) {
    _sessions?.markActivity();
    _emit(
      eventName: eventNavigation,
      severity: Severity.INFO,
      time: event.timestamp,
      attributes: {
        'url.full': event.to ?? '',
        'navigation.action': event.action,
        if (event.from != null) 'navigation.from': event.from!,
        if (event.to != null) 'navigation.to': event.to!,
      },
    );
  }

  void recordNetworkEvent(NetworkEvent event) {
    if (_endpoints.isOwn(event.url)) return;
    if (!_ready) {
      _queue(() => recordNetworkEvent(event));
      return;
    }
    final tracer = _tracer;
    if (tracer == null || _shutdown) return;
    try {
      final end = event.timestamp;
      final status = event.statusCode;
      final attrs = <String, Object>{
        'http.request.method': event.method,
        'url.full': event.url,
        if (status != null) 'http.response.status_code': status,
        if (event.requestBytes != null)
          'http.request.body.size': event.requestBytes!,
        if (event.responseBytes != null)
          'http.response.body.size': event.responseBytes!,
        if (event.error != null)
          'error.type': event.error!
        else if (status != null && status >= 400)
          'error.type': '$status',
      };
      final span = tracer.startSpan(
        event.method,
        kind: SpanKind.client,
        root: true,
        attributes: OTel.attributesFromMap(attrs),
        startTime: end.subtract(event.duration),
      );
      final failed = event.error != null || (status != null && status >= 400);
      span.end(
        endTime: end,
        spanStatus: failed ? SpanStatusCode.Error : null,
      );
    } catch (e) {
      _log('network span failed: $e');
    }
  }

  /// Notes user activity so the session's inactivity timeout restarts.
  void markActivity() => _sessions?.markActivity();

  /// Sends everything that is ready now: queued records, replay clips being
  /// encoded and telemetry that failed earlier. Telemetry still held in the
  /// ring buffer stays there.
  Future<void> flush([int? timeoutMs]) async {
    final work = _flush();
    if (timeoutMs == null) return work;
    await work.timeout(Duration(milliseconds: timeoutMs), onTimeout: () {});
  }

  Future<void> _flush() async {
    await ready;
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await _logSink?.forceFlush();
      await _spanSink?.forceFlush();
      await _replay.drain();
      await _logSink?.forceFlush();
      await _outbox?.drain();
      await _store.flush();
    } catch (e) {
      _log('flush failed: $e');
    }
  }

  /// Flushes and stops the SDK. A new [initialize] call starts it again.
  Future<void> shutdown() async {
    if (_shutdown) return;
    await ready;
    final sessions = _sessions;
    final session = sessions?.current;
    if (session != null) {
      _emitSessionEnd(session, DateTime.now().millisecondsSinceEpoch);
    }
    await _flush();
    _shutdown = true;
    sessions?.stop();
    _opamp?.stop();
    _replay.stop();
    _outbox?.dispose();
    _refreshTimer?.cancel();
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    await _store.flush();
    try {
      if (_ownsOTel) {
        await OTel.shutdown();
      } else {
        await _logSink?.shutdown();
        await _spanSink?.shutdown();
      }
    } catch (_) {}
    if (identical(_instance, this)) _instance = null;
  }

  // ------------------------------------------------------------- emission

  void _queue(void Function() emit) {
    if (_pending.length < _maxPendingBeforeReady) _pending.add(emit);
  }

  void _emit({
    String? eventName,
    Severity? severity,
    String? severityText,
    Object? body,
    Map<String, Object> attributes = const {},
    DateTime? time,
  }) {
    if (_shutdown) return;
    final timestamp = time ?? DateTime.now();
    if (!_ready) {
      _queue(() => _emit(
            eventName: eventName,
            severity: severity,
            severityText: severityText,
            body: body,
            attributes: attributes,
            time: timestamp,
          ));
      return;
    }
    final logger = _logger;
    if (logger == null) return;
    try {
      logger.emit(
        timeStamp: timestamp,
        severityNumber: severity,
        severityText: severityText,
        body: body,
        eventName: eventName,
        attributes:
            attributes.isEmpty ? null : OTel.attributesFromMap(attributes),
      );
    } catch (e) {
      _log('emit failed: $e');
    }
  }

  void _emitSessionEnd(SessionInfo session, int endedAtMs) {
    _emit(
      eventName: eventSessionEnd,
      severity: Severity.INFO,
      time: DateTime.fromMillisecondsSinceEpoch(endedAtMs),
      attributes: {
        attrSessionId: session.id,
        attrSessionStartedAt: session.startedAtMs,
      },
    );
  }

  void _onSessionStart(SessionInfo session, bool resumed) {
    if (!resumed) _triggers.resetSession();
    _emit(
      eventName: resumed ? eventSessionUpdate : eventSessionStart,
      severity: Severity.INFO,
      time: resumed ? null : DateTime.fromMillisecondsSinceEpoch(session.startedAtMs),
      attributes: {
        attrSessionId: session.id,
        attrSessionStartedAt: session.startedAtMs,
      },
    );
    _scheduleRefresh();
  }

  void _onSessionEnd(SessionInfo session, int endedAtMs) =>
      _emitSessionEnd(session, endedAtMs);

  // ----------------------------------------------------------- RouterHooks

  @override
  String? get sessionId => _sessions?.currentId;

  @override
  String? globalAttribute(String key) => _globalAttributes[key];

  @override
  bool enrichLog(ReadWriteLogRecord record, String signal) {
    final existing = record.attributes?.toMap() ?? const {};
    final session = _sessions?.current;
    if (session != null && !existing.containsKey(attrSessionStartedAt)) {
      record.addAttribute(
          OTel.attributeInt(attrSessionStartedAt, session.startedAtMs));
    }
    _globalAttributes.forEach((key, value) {
      if (!existing.containsKey(key)) {
        record.addAttribute(OTel.attributeString(key, value));
      }
    });
    if (signal == 'errors') {
      final key = '${existing['exception.type']?.value}:'
          '${existing['exception.message']?.value}';
      if (!_admitError(key)) return false;
      if (_suppressedErrors > 0) {
        record.addAttribute(OTel.attributeInt(
            'traceway.error.suppressed_count', _suppressedErrors));
        _suppressedErrors = 0;
      }
    }
    return true;
  }

  /// Stops a crash loop from flooding the server: identical errors within a
  /// second collapse into one, and no more than 60 leave per minute.
  bool _admitError(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (key == _lastErrorKey && now - _lastErrorMs < _duplicateErrorWindowMs) {
      _suppressedErrors++;
      return false;
    }
    _errorTimes.removeWhere((t) => now - t > 60000);
    if (_errorTimes.length >= _maxErrorsPerMinute) {
      _suppressedErrors++;
      return false;
    }
    _errorTimes.add(now);
    _lastErrorKey = key;
    _lastErrorMs = now;
    return true;
  }

  @override
  void observe(ObservedRecord observed) {
    if (observed.signal == signalControl) return;
    if (!_control.enabled) return;
    final fired = _triggers.observe(
        ObservedEvent(timeMs: observed.timeMs, lookup: observed.lookup));
    final item = observed.item;
    final isError = observed.signal == 'errors' && item is LogItem;

    var replayRequested = false;
    var replayAvailable = false;
    if (isError) {
      replayAvailable = _control.replayMode != Mode.off;
      Trigger? defaultTrigger;
      for (final trigger in _control.settings.triggers) {
        if (trigger.id == defaultExceptionTriggerId) defaultTrigger = trigger;
      }
      replayRequested = fired.any((f) =>
          f.trigger.actions.any((a) => a.type == 'flush' && a.replay));
      final skipped = _triggers.skipped[defaultExceptionTriggerId];
      final status = _control.replayMode == Mode.off
          ? 'disabled'
          : replayRequested
              ? 'requested'
              : (skipped ??
                  (defaultTrigger?.enabled == false
                      ? 'trigger_disabled'
                      : 'not_triggered'));
      item.record.addAttribute(OTel.attributeString(attrReplayStatus, status));
      // A clip skipped for cooldown or the per-session limit still gets its
      // breadcrumbs: only the video is rationed.
      if (skipped == 'cooldown' || skipped == 'session_clip_limit') {
        for (final action in defaultTrigger?.actions ?? const <TriggerAction>[]) {
          if (action.type == 'flush' && !action.replay) _runAction(action);
        }
      }
      item.record.addAttribute(
          OTel.attributeInt('traceway.context.evicted', _buffer.evictedCount));
    }

    _replayFlushedForCurrentRecord = false;
    for (final trigger in fired) {
      _runTrigger(trigger);
    }
    if (isError &&
        replayAvailable &&
        replayRequested &&
        !_replayFlushedForCurrentRecord) {
      item.record.addAttribute(
          OTel.attributeString(attrReplayStatus, 'buffer_unavailable'));
    }
    if (fired.isNotEmpty) _router?.sendIfStreaming(observed);
    if (observed.signal == 'errors' || observed.signal == 'messages') {
      _flushSoon();
    }
  }

  // --------------------------------------------------------------- triggers

  void _runTrigger(FiredTrigger fired) {
    final raw = fired.cause.lookup('attributes.$attrExceptionId');
    final exceptionId = raw is String ? raw : null;
    for (final action in fired.trigger.actions) {
      _runAction(action, exceptionId: exceptionId, triggerId: fired.trigger.id);
    }
    _emit(
      eventName: eventTriggerFired,
      severity: Severity.INFO,
      attributes: {
        'traceway.trigger.id': fired.trigger.id,
        if (fired.trigger.name != null)
          'traceway.trigger.name': fired.trigger.name!,
      },
    );
  }

  static Set<String>? _selectorSet(List<String>? signals) {
    if (signals == null || signals.contains('*')) return null;
    return signals.toSet();
  }

  void _runAction(
    TriggerAction action, {
    String? exceptionId,
    String? triggerId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (action.type) {
      case 'flush':
        final lookbackMs = ((action.lookbackSeconds ?? 0) * 1000).round();
        _router?.flushBuffered(
            now - lookbackMs, _selectorSet(action.signals), now);
        if (action.replay && _replay.flush(lookbackMs, exceptionId)) {
          _replayFlushedForCurrentRecord = true;
        }
      case 'stream':
        _control.addOverride(StreamOverride(
          signals: action.signals ?? const ['*'],
          untilMs: now + ((action.durationSeconds ?? 0) * 1000).round(),
        ));
      case 'startReplay':
        // The screen recording is never streamed; see ReplayController.
        break;
      case 'emit':
        _emit(
          eventName: action.eventName,
          severity: Severity.INFO,
          attributes: {...?action.attributes},
        );
      case 'capture':
        _startLocalCapture(action, exceptionId, triggerId ?? 'local');
    }
  }

  /// A capture a trigger started on this device: upload the lookback once,
  /// then stream the selected signals until it ends. While it runs, the same
  /// trigger only extends it.
  void _startLocalCapture(
    TriggerAction action,
    String? exceptionId,
    String triggerId,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var untilMs = now + ((action.durationSeconds ?? 0) * 1000).round();
    final signals = action.signals ?? const ['*'];
    final running = _localCaptures[triggerId];
    if (running != null && running > now) {
      if (running > untilMs) untilMs = running;
    } else {
      _runAction(
        TriggerAction(
          type: 'flush',
          lookbackSeconds: action.lookbackSeconds ?? 60,
          signals: signals,
          replay: action.replay,
        ),
        exceptionId: exceptionId,
      );
      _emit(
        eventName: eventCaptureStarted,
        severity: Severity.INFO,
        attributes: {
          'traceway.capture.id': '$triggerId:$now',
          'traceway.capture.source': 'trigger',
          'traceway.trigger.id': triggerId,
          'traceway.capture.until':
              DateTime.fromMillisecondsSinceEpoch(untilMs)
                  .toUtc()
                  .toIso8601String(),
        },
      );
    }
    _localCaptures[triggerId] = untilMs;
    _control.setOverrides('local:$triggerId', [
      StreamOverride(signals: signals, untilMs: untilMs, includeOff: true),
    ]);
  }

  /// Captures requested from the dashboard: each uploads its lookback once
  /// per installation and then streams until it ends.
  void _runCaptures(Settings settings) {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final stored = _store.get('captures');
    final done = <String>{if (stored is List) ...stored.whereType<String>()};
    final overrides = <StreamOverride>[];
    for (final capture in settings.captures) {
      if (!capture.until.isAfter(now)) continue;
      final signals = capture.signals ?? const ['*'];
      if (done.add(capture.id)) {
        _router?.flushBuffered(
          nowMs - ((capture.lookbackSeconds ?? 600) * 1000).round(),
          _selectorSet(signals),
          nowMs,
        );
        _emit(
          eventName: eventCaptureStarted,
          severity: Severity.INFO,
          attributes: {
            'traceway.capture.id': capture.id,
            'traceway.capture.source': 'remote',
          },
        );
      }
      overrides.add(StreamOverride(
        signals: signals,
        untilMs: capture.until.millisecondsSinceEpoch,
        includeOff: true,
      ));
    }
    final active = settings.captures.map((c) => c.id).toSet();
    done.retainWhere(active.contains);
    _store.set('captures', done.toList());
    _control.setOverrides('remote-captures', overrides);
  }

  void _onSettingsChanged(Settings settings) {
    _triggers.setTriggers(settings.triggers);
    _buffer.retain((entry) => _control.canExport(entry.signal));
    final maxAgeMs = (settings.bufferMaxAgeSeconds * 1000).round();
    _buffer.configure(maxBytes: settings.bufferMaxBytes, maxAgeMs: maxAgeMs);
    _replay.apply(_control.replayMode, maxAgeMs: maxAgeMs);
    _runCaptures(settings);
  }

  // ------------------------------------------------------------------ OpAMP

  AgentDescription _describe() {
    final nonIdentifying = <String, Object>{};
    _resourceAttributes.forEach((key, value) {
      if (key != 'service.name' && key != 'service.instance.id') {
        nonIdentifying[key] = _clip(value);
      }
    });
    _globalAttributes.forEach((key, value) {
      if (key.length <= 128) nonIdentifying[key] = _clip(value);
    });
    final session = _sessions?.currentId;
    if (session != null) nonIdentifying[attrSessionId] = session;
    return AgentDescription(
      identifying: {
        'service.name': _serviceName,
        'service.instance.id': bytesToUuid(_instanceUid),
      },
      nonIdentifying: nonIdentifying,
    );
  }

  static String _clip(String value) =>
      value.length > 1024 ? value.substring(0, 1024) : value;

  ApplyResult _applyRemoteConfig(RemoteConfig config) {
    final object = config.configMap['traceway'];
    final body = object == null ? '{}' : utf8.decode(object.body);
    final Json overlay;
    try {
      overlay = parseSettingsDocument(body);
    } on SettingsError catch (e) {
      return ApplyResult.failed(e.message);
    }
    _control.applyRemote(overlay);
    final hash = _bytesToHex(config.configHash);
    _store.set('config', {'hash': hash, 'body': body});
    _emit(
      eventName: eventConfigApplied,
      severity: Severity.INFO,
      attributes: {'traceway.config.hash': hash},
    );
    _log('remote config applied ($hash)');
    return const ApplyResult.applied();
  }

  /// A targeting attribute or the session changed: let the server re-evaluate
  /// its rules soon, without a poll per change.
  void _scheduleRefresh() {
    if (_opamp == null || _refreshTimer != null) return;
    _refreshTimer = Timer(const Duration(seconds: 2), () {
      _refreshTimer = null;
      unawaited(_opamp?.refresh());
    });
  }

  // -------------------------------------------------------------- lifecycle

  /// An error should not wait for the batch delay: the app may be about to
  /// die.
  void _flushSoon() {
    _flushTimer ??= Timer(const Duration(milliseconds: 100), () {
      _flushTimer = null;
      unawaited(_logSink?.forceFlush());
      unawaited(_spanSink?.forceFlush());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_shutdown) return;
    if (state == AppLifecycleState.resumed) {
      _sessions?.markActivity();
      unawaited(_opamp?.poll());
      unawaited(_outbox?.drain());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_logSink?.forceFlush());
      unawaited(_spanSink?.forceFlush());
      unawaited(_store.flush());
    }
  }

  void _log(String message) {
    if (_options.debug) debugPrint('Traceway: $message');
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _hexToBytes(String hex) {
    if (hex.isEmpty || hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }
}
