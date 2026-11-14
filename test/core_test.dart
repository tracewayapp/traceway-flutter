import 'package:flutter_test/flutter_test.dart' hide matches;
import 'package:traceway/src/core/control_state.dart';
import 'package:traceway/src/core/endpoints.dart';
import 'package:traceway/src/core/ids.dart';
import 'package:traceway/src/core/matcher.dart';
import 'package:traceway/src/core/merge.dart';
import 'package:traceway/src/core/ring_buffer.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/core/trigger_engine.dart';

FieldLookup lookupOf(Map<String, Object?> values) => (key) => values[key];

void main() {
  group('resolveEndpoints', () {
    test('accepts the bare url and the 1.x report url', () {
      for (final url in [
        'https://host',
        'https://host/',
        'https://host/api',
        'https://host/api/report',
      ]) {
        final e = resolveEndpoints(url);
        expect(e.logs, 'https://host/api/otel/v1/logs');
        expect(e.traces, 'https://host/api/otel/v1/traces');
        expect(e.opamp, 'https://host/api/otel/v1/opamp');
        expect(e.recordings, 'https://host/api/recordings');
      }
    });

    test('recognises the SDK own requests', () {
      final e = resolveEndpoints('https://host/api/report');
      expect(e.isOwn('https://host/api/otel/v1/logs'), isTrue);
      expect(e.isOwn('https://host/api/recordings'), isTrue);
      expect(e.isOwn('https://host/api/users'), isFalse);
    });
  });

  group('ids', () {
    test('uuidv7 carries the timestamp, version and variant', () {
      final id = uuidv7(0x0195f2a00000);
      expect(id.startsWith('0195f2a0-0000-7'), isTrue);
      expect('89ab'.contains(id[19]), isTrue);
      expect(uuidToBytes(id), hasLength(16));
      expect(bytesToUuid(uuidToBytes(id)!), id);
    });

    test('unitHash is stable and matches the browser SDK (FNV-1a)', () {
      expect(unitHash(''), closeTo(0x811c9dc5 / 0x100000000, 1e-12));
      expect(unitHash('a'), closeTo(0xe40c292c / 0x100000000, 1e-12));
      expect(unitHash('session'), inInclusiveRange(0, 1));
    });
  });

  group('RingBuffer', () {
    test('evicts by size and by age, oldest first', () {
      var now = 1000;
      final buffer =
          RingBuffer<String>(maxBytes: 30, maxAgeMs: 1000, now: () => now);
      for (var i = 0; i < 4; i++) {
        buffer.push(BufferEntry(
            timeMs: now, signal: 'console', bytes: 10, item: 'e$i'));
      }
      expect(buffer.snapshot().map((e) => e.item), ['e1', 'e2', 'e3']);
      expect(buffer.evictedCount, 1);
      now = 2500;
      expect(buffer.snapshot(), isEmpty);
      expect(buffer.totalBytes, 0);
    });

    test('take removes only the selected window and signals', () {
      var now = 10000;
      final buffer =
          RingBuffer<String>(maxBytes: 1000, maxAgeMs: 100000, now: () => now);
      buffer.push(
          BufferEntry(timeMs: 1000, signal: 'console', bytes: 1, item: 'old'));
      buffer.push(
          BufferEntry(timeMs: 9000, signal: 'console', bytes: 1, item: 'log'));
      buffer.push(
          BufferEntry(timeMs: 9500, signal: 'network', bytes: 1, item: 'net'));
      expect(buffer.take(8000, {'console'}).map((e) => e.item), ['log']);
      expect(buffer.take(8000, <String>{}), isEmpty);
      expect(buffer.take(0, null).map((e) => e.item), ['old', 'net']);
      expect(buffer.length, 0);
    });
  });

  group('matcher', () {
    test('operators', () {
      final lookup = lookupOf({
        'event.name': 'checkout_failed',
        'attributes.status': 503,
        'resource.service.version': '2.3.1',
        'body': 'Payment FAILED hard',
      });
      bool m(String key, String op, {Object? value, List<Object>? values}) =>
          matches(Condition(key, op, value: value, values: values), lookup);
      expect(m('event.name', 'eq', value: 'checkout_failed'), isTrue);
      expect(m('event.name', 'neq', value: 'x'), isTrue);
      expect(m('attributes.status', 'eq', value: '503'), isTrue);
      expect(m('attributes.status', 'gte', value: 500), isTrue);
      expect(m('attributes.status', 'lt', value: 500), isFalse);
      expect(m('attributes.status', 'in', values: [500, 503]), isTrue);
      expect(m('attributes.status', 'not_in', values: [500, 503]), isFalse);
      expect(m('body', 'contains', value: 'FAILED'), isTrue);
      expect(m('body', 'contains', value: 'failed'), isFalse);
      expect(m('body', 'icontains', value: 'failed'), isTrue);
      expect(m('body', 'starts_with', value: 'Payment'), isTrue);
      expect(m('body', 'glob', value: 'pay*fail?d*'), isTrue);
      expect(m('missing', 'exists'), isFalse);
      expect(m('missing', 'not_exists'), isTrue);
      expect(m('resource.service.version', 'version', value: '>=2.1 <3'),
          isTrue);
      expect(m('resource.service.version', 'version', value: '<2.3'), isFalse);
    });

    test('all, any and not combine', () {
      final lookup = lookupOf({'a': 1, 'b': 2});
      const a = Condition('a', 'eq', value: 1);
      const b = Condition('b', 'eq', value: 9);
      expect(matches(const AllMatcher([a, b]), lookup), isFalse);
      expect(matches(const AnyMatcher([a, b]), lookup), isTrue);
      expect(matches(const NotMatcher(b), lookup), isTrue);
    });
  });

  group('TriggerEngine', () {
    ObservedEvent event(int timeMs, String name) =>
        ObservedEvent(timeMs: timeMs, lookup: lookupOf({'event.name': name}));

    test('default trigger fires on exceptions with cooldown and cap', () {
      final engine = TriggerEngine()
        ..setTriggers([
          defaultExceptionTrigger().copyWith(maxPerSession: 2),
        ]);
      expect(engine.observe(event(0, 'other')), isEmpty);
      expect(engine.observe(event(1000, 'exception')), hasLength(1));
      expect(engine.observe(event(2000, 'exception')), isEmpty);
      expect(engine.skipped[defaultExceptionTriggerId], 'cooldown');
      expect(engine.observe(event(7000, 'exception')), hasLength(1));
      expect(engine.observe(event(20000, 'exception')), isEmpty);
      expect(engine.skipped[defaultExceptionTriggerId], 'session_clip_limit');
      engine.resetSession();
      expect(engine.observe(event(30000, 'exception')), hasLength(1));
    });

    test('multi-step trigger honours withinSeconds', () {
      const step = Condition('event.name', 'eq', value: 'fail');
      final engine = TriggerEngine()
        ..setTriggers([
          const Trigger(id: 't', steps: [
            TriggerStep(match: step),
            TriggerStep(match: step, withinSeconds: 60),
          ], actions: [
            TriggerAction(type: 'flush', lookbackSeconds: 60),
          ]),
        ]);
      expect(engine.observe(event(0, 'fail')), isEmpty);
      expect(engine.observe(event(120000, 'fail')), isEmpty);
      expect(engine.observe(event(130000, 'fail')), hasLength(1));
    });

    test('counted step needs N hits inside the period', () {
      final engine = TriggerEngine()
        ..setTriggers([
          const Trigger(id: 't', steps: [
            TriggerStep(
              match: Condition('event.name', 'eq', value: 'e'),
              count: 3,
              periodSeconds: 10,
            ),
          ], actions: [
            TriggerAction(type: 'flush', lookbackSeconds: 60),
          ]),
        ]);
      expect(engine.observe(event(0, 'e')), isEmpty);
      expect(engine.observe(event(20000, 'e')), isEmpty);
      expect(engine.observe(event(21000, 'e')), isEmpty);
      expect(engine.observe(event(22000, 'e')), hasLength(1));
    });

    test('sampleRate uses the injected random', () {
      final engine = TriggerEngine(random: () => 0.9)
        ..setTriggers([defaultExceptionTrigger().copyWith(sampleRate: 0.5)]);
      expect(engine.observe(event(0, 'exception')), isEmpty);
      expect(engine.skipped[defaultExceptionTriggerId], 'sampled_out');
    });
  });

  group('settings', () {
    test('defaults buffer breadcrumbs and stream errors', () {
      final s = defaultSettings();
      expect(s.signals['errors']!.mode, Mode.stream);
      expect(s.signals['console']!.mode, Mode.buffer);
      expect(s.signals['network']!.mode, Mode.buffer);
      expect(s.replayMode, Mode.buffer);
      expect(s.bufferMaxBytes, 2 * 1024 * 1024);
      expect(s.bufferMaxAgeSeconds, 600);
    });

    test('overlay merges known fields and ignores malformed ones', () {
      final merged = applyOverlay(
        defaultSettings(),
        parseSettingsDocument('''{"schemaVersion":1,
          "signals":{"custom":{"mode":"stream","sampleRate":7},
                     "console":{"mode":"nope","minSeverity":"warn"}},
          "sessions":{"baselineSampleRate":0.25},
          "buffer":{"maxBytes":1e12,"maxAgeSeconds":30},
          "unknown":{"x":1},
          "triggers":[{"id":"default-exception","enabled":false},
                      {"id":"t2","steps":[{"match":{"key":"event.name","op":"eq","value":"x"}}],
                       "actions":[{"type":"flush","lookbackSeconds":60,"signals":["custom","bogus"]}]},
                      {"id":"bad","steps":[],"actions":[]}],
          "captures":[{"id":"c1","until":"2099-01-01T00:00:00Z","lookbackSeconds":0},
                      {"id":"c2","until":"not a date"}]}'''),
      );
      expect(merged.signals['custom']!.mode, Mode.stream);
      expect(merged.signals['custom']!.sampleRate, 1);
      expect(merged.signals['console']!.mode, Mode.buffer);
      expect(merged.signals['console']!.minSeverity, 'warn');
      expect(merged.baselineSampleRate, 0.25);
      expect(merged.bufferMaxBytes, 64 * 1024 * 1024);
      expect(merged.bufferMaxAgeSeconds, 30);
      expect(merged.triggers.map((t) => t.id), ['default-exception', 't2']);
      expect(merged.triggers.first.enabled, isFalse);
      expect(merged.triggers.first.steps, hasLength(1));
      expect(merged.triggers[1].actions.single.signals, ['custom']);
      expect(merged.captures.single.id, 'c1');
      expect(merged.captures.single.lookbackSeconds, 0);
    });

    test('rejects documents it cannot apply', () {
      expect(() => parseSettingsDocument('nope'), throwsA(isA<SettingsError>()));
      expect(() => parseSettingsDocument('[]'), throwsA(isA<SettingsError>()));
      expect(() => parseSettingsDocument('{"schemaVersion":2}'),
          throwsA(isA<SettingsError>()));
    });
  });

  group('ControlState', () {
    test('remote settings cannot exceed the init ceilings', () {
      final control = ControlState(
        defaultSettings(),
        ceilingsFrom(screenCapture: false, captureNetwork: false),
      );
      control.applyRemote(parseSettingsDocument(
          '{"signals":{"network":{"mode":"stream"}},"replay":{"mode":"stream"}}'));
      expect(control.modeFor('network'), Mode.off);
      expect(control.canExport('network'), isFalse);
      expect(control.replayMode, Mode.off);
    });

    test('replay never streams, whatever the server or an override asks', () {
      var now = 0;
      final control = ControlState(
        defaultSettings(),
        ceilingsFrom(screenCapture: true),
        now: () => now,
      );
      expect(control.replayMode, Mode.buffer);
      control.applyRemote(parseSettingsDocument(
          '{"replay":{"mode":"stream","sessionSampleRate":1}}'));
      expect(control.settings.replayMode, Mode.buffer);
      expect(control.replayMode, Mode.buffer);
      control.addOverride(StreamOverride(signals: ['*'], untilMs: 1000));
      expect(control.replayMode, Mode.buffer);
      control.applyRemote(parseSettingsDocument('{"replay":{"mode":"off"}}'));
      expect(control.replayMode, Mode.off);
    });

    test('plan limits lower the ceilings', () {
      final control =
          ControlState(defaultSettings(), ceilingsFrom(screenCapture: true));
      control.applyRemote(parseSettingsDocument(
          '{"signals":{"custom":{"mode":"stream"}},'
          '"limits":{"signals":{"custom":"buffer"},"replay":"off"}}'));
      expect(control.modeFor('custom'), Mode.buffer);
      expect(control.replayMode, Mode.off);
    });

    test('stream overrides expire', () {
      var now = 0;
      final control =
          ControlState(defaultSettings(), ceilingsFrom(), now: () => now);
      control.addOverride(StreamOverride(signals: ['console'], untilMs: 1000));
      expect(control.modeFor('console'), Mode.stream);
      expect(control.modeFor('network'), Mode.buffer);
      now = 1001;
      expect(control.modeFor('console'), Mode.buffer);
    });

    test('kill switch turns everything off', () {
      final control =
          ControlState(defaultSettings(), ceilingsFrom(screenCapture: true));
      control.applyRemote(parseSettingsDocument('{"enabled":false}'));
      expect(control.enabled, isFalse);
      expect(control.modeFor('errors'), Mode.off);
      expect(control.replayMode, Mode.off);
    });
  });
}
