// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/traceway.dart';

import 'support.dart';

class UserPage extends StatelessWidget {
  const UserPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('User')),
        body: Center(
          child: ElevatedButton(
            key: const Key('open-profile'),
            onPressed: () =>
                TracewayClient.instance?.recordLog('Profile loaded for 42'),
            child: const Text('Profile'),
          ),
        ),
      );
}

final _navigator = GlobalKey<NavigatorState>();

Widget shopApp() => Traceway(
      child: MaterialApp(
        navigatorKey: _navigator,
        navigatorObservers: [Traceway.navigatorObserver],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => settings.name == '/'
              ? Scaffold(
                  body: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ElevatedButton(
                        key: const Key('pay'),
                        onPressed: () {},
                        child: const Text('Pay now'),
                      ),
                      MouseRegion(
                        child: Container(
                          key: const Key('menu'),
                          width: 120,
                          height: 40,
                          color: const Color(0xff336699),
                          child: const Text('Menu'),
                        ),
                      ),
                    ]),
                  ),
                )
              : const UserPage(),
        ),
      ),
    );

Map<String, Object?> journeyTrigger({String log = 'Profile loaded'}) => {
      'id': 'open-profile',
      'name': 'Open profile',
      'cooldownSeconds': 0,
      'steps': [
        {
          'match': {
            'event': {'type': 'navigation', 'value': '/users/{id}'}
          }
        },
        {
          'match': {
            'event': {'type': 'click', 'value': 'ElevatedButton#open-profile'}
          },
          'withinSeconds': 30,
        },
        {
          'match': {
            'event': {'type': 'log', 'value': log, 'mode': 'contains'}
          },
          'withinSeconds': 10,
        },
      ],
      'actions': [
        {
          'type': 'capture',
          'durationSeconds': 600,
          'lookbackSeconds': 30,
          'replay': true,
        }
      ],
    };

/// Runs [body] with a started client and [shopApp] on screen, then shuts
/// the client down so no timer outlives the test.
Future<void> withApp(
  WidgetTester tester,
  Future<void> Function(Harness h) body, {
  TracewayOptions options = const TracewayOptions(remoteConfig: false),
  Handler? handler,
  Directory? stateDirectory,
  FakeReplaySource? replay,
}) async {
  final h = (await tester.runAsync(() => startHarness(
      options: options, handler: handler, stateDirectory: stateDirectory)))!;
  await tester.pumpWidget(shopApp());
  await tester.pumpAndSettle();
  if (replay != null) h.client.replaySource = replay;
  try {
    await body(h);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(TracewayClient.resetForTest);
  }
}

Future<void> settle(WidgetTester tester, Harness h) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() => h.client.flush());
}

