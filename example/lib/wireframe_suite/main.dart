// The wireframe replay regression suite: a gallery of Flutter UI that
// records itself with TracewayScreenCaptureMode.wireframe and drives itself
// through every scenario with real pointer events. tool/e2e/wireframe/run.py
// runs it, replays the recording and compares every checkpoint with what
// the app drew and with the accepted baseline.
//
//   flutter build linux --debug -t lib/wireframe_suite/main.dart
//   TRACEWAY_DSN=token@http://127.0.0.1:8082 build/linux/x64/debug/bundle/traceway_example
//
// The DSN comes from the environment (desktop) or from
// --dart-define=TRACEWAY_DSN (mobile). E2E_ONLY=forms,overlays runs only
// those scenarios; E2E_SHOTS is where the app saves its own pictures.
//
// The app runs on SuiteBinding, which can show a soft keyboard on desktop
// (driver.dart's `simulatedKeyboard`).
//
// Prints, one per line: E2E_WINDOW, E2E_SESSION, E2E_SECRET <json>,
// E2E_VIEW <size>, E2E_SCENARIO <id> <ms>, E2E_CHECKPOINT <json>,
// E2E_SCENARIO_FAILED <id> <error>, E2E_TOUR_DONE and E2E_DONE.
import 'dart:async';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:traceway/traceway.dart';

import 'driver.dart';
import 'scenario.dart';
import 'scenes/forms.dart';
import 'scenes/keyboard.dart';
import 'scenes/layout.dart';
import 'scenes/media.dart';
import 'scenes/motion.dart';
import 'scenes/navigation.dart';
import 'scenes/overlays.dart';
import 'scenes/privacy.dart';
import 'scenes/scrolling.dart';

final String _dsn = Platform.environment['TRACEWAY_DSN'] ??
    const String.fromEnvironment('TRACEWAY_DSN');

final Set<String>? _only = Platform.environment['E2E_ONLY']
    ?.split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toSet();

bool _selected(String id) => _only == null || _only!.contains(id);

final _shotKey = GlobalKey();
final _navigator = GlobalKey<NavigatorState>();
final _homeList = ScrollController();
final driver = Driver(
  shotKey: _shotKey,
  navigator: _navigator,
  shotsDir: Platform.environment['E2E_SHOTS'],
);

/// Every scenario, in the order the tour visits them.
final List<Scenario> scenarios = [
  ...layoutScenarios,
  ...scrollingScenarios,
  ...navigationScenarios,
  ...formScenarios,
  ...overlayScenarios,
  ...mediaScenarios,
  ...motionScenarios,
  ...privacyScenarios,
  ...keyboardScenarios,
];

/// The binding of the suite: Flutter's, with [SimulatedKeyboard] between
/// the view and the app, so a desktop run can show a soft keyboard.
class SuiteBinding extends WidgetsFlutterBinding {
  @override
  Widget wrapWithDefaultView(Widget rootWidget) =>
      super.wrapWithDefaultView(SimulatedKeyboard(child: rootWidget));
}

void main() {
  if (_dsn.isEmpty) {
    stderr.writeln('Set TRACEWAY_DSN=token@http://host:port');
    exit(64);
  }
  // A blinking caret would keep a focused field from ever settling.
  EditableText.debugDeterministicCursor = true;
  SuiteBinding();
  final at = _dsn.indexOf('@');
  Traceway.run(
    token: _dsn.substring(0, at < 0 ? 0 : at),
    baseUrl: _dsn.substring(at + 1),
    options: const TracewayOptions(
      screenCapture: true,
      screenCaptureMode: TracewayScreenCaptureMode.wireframe,
      recordAllSessions: true,
      remoteConfig: false,
      debug: true,
      version: 'wireframe-suite',
      fps: 10,
      // Pictures are inlined whatever the network.
      collection: {
        'replay': {'images': 'always'},
      },
    ),
    child: RepaintBoundary(key: _shotKey, child: const SuiteApp()),
  );
}

