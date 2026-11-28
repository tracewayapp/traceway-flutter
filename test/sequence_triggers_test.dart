// The browser SDK's sequence-trigger tests (js-client
// packages/core/src/sequence-triggers.test.ts), ported so both engines are
// held to the same behavior.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/core/matcher.dart' as m;
import 'package:traceway/src/core/merge.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/core/trigger_engine.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

import 'support.dart';

ObservedEvent event(int timeMs, Map<String, Object?> fields,
        {String? sequence}) =>
    ObservedEvent(timeMs: timeMs, lookup: (key) => fields[key], sequence: sequence);

Trigger parseTrigger(Map<String, Object?> json) =>
    applyOverlay(defaultSettings(), {
      'triggers': [json]
    }).triggers.firstWhere((t) => t.id == json['id']);

final journey = parseTrigger({
  'id': 'journey',
  'maxPerSession': 1,
  'steps': [
    {
      'match': {
        'event': {'type': 'click', 'value': '#users .open'}
      }
    },
    {
      'match': {
        'event': {'type': 'navigation', 'value': '/users/{id}'}
      },
      'withinSeconds': 10,
    },
    {
      'match': {
        'event': {'type': 'log', 'value': 'loaded'}
      },
      'withinSeconds': 5,
    },
  ],
  'actions': [
    {'type': 'capture', 'replay': true, 'durationSeconds': 30}
  ],
});

Map<String, Object?> named(String name) =>
    {'key': 'event.name', 'op': 'eq', 'value': name};

List<int> run(List<Map<String, Object?>> steps, List<(int, String)> events) {
  final engine = TriggerEngine()
    ..setTriggers([
      parseTrigger({
        'id': 't',
        'steps': steps,
        'actions': [
          {'type': 'emit', 'eventName': 'x'}
        ],
      })
    ]);
  return [
    for (final (time, name) in events)
      engine.observe(event(time, {'event.name': name})).length,
  ];
}