void main() {
  testWidgets('a tap is recorded with a selector naming the widget',
      (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(remoteConfig: false, recordAllSessions: true),
      (h) async {
        await tester.tap(find.text('Pay now'));
        await settle(tester, h);
        final click = h.named('browser.user_action.click').single;
        expect(attr(click, 'browser.css_selector'), 'ElevatedButton#pay');
        expect(attr(click, 'browser.tag_name'), 'ElevatedButton');
        expect(attr(click, 'app.widget.id'), 'pay');
        expect(attr(click, 'app.widget.text'), 'Pay now');
        expect(attr(click, 'app.screen.name'), '/');
        expect(attr(click, 'session.id'), isNotNull);
      },
    );
  });

  testWidgets('taps are buffered by default and leave with an error',
      (tester) async {
    await withApp(tester, (h) async {
      await tester.tap(find.text('Pay now'));
      await settle(tester, h);
      expect(h.named('browser.user_action.click'), isEmpty);
      h.client.captureException(StateError('boom'));
      await settle(tester, h);
      expect(h.named('browser.user_action.click'), hasLength(1));
    });
  });

  testWidgets('a drag is not a tap, and captureUserActions turns taps off',
      (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(remoteConfig: false, recordAllSessions: true),
      (h) async {
        await tester.drag(find.text('Pay now'), const Offset(0, 80));
        await settle(tester, h);
        expect(h.named('browser.user_action.click'), isEmpty);
      },
    );
    await withApp(
      tester,
      options: const TracewayOptions(
          remoteConfig: false,
          recordAllSessions: true,
          captureUserActions: false),
      (h) async {
        await tester.tap(find.text('Pay now'));
        await settle(tester, h);
        expect(h.named('browser.user_action.click'), isEmpty);
      },
    );
  });

  testWidgets(
      'a navigation, a tap and a log line complete a recording trigger '
      'from local settings', (tester) async {
    final replay = FakeReplaySource();
    await withApp(
      tester,
      replay: replay,
      options: TracewayOptions(
        remoteConfig: false,
        screenCapture: true,
        collection: {
          'triggers': [journeyTrigger()]
        },
      ),
      (h) async {
        // A tap on the wrong screen does not start it.
        await tester.tap(find.text('Pay now'));
        _navigator.currentState!.pushNamed('/users/42');
        await tester.pumpAndSettle();
        expect(h.client.currentScreen, '/users/42');
        await tester.tap(find.text('Profile'));
        await settle(tester, h);

        final fired = h.named('traceway.trigger.fired').single;
        expect(attr(fired, 'traceway.trigger.id'), 'open-profile');
        expect(attr(fired, 'traceway.trigger.name'), 'Open profile');
        expect(attr(fired, 'traceway.trigger.replay'), 'true');
        final steps =
            jsonDecode(attr(fired, 'traceway.trigger.steps') as String) as List;
        expect(steps.map((s) => (s as Map)['match']['event']['type']),
            ['navigation', 'click', 'log']);

        final capture = h.named('traceway.capture.started').single;
        expect(attr(capture, 'traceway.capture.source'), 'trigger');
        expect(h.client.replay.mode, Mode.stream);
        // The lookback went up: the journey's own records and the clip.
        expect(h.named('browser.navigation').map((r) => attr(r, 'url.full')),
            containsAll(['/', '/users/42']));
        expect(
            h.named('browser.user_action.click')
                .map((r) => attr(r, 'browser.css_selector')),
            ['ElevatedButton#pay', 'ElevatedButton#open-profile']);
        expect(h.named(null).map((r) => r.body),
            contains('Profile loaded for 42'));
        expect(replay.captures, isNotEmpty);
        // While the capture runs, breadcrumbs stream.
        h.client.recordLog('after the journey');
        await settle(tester, h);
        expect(h.named(null).map((r) => r.body), contains('after the journey'));
      },
    );
  });

  testWidgets('the steps must come in order and within their time',
      (tester) async {
    await withApp(
      tester,
      options: TracewayOptions(
        remoteConfig: false,
        collection: {
          'triggers': [journeyTrigger()]
        },
      ),
      (h) async {
        _navigator.currentState!.pushNamed('/users/42');
        await tester.pumpAndSettle();
        h.client.recordLog('Profile loaded before the tap');
        await settle(tester, h);
        expect(h.named('traceway.trigger.fired'), isEmpty);
      },
    );
  });

  testWidgets('an unnamed route is reported by its page widget',
      (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(remoteConfig: false, recordAllSessions: true),
      (h) async {
        _navigator.currentState!
            .push(MaterialPageRoute<void>(builder: (_) => const UserPage()));
        await tester.pumpAndSettle();
        _navigator.currentState!.pop();
        await settle(tester, h);
        final nav = h.named('browser.navigation').toList();
        expect(
            nav.map((r) =>
                '${attr(r, 'navigation.action')} ${attr(r, 'url.full')}'),
            ['push /', 'push /UserPage', 'pop /']);
        expect(attr(nav[1], 'navigation.from'), '/');
        expect(attr(nav[1], 'browser.navigation.type'), 'push');
        expect(h.client.currentScreen, '/');
      },
    );
  });

  testWidgets('a removed route is not a screen the user arrived at',
      (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(remoteConfig: false, recordAllSessions: true,
          collection: {
            'triggers': [
              {
                'id': 'back-home',
                'steps': [
                  {
                    'match': {
                      'event': {'type': 'navigation', 'value': '/'}
                    }
                  }
                ],
                'actions': [
                  {'type': 'emit', 'eventName': 'home'}
                ],
              }
            ]
          }),
      (h) async {
        _navigator.currentState!.pushNamed('/users/1');
        await tester.pumpAndSettle();
        _navigator.currentState!
            .pushNamedAndRemoveUntil('/users/2', (_) => false);
        await settle(tester, h);
        expect(h.client.currentScreen, '/users/2');
        final nav = h.named('browser.navigation').toList();
        expect(nav.map((r) => attr(r, 'navigation.action')),
            ['push', 'push', 'push', 'remove', 'remove']);
        expect(nav.where((r) => attr(r, 'navigation.action') == 'remove')
                .map((r) => attr(r, 'url.full')),
            ['', '']);
        // The app's start on `/` fired it once; the removals that leave
        // nothing below do not.
        expect(h.named('traceway.trigger.fired'), hasLength(1));
      },
    );
  });

  testWidgets('a hover step matches when the mouse enters the widget',
      (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(remoteConfig: false, collection: {
        'triggers': [
          {
            'id': 'menu-hover',
            'steps': [
              {
                'match': {
                  'event': {'type': 'hover', 'value': '#menu'}
                }
              }
            ],
            'actions': [
              {'type': 'emit', 'eventName': 'menu_hovered'}
            ],
          }
        ],
      }),
      (h) async {
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(gesture.removePointer);
        await gesture.addPointer(location: Offset.zero);
        final menu = tester.getRect(find.byKey(const Key('menu')));
        for (final dx in [10.0, 40.0, 80.0]) {
          await gesture.moveTo(menu.centerLeft + Offset(dx, 0));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await gesture.moveTo(Offset.zero);
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveTo(menu.center);
        await tester.pump(const Duration(milliseconds: 100));
        await settle(tester, h);
        // Moving inside the menu does not count again; leaving and coming
        // back does.
        expect(h.named('traceway.trigger.fired'), hasLength(2));
      },
    );
  });

  testWidgets('progress survives an app restart within the session',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('traceway_journey');
    addTearDown(() => dir.deleteSync(recursive: true));
    final options = TracewayOptions(
      remoteConfig: false,
      collection: {
        'triggers': [journeyTrigger(log: 'after restart')]
      },
    );
    await withApp(tester, stateDirectory: dir, options: options, (h) async {
      _navigator.currentState!.pushNamed('/users/7');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile'));
      await settle(tester, h);
      expect(h.named('traceway.trigger.fired'), isEmpty);
      await tester.runAsync(() => h.client.flush());
    });
    await withApp(tester, stateDirectory: dir, options: options, (h) async {
      // The capture's flush reads the saved buffer from disk: real I/O,
      // which the widget test's fake clock would never complete.
      await tester.runAsync(() async {
        h.client.recordLog('Profile shown after restart');
      });
      await settle(tester, h);
      expect(h.named('traceway.trigger.fired'), hasLength(1));
      expect(h.client.settings.signals['console']!.mode, Mode.buffer);
      expect(h.client.control.modeFor('console'), Mode.stream);
    });
    // The capture the trigger started outlives the run that started it.
    await withApp(tester, stateDirectory: dir, options: options, (h) async {
      expect(h.client.control.modeFor('console'), Mode.stream);
    });
  });

  testWidgets('rules that arrive later still see the current screen once',
      (tester) async {
    var polls = 0;
    await withApp(
      tester,
      options: const TracewayOptions(),
      handler: (request) async {
        if (!request.url.path.endsWith('/opamp')) return null;
        return polls++ == 1
            ? opampConfig({
                'triggers': [
                  {
                    'id': 'on-home',
                    'steps': [
                      {
                        'match': {
                          'event': {'type': 'navigation', 'value': '/'}
                        }
                      },
                      {
                        'match': {
                          'event': {'type': 'click', 'value': '#pay'}
                        }
                      },
                    ],
                    'actions': [
                      {'type': 'emit', 'eventName': 'paid_from_home'}
                    ],
                  }
                ]
              }, [4])
            : null;
      },
      (h) async {
        await tester.runAsync(() => h.client.refreshConfig());
        await tester.tap(find.text('Pay now'));
        await settle(tester, h);
        expect(
            h.named('traceway.trigger.fired')
                .map((r) => attr(r, 'traceway.trigger.id')),
            ['on-home']);
        final poll = h.requestsTo('/opamp').first;
        expect(utf8.decode(poll.bodyBytes, allowMalformed: true),
            contains('io.traceway.sdk.sequence-triggers/v1'));
      },
    );
  });

  testWidgets('without remote config the local collection settings apply',
      (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(remoteConfig: false, collection: {
        'signals': {
          'console': {'mode': 'stream'}
        },
      }),
      (h) async {
        h.client.recordLog('streamed by local settings');
        await settle(tester, h);
        expect(h.named(null).map((r) => r.body),
            contains('streamed by local settings'));
        expect(h.requestsTo('/opamp'), isEmpty);
      },
    );
  });

  testWidgets('remote rules lay over the local settings', (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(collection: {
        'signals': {
          'console': {'mode': 'stream'},
          'custom': {'mode': 'stream'},
        },
      }),
      handler: (request) async => request.url.path.endsWith('/opamp')
          ? opampConfig({
              'signals': {
                'console': {'mode': 'off'}
              }
            }, [6])
          : null,
      (h) async {
        await tester.runAsync(() => h.client.refreshConfig());
        expect(h.client.settings.signals['console']!.mode, Mode.off);
        expect(h.client.settings.signals['custom']!.mode, Mode.stream);
      },
    );
  });

  testWidgets('an invalid local document is ignored', (tester) async {
    await withApp(
      tester,
      options: const TracewayOptions(
          remoteConfig: false, collection: {'schemaVersion': 3}),
      (h) async {
        expect(h.client.settings.signals['console']!.mode, Mode.buffer);
      },
    );
  });

}
