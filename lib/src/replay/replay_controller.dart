import 'dart:async';

import '../core/settings.dart';
import '../models/session_recording_payload.dart';
import 'collection_budget.dart';
import 'recordings_transport.dart';

/// What the controller needs from a screen recorder: the video recorder or
/// the wireframe recorder. Lets tests stand in for both.
abstract class ReplaySource {
  bool get isRunning;
  void start();
  void stop();
  void clearBuffer();

  /// Whether any frame was captured at or after [since] and before [until].
  bool hasFrames({DateTime? since, DateTime? until});

  /// Makes one clip of what was on screen at or after [since] and before
  /// [until]. The frames are chosen when this is called.
  Future<SessionRecordingPayload?> captureRecording(
    String clipId, {
    DateTime? since,
    DateTime? until,
  });
}

/// Runs the screen recording according to the replay mode, like the browser
/// SDK runs rrweb:
///
/// - `off` stops recording and forgets the frames.
/// - `buffer` keeps the last frames in the recorder's ring buffer (150
///   frames, about 10 s by default) and uploads a clip only when a trigger or
///   capture flushes it.
/// - `stream` (a capture or trigger that asks for replay, or a rule) uploads
///   the session as consecutive video segments, one every [segmentMs].
///
/// The session's segments never overlap: each starts where the previous one
/// uploaded for the session ended, so the dashboard plays them in a row.
class ReplayController {
  ReplayController({
    required this.transport,
    required this.sessionId,
    required this.nextSegmentIndex,
    this.segmentMs = 8000,
    CollectionBudget? budget,
    DateTime Function()? now,
  })  : budget = budget ?? CollectionBudget(),
        _now = now ?? DateTime.now;

  final RecordingsTransport transport;
  final String? Function() sessionId;
  final int Function() nextSegmentIndex;
  final CollectionBudget budget;

  /// How long a streamed segment is. Must stay below the frame ring buffer's
  /// length, or frames are evicted before they are uploaded.
  int segmentMs;
  final DateTime Function() _now;

  ReplaySource? _source;
  Mode _mode = Mode.off;
  int _maxAgeMs = 600000;
  final Set<Future<void>> _encodings = {};
  Timer? _segmentTimer;

  /// The end of the last frames uploaded as part of the current session.
  DateTime? _sessionCursor;

  Mode get mode => _mode;

  void attach(ReplaySource? source) {
    final previous = _source;
    if (previous != null && !identical(previous, source)) previous.stop();
    if (source == null) _stopTimer();
    _source = source;
    _sync();
  }

  /// [sessionSampled] is whether the session falls inside
  /// `replay.sessionSampleRate`; sessions outside it never stream.
  void apply(Mode mode, {required int maxAgeMs, bool sessionSampled = true}) {
    _maxAgeMs = maxAgeMs;
    final effective =
        mode == Mode.stream && !sessionSampled ? Mode.buffer : mode;
    final previous = _mode;
    if (previous == Mode.stream && effective != Mode.stream) {
      // What was recorded since the last segment still belongs to the
      // session that was streaming.
      _cutSegment();
    }
    _mode = effective;
    if (effective == Mode.stream && previous != Mode.stream) {
      final now = _now();
      final cursor = _sessionCursor;
      // Right after a lookback flush (a capture), streaming continues where
      // the flushed clip ended; otherwise it starts now.
      if (cursor == null || now.difference(cursor).inMilliseconds > 1000) {
        _sessionCursor = now;
      }
    }
    _sync();
  }

  void _sync() {
    final source = _source;
    if (_mode != Mode.stream) _stopTimer();
    if (source == null) return;
    if (_mode == Mode.off) {
      if (source.isRunning) source.stop();
      source.clearBuffer();
      transport.discard();
      _sessionCursor = null;
      return;
    }
    if (!source.isRunning) source.start();
    if (_mode == Mode.stream) {
      _segmentTimer ??= Timer.periodic(
          Duration(milliseconds: segmentMs), (_) => _cutSegment(timed: true));
    }
  }

  void _stopTimer() {
    _segmentTimer?.cancel();
    _segmentTimer = null;
  }

