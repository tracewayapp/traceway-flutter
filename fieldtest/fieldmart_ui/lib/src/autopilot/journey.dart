import 'dart:convert';

/// `shared/journey.json` (02-APP-SPEC.md §5): every scenario as timed steps.
class Journey {
  Journey(this.version, this.width, this.height, this.scenarios, this.raw);

  factory Journey.parse(String source) {
    final j = jsonDecode(source) as Map<String, Object?>;
    final viewport = (j['viewport'] as Map<String, Object?>?) ?? const {};
    final scenarios = <String, Scenario>{};
    final s = (j['scenarios'] as Map<String, Object?>?) ?? const {};
    for (final e in s.entries) {
      if (e.value is Map<String, Object?>) {
        scenarios[e.key] = Scenario.fromJson(e.key, e.value as Map<String, Object?>);
      }
    }
    return Journey(
      (j['version'] as num?)?.toInt() ?? 0,
      (viewport['width'] as num?)?.toDouble() ?? 412,
      (viewport['height'] as num?)?.toDouble() ?? 892,
      scenarios,
      j,
    );
  }

  final int version;
  final double width;
  final double height;
  final Map<String, Scenario> scenarios;
  final Map<String, Object?> raw;

  /// The scenario named [id] exactly, or the one whose key starts `<id>-`
  /// (`S6` finds `S6-shopper`).
  Scenario? find(String id) {
    final exact = scenarios[id];
    if (exact != null) return exact;
    for (final e in scenarios.entries) {
      if (e.key.startsWith('$id-')) return e.value;
    }
    return null;
  }
}

class Scenario {
  Scenario(this.id, this.launch, this.start, this.durationMs, this.steps);

  factory Scenario.fromJson(String id, Map<String, Object?> j) => Scenario(
        id,
        (j['launch'] as String?) ?? 'cold',
        (j['start'] as String?) ?? 'home',
        (j['durationMs'] as num?)?.toInt() ?? 0,
        [
          for (final (i, s) in ((j['steps'] as List?) ?? const []).indexed)
            if (s is Map<String, Object?>) Step(i, s),
        ],
      );

  final String id;
  final String launch;
  final String start;
  final int durationMs;
  final List<Step> steps;
}

class Step {
  Step(this.index, this.raw);

  final int index;
  final Map<String, Object?> raw;

  int get t => (raw['t'] as num?)?.toInt() ?? 0;
  String get action => (raw['do'] as String?) ?? '';
  String? get id => raw['id'] as String?;
  String? get name => raw['name'] as String?;
  String? get text => raw['text'] as String?;
  String? get dir => raw['dir'] as String?;
  String? get mode => raw['mode'] as String?;
  Object? get value => raw['value'];

  /// Bring the element fully into view first, by dragging its container.
  bool get reveal => raw['reveal'] == true;

  /// A drag that leaves the finger down until the next `release`.
  bool get hold => raw['hold'] == true;

  /// The field a `type` or `paste` goes into.
  String? get into => raw['into'] as String?;

  /// The platforms the step runs on; null for all.
  List<String>? get platforms => raw['platforms'] is List ? [for (final p in raw['platforms'] as List) '$p'] : null;

  int get timeoutMs => _int('timeoutMs', 15000);
  int get ms => _int('ms', 600);
  int get durationMs => _int('durationMs', 250);
  int get perCharMs => _int('perCharMs', 120);
  int get settleMs => _int('settleMs', 400);
  int get seconds => _int('seconds', 0);
  double get distance => (raw['distance'] as num?)?.toDouble() ?? 0.6;

  /// A point as fractions of the element, `[x, y]` or `{x, y}`.
  (double, double)? point(String key) {
    final v = raw[key];
    if (v is List && v.length >= 2) return ((v[0] as num).toDouble(), (v[1] as num).toDouble());
    if (v is Map) return ((v['x'] as num).toDouble(), (v['y'] as num).toDouble());
    return null;
  }

  List<String> strings(String key) =>
      raw[key] is List ? [for (final e in raw[key] as List) '$e'] : const [];

  int _int(String key, int fallback) => (raw[key] as num?)?.toInt() ?? fallback;

  /// Whether the step moves a finger or types: no two may overlap.
  bool get isInput => const {'tap', 'longPress', 'fling', 'drag', 'type', 'paste', 'key', 'pick'}.contains(action);

  @override
  String toString() => jsonEncode(raw);
}
