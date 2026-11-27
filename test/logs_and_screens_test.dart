// Log capture (levels, package:logging, printed lines) and the context an
// issue carries (the screen it happened on), with the error handlers'
// console output kept out of the logs.
// ignore_for_file: avoid_print, deprecated_member_use
import 'dart:async';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show Severity;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:traceway/src/core/ids.dart';
import 'package:traceway/src/error_handler.dart';
import 'package:traceway/src/events/log_capture.dart';
import 'package:traceway/src/opamp/messages.dart';
import 'package:traceway/src/otel/events.dart';
import 'package:traceway/traceway.dart';

import 'support.dart';

/// Runs [body] in the zone `Traceway.run` records printed lines in.
T inLogZone<T>(T Function() body) =>
    runZoned(body, zoneSpecification: buildLogZoneSpec());

/// Breadcrumbs only leave the device with an issue.
Future<void> flushWithError(Harness h) async {
  h.client.captureException(StateError('flush'));
  await h.client.flush();
}

Map<String, LogRecordView> logsByBody(Harness h) => {
      for (final r in h.named(null)) '${r.body}': LogRecordView(r),
    };

/// What a test reads from one exported log record.
class LogRecordView {
  LogRecordView(this.record);
  final dynamic record;
  Severity? get severity => record.severityNumber as Severity?;
  String? get severityText => record.severityText as String?;
  Object? operator [](String key) => attr(record, key);
}

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Checkout')));
}

final _navigator = GlobalKey<NavigatorState>();

Widget shop({VoidCallback? onLongPress}) => Traceway(
      child: MaterialApp(
        navigatorKey: _navigator,
        navigatorObservers: [Traceway.navigatorObserver],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () {},
                onLongPress: onLongPress ?? () {},
                child: const SizedBox(
                    width: 200, height: 60, child: Text('Hold me')),
              ),
            ),
          ),
        ),
      ),
    );

Future<Harness> startApp(WidgetTester tester, Widget app,
    {TracewayOptions options = const TracewayOptions(
        remoteConfig: false, recordAllSessions: true)}) async {
  final h = (await tester.runAsync(() => startHarness(options: options)))!;
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(TracewayClient.resetForTest);
  });
  return h;
}

Future<void> settle(WidgetTester tester, Harness h) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() => h.client.flush());
}

