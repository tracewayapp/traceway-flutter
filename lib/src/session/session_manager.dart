import 'dart:async';

import '../core/ids.dart';
import '../persistence/state_store.dart';

const int defaultInactivityMs = 15 * 60 * 1000;
const int defaultMaxDurationMs = 60 * 60 * 1000;
const String _storeKey = 'session';

class SessionInfo {
  const SessionInfo(this.id, this.startedAtMs);
  final String id;
  final int startedAtMs;
}

/// One session per app run, ended after [inactivityMs] without user activity
/// or [maxDurationMs] in total. A restart or a return from the background
/// inside the inactivity window continues the same session.
class SessionManager {
  SessionManager({
    required this.store,
    required this.onStart,
    required this.onEnd,
    this.inactivityMs = defaultInactivityMs,
    this.maxDurationMs = defaultMaxDurationMs,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final StateStore store;
  final void Function(SessionInfo session, bool resumed) onStart;
  final void Function(SessionInfo session, int endedAtMs) onEnd;
  final int inactivityMs;
  final int maxDurationMs;
  final int Function() _now;

  SessionInfo? _session;
  int _lastActivityMs = 0;
  int _segmentIndex = 0;
  int _lastPersistMs = 0;
  Timer? _timer;

  SessionInfo? get current => _session;
  String? get currentId => _session?.id;

  void start() {
    if (_timer != null) return;
    _open();
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _persist();
    _session = null;
  }

  /// Next index for a replay segment of this session.
  int nextSegmentIndex() {
    final index = _segmentIndex++;
    _persist();
    return index;
  }

  /// Notes user activity; an expired session is replaced first.
  void markActivity() {
    if (_timer == null) return;
    check();
    if (_session == null) _open();
    _lastActivityMs = _now();
    if (_lastActivityMs - _lastPersistMs > 5000) _persist();
  }

  /// Ends an expired session. The next activity starts its successor.
  void check() {
    final session = _session;
    if (session == null) return;
    final now = _now();
    final idle = now - _lastActivityMs >= inactivityMs;
    final tooLong = now - session.startedAtMs >= maxDurationMs;
    if (!idle && !tooLong) return;
    final endedAt = idle ? _lastActivityMs : now;
    _session = null;
    store.set(_storeKey, null);
    onEnd(session, endedAt);
  }

  void _open() {
    final now = _now();
    final stored = store.get(_storeKey);
    SessionInfo? resumed;
    if (stored is Map) {
      final id = stored['id'];
      final startedAt = stored['startedAtMs'];
      final lastActivity = stored['lastActivityMs'];
      if (id is String &&
          startedAt is int &&
          lastActivity is int &&
          now - lastActivity < inactivityMs &&
          now - startedAt < maxDurationMs) {
        resumed = SessionInfo(id, startedAt);
        _segmentIndex =
            stored['segmentIndex'] is int ? stored['segmentIndex'] as int : 0;
      }
    }
    if (resumed == null) _segmentIndex = 0;
    final session = resumed ?? SessionInfo(uuidv4(), now);
    _session = session;
    _lastActivityMs = now;
    _persist();
    onStart(session, resumed != null);
  }

  void _persist() {
    final session = _session;
    if (session == null) return;
    _lastPersistMs = _now();
    store.set(_storeKey, {
      'id': session.id,
      'startedAtMs': session.startedAtMs,
      'lastActivityMs': _lastActivityMs,
      'segmentIndex': _segmentIndex,
    });
  }
}