class SuiteApp extends StatelessWidget {
  const SuiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      title: 'Wireframe suite',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3F51B5)),
      navigatorObservers: [Traceway.navigatorObserver],
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    unawaited(_tour().catchError((Object e, StackTrace s) {
      print('E2E_FAILED $e\n$s');
      exit(1);
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wireframe suite'),
        actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.search))],
      ),
      body: ListView(
        controller: _homeList,
        // The last entries scroll up from under the button.
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          for (final scenario in scenarios)
            ListTile(
              leading: CircleAvatar(child: Icon(scenario.icon)),
              title: Text(scenario.title),
              subtitle: Text(scenario.subtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final settings = RouteSettings(name: '/${scenario.id}');
                Widget builder(BuildContext _) => scenario.page();
                Navigator.of(context).push(scenario.route?.call(builder, settings) ??
                    MaterialPageRoute<void>(settings: settings, builder: builder));
              },
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {},
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
    );
  }
}

/// Taps the home entry of [scenario], scrolling the list to it first.
Future<void> _open(Scenario scenario) async {
  final d = driver;
  final s = d.screen;
  bool onScreen(Element? e) {
    if (e == null) return false;
    final y = d.rectOf(e).center.dy;
    return y > 64 && y < s.height - 90;
  }

  var entry = d.findText(scenario.title);
  for (var i = 0; i < 12 && !onScreen(entry); i++) {
    final below = entry == null || d.rectOf(entry).center.dy >= s.height - 90;
    await d.drag(Offset(s.width / 2, s.height * 0.5),
        Offset(0, (below ? -1 : 1) * s.height * 0.3));
    await d.settle();
    entry = d.findText(scenario.title);
  }
  if (!onScreen(entry)) throw DriverError('no entry "${scenario.title}" on screen');
  await d.tapAt(d.rectOf(entry!).center);
  await d.pause(400);
  await d.settle();
}

Future<void> _tour() async {
  final client = TracewayClient.instance!;
  await client.ready;
  final d = driver..install();
  // The harness sizes the window until the view is E2E_SIZE (a phone's):
  // it hears each size the view takes.
  final wanted = Platform.environment['E2E_SIZE'];
  String size() => '${d.screen.width.round()}x${d.screen.height.round()}';
  var reported = '';
  for (var i = 0; i < 120; i++) {
    if (size() != reported) {
      reported = size();
      print('E2E_VIEW $reported');
    }
    if (wanted == null ? d.screen.width <= 700 : reported == wanted) break;
    await d.pause(250);
  }
  await d.pause(1200);
  print('E2E_WINDOW ${d.screen.width.round()}x${d.screen.height.round()}');
  print('E2E_SESSION ${client.currentSessionId}');
  secrets.forEach(d.secret);

  if (_selected('home')) {
    d.scenario = 'home';
    print('E2E_SCENARIO home ${DateTime.now().millisecondsSinceEpoch}');
    await d.checkpoint('home', shows: ['Wireframe suite', 'Text & typography']);
    await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.75),
        Offset(0, -d.screen.height * 0.4));
    await d.checkpoint('home-scrolled', shows: ['Wireframe suite']);
  }

  var failed = 0;
  for (final scenario in scenarios.where((s) => _selected(s.id))) {
    d.scenario = scenario.id;
    print('E2E_SCENARIO ${scenario.id} ${DateTime.now().millisecondsSinceEpoch}');
    try {
      await _open(scenario);
      await scenario.script(d);
    } catch (e, stack) {
      failed++;
      print('E2E_SCENARIO_FAILED ${scenario.id} $e');
      print(stack);
    }
    await d.home();
  }

  d.scenario = 'end';
  print('E2E_SCENARIO end ${DateTime.now().millisecondsSinceEpoch}');
  // The same last screen whichever scenarios ran.
  _homeList.jumpTo(0);
  await d.checkpoint('end', shows: ['Wireframe suite']);
  print('E2E_TOUR_DONE failed=$failed');
  // Going to the background uploads the last segment.
  WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await client.flush(20000);
  await d.pause(1500);
  await client.flush(20000);
  print('E2E_DONE session=${client.currentSessionId}');
  exit(0);
}