void main() {
  test('a huge withinSeconds is capped instead of breaking every record', () {
    final steps = [
      {'match': named('a')},
      {'match': named('b'), 'withinSeconds': 1e306},
    ];
    expect(parseTrigger({
      'id': 't',
      'steps': steps,
      'actions': [
        {'type': 'emit', 'eventName': 'x'}
      ],
    }).steps[1].withinSeconds, 24 * 60 * 60);
    expect(run(steps, [(0, 'a'), (1000, 'c'), (2000, 'b')]), [0, 0, 1]);
  });

  group('event sequences', () {
    test(
        'restores a click across an app restart, fires once, and ignores '
        'unrelated logs', () {
      final first = TriggerEngine()..setTriggers([journey]);
      first.observe(event(1000, {
        m.keyPointerAction: 'click',
        m.keyTargetMatches: (String s) => s == '#users .open',
      }));
      final next = TriggerEngine()..setTriggers([journey]);
      next.restoreProgress(
          jsonDecode(jsonEncode(first.snapshotProgress())), 2000);
      expect(
          next.observe(event(2000, {
            'event.name': 'browser.navigation',
            'attributes.url.full': 'https://app.test/users/42?secret=hidden',
          })),
          isEmpty);
      expect(
          next.observe(
              event(2100, {'event.name': 'browser.console', 'body': 'other'})),
          isEmpty);
      expect(
          next.observe(
              event(2200, {'event.name': 'browser.console', 'body': 'loaded'})),
          hasLength(1));
      expect(
          next.observe(
              event(2300, {'event.name': 'browser.console', 'body': 'loaded'})),
          isEmpty);
    });

    test('rejects expired and changed-rule progress', () {
      final engine = TriggerEngine()..setTriggers([journey]);
      engine.observe(event(1000, {
        m.keyPointerAction: 'click',
        m.keyTargetMatches: (String _) => true,
      }));
      final changed = journey.copyWith(actions: const [
        TriggerAction(type: 'startReplay', durationSeconds: 10),
      ]);
      for (final (rule, now) in [(journey, 12000), (changed, 2000)]) {
        final restored = TriggerEngine()..setTriggers([rule]);
        restored.restoreProgress(engine.snapshotProgress(), now);
        restored.observe(event(now, {
          'event.name': 'browser.navigation',
          'attributes.url.full': '/users/42',
        }));
        expect(
            restored.observe(event(
                now + 1, {'event.name': 'browser.console', 'body': 'loaded'})),
            isEmpty);
      }
    });

    test('matches exactly one route segment and preserves case', () {
      const m0 = EventMatcher('navigation', '/users/{id}');
      for (final (url, expected) in [
        ('/users/42', true),
        ('/users/42/edit', false),
        ('/Users/42', false),
        ('/users/', false),
        ('users/42', true),
        ('/users/42?tab=1', true),
      ]) {
        expect(
            m.matches(
                m0,
                (k) => k == 'event.name'
                    ? 'browser.navigation'
                    : k == 'attributes.url.full'
                        ? url
                        : null),
            expected,
            reason: url);
      }
      expect(m.matchesRoute('/café', '/caf%C3%A9'), isTrue);
    });

    test('validates bounded event matchers and distinguishes exact and '
        'contains logs', () {
      expect(
          parseMatcher({
            'event': {'type': 'hover', 'value': '#menu'}
          }),
          isA<EventMatcher>());
      for (final bad in [
        {'type': 'click', 'value': ':has(*)'},
        {'type': 'click', 'value': 'a, b'},
        {'type': 'unknown', 'value': 'x'},
        {'type': 'log', 'value': ' '},
        {'type': 'log', 'value': 'x', 'mode': 'regex'},
        {'type': 'log', 'value': 'x' * 257},
      ]) {
        expect(parseMatcher({'event': bad}), isNull, reason: '$bad');
      }
      Object? lookup(String k) =>
          k == 'event.name' ? 'browser.console' : 'some loaded message';
      expect(m.matches(const EventMatcher('log', 'loaded'), lookup), isFalse);
      expect(
          m.matches(const EventMatcher('log', 'loaded', mode: 'contains'), lookup),
          isTrue);
      expect(
          m.matches(const EventMatcher('log', 'hello'),
              (k) => {'signal': 'messages', 'body': 'hello'}[k]),
          isTrue);
    });

    test('a trigger with a malformed event step is dropped whole', () {
      final settings = applyOverlay(defaultSettings(), {
        'triggers': [
          {
            'id': 'bad',
            'steps': [
              {
                'match': {
                  'event': {'type': 'click', 'value': 'a:hover'}
                }
              }
            ],
            'actions': [
              {'type': 'emit', 'eventName': 'x'}
            ],
          }
        ]
      });
      expect(settings.triggers.map((t) => t.id), ['default-exception']);
    });

    test('steps are reported in the schema the server validates', () {
      final steps = jsonDecode(jsonEncode(journey.stepsJson())) as List;
      expect(steps[0], {
        'match': {
          'event': {'type': 'click', 'value': '#users .open'}
        },
        'withinSeconds': null,
      });
      expect(steps[1]['withinSeconds'], 10);
    });
  });

  group('overlapping sequences', () {
    test('keeps progress when the first step happens again', () {
      expect(
        run([
          {'match': named('a')},
          {'match': named('b')},
          {'match': named('c')},
        ], [
          (1, 'a'),
          (2, 'b'),
          (3, 'a'),
          (4, 'c'),
        ]),
        [0, 0, 0, 1],
      );
    });

    test('fires an action after an error storm that keeps going', () {
      expect(
        run([
          {'match': named('err'), 'count': 3, 'periodSeconds': 10},
          {'match': named('retry'), 'withinSeconds': 5},
        ], [
          (0, 'err'),
          (100, 'err'),
          (200, 'err'),
          (300, 'err'),
          (400, 'retry'),
        ]),
        [0, 0, 0, 0, 1],
      );
    });

    test('measures a timeout from the latest earlier step', () {
      final steps = [
        {'match': named('a')},
        {'match': named('b'), 'withinSeconds': 5},
      ];
      expect(run(steps, [(0, 'a'), (4000, 'a'), (8000, 'b')]), [0, 0, 1]);
      expect(run(steps, [(0, 'a'), (6000, 'b')]), [0, 0]);
    });

    test('counts a later step only from the moment the earlier one completed',
        () {
      expect(
        run([
          {'match': named('a')},
          {'match': named('b'), 'count': 2, 'withinSeconds': 10},
        ], [
          (0, 'b'),
          (1, 'a'),
          (2, 'b'),
          (3, 'a'),
          (3, 'b'),
        ]),
        [0, 0, 0, 0, 1],
      );
    });

    test('does not let one event complete two steps', () {
      expect(
        run([
          {'match': named('a')},
          {'match': named('a')},
        ], [
          (0, 'a'),
          (0, 'a'),
          (0, 'a'),
          (0, 'a'),
        ]),
        [0, 1, 0, 1],
      );
    });

    test('carries a count on the first step across app starts', () {
      final counted = parseTrigger({
        'id': 'burst',
        'steps': [
          {'match': named('err'), 'count': 3, 'periodSeconds': 60}
        ],
        'actions': [
          {'type': 'emit', 'eventName': 'x'}
        ],
      });
      final first = TriggerEngine()..setTriggers([counted]);
      first.observe(event(1000, {'event.name': 'err'}));
      first.observe(event(2000, {'event.name': 'err'}));
      final next = TriggerEngine()..setTriggers([counted]);
      next.restoreProgress(
          jsonDecode(jsonEncode(first.snapshotProgress())), 3000);
      expect(next.observe(event(3000, {'event.name': 'err'})), hasLength(1));
    });

    test('keeps a step without a timeout for as long as the session', () {
      final open = parseTrigger({
        'id': 'open',
        'steps': [
          {'match': named('a')},
          {'match': named('b')},
        ],
        'actions': [
          {'type': 'emit', 'eventName': 'x'}
        ],
      });
      final first = TriggerEngine()..setTriggers([open]);
      first.observe(event(0, {'event.name': 'a'}));
      final next = TriggerEngine()..setTriggers([open]);
      next.restoreProgress(first.snapshotProgress(), 3600000);
      expect(next.observe(event(3600000, {'event.name': 'b'})), hasLength(1));
    });

    test('matches a tap only against steps that name a click', () {
      final engine = TriggerEngine()
        ..setTriggers([
          parseTrigger({
            'id': 'negated',
            'steps': [
              {
                'match': {'not': named('exception')}
              }
            ],
            'actions': [
              {'type': 'emit', 'eventName': 'x'}
            ],
          }),
          parseTrigger({
            'id': 'pro-click',
            'steps': [
              {
                'match': {
                  'all': [
                    {
                      'event': {'type': 'click', 'value': '#buy'}
                    },
                    {'key': 'global.plan', 'op': 'eq', 'value': 'pro'},
                  ]
                }
              }
            ],
            'actions': [
              {'type': 'emit', 'eventName': 'x'}
            ],
          }),
        ]);
      final fired = engine.observe(event(
        0,
        {
          m.keyPointerAction: 'click',
          m.keyTargetMatches: (String _) => true,
          'global.plan': 'pro',
        },
        sequence: 'click',
      ));
      expect(fired.map((f) => f.trigger.id), ['pro-click']);
    });

    test('only reports a change of progress when there is one', () {
      final engine = TriggerEngine()
        ..setTriggers([
          parseTrigger({
            'id': 't',
            'steps': [
              {'match': named('a')},
              {'match': named('b')},
            ],
            'actions': [
              {'type': 'emit', 'eventName': 'x'}
            ],
          })
        ]);
      final before = engine.progressVersion;
      engine.observe(event(0, {'event.name': 'other'}));
      expect(engine.progressVersion, before);
      engine.observe(event(1, {'event.name': 'a'}));
      expect(engine.progressVersion, isNot(before));
    });

    test('a snapshot does not change with later progress', () {
      final counted = parseTrigger({
        'id': 'burst',
        'steps': [
          {'match': named('a')},
          {'match': named('err'), 'count': 5, 'periodSeconds': 1},
        ],
        'actions': [
          {'type': 'emit', 'eventName': 'x'}
        ],
      });
      final engine = TriggerEngine()..setTriggers([counted]);
      engine.observe(event(0, {'event.name': 'a'}));
      engine.observe(event(100, {'event.name': 'err'}));
      final snapshot = engine.snapshotProgress();
      final saved = jsonEncode(snapshot);
      for (var t = 2000; t < 2600; t += 100) {
        engine.observe(event(t, {'event.name': 'err'}));
      }
      expect(jsonEncode(snapshot), saved);
    });

    test('fire counts survive a restart within the session', () {
      final once = parseTrigger({
        'id': 'once',
        'maxPerSession': 1,
        'steps': [
          {'match': named('a')}
        ],
        'actions': [
          {'type': 'emit', 'eventName': 'x'}
        ],
      });
      final first = TriggerEngine()..setTriggers([once]);
      expect(first.observe(event(0, {'event.name': 'a'})), hasLength(1));
      final next = TriggerEngine()..setTriggers([once]);
      next.restoreSessionLimits(
          jsonDecode(jsonEncode(first.snapshotSessionLimits())));
      expect(next.observe(event(1, {'event.name': 'a'})), isEmpty);
      expect(next.skipped['once'], 'session_clip_limit');
    });
  });

  group('progress on the device', () {
    tearDown(TracewayClient.resetForTest);

    test('a new config does not bring back progress of a trigger that fired',
        () async {
      final trigger = {
        'id': 'a-then-b',
        'steps': [
          {'match': named('step_a')},
          {'match': named('step_b')},
        ],
        'actions': [
          {'type': 'emit', 'eventName': 'x'}
        ],
      };
      Map<String, dynamic> settings = {
        'triggers': [trigger]
      };
      var hash = [1];
      final h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async => request.url.path.endsWith('/opamp')
            ? opampConfig(settings, hash)
            : null,
      );
      await h.client.refreshConfig();
      h.client.track('step_a');
      h.client.track('step_b');
      settings = {
        'triggers': [trigger],
        'buffer': {'maxAgeSeconds': 300},
      };
      hash = [2];
      await h.client.refreshConfig();
      h.client.track('step_b');
      await h.client.flush();
      expect(
          h.named('traceway.trigger.fired')
              .where((r) => attr(r, 'traceway.trigger.id') == 'a-then-b'),
          hasLength(1));
    });
  });
}
