/// The collection settings document. The server sends a partial overlay of it
/// over OpAMP (`config_map["traceway"]`); the SDK merges that onto its
/// built-in defaults and clamps the result to the ceilings set at init.
library;

import 'dart:convert';

/// `off` drops a signal, `buffer` keeps it on the device until a trigger or
/// capture flushes it, `stream` sends it.
enum Mode { off, buffer, stream }

Mode? modeFromString(Object? value) {
  switch (value) {
    case 'off':
      return Mode.off;
    case 'buffer':
      return Mode.buffer;
    case 'stream':
      return Mode.stream;
  }
  return null;
}

Mode lowerMode(Mode a, Mode b) => a.index <= b.index ? a : b;

/// Signal names are shared with the browser SDK so one settings schema serves
/// both. `webVitals`, `resourceTiming`, `longTasks` and `routeTiming` have no
/// Flutter source; they are known only so documents naming them apply.
const List<String> signalNames = [
  'errors',
  'messages',
  'network',
  'console',
  'navigation',
  'userActions',
  'webVitals',
  'resourceTiming',
  'longTasks',
  'routeTiming',
  'custom',
];

const List<String> severities = [
  'trace',
  'debug',
  'info',
  'warn',
  'error',
  'fatal',
];

class SignalSettings {
  SignalSettings({required this.mode, this.sampleRate = 1, this.minSeverity});

  Mode mode;
  double sampleRate;

  /// Console only: records below it are dropped.
  String? minSeverity;

  SignalSettings copy() => SignalSettings(
      mode: mode, sampleRate: sampleRate, minSeverity: minSeverity);
}

sealed class Matcher {
  const Matcher();
  Object toJson();
}

class Condition extends Matcher {
  const Condition(this.key, this.op, {this.value, this.values});

  final String key;
  final String op;
  final Object? value;
  final List<Object>? values;

  @override
  Object toJson() => {
        'key': key,
        'op': op,
        if (value != null) 'value': value,
        if (values != null) 'values': values,
      };
}

/// A step of a recorded journey: a tap (`click`), a mouse entering a widget
/// (`hover`), a route the app arrived at (`navigation`) or a log line (`log`).
/// Click and hover values are selectors over the widget tree, see
/// `WidgetSelector`; navigation values are paths with optional `{param}`
/// segments.
class EventMatcher extends Matcher {
  const EventMatcher(this.type, this.value, {this.mode});

  /// `click`, `hover`, `navigation` or `log`.
  final String type;
  final String value;

  /// `exact` (default) or `contains`, for `log`.
  final String? mode;

  @override
  Object toJson() => {
        'event': {
          'type': type,
          'value': value,
          if (mode != null) 'mode': mode,
        },
      };
}

class AllMatcher extends Matcher {
  const AllMatcher(this.items);
  final List<Matcher> items;
  @override
  Object toJson() => {'all': items.map((m) => m.toJson()).toList()};
}

class AnyMatcher extends Matcher {
  const AnyMatcher(this.items);
  final List<Matcher> items;
  @override
  Object toJson() => {'any': items.map((m) => m.toJson()).toList()};
}

class NotMatcher extends Matcher {
  const NotMatcher(this.inner);
  final Matcher inner;
  @override
  Object toJson() => {'not': inner.toJson()};
}

/// One action of a trigger. [type] is `flush`, `stream`, `startReplay`,
/// `emit` or `capture`; the other fields apply as the type needs them.
class TriggerAction {
  const TriggerAction({
    required this.type,
    this.lookbackSeconds,
    this.durationSeconds,
    this.signals,
    this.replay = false,
    this.eventName,
    this.attributes,
  });

  final String type;
  final double? lookbackSeconds;
  final double? durationSeconds;

  /// `null` means every signal; an empty list means none.
  final List<String>? signals;
  final bool replay;
  final String? eventName;
  final Map<String, String>? attributes;

