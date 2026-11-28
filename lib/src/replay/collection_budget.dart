import '../persistence/state_store.dart';

/// Bounds what replay uploads per session, as the browser SDK does: 50 MiB
/// and 10,000 events (a video clip is one event; a wireframe clip counts
/// each of its rrweb events). A streaming capture that runs for hours stops
/// uploading replay once a session has used its budget; the counts are
/// reported on the session's lifecycle events and in
/// `traceway.collection.health`. The pictures a wireframe inlines
/// ([admitImage]) have a budget of their own inside it, [maxImageBytes] of
/// encoded image data per session, as on Android and iOS.
class CollectionBudget {
  CollectionBudget({
    this.maxBytes = 50 * 1024 * 1024,
    this.maxEvents = 10000,
    this.maxImageBytes = defaultMaxImageBytes,
    StateStore? store,
  }) : _store = store;

  static const int defaultMaxImageBytes = 4 * 1024 * 1024;

  final int maxBytes;
  final int maxEvents;
  final int maxImageBytes;
  StateStore? _store;
  String? _sessionId;
  int _bytes = 0;
  int _events = 0;
  int _dropped = 0;
  int _imageBytes = 0;
  bool _loaded = false;

  set store(StateStore store) => _store = store;

  bool admit(String? sessionId, int bytes, [int events = 1]) {
    _switchTo(sessionId);
    if (_bytes + bytes > maxBytes || _events + events > maxEvents) {
      _dropped += events;
      _save();
      return false;
    }
    _bytes += bytes;
    _events += events;
    _save();
    return true;
  }

  /// Whether [sessionId] may still record a picture.
  bool hasImageRoom(String? sessionId) {
    _switchTo(sessionId);
    return _imageBytes < maxImageBytes;
  }

  /// Counts a picture of [bytes] encoded bytes against [sessionId]'s image
  /// budget; false when it does not fit.
  bool admitImage(String? sessionId, int bytes) {
    _switchTo(sessionId);
    if (bytes < 0 || _imageBytes + bytes > maxImageBytes) return false;
    _imageBytes += bytes;
    _save();
    return true;
  }

  void _switchTo(String? sessionId) {
    if (_loaded && sessionId == _sessionId) return;
    _loaded = true;
    _sessionId = sessionId;
    _bytes = _events = _dropped = _imageBytes = 0;
    final saved = _store?.get('budget');
    if (saved is Map && saved['sessionId'] == sessionId && sessionId != null) {
      int read(String key) {
        final value = saved[key];
        return value is int && value >= 0 ? value : 0;
      }

      _bytes = read('bytes');
      _events = read('events');
      _dropped = read('dropped');
      _imageBytes = read('imageBytes');
    }
  }

  void _save() {
    if (_sessionId == null) return;
    _store?.set('budget', {
      'sessionId': _sessionId,
      'bytes': _bytes,
      'events': _events,
      'dropped': _dropped,
      'imageBytes': _imageBytes,
    });
  }

  /// Whether [sessionId] has uploaded any replay.
  bool hasUploaded(String sessionId) {
    _switchTo(sessionId);
    return _events > 0;
  }

  Map<String, int> snapshot(String? sessionId) {
    _switchTo(sessionId);
    return {
      'traceway.collection.bytes': _bytes,
      'traceway.collection.events': _events,
      'traceway.collection.dropped': _dropped,
      'traceway.collection.max_bytes': maxBytes,
      'traceway.collection.max_events': maxEvents,
      'traceway.replay.image_bytes': _imageBytes,
    };
  }
}
