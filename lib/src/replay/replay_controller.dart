import 'dart:async';

import '../core/settings.dart';
import '../models/session_recording_payload.dart';
import 'recordings_transport.dart';

/// What the controller needs from the screen recorder; lets tests stand in
/// for the platform video encoder.
abstract class ReplaySource {
  bool get isRunning;
  void start();
  void stop();
  void clearBuffer();

  /// Encodes the frames buffered since [since] into one clip.
  Future<SessionRecordingPayload?> captureRecording(
    String exceptionId, {
    DateTime? since,
  });
}

/// Keeps the screen recording as a short on-device ring buffer and uploads a
/// clip only when a trigger asks for one for a specific exception.
///
/// There is no streaming mode: `off` stops recording and forgets the frames,
/// anything else buffers. The clip length is bounded by the recorder's frame
/// ring buffer (150 frames, about 10 s by default); remote settings can
/// shorten the window but never extend it.
class ReplayController {
  ReplayController({
    required this.transport,
    required this.sessionId,
    required this.nextSegmentIndex,
  });

  final RecordingsTransport transport;
  final String? Function() sessionId;
  final int Function() nextSegmentIndex;

  ReplaySource? _source;
  Mode _mode = Mode.off;
  int _maxAgeMs = 600000;
  final Set<Future<void>> _encodings = {};

  /// `off` or `buffer`.
  Mode get mode => _mode;

  void attach(ReplaySource? source) {
    if (source == null) _source?.stop();
    _source = source;
    _sync();
  }

  void apply(Mode mode, {required int maxAgeMs}) {
    _maxAgeMs = maxAgeMs;
    _mode = mode == Mode.off ? Mode.off : Mode.buffer;
    _sync();
  }

  void _sync() {
    final source = _source;
    if (source == null) return;
    if (_mode == Mode.off) {
      if (source.isRunning) source.stop();
      source.clearBuffer();
      transport.discard();
    } else if (!source.isRunning) {
      source.start();
    }
  }

  /// Uploads the frames of the last [lookbackMs] as the clip of
  /// [exceptionId]. Returns false when no clip can be made. A clip is never
  /// sent without an exception to attach it to.
  bool flush(int lookbackMs, String? exceptionId) {
    final source = _source;
    if (_mode == Mode.off ||
        source == null ||
        exceptionId == null ||
        exceptionId.isEmpty) {
      return false;
    }
    final windowMs = lookbackMs < _maxAgeMs ? lookbackMs : _maxAgeMs;
    final since = DateTime.now().subtract(Duration(milliseconds: windowMs));
    final session = sessionId();
    final future = () async {
      try {
        final recording =
            await source.captureRecording(exceptionId, since: since);
        if (recording == null || recording.events.isEmpty) return;
        if (_mode == Mode.off) return;
        transport.send([
          RecordingSegment(
            exceptionId: exceptionId,
            sessionId: session,
            segmentIndex: session == null ? null : nextSegmentIndex(),
            events: recording.events,
            startedAt: recording.startedAt,
            endedAt: recording.endedAt,
          ),
        ]);
      } catch (_) {
        // A failed encode loses the clip, never the app.
      }
    }();
    _encodings.add(future);
    future.whenComplete(() => _encodings.remove(future));
    return true;
  }

  /// Waits for clips being encoded and for their upload.
  Future<void> drain() async {
    await Future.wait(List.of(_encodings));
    await transport.flush();
  }

  void stop() {
    _source?.stop();
  }
}
