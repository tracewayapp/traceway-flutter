import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart' as logging;
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
import 'guarded.dart';
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
import 'persistence/legacy_reports.dart';
import 'persistence/outbox.dart';
import 'persistence/state_store.dart';
import 'replay/recordings_transport.dart';
import 'replay/replay_controller.dart';
import 'replay/replay_source.dart';
import 'screen_recorder.dart';
import 'session/session_manager.dart';
import 'stack_trace_formatter.dart';
import 'sdk_version.dart';
import 'traceway_captured_error.dart';
import 'traceway_interaction.dart';
import 'traceway_log_level.dart';
import 'traceway_options.dart';
import 'traceway_screen_capture_mode.dart';
import 'wireframe/wireframe_recorder.dart';

export 'sdk_version.dart' show tracewaySdkName, tracewaySdkVersion;

const int _maxPendingBeforeReady = 500;
const int _maxErrorsPerMinute = 60;
const int _duplicateErrorWindowMs = 1000;
const int _maxGlobalAttributes = 64;
const int _defaultHealthDelayMs = 1000;
const int _maxHealthDelayMs = 300000;

/// Kept while the SDK starts even when breadcrumbs filled the queue.
const Set<String> _keptBeforeReady = {
  eventException,
  eventMessage,
  eventSessionStart,
  eventSessionEnd,
  eventSessionUpdate,
};

/// The running client, or null: set as [TracewayClient.instance] changes, so
/// the `Traceway` widget follows a client started after another was shut
/// down.
final ValueNotifier<TracewayClient?> tracewayClientChanges =
    ValueNotifier(null);

/// Replaces the parts of the SDK that touch the platform or the network, so
/// tests can run it against in-memory exporters and a fake server.
@visibleForTesting
class TracewayTestOverrides {
  TracewayTestOverrides({
    this.logExporter,
    this.spanExporter,
    this.httpClient,
    this.stateDirectory,
    this.legacyDirectory,
    this.deviceAttributes = const {},
    this.random,
    this.opampMinPollIntervalMs,
    this.videoSupported = true,
    this.appVitals = false,
    this.collectionHealthDelayMs,
  });

  final LogRecordExporter? logExporter;
  final SpanExporter? spanExporter;
  final http.Client? httpClient;

  /// `null` keeps state in memory only.
  final Directory? stateDirectory;
  final Directory? legacyDirectory;
  final Map<String, String> deviceAttributes;
  final double Function()? random;
  final int? opampMinPollIntervalMs;

  /// Whether the platform can encode video; tests attach a fake source.
  final bool videoSupported;

  /// Whether the frame, start and hang instrumentation runs. Metrics the
  /// app reports and requests, sessions and errors are recorded either way.
  final bool appVitals;

  /// The first delay of `traceway.collection.health` (1 s by default).
  final int? collectionHealthDelayMs;
}

