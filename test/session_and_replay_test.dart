import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/models/session_recording_payload.dart';
import 'package:traceway/src/persistence/state_store.dart';
import 'package:traceway/src/replay/collection_budget.dart';
import 'package:traceway/src/replay/recordings_transport.dart';
import 'package:traceway/src/replay/replay_controller.dart';
import 'package:traceway/src/session/session_manager.dart';

import 'support.dart';

void main() {
  group('SessionManager', () {
    late int now;
    late List<String> events;
    SessionManager manager(StateStore store) => SessionManager(
          store: store,
          now: () => now,
          onStart: (s, resumed) =>
              events.add('${resumed ? 'resume' : 'start'}:${s.id}'),
          onEnd: (s, endedAt) => events.add('end:${s.id}@$endedAt'),
        );

    setUp(() {
      now = 1000000;
      events = [];
    });

    test('waits for activity after timeout even across an idle hour', () {
      final m = manager(StateStore(null))..start();
      final first = m.currentId!;
      now += 60000;
      m.markActivity();
      final lastActivity = now;
      now += defaultInactivityMs;
      m.check();
      for (var i = 0; i < 120; i++) {
        now += 30000;
        m.check();
      }
      expect(m.currentId, isNull);
      expect(events, ['start:$first', 'end:$first@$lastActivity']);
      m.markActivity();
      expect(m.currentId, isNot(first));
      expect(events, [
        'start:$first',
        'end:$first@$lastActivity',
        'start:${m.currentId}',
      ]);
      m.stop();
    });

    test('ends at the maximum duration even with activity', () {
      final m = manager(StateStore(null))..start();
      final first = m.currentId!;
      for (var i = 0; i < 13; i++) {
        now += 5 * 60000;
        m.markActivity();
      }
      expect(m.currentId, isNot(first));
      m.stop();
    });

    test('a restart inside the inactivity window resumes the session', () {
      final store = StateStore(null);
      final a = manager(store)..start();
      final id = a.currentId!;
      expect(a.nextSegmentIndex(), 0);
      a.stop();
      now += 60000;
      final b = manager(store)..start();
      expect(b.currentId, id);
      expect(b.nextSegmentIndex(), 1);
      expect(events.last, 'resume:$id');
      b.stop();
      now += defaultInactivityMs;
      final c = manager(store)..start();
      expect(c.currentId, isNot(id));
      c.stop();
    });
  });

  group('StateStore', () {
    test('persists values across instances', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_state');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = StateStore(dir);
      await a.load();
      a.set('k', {'n': 1});
      a.set('gone', 'x');
      a.set('gone', null);
      await a.flush();
      final b = StateStore(dir);
      await b.load();
      expect(b.get('k'), {'n': 1});
      expect(b.get('gone'), isNull);
    });

    test('a corrupt file starts empty', () async {
      final dir = Directory.systemTemp.createTempSync('traceway_state');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/state.json').writeAsStringSync('{not json');
      final store = StateStore(dir);
      await store.load();
      expect(store.get('k'), isNull);
    });
  });

  group('RecordingsTransport', () {
    RecordingSegment segment() => RecordingSegment(
          exceptionId: 'e1',
          events: [
            {'type': 'flutter_video', 'data': 'AAAA', 'format': 'mp4'}
          ],
          startedAt: DateTime.utc(2026, 1, 1),
          endedAt: DateTime.utc(2026, 1, 1, 0, 0, 10),
        );

    test('posts gzipped JSON with the bearer token', () async {
      late http.Request seen;
      final transport = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response('{}', 200);
        }),
      );
      transport.send([segment()]);
      await transport.flush();
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['Content-Encoding'], 'gzip');
      final body = jsonDecode(utf8.decode(gzip.decode(seen.bodyBytes))) as Map;
      final sent = (body['segments'] as List).single as Map;
      expect(sent['exceptionId'], 'e1');
      expect(sent['startedAt'], '2026-01-01T00:00:00.000Z');
      expect(sent.containsKey('sessionId'), isFalse);
      expect(transport.sentSegments, 1);
    });

    test('retries a transient failure and then delivers', () async {
      var calls = 0;
      final transport = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        retryDelaysMs: const [1, 1, 1],
        httpClient:
            MockClient((_) async => http.Response('', ++calls < 3 ? 503 : 200)),
      );
      transport.send([segment()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 3);
      expect(transport.sentSegments, 1);
      expect(transport.pending, 0);
    });

    test('keeps at most maxQueuedBytes waiting, dropping the oldest', () async {
      final transport = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        maxQueuedBytes: 10,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      for (var i = 0; i < 5; i++) {
        transport.send([segment()]);
      }
      expect(transport.pending, 2);
      expect(transport.failedSegments, 3);
      await transport.flush();
      expect(transport.sentSegments, 2);
    });

    test('gives up after the retry budget, and at once on a permanent error',
        () async {
      var calls = 0;
      final failing = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        retryDelaysMs: const [1, 1, 1],
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 500);
        }),
      );
      failing.send([segment()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 4);
      expect(failing.failedSegments, 1);
      expect(failing.pending, 0);

      calls = 0;
      final rejected = RecordingsTransport(
        url: 'https://h/api/recordings',
        token: 'tok',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 413);
        }),
      );
      rejected.send([segment()]);
      await rejected.flush();
      expect(calls, 1);
      expect(rejected.failedSegments, 1);
    });
  });

  group('ReplayController', () {
    late List<http.Request> posts;
    late DateTime now;
    var index = 0;
    String? session = 's1';
    ReplayController controller({int segmentMs = 8000}) => ReplayController(
          transport: RecordingsTransport(
            url: 'https://h/api/recordings',
            token: 'tok',
            httpClient: MockClient((request) async {
              posts.add(request);
              return http.Response('{}', 200);
            }),
          ),
          sessionId: () => session,
          nextSegmentIndex: () => index++,
          segmentMs: segmentMs,
          now: () => now,
        );

    List<Map<String, dynamic>> segments() => [
          for (final post in posts)
            for (final segment
                in (jsonDecode(utf8.decode(gzip.decode(post.bodyBytes)))
                    as Map)['segments'] as List)
              (segment as Map).cast<String, dynamic>(),
        ];

    setUp(() {
      posts = [];
      now = DateTime.utc(2026, 1, 1, 12);
      index = 0;
      session = 's1';
    });

    test('a capture flush without an exception is part of the session',
        () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      expect(c.flush(30000, null), isTrue);
      await c.drain();
      final segment = segments().single;
      expect(segment['sessionId'], 's1');
      expect(segment['segmentIndex'], 0);
      expect(segment.containsKey('exceptionId'), isFalse);
    });

    test('without a session or an exception there is nothing to attach to',
        () async {
      session = null;
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      expect(c.flush(30000, null), isFalse);
      expect(c.flush(30000, ''), isFalse);
      await c.drain();
      expect(source.captures, isEmpty);
      expect(posts, isEmpty);
    });

    test('the window is the smaller of the lookback and the buffer age',
        () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 4000);
      expect(c.flush(30000, 'e1'), isTrue);
      await c.drain();
      final capture = source.captures.single;
      expect(capture.until, now);
      expect(now.difference(capture.since!).inMilliseconds, 4000);
      expect(segments().single['exceptionId'], 'e1');
    });

    test('clips of one session never overlap, and every exception gets its window',
        () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      c.flush(30000, 'e1');
      final first = now;
      now = now.add(const Duration(seconds: 5));
      c.flush(30000, 'e2');
      await c.drain();
      final windows = {
        for (final capture in source.captures)
          capture.clipId: (capture.since, capture.until)
      };
      expect(windows['e2'], (now.subtract(const Duration(seconds: 30)), now));
      expect(windows['s1_1'], (first, now));
      final session = segments().where((s) => s['sessionId'] == 's1').toList();
      expect(session.map((s) => s['segmentIndex']), [0, 1]);
      final clip = segments().singleWhere((s) => s['exceptionId'] == 'e2');
      expect(clip.containsKey('sessionId'), isFalse);
    });

    test('stream uploads consecutive segments that start where the last ended',
        () async {
      final source = FakeReplaySource();
      final c = controller(segmentMs: 50)
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      // A capture: its lookback first, then streaming from there.
      c.flush(30000, null);
      final flushedUntil = now;
      c.apply(Mode.stream, maxAgeMs: 600000);
      expect(c.mode, Mode.stream);
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 8));
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }
      now = now.add(const Duration(seconds: 2));
      c.apply(Mode.buffer, maxAgeMs: 600000);
      await c.drain();
      final windows = source.captures.map((c) => (c.since, c.until)).toList();
      expect(windows.length, greaterThanOrEqualTo(4));
      expect(windows[1].$1, flushedUntil);
      for (var i = 1; i < windows.length; i++) {
        expect(windows[i].$1, windows[i - 1].$2, reason: 'segment $i');
      }
      final uploaded = segments();
      expect(uploaded.every((s) => s['sessionId'] == 's1'), isTrue);
      expect(uploaded.every((s) => !s.containsKey('exceptionId')), isTrue);
      expect(uploaded.map((s) => s['segmentIndex']),
          List.generate(uploaded.length, (i) => i));
    });

    test('an exception while streaming gets its own clip outside the session',
        () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.stream, maxAgeMs: 600000);
      now = now.add(const Duration(seconds: 3));
      expect(c.flush(30000, 'e1'), isTrue);
      await c.drain();
      final clip = segments().single;
      expect(clip['exceptionId'], 'e1');
      expect(clip.containsKey('sessionId'), isFalse);
      expect(now.difference(source.captures.single.since!).inSeconds, 30);
    });

    test('a slow encoder makes the next segment longer, not a queue', () async {
      final source = SlowReplaySource();
      final c = controller(segmentMs: 20)
        ..attach(source)
        ..apply(Mode.stream, maxAgeMs: 600000);
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(seconds: 8));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(source.pending, 1, reason: 'one encode at a time');
      source.release();
      now = now.add(const Duration(seconds: 8));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(source.windows, hasLength(2));
      expect(source.windows[1].$1, source.windows[0].$2);
      expect(source.windows[1].$2.difference(source.windows[1].$1).inSeconds,
          greaterThan(30));
      source.release();
      c.apply(Mode.buffer, maxAgeMs: 600000);
      source.release();
      await c.drain();
    });

    test('a session that is not sampled for replay keeps buffering', () {
      final c = controller()
        ..apply(Mode.stream, maxAgeMs: 600000, sessionSampled: false);
      expect(c.mode, Mode.buffer);
    });

    test('the last streamed segment belongs to the session that ended',
        () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.stream, maxAgeMs: 600000);
      now = now.add(const Duration(seconds: 4));
      session = null;
      c.onSessionEnd('s1');
      await c.drain();
      expect(segments().single['sessionId'], 's1');
    });

    test('a session stops uploading video once its budget is used', () async {
      final source = FakeReplaySource();
      final c = ReplayController(
        transport: RecordingsTransport(
          url: 'https://h/api/recordings',
          token: 'tok',
          httpClient: MockClient((request) async {
            posts.add(request);
            return http.Response('{}', 200);
          }),
        ),
        sessionId: () => session,
        nextSegmentIndex: () => index++,
        budget: CollectionBudget(maxBytes: 600),
        now: () => now,
      )
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      for (var i = 0; i < 4; i++) {
        c.flush(30000, 'e$i');
        now = now.add(const Duration(seconds: 60));
        await c.drain();
      }
      expect(segments(), hasLength(2));
      final snapshot = c.budget.snapshot('s1');
      expect(snapshot['traceway.collection.events'], 2);
      expect(snapshot['traceway.collection.dropped'], 2);
      expect(c.budget.snapshot('s2')['traceway.collection.events'], 0);
    });

    test('a session has replay while its first clip is still encoding',
        () async {
      final source = SlowReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      expect(c.hasReplayFor('s1'), isFalse);
      expect(c.flush(30000, null), isTrue);
      expect(source.pending, 1);
      expect(c.budget.hasUploaded('s1'), isFalse);
      expect(c.hasReplayFor('s1'), isTrue);
      expect(c.hasReplayFor('s2'), isFalse);
      source.release();
      await c.drain();
      expect(c.hasReplayFor('s1'), isTrue);
      expect(c.budget.hasUploaded('s1'), isTrue);
    });

    test('a clip that encodes to nothing leaves the session without replay',
        () async {
      final source = SlowReplaySource()..empty = true;
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      source.empty = false;
      expect(c.flush(30000, null), isTrue);
      source.empty = true;
      expect(c.hasReplayFor('s1'), isTrue);
      source.release();
      await c.drain();
      expect(c.hasReplayFor('s1'), isFalse);
    });

    test('off stops the source, clears frames and refuses to flush', () async {
      final source = FakeReplaySource();
      final c = controller()
        ..attach(source)
        ..apply(Mode.buffer, maxAgeMs: 600000);
      expect(source.running, isTrue);
      c.apply(Mode.off, maxAgeMs: 600000);
      expect(source.running, isFalse);
      expect(source.clears, greaterThan(0));
      expect(c.flush(30000, 'e1'), isFalse);
      await c.drain();
      expect(posts, isEmpty);
    });
  });
}

/// Encodes only when told to, like a device too slow for its encoder.
class SlowReplaySource extends FakeReplaySource {
  final List<(DateTime, DateTime)> windows = [];
  final List<Completer<void>> _waiting = [];
  int get pending => _waiting.length;

  void release() {
    for (final waiting in List.of(_waiting)) {
      waiting.complete();
    }
    _waiting.clear();
  }

  @override
  Future<SessionRecordingPayload?> captureRecording(
    String clipId, {
    DateTime? since,
    DateTime? until,
  }) async {
    windows.add((since!, until!));
    final waiting = Completer<void>();
    _waiting.add(waiting);
    await waiting.future;
    return super.captureRecording(clipId, since: since, until: until);
  }
}
