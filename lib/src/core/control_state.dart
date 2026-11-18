import 'merge.dart';
import 'settings.dart';

class StreamOverride {
  StreamOverride({
    required this.signals,
    required this.untilMs,
    this.replay = false,
    this.includeOff = false,
  });

  /// `"*"` covers every signal that is not off; listing a signal also turns
  /// it on. Either way the result stays within the ceilings and plan limits.
  final List<String> signals;
  final int untilMs;

  /// Streams the screen recording too, as segments, while it lasts.
  final bool replay;

  /// A capture: `"*"` also brings back the signals rules switched off.
  final bool includeOff;
}

/// The effective collection settings at any moment: built-in defaults (with
/// the app's local collection settings), then the remote overlay, clamped to
/// the app's ceilings, then any temporary "stream for a while" overrides from
/// triggers and captures.
class ControlState {
  ControlState(this._defaults, this._appCeilings, {int Function()? now})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _ceilings = _appCeilings,
        _effective = clampToCeilings(_defaults, _appCeilings);

  final Settings _defaults;
  final Ceilings _appCeilings;
  final int Function() _now;
  Ceilings _ceilings;
  Settings _effective;
  Json? _remote;
  final Map<String, List<StreamOverride>> _overrides = {};
  int _overrideSequence = 0;
  final List<void Function(Settings)> _listeners = [];

  Settings get settings => _effective;
  Json? get remoteOverlay => _remote;

  /// Applies a parsed remote document, or `null` to fall back to defaults.
  void applyRemote(Json? overlay) {
    _remote = overlay;
    _ceilings = applyLimits(_appCeilings, overlay);
    final merged = overlay == null ? _defaults : applyOverlay(_defaults, overlay);
    _effective = clampToCeilings(merged, _ceilings);
    for (final listener in List.of(_listeners)) {
      try {
        listener(_effective);
      } catch (_) {
        // A listener must not stop the others from seeing the change.
      }
    }
  }

  void onChange(void Function(Settings) listener) => _listeners.add(listener);

  void addOverride(StreamOverride override) =>
      setOverrides('stream:${_overrideSequence++}', [override]);

  void setOverrides(String owner, List<StreamOverride> overrides) {
    if (overrides.isEmpty) {
      _overrides.remove(owner);
    } else {
      _overrides[owner] = overrides;
    }
    _activeOverrides();
  }

  /// When the next override ends, so the caller can re-apply replay then.
  int? get nextOverrideExpiryMs {
    final active = _activeOverrides();
    if (active.isEmpty) return null;
    return active.map((o) => o.untilMs).reduce((a, b) => a < b ? a : b);
  }

  List<StreamOverride> _activeOverrides() {
    final now = _now();
    _overrides.removeWhere((_, list) {
      list.removeWhere((o) => o.untilMs <= now);
      return list.isEmpty;
    });
    return [for (final list in _overrides.values) ...list];
  }

  bool canExport(String signal) =>
      enabled &&
      _ceilings.signals[signal] == Mode.stream &&
      modeFor(signal) != Mode.off;

  bool get enabled => _effective.enabled;

  Mode modeFor(String signal) {
    if (!_effective.enabled) return Mode.off;
    final base = _effective.signals[signal]!.mode;
    if (base == Mode.stream) return base;
    for (final override in _activeOverrides()) {
      if (_covers(override, signal, base)) {
        return lowerMode(Mode.stream, _ceilings.signals[signal]!);
      }
    }
    return base;
  }

  bool _covers(StreamOverride override, String signal, Mode base) {
    if (override.signals.contains(signal)) return true;
    if (!override.signals.contains('*')) return false;
    return base != Mode.off ||
        (override.includeOff && _defaults.signals[signal]!.mode != Mode.off);
  }

  Mode get replayMode {
    if (!_effective.enabled) return Mode.off;
    final base = _effective.replayMode;
    if (base != Mode.stream && _activeOverrides().any((o) => o.replay)) {
      return lowerMode(Mode.stream, _ceilings.replay);
    }
    return base;
  }

  double sampleRate(String signal) => _effective.signals[signal]!.sampleRate;

  /// The aggregates setting, or null when metrics are off: the kill switch,
  /// the app's `captureMetrics`, the plan's limit or a rule.
  MetricsSettings? get metrics {
    final metrics = _effective.metrics;
    return _effective.enabled && metrics.enabled ? metrics : null;
  }
}