class TracewayClient with WidgetsBindingObserver implements RouterHooks {
  TracewayClient._(
    String? connectionString,
    this._options,
    this._overrides,
  ) : _standalone = connectionString == null {
    guardedDebugLogging = _options.debug;
    if (connectionString != null) {
      final parsed = parseConnectionString(connectionString);
      _token = parsed.token;
      _endpoints = resolveEndpoints(parsed.apiUrl);
    } else if (_options.telemetry?.coversAllSignals != true) {
      throw ArgumentError('Without a connection string, TracewayOptions.'
          'telemetry needs a base url or all three signal endpoints');
    }
    _routes = TelemetryRoutes.resolve(_endpoints, _token, _options.telemetry);
    _globalAttributes.addAll(_options.attributes);
    if (_options.captureLogs) {
      _loggingSubscription = logging.Logger.root.onRecord.listen(
        (record) => guarded('logging record', () => _onLoggingRecord(record)),
        onError: (Object _) {},
      );
    }

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
    if (_screenCapture &&
        _options.screenCaptureMode == TracewayScreenCaptureMode.video &&
        !_videoSupported) {
      _log('this platform has no video encoder: the screen is recorded as '
          'a wireframe');
    }
    _control = ControlState(
      defaults,
      ceilingsFrom(
        screenCapture: recordsScreen,
        captureLogs: _options.captureLogs,
        captureNetwork: _options.captureNetwork,
        captureNavigation: _options.captureNavigation,
        captureUserActions: _options.captureUserActions,
        // Standalone, nothing receives the session rows; the session id
        // still correlates records and samples.
        sessions: _options.sessions && !_standalone,
        captureMetrics: _options.captureMetrics,
        replayImages: _options.replayImages,
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
      url: _endpoints?.recordings ?? '',
      token: _token ?? '',
      httpClient: _http,
      onFailed: _scheduleHealth,
    );
    // A streamed segment must leave before the frame ring buffer wraps.
    final ringMs =
        max(1, _options.maxBufferFrames) * 1000 ~/ _options.fps.clamp(1, 59);
    _replay = ReplayController(
      transport: _recordings,
      sessionId: () => _sessions?.currentId,
      nextSegmentIndex: () => _sessions?.nextSegmentIndex() ?? 0,
      segmentMs: (ringMs * 0.8).round().clamp(200, 10000),
      onBudgetExceeded: _scheduleHealth,
    );
    _metrics = MetricsRecorder(
      control: _control,
      sessionId: () => _sessions?.currentId,
      installationId: () => bytesToUuid(_instanceUid),
      resource: () => _resourceAttributes,
      send: _sendMetrics,
      store: () => _store,
      storageScope: _routes.metrics.key,
      scopeName: tracewaySdkName,
      scopeVersion: tracewaySdkVersion,
      dimensions: _options.metricDimensions,
      deferUntilStart: true,
    );
    _vitals = AppVitals(
      _metrics,
      currentScreen: () => _metricsScreen,
      // A breakpoint or a hot reload stops a debug build like a hang does.
      reportHangs: !kDebugMode || _options.reportHangsInDebug,
    );
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

  static void _setInstance(TracewayClient? client) {
    _instance = client;
    guarded('client change', () => tracewayClientChanges.value = client);
  }

  final TracewayOptions _options;
  final TracewayTestOverrides? _overrides;

  /// Without a connection string the SDK runs standalone: no OpAMP, no
  /// replay uploads, no session rows, and every record goes to the
  /// [TracewayOptions.telemetry] receivers.
  final bool _standalone;
  String? _token;
  TracewayEndpoints? _endpoints;
  late final TelemetryRoutes _routes;
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

  /// Errors the flood guard dropped since the SDK started.
  int _suppressedTotal = 0;

  Timer? _healthTimer;
  late int _healthDelayMs = _firstHealthDelayMs;
  late final int _firstHealthDelayMs =
      _overrides?.collectionHealthDelayMs ?? _defaultHealthDelayMs;

  /// Whether this session's row already heard that data was dropped.
  bool _healthReported = false;

  StateStore _store = StateStore(null);
  Outbox? _outbox;
  LegacyReports? _legacyReports;

  /// Traceway's queue when the live one belongs to another receiver: it
  /// takes the exceptions, messages and control records restored from disk
  /// when ordinary logs go elsewhere.
  Outbox? _tracewayOutbox;
  bool _splitsLogs = false;
  BufferPersistence? _persisted;
  SessionManager? _sessions;
  TelemetryRouter? _router;
  LogRecordProcessor? _logSink;
  SpanProcessor? _spanSink;
  LogRecordExporter? _logExporter;
  SpanExporter? _spanExporter;
  OTelLogger? _logger;
  Tracer? _tracer;
  OpampHttpClient? _opamp;
  Uint8List _instanceUid = Uint8List(16);
  ReplaySource? _screenRecorder;
  Timer? _flushTimer;
  Timer? _refreshTimer;
  bool _ready = false;
  bool _shutdown = false;
  LoggerProvider? _privateLoggerProvider;
  TracerProvider? _privateTracerProvider;

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
  /// Popups over it do not change it.
  String? _currentScreen;

  /// The current screen's route template, when the app or its router gave
  /// one.
  String? _currentRoute;

  /// The screen before [_currentScreen], and when the current one came.
  String? _previousScreen;
  int? _screenSinceMs;

  /// Event types (`click`, `hover`, `navigation`) the triggers name.
  Set<String> _sequenceKinds = const {};
  bool _screenObservedForSequences = false;
  Set<Element> _hovered = const {};
  Object? _hoverLeaf;

  bool get debug => _options.debug;
  TracewayOptions get options => _options;

  /// Whether the screen is recorded: screen capture is on and there is a
  /// Traceway to upload it to. Every platform can record a wireframe.
  bool get recordsScreen => _screenCapture;

  /// How the screen is recorded, or null when it is not. The [Traceway]
  /// widget swaps its recorder when this changes: `replay.captureMode` in
  /// the settings overrides [TracewayOptions.screenCaptureMode], and video
  /// falls back to a wireframe where there is no video encoder.
  ValueListenable<TracewayScreenCaptureMode?> get captureMode => _captureMode;
  late final ValueNotifier<TracewayScreenCaptureMode?> _captureMode =
      ValueNotifier(recordsScreen ? _wantedCaptureMode() : null);

  TracewayScreenCaptureMode _wantedCaptureMode() {
    final requested =
        _captureModeNamed(_control.settings.replayCaptureMode) ??
            _options.screenCaptureMode;
    return requested == TracewayScreenCaptureMode.video && !_videoSupported
        ? TracewayScreenCaptureMode.wireframe
        : requested;
  }

  static TracewayScreenCaptureMode? _captureModeNamed(Object? name) =>
      switch (name) {
        'video' => TracewayScreenCaptureMode.video,
        'wireframe' => TracewayScreenCaptureMode.wireframe,
        _ => null,
      };

  /// Follows the settings' capture mode. One session's replay is all video
  /// or all wireframe, since the dashboard plays it with one player: once
  /// some of it was uploaded, a change waits for the next session. The
  /// mode is saved with the session, which may resume after a restart.
  void _updateCaptureMode(String? session) {
    if (!recordsScreen) return;
    final wanted = _wantedCaptureMode();
    var mode = wanted;
    if (session != null) {
      final saved = _store.get('captureMode');
      final savedMode = saved is Map && saved['sessionId'] == session
          ? _captureModeNamed(saved['mode'])
          : null;
      if (savedMode != null &&
          savedMode != wanted &&
          (savedMode != TracewayScreenCaptureMode.video || _videoSupported) &&
          // A clip still being encoded counts: it uploads after a switch.
          _replay.hasReplayFor(session)) {
        mode = savedMode;
      }
      if (savedMode != mode) {
        _store.set('captureMode', {'sessionId': session, 'mode': mode.name});
      }
    }
    if (_captureMode.value == mode) return;
    final what =
        mode == TracewayScreenCaptureMode.video ? 'video' : 'a wireframe';
    _log('the screen is recorded as $what'
        '${mode != wanted ? ' until this session ends' : ''}');
    _captureMode.value = mode;
  }

  /// Screen recordings only go to Traceway: standalone there is nowhere to
  /// upload them.
  bool get _screenCapture => _options.screenCapture && !_standalone;

  bool get _remoteConfig => _options.remoteConfig && !_standalone;

  /// Completes when the SDK has finished starting and queued records have
  /// been emitted.
  Future<void> get ready => _readyCompleter.future;

  /// The effective collection settings after remote config and ceilings.
  @visibleForTesting
  Settings get settings => _control.settings;

  @visibleForTesting
  ControlState get control => _control;

  @visibleForTesting
  int get bufferedCount {
    _recordPrinted();
    return _buffer.length;
  }

  @visibleForTesting
  List<BufferEntry<TelemetryItem>> get bufferSnapshot {
    _recordPrinted();
    return _buffer.snapshot();
  }

  /// The current session, or null when sessions are off.
  String? get currentSessionId => _sessions?.currentId;

  @visibleForTesting
  ReplayController get replay => _replay;

  /// The screen recorder of the mounted [Traceway] widget, if any: a
  /// [ScreenRecorder] or a [WireframeRecorder].
  ReplaySource? get screenRecorder => _screenRecorder;
  set screenRecorder(ReplaySource? recorder) {
    _screenRecorder = recorder;
    _configureRecorder(recorder, _control.settings);
    _replay.attach(recorder);
  }

  /// What the settings say about privacy, for the recorder of either kind.
  static void _configureRecorder(ReplaySource? recorder, Settings settings) {
    if (recorder is WireframeRecorder) {
      recorder.maskAllInputs = settings.replayMaskAllInputs;
      recorder.networkImages = settings.replayImages != TracewayImagePolicy.off;
    } else if (recorder is ScreenRecorder) {
      recorder.maskAllInputs = settings.replayMaskAllInputs;
    }
  }

  /// Uses [source] instead of the screen recorder as the origin of clips.
  @visibleForTesting
  set replaySource(ReplaySource? source) {
    _replay.attach(source);
  }

  /// Starts the SDK. Without [connectionString] it runs standalone and
  /// sends everything to [TracewayOptions.telemetry].
  static TracewayClient initialize(
    String? connectionString,
    TracewayOptions options,
  ) {
    final existing = _instance;
    if (existing != null && !existing._shutdown && existing._stopping == null) {
      return existing;
    }
    final client = TracewayClient._(connectionString, options, null);
    _setInstance(client);
    unawaited(client._start());
    return client;
  }

  @visibleForTesting
  static Future<TracewayClient> initializeForTest(
    String? connectionString,
    TracewayOptions options, {
    TracewayTestOverrides? overrides,
  }) async {
    await resetForTest();
    final client = TracewayClient._(
        connectionString, options, overrides ?? TracewayTestOverrides());
    _setInstance(client);
    await client._start();
    return client;
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    final existing = _instance;
    _setInstance(null);
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
    _store = StateStore(stateDir,
        destination: _routes.traceway?.key ?? _bufferDestination);
    await _store.load();
    _replay.budget.store = _store;
    final legacyDirectory = _overrides == null && stateDir != null
        ? Directory('${stateDir.parent.path}/traceway_pending')
        : _overrides?.legacyDirectory;
    if (legacyDirectory != null) {
      OtlpDestination? target;
      final previous = _options.legacyConnectionString;
      if (previous != null) {
        try {
          final parsed = parseConnectionString(previous);
          target = OtlpDestination(
              parsed.apiUrl, {'Authorization': 'Bearer ${parsed.token}'});
        } on ArgumentError {
          _log(
              'Invalid 1.x connection string; legacy reports will expire on device.');
        }
      }
      final legacy =
          _legacyReports = LegacyReports(legacyDirectory, target, _http);
      unawaited(guardedAsync('legacy reports', legacy.drain));
    }

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
    if (_remoteConfig && cached is Map) {
      try {
        final body = cached['body'];
        final hash = cached['hash'];
        if (body is String && hash is String) {
          _control.applyRemote(parseSettingsDocument(body));
          appliedHash = hexToBytes(hash);
        }
      } catch (_) {
        appliedHash = null;
      }
    }

    await _buildResource();
    await _setUpOTel(stateDir);

    // Sessions always run: their id correlates records, samples and keys
    // trigger state. `sessions` only decides whether the session records
    // are sent.
    _sessions = SessionManager(
      store: _store,
      onStart: _onSessionStart,
      onEnd: _onSessionEnd,
    )..start();

    if (stateDir != null) {
      final persisted =
          BufferPersistence(stateDir, destination: _bufferDestination);
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

    final endpoints = _endpoints;
    if (_remoteConfig && endpoints != null) {
      _opamp = OpampHttpClient(
        endpoint: endpoints.opamp,
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
        onInstanceUidChange: _changeInstanceUid,
        onStopped: (code) => _log('remote config stopped (HTTP $code)'),
        httpClient: _http,
        minPollIntervalMs: _overrides?.opampMinPollIntervalMs ?? 30000,
      )..start();
    }
    _started = true;
    // Each step on its own: one that fails must not leave the ones after it
    // undone for the whole run.
    if (_options.captureMetrics) {
      guarded('metrics start', _metrics.start);
      if (_overrides?.appVitals ?? true) guarded('vitals start', _vitals.start);
    }
    guarded('local captures restore', _restoreLocalCaptures);
    guarded('settings apply', () => _onSettingsChanged(_control.settings));
    final opamp = _opamp;
    if (opamp == null) {
      guarded('captures confirm', _confirmCaptures);
    } else {
      unawaited(guardedAsync('first poll', opamp.poll).whenComplete(
          () => guarded('captures confirm', _confirmCaptures)));
    }
    guarded('outbox schedule', () {
      _outbox?.schedule(const Duration(seconds: 2));
      _tracewayOutbox?.schedule(const Duration(seconds: 2));
    });
    _log('started, instance ${bytesToUuid(_instanceUid)}');
  }

  /// The server gave this installation another id (it saw the old one on
  /// two devices, e.g. restored from a backup): records from now on carry
  /// it, not only the next run's.
  void _changeInstanceUid(Uint8List uid) {
    _instanceUid = uid;
    final id = bytesToUuid(uid);
    _store.set('instanceUid', id);
    _resourceAttributes['service.instance.id'] = id;
    try {
      final resource =
          OTel.resource(OTel.attributesFromMap(_resourceAttributes));
      _privateLoggerProvider?.resource = resource;
      _privateTracerProvider?.resource = resource;
    } catch (e) {
      _log('could not apply the new instance id: $e');
    }
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
      attrs.addAll(_options.captureDeviceInfo
          ? overrides.deviceAttributes
          : {
              for (final MapEntry(:key, :value)
                  in overrides.deviceAttributes.entries)
                if (key.startsWith('os.')) key: value,
            });
    } else {
      try {
        if (_options.captureDeviceInfo) {
          attrs.addAll(DeviceInfoCollector.collectSync());
          attrs.addAll(await DeviceInfoCollector.collectAsync()
              .timeout(const Duration(seconds: 2), onTimeout: () => {}));
        } else {
          // The operating system only: no model, name, address or locale.
          attrs.addAll(DeviceInfoCollector.collectOs());
        }
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

  /// Queues of receivers no longer configured: nothing would ever send
  /// them, so they only take space.
  static void _pruneOutboxes(Directory? stateDir, {String? keep}) {
    if (stateDir == null) return;
    try {
      for (final entry in stateDir.listSync()) {
        final name = entry.path.split(Platform.pathSeparator).last;
        if (entry is Directory && name.startsWith('outbox-') && name != keep) {
          entry.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
  }

  Map<String, String> get _tracewayAuth =>
      {if (_token != null) 'Authorization': 'Bearer $_token'};

  String get _bufferDestination => destinationDigest([
        _routes.traceway?.key ?? '',
        _routes.logs.key,
        _routes.traces.key,
        _routes.metrics.key,
      ]);

  String get _serviceName {
    final name = _options.serviceName;
    return name == null || name.isEmpty ? 'flutter-app' : name;
  }

  String get _serviceVersion =>
      _options.version.isEmpty ? 'unknown' : _options.version;

  Future<void> _setUpOTel(Directory? stateDir) async {
    Directory? dir(String name) => stateDir == null
        ? null
        : Directory('${stateDir.path}${Platform.pathSeparator}$name');
    // Records and batches, queued or stored on disk, whose signal a rule or
    // the kill switch turned off are not sent.
    bool admitLog(String? eventName) => canExportLog(_control, eventName);
    bool admitSpans() => _control.canExport('network');
    final routes = _routes;
    final endpoints = _endpoints;
    // Batches queued for Traceway stay in `outbox`, as before; batches for
    // another receiver wait in a directory of their own destinations.
    final tracewayOutbox = endpoints == null
        ? null
        : Outbox(
            directory: dir('outbox'),
            destinations: {
              'logs': OtlpDestination(endpoints.logs, _tracewayAuth),
              'traces': OtlpDestination(endpoints.traces, _tracewayAuth),
            },
            httpClient: _http,
            admitLog: admitLog,
            admitSpans: admitSpans,
          );
    final external = routes.logs.external || routes.traces.external;
    final externalName = external
        ? 'outbox-${destinationDigest([routes.logs.key, routes.traces.key])}'
        : null;
    final outbox = externalName == null && tracewayOutbox != null
        ? tracewayOutbox
        : Outbox(
            directory: dir(externalName ?? 'outbox'),
            destinations: {'logs': routes.logs, 'traces': routes.traces},
            httpClient: _http,
            admitLog: admitLog,
            admitSpans: admitSpans,
          );
    _outbox = outbox;
    // Drained too when it is not the live one, so what an earlier run left
    // there for Traceway still goes.
    _tracewayOutbox = identical(tracewayOutbox, outbox) ? null : tracewayOutbox;
    _splitsLogs = routes.splitsLogs;
    outbox.claim();
    _tracewayOutbox?.claim();
    _pruneOutboxes(stateDir, keep: externalName);
    final delay = Duration(
        milliseconds:
            _options.exportDelayMs < 50 ? 50 : _options.exportDelayMs);

    LogRecordExporter logExporter = _overrides?.logExporter ??
        OtlpLogExporter(routes.logs, outbox, _http, admit: admitLog);
    final tracewayLogs = routes.traceway;
    if (routes.splitsLogs && tracewayLogs != null && tracewayOutbox != null) {
      logExporter = RoutingLogExporter(
        logExporter,
        OtlpLogExporter(tracewayLogs, tracewayOutbox, _http, admit: admitLog),
      );
    }
    final spanExporter = _overrides?.spanExporter ??
        OtlpSpanExporter(routes.traces, outbox, _http, admit: admitSpans);
    _logExporter = logExporter;
    _spanExporter = spanExporter;
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
      logExporter: logExporter,
      spanExporter: spanExporter,
      hooks: this,
      persistIssue: stateDir == null || _overrides?.logExporter != null
          ? null
          : (tracewayOutbox ?? outbox).persistLog,
      random: _overrides?.random,
    );

    final logProcessor = ControlLogProcessor(() => _router, logSink);
    final spanProcessor = ControlSpanProcessor(() => _router, spanSink);
    // The OpenTelemetry SDK prints its own diagnostics, export failures
    // included; an app should only see them when it asked for debug output.
    if (OTelFactory.otelFactory is! OTelSDKFactory) {
      // The app has not set OpenTelemetry up (yet). The SDK needs a factory
      // installed, but one the app's own `OTel.initialize` may replace
      // later instead of failing, and global providers that send nothing:
      // the app's spans are not Traceway's.
      OTelLog.logFunction =
          _options.debug ? (message) => debugPrint('Traceway: $message') : null;
      await OTel.initialize(
        serviceName: _serviceName,
        serviceVersion: _serviceVersion,
        tracerName: tracewaySdkName,
        tracerVersion: tracewaySdkVersion,
        spanProcessor: _NoSpans(),
        logRecordProcessor: _NoLogs(),
        enableMetrics: false,
        detectPlatformResources: false,
        oTelFactoryCreationFunction: _ReplaceableOTelFactory.create,
      );
    }
    final factory = OTelFactory.otelFactory as OTelSDKFactory;
    // Private providers keep this installation's resource and lifetime
    // independent of the app's exporters and processors, whoever set
    // OpenTelemetry up.
    final resource = OTel.resource(OTel.attributesFromMap(_resourceAttributes));
    final logs = _privateLoggerProvider = factory.loggerProvider(
      endpoint: routes.logs.url,
      serviceName: _serviceName,
      serviceVersion: _serviceVersion,
      resource: resource,
    ) as LoggerProvider;
    final traces = _privateTracerProvider = factory.tracerProvider(
      endpoint: routes.traces.url,
      serviceName: _serviceName,
      serviceVersion: _serviceVersion,
      resource: resource,
    ) as TracerProvider;
    logs.addLogRecordProcessor(logProcessor);
    traces
      ..sampler = ParentBasedSampler(const AlwaysOnSampler())
      ..addSpanProcessor(spanProcessor);
    _logger = logs.getLogger(tracewaySdkName, version: tracewaySdkVersion);
    _tracer = traces.getTracer(tracewaySdkName, version: tracewaySdkVersion);
  }

  // ------------------------------------------------------------- public API

  /// The id this installation reports to the server (`service.instance.id`),
  /// usable to target it from the dashboard.
  String getInstanceId() => bytesToUuid(_instanceUid);

  void captureException(
    Object error, [
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  ]) =>
      guarded('captureException',
          () => _captureException(error, stackTrace, attributes));

  /// The error is the app's object: its `toString` may throw, and must not
  /// fail the call that reports it.
  void _captureException(
    Object error,
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  ) {
    final attrs = <String, Object>{..._screenContext(), ...?attributes};
    final message = safeToString(error);
    if (!_reports(TracewayCapturedError(
      error: error,
      stackTrace: stackTrace,
      type: error.runtimeType.toString(),
      message: message,
      attributes: Map.unmodifiable(attrs),
    ))) {
      return;
    }
    final raw = stackTrace == null ? null : safeToString(stackTrace);
    final obfuscated = raw != null && isNonSymbolicTrace(raw);
    // An obfuscated build renames classes on every build, so its type name
    // would split one issue into many: the message alone heads the trace,
    // and the raw frames go to the server to be symbolicated. A readable
    // trace is normalized so issues group the same on every platform.
    if (!obfuscated) attrs['exception.type'] = error.runtimeType.toString();
    attrs['exception.message'] = message;
    if (raw != null) {
      attrs['exception.stacktrace'] = obfuscated
          ? raw
          : formatException(error, stackTrace!, message: message);
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
    // An ignored error (a dropped connection) is not a crash either.
    guarded('crash count', () {
      if (_options.captureMetrics &&
          !_ignored('${error.runtimeType}: ${safeToString(error)}')) {
        _metrics.crash();
      }
    });
    captureException(error, stackTrace);
  }

  void captureMessage(String message, [Map<String, String>? attributes]) =>
      guarded('captureMessage', () => _captureMessage(message, attributes));

  void _captureMessage(String message, Map<String, String>? attributes) {
    final attrs = <String, Object>{..._screenContext(), ...?attributes};
    if (!_reports(TracewayCapturedError(
      message: message,
      isMessage: true,
      attributes: Map.unmodifiable(attrs),
    ))) {
      return;
    }
    _emit(
      eventName: eventMessage,
      severity: Severity.INFO,
      severityText: 'INFO',
      body: message,
      attributes: {...attrs, attrExceptionId: uuidv4()},
    );
  }

  /// Whether [captured] is reported: not matched by
  /// [TracewayOptions.ignoreErrors] and not dropped by
  /// [TracewayOptions.beforeCapture].
  bool _reports(TracewayCapturedError captured) {
    final type = captured.type;
    // `error.toString()` usually starts with the type already.
    final line = type == null || captured.message.startsWith(type)
        ? captured.message
        : '$type: ${captured.message}';
    if (_ignored(line)) return false;
    final before = _options.beforeCapture;
    if (before == null) return true;
    try {
      return before(captured);
    } catch (e) {
      _log('beforeCapture threw, the record is kept: $e');
      return true;
    }
  }

  /// Starts an interaction named [name] (`checkout`, `search`): a span the
  /// requests made in its [TracewayInteraction.run] are children of, and
  /// that the exceptions and logs recorded there point to. Call
  /// [TracewayInteraction.end] when the action is over. One started inside
  /// another's `run` is its child. Before the SDK has started (see
  /// [ready]) it records nothing.
  TracewayInteraction startInteraction(String name,
      {Map<String, Object>? attributes}) {
    final tracer = _tracer;
    Span? span;
    if (tracer != null && _ready && !_shutdown && name.isNotEmpty) {
      span = guardedOr<Span?>('startInteraction', null, () {
        final parent = currentInteraction?.context;
        return tracer.startSpan(
          name,
          kind: SpanKind.internal,
          context: parent,
          root: parent == null,
          attributes: OTel.attributesFromMap(
              {...?attributes, 'traceway.interaction': true}),
        );
      });
    }
    return TracewayInteraction.internal(span,
        captureException: captureException);
  }

  /// Patterns match the `Type: message` line only: matching the stack would
  /// let a function named like a pattern silence every error through it.
  /// A pattern of the app's that throws matches nothing.
  bool _ignored(String line) {
    final first = line.split('\n').first;
    for (final pattern in _options.ignoreErrors ?? defaultIgnoreErrors) {
      if (guardedOr(
          'ignoreErrors pattern',
          false,
          () => pattern is String
              ? first.contains(pattern)
              : pattern.allMatches(first).isNotEmpty)) {
        return true;
      }
    }
    return false;
  }

  /// Where the app was when an issue happened: the screen on top (popups
  /// over it aside), the one before it, how long it had been shown, and
  /// the size of the window in logical pixels. Read when the issue is
  /// captured, not when it is sent.
  Map<String, Object> _screenContext() {
    final screen = _currentScreen;
    final since = _screenSinceMs;
    String? viewport;
    try {
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (view != null && view.devicePixelRatio > 0) {
        final size = view.physicalSize / view.devicePixelRatio;
        if (!size.isEmpty) {
          viewport = '${size.width.round()}x${size.height.round()}';
        }
      }
    } catch (_) {
      // No binding: a plain Dart test.
    }
    return {
      if (screen != null && screen.isNotEmpty) 'app.screen.name': screen,
      if (_currentRoute != null) 'app.screen.route': _currentRoute!,
      if (_previousScreen != null && _previousScreen!.isNotEmpty)
        'app.screen.previous': _previousScreen!,
      if (screen != null && since != null)
        'app.screen.duration_ms':
            max(0, DateTime.now().millisecondsSinceEpoch - since),
      if (viewport != null) 'viewport': viewport,
    };
  }

  /// Records a custom breadcrumb, shown on the session timeline.
  void recordAction({
    required String category,
    required String name,
    Map<String, dynamic>? data,
  }) =>
      guarded('recordAction',
          () => _recordAction(category: category, name: name, data: data));

  void _recordAction({
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
        encoded = safeToString(data);
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
  void track(String eventName, [Map<String, Object>? attributes]) =>
      guarded('track', () {
        if (eventName.isEmpty) return;
        _emit(
          eventName: eventName,
          severity: Severity.INFO,
          attributes: {...?attributes},
        );
      });

  /// Sets an attribute attached to every later record and reported to the
  /// server for remote-config targeting.
  void setAttribute(String key, String value) =>
      guarded('setAttribute', () => _setAttribute(key, value));

  void _setAttribute(String key, String value) {
    if (key.isEmpty) return;
    if (!_globalAttributes.containsKey(key) &&
        _globalAttributes.length >= _maxGlobalAttributes) {
      return;
    }
    if (_globalAttributes[key] == value) return;
    _globalAttributes[key] = value;
    _attributesChanged();
  }

  void setAttributes(Map<String, String> attributes) =>
      guarded('setAttributes', () => attributes.forEach(setAttribute));

  void removeAttribute(String key) => guarded('removeAttribute', () {
        if (_globalAttributes.remove(key) != null) _attributesChanged();
      });

  void clearAttributes() => guarded('clearAttributes', () {
        if (_globalAttributes.isEmpty) return;
        _globalAttributes.clear();
        _attributesChanged();
      });

  /// The server keeps a session's attributes from its session events: a
  /// `user.id` set after sign-in reaches the session now, not when it ends.
  /// Changes made together send one update.
  void _attributesChanged() {
    _scheduleRefresh();
    _scheduleSessionUpdate();
  }

  /// Sends `traceway.session.update` for the current session soon; calls
  /// made together send one.
  void _scheduleSessionUpdate() {
    if (_sessionUpdateScheduled) return;
    _sessionUpdateScheduled = true;
    scheduleMicrotask(() => guarded('session update', () {
          _sessionUpdateScheduled = false;
          final session = _sessions?.current;
          if (_shutdown ||
              session == null ||
              !_reportedSessions.contains(session.id)) {
            return;
          }
          _emit(
            eventName: eventSessionUpdate,
            severity: Severity.INFO,
            attributes: _sessionAttributes(session),
          );
        }));
  }

  bool _sessionUpdateScheduled = false;

  /// Asks the server for collection settings now instead of at the next poll.
  Future<void> refreshConfig() => guardedAsync('refreshConfig', () async {
        await ready;
        await _opamp?.refresh();
      });

  /// A line the app printed (`print`, `debugPrint`). It has no level, so it
  /// is info. Lines are recorded once the code printing them returns, so a
  /// `package:logging` record the app prints itself is recorded once, with
  /// its level, and not again as a line.
  void recordLog(String line) {
    // The SDK's own debug output is not app telemetry. Nor is a line printed
    // while a record is emitted (OpenTelemetry's diagnostics, when the app
    // turned them on): recording it would print the next one, without end.
    // Nor the console dump of an error the SDK captured as an exception.
    if (line.startsWith('Traceway: ') || _emitDepth > 0 || _quietConsole > 0) {
      return;
    }
    if (_shutdown) return;
    _printed.add((line, DateTime.now(), Context.current));
    _endTurnLater();
  }

  /// Lines printed and not recorded yet, and the messages of the
  /// `package:logging` records published in this turn of the event loop.
  /// A line waits at most until the turn ends, or until anything else is
  /// recorded: an error thrown right after it still comes after it.
  final List<(String, DateTime, Context)> _printed = [];
  final List<String> _loggedThisTurn = [];
  bool _turnEnding = false;
  StreamSubscription<logging.LogRecord>? _loggingSubscription;

  /// While above zero, printed lines are not recorded: see
  /// [withoutConsoleCapture].
  int _quietConsole = 0;

  void _endTurnLater() {
    if (_turnEnding) return;
    _turnEnding = true;
    scheduleMicrotask(() {
      _turnEnding = false;
      guarded('printed lines', _recordPrinted);
      _loggedThisTurn.clear();
    });
  }

  void _recordPrinted() {
    if (_printed.isEmpty) return;
    final lines = List.of(_printed);
    _printed.clear();
    for (final (line, time, context) in lines) {
      if (_loggedThisTurn.any((message) => _echoes(line, message))) continue;
      _emitLog(line, TracewayLogLevel.info,
          time: time,
          context: context,
          attributes: const {'log.source': 'print'});
    }
  }

  /// Whether [line] is the app printing a logging record with [message]
  /// (`'INFO: 12:00: $message'`); a message over several lines is printed
  /// a line at a time by `debugPrint`.
  static bool _echoes(String line, String message) {
    if (message.isEmpty) return false;
    if (line.contains(message)) return true;
    final first = message.split('\n').first;
    if (first.length >= 8 && line.contains(first)) return true;
    final trimmed = line.trim();
    return trimmed.length >= 8 && message.contains(trimmed);
  }

  /// Runs [body] without recording what it prints, e.g. the console dump of
  /// an error already reported as an exception.
  T withoutConsoleCapture<T>(T Function() body) {
    _quietConsole++;
    try {
      return body();
    } finally {
      _quietConsole--;
    }
  }

  void _onLoggingRecord(logging.LogRecord record) {
    if (_shutdown) return;
    if (record.loggerName == 'Traceway') return;
    final message = record.message;
    _loggedThisTurn.add(message);
    _endTurnLater();
    _emitLog(
      message,
      _levelOf(record.level),
      time: record.time,
      error: record.error,
      stackTrace: record.stackTrace,
      attributes: {
        'log.source': 'logging',
        if (record.loggerName.isNotEmpty) 'logger.name': record.loggerName,
      },
    );
  }

  static TracewayLogLevel _levelOf(logging.Level level) {
    final value = level.value;
    if (value < logging.Level.FINE.value) return TracewayLogLevel.trace;
    if (value < logging.Level.CONFIG.value) return TracewayLogLevel.debug;
    if (value < logging.Level.WARNING.value) return TracewayLogLevel.info;
    if (value < logging.Level.SEVERE.value) return TracewayLogLevel.warn;
    if (value < logging.Level.SHOUT.value) return TracewayLogLevel.error;
    return TracewayLogLevel.fatal;
  }

  /// Records [message] as a log line at [level], shown on the session
  /// timeline with that level and filtered by the console's minimum
  /// severity in the remote settings. [error] and [stackTrace] are attached
  /// to it; to report an issue, use [captureException].
  void log(
    String message, {
    TracewayLogLevel level = TracewayLogLevel.info,
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? attributes,
  }) =>
      guarded('log', () {
        if (_shutdown || !_options.captureLogs) return;
        _emitLog(message, level,
            error: error,
            stackTrace: stackTrace,
            attributes: {...?attributes, 'log.source': 'api'});
      });

  void _emitLog(
    String message,
    TracewayLogLevel level, {
    DateTime? time,
    Context? context,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object> attributes = const {},
  }) {
    // The error is the app's: its `toString` may throw.
    final errorMessage = error == null ? null : safeToString(error);
    _emit(
      severity: level.severity,
      severityText: level.severityText,
      body: message,
      time: time,
      context: context,
      attributes: {
        ...attributes,
        if (error != null) ...{
          'exception.type': error.runtimeType.toString(),
          'exception.message': errorMessage!,
        },
        if (stackTrace != null)
          'exception.stacktrace': error != null
              ? formatException(error, stackTrace, message: errorMessage)
              : safeToString(stackTrace),
      },
    );
  }

  void recordNavigationEvent(NavigationEvent event) =>
      guarded('navigation', () => _recordNavigationEvent(event));

  void _recordNavigationEvent(NavigationEvent event) {
    _sessions?.markActivity();
    // A removal takes a route out of the stack without the user arriving
    // anywhere: it is on the timeline, but not a navigation triggers match.
    final arrived = event.action != 'remove';
    final to = arrived ? event.to : null;
    // A popup (a dialog, a sheet, a menu) shows over the screen: the screen
    // stays current, and so does its visit, which a loading dialog closing
    // must not end before the screen reports it is fully displayed.
    final route = _template(event.route);
    if (!event.overlay && to != null && to.isNotEmpty) {
      if (to != _currentScreen) {
        _previousScreen = _currentScreen;
        _currentScreen = to;
        _screenSinceMs = event.timestamp.millisecondsSinceEpoch;
        _currentRoute = route;
      } else if (route != null) {
        _currentRoute = route;
      }
    }
    if (_options.captureMetrics && arrived && !event.overlay) {
      _vitals.navigated(
        to == null || to.isEmpty ? null : route ?? normalizePath(to),
        event.action,
        event.timestamp,
        displayed: event.displayed,
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
        if (event.overlay) 'navigation.overlay': true,
        if (_currentScreen != null) 'app.screen.name': _currentScreen!,
        if (_currentRoute != null) 'app.screen.route': _currentRoute!,
      },
    );
  }

  /// The path of the route on top, as the last navigation reported it.
  String? get currentScreen => _currentScreen;

  /// The route template of the current screen, from [setRoute] or the
  /// navigation that reached it, or null.
  String? get currentRoute => _currentRoute;

  /// Names the current screen by its route template (`/orders/:id`), so
  /// metrics group by route and issues carry it (`app.screen.route`). Lasts
  /// until the next screen; null removes it. Without one, ids in the path
  /// are replaced (`/orders/8841` is `/orders/:id`).
  void setRoute(String? template) => guarded('setRoute', () {
        final route = _template(template);
        _currentRoute = route;
        if (route != null && _options.captureMetrics) {
          _vitals.routeNamed(route);
        }
      });

  static String? _template(String? template) {
    final trimmed = template?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final route = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return route.length > 64 ? route.substring(0, 64) : route;
  }

  /// The current screen as a metrics dimension: its route template, or its
  /// path with ids replaced (`/orders/8841` is `/orders/:id`), so every
  /// order is one series.
  String? get _metricsScreen {
    final route = _currentRoute;
    if (route != null) return route;
    final screen = _currentScreen;
    if (screen == null || screen.isEmpty) return null;
    // Read on every frame: the path is normalized once per screen.
    if (!identical(screen, _normalizedFor)) {
      _normalizedFor = screen;
      _normalized = normalizePath(screen);
    }
    return _normalized;
  }

  String? _normalizedFor;
  String? _normalized;

  // ---------------------------------------------------------------- metrics

  /// The screen on top shows everything it loads: ends its time to full
  /// display (`app.screen.ttfd`), measured from the navigation to it.
  void reportFullyDisplayed() => guarded('reportFullyDisplayed', () {
        if (_options.captureMetrics) _vitals.fullyDisplayed();
      });

  /// Observes [value] of an app-defined distribution, e.g.
  /// `checkout.duration`. Names are lowercase letters, digits, `_` and `.`,
  /// and may not start with `app.`, `browser.`, `traceway.` or `custom.`; at
  /// most two dimensions are kept.
  void recordMetric(String name, double value, [Map<String, Object>? dims]) =>
      guarded('metric', () {
        if (_options.captureMetrics) _metrics.metric(name, value, dims);
      });

  /// Adds [n] to an app-defined counter; see [recordMetric] for names.
  void recordCount(String name, [double n = 1, Map<String, Object>? dims]) =>
      guarded('count', () {
        if (_options.captureMetrics) _metrics.count(name, n, dims);
      });

  /// Sets an app-defined dimension on every metric from now on (sent as
  /// `custom.<key>`); null removes it. At most two keys.
  void setMetricDimension(String key, String? value) => guarded(
      'setMetricDimension', () => _metrics.setDimension(key, value));

  Future<int> _sendMetrics(List<int> body) =>
      postOtlp(_http, _routes.metrics, body);

  static int _maxRss() {
    try {
      return ProcessInfo.maxRss;
    } catch (_) {
      return 0;
    }
  }

  late final String _memoryKey = 'metricsMemory:${_routes.metrics.key}';

  static int _currentRss() {
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return 0;
    }
  }

  /// [ProcessInfo.maxRss] never goes down: a session after another in the
  /// same run would report the earlier one's peak. So the high-water mark
  /// counts only when it rose during the session; otherwise the session's
  /// own peak is the most the process used when sampled.
  int _maxRssAtSessionStart = 0;
  int _sampledRssPeak = 0;
  Timer? _rssTimer;

  void _sampleRss() {
    final rss = _currentRss();
    if (rss > _sampledRssPeak) _sampledRssPeak = rss;
  }

  void _sessionMemoryStarts() {
    _maxRssAtSessionStart = _maxRss();
    _sampledRssPeak = _currentRss();
    _rssTimer ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => guarded('memory sample', _sampleRss));
  }

  /// The most memory the current session used in this run.
  int _sessionRssPeak() {
    final high = _maxRss();
    if (high > _maxRssAtSessionStart) return high;
    _sampleRss();
    return _sampledRssPeak;
  }

  /// The process may be killed in the background: what the session used so
  /// far is kept, and observed when the session is known to have ended.
  void _rememberMemoryPeak() {
    final session = _sessions?.currentId;
    if (!_options.captureMetrics || session == null) return;
    final bytes = _memoryPeak(session);
    if (bytes > 0) _store.set(_memoryKey, {'s': session, 'b': bytes});
  }

  /// The most memory [session] used: now, or in an earlier run of the app.
  int _memoryPeak(String session) {
    final record = _store.get(_memoryKey);
    final remembered =
        record is Map && record['s'] == session && record['b'] is int
            ? record['b'] as int
            : 0;
    return max(_sessionRssPeak(), remembered);
  }

  void _recordMemoryPeak(String session) {
    if (!_options.captureMetrics) return;
    final bytes = _memoryPeak(session);
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
  void recordTap(Offset position, {int? viewId}) =>
      guarded('tap', () => _recordTap(position, viewId: viewId));

  void _recordTap(Offset position, {int? viewId}) {
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
  void recordHover(Offset position, {int? viewId}) =>
      guarded('hover', () => _recordHover(position, viewId: viewId));

  void _recordHover(Offset position, {int? viewId}) {
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

  /// Client spans of requests that carry a `traceparent`, open until their
  /// [NetworkEvent] arrives. Bounded: a request whose event never comes is
  /// forgotten, its span never sent.
  final Map<String, Span> _requestSpans = {};
  static const int _maxRequestSpans = 256;

  bool _isOwnRequest(String url) =>
      _endpoints?.isOwn(url) == true ||
      _routes.isOwn(url) ||
      _legacyReports?.destination?.url == url;

  /// The W3C `traceparent` to send with a request to [url], or null when
  /// [TracewayOptions.propagateTraceHeaderUrls] does not select it. Starts
  /// the request's client span now, so the header names it; the
  /// [NetworkEvent] that carries the header back ends it.
  String? traceparentFor(String method, Uri url, {DateTime? startTime}) =>
      guardedOr('trace header', null,
          () => _traceparentFor(method, url, startTime: startTime));

  String? _traceparentFor(String method, Uri url, {DateTime? startTime}) {
    final tracer = _tracer;
    final patterns = _options.propagateTraceHeaderUrls;
    if (patterns.isEmpty || tracer == null || !_ready || _shutdown) {
      return null;
    }
    final full = url.toString();
    if (_isOwnRequest(full) || !patterns.any((p) => _urlMatches(p, full))) {
      return null;
    }
    try {
      final parent = currentInteraction?.context;
      final span = tracer.startSpan(
        method.toUpperCase(),
        kind: SpanKind.client,
        context: parent,
        root: parent == null,
        startTime: startTime ?? DateTime.now(),
      );
      final context = span.spanContext;
      final header = '00-${context.traceId.hexString}-'
          '${context.spanId.hexString}-'
          '${context.traceFlags.isSampled ? '01' : '00'}';
      if (_requestSpans.length >= _maxRequestSpans) {
        _requestSpans.remove(_requestSpans.keys.first);
      }
      _requestSpans[header] = span;
      return header;
    } catch (e) {
      _log('trace header failed: $e');
      return null;
    }
  }

  /// The request named by [traceparent] did not send it after all: its
  /// span is recorded from its [NetworkEvent] instead.
  void forgetRequestSpan(String traceparent) =>
      guarded('trace header', () => _requestSpans.remove(traceparent));

  static bool _urlMatches(Pattern pattern, String url) => pattern is String
      ? url.startsWith(pattern)
      : pattern.allMatches(url).isNotEmpty;

  void recordNetworkEvent(NetworkEvent event) =>
      guarded('request', () => _recordNetworkEvent(event));

  void _recordNetworkEvent(NetworkEvent event) {
    if (_isOwnRequest(event.url)) return;
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
      final open = event.traceparent == null
          ? null
          : _requestSpans.remove(event.traceparent);
      final Span span;
      if (open != null) {
        span = open..addAttributes(OTel.attributesFromMap(attrs));
      } else {
        // A request made inside an interaction's `run` is part of it.
        final parent = currentInteraction?.context;
        span = tracer.startSpan(
          event.method,
          kind: SpanKind.client,
          context: parent,
          root: parent == null,
          attributes: OTel.attributesFromMap(attrs),
          startTime: end.subtract(event.duration),
        );
      }
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
  void markActivity() =>
      guarded('session activity', () => _sessions?.markActivity());

  /// Sends everything that is ready now: queued records, replay clips being
  /// encoded and telemetry that failed earlier. Telemetry still held in the
  /// ring buffer stays there.
  Future<void> flush([int? timeoutMs]) => guardedAsync('flush', () {
        final work = _flush();
        if (timeoutMs == null) return work;
        return work.timeout(Duration(milliseconds: timeoutMs),
            onTimeout: () {});
      });

  /// Each step on its own: one that fails does not keep the others from
  /// sending.
  Future<void> _flush() async {
    guarded('printed lines', _recordPrinted);
    await ready;
    _flushTimer?.cancel();
    _flushTimer = null;
    await guardedAsync('logs flush', () => _logSink?.forceFlush());
    await guardedAsync('spans flush', () => _spanSink?.forceFlush());
    await guardedAsync('buffer flush', () => _router?.settle());
    // The processors hand a batch over and forget it: wait for the
    // requests still on their way.
    await guardedAsync('logs export', () => _logExporter?.forceFlush());
    await guardedAsync('spans export', () => _spanExporter?.forceFlush());
    await guardedAsync('replay drain', _replay.drain);
    await guardedAsync('logs flush', () => _logSink?.forceFlush());
    await guardedAsync('logs export', () => _logExporter?.forceFlush());
    await guardedAsync('metrics flush', _metrics.flush);
    await guardedAsync('legacy reports', () => _legacyReports?.drain());
    await guardedAsync('outbox drain', () => _outbox?.drain());
    await guardedAsync('outbox drain', () => _tracewayOutbox?.drain());
    await guardedAsync('buffer save', _persistBuffer);
    guarded('trigger progress', () => _saveTriggerProgress(now: true));
    await guardedAsync('state save', _store.flush);
  }

  /// Flushes and stops the SDK. A new [initialize] call starts it again,
  /// also while this one is still stopping.
  Future<void> shutdown() =>
      _stopping ??= guardedAsync('shutdown', _shutdownOnce);

  /// Set as soon as [shutdown] is called.
  Future<void>? _stopping;

  Future<void> _shutdownOnce() async {
    if (_shutdown) return;
    try {
      final logging = _loggingSubscription;
      _loggingSubscription = null;
      await guardedAsync('logging cancel', () => logging?.cancel());
      await ready;
      guarded('session end', () {
        final session = _sessions?.current;
        if (session != null) {
          _emitSessionEnd(session, DateTime.now().millisecondsSinceEpoch);
        }
        // The session may go on after a restart: its memory is observed
        // when it ends.
        _rememberMemoryPeak();
      });
      guarded('vitals stop', _vitals.stop);
      await _flush();
      guarded('metrics stop', _metrics.stop);
    } finally {
      // Whatever failed above, the SDK stops.
      _shutdown = true;
      guarded('sessions stop', () => _sessions?.stop());
      guarded('opamp stop', () => _opamp?.stop());
      guarded('replay stop', _replay.stop);
      guarded('stop', () {
        _refreshTimer?.cancel();
        _overrideTimer?.cancel();
        _healthTimer?.cancel();
        _progressTimer?.cancel();
        _rssTimer?.cancel();
        _flushTimer?.cancel();
        WidgetsBinding.instance.removeObserver(this);
      });
      await guardedAsync('state save', _store.flush);
      // The app's OpenTelemetry, if it has one, keeps running.
      await guardedAsync(
          'logs shutdown', () => _privateLoggerProvider?.shutdown());
      await guardedAsync(
          'traces shutdown', () => _privateTracerProvider?.shutdown());
      // After the processors' last export: a batch that fails then is still
      // queued on disk for the next start.
      guarded('outbox dispose', () {
        _outbox?.dispose();
        _tracewayOutbox?.dispose();
      });
      if (identical(_instance, this)) _setInstance(null);
    }
  }

  // ------------------------------------------------------------- emission

  /// Breadcrumbs take at most [_maxPendingBeforeReady] places, so a chatty
  /// start cannot crowd out errors and session records ([keep]).
  void _queue(void Function() emit, {bool keep = false}) {
    final limit =
        keep ? 2 * _maxPendingBeforeReady : _maxPendingBeforeReady;
    if (_pending.length < limit) _pending.add(emit);
  }

  void _emit({
    String? eventName,
    Severity? severity,
    String? severityText,
    Object? body,
    Map<String, Object> attributes = const {},
    DateTime? time,
    Context? context,
  }) {
    if (_shutdown) return;
    final timestamp = time ?? DateTime.now();
    // An interaction's trace, when this was recorded inside its `run`.
    final traced = context ?? Context.current;
    // Lines printed before this record are recorded before it.
    if (_printed.isNotEmpty) _recordPrinted();
    if (!_ready) {
      _queue(
          () => _emit(
                eventName: eventName,
                severity: severity,
                severityText: severityText,
                body: body,
                attributes: attributes,
                time: timestamp,
                context: traced,
              ),
          keep: _keptBeforeReady.contains(eventName));
      return;
    }
    final logger = _logger;
    if (logger == null) return;
    _emitDepth++;
    try {
      logger.emit(
        timeStamp: timestamp,
        context: traced,
        severityNumber: severity,
        severityText: severityText,
        body: body,
        eventName: eventName,
        attributes:
            attributes.isEmpty ? null : OTel.attributesFromMap(attributes),
      );
    } catch (e) {
      _log('emit failed: $e');
    } finally {
      _emitDepth--;
    }
  }

  /// How many records are being emitted right now, one inside the other: a
  /// record runs the triggers, and an `emit` action emits the next one from
  /// inside them.
  int _emitDepth = 0;

  /// A rule may answer the event of another rule's `emit` action, this many
  /// deep. A rule that emits what it matches (on its own or in a circle)
  /// would otherwise never return.
  static const int _maxEmitDepth = 4;

  /// Sessions whose start (or resumption) was reported in this run: their
  /// end is reported too, and only theirs, whatever remote settings say by
  /// then, so the server never has a start without an end or the reverse.
  final Set<String> _reportedSessions = {};

  void _emitSessionEnd(SessionInfo session, int endedAtMs) {
    if (!_reportedSessions.remove(session.id)) return;
    _emit(
      eventName: eventSessionEnd,
      severity: Severity.INFO,
      time: DateTime.fromMillisecondsSinceEpoch(endedAtMs),
      attributes: _sessionAttributes(session),
    );
  }

  /// What every session event carries: the session, how much of its
  /// diagnostic budget replay used and what was dropped, shown on the
  /// session page.
  Map<String, Object> _sessionAttributes(SessionInfo session) => {
        attrSessionId: session.id,
        attrSessionStartedAt: session.startedAtMs,
        ..._replay.budget.snapshot(session.id),
        'traceway.replay.failed_segments': _recordings.failedSegments,
        'traceway.context.evicted': _buffer.evictedCount,
        'traceway.error.suppressed_total': _suppressedTotal,
        'traceway.replay.images': replayImagePolicy.name,
      };

  /// What replay may show of the app's images now: the `replay.images`
  /// setting under [TracewayOptions.replayImages], and `off` when the
  /// screen is not recorded.
  @visibleForTesting
  TracewayImagePolicy get replayImagePolicy => recordsScreen
      ? _control.settings.replayImages
      : TracewayImagePolicy.off;

  /// Tells the server that data was dropped: a `traceway.collection.health`
  /// record with the session's counters, after 1 s and then at most once
  /// per doubling delay (up to 5 minutes), as the browser SDK does. The
  /// first one in a session also updates the session row, whose closing
  /// event carries the totals.
  void _scheduleHealth() {
    if (_healthTimer != null || _shutdown) return;
    _healthTimer = Timer(Duration(milliseconds: _healthDelayMs), () {
      _healthTimer = null;
      guarded('collection health', _reportHealth);
    });
  }

  void _reportHealth() {
    final session = _sessions?.current;
    _emit(
      eventName: eventCollectionHealth,
      severity: Severity.INFO,
      attributes: {
        ..._replay.budget.snapshot(session?.id),
        'traceway.error.suppressed_total': _suppressedTotal,
        'traceway.context.evicted': _buffer.evictedCount,
        'traceway.replay.failed_segments': _recordings.failedSegments,
      },
    );
    if (session != null && !_healthReported) _scheduleSessionUpdate();
    _healthReported = true;
    _healthDelayMs = min(_healthDelayMs * 2, _maxHealthDelayMs);
  }

  void _onSessionStart(SessionInfo session, bool resumed) {
    // What an earlier session left behind is not this one's context.
    if (!resumed) {
      _buffer.clear();
      _persisted?.restored.clear();
    }
    _triggers.resetSession();
    _healthDelayMs = _firstHealthDelayMs;
    _healthReported = false;
    final limits = _store.get('triggerLimits');
    if (limits is Map && limits['sessionId'] == session.id) {
      _triggers.restoreSessionLimits(limits['limits']);
    }
    // [_sessions] is not assigned yet when the first session starts.
    guarded('trigger progress', () => _restoreTriggerProgress(session.id));
    guarded('replay session', _replay.onSessionStart);
    if (_options.captureMetrics) {
      guarded('session metrics', () {
        _settleMemoryPeak(session.id);
        _sessionMemoryStarts();
        _metrics.sessionStarted(session.id, resumed: resumed);
      });
    }
    if (_control.settings.sessionsEnabled) {
      _reportedSessions.add(session.id);
      _emit(
        eventName: resumed ? eventSessionUpdate : eventSessionStart,
        severity: Severity.INFO,
        time: resumed
            ? null
            : DateTime.fromMillisecondsSinceEpoch(session.startedAtMs),
        attributes: _sessionAttributes(session),
      );
    }
    guarded('replay apply', () => _applyReplay(sessionId: session.id));
    _scheduleRefresh();
  }

  void _onSessionEnd(SessionInfo session, int endedAtMs) {
    guarded('replay session', () => _replay.onSessionEnd(session.id));
    guarded('memory peak', () => _recordMemoryPeak(session.id));
    _emitSessionEnd(session, endedAtMs);
  }

  // ----------------------------------------------------------- RouterHooks

  @override
  String? get sessionId => _sessions?.currentId;

  @override
  String? globalAttribute(String key) => _globalAttributes[key];

  @override
  bool enrichLog(ReadWriteLogRecord record, String signal) {
    // Only session events carry traceway.session.started_at, as in the browser SDK: the server reads the
    // session's start from them and nothing else.
    final existing = record.attributes?.toMap() ?? const {};
    _globalAttributes.forEach((key, value) {
      if (!existing.containsKey(key)) {
        record.addAttribute(OTel.attributeString(key, value));
      }
    });
    if (signal == 'errors') {
      final key = '${existing['exception.type']?.value}:'
          '${existing['exception.message']?.value}';
      if (!_admitError(key)) {
        _suppressedTotal++;
        _scheduleHealth();
        return false;
      }
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
    // An error or message left out by its sample rate is as if it never
    // happened: it must not upload breadcrumbs or a clip of its own.
    if (observed.routed == Routed.filtered &&
        (observed.signal == 'errors' || observed.signal == 'messages')) {
      return;
    }
    if (observed.signal == 'navigation' &&
        _sequenceKinds.contains('navigation')) {
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
      final replayRequested = fired.any((f) =>
          f.trigger.actions.any((a) => a.replay || a.type == 'startReplay'));
      flushRequested = fired.any((f) => f.trigger.actions
          .any((a) => a.replay && (a.type == 'flush' || a.type == 'capture')));
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
      item.record.addAttribute(
          OTel.attributeDouble('traceway.context.lookback_seconds', lookback));
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

  /// Each trigger, and each of its actions, on its own: one that fails
  /// does not keep the others from running.
  void _runFired(List<FiredTrigger> fired) {
    for (final trigger in fired) {
      guarded('trigger', () => _runTrigger(trigger));
    }
    guarded('trigger limits', () {
      if (fired.isNotEmpty) {
        _store.set('triggerLimits', {
          'sessionId': _sessions?.currentId,
          'limits': _triggers.snapshotSessionLimits(),
        });
      }
      _saveTriggerProgress();
    });
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
      _progressTimer ??= Timer(
          const Duration(seconds: 2),
          () => guarded('trigger progress', () {
                _progressTimer = null;
                _saveTriggerProgress(now: true);
              }));
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

  void _restoreTriggerProgress(String? session, {Set<String>? only}) {
    final saved = _store.get('triggerProgress');
    if (saved is Map && session != null && saved['sessionId'] == session) {
      _triggers.restoreProgress(saved['progress'], null, only);
    }
  }

  void _runTrigger(FiredTrigger fired) {
    final raw = fired.cause.lookup('attributes.$attrExceptionId');
    final exceptionId = raw is String ? raw : null;
    for (final action in fired.trigger.actions) {
      guarded(
          'trigger action',
          () => _runAction(action,
              exceptionId: exceptionId, triggerId: fired.trigger.id));
    }
    final wantsReplay =
        fired.trigger.actions.any((a) => a.replay || a.type == 'startReplay');
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
        guarded('buffer flush',
            () => _router?.flushBuffered(now - lookbackMs, signals, now));
        guarded('restored flush',
            () => _flushRestored(now - lookbackMs, signals, now));
        if (action.replay &&
            guardedOr('replay flush', false,
                () => _replay.flush(lookbackMs, exceptionId))) {
          _replayFlushes++;
        }
        // The file must not hold records that just left, or a crash before
        // the next save would send them again after a restart.
        if (_persisted != null) {
          unawaited(guardedAsync('buffer save', _persistBuffer));
        }
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
        if (_emitDepth >= _maxEmitDepth) break;
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
    final bodies =
        persisted.take(sinceMs, signals, untilMs, _control.canExport);
    if (bodies.isEmpty) return;
    final traceway = _splitsLogs ? _tracewayOutbox : null;
    bodies.forEach((kind, requests) {
      for (final body in requests) {
        if (kind != 'logs' || traceway == null) {
          outbox.add(kind, body);
          continue;
        }
        final (own, rest) = splitLogsRequest(body);
        if (own != null) traceway.add(kind, own);
        if (rest != null) outbox.add(kind, rest);
      }
    });
    unawaited(guardedAsync('outbox drain', outbox.drain));
    if (traceway != null) {
      unawaited(guardedAsync('outbox drain', traceway.drain));
    }
  }

  Future<void> _persistBuffer() async {
    // Lines printed in this turn, before the app left, are kept too.
    _recordPrinted();
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
      guarded('override expiry', _applyReplay);
      guarded('override expiry', _scheduleOverrideExpiry);
    });
  }

  /// [sessionId]: the session starting, which [_sessions] does not report
  /// yet when it is the first.
  void _applyReplay({String? sessionId}) {
    final session = sessionId ?? _sessions?.currentId;
    _updateCaptureMode(session);
    final settings = _control.settings;
    _configureRecorder(_screenRecorder, settings);
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
          signals: signals is List
              ? signals.whereType<String>().toList()
              : const ['*'],
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
          'traceway.capture.until': DateTime.fromMillisecondsSinceEpoch(untilMs)
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
    guarded('captures', () => _runCaptures(_control.settings));
    guarded('replay apply', _applyReplay);
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
    guarded('captures', () => _runCaptures(settings));
    _buffer.retain((entry) => _control.canExport(entry.signal));
    _persisted?.retain(_control.canExport);
    if (!settings.persist) {
      unawaited(guardedAsync('buffer clear', () => _persisted?.clear()));
    }
    final maxAgeMs = (settings.bufferMaxAgeSeconds * 1000).round();
    _buffer.configure(maxBytes: settings.bufferMaxBytes, maxAgeMs: maxAgeMs);
    // Triggers that were already running keep their progress: what was saved
    // can be up to two seconds older, and would undo a fire.
    _restoreTriggerProgress(_sessions?.currentId,
        only: _triggers.setTriggers(settings.triggers));
    _sequenceKinds = {
      for (final trigger in _triggers.triggers)
        for (final step in trigger.steps) ...eventKinds(step.match),
    };
    if (!_sequenceKinds.contains('hover')) _hovered = const {};
    guarded('sequence screen', _observeScreenForSequences);
    guarded('replay apply', _applyReplay);
    guarded('metrics configure', _metrics.configure);
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

  /// At most the 1024 UTF-8 bytes the server reads of a value; it ignores
  /// longer ones.
  static String _clip(String value) {
    var bytes = 0;
    final out = StringBuffer();
    for (final rune in value.runes) {
      bytes += utf8.encode(String.fromCharCode(rune)).length;
      if (bytes > 1024) break;
      out.writeCharCode(rune);
    }
    return out.toString();
  }

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
    final hash = bytesToHex(config.configHash);
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
      unawaited(guardedAsync('config refresh', () => _opamp?.refresh()));
    });
  }

  // -------------------------------------------------------------- lifecycle

  /// An error should not wait for the batch delay: the app may be about to
  /// die.
  void _flushSoon() {
    _flushTimer ??= Timer(const Duration(milliseconds: 100), () {
      _flushTimer = null;
      _sendNow();
    });
  }

  void _sendNow() {
    unawaited(guardedAsync(
        'outbox drain', () => (_tracewayOutbox ?? _outbox)?.drain()));
    unawaited(guardedAsync('logs flush', () => _logSink?.forceFlush()));
    unawaited(guardedAsync('spans flush', () => _spanSink?.forceFlush()));
  }

  /// Each step on its own: what fails in one (a recorder, a disk) leaves
  /// the others, and the app's other observers, unaffected.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_shutdown) return;
    if (_options.captureMetrics) {
      guarded('vitals lifecycle', () => _vitals.lifecycleChanged(state));
    }
    if (state == AppLifecycleState.resumed) {
      // Clips that failed to encode while the app was away are made now.
      guarded('replay resume', _replay.onResumed);
      guarded('session activity', () => _sessions?.markActivity());
      unawaited(guardedAsync('config poll', () => _opamp?.pollIfDue()));
      unawaited(guardedAsync('legacy reports', () => _legacyReports?.drain()));
      unawaited(guardedAsync('outbox drain', () => _outbox?.drain()));
      unawaited(guardedAsync('outbox drain', () => _tracewayOutbox?.drain()));
    } else if (state == AppLifecycleState.inactive) {
      // About to leave: the last segment is cut while the app is still in
      // the foreground, where the platform's video encoder works.
      guarded('replay inactive', _replay.onInactive);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      guarded('replay pause', _replay.onPaused);
      if (_options.captureMetrics && _started) {
        guarded('memory peak', _rememberMemoryPeak);
        // Stored before it is sent: the process may not live to see the
        // answer.
        unawaited(
            guardedAsync('metrics flush', () => _metrics.flush(final_: true)));
      }
      guarded('trigger progress', () => _saveTriggerProgress(now: true));
      unawaited(guardedAsync('buffer save', _persistBuffer));
      _sendNow();
      unawaited(guardedAsync('state save', _store.flush));
    }
  }

  void _log(String message) {
    if (_options.debug) debugPrint('Traceway: $message');
  }
}

/// The OpenTelemetry factory the SDK installs when the app has none: the
/// SDK's own, except that it says it may be replaced, so an
/// `OTel.initialize` the app makes later installs the app's instead of
/// failing. Traceway keeps its private providers made from this one.
class _ReplaceableOTelFactory extends OTelSDKFactory {
  _ReplaceableOTelFactory({
    required super.apiEndpoint,
    required super.apiServiceName,
    required super.apiServiceVersion,
  }) : super(factoryFactory: create);

  static OTelFactory create({
    required String apiEndpoint,
    required String apiServiceName,
    required String apiServiceVersion,
  }) =>
      _ReplaceableOTelFactory(
        apiEndpoint: apiEndpoint,
        apiServiceName: apiServiceName,
        apiServiceVersion: apiServiceVersion,
      );

  @override
  bool get isAPIFactory => true;
}

/// What the global tracer provider does with spans while the app has not
/// set OpenTelemetry up: nothing, as without an SDK.
class _NoSpans implements SpanProcessor {
  @override
  Future<void> onStart(Span span, Context? parentContext) async {}

  @override
  Future<void> onEnd(Span span) async {}

  @override
  Future<void> onNameUpdate(Span span, String newName) async {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

/// The global logger provider's counterpart of [_NoSpans].
class _NoLogs implements LogRecordProcessor {
  @override
  Future<void> onEmit(ReadWriteLogRecord logRecord, Context? context) async {}

  @override
  bool enabled({
    Context? context,
    InstrumentationScope? instrumentationScope,
    Severity? severityNumber,
    String? eventName,
  }) =>
      false;

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}