  /// Uploads the frames of the last [lookbackMs]. With [exceptionId] the
  /// clip is that exception's; without, it is part of the session (a
  /// capture's lookback). Returns false when no clip can be made.
  bool flush(int lookbackMs, String? exceptionId) {
    final source = _source;
    if (_mode == Mode.off || source == null) return false;
    final until = _now();
    final windowMs = lookbackMs < _maxAgeMs ? lookbackMs : _maxAgeMs;
    final since = until.subtract(Duration(milliseconds: windowMs));
    final hasException = exceptionId != null && exceptionId.isNotEmpty;

    if (_mode == Mode.stream) {
      if (!hasException) {
        // The session already streams; a capture's lookback adds nothing.
        _cutSegment();
        return true;
      }
      // The exception gets a clip of its own. It is not part of the
      // session, whose segments are streamed anyway.
      if (!source.hasFrames(since: since, until: until)) return false;
      _encode(since: since, until: until, exceptionId: exceptionId);
      return true;
    }

    final session = sessionId();
    if (session == null && !hasException) return false;
    var from = since;
    final cursor = _sessionCursor;
    if (session != null && cursor != null && cursor.isAfter(from)) {
      from = cursor;
    }
    var clipped = false;
    if (hasException && from != since) {
      // Part of the window already went up with the session: the exception
      // still gets a clip of the whole window, outside the session.
      if (!source.hasFrames(since: since, until: until)) return false;
      _encode(since: since, until: until, exceptionId: exceptionId);
      clipped = true;
    }
    if (!source.hasFrames(since: from, until: until)) return clipped;
    _encode(
      since: from,
      until: until,
      exceptionId: hasException && !clipped ? exceptionId : null,
      session: session,
      index: session == null ? null : nextSegmentIndex(),
    );
    if (session != null) _sessionCursor = until;
    return true;
  }

  /// Streams what was recorded since the last segment of the session.
  /// [session] overrides the current session, for the one that just ended.
  /// A [timed] cut waits while an earlier clip is still encoding: on a
  /// device too slow to keep up the next segment covers more instead of
  /// clips piling up in memory, and frames the ring buffer drops meanwhile
  /// are lost.
  void _cutSegment({String? session, bool timed = false}) {
    final source = _source;
    final id = session ?? sessionId();
    if (source == null || id == null || _mode != Mode.stream) return;
    if (timed && _encodings.isNotEmpty) return;
    final until = _now();
    final since = _sessionCursor ??
        until.subtract(Duration(milliseconds: segmentMs));
    _sessionCursor = until;
    if (!since.isBefore(until) ||
        !source.hasFrames(since: since, until: until)) {
      return;
    }
    _encode(since: since, until: until, session: id, index: nextSegmentIndex());
  }

  void _encode({
    required DateTime since,
    required DateTime until,
    String? exceptionId,
    String? session,
    int? index,
  }) {
    final source = _source!;
    final clipId = exceptionId ?? '${session}_$index';
    // An exception's clip outside the session still counts against the
    // budget of the session it happened in.
    final budgetSession = session ?? sessionId();
    final recording = source.captureRecording(clipId, since: since, until: until);
    final future = () async {
      try {
        final clip = await recording;
        if (clip == null || clip.events.isEmpty || _mode == Mode.off) return;
        final segment = RecordingSegment(
          exceptionId: exceptionId,
          sessionId: session,
          segmentIndex: index,
          events: clip.events,
          startedAt: clip.startedAt,
          endedAt: clip.endedAt,
          approxBytes: clip.approxBytes,
        );
        if (!budget.admit(
            budgetSession, 256 + segment.bytes, clip.events.length)) {
          return;
        }
        transport.send([segment]);
      } catch (_) {
        // A failed encode loses the clip, never the app.
      }
    }();
    _encodings.add(future);
    future.whenComplete(() => _encodings.remove(future));
  }

  /// The session ended: a streaming one uploads its last segment under the
  /// session it belongs to.
  void onSessionEnd(String endedSessionId) {
    _cutSegment(session: endedSessionId);
    _sessionCursor = null;
  }

  void onSessionStart() {
    _sessionCursor = _mode == Mode.stream ? _now() : null;
  }

  /// The app went to the background and may be killed there: a streaming
  /// session uploads what it has.
  void onPaused() => _cutSegment();

  /// Waits for clips being encoded and for their upload.
  Future<void> drain() async {
    await Future.wait(List.of(_encodings));
    await transport.flush();
  }

  void stop() {
    _stopTimer();
    _source?.stop();
  }
}
