import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/exception_store.dart';
import 'package:traceway/src/models/exception_stack_trace.dart';
import 'package:traceway/src/models/session_recording_payload.dart';

ExceptionStackTrace _makeException(String message) {
  return ExceptionStackTrace(
    stackTrace: 'Error: $message',
    recordedAt: DateTime.utc(2026, 4, 14, 12, 0, 0),
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
    tempDir = Directory.systemTemp.createTempSync('traceway_test_');
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
  // ExceptionStore core operations
  // ═══════════════════════════════════════════════════════════════════════════

  group('ExceptionStore init', () {
    test('creates directory and sets available', () async {
      final dir = Directory('${tempDir.path}/sub');
      final store = ExceptionStore(
        maxLocalFiles: 30,
        maxAgeHours: 48,
        testDir: dir,
      );
      await store.init();
      expect(store.available, true);
      expect(dir.existsSync(), true);
    });

    test('not available before init', () {
      final store = createStore();
      expect(store.available, false);
    });

    test('idempotent — can call init twice', () async {
      final store = createStore();
      await store.init();
      await store.init();
      expect(store.available, true);
    });
  });

  group('ExceptionStore write', () {
    test('persists exception as JSON file', () async {
      final store = createStore();
      await store.init();

      final exception = _makeException('test error');
      final fileId = store.write(exception);

      expect(fileId, isNotNull);
      final file = File('${tempDir.path}/$fileId.json');
      expect(file.existsSync(), true);

      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(data['exception']['stackTrace'], 'Error: test error');
      expect(data['createdAt'], isNotNull);
      expect(data['recording'], isNull);
    });

    test('returns unique IDs for each call', () async {
      final store = createStore();
      await store.init();

      final id1 = store.write(_makeException('a'));
      final id2 = store.write(_makeException('b'));
      final id3 = store.write(_makeException('c'));

      expect({id1, id2, id3}.length, 3);
    });

    test('returns null when store not initialized', () {
      final store = createStore();
      final id = store.write(_makeException('test'));
      expect(id, isNull);
    });

    test('preserves all exception fields', () async {
      final store = createStore();
      await store.init();

      final exception = ExceptionStackTrace(
        traceId: 'tid',
        isTask: true,
        stackTrace: 'Error: full',
        recordedAt: DateTime.utc(2026, 1, 1),
        attributes: {'key': 'value'},
        isMessage: true,
        sessionRecordingId: 'sid',
        distributedTraceId: 'did',
      );
      final fileId = store.write(exception)!;

      final file = File('${tempDir.path}/$fileId.json');
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final exc = data['exception'] as Map<String, dynamic>;

      expect(exc['traceId'], 'tid');
      expect(exc['isTask'], true);
      expect(exc['isMessage'], true);
      expect(exc['sessionRecordingId'], 'sid');
      expect(exc['distributedTraceId'], 'did');
      expect(exc['attributes']['key'], 'value');
    });
  });

  group('ExceptionStore writeRecording', () {
    test('updates existing file with recording data', () async {
      final store = createStore();
      await store.init();

      final fileId = store.write(_makeException('with recording'))!;

      final recording = SessionRecordingPayload(
        exceptionId: 'rec-123',
        events: [
          {'type': 'flutter_video', 'data': 'base64data'}
        ],
      );
      store.writeRecording(fileId, recording);

      final file = File('${tempDir.path}/$fileId.json');
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(data['recording'], isNotNull);
      expect(data['recording']['exceptionId'], 'rec-123');
      expect(
        (data['recording']['events'] as List).first['type'],
        'flutter_video',
      );
    });

    test('no-op for nonexistent file ID', () async {
      final store = createStore();
      await store.init();

      store.writeRecording(
        'nonexistent',
        SessionRecordingPayload(exceptionId: 'x', events: []),
      );
      // Should not throw, no files created
      expect(_jsonFileCount(tempDir), 0);
    });

    test('no-op when store not initialized', () {
      final store = createStore();
      store.writeRecording(
        'any-id',
        SessionRecordingPayload(exceptionId: 'x', events: []),
      );
      // No crash
    });
  });

  group('ExceptionStore remove', () {
    test('deletes specified files from disk', () async {
      final store = createStore();
      await store.init();

      final id1 = store.write(_makeException('one'))!;
      final id2 = store.write(_makeException('two'))!;

      store.remove([id1]);

      expect(File('${tempDir.path}/$id1.json').existsSync(), false);
      expect(File('${tempDir.path}/$id2.json').existsSync(), true);
    });

    test('removes multiple files at once', () async {
      final store = createStore();
      await store.init();

      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        ids.add(store.write(_makeException('e$i'))!);
      }

      store.remove([ids[0], ids[2], ids[4]]);

      expect(File('${tempDir.path}/${ids[0]}.json').existsSync(), false);
      expect(File('${tempDir.path}/${ids[1]}.json').existsSync(), true);
      expect(File('${tempDir.path}/${ids[2]}.json').existsSync(), false);
      expect(File('${tempDir.path}/${ids[3]}.json').existsSync(), true);
      expect(File('${tempDir.path}/${ids[4]}.json').existsSync(), false);
    });

    test('no-op for nonexistent file IDs', () async {
      final store = createStore();
      await store.init();

      store.remove(['nonexistent-id', 'another-missing']);
      // Should not throw
    });

    test('no-op when store not initialized', () {
      final store = createStore();
      store.remove(['any-id']);
      // No crash
    });
  });

  group('ExceptionStore loadAll', () {
    test('returns entries sorted by creation time', () async {
      final store = createStore();
      await store.init();

      store.write(_makeException('first'));
      store.write(_makeException('second'));
      store.write(_makeException('third'));

      final entries = store.loadAll();
      expect(entries.length, 3);
      expect(entries[0].exception.stackTrace, 'Error: first');
      expect(entries[1].exception.stackTrace, 'Error: second');
      expect(entries[2].exception.stackTrace, 'Error: third');
    });

    test('sets fileId on loaded exceptions', () async {
      final store = createStore();
      await store.init();

      final id = store.write(_makeException('test'))!;
      final entries = store.loadAll();

      expect(entries.length, 1);
      expect(entries[0].id, id);
      expect(entries[0].exception.fileId, id);
    });

    test('includes recording when present', () async {
      final store = createStore();
      await store.init();

      final id = store.write(_makeException('test'))!;
      store.writeRecording(
        id,
        SessionRecordingPayload(exceptionId: 'rec-1', events: []),
      );

      final entries = store.loadAll();
      expect(entries.length, 1);
      expect(entries[0].recording, isNotNull);
      expect(entries[0].recording!.exceptionId, 'rec-1');
    });

    test('returns null recording when not present', () async {
      final store = createStore();
      await store.init();

      store.write(_makeException('no-rec'));

      final entries = store.loadAll();
      expect(entries.length, 1);
      expect(entries[0].recording, isNull);
    });

    test('skips and deletes corrupt files', () async {
      final store = createStore();
      await store.init();

      store.write(_makeException('valid'));
      File('${tempDir.path}/corrupt.json').writeAsStringSync('not json{{{');

      final entries = store.loadAll();
      expect(entries.length, 1);
      expect(entries[0].exception.stackTrace, 'Error: valid');
      expect(File('${tempDir.path}/corrupt.json').existsSync(), false);
    });

    test('ignores non-json files', () async {
      final store = createStore();
      await store.init();

      store.write(_makeException('valid'));
      File('${tempDir.path}/readme.txt').writeAsStringSync('hello');

      final entries = store.loadAll();
      expect(entries.length, 1);
      // txt file untouched
      expect(File('${tempDir.path}/readme.txt').existsSync(), true);
    });

    test('returns empty list when store not initialized', () {
      final store = createStore();
      expect(store.loadAll(), isEmpty);
    });

    test('returns empty list when directory is empty', () async {
      final store = createStore();
      await store.init();
      expect(store.loadAll(), isEmpty);
    });
  });

  group('ExceptionStore pruning', () {
    test('pruneExpired removes files older than maxAgeHours on init', () async {
      final store = createStore(maxAgeHours: 1);
      await store.init();

      // Manually write an old file
      final oldData = jsonEncode({
        'createdAt': DateTime.now()
            .subtract(const Duration(hours: 2))
            .toUtc()
            .toIso8601String(),
        'exception': _makeException('old').toJson(),
      });
      File('${tempDir.path}/old-entry.json').writeAsStringSync(oldData);

      // Write a fresh one
      store.write(_makeException('fresh'));

      // Re-init triggers pruning
      await store.init();

      final entries = store.loadAll();
      expect(entries.length, 1);
      expect(entries[0].exception.stackTrace, 'Error: fresh');
    });

    test('pruneExpired keeps files within maxAgeHours', () async {
      final store = createStore(maxAgeHours: 48);
      await store.init();

      store.write(_makeException('recent'));

      await store.init();
      expect(store.loadAll().length, 1);
    });

    test('pruneExcess keeps only maxLocalFiles newest files', () async {
      final store = createStore(maxLocalFiles: 2);
      await store.init();

      store.write(_makeException('one'));
      store.write(_makeException('two'));
      store.write(_makeException('three'));

      // Re-init triggers pruning
      await store.init();

      expect(_jsonFileCount(tempDir), 2);
    });

    test('pruneExcess is no-op when under limit', () async {
      final store = createStore(maxLocalFiles: 10);
      await store.init();

      store.write(_makeException('one'));
      store.write(_makeException('two'));

      await store.init();
      expect(_jsonFileCount(tempDir), 2);
    });

    test('pruneExpired deletes corrupt files during pruning', () async {
      final store = createStore(maxAgeHours: 1);
      await store.init();

      File('${tempDir.path}/bad.json').writeAsStringSync('{corrupt');

      await store.init();
      expect(File('${tempDir.path}/bad.json').existsSync(), false);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Model serialization
  // ═══════════════════════════════════════════════════════════════════════════

  group('ExceptionStackTrace serialization', () {
    test('fromJson round-trips with toJson (all fields)', () {
      final original = ExceptionStackTrace(
        traceId: 'trace-1',
        isTask: true,
        stackTrace: 'Error: test',
        recordedAt: DateTime.utc(2026, 4, 14),
        attributes: {'os.name': 'ios', 'device.model': 'iPhone'},
        isMessage: true,
        sessionRecordingId: 'session-1',
        distributedTraceId: 'dtrace-1',
      );

      final json = original.toJson();
      final restored = ExceptionStackTrace.fromJson(json);

      expect(restored.traceId, 'trace-1');
      expect(restored.isTask, true);
      expect(restored.stackTrace, 'Error: test');
      expect(restored.recordedAt, DateTime.utc(2026, 4, 14));
      expect(restored.attributes, {'os.name': 'ios', 'device.model': 'iPhone'});
      expect(restored.isMessage, true);
      expect(restored.sessionRecordingId, 'session-1');
      expect(restored.distributedTraceId, 'dtrace-1');
    });

    test('fromJson handles minimal fields', () {
      final json = {
        'stackTrace': 'Error: minimal',
        'recordedAt': '2026-04-14T00:00:00.000Z',
      };

      final restored = ExceptionStackTrace.fromJson(json);
      expect(restored.stackTrace, 'Error: minimal');
      expect(restored.isTask, false);
      expect(restored.isMessage, false);
      expect(restored.traceId, isNull);
      expect(restored.attributes, isNull);
      expect(restored.sessionRecordingId, isNull);
      expect(restored.distributedTraceId, isNull);
    });

    test('fromJson handles empty attributes map', () {
      final json = {
        'stackTrace': 'Error: empty attrs',
        'recordedAt': '2026-04-14T00:00:00.000Z',
        'attributes': <String, dynamic>{},
      };

      final restored = ExceptionStackTrace.fromJson(json);
      expect(restored.attributes, isEmpty);
    });

    test('fileId is not included in toJson', () {
      final exception = _makeException('test');
      exception.fileId = 'some-file-id';

      final json = exception.toJson();
      expect(json.containsKey('fileId'), false);
    });
  });

  group('SessionRecordingPayload serialization', () {
    test('fromJson round-trips with toJson', () {
      final original = SessionRecordingPayload(
        exceptionId: 'exc-1',
        events: [
          {'type': 'flutter_video', 'data': 'base64...'}
        ],
        logs: [
          LogEvent(message: 'hello world'),
        ],
        actions: [
          CustomEvent(category: 'cart', name: 'add', data: {'sku': '123'}),
        ],
      );

      final json = original.toJson();
      final restored = SessionRecordingPayload.fromJson(json);

      expect(restored.exceptionId, 'exc-1');
      expect(restored.events.first['type'], 'flutter_video');
      expect(restored.logs.single.message, 'hello world');
      expect(restored.actions.single, isA<CustomEvent>());
    });

    test('fromJson handles empty events', () {
      final original = SessionRecordingPayload(
        exceptionId: 'exc-2',
        events: [],
      );

      final json = original.toJson();
      final restored = SessionRecordingPayload.fromJson(json);

      expect(restored.exceptionId, 'exc-2');
      expect(restored.events, isEmpty);
      expect(restored.logs, isEmpty);
      expect(restored.actions, isEmpty);
    });
  });
}
