import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/exception_store.dart';
import 'package:traceway/src/models/exception_stack_trace.dart';
import 'package:traceway/src/models/session_recording_payload.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

const _dsn = 'token@https://example.com/api/report';

ExceptionStackTrace _makeException(String message) {
  return ExceptionStackTrace(
    stackTrace: 'Error: $message',
    recordedAt: DateTime.now(),
  );
}

int _jsonFileCount(Directory dir) {
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .length;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('traceway_client_disk_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  ExceptionStore createStore({
    int maxLocalFiles = 30,
    int maxAgeHours = 48,
  }) {
    return ExceptionStore(
      maxLocalFiles: maxLocalFiles,
      maxAgeHours: maxAgeHours,
      testDir: tempDir,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Client writes exceptions to disk
  // ═══════════════════════════════════════════════════════════════════════════

  group('TracewayClient disk persistence — write', () {
    test('addException writes file to disk when store is available', () async {
      final store = createStore();
      await store.init();

      TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      TracewayClient.instance!.addException(_makeException('disk write'));

      expect(_jsonFileCount(tempDir), 1);
    });

    test('addException assigns fileId to persisted exception', () async {
      final store = createStore();
      await store.init();

      TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      final exception = _makeException('check fileId');
      TracewayClient.instance!.addException(exception);

      expect(exception.fileId, isNotNull);
      expect(
          File('${tempDir.path}/${exception.fileId}.json').existsSync(), true);
    });

    test('multiple addException calls create separate files', () async {
      final store = createStore();
      await store.init();

      TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      for (var i = 0; i < 5; i++) {
        TracewayClient.instance!.addException(_makeException('e$i'));
      }

      expect(_jsonFileCount(tempDir), 5);
    });

    test('addException works even when store is unavailable (memory-only)',
        () async {
      // Store never init'd — available is false.
      final store = createStore();

      TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      final exception = _makeException('memory only');
      TracewayClient.instance!.addException(exception);

      expect(exception.fileId, isNull);
      expect(TracewayClient.instance!.pendingExceptionCount, 1);
      expect(_jsonFileCount(tempDir), 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Successful sync removes files
  // ═══════════════════════════════════════════════════════════════════════════

  group('TracewayClient disk persistence — sync removes files', () {
    test('successful sync removes files from disk', () async {
      final store = createStore();
      await store.init();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      client.addException(_makeException('will sync'));
      expect(_jsonFileCount(tempDir), 1);

      await client.flush(1000);

      expect(client.pendingExceptionCount, 0);
      expect(_jsonFileCount(tempDir), 0);
    });

    test('successful sync removes only the synced files', () async {
      final store = createStore();
      await store.init();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0, maxPendingExceptions: 10),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      client.addException(_makeException('a'));
      client.addException(_makeException('b'));
      expect(_jsonFileCount(tempDir), 2);

      await client.flush(1000);

      // Both should be synced and removed
      expect(client.pendingExceptionCount, 0);
      expect(_jsonFileCount(tempDir), 0);
    });

    test('failed sync keeps files on disk', () async {
      final store = createStore();
      await store.init();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, ___) async => false,
        store: store,
      );

      client.addException(_makeException('will fail'));
      expect(_jsonFileCount(tempDir), 1);

      await client.flush(1000);

      // Re-queued in memory AND file still on disk
      expect(client.pendingExceptionCount, 1);
      expect(_jsonFileCount(tempDir), 1);
    });

    test('sync exception keeps files on disk', () async {
      final store = createStore();
      await store.init();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, ___) async => throw Exception('network'),
        store: store,
      );

      client.addException(_makeException('will throw'));
      expect(_jsonFileCount(tempDir), 1);

      await client.flush(1000);

      expect(client.pendingExceptionCount, 1);
      expect(_jsonFileCount(tempDir), 1);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Trim removes files
  // ═══════════════════════════════════════════════════════════════════════════

  group('TracewayClient disk persistence — trim', () {
    test('trimPending removes disk files for dropped exceptions', () async {
      final store = createStore();
      await store.init();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999, maxPendingExceptions: 3),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      for (var i = 0; i < 5; i++) {
        client.addException(_makeException('e$i'));
      }

      // Only 3 kept in memory, the 2 oldest should be removed from disk too
      expect(client.pendingExceptionCount, 3);
      expect(_jsonFileCount(tempDir), 3);
    });

    test('trimPending after failed sync respects maxPendingExceptions',
        () async {
      final store = createStore();
      await store.init();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0, maxPendingExceptions: 2),
        reportSender: (_, __, ___) async => false,
        store: store,
      );

      client.addException(_makeException('a'));
      client.addException(_makeException('b'));
      await client.flush(1000);

      // Re-queued: 2 exceptions. Add one more → trim to 2.
      client.addException(_makeException('c'));

      expect(client.pendingExceptionCount, 2);
      expect(_jsonFileCount(tempDir), 2);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Load from disk on startup
  // ═══════════════════════════════════════════════════════════════════════════

  group('TracewayClient disk persistence — loadPendingFromDisk', () {
    test('loads previously persisted exceptions into memory', () async {
      // Phase 1: write files to disk via a store
      final store1 = createStore();
      await store1.init();
      store1.write(ExceptionStackTrace(
        stackTrace: 'Error: survived restart',
        recordedAt: DateTime.utc(2026, 4, 14),
      ));
      store1.write(ExceptionStackTrace(
        stackTrace: 'Error: also survived',
        recordedAt: DateTime.utc(2026, 4, 14),
      ));
      expect(_jsonFileCount(tempDir), 2);

      // Phase 2: new client loads from disk
      final store2 = createStore();
      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store2,
      );

      await client.loadPendingFromDisk();

      expect(client.pendingExceptionCount, 2);
      final traces =
          client.pendingExceptions.map((e) => e.stackTrace).toList();
      expect(traces, contains('Error: survived restart'));
      expect(traces, contains('Error: also survived'));
    });

    test('loaded exceptions have fileId set', () async {
      final store1 = createStore();
      await store1.init();
      final writtenId = store1.write(_makeException('persisted'))!;

      final store2 = createStore();
      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store2,
      );

      await client.loadPendingFromDisk();

      expect(client.pendingExceptions.first.fileId, writtenId);
    });

    test('loaded exceptions can be synced and files removed', () async {
      final store1 = createStore();
      await store1.init();
      store1.write(_makeException('to sync'));

      final store2 = createStore();
      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, ___) async => true,
        store: store2,
      );

      await client.loadPendingFromDisk();
      expect(client.pendingExceptionCount, 1);
      expect(_jsonFileCount(tempDir), 1);

      await client.flush(1000);

      expect(client.pendingExceptionCount, 0);
      expect(_jsonFileCount(tempDir), 0);
    });

    test('loads recordings alongside exceptions', () async {
      final store1 = createStore();
      await store1.init();
      final fileId = store1.write(_makeException('with video'))!;
      store1.writeRecording(
        fileId,
        SessionRecordingPayload(exceptionId: 'rec-99', events: []),
      );

      final store2 = createStore();
      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store2,
      );

      await client.loadPendingFromDisk();

      expect(client.pendingExceptionCount, 1);
      expect(client.pendingRecordingCount, 1);
    });

    test('applies maxPendingExceptions trim to loaded entries', () async {
      final store1 = createStore();
      await store1.init();
      for (var i = 0; i < 10; i++) {
        store1.write(_makeException('e$i'));
      }

      final store2 = createStore();
      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999, maxPendingExceptions: 3),
        reportSender: (_, __, ___) async => true,
        store: store2,
      );

      await client.loadPendingFromDisk();

      expect(client.pendingExceptionCount, 3);
    });

    test('no-op when disk directory is empty', () async {
      final store = createStore();
      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      await client.loadPendingFromDisk();
      expect(client.pendingExceptionCount, 0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // persistToDisk option
  // ═══════════════════════════════════════════════════════════════════════════

  group('TracewayClient disk persistence — persistToDisk option', () {
    test('persistToDisk false skips store init and disk writes', () async {
      final store = createStore();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999, persistToDisk: false),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      // loadPendingFromDisk should be a no-op
      await client.loadPendingFromDisk();
      expect(store.available, false);

      // addException should work (memory only), no file written
      client.addException(_makeException('memory only'));
      expect(client.pendingExceptionCount, 1);
      expect(_jsonFileCount(tempDir), 0);
    });

    test('persistToDisk false still syncs from memory', () async {
      final store = createStore();

      final client = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0, persistToDisk: false),
        reportSender: (_, __, ___) async => true,
        store: store,
      );

      await client.loadPendingFromDisk();
      client.addException(_makeException('mem sync'));
      await client.flush(1000);

      expect(client.pendingExceptionCount, 0);
    });

    test('persistToDisk true is the default', () {
      const options = TracewayOptions();
      expect(options.persistToDisk, true);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // End-to-end scenario
  // ═══════════════════════════════════════════════════════════════════════════

  group('TracewayClient disk persistence — end-to-end', () {
    test('crash recovery: write → "restart" → load → sync → clean', () async {
      // Simulate first app session that crashes before sync
      final store1 = createStore();
      await store1.init();
      final client1 = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 9999),
        reportSender: (_, __, ___) async => true,
        store: store1,
      );
      client1.addException(_makeException('crash before sync'));
      expect(_jsonFileCount(tempDir), 1);

      // Simulate app restart — new client, same disk directory
      String? sentBody;
      final store2 = createStore();
      final client2 = TracewayClient.initializeForTest(
        _dsn,
        const TracewayOptions(debounceMs: 0),
        reportSender: (_, __, body) async {
          sentBody = body;
          return true;
        },
        store: store2,
      );

      await client2.loadPendingFromDisk();
      expect(client2.pendingExceptionCount, 1);

      await client2.flush(1000);

      // Exception sent to backend
      expect(sentBody, isNotNull);
      expect(sentBody, contains('crash before sync'));

      // Disk cleaned up
      expect(client2.pendingExceptionCount, 0);
      expect(_jsonFileCount(tempDir), 0);
    });
  });
}