  Object toJson() => {
        'type': type,
        if (lookbackSeconds != null) 'lookbackSeconds': lookbackSeconds,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        if (signals != null) 'signals': signals,
        if (replay) 'replay': true,
        if (eventName != null) 'eventName': eventName,
        if (attributes != null && attributes!.isNotEmpty)
          'attributes': attributes,
      };
}

class TriggerStep {
  const TriggerStep({
    required this.match,
    this.withinSeconds,
    this.count,
    this.periodSeconds,
  });

  final Matcher match;

  /// Longest gap allowed since the previous step; null means no limit.
  final double? withinSeconds;

  /// Matching records needed before the step completes. Default 1.
  final int? count;

  /// With [count]: all of them within this many seconds of each other.
  final double? periodSeconds;

  Object toJson() => {
        'match': match.toJson(),
        'withinSeconds': withinSeconds,
        if (count != null) 'count': count,
        if (count != null) 'periodSeconds': periodSeconds,
      };
}

class Trigger {
  const Trigger({
    required this.id,
    this.name,
    this.enabled,
    this.sampleRate,
    this.cooldownSeconds,
    this.maxPerSession,
    required this.steps,
    required this.actions,
  });

  final String id;
  final String? name;
  final bool? enabled;
  final double? sampleRate;
  final double? cooldownSeconds;
  final int? maxPerSession;
  final List<TriggerStep> steps;
  final List<TriggerAction> actions;

  /// Changes whenever the steps or actions do, so progress made under an
  /// older version of a trigger is not carried over.
  String get signature => jsonEncode([
        steps.map((s) => s.toJson()).toList(),
        actions.map((a) => a.toJson()).toList(),
      ]);

  List<Object> stepsJson() => steps.map((s) => s.toJson()).toList();

  Trigger copyWith({
    String? name,
    bool? enabled,
    double? sampleRate,
    double? cooldownSeconds,
    int? maxPerSession,
    List<TriggerStep>? steps,
    List<TriggerAction>? actions,
  }) =>
      Trigger(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        sampleRate: sampleRate ?? this.sampleRate,
        cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
        maxPerSession: maxPerSession ?? this.maxPerSession,
        steps: steps ?? this.steps,
        actions: actions ?? this.actions,
      );
}

/// An on-demand capture requested from the dashboard; only the server creates
/// these.
class Capture {
  const Capture({
    required this.id,
    required this.until,
    this.lookbackSeconds,
    this.signals,
    this.replay = false,
  });

  final String id;
  final DateTime until;
  final double? lookbackSeconds;
  final List<String>? signals;
  final bool replay;
}

class Settings {
  Settings({
    required this.enabled,
    required this.signals,
    required this.sessionsEnabled,
    required this.baselineSampleRate,
    required this.replayMode,
    required this.replaySessionSampleRate,
    this.maskAllInputs = true,
    required this.bufferMaxBytes,
    required this.bufferMaxAgeSeconds,
    required this.replayMaxBytes,
    required this.persist,
    required this.triggers,
    required this.captures,
  });

  /// Kill switch: when false nothing but the OpAMP poll leaves the device.
  bool enabled;
  Map<String, SignalSettings> signals;
  bool sessionsEnabled;
  double baselineSampleRate;
  Mode replayMode;
  double replaySessionSampleRate;

  /// Read for schema parity with the browser SDK. Flutter masks with
  /// `TracewayPrivacyMask` instead of input fields.
  bool maskAllInputs;
  int bufferMaxBytes;
  double bufferMaxAgeSeconds;
  int replayMaxBytes;
  bool persist;
  List<Trigger> triggers;
  List<Capture> captures;

  Settings copy() => Settings(
        enabled: enabled,
        signals: {for (final e in signals.entries) e.key: e.value.copy()},
        sessionsEnabled: sessionsEnabled,
        baselineSampleRate: baselineSampleRate,
        replayMode: replayMode,
        replaySessionSampleRate: replaySessionSampleRate,
        maskAllInputs: maskAllInputs,
        bufferMaxBytes: bufferMaxBytes,
        bufferMaxAgeSeconds: bufferMaxAgeSeconds,
        replayMaxBytes: replayMaxBytes,
        persist: persist,
        triggers: List.of(triggers),
        captures: List.of(captures),
      );
}