void main() {
  tearDown(TracewayClient.resetForTest);

  group('logs', () {
    test('Traceway.log keeps its level; a printed line is info', () async {
      final h = await startHarness();
      Traceway.log('cart synced', level: TracewayLogLevel.debug);
      h.client.log('payment declined',
          level: TracewayLogLevel.warn,
          error: StateError('card expired'),
          stackTrace: StackTrace.current,
          attributes: {'order.id': '42'});
      Traceway.log('cannot reach the payment provider',
          level: TracewayLogLevel.fatal);
      h.client.recordLog('plain line');
      await flushWithError(h);

      final logs = logsByBody(h);
      // The console's minimum severity is info unless settings lower it.
      expect(logs.keys, isNot(contains('cart synced')));
      final declined = logs['payment declined']!;
      expect(declined.severity, Severity.WARN);
      expect(declined.severityText, 'WARN');
      expect(declined['log.source'], 'api');
      expect(declined['order.id'], '42');
      expect(declined['exception.type'], 'StateError');
      expect(declined['exception.message'], contains('card expired'));
      expect(declined['exception.stacktrace'], contains('logs_and_screens_test'));
      expect(logs['cannot reach the payment provider']!.severity,
          Severity.FATAL);
      expect(logs['plain line']!.severity, Severity.INFO);
      expect(logs['plain line']!['log.source'], 'print');
    });

    test('package:logging records keep their level, logger and error',
        () async {
      final h = await startHarness();
      final log = Logger('checkout');
      log.warning('slow payment provider');
      log.severe('payment failed', StateError('declined'), StackTrace.current);
      log.shout('ledger out of sync');
      log.fine('below the default level, so never published');
      await flushWithError(h);

      final logs = logsByBody(h);
      expect(logs.keys, isNot(contains(startsWith('below the default'))));
      final slow = logs['slow payment provider']!;
      expect(slow.severity, Severity.WARN);
      expect(slow['log.source'], 'logging');
      expect(slow['logger.name'], 'checkout');
      final failed = logs['payment failed']!;
      expect(failed.severity, Severity.ERROR);
      expect(failed['exception.message'], contains('declined'));
      expect(failed['exception.stacktrace'], isNotNull);
      expect(logs['ledger out of sync']!.severity, Severity.FATAL);
    });

    test('package:logging maps every level', () async {
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = previous);
      final h = await startHarness(
        options: const TracewayOptions(remoteConfig: false, collection: {
          'signals': {
            'console': {'minSeverity': 'trace'}
          }
        }),
      );
      Traceway.log('cart synced', level: TracewayLogLevel.debug);
      final log = Logger('levels');
      log.finest('finest');
      log.fine('fine');
      log.config('config');
      log.info('info');
      await flushWithError(h);
      final logs = logsByBody(h);
      expect(logs['cart synced']!.severity, Severity.DEBUG);
      expect(logs['cart synced']!.severityText, 'DEBUG');
      expect(logs['finest']!.severity, Severity.TRACE);
      expect(logs['fine']!.severity, Severity.DEBUG);
      expect(logs['config']!.severity, Severity.INFO);
      expect(logs['info']!.severity, Severity.INFO);
    });

    for (final appListensFirst in [true, false]) {
      test(
          'a logging record the app prints itself is recorded once, with its '
          'level (app listens ${appListensFirst ? 'before' : 'after'} the SDK)',
          () async {
        late StreamSubscription<LogRecord> printing;
        void listen() => printing = inLogZone(() => Logger.root.onRecord
            .listen((r) => print('${r.level.name}: ${r.time}: ${r.message}')));
        Harness h;
        if (appListensFirst) {
          listen();
          h = await startHarness();
        } else {
          h = await startHarness();
          listen();
        }
        addTearDown(() => printing.cancel());

        inLogZone(() {
          Logger('stock').warning('stock low for sku 991');
          print('an unrelated line');
        });
        await flushWithError(h);

        final bodies = h.named(null).map((r) => '${r.body}').toList();
        expect(bodies.where((b) => b.contains('stock low')),
            ['stock low for sku 991']);
        expect(logsByBody(h)['stock low for sku 991']!.severity, Severity.WARN);
        expect(bodies, contains('an unrelated line'));
      });
    }

    test('a line printed just before an issue leaves with it', () async {
      final h = await startHarness();
      inLogZone(() {
        print('about to charge the card');
        h.client.captureException(StateError('charge failed'));
      });
      await h.client.flush();
      // Console lines are buffered: one recorded after the issue would
      // still be on the device.
      expect(h.named(null).map((r) => r.body),
          contains('about to charge the card'));
    });

    test("the console's minimum severity filters by level", () async {
      final h = await startHarness(
        options: const TracewayOptions(remoteConfig: false, collection: {
          'signals': {
            'console': {'minSeverity': 'warn'}
          }
        }),
      );
      h.client.recordLog('printed, so info');
      Traceway.log('debug detail', level: TracewayLogLevel.debug);
      Traceway.log('retrying payment', level: TracewayLogLevel.warn);
      Logger('pay').severe('gave up');
      await flushWithError(h);
      expect(logsByBody(h).keys.toSet(), {'retrying payment', 'gave up'});
    });

    test('what is printed in withoutConsoleCapture is not recorded', () async {
      final h = await startHarness();
      inLogZone(() {
        h.client.withoutConsoleCapture(() => print('an error dump line'));
        print('kept');
      });
      await flushWithError(h);
      expect(logsByBody(h).keys, ['kept']);
    });

    test('captureLogs: false records neither lines nor logging records',
        () async {
      final h = await startHarness(
          options:
              const TracewayOptions(remoteConfig: false, captureLogs: false));
      Logger('quiet').warning('not recorded');
      Traceway.log('not recorded either');
      await flushWithError(h);
      expect(h.named(null), isEmpty);
    });
  });

  group('error handlers', () {
    late FlutterExceptionHandler? flutterHandler;
    late ErrorCallback? platformHandler;
    late DebugPrintCallback printer;
    final printed = <String>[];

    setUp(() {
      flutterHandler = FlutterError.onError;
      platformHandler = PlatformDispatcher.instance.onError;
      printer = debugPrint;
      printed.clear();
      // Synchronous, through the zone's print.
      debugPrint = (message, {wrapWidth}) => print(message);
    });

    tearDown(() {
      FlutterError.onError = flutterHandler;
      PlatformDispatcher.instance.onError = platformHandler;
      debugPrint = printer;
    });

    /// Runs [body] where printed lines are both recorded and collected.
    void printing(void Function() body) => runZoned(
          () => inLogZone(body),
          zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => printed.add(line)),
        );

    test('a silent Flutter error is not an issue; a loud one is, and its dump '
        'is not recorded as log lines', () async {
      final h = await startHarness(
          options:
              const TracewayOptions(remoteConfig: false, captureMetrics: false));
      final seen = <Object>[];
      FlutterError.onError = (details) {
        seen.add(details.exception);
        FlutterError.dumpErrorToConsole(details, forceReport: true);
      };
      ErrorHandler().install();

      printing(() {
        FlutterError.reportError(FlutterErrorDetails(
          exception: StateError('image 404, nobody listening'),
          silent: true,
        ));
        FlutterError.reportError(
            FlutterErrorDetails(exception: StateError('layout overflowed')));
      });
      await h.client.flush();

      final issues = h.named(eventException).toList();
      expect(issues.map((r) => attr(r, 'exception.message')),
          [contains('layout overflowed')]);
      // The app's own handler still sees both, and prints them.
      expect(seen, hasLength(2));
      expect(printed.join('\n'), contains('layout overflowed'));
      expect(h.named(null).where((r) => '${r.body}'.contains('overflowed')),
          isEmpty);
    });

    test('an uncaught async error is reported and printed, once', () async {
      final h = await startHarness();
      PlatformDispatcher.instance.onError = null;
      final handler = ErrorHandler()..install();
      // The zone hands the error on to the root zone, whose errors the
      // engine gives to PlatformDispatcher.onError: with no app handler
      // there, the SDK prints it.
      printing(() => runZonedGuarded(
            () => runZonedGuarded(
                () => scheduleMicrotask(() => throw StateError('async boom')),
                handler.handleZoneError),
            (error, stack) => PlatformDispatcher.instance.onError!(error, stack),
          ));
      await Future<void>.delayed(Duration.zero);
      await h.client.flush();

      expect(h.named(eventException).map((r) => attr(r, 'exception.message')),
          [contains('async boom')]);
      expect(printed.join('\n'), contains('async boom'));
      expect(h.named(null).where((r) => '${r.body}'.contains('async boom')),
          isEmpty);
    });

    test('an unhandled platform error is printed when no app handler takes it',
        () async {
      await startHarness();
      PlatformDispatcher.instance.onError = null;
      ErrorHandler().install();
      bool? handled;
      printing(() => handled = PlatformDispatcher.instance.onError!(
          StateError('isolate boom'), StackTrace.current));
      expect(handled, isTrue);
      expect(printed.join('\n'), contains('isolate boom'));
    });
  });

  group('the screen an issue happened on', () {
    testWidgets('errors and messages carry the screen, the one before it, '
        'how long it was shown and the window size', (tester) async {
      final h = await startApp(tester, shop());
      _navigator.currentState!.pushNamed('/cart');
      await tester.pumpAndSettle();
      _navigator.currentState!.pushNamed('/checkout');
      await tester.pumpAndSettle();
      h.client.captureException(StateError('pay'));
      h.client.captureMessage('retrying payment', {'attempt': '2'});
      await settle(tester, h);

      for (final record in [
        h.named(eventException).single,
        h.named(eventMessage).single
      ]) {
        expect(attr(record, 'app.screen.name'), '/checkout');
        expect(attr(record, 'app.screen.previous'), '/cart');
        expect(attr(record, 'app.screen.duration_ms'), isA<int>());
        expect(attr(record, 'viewport'), matches(RegExp(r'^\d+x\d+$')));
      }
      expect(attr(h.named(eventMessage).single, 'attempt'), '2');
    });

    testWidgets('an attribute the app passes wins over the context',
        (tester) async {
      final h = await startApp(tester, shop());
      h.client.captureException(
          StateError('x'), null, {'app.screen.name': '/from-the-app'});
      await settle(tester, h);
      expect(attr(h.named(eventException).single, 'app.screen.name'),
          '/from-the-app');
    });

    testWidgets('a dialog, sheet or menu over a screen leaves it the current '
        'screen', (tester) async {
      final h = await startApp(tester, shop());
      _navigator.currentState!.pushNamed('/orders');
      await tester.pumpAndSettle();
      final context = _navigator.currentContext!;
      unawaited(showDialog<void>(
          context: context,
          builder: (_) =>
              const Center(child: CircularProgressIndicator())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      h.client.captureException(StateError('while loading'));
      _navigator.currentState!.pop();
      await tester.pumpAndSettle();
      unawaited(showModalBottomSheet<void>(
          context: context, builder: (_) => const Text('Sort by')));
      await tester.pumpAndSettle();
      expect(h.client.currentScreen, '/orders');
      _navigator.currentState!.pop();
      await settle(tester, h);

      expect(attr(h.named(eventException).single, 'app.screen.name'),
          '/orders');
      final navigations = h.named(eventNavigation).toList();
      final overlays =
          navigations.where((r) => attr(r, 'navigation.overlay') == true);
      expect(overlays, hasLength(4)); // dialog and sheet, opened and closed
      for (final r in overlays) {
        expect(attr(r, 'app.screen.name'), '/orders');
      }
      expect(h.client.currentScreen, '/orders');
    });

    testWidgets('a PageRouteBuilder screen is named after its page',
        (tester) async {
      final h = await startApp(tester, shop());
      _navigator.currentState!.push(PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const CheckoutPage(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ));
      await tester.pumpAndSettle();
      await settle(tester, h);
      expect(h.named(eventNavigation).map((r) => attr(r, 'url.full')),
          contains('/CheckoutPage'));
      expect(h.client.currentScreen, '/CheckoutPage');
    });

    testWidgets('a long press is not a tap', (tester) async {
      var longPresses = 0;
      final h = await startApp(tester, shop(onLongPress: () => longPresses++));
      // Test gestures stamp their events with zero unless told otherwise.
      final gesture = await tester.createGesture();
      await gesture.down(tester.getCenter(find.text('Hold me')),
          timeStamp: const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up(timeStamp: const Duration(milliseconds: 1700));
      await settle(tester, h);
      expect(longPresses, 1);
      expect(h.named(eventClick), isEmpty);

      await tester.tap(find.text('Hold me'));
      await settle(tester, h);
      expect(h.named(eventClick), hasLength(1));
    });
  });

  group('attributes', () {
    test('changing attributes updates the session, once per change',
        () async {
      final h = await startHarness();
      await h.client.flush();
      final before = h.named(eventSessionUpdate).length;

      h.client.setAttributes({'user.id': 'u-42', 'plan': 'pro'});
      h.client.setAttribute('user.id', 'u-42');
      await Future<void>.delayed(Duration.zero);
      h.client.setAttribute('user.id', 'u-42'); // unchanged: no update
      await Future<void>.delayed(Duration.zero);
      await h.client.flush();

      final updates = h.named(eventSessionUpdate).skip(before).toList();
      expect(updates, hasLength(1));
      expect(attr(updates.single, 'user.id'), 'u-42');
      expect(attr(updates.single, 'plan'), 'pro');
      expect(attr(updates.single, 'session.id'), h.client.currentSessionId);

      h.client.removeAttribute('plan');
      await Future<void>.delayed(Duration.zero);
      await h.client.flush();
      expect(h.named(eventSessionUpdate).skip(before), hasLength(2));
    });
  });

  group('lifecycle', () {
    test('an instance id the server assigns is on records from then on',
        () async {
      final assigned = Uint8List.fromList(
          [0x01, 0x95, 0xf2, 0xa0, 0, 0, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x42]);
      final h = await startHarness(
        options: const TracewayOptions(),
        handler: (request) async => request.url.path.endsWith('/opamp')
            ? http.Response.bytes(
                encodeServerToAgent(
                    heartbeatIntervalSeconds: 300, newInstanceUid: assigned),
                200)
            : null,
      );
      await h.client.refreshConfig();
      expect(h.client.getInstanceId(), bytesToUuid(assigned));
      h.client.captureException(StateError('after the new id'));
      await h.client.flush();
      final record = h.named(eventException).single;
      // The exported record is the SDK's, which knows its resource.
      final resource = (record as dynamic).resource.attributes.toMap() as Map;
      expect(resource['service.instance.id'].value, bytesToUuid(assigned));
    });

    test('initialize while a shutdown is still running starts a new client',
        () async {
      final h = await startHarness();
      final stopping = h.client.shutdown();
      expect(identical(h.client.shutdown(), stopping), isTrue);
      final next = TracewayClient.initialize(
          null,
          const TracewayOptions(
            remoteConfig: false,
            persistToDisk: false,
            captureMetrics: false,
            telemetry: TracewayTelemetry(url: 'https://collector.test'),
          ));
      expect(identical(next, h.client), isFalse);
      await stopping;
      expect(identical(TracewayClient.instance, next), isTrue);
      await next.ready;
    });
  });
}
