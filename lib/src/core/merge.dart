import 'dart:convert';

import 'settings.dart';

class SettingsError implements Exception {
  SettingsError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _conditionOps = [
  'eq',
  'neq',
  'in',
  'not_in',
  'contains',
  'icontains',
  'starts_with',
  'glob',
  'exists',
  'not_exists',
  'gt',
  'gte',
  'lt',
  'lte',
  'version',
];

const _maxMatcherDepth = 8;
const _maxStepCount = 1000;
const _maxBufferBytes = 64 * 1024 * 1024;
const double _maxBufferAgeSeconds = 24 * 60 * 60;

typedef Json = Map<String, dynamic>;

Json? _object(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : null;

double? _rate(Object? value) =>
    value is num && value.isFinite ? value.toDouble().clamp(0, 1) : null;

double? _positive(Object? value, num max) =>
    value is num && value.isFinite && value > 0
        ? (value > max ? max.toDouble() : value.toDouble())
        : null;

/// Parses the document the server sent. Throws for anything this SDK cannot
/// apply.
Json parseSettingsDocument(Object body) {
  final text = body is String ? body : utf8.decode(body as List<int>);
  Object? parsed;
  try {
    parsed = jsonDecode(text);
  } catch (_) {
    throw SettingsError('settings document is not valid JSON');
  }
  final object = _object(parsed);
  if (object == null) {
    throw SettingsError('settings document must be a JSON object');
  }
  final version = object['schemaVersion'];
  if (version != null && version != 1) {
    throw SettingsError('unsupported settings schemaVersion $version');
  }
  return object;
}

bool _scalar(Object? value) => value is String || value is num || value is bool;

Matcher? parseMatcher(Object? value, [int depth = 0]) {
  final object = _object(value);
  if (object == null || depth > _maxMatcherDepth) return null;
  if (object['all'] is List || object['any'] is List) {
    final isAll = object['all'] is List;
    final items = <Matcher>[];
    for (final item in object[isAll ? 'all' : 'any'] as List) {
      final parsed = parseMatcher(item, depth + 1);
      if (parsed == null) return null;
      items.add(parsed);
    }
    return isAll ? AllMatcher(items) : AnyMatcher(items);
  }
  if (object.containsKey('not')) {
    final inner = parseMatcher(object['not'], depth + 1);
    return inner == null ? null : NotMatcher(inner);
  }
  final key = object['key'];
  final op = object['op'];
  if (key is! String || key.isEmpty) return null;
  if (op is! String || !_conditionOps.contains(op)) return null;
  final raw = object['value'];
  if (raw != null && !_scalar(raw)) return null;
  List<Object>? values;
  final rawValues = object['values'];
  if (rawValues != null) {
    if (rawValues is! List || !rawValues.every(_scalar)) return null;
    values = rawValues.cast<Object>();
  }
  return Condition(key, op, value: raw, values: values);
}

List<String>? _parseSignalSelector(Object? value) {
  if (value is! List) return null;
  return value
      .whereType<String>()
      .where((s) => s == '*' || signalNames.contains(s))
      .toList();
}

TriggerAction? _parseAction(Object? value) {
  final object = _object(value);
  if (object == null) return null;
  switch (object['type']) {
    case 'flush':
      final lookback =
          _positive(object['lookbackSeconds'], _maxBufferAgeSeconds);
      if (lookback == null) return null;
      return TriggerAction(
        type: 'flush',
        lookbackSeconds: lookback,
        signals: _parseSignalSelector(object['signals']),
        replay: object['replay'] == true,
      );
    case 'stream':
      final duration =
          _positive(object['durationSeconds'], _maxBufferAgeSeconds);
      if (duration == null) return null;
      return TriggerAction(
        type: 'stream',
        durationSeconds: duration,
        signals: _parseSignalSelector(object['signals']),
        replay: object['replay'] == true,
      );
    case 'startReplay':
      final duration =
          _positive(object['durationSeconds'], _maxBufferAgeSeconds);
      if (duration == null) return null;
      return TriggerAction(type: 'startReplay', durationSeconds: duration);
    case 'capture':
      final duration =
          _positive(object['durationSeconds'], _maxBufferAgeSeconds);
      if (duration == null) return null;
      return TriggerAction(
        type: 'capture',
        durationSeconds: duration,
        lookbackSeconds:
            _positive(object['lookbackSeconds'], _maxBufferAgeSeconds),
        signals: _parseSignalSelector(object['signals']),
        replay: object['replay'] == true,
      );
    case 'emit':
      final eventName = object['eventName'];
      if (eventName is! String || eventName.isEmpty) return null;
      final attributes = <String, String>{};
      final raw = _object(object['attributes']);
      if (raw != null) {
        raw.forEach((k, v) {
          if (v is String) attributes[k] = v;
        });
      }
      return TriggerAction(
          type: 'emit', eventName: eventName, attributes: attributes);
  }
  return null;
}

List<TriggerStep>? _parseSteps(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final steps = <TriggerStep>[];
  for (final raw in value) {
    final object = _object(raw);
    if (object == null) return null;
    final match = parseMatcher(object['match']);
    if (match == null) return null;
    final within = object['withinSeconds'];
    int? count;
    double? period;
    final rawCount = object['count'];
    if (rawCount is num && rawCount == rawCount.roundToDouble() && rawCount > 1) {
      count = rawCount > _maxStepCount ? _maxStepCount : rawCount.toInt();
      final rawPeriod = object['periodSeconds'];
      period = rawPeriod is num && rawPeriod > 0
          ? (rawPeriod > _maxBufferAgeSeconds
              ? _maxBufferAgeSeconds
              : rawPeriod.toDouble())
          : null;
    }
    steps.add(TriggerStep(
      match: match,
      withinSeconds: within is num && within > 0 ? within.toDouble() : null,
      count: count,
      periodSeconds: period,
    ));
  }
  return steps;
}

List<TriggerAction>? _parseActions(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final actions = <TriggerAction>[];
  for (final raw in value) {
    final action = _parseAction(raw);
    if (action == null) return null;
    actions.add(action);
  }
  return actions;
}

Trigger? _mergeTrigger(Trigger? base, Json raw) {
  final steps =
      raw.containsKey('steps') ? _parseSteps(raw['steps']) : base?.steps;
  final actions =
      raw.containsKey('actions') ? _parseActions(raw['actions']) : base?.actions;
  if (steps == null || actions == null) return null;
  final cooldown = raw['cooldownSeconds'];
  final maxPerSession = raw['maxPerSession'];
  return (base ?? Trigger(id: raw['id'] as String, steps: steps, actions: actions))
      .copyWith(
    steps: steps,
    actions: actions,
    name: raw['name'] is String ? raw['name'] as String : null,
    enabled: raw['enabled'] is bool ? raw['enabled'] as bool : null,
    sampleRate: _rate(raw['sampleRate']),
    cooldownSeconds:
        cooldown is num && cooldown >= 0 ? cooldown.toDouble() : null,
    maxPerSession:
        maxPerSession is num && maxPerSession >= 0 ? maxPerSession.toInt() : null,
  );
}

Capture? _parseCapture(Object? value) {
  final object = _object(value);
  if (object == null) return null;
  final id = object['id'];
  final until = object['until'];
  if (id is! String || until is! String) return null;
  final parsed = DateTime.tryParse(until);
  if (parsed == null) return null;
  final rawLookback = object['lookbackSeconds'];
  return Capture(
    id: id,
    until: parsed,
    replay: object['replay'] == true,
    lookbackSeconds: rawLookback == 0
        ? 0
        : _positive(rawLookback, _maxBufferAgeSeconds),
    signals: _parseSignalSelector(object['signals']),
  );
}

/// Lays a remote overlay over [base]. Fields this SDK does not know are
/// ignored so a newer server can add settings; malformed values of known
/// fields are skipped individually instead of rejecting the whole document.
Settings applyOverlay(Settings base, Json overlay) {
  final out = base.copy();
  if (overlay['enabled'] is bool) out.enabled = overlay['enabled'] as bool;

  final signals = _object(overlay['signals']);
  if (signals != null) {
    for (final signal in signalNames) {
      final raw = _object(signals[signal]);
      if (raw == null) continue;
      final target = out.signals[signal]!;
      final mode = modeFromString(raw['mode']);
      if (mode != null) target.mode = mode;
      final sampleRate = _rate(raw['sampleRate']);
      if (sampleRate != null) target.sampleRate = sampleRate;
      final minSeverity = raw['minSeverity'];
      if (minSeverity is String && severities.contains(minSeverity)) {
        target.minSeverity = minSeverity;
      }
    }
  }

  final sessions = _object(overlay['sessions']);
  if (sessions != null) {
    if (sessions['enabled'] is bool) {
      out.sessionsEnabled = sessions['enabled'] as bool;
    }
    final baseline = _rate(sessions['baselineSampleRate']);
    if (baseline != null) out.baselineSampleRate = baseline;
  }

  final replay = _object(overlay['replay']);
  if (replay != null) {
    final mode = modeFromString(replay['mode']);
    if (mode != null) out.replayMode = mode;
    final sampleRate = _rate(replay['sessionSampleRate']);
    if (sampleRate != null) out.replaySessionSampleRate = sampleRate;
  }

  final buffer = _object(overlay['buffer']);
  if (buffer != null) {
    final maxBytes = _positive(buffer['maxBytes'], _maxBufferBytes);
    if (maxBytes != null) out.bufferMaxBytes = maxBytes.toInt();
    final maxAge = _positive(buffer['maxAgeSeconds'], _maxBufferAgeSeconds);
    if (maxAge != null) out.bufferMaxAgeSeconds = maxAge;
    final replayMax = _positive(buffer['replayMaxBytes'], _maxBufferBytes);
    if (replayMax != null) out.replayMaxBytes = replayMax.toInt();
    if (buffer['persist'] is bool) out.persist = buffer['persist'] as bool;
  }

  final triggers = overlay['triggers'];
  if (triggers is List) {
    for (final item in triggers) {
      final raw = _object(item);
      if (raw == null) continue;
      final id = raw['id'];
      if (id is! String || id.isEmpty) continue;
      final index = out.triggers.indexWhere((t) => t.id == id);
      final merged = _mergeTrigger(index >= 0 ? out.triggers[index] : null, raw);
      if (merged == null) continue;
      if (index >= 0) {
        out.triggers[index] = merged;
      } else {
        out.triggers.add(merged);
      }
    }
  }

  final captures = overlay['captures'];
  if (captures is List) {
    out.captures = captures.map(_parseCapture).whereType<Capture>().toList();
  }

  return out;
}

/// Lowers the app's ceilings to the `limits` a remote document carries: what
/// the organization's plan accepts at ingest.
Ceilings applyLimits(Ceilings ceilings, Json? overlay) {
  final limits = overlay == null ? null : _object(overlay['limits']);
  if (limits == null) return ceilings;
  final signals = Map<String, Mode>.of(ceilings.signals);
  final limitSignals = _object(limits['signals']);
  if (limitSignals != null) {
    for (final signal in signalNames) {
      final mode = modeFromString(limitSignals[signal]);
      if (mode != null) signals[signal] = lowerMode(signals[signal]!, mode);
    }
  }
  final replay = modeFromString(limits['replay']);
  return Ceilings(
    enabled: ceilings.enabled,
    signals: signals,
    replay: replay == null ? ceilings.replay : lowerMode(ceilings.replay, replay),
    sessions: ceilings.sessions,
  );
}

/// Holds every mode at or below what init allowed in this app.
Settings clampToCeilings(Settings settings, Ceilings ceilings) {
  final out = settings.copy();
  out.enabled = out.enabled && ceilings.enabled;
  for (final signal in signalNames) {
    final target = out.signals[signal]!;
    target.mode = lowerMode(target.mode, ceilings.signals[signal]!);
  }
  out.replayMode = lowerMode(out.replayMode, ceilings.replay);
  out.sessionsEnabled = out.sessionsEnabled && ceilings.sessions;
  return out;
}
