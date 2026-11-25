import 'dart:math';

import 'matcher.dart';
import 'settings.dart';

class ObservedEvent {
  ObservedEvent({required this.timeMs, required this.lookup, this.sequence});
  final int timeMs;
  final FieldLookup lookup;

  /// Set for the tap and hover events the app feeds in directly (`click` or
  /// `hover`). They answer almost no field, so only a step that names this
  /// event type may match them: a negated condition would otherwise match
  /// every tap.
  final String? sequence;
}

class FiredTrigger {
  FiredTrigger(this.trigger, this.cause);
  final Trigger trigger;

  /// The event that completed the trigger, e.g. the exception a clip belongs
  /// to.
  final ObservedEvent cause;
}

/// A completed prefix waiting for its next step: when it completed, and the
/// hit it started counting from.
class _Anchor {
  _Anchor(this.at, this.from);
  final int at;
  int from;
}

class _StepState {
  /// Unused on the first step, which is always open. Oldest first.
  List<_Anchor> anchors = [];

  /// Times of the records counted towards this step, when it needs more than
  /// one.
  List<int> hits = [];

  /// Hits dropped from the front of [hits], so an anchor's `from` stays
  /// valid.
  int base = 0;
}

class _TriggerState {
  _TriggerState(this.signature, this.steps, this.kinds,
      {this.fires = 0, this.lastFireMs = 0});
  final String signature;
  List<_StepState> steps;

  /// Per step, the event types (`click`, `hover`, ...) its matcher names.
  final List<Set<String>> kinds;
  int fires;
  int lastFireMs;
}

const _maxAnchors = 8;
const _maxHits = 1000;
const _maxRestoreAgeMs = 86400000;

/// Runs the server-defined triggers against every event on the device. A
/// trigger is a sequence of steps. Every way the sequence could be under way
/// is followed at once: each step remembers when the steps before it last
/// completed, so an event that could also start the sequence over does not
/// discard the progress already made. A step that arrives later than its
/// `withinSeconds` is dropped, and the last step fires the trigger's actions.
/// Progress and fire counts are per session.
///
/// The same algorithm as the browser SDK, so a rule behaves the same on both.
class TriggerEngine {
  TriggerEngine({double Function()? random})
      : _random = random ?? Random().nextDouble;

  final double Function() _random;
  List<Trigger> _triggers = [];
  Map<String, _TriggerState> _states = {};

  /// Fires and the last fire time per trigger id in the current session.
  Map<String, ({int fires, int lastFireMs})> sessionLimits = {};

  /// Changes whenever progress does, so the caller can skip saving it.
  int progressVersion = 0;

  /// Why a trigger that completed did not fire on the last [observe] call.
  final Map<String, String> skipped = {};

  List<Trigger> get triggers => _triggers;

  /// Returns the ids of the triggers that start without progress: new ones,
  /// and ones whose steps or actions changed.
  Set<String> setTriggers(List<Trigger> triggers) {
    _triggers = triggers
        .where((t) =>
            t.enabled != false && t.steps.isNotEmpty && t.actions.isNotEmpty)
        .toList();
    final next = <String, _TriggerState>{};
    final created = <String>{};
    for (final trigger in _triggers) {
      final signature = trigger.signature;
      final prev = _states[trigger.id];
      final limits = sessionLimits[trigger.id];
      final kept = prev != null && prev.signature == signature;
      if (!kept) created.add(trigger.id);
      next[trigger.id] = kept
          ? prev
          : _TriggerState(
              signature,
              [for (final _ in trigger.steps) _StepState()],
              [for (final step in trigger.steps) eventKinds(step.match)],
              fires: prev?.fires ?? limits?.fires ?? 0,
              lastFireMs: prev?.lastFireMs ?? limits?.lastFireMs ?? 0,
            );
    }
    _states = next;
    progressVersion++;
    return created;
  }

  /// The progress of every trigger under way, as JSON, to continue it after
  /// an app restart within the same session.
  List<Object> snapshotProgress() => [
        for (final entry in _states.entries)
          if (entry.value.steps
              .any((s) => s.anchors.isNotEmpty || s.hits.isNotEmpty))
            {
              'id': entry.key,
              'v': 2,
              'signature': entry.value.signature,
              'steps': [
                for (final step in entry.value.steps)
                  {
                    'anchors': [
                      for (final a in step.anchors)
                        [a.at, max(0, a.from - step.base)]
                    ],
                    'hits': List.of(step.hits),
                  }
              ],
            }
      ];