/// The most a signal may do in this app, set from the init options. Remote
/// settings can only go lower.
class Ceilings {
  Ceilings({
    required this.enabled,
    required this.signals,
    required this.replay,
    required this.sessions,
  });

  final bool enabled;
  final Map<String, Mode> signals;

  /// [Mode.off] when screen capture is not allowed or the platform cannot
  /// encode video.
  final Mode replay;
  final bool sessions;
}

const String defaultExceptionTriggerId = 'default-exception';

/// Lookback of the default replay clip. The frame ring buffer holds less than
/// this, so the clip is always "everything the buffer has".
const double defaultReplayLookbackSeconds = 30;

Trigger defaultExceptionTrigger() => const Trigger(
      id: defaultExceptionTriggerId,
      name: 'Error clip',
      enabled: true,
      sampleRate: 1,
      cooldownSeconds: 5,
      maxPerSession: 20,
      steps: [
        TriggerStep(match: Condition('event.name', 'eq', value: 'exception')),
      ],
      actions: [
        TriggerAction(type: 'flush', lookbackSeconds: 600, signals: ['*']),
        TriggerAction(
          type: 'flush',
          lookbackSeconds: defaultReplayLookbackSeconds,
          signals: [],
          replay: true,
        ),
      ],
    );

/// The built-in collection policy, the same as the browser SDK's: errors and
/// messages stream, breadcrumbs and replay stay on the device until an error
/// or a capture asks for them. [recordAllSessions] streams breadcrumbs and
/// replay instead.
Settings defaultSettings({
  double baselineSampleRate = 0,
  bool recordAllSessions = false,
}) {
  SignalSettings s(Mode mode, {String? minSeverity}) =>
      SignalSettings(mode: mode, minSeverity: minSeverity);
  final breadcrumbs = recordAllSessions ? Mode.stream : Mode.buffer;
  return Settings(
    enabled: true,
    signals: {
      'errors': s(Mode.stream),
      'messages': s(Mode.stream),
      'network': s(breadcrumbs),
      'console': s(breadcrumbs, minSeverity: 'info'),
      'navigation': s(breadcrumbs),
      'userActions': s(breadcrumbs),
      'webVitals': s(Mode.buffer),
      'resourceTiming': s(Mode.off),
      'longTasks': s(Mode.off),
      'routeTiming': s(Mode.off),
      'custom': s(breadcrumbs),
    },
    sessionsEnabled: true,
    baselineSampleRate:
        baselineSampleRate.isFinite ? baselineSampleRate.clamp(0, 1) : 0,
    replayMode: recordAllSessions ? Mode.stream : Mode.buffer,
    replaySessionSampleRate: 1,
    bufferMaxBytes: 2 * 1024 * 1024,
    bufferMaxAgeSeconds: 600,
    replayMaxBytes: 8 * 1024 * 1024,
    persist: true,
    triggers: [defaultExceptionTrigger()],
    captures: [],
  );
}

Ceilings ceilingsFrom({
  bool enabled = true,
  bool screenCapture = false,
  bool captureLogs = true,
  bool captureNetwork = true,
  bool captureNavigation = true,
  bool captureUserActions = true,
  bool sessions = true,
}) {
  Mode allow(bool flag) => flag ? Mode.stream : Mode.off;
  final signals = {for (final name in signalNames) name: Mode.stream};
  signals['console'] = allow(captureLogs);
  signals['network'] = allow(captureNetwork);
  signals['navigation'] = allow(captureNavigation);
  signals['userActions'] = allow(captureUserActions);
  return Ceilings(
    enabled: enabled,
    signals: signals,
    replay: allow(screenCapture),
    sessions: sessions,
  );
}
