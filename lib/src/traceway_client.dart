import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'connection_string.dart';
import 'models/collection_frame.dart';
import 'models/exception_stack_trace.dart';
import 'models/report_request.dart';
import 'models/session_recording_payload.dart';
import 'screen_recorder.dart';
import 'stack_trace_formatter.dart';
import 'traceway_options.dart';
import 'transport.dart';

const _uuid = Uuid();

class TracewayClient {
  static TracewayClient? _instance;
  static TracewayClient? get instance => _instance;

  final String _apiUrl;
  final String _token;
  final TracewayOptions _options;
  final Random _random = Random();

  final List<ExceptionStackTrace> _pendingExceptions = [];
  final List<SessionRecordingPayload> _pendingRecordings = [];
  bool _isSyncing = false;
  Timer? _debounceTimer;
  Timer? _retryTimer;

  ScreenRecorder? screenRecorder;

  TracewayClient._(this._apiUrl, this._token, this._options);

  static TracewayClient initialize(
    String connectionString,
    TracewayOptions options,
  ) {
    final parsed = parseConnectionString(connectionString);
    final client = TracewayClient._(parsed.apiUrl, parsed.token, options);
    _instance = client;
    return client;
  }

  bool get debug => _options.debug;
  TracewayOptions get options => _options;

  bool _shouldSample() {
    if (_options.sampleRate >= 1.0) return true;
    if (_options.sampleRate <= 0.0) return false;
    return _random.nextDouble() < _options.sampleRate;
  }

  void addException(ExceptionStackTrace exception) {
    if (!_shouldSample()) {
      if (_options.debug) {
        print('Traceway: exception dropped by sampling');
      }
      return;
    }

    if (screenRecorder != null) {
      final exceptionId = _uuid.v4();
      exception.sessionRecordingId = exceptionId;
      screenRecorder!.captureRecording(exceptionId).then((recording) {
        if (recording != null) {
          _pendingRecordings.add(recording);
        }
      });
    }

    _pendingExceptions.add(exception);
    _scheduleSync();
  }

  void captureException(Object error, [StackTrace? stackTrace]) {
    final formatted = formatFlutterError(error, stackTrace);
    addException(ExceptionStackTrace(
      stackTrace: formatted,
      recordedAt: DateTime.now(),
      isMessage: false,
    ));
  }

  void captureMessage(String message) {
    addException(ExceptionStackTrace(
      stackTrace: message,
      recordedAt: DateTime.now(),
      isMessage: true,
    ));
  }

  void _scheduleSync() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      Duration(milliseconds: _options.debounceMs),
      () {
        _debounceTimer = null;
        _doSync();
      },
    );
  }

  Future<void> _doSync() async {
    if (_isSyncing) return;
    if (_pendingExceptions.isEmpty) return;

    _isSyncing = true;
    final batch = List<ExceptionStackTrace>.from(_pendingExceptions);
    final recordings = List<SessionRecordingPayload>.from(_pendingRecordings);
    _pendingExceptions.clear();
    _pendingRecordings.clear();

    final frame = CollectionFrame(
      stackTraces: batch,
      sessionRecordings: recordings.isNotEmpty ? recordings : null,
    );

    final payload = ReportRequest(
      collectionFrames: [frame],
      appVersion: _options.version,
      serverName: '',
    );

    bool failed = false;
    try {
      final success = await sendReport(
        _apiUrl,
        _token,
        jsonEncode(payload.toJson()),
      );
      if (!success) {
        failed = true;
        _pendingExceptions.insertAll(0, batch);
        _pendingRecordings.insertAll(0, recordings);
        if (_options.debug) {
          print('Traceway: sync failed, re-queued exceptions');
        }
      }
    } catch (e) {
      failed = true;
      _pendingExceptions.insertAll(0, batch);
      _pendingRecordings.insertAll(0, recordings);
      if (_options.debug) {
        print('Traceway: sync error: $e');
      }
    } finally {
      _isSyncing = false;
      if (_pendingExceptions.isNotEmpty) {
        if (failed) {
          _scheduleRetry();
        } else {
          _doSync();
        }
      }
    }
  }

  void _scheduleRetry() {
    if (_retryTimer != null) return;
    _retryTimer = Timer(
      Duration(milliseconds: _options.retryDelayMs),
      () {
        _retryTimer = null;
        _doSync();
      },
    );
  }

  Future<void> flush([int? timeoutMs]) async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    screenRecorder?.stop();

    final syncFuture = _doSync();

    if (timeoutMs != null) {
      await Future.any([
        syncFuture,
        Future.delayed(Duration(milliseconds: timeoutMs)),
      ]);
    } else {
      await syncFuture;
    }
  }
}