  /// [only] limits the restore to those trigger ids.
  void restoreProgress(Object? saved, [int? nowMs, Set<String>? only]) {
    if (saved is! List) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final item in saved.take(20)) {
      if (item is! Map || item['v'] != 2) continue;
      if (only != null && !only.contains(item['id'])) continue;
      final state = _states[item['id']];
      Trigger? trigger;
      for (final t in _triggers) {
        if (t.id == item['id']) trigger = t;
      }
      final steps = item['steps'];
      if (state == null ||
          trigger == null ||
          state.signature != item['signature'] ||
          steps is! List ||
          steps.length != trigger.steps.length) {
        continue;
      }
      state.steps = [
        for (var k = 0; k < trigger.steps.length; k++)
          _restoreStep(trigger.steps[k], k, steps[k], now),
      ];
      progressVersion++;
    }
  }

  _StepState _restoreStep(TriggerStep step, int k, Object? from, int now) {
    final restored = _StepState();
    if (from is! Map) return restored;
    final rawHits = from['hits'];
    final needed = step.count ?? 1;
    if (needed > 1) {
      final period = step.periodSeconds;
      final oldest = period != null
          ? now - (period * 1000).round()
          : now - _maxRestoreAgeMs;
      final hits = rawHits is List
          ? rawHits
              .whereType<num>()
              .where((v) => v.isFinite && v <= now && v >= oldest)
              .map((v) => v.toInt())
              .toList()
          : <int>[];
      restored.hits =
          hits.length > _maxHits ? hits.sublist(hits.length - _maxHits) : hits;
    }
    final rawAnchors = from['anchors'];
    if (k == 0 || rawAnchors is! List) {
      if (k > 0) restored.hits = [];
      return restored;
    }
    final within = step.withinSeconds;
    final maxAge =
        within != null ? (within * 1000).round() : _maxRestoreAgeMs;
    final dropped = rawHits is List && needed > 1
        ? rawHits.length - restored.hits.length
        : 0;
    for (final anchor in rawAnchors.take(_maxAnchors)) {
      if (anchor is! List || anchor.length < 2) continue;
      final at = anchor[0];
      final start = anchor[1];
      if (at is! num ||
          !at.isFinite ||
          at > now ||
          now - at > maxAge ||
          start is! int ||
          start < 0) {
        continue;
      }
      restored.anchors.add(_Anchor(
          at.toInt(), min(restored.hits.length, max(0, start - dropped))));
    }
    if (restored.anchors.isEmpty) restored.hits = [];
    return restored;
  }

  void resetSession() {
    sessionLimits = {};
    for (final state in _states.values) {
      state.steps = [for (final _ in state.steps) _StepState()];
      state.fires = 0;
      state.lastFireMs = 0;
    }
    progressVersion++;
  }

  Map<String, Object> snapshotSessionLimits() => {
        for (final e in sessionLimits.entries)
          e.key: {'fires': e.value.fires, 'lastFireMs': e.value.lastFireMs},
      };

  void restoreSessionLimits(Object? saved) {
    if (saved is! Map) return;
    saved.forEach((id, value) {
      if (id is! String || value is! Map) return;
      final fires = value['fires'];
      final last = value['lastFireMs'];
      if (fires is! int || fires < 0 || last is! int) return;
      sessionLimits[id] = (fires: fires, lastFireMs: last);
      final state = _states[id];
      if (state != null) {
        state.fires = fires;
        state.lastFireMs = last;
      }
    });
  }

  List<FiredTrigger> observe(ObservedEvent event) {
    skipped.clear();
    final fired = <FiredTrigger>[];
    for (final trigger in _triggers) {
      final state = _states[trigger.id];
      if (state == null) continue;
      if (!_advance(trigger, state, event)) continue;
      if (!_mayFire(trigger, state, event.timeMs)) continue;
      state.fires++;
      state.lastFireMs = event.timeMs;
      sessionLimits[trigger.id] =
          (fires: state.fires, lastFireMs: state.lastFireMs);
      fired.add(FiredTrigger(trigger, event));
    }
    return fired;
  }

  /// Feeds one record to a trigger; true when it completed the last step.
  /// Later steps are tried first, so the progress a record makes on one step
  /// is not also counted towards the next one.
  bool _advance(Trigger trigger, _TriggerState state, ObservedEvent event) {
    final last = trigger.steps.length - 1;
    final now = event.timeMs;
    var completed = false;
    for (var k = last; k >= 1 && !completed; k--) {
      final step = trigger.steps[k];
      final at = state.steps[k];
      if (at.anchors.isEmpty) continue;
      final within = step.withinSeconds;
      if (within != null && within > 0) {
        final oldest = now - (within * 1000).round();
        if (at.anchors.first.at < oldest) {
          at.anchors = at.anchors.where((a) => a.at >= oldest).toList();
          if (at.anchors.isEmpty) at.hits = [];
          progressVersion++;
          if (at.anchors.isEmpty) continue;
        }
      }
      if (!_stepMatches(step, state.kinds[k], event)) continue;
      progressVersion++;
      final needed = step.count ?? 1;
      if (needed > 1) {
        _countHit(at, step, now);
        final counted = at.base +
            at.hits.length -
            max(at.anchors.first.from, at.base);
        if (counted < needed) continue;
        at.anchors.removeAt(0);
        if (at.anchors.isEmpty) at.hits = [];
      } else {
        at.anchors = [];
      }
      if (k == last) {
        completed = true;
      } else {
        _open(state.steps[k + 1], trigger.steps[k + 1], now);
      }
    }
    if (!completed) {
      final step = trigger.steps[0];
      if (!_stepMatches(step, state.kinds[0], event)) return false;
      final first = state.steps[0];
      final needed = step.count ?? 1;
      if (needed > 1) {
        progressVersion++;
        _countHit(first, step, now);
        if (first.hits.length < needed) return false;
        first.hits = [];
        first.base = 0;
      }
      if (last == 0) {
        completed = true;
      } else {
        progressVersion++;
        _open(state.steps[1], trigger.steps[1], now);
      }
    }
    if (!completed) return false;
    if (last > 0) {
      state.steps = [for (final _ in state.steps) _StepState()];
      progressVersion++;
    }
    return true;
  }

  bool _mayFire(Trigger trigger, _TriggerState state, int nowMs) {
    final maxPerSession = trigger.maxPerSession;
    if (maxPerSession != null && state.fires >= maxPerSession) {
      skipped[trigger.id] = 'session_clip_limit';
      return false;
    }
    final cooldown = trigger.cooldownSeconds;
    if (cooldown != null &&
        cooldown > 0 &&
        state.fires > 0 &&
        nowMs - state.lastFireMs < cooldown * 1000) {
      skipped[trigger.id] = 'cooldown';
      return false;
    }
    final sampleRate = trigger.sampleRate ?? 1;
    final accepted = sampleRate >= 1 || _random() < sampleRate;
    if (!accepted) skipped[trigger.id] = 'sampled_out';
    return accepted;
  }
}

