import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'connection_string.dart';
import 'core/control_state.dart';
import 'core/endpoints.dart';
import 'core/ids.dart';
import 'core/matcher.dart';
import 'core/merge.dart';
import 'core/ring_buffer.dart';
import 'core/settings.dart';
import 'core/trigger_engine.dart';
import 'device_info_collector.dart';
import 'events/traceway_event.dart';
import 'interaction/tap_target.dart';
import 'interaction/widget_selector.dart';
import 'metrics/app_vitals.dart';
import 'metrics/metrics_recorder.dart';
import 'metrics/route.dart';
import 'opamp/client.dart';
import 'opamp/messages.dart';
import 'otel/events.dart';
import 'otel/router.dart';
import 'persistence/buffer_persistence.dart';
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
    this.videoSupported = true,
    this.appVitals = false,
  });

  final LogRecordExporter? logExporter;
  final SpanExporter? spanExporter;
  final http.Client? httpClient;

  /// `null` keeps state in memory only.
  final Directory? stateDirectory;
  final Map<String, String> deviceAttributes;
  final double Function()? random;
  final int? opampMinPollIntervalMs;

  /// Whether the platform can encode video; tests attach a fake source.
  final bool videoSupported;

  /// Whether the frame, start and hang instrumentation runs. Metrics the
  /// app reports and requests, sessions and errors are recorded either way.
  final bool appVitals;
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

    var defaults = defaultSettings(
      baselineSampleRate: _options.baselineSampleRate,
      recordAllSessions: _options.recordAllSessions,
    );
    final errorRate = _options.sampleRate.clamp(0.0, 1.0).toDouble();
    defaults.signals['errors']!.sampleRate = errorRate;
    defaults.signals['messages']!.sampleRate = errorRate;
    final collection = _options.collection;
    if (collection != null) {
      try {
        defaults = applyOverlay(
            defaults, parseSettingsDocument(jsonEncode(collection)));
      } catch (e) {
        debugPrint('Traceway: ignoring TracewayOptions.collection: $e');
      }
    }
    _videoSupported =
        _overrides?.videoSupported ?? ScreenRecorder.isVideoSupported;
    if (_options.screenCapture && !_videoSupported) {
      _log('screen capture needs a video encoder, which this platform '
          'does not have: replay is off');
    }
    _control = ControlState(
      defaults,
      ceilingsFrom(
        screenCapture: _options.screenCapture && _videoSupported,
        captureLogs: _options.captureLogs,
        captureNetwork: _options.captureNetwork,
        captureNavigation: _options.captureNavigation,
        captureUserActions: _options.captureUserActions,
        sessions: _options.sessions,
        captureMetrics: _options.captureMetrics,
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
    // A streamed segment must leave before the frame ring buffer wraps.
    final ringMs =
        max(1, _options.maxBufferFrames) * 1000 ~/ _options.fps.clamp(1, 59);
    _replay = ReplayController(
      transport: _recordings,
      sessionId: () => _sessions?.currentId,
      nextSegmentIndex: () => _sessions?.nextSegmentIndex() ?? 0,
      segmentMs: (ringMs * 0.8).round().clamp(200, 10000),
    );
    _metrics = MetricsRecorder(
      control: _control,
      sessionId: () => _sessions?.currentId,
      installationId: () => bytesToUuid(_instanceUid),
      resource: () => _resourceAttributes,
      send: _sendMetrics,
      store: () => _store,
      scopeName: tracewaySdkName,
      scopeVersion: tracewaySdkVersion,
      dimensions: _options.metricDimensions,
      deferUntilStart: true,
    );
    _vitals = AppVitals(_metrics, currentScreen: () => _metricsScreen);
    if (_options.captureMetrics && (_overrides?.appVitals ?? true)) {
      _vitals.watchColdStart(
        sdkStartMs: _sdkStartMs,
        processStartMs: AppVitals.readProcessStartMs(),
      );
    }
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
  late final bool _videoSupported;
  late final MetricsRecorder _metrics;
  late final AppVitals _vitals;

  /// When the app initialized the SDK: the start of a cold start where the
  /// process start is not known.
  final int _sdkStartMs = DateTime.now().millisecondsSinceEpoch;

  final Map<String, String> _globalAttributes = {};
  final Map<String, String> _resourceAttributes = {};
  final List<void Function()> _pending = [];
  final Completer<void> _readyCompleter = Completer<void>();
  final List<int> _errorTimes = [];
  String? _lastErrorKey;
  int _lastErrorMs = 0;
  int _suppressedErrors = 0;

  StateStore _store = StateStore(null);
  Outbox? _outbox;
  BufferPersistence? _persisted;
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
  /// Clips flushed so far; an exception compares it before and after its
  /// triggers run (an `emit` action re-enters observe on the way).
  int _replayFlushes = 0;

  /// Set once the SDK has started: settings changes apply from then on.
  bool _started = false;

  /// Captures known only from the cached config keep streaming, but start
  /// nothing new until the server has answered: they may have been
  /// cancelled while the app was away.
  bool _capturesConfirmed = false;
  Timer? _overrideTimer;
  int _savedProgressVersion = -1;

  /// The path of the route on top, as the last navigation reported it.
  String? _currentScreen;

  /// Event types (`click`, `hover`, `navigation`) the triggers name.
  Set<String> _sequenceKinds = const {};
  bool _screenObservedForSequences = false;
  Set<Element> _hovered = const {};
  Object? _hoverLeaf;

  bool get debug => _options.debug;
  TracewayOptions get options => _options;

  /// Whether the screen is recorded: screen capture is on and this platform
  /// can encode video.
  bool get recordsScreen => _options.screenCapture && _videoSupported;

  /// Completes when the SDK has finished starting and queued records have
  /// been emitted.
  Future<void> get ready => _readyCompleter.future;

  /// The effective collection settings after remote config and ceilings.
  @visibleForTesting
  Settings get settings => _control.settings;

  @visibleForTesting
  ControlState get control => _control;

  @visibleForTesting
  int get bufferedCount => _buffer.length;

  @visibleForTesting
  List<BufferEntry<TelemetryItem>> get bufferSnapshot => _buffer.snapshot();

  /// The current session, or null when sessions are off.
  String? get currentSessionId => _sessions?.currentId;

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
    _replay.budget.store = _store;

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

    if (stateDir != null) {
      final persisted = BufferPersistence(stateDir);
      _persisted = persisted;
      final settings = _control.settings;
      if (settings.persist) {
        await persisted.load(
          _sessions?.currentId,
          maxAgeMs: (settings.bufferMaxAgeSeconds * 1000).round(),
          maxBytes: settings.bufferMaxBytes,
        );
        persisted.retain(_control.canExport);
      } else {
        await persisted.clear();
      }
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
          'io.traceway.sdk.sequence-triggers/v1',
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
    _started = true;
    if (_options.captureMetrics) {
      _metrics.start();
      if (_overrides?.appVitals ?? true) _vitals.start();
    }
    _restoreLocalCaptures();
    _onSettingsChanged(_control.settings);
    final opamp = _opamp;
    if (opamp == null) {
      _confirmCaptures();
    } else {
      unawaited(opamp.poll().whenComplete(_confirmCaptures));
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
    // The numbers of the SDK's performance events arrive as metrics: the
    // server must not count an uploaded event a second time.
    if (_options.captureMetrics) attrs['traceway.metrics'] = 'aggregated';
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

  /// An error nothing in the app caught: reported like [captureException]
  /// and counted as an unhandled error (`app.crash`).
  void captureUnhandledException(Object error, [StackTrace? stackTrace]) {
    if (_options.captureMetrics) _metrics.crash();
    captureException(error, stackTrace);
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
    // A removal takes a route out of the stack without the user arriving
    // anywhere: it is on the timeline, but not a navigation triggers match.
    final arrived = event.action != 'remove';
    final to = arrived ? event.to : null;
    if (to != null && to.isNotEmpty) _currentScreen = to;
    if (_options.captureMetrics && arrived) {
      _vitals.navigated(
        to == null || to.isEmpty ? null : normalizePath(to),
        event.action,
        event.timestamp,
      );
    }
    _emit(
      eventName: eventNavigation,
      severity: Severity.INFO,
      time: event.timestamp,
      attributes: {
        'url.full': to ?? '',
        'navigation.action': event.action,
        // The session timeline labels a navigation by this.
        'browser.navigation.type': event.action,
        if (event.from != null) 'navigation.from': event.from!,
        if (to != null) 'navigation.to': to,
        if (to != null && to.isNotEmpty) 'app.screen.name': to,
      },
    );
  }

  /// The path of the route on top, as the last navigation reported it.
  String? get currentScreen => _currentScreen;

  /// The current screen as a metrics dimension: `/orders/8841` is
  /// `/orders/:id`, so every order is one series.
  String? get _metricsScreen {
    final screen = _currentScreen;
    return screen == null || screen.isEmpty ? null : normalizePath(screen);
  }

  // ---------------------------------------------------------------- metrics

  /// The screen on top shows everything it loads: ends its time to full
  /// display (`app.screen.ttfd`), measured from the navigation to it.
  void reportFullyDisplayed() {
    if (_options.captureMetrics) _vitals.fullyDisplayed();
  }

  /// Observes [value] of an app-defined distribution, e.g.
  /// `checkout.duration`. Names are lowercase letters, digits, `_` and `.`,
  /// and may not start with `app.`, `browser.`, `traceway.` or `custom.`; at
  /// most two dimensions are kept.
  void recordMetric(String name, double value, [Map<String, Object>? dims]) {
    if (_options.captureMetrics) _metrics.metric(name, value, dims);
  }

  /// Adds [n] to an app-defined counter; see [recordMetric] for names.
  void recordCount(String name, [double n = 1, Map<String, Object>? dims]) {
    if (_options.captureMetrics) _metrics.count(name, n, dims);
  }

  /// Sets an app-defined dimension on every metric from now on (sent as
  /// `custom.<key>`); null removes it. At most two keys.
  void setMetricDimension(String key, String? value) =>
      _metrics.setDimension(key, value);

  Future<int> _sendMetrics(List<int> body) async {
    final response = await _http
        .post(
          Uri.parse(_endpoints.metrics),
          headers: {
            'Content-Type': 'application/x-protobuf',
            'Authorization': 'Bearer $_token',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 10));
    return response.statusCode;
  }

  static int _maxRss() {
    try {
      return ProcessInfo.maxRss;
    } catch (_) {
      return 0;
    }
  }

  static const String _memoryKey = 'metricsMemory';

  /// The process may be killed in the background: what the session used so
  /// far is kept, and observed when the session is known to have ended.
  void _rememberMemoryPeak() {
    final session = _sessions?.currentId;
    if (!_options.captureMetrics || session == null) return;
    var bytes = _maxRss();
    final record = _store.get(_memoryKey);
    if (record is Map && record['s'] == session && record['b'] is int) {
      bytes = max(bytes, record['b'] as int);
    }
    if (bytes > 0) _store.set(_memoryKey, {'s': session, 'b': bytes});
  }

  void _recordMemoryPeak(String session) {
    if (!_options.captureMetrics) return;
    var bytes = _maxRss();
    final record = _store.get(_memoryKey);
    if (record is Map && record['s'] == session && record['b'] is int) {
      bytes = max(bytes, record['b'] as int);
    }
    _store.set(_memoryKey, null);
    _metrics.memoryPeak(session, bytes);
  }

  /// A session that ended while the app was not running.
  void _settleMemoryPeak(String current) {
    final record = _store.get(_memoryKey);
    if (!_options.captureMetrics || record is! Map) return;
    final session = record['s'];
    final bytes = record['b'];
    if (session is String && session != current && bytes is int) {
      _store.set(_memoryKey, null);
      _metrics.memoryPeak(session, bytes);
    }
  }

  /// Records a tap at [position] (global logical pixels): a
  /// `browser.user_action.click` record naming the widget, and a click for
  /// recording triggers. The `Traceway` widget calls this for every tap.
  void recordTap(Offset position, {int? viewId}) {
    if (_shutdown || !_options.captureUserActions) return;
    _sessions?.markActivity();
    final wantsTriggers = _ready && _sequenceKinds.contains('click');
    if (!wantsTriggers && _control.modeFor('userActions') == Mode.off) return;
    final ElementPath? path;
    try {
      path = elementPathAt(position, viewId: viewId);
    } catch (e) {
      _log('tap lookup failed: $e');
      return;
    }
    if (path == null) return;
    final target = describeTap(path);
    if (target != null) {
      _emit(
        eventName: eventClick,
        severity: Severity.INFO,
        attributes: {
          'browser.css_selector': target.selector,
          'browser.tag_name': target.tag,
          'app.widget.name': target.tag,
          if (target.id != null) 'app.widget.id': target.id!,
          if (target.text != null) 'app.widget.text': target.text!,
          if (target.label != null) 'app.widget.label': target.label!,
          'app.screen.coordinate.x': position.dx.round(),
          'app.screen.coordinate.y': position.dy.round(),
          if (_currentScreen != null) 'app.screen.name': _currentScreen!,
        },
      );
    }
    if (wantsTriggers) {
      _observePointer('click', (selector) {
        final parsed = WidgetSelector.parse(selector);
        return parsed != null && parsed.matches(path!);
      });
    }
  }

  /// Feeds a mouse hover to recording triggers: a hover step matches when
  /// the pointer enters a matching widget, not while it moves inside it.
  /// Only runs while a trigger names a hover.
  void recordHover(Offset position, {int? viewId}) {
    if (_shutdown || !_ready || !_options.captureUserActions) return;
    if (!_sequenceKinds.contains('hover')) return;
    final ElementPath? path;
    try {
      // Hit testing is cheap; walking the element tree is done only when
      // the mouse is over something else than before.
      final leaf = hitLeaf(position, viewId: viewId);
      if (leaf == null || identical(leaf, _hoverLeaf)) return;
      _hoverLeaf = leaf;
      path = elementPathAt(position, viewId: viewId);
    } catch (_) {
      return;
    }
    if (path == null) return;
    final previous = _hovered;
    _hovered = path.elements.toSet();
    _observePointer('hover', (selector) {
      final parsed = WidgetSelector.parse(selector);
      if (parsed == null) return false;
      final index = parsed.firstMatchWhere(
          path!, (element) => !previous.contains(element));
      return index != null;
    });
  }

  void _observePointer(String type, bool Function(String selector) test) {
    if (!_control.enabled || _sessions?.currentId == null) return;
    _runFired(_triggers.observe(ObservedEvent(
      timeMs: DateTime.now().millisecondsSinceEpoch,
      lookup: _pageLookup({keyPointerAction: type, keyTargetMatches: test}),
      sequence: type,
    )));
  }

  /// The fields of an event the app reports itself, next to what every
  /// record can be matched on.
  FieldLookup _pageLookup(Map<String, Object?> fields) => (key) {
        if (fields.containsKey(key)) return fields[key];
        if (key.startsWith('global.')) {
          return _globalAttributes[key.substring('global.'.length)];
        }
        if (key.startsWith('resource.')) {
          return _resourceAttributes[key.substring('resource.'.length)];
        }
        if (key == attrSessionId) return _sessions?.currentId;
        return null;
      };

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
    if (_options.captureMetrics) {
      final status = event.statusCode;
      _metrics.request(
        event.url,
        event.duration.inMicroseconds / 1000,
        failed: event.error != null || status == null || status >= 400,
        responseBytes: event.responseBytes,
      );
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
      await _metrics.flush();
      await _outbox?.drain();
      await _persistBuffer();
      _saveTriggerProgress(now: true);
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
    // The session may go on after a restart: its memory is observed when it
    // ends.
    _rememberMemoryPeak();
    _vitals.stop();
    await _flush();
    _metrics.stop();
    _shutdown = true;
    sessions?.stop();
    _opamp?.stop();
    _replay.stop();
    _outbox?.dispose();
    _refreshTimer?.cancel();
    _overrideTimer?.cancel();
    _progressTimer?.cancel();
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
      attributes: _sessionAttributes(session),
    );
  }

  /// What every session event carries: the session and how much of its
  /// diagnostic budget replay used, shown on the session page.
  Map<String, Object> _sessionAttributes(SessionInfo session) => {
        attrSessionId: session.id,
        attrSessionStartedAt: session.startedAtMs,
        ..._replay.budget.snapshot(session.id),
        'traceway.replay.failed_segments': _recordings.failedSegments,
        'traceway.context.evicted': _buffer.evictedCount,
      };

  void _onSessionStart(SessionInfo session, bool resumed) {
    // What an earlier session left behind is not this one's context.
    if (!resumed) _persisted?.restored.clear();
    _triggers.resetSession();
    final limits = _store.get('triggerLimits');
    if (limits is Map && limits['sessionId'] == session.id) {
      _triggers.restoreSessionLimits(limits['limits']);
    }
    _restoreTriggerProgress();
    _replay.onSessionStart();
    if (_options.captureMetrics) {
      _settleMemoryPeak(session.id);
      _metrics.sessionStarted(session.id, resumed: resumed);
    }
    _emit(
      eventName: resumed ? eventSessionUpdate : eventSessionStart,
      severity: Severity.INFO,
      time: resumed ? null : DateTime.fromMillisecondsSinceEpoch(session.startedAtMs),
      attributes: _sessionAttributes(session),
    );
    _applyReplay();
    _scheduleRefresh();
  }

  void _onSessionEnd(SessionInfo session, int endedAtMs) {
    _replay.onSessionEnd(session.id);
    _recordMemoryPeak(session.id);
    _emitSessionEnd(session, endedAtMs);
  }

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
    if (observed.signal == 'navigation' && _sequenceKinds.contains('navigation')) {
      _screenObservedForSequences = true;
    }
    final fired = _triggers.observe(
        ObservedEvent(timeMs: observed.timeMs, lookup: observed.lookup));
    final item = observed.item;
    final isError = observed.signal == 'errors' && item is LogItem;

    var flushRequested = false;
    var replayAvailable = false;
    if (isError) {
      replayAvailable = _control.replayMode != Mode.off;
      Trigger? defaultTrigger;
      for (final trigger in _control.settings.triggers) {
        if (trigger.id == defaultExceptionTriggerId) defaultTrigger = trigger;
      }
      final replayRequested = fired.any((f) => f.trigger.actions
          .any((a) => a.replay || a.type == 'startReplay'));
      flushRequested = fired.any((f) => f.trigger.actions.any(
          (a) => a.replay && (a.type == 'flush' || a.type == 'capture')));
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
      final contextActions = [
        for (final action in defaultTrigger?.actions ?? const <TriggerAction>[])
          if (action.type == 'flush' && !action.replay) action,
      ];
      if (skipped == 'cooldown' || skipped == 'session_clip_limit') {
        for (final action in contextActions) {
          _runAction(action);
        }
      }
      var lookback = 0.0;
      for (final action in contextActions) {
        lookback = max(lookback, action.lookbackSeconds ?? 0);
      }
      item.record.addAttribute(OTel.attributeDouble(
          'traceway.context.lookback_seconds', lookback));
      item.record.addAttribute(
          OTel.attributeInt('traceway.context.evicted', _buffer.evictedCount));
    }

    final flushesBefore = _replayFlushes;
    _runFired(fired);
    if (isError &&
        replayAvailable &&
        flushRequested &&
        _replayFlushes == flushesBefore) {
      item.record.addAttribute(
          OTel.attributeString(attrReplayStatus, 'buffer_unavailable'));
    }
    if (fired.isNotEmpty) _router?.sendIfStreaming(observed);
    if (observed.signal == 'errors' || observed.signal == 'messages') {
      _flushSoon();
    }
  }

  // --------------------------------------------------------------- triggers

  void _runFired(List<FiredTrigger> fired) {
    for (final trigger in fired) {
      _runTrigger(trigger);
    }
    if (fired.isNotEmpty) {
      _store.set('triggerLimits', {
        'sessionId': _sessions?.currentId,
        'limits': _triggers.snapshotSessionLimits(),
      });
    }
    _saveTriggerProgress();
  }

  String _savedProgress = '';
  Timer? _progressTimer;
  int _lastProgressSaveMs = 0;

  /// Keeps sequences under way across an app restart within the session.
  /// At most every two seconds: a step that counts frequent records changes
  /// progress on each of them.
  void _saveTriggerProgress({bool now = false}) {
    if (_triggers.progressVersion == _savedProgressVersion) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!now && nowMs - _lastProgressSaveMs < 2000) {
      _progressTimer ??= Timer(const Duration(seconds: 2), () {
        _progressTimer = null;
        _saveTriggerProgress(now: true);
      });
      return;
    }
    _progressTimer?.cancel();
    _progressTimer = null;
    _lastProgressSaveMs = nowMs;
    _savedProgressVersion = _triggers.progressVersion;
    final progress = _triggers.snapshotProgress();
    final encoded = jsonEncode([_sessions?.currentId, progress]);
    if (encoded == _savedProgress) return;
    _savedProgress = encoded;
    _store.set('triggerProgress', {
      'sessionId': _sessions?.currentId,
      'progress': progress,
    });
  }

  void _restoreTriggerProgress() {
    final saved = _store.get('triggerProgress');
    final session = _sessions?.currentId;
    if (saved is Map && session != null && saved['sessionId'] == session) {
      _triggers.restoreProgress(saved['progress']);
    }
  }

  void _runTrigger(FiredTrigger fired) {
    final raw = fired.cause.lookup('attributes.$attrExceptionId');
    final exceptionId = raw is String ? raw : null;
    for (final action in fired.trigger.actions) {
      _runAction(action, exceptionId: exceptionId, triggerId: fired.trigger.id);
    }
    final wantsReplay = fired.trigger.actions
        .any((a) => a.replay || a.type == 'startReplay');
    _emit(
      eventName: eventTriggerFired,
      severity: Severity.INFO,
      attributes: {
        'traceway.trigger.id': fired.trigger.id,
        if (fired.trigger.name != null)
          'traceway.trigger.name': fired.trigger.name!,
        // The server lists the sessions a recording trigger asked replay
        // for, with the sequence that did.
        if (wantsReplay && _control.replayMode != Mode.off) ...{
          'traceway.trigger.replay': 'true',
          'traceway.trigger.steps': jsonEncode(fired.trigger.stepsJson()),
        },
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
        final signals = _selectorSet(action.signals);
        _router?.flushBuffered(now - lookbackMs, signals, now);
        _flushRestored(now - lookbackMs, signals, now);
        if (action.replay && _replay.flush(lookbackMs, exceptionId)) {
          _replayFlushes++;
        }
        // The file must not hold records that just left, or a crash before
        // the next save would send them again after a restart.
        if (_persisted != null) unawaited(_persistBuffer());
      case 'stream':
        _streamFor(
          action.signals ?? const ['*'],
          replay: action.replay,
          untilMs: now + ((action.durationSeconds ?? 0) * 1000).round(),
        );
      case 'startReplay':
        _streamFor(
          const [],
          replay: true,
          untilMs: now + ((action.durationSeconds ?? 0) * 1000).round(),
        );
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

  /// Uploads what the last run left in the buffer for this session, within
  /// the window, through the outbox so a failed upload is retried.
  void _flushRestored(int sinceMs, Set<String>? signals, int untilMs) {
    final persisted = _persisted;
    final outbox = _outbox;
    if (persisted == null || outbox == null) return;
    final bodies = persisted.take(sinceMs, signals, untilMs, _control.canExport);
    if (bodies.isEmpty) return;
    bodies.forEach(outbox.add);
    unawaited(outbox.drain());
  }

  Future<void> _persistBuffer() async {
    final persisted = _persisted;
    if (persisted == null || !_control.settings.persist || _shutdown) return;
    await persisted.save(_sessions?.currentId, _buffer.snapshot());
  }

  void _streamFor(
    List<String> signals, {
    required bool replay,
    required int untilMs,
    bool capture = false,
    String? owner,
  }) {
    final override = StreamOverride(
      signals: signals,
      replay: replay,
      untilMs: untilMs,
      includeOff: capture,
    );
    if (owner != null) {
      _control.setOverrides(owner, [override]);
    } else {
      _control.addOverride(override);
    }
    _applyReplay();
    _scheduleOverrideExpiry();
  }

  /// Re-applies replay when the next override ends, so a streaming capture
  /// returns to buffering on time.
  void _scheduleOverrideExpiry() {
    _overrideTimer?.cancel();
    _overrideTimer = null;
    final expiry = _control.nextOverrideExpiryMs;
    if (expiry == null || _shutdown) return;
    final delay = expiry - DateTime.now().millisecondsSinceEpoch;
    _overrideTimer = Timer(Duration(milliseconds: max(0, delay) + 1), () {
      _overrideTimer = null;
      _applyReplay();
      _scheduleOverrideExpiry();
    });
  }

  void _applyReplay() {
    final session = _sessions?.currentId;
    final settings = _control.settings;
    _replay.apply(
      _control.replayMode,
      maxAgeMs: (settings.bufferMaxAgeSeconds * 1000).round(),
      sessionSampled: session != null &&
          unitHash(session) < settings.replaySessionSampleRate,
    );
  }

  List<Map<String, dynamic>> _readLocalCaptures() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stored = _store.get('localCaptures');
    return [
      if (stored is List)
        for (final c in stored)
          if (c is Map &&
              c['id'] is String &&
              c['triggerId'] is String &&
              c['untilMs'] is int &&
              (c['untilMs'] as int) > now)
            c.cast<String, dynamic>(),
    ];
  }

  /// Local captures outlive the app run that started them, like the
  /// browser SDK's outlive a page: a restart keeps streaming until they end.
  void _restoreLocalCaptures() {
    for (final capture in _readLocalCaptures()) {
      final signals = capture['signals'];
      _control.setOverrides('local:${capture['triggerId']}', [
        StreamOverride(
          signals: signals is List ? signals.whereType<String>().toList() : const ['*'],
          untilMs: capture['untilMs'] as int,
          replay: capture['replay'] == true,
          includeOff: true,
        ),
      ]);
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
    final untilMs = now + ((action.durationSeconds ?? 0) * 1000).round();
    final signals = action.signals ?? const ['*'];
    final captures = _readLocalCaptures();
    Map<String, dynamic>? running;
    for (final c in captures) {
      if (c['triggerId'] == triggerId) running = c;
    }
    if (running != null) {
      running['untilMs'] = max(running['untilMs'] as int, untilMs);
    } else {
      final id = '$triggerId:$now';
      captures.add({
        'id': id,
        'triggerId': triggerId,
        'untilMs': untilMs,
        'signals': signals,
        'replay': action.replay,
      });
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
          'traceway.capture.id': id,
          'traceway.capture.source': 'trigger',
          'traceway.trigger.id': triggerId,
          'traceway.capture.until':
              DateTime.fromMillisecondsSinceEpoch(untilMs)
                  .toUtc()
                  .toIso8601String(),
        },
      );
    }
    _store.set('localCaptures', captures);
    _streamFor(
      signals,
      replay: action.replay,
      untilMs: (running?['untilMs'] as int?) ?? untilMs,
      capture: true,
      owner: 'local:$triggerId',
    );
  }

  void _confirmCaptures() {
    if (_capturesConfirmed || _shutdown) return;
    _capturesConfirmed = true;
    _runCaptures(_control.settings);
    _applyReplay();
  }

  /// Starts the dashboard's captures aimed at this app. The lookback flush
  /// runs once per capture, remembered across app starts; streaming lasts
  /// until the capture's end.
  void _runCaptures(Settings settings) {
    if (!_started) return;
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    _control.setOverrides('remote-captures', [
      for (final capture in settings.captures)
        if (capture.until.isAfter(now))
          StreamOverride(
            signals: capture.signals ?? const ['*'],
            replay: capture.replay,
            untilMs: capture.until.millisecondsSinceEpoch,
            includeOff: true,
          ),
    ]);
    _scheduleOverrideExpiry();
    if (!_capturesConfirmed) return;
    final stored = _store.get('captures');
    final done = <Map<String, Object>>[
      if (stored is List)
        for (final c in stored)
          if (c is Map &&
              c['id'] is String &&
              c['untilMs'] is int &&
              (c['untilMs'] as int) > nowMs)
            {'id': c['id'] as String, 'untilMs': c['untilMs'] as int},
    ];
    var changed = done.length != (stored is List ? stored.length : 0);
    for (final capture in settings.captures) {
      if (!capture.until.isAfter(now)) continue;
      if (done.any((c) => c['id'] == capture.id)) continue;
      final lookbackSeconds = capture.lookbackSeconds ?? 600;
      if (lookbackSeconds > 0) {
        _runAction(TriggerAction(
          type: 'flush',
          lookbackSeconds: lookbackSeconds,
          signals: capture.signals ?? const ['*'],
          replay: capture.replay,
        ));
      }
      _emit(
        eventName: eventCaptureStarted,
        severity: Severity.INFO,
        attributes: {
          'traceway.capture.id': capture.id,
          'traceway.capture.source': 'remote',
        },
      );
      done.add({
        'id': capture.id,
        'untilMs': capture.until.millisecondsSinceEpoch,
      });
      changed = true;
    }
    if (changed) _store.set('captures', done);
  }

  void _onSettingsChanged(Settings settings) {
    _runCaptures(settings);
    _buffer.retain((entry) => _control.canExport(entry.signal));
    _persisted?.retain(_control.canExport);
    if (!settings.persist) unawaited(_persisted?.clear());
    final maxAgeMs = (settings.bufferMaxAgeSeconds * 1000).round();
    _buffer.configure(maxBytes: settings.bufferMaxBytes, maxAgeMs: maxAgeMs);
    _triggers.setTriggers(settings.triggers);
    _restoreTriggerProgress();
    _sequenceKinds = {
      for (final trigger in _triggers.triggers)
        for (final step in trigger.steps) ...eventKinds(step.match),
    };
    if (!_sequenceKinds.contains('hover')) _hovered = const {};
    _observeScreenForSequences();
    _applyReplay();
    _metrics.configure();
  }

  /// Triggers that arrive after the app reached its current screen still see
  /// that screen once, as the browser SDK lets them see the page it loaded.
  void _observeScreenForSequences() {
    final screen = _currentScreen;
    // Before the SDK is ready the screen's own navigation record is still
    // queued, and the triggers see it when it is emitted.
    if (!_ready ||
        _screenObservedForSequences ||
        screen == null ||
        !_sequenceKinds.contains('navigation') ||
        !_control.enabled ||
        _sessions?.currentId == null ||
        !_options.captureNavigation) {
      return;
    }
    _screenObservedForSequences = true;
    _runFired(_triggers.observe(ObservedEvent(
      timeMs: DateTime.now().millisecondsSinceEpoch,
      lookup: _pageLookup({
        'event.name': eventNavigation,
        'signal': 'navigation',
        'attributes.url.full': screen,
      }),
    )));
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
    if (_options.captureMetrics) _vitals.lifecycleChanged(state);
    if (state == AppLifecycleState.resumed) {
      _sessions?.markActivity();
      unawaited(_opamp?.poll());
      unawaited(_outbox?.drain());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _replay.onPaused();
      if (_options.captureMetrics && _started) {
        _rememberMemoryPeak();
        // Stored before it is sent: the process may not live to see the
        // answer.
        unawaited(_metrics.flush(final_: true));
      }
      _saveTriggerProgress(now: true);
      unawaited(_persistBuffer());
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
