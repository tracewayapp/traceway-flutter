import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'connection_string.dart';
import 'device_info_collector.dart';
import 'exception_store.dart';
import 'models/collection_frame.dart';
import 'models/exception_stack_trace.dart';
import 'models/report_request.dart';
import 'models/session_recording_payload.dart';
import 'screen_recorder.dart';
import 'stack_trace_formatter.dart';
import 'traceway_options.dart';
import 'transport.dart';

const _uuid = Uuid();

typedef ReportSender = Future<bool> Function(
    String apiUrl, String token, String body);

class TracewayClient {
  static TracewayClient? _instance;
  static TracewayClient? get instance => _instance;

  final String _apiUrl;
  final String _token;
  final TracewayOptions _options;
  final Random _random = Random();

  final List<ExceptionStackTrace> _pendingExceptions = [];
  final List<SessionRecordingPayload> _pendingRecordings = [];
  final List<Future<void>> _pendingEncodings = [];
  bool _isSyncing = false;
  Timer? _debounceTimer;
  Timer? _retryTimer;

  Map<String, String> _deviceAttributes = {};
  final ReportSender _reportSender;

  ScreenRecorder? screenRecorder;

  final ExceptionStore _store;

  TracewayClient._(
    this._apiUrl,
    this._token,
    this._options, {
    ReportSender? reportSender,
    ExceptionStore? store,
  })  : _reportSender = reportSender ?? sendReport,
        _store = store ??
            ExceptionStore(
              maxLocalFiles: _options.maxLocalFiles,
              maxAgeHours: _options.localFileMaxAgeHours,
              debug: _options.debug,
            );

  static TracewayClient initialize(
    String connectionString,
    TracewayOptions options,
  ) {
    final parsed = parseConnectionString(connectionString);
    final client = TracewayClient._(parsed.apiUrl, parsed.token, options);
    _instance = client;
    return client;
  }

  @visibleForTesting
  static TracewayClient initializeForTest(
    String connectionString,
    TracewayOptions options, {
    ReportSender? reportSender,
    ExceptionStore? store,
  }) {
    final parsed = parseConnectionString(connectionString);
    final client = TracewayClient._(
      parsed.apiUrl,
      parsed.token,
      options,
      reportSender: reportSender,
      store: store,
    );
    _instance = client;
    return client;
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    final client = _instance;
    if (client != null) {
      if (client._pendingEncodings.isNotEmpty) {
        await Future.wait(List.from(client._pendingEncodings));
      }
      await client.flush(1000);
      client._debounceTimer?.cancel();
      client._retryTimer?.cancel();
      client.screenRecorder?.stop();
      client.screenRecorder = null;
    }
    _instance = null;
  }

  bool get debug => _options.debug;
  TracewayOptions get options => _options;

  /// Initializes disk storage and loads any previously persisted exceptions
  /// into memory for syncing. Call once after [initialize].
  /// No-op when [TracewayOptions.persistToDisk] is false.
  Future<void> loadPendingFromDisk() async {
    if (!_options.persistToDisk) return;
    await _store.init();
    if (!_store.available) return;

    final entries = _store.loadAll();
    if (entries.isEmpty) return;

    for (final entry in entries) {
      entry.exception.fileId = entry.id;
      _pendingExceptions.add(entry.exception);
      if (entry.recording != null) {
        _pendingRecordings.add(entry.recording!);
      }
    }
    _trimPending();

    if (_options.debug) {
      print('Traceway: loaded ${entries.length} pending entries from disk');
    }

    if (_pendingExceptions.isNotEmpty) {
      _scheduleSync();
    }
  }

  @visibleForTesting
  int get pendingExceptionCount => _pendingExceptions.length;

  @visibleForTesting
  int get pendingRecordingCount => _pendingRecordings.length;

  @visibleForTesting
  List<ExceptionStackTrace> get pendingExceptions =>
      List.unmodifiable(_pendingExceptions);

  void collectSyncDeviceInfo() {
    _deviceAttributes = DeviceInfoCollector.collectSync();
    if (_options.debug) {
      print('Traceway: collected sync device info: $_deviceAttributes');
    }
  }

  Future<void> collectDeviceInfo() async {
    final asyncInfo = await DeviceInfoCollector.collectAsync();
    _deviceAttributes = {..._deviceAttributes, ...asyncInfo};
    if (_options.debug) {
      print('Traceway: collected async device info: $_deviceAttributes');
    }
  }

  @visibleForTesting
  void setDeviceAttributes(Map<String, String> attributes) {
    _deviceAttributes = Map.from(attributes);
  }

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

    if (_deviceAttributes.isNotEmpty) {
      exception.attributes = {
        ..._deviceAttributes,
        ...?exception.attributes,
      };
    }

    _pendingExceptions.add(exception);

    // Persist to disk (best-effort)
    final fileId = _store.write(exception);
    if (fileId != null) {
      exception.fileId = fileId;
    }

    _trimPending();

    if (screenRecorder != null) {
      final exceptionId = _uuid.v4();
      exception.sessionRecordingId = exceptionId;
      final future = screenRecorder!.captureRecording(exceptionId).then((recording) {
        if (recording != null) {
          final stillPending = _pendingExceptions
              .any((e) => e.sessionRecordingId == exceptionId);
          if (stillPending) {
            _pendingRecordings.add(recording);
            if (exception.fileId != null) {
              _store.writeRecording(exception.fileId!, recording);
            }
          }
        }
        _scheduleSync();
      });
      _pendingEncodings.add(future);
      future.whenComplete(() => _pendingEncodings.remove(future));
    } else {
      _scheduleSync();
    }
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

  void _trimPending() {
    while (_pendingExceptions.length > _options.maxPendingExceptions) {
      final dropped = _pendingExceptions.removeAt(0);
      if (dropped.sessionRecordingId != null) {
        _pendingRecordings
            .removeWhere((r) => r.exceptionId == dropped.sessionRecordingId);
      }
      if (dropped.fileId != null) {
        _store.remove([dropped.fileId!]);
      }
      if (_options.debug) {
        print('Traceway: dropped oldest exception (buffer full)');
      }
    }
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
      final jsonBody = jsonEncode(payload.toJson());
      if (_options.debug) {
        print('Traceway: payload_size_bytes=${utf8.encode(jsonBody).length}');
      }
      final success = await _reportSender(
        _apiUrl,
        _token,
        jsonBody,
      );
      if (!success) {
        failed = true;
        _pendingExceptions.insertAll(0, batch);
        _pendingRecordings.insertAll(0, recordings);
        _trimPending();
        if (_options.debug) {
          print('Traceway: sync failed, re-queued exceptions');
        }
      } else {
        // Sync succeeded — remove persisted files from disk
        final fileIds = batch.map((e) => e.fileId).whereType<String>().toList();
        if (fileIds.isNotEmpty) {
          _store.remove(fileIds);
        }
      }
    } catch (e) {
      failed = true;
      _pendingExceptions.insertAll(0, batch);
      _pendingRecordings.insertAll(0, recordings);
      _trimPending();
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

    // Wait for in-flight recordings to finish encoding before syncing.
    if (_pendingEncodings.isNotEmpty) {
      await Future.wait(List.from(_pendingEncodings));
    }

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