void _countHit(_StepState at, TriggerStep step, int now) {
  at.hits.add(now);
  var drop = max(0, at.hits.length - _maxHits);
  final period = step.periodSeconds;
  if (period != null && period > 0) {
    final cutoff = now - (period * 1000).round();
    while (drop < at.hits.length && at.hits[drop] < cutoff) {
      drop++;
    }
  }
  if (drop > 0) {
    at.hits.removeRange(0, drop);
    at.base += drop;
  }
}

/// Records that the steps before this one just completed.
void _open(_StepState at, TriggerStep step, int now) {
  if ((step.count ?? 1) <= 1) {
    at.anchors = [_Anchor(now, 0)];
    return;
  }
  final anchor = _Anchor(now, at.base + at.hits.length);
  if (at.anchors.length >= _maxAnchors) {
    at.anchors[_maxAnchors - 1] = anchor;
  } else {
    at.anchors.add(anchor);
  }
}

bool _stepMatches(TriggerStep step, Set<String> kinds, ObservedEvent event) {
  final sequence = event.sequence;
  if (sequence != null && !kinds.contains(sequence)) return false;
  return matches(step.match, event.lookup);
}

/// The event types (`click`, `hover`, `navigation`, `log`) a matcher names.
Set<String> eventKinds(Matcher matcher, [Set<String>? into]) {
  final out = into ?? <String>{};
  switch (matcher) {
    case EventMatcher e:
      out.add(e.type);
    case AllMatcher m:
      for (final item in m.items) {
        eventKinds(item, out);
      }
    case AnyMatcher m:
      for (final item in m.items) {
        eventKinds(item, out);
      }
    case NotMatcher m:
      eventKinds(m.inner, out);
    case Condition _:
      break;
  }
  return out;
}

/// Whether any of [triggers] has a step that names one of [types].
bool hasSequenceEvent(List<Trigger> triggers, Set<String> types) {
  for (final trigger in triggers) {
    if (trigger.enabled == false) continue;
    for (final step in trigger.steps) {
      if (eventKinds(step.match).any(types.contains)) return true;
    }
  }
  return false;
}
