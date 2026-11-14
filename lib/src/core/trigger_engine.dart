import 'dart:math';

import 'matcher.dart';
import 'settings.dart';

class ObservedEvent {
  ObservedEvent({required this.timeMs, required this.lookup});
  final int timeMs;
  final FieldLookup lookup;
}

class FiredTrigger {
  FiredTrigger(this.trigger, this.cause);
  final Trigger trigger;

  /// The event that completed the trigger, e.g. the exception a clip belongs
  /// to.
  final ObservedEvent cause;
}

class _TriggerState {
  _TriggerState(this.signature, {this.fires = 0, this.lastFireMs = 0});
  final String signature;
  int step = 0;
  int lastStepMs = 0;

  /// Times of the records counted towards the current step.
  List<int> hits = [];
  int fires;
  int lastFireMs;

  void restart() {
    step = 0;
    hits = [];
  }
}

/// Runs the server-defined triggers against every event on the device. A
/// trigger is a sequence of steps; each matching event advances it, a step
/// that arrives later than its `withinSeconds` starts it over, and the last
/// step fires the trigger's actions. Progress and fire counts are per session.
class TriggerEngine {
  TriggerEngine({double Function()? random})
      : _random = random ?? Random().nextDouble;

  final double Function() _random;
  List<Trigger> _triggers = [];
  Map<String, _TriggerState> _states = {};

  /// Why a trigger that completed did not fire on the last [observe] call.
  final Map<String, String> skipped = {};

  void setTriggers(List<Trigger> triggers) {
    _triggers = triggers
        .where((t) =>
            t.enabled != false && t.steps.isNotEmpty && t.actions.isNotEmpty)
        .toList();
    final next = <String, _TriggerState>{};
    for (final trigger in _triggers) {
      final signature = trigger.stepsSignature;
      final prev = _states[trigger.id];
      next[trigger.id] = prev != null && prev.signature == signature
          ? prev
          : _TriggerState(signature,
              fires: prev?.fires ?? 0, lastFireMs: prev?.lastFireMs ?? 0);
    }
    _states = next;
  }

  void resetSession() {
    for (final state in _states.values) {
      state.restart();
      state.lastStepMs = 0;
      state.fires = 0;
      state.lastFireMs = 0;
    }
  }

  List<FiredTrigger> observe(ObservedEvent event) {
    skipped.clear();
    final fired = <FiredTrigger>[];
    for (final trigger in _triggers) {
      final state = _states[trigger.id];
      if (state == null) continue;
      if (state.step > 0) {
        final within = trigger.steps[state.step].withinSeconds;
        if (within != null &&
            within > 0 &&
            event.timeMs - state.lastStepMs > within * 1000) {
          state.restart();
        }
      }
      if (!_advance(trigger, state, event)) continue;
      if (!_mayFire(trigger, state, event.timeMs)) continue;
      state.fires++;
      state.lastFireMs = event.timeMs;
      fired.add(FiredTrigger(trigger, event));
    }
    return fired;
  }

  /// Feeds one record to a trigger; true when it completed the last step.
  bool _advance(Trigger trigger, _TriggerState state, ObservedEvent event) {
    if (!matches(trigger.steps[state.step].match, event.lookup)) {
      if (state.step == 0 || !matches(trigger.steps[0].match, event.lookup)) {
        return false;
      }
      state.restart();
    }
    final step = trigger.steps[state.step];
    final needed = step.count ?? 1;
    if (needed > 1) {
      state.hits.add(event.timeMs);
      final period = step.periodSeconds;
      if (period != null && period > 0) {
        final cutoff = event.timeMs - period * 1000;
        state.hits = state.hits.where((t) => t >= cutoff).toList();
      }
      if (state.hits.length < needed) return false;
    }
    state.hits = [];
    state.step++;
    state.lastStepMs = event.timeMs;
    if (state.step < trigger.steps.length) return false;
    state.step = 0;
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
