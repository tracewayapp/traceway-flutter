import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart'
    show ReadableLogRecord;

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/core/control_state.dart';
import 'package:traceway/src/core/ids.dart';
import 'package:traceway/src/core/merge.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/events/traceway_event.dart';
import 'package:traceway/src/metrics/aggregator.dart';
import 'package:traceway/src/metrics/app_vitals.dart';
import 'package:traceway/src/metrics/histogram.dart';
import 'package:traceway/src/metrics/metrics_recorder.dart';
import 'package:traceway/src/metrics/otlp.dart';
import 'package:traceway/src/metrics/route.dart';
import 'package:traceway/src/persistence/state_store.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

import 'support.dart';

Json doc(Map<String, Object?> settings) =>
    parseSettingsDocument(jsonEncode(settings));

/// What the server would chart from one or more payloads: histogram counts
/// and counter sums by `name|dim=value,...`.
class Decoded {
  Decoded(this.requests);
  final List<proto.ExportMetricsServiceRequest> requests;

  static String _key(String name, List<proto.KeyValue> attrs) {
    final dims = [for (final a in attrs) '${a.key}=${_value(a.value)}']..sort();
    return dims.isEmpty ? name : '$name|${dims.join(',')}';
  }

  static Object? _value(proto.AnyValue v) {
    if (v.hasStringValue()) return v.stringValue;
    if (v.hasBoolValue()) return v.boolValue;
    if (v.hasIntValue()) return v.intValue.toInt();
    if (v.hasDoubleValue()) return v.doubleValue;
    return null;
  }

  Map<String, Object?> resource([int index = 0]) => {
        for (final a
            in requests[index].resourceMetrics.first.resource.attributes)
          a.key: _value(a.value),
      };

  Iterable<proto.Metric> get _metrics => [
        for (final r in requests)
          for (final rm in r.resourceMetrics)
            for (final sm in rm.scopeMetrics) ...sm.metrics,
      ];

  Map<String, double> get sums {
    final out = <String, double>{};
    for (final m in _metrics.where((m) => m.hasSum())) {
      expect(m.sum.aggregationTemporality,
          proto.AggregationTemporality.AGGREGATION_TEMPORALITY_DELTA);
      expect(m.sum.isMonotonic, isTrue);
      for (final p in m.sum.dataPoints) {
        final key = _key(m.name, p.attributes);
        out[key] = (out[key] ?? 0) + p.asDouble;
      }
    }
    return out;
  }

  Map<String, proto.ExponentialHistogramDataPoint> get histograms {
    final out = <String, proto.ExponentialHistogramDataPoint>{};
    for (final m in _metrics.where((m) => m.hasExponentialHistogram())) {
      expect(m.exponentialHistogram.aggregationTemporality,
          proto.AggregationTemporality.AGGREGATION_TEMPORALITY_DELTA);
      for (final p in m.exponentialHistogram.dataPoints) {
        out[_key(m.name, p.attributes)] = p;
      }
    }
    return out;
  }
}

class Recorded {
  Recorded(this.recorder, this.bodies, this.store);
  final MetricsRecorder recorder;
  final List<List<int>> bodies;
  final StateStore store;

  Decoded get decoded => Decoded([
        for (final b in bodies) proto.ExportMetricsServiceRequest.fromBuffer(b),
      ]);
}

/// A session id whose hash falls under [rate], or above it.
String sessionFor(double rate, {required bool sampled}) {
  for (var i = 0;; i++) {
    final id = 'session-$i';
    if ((unitHash(id) < rate) == sampled) return id;
  }
}

Recorded recorder({
  Map<String, Object?>? overlay,
  String? session = 'session-a',
  bool persistent = false,
  List<int> statuses = const [],
  int Function()? now,
}) {
  final control = ControlState(defaultSettings(), ceilingsFrom());
  if (overlay != null) control.applyRemote(doc(overlay));
  final bodies = <List<int>>[];
  final queue = List.of(statuses);
  final store = StateStore(persistent ? Directory.systemTemp : null);
  final r = MetricsRecorder(
    control: control,
    sessionId: () => session,
    installationId: () => 'install-1',
    resource: () => {
      'service.name': 'shop',
      'service.version': '1.2.3',
      'service.instance.id': 'must-not-be-sent',
      'os.name': 'android',
      'os.major': '14',
      'device.form_factor': 'phone',
      'device.model': 'must-not-be-sent',
    },
    send: (body) async {
      bodies.add(body);
      return queue.isEmpty ? 200 : queue.removeAt(0);
    },
    store: () => store,
    scopeName: 'traceway-flutter',
    scopeVersion: 'test',
    now: now,
  );
  return Recorded(r, bodies, store);
}

FrameTiming frame({int buildUs = 1000, int rasterUs = 1000, int? totalUs}) {
  const start = 1000000;
  final total = totalUs ?? buildUs + rasterUs;
  return FrameTiming(
    vsyncStart: start,
    buildStart: start,
    buildFinish: start + buildUs,
    rasterStart: start + total - rasterUs,
    rasterFinish: start + total,
    rasterFinishWallTime: start + total,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('histogram', () {
    test('buckets match the server at every boundary', () {
      // Go: int32(math.Ceil(math.Log2(v)*8)) - 1
      final expected = {
        1.0: -1, 2.0: 7, 8.0: 23, 16.0: 31, 1024.0: 79, 0.5: -9, //
        3.0: 12, 100.0: 53, 16.7: 32, 2500.0: 90, 1e9: 239,
      };
      expected.forEach((value, index) {
        expect(bucketIndex(value), index, reason: '$value');
      });
    });

    test('records count, sum, min, max and zeros; refuses what it cannot hold',
        () {
      final h = Histogram();
      for (final v in [0.0, 1.5, 100.0, 100.0]) {
        expect(h.record(v), isTrue);
      }
      expect(h.record(-1), isFalse);
      expect(h.record(double.nan), isFalse);
      expect(h.record(double.infinity), isFalse);
      expect(h.count, 4);
      expect(h.sum, 201.5);
      expect(h.min, 0);
      expect(h.max, 100);
      expect(h.zeroCount, 1);
      expect(h.buckets, {bucketIndex(1.5): 1, bucketIndex(100): 2});
    });
  });

  group('aggregator', () {
    test('cells per name and dimensions; drain hands them over once', () {
      final a = MetricAggregator();
      a.observe('app.screen.ttid', 100, dims: {'screen': '/a'}, unit: 'ms');
      a.observe('app.screen.ttid', 300, dims: {'screen': '/a'}, unit: 'ms');
      a.observe('app.screen.ttid', 50, dims: {'screen': '/b'}, unit: 'ms');
      a.count('app.session');
      a.ratio('app.frames.slow', 3, 10);
      a.ratio('app.frames.slow', 5, 2); // part above total is clamped
      final batch = a.drain()!;
      expect(batch.histograms.map((h) => h.histogram.count), [2, 1]);
      final sums = {for (final s in batch.sums) s.name: s.value};
      expect(sums, {
        'app.session': 1,
        'app.frames.slow.total': 12,
        'app.frames.slow': 5,
      });
      expect(a.drain(), isNull);
    });

    test('past the cell limit the screen folds to other, then cells drop', () {
      final a = MetricAggregator(maxCells: 2);
      a.count('a');
      a.count('b');
      a.observe('app.screen.ttid', 1, dims: {'screen': '/x'});
      a.observe('app.screen.ttid', 2, dims: {'screen': '/y'});
      a.count('c');
      final batch = a.drain()!;
      expect(batch.histograms.single.dims, {'screen': 'other'});
      expect(batch.histograms.single.histogram.count, 2);
      expect(a.dropped, 1);
    });

    test('keeps the three highest exemplars', () {
      final a = MetricAggregator();
      for (final v in [5.0, 1.0, 9.0, 3.0, 7.0]) {
        a.observe('app.hang.duration', v, exemplarSession: 's$v');
      }
      final exemplars = a.drain()!.histograms.single.exemplars;
      expect(exemplars.map((e) => e.value).toSet(), {5.0, 9.0, 7.0});
    });
  });

  test('OTLP encoding: delta exponential histograms and monotonic sums', () {
    final a = MetricAggregator(now: () => 1700000000000);
    a.observe('app.start.duration', 1200,
        dims: {'start_type': 'cold'}, unit: 'ms', exemplarSession: 'sess');
    a.observe('app.start.duration', 1300,
        dims: {'start_type': 'cold'}, unit: 'ms');
    a.count('app.session', 2);
    final request = encodeMetrics(a.drain()!, {'service.name': 'shop', 'n': 1},
        scopeName: 'traceway-flutter', scopeVersion: '9');
    final rm = request.resourceMetrics.single;
    expect(rm.scopeMetrics.single.scope.name, 'traceway-flutter');
    final histogram = rm.scopeMetrics.single.metrics
        .firstWhere((m) => m.name == 'app.start.duration');
    expect(histogram.unit, 'ms');
    final point = histogram.exponentialHistogram.dataPoints.single;
    expect(point.scale, histogramScale);
    expect(point.count.toInt(), 2);
    expect(point.sum, 2500);
    expect(point.min, 1200);
    expect(point.max, 1300);
    expect(point.positive.offset, bucketIndex(1200));
    expect(
        point.positive.bucketCounts.fold<int>(0, (n, c) => n + c.toInt()), 2);
    expect(point.exemplars.single.filteredAttributes.single.value.stringValue,
        'sess');
    final sum = rm.scopeMetrics.single.metrics.firstWhere((m) => m.hasSum());
    expect(sum.sum.dataPoints.single.asDouble, 2);
  });

  test('route paths normalize like the server', () {
    // The table of backend/app/clientmetrics/route_test.go.
    const table = {
      '/': '/',
      '': '/',
      '/orders/8841': '/orders/:id',
      '/orders/8841/': '/orders/:id',
      '/orders/8841?x=1#y': '/orders/:id',
      '/u/3f2b8c1e-9a4d-4c7e-8b1a-2d3e4f5a6b7c/edit': '/u/:id/edit',
      '/commit/9fceb02d0ae598e9': '/commit/:id',
      '/reset/dGhpcyBpcyBhIHRva2VuIHZhbHVl0': '/reset/:id',
      '/products/blue-suede-shoes': '/products/blue-suede-shoes',
      '/deadbeef': '/deadbeef',
      '/a/b/c/d/e/f/g/h': '/a/b/c/d/e/f/*',
      '/search/hello%20world': '/search/:id',
      '/endpoints/POST%20%2Ftasks%2F%7BtaskId%7D/9fceb02d0ae598e9': '/endpoints/:id/:id',
      '/caf%C3%A9/menu': '/caf%C3%A9/menu',
      '/:lang?/about': '/:lang?/about',
      '/:locale(en|fr)?/products/:slug': '/:locale(en|fr)?/products/:slug',
      '/users/:id?': '/users/:id',
      '/orders/8841?/next': '/orders/:id',
      '/products/:slug()': '/products/:slug()',
      '/docs/:slug(.*)*': '/docs/:slug(.*)*',
      '/docs/:slug*': '/docs/:slug*',
      '/posts/\$postId': '/posts/\$postId',
      '/posts/[id]': '/posts/[id]',
      '/CheckoutPage': '/CheckoutPage',
    };
    table.forEach((input, want) => expect(normalizePath(input), want, reason: input));
    final long = normalizePath('/${'segment-that-is-long/' * 8}');
    expect(long.length, lessThanOrEqualTo(64));
    expect(long, endsWith('/*'));
  });

  group('settings', () {
    test('metrics settings merge, clamp and obey the kill switch and limits',
        () {
      var control = ControlState(defaultSettings(), ceilingsFrom());
      expect(control.metrics!.sampleRate, 1);
      expect(control.metrics!.flushSeconds, 300);
      control.applyRemote(doc({
        'metrics': {'sampleRate': 0.25, 'flushSeconds': 5},
      }));
      expect(control.metrics!.sampleRate, 0.25);
      expect(control.metrics!.flushSeconds, minMetricsFlushSeconds);
      control.applyRemote(doc({
        'metrics': {'enabled': false},
      }));
      expect(control.metrics, isNull);
      control.applyRemote(doc({'enabled': false}));
      expect(control.metrics, isNull);
      control.applyRemote(doc({
        'limits': {'metrics': 'off'},
        'metrics': {'enabled': true},
      }));
      expect(control.metrics, isNull);

      control =
          ControlState(defaultSettings(), ceilingsFrom(captureMetrics: false));
      control.applyRemote(doc({
        'metrics': {'enabled': true},
      }));
      expect(control.metrics, isNull);
    });
  });

  group('MetricsRecorder', () {
    test('a payload carries the device dimensions and nothing that identifies',
        () async {
      final r = recorder();
      r.recorder.setDimension('plan', 'pro');
      r.recorder.setDimension('arm', 'b');
      r.recorder.setDimension('third', 'ignored');
      r.recorder.sessionStarted('session-a');
      await r.recorder.flush();
      final resource = r.decoded.resource();
      expect(resource['traceway.metrics'], 'aggregated');
      expect(resource['traceway.sample_rate'], 1.0);
      expect(resource['traceway.batch_id'], isA<String>());
      expect(resource['traceway.sent_at'], isA<int>());
      expect(resource['service.name'], 'shop');
      expect(resource['os.major'], '14');
      expect(resource['device.form_factor'], 'phone');
      expect(resource['custom.plan'], 'pro');
      expect(resource['custom.arm'], 'b');
      expect(resource.containsKey('custom.third'), isFalse);
      expect(resource.containsKey('service.instance.id'), isFalse);
      expect(resource.containsKey('device.model'), isFalse);
      expect(r.decoded.sums, {'app.session': 1});
    });

    test('a session is counted once, and not again when it resumes', () async {
      final r = recorder();
      r.recorder.sessionStarted('session-a');
      r.recorder.sessionStarted('session-a');
      r.recorder.sessionStarted('session-b', resumed: true);
      await r.recorder.flush();
      expect(r.decoded.sums, {'app.session': 1});
    });

    test(
        'a session outside the sample records nothing; one inside states its rate',
        () async {
      final out = recorder(overlay: {
        'metrics': {'sampleRate': 0.5}
      }, session: sessionFor(0.5, sampled: false));
      out.recorder.sessionStarted(sessionFor(0.5, sampled: false));
      out.recorder.request('https://api.shop.test/x', 120, failed: false);
      await out.recorder.flush();
      expect(out.bodies, isEmpty);

      final inside = sessionFor(0.5, sampled: true);
      final r = recorder(overlay: {
        'metrics': {'sampleRate': 0.5}
      }, session: inside);
      r.recorder.sessionStarted(inside);
      await r.recorder.flush();
      expect(r.decoded.resource()['traceway.sample_rate'], 0.5);
    });

    test('requests by host, with failures as a ratio and at most 20 hosts',
        () async {
      final r = recorder();
      r.recorder.request('https://api.shop.test/a', 100,
          failed: false, responseBytes: 2048);
      r.recorder.request('https://api.shop.test:8443/b', 300, failed: true);
      for (var i = 0; i < 25; i++) {
        r.recorder.request('https://h$i.test/', 10, failed: false);
      }
      await r.recorder.flush();
      final sums = r.decoded.sums;
      expect(sums['app.request.failed.total|host=api.shop.test'], 1);
      expect(sums['app.request.failed|host=api.shop.test'], isNull,
          reason: 'zero counts are not sent');
      expect(sums['app.request.failed|host=api.shop.test:8443'], 1);
      expect(sums['app.request.failed.total|host=other'], 7);
      final histograms = r.decoded.histograms;
      expect(
          histograms['app.request.duration|host=api.shop.test']!.count.toInt(),
          1);
      expect(histograms['app.request.bytes|host=api.shop.test']!.sum, 2048);
    });

    test('users and affected users once a day, only with lasting storage',
        () async {
      var day = 20000 * 86400000;
      final r = recorder(persistent: true, now: () => day);
      r.store.set('metricsUser', null);
      r.recorder.start();
      r.recorder.crash();
      r.recorder.crash();
      r.recorder.hang(2500, '/cart');
      await r.recorder.flush();
      r.recorder.stop();
      expect(r.decoded.sums, {
        'app.user': 1,
        'app.user.affected|issue=crash': 1,
        'app.user.affected|issue=hang': 1,
        'app.crash': 2,
        'app.hang|screen=/cart': 1,
      });
      expect(
          r.decoded.histograms['app.hang.duration|screen=/cart']!.exemplars
              .single.filteredAttributes.single.value.stringValue,
          'session-a');

      r.bodies.clear();
      r.recorder.crash();
      await r.recorder.flush();
      expect(r.decoded.sums, {'app.crash': 1});

      day += 86400000;
      r.bodies.clear();
      r.recorder.crash();
      await r.recorder.flush();
      expect(r.decoded.sums,
          {'app.user': 1, 'app.user.affected|issue=crash': 1, 'app.crash': 1});
      r.store.set('metricsUser', null);

      final memory = recorder();
      memory.recorder.crash();
      await memory.recorder.flush();
      expect(memory.decoded.sums, {'app.crash': 1});
    });

    test('a failed upload is resent once, restamped and marked as a retry',
        () async {
      var now = 1000000;
      final r = recorder(statuses: [503, 200, 200], now: () => now);
      r.recorder.sessionStarted('session-a');
      await r.recorder.flush();
      expect(r.bodies, hasLength(1));
      now += 60000;
      r.recorder.crash();
      await r.recorder.flush();
      expect(r.bodies, hasLength(3), reason: 'the new payload, then the retry');
      final retry = r.decoded.resource(2);
      expect(retry['traceway.retry'], isTrue);
      expect(retry['traceway.sent_at'], now);
      expect(retry['traceway.batch_id'],
          r.decoded.resource(0)['traceway.batch_id']);
      await r.recorder.flush();
      expect(r.bodies, hasLength(3), reason: 'never a third attempt');
    });

    test('a payload sent as the app leaves is stored until it is answered',
        () async {
      final r = recorder(statuses: [0, 200, 200]);
      r.recorder.sessionStarted('session-a');
      await r.recorder.flush(final_: true);
      expect(r.store.get('metricsPending'), hasLength(1));
      r.recorder.crash();
      await r.recorder.flush();
      expect(r.decoded.resource(2)['traceway.retry'], isTrue);
      expect(r.store.get('metricsPending'), isNull);
    });

    test('a sample rate change uploads what was taken under the old rate',
        () async {
      final control = ControlState(defaultSettings(), ceilingsFrom());
      final bodies = <List<int>>[];
      final r = MetricsRecorder(
        control: control,
        sessionId: () => 'session-a',
        installationId: () => 'i',
        resource: () => const {},
        send: (b) async {
          bodies.add(b);
          return 200;
        },
        store: () => StateStore(null),
        scopeName: 's',
        scopeVersion: 'v',
      );
      r.sessionStarted('session-a');
      control.applyRemote(doc({
        'metrics': {'sampleRate': 0.99}
      }));
      r.configure();
      await r.flush();
      expect(bodies, hasLength(1));
      expect(
          Decoded([proto.ExportMetricsServiceRequest.fromBuffer(bodies.single)])
              .resource()['traceway.sample_rate'],
          1.0);

      control.applyRemote(doc({
        'metrics': {'enabled': false}
      }));
      r.crash();
      r.configure();
      await r.flush();
      expect(bodies, hasLength(1), reason: 'switched off sends nothing more');
    });

    test('a payload over the body limit is split, nothing lost', () async {
      final r = recorder();
      // Every bucket from 2^-12 to 2^50: about 500 buckets a cell.
      for (var i = 0; i < 150; i++) {
        for (var k = -96; k < 400; k++) {
          r.recorder.aggregator
              .observe('custom_$i', math.pow(2, (k + 0.5) / 8).toDouble());
        }
      }
      await r.recorder.flush();
      expect(r.bodies.length, greaterThan(1));
      expect(r.bodies.every((b) => b.length <= 60 * 1024), isTrue);
      expect(r.decoded.histograms, hasLength(150));
    });

    test('what is observed before the start waits for the first session',
        () async {
      String? session;
      final bodies = <List<int>>[];
      final r = MetricsRecorder(
        control: ControlState(defaultSettings(), ceilingsFrom()),
        sessionId: () => session,
        installationId: () => 'i',
        resource: () => const {},
        send: (b) async {
          bodies.add(b);
          return 200;
        },
        store: () => StateStore(null),
        scopeName: 's',
        scopeVersion: 'v',
        deferUntilStart: true,
      );
      // The first frame and the first screen come before the SDK started.
      r.appStart(850, 'cold', slow: false);
      r.screenDisplayed('/', 40);
      r.crash();
      expect(r.aggregator.size, 0);
      session = 'session-a';
      r.sessionStarted('session-a');
      r.start();
      await r.flush();
      r.stop();
      final decoded = Decoded(
          [proto.ExportMetricsServiceRequest.fromBuffer(bodies.single)]);
      expect(decoded.sums, {'app.session': 1, 'app.crash': 1});
      expect(decoded.histograms.keys.toSet(),
          {'app.start.duration|start_type=cold', 'app.screen.ttid|screen=/'});
    });

    test('custom metrics keep to their names and two dimensions', () async {
      final r = recorder();
      r.recorder
          .metric('checkout.duration', 420, {'plan': 'pro', 'b': 1, 'c': 2});
      r.recorder.metric('app.start.duration', 1);
      r.recorder.metric('Bad Name', 1);
      r.recorder.count('cart.add', 2);
      await r.recorder.flush();
      expect(r.decoded.histograms.keys, ['checkout.duration|b=1,c=2']);
      expect(r.decoded.sums, {'cart.add': 2});
    });
  });

  test('a cold start counts while the app is on screen, focused or not', () {
    for (final state in [
      null,
      AppLifecycleState.resumed,
      // An unfocused desktop window, iOS before it becomes active.
      AppLifecycleState.inactive,
    ]) {
      expect(AppVitals.coldStartCounts(false, state), isTrue, reason: '$state');
    }
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(AppVitals.coldStartCounts(false, state), isFalse,
          reason: '$state');
    }
    // Left before the first frame, then back.
    expect(AppVitals.coldStartCounts(true, AppLifecycleState.resumed), isFalse);
  });

  group('AppVitals', () {
    late Recorded r;
    late int nowUs;
    late AppVitals vitals;
    String? screen;

    setUp(() {
      r = recorder();
      nowUs = 1000000000;
      screen = '/cart';
      vitals = AppVitals(r.recorder,
          currentScreen: () => screen,
          nowUs: () => nowUs,
          hangThresholdMs: 150,
          watchdogIntervalMs: 20);
    });

    tearDown(() => vitals.stop());

    testWidgets('time to initial and full display of a pushed screen',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      vitals.navigated(
          '/users/:id', 'push', DateTime.fromMicrosecondsSinceEpoch(nowUs));
      nowUs += 250000;
      await tester.pump();
      nowUs += 750000;
      vitals.fullyDisplayed();
      vitals.fullyDisplayed();
      // A return to a screen already built is not a display.
      vitals.navigated(
          '/cart', 'pop', DateTime.fromMicrosecondsSinceEpoch(nowUs));
      await tester.pump();
      await r.recorder.flush();
      final h = r.decoded.histograms;
      expect(h.keys.toSet(), {
        'app.screen.ttid|screen=/users/:id',
        'app.screen.ttfd|screen=/users/:id'
      });
      expect(h['app.screen.ttid|screen=/users/:id']!.sum, 250);
      expect(h['app.screen.ttfd|screen=/users/:id']!.sum, 1000);
    });

    testWidgets(
        'a screen pushed from a post-frame callback is displayed by the next '
        'frame, not at once', (tester) async {
      await tester.pumpWidget(const SizedBox());
      // A splash screen replacing itself once it is drawn.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        vitals.navigated(
            '/home', 'replace', DateTime.fromMicrosecondsSinceEpoch(nowUs));
        nowUs += 120000;
      });
      SchedulerBinding.instance.scheduleFrame();
      await tester.pump();
      await tester.pump();
      await r.recorder.flush();
      expect(r.decoded.histograms['app.screen.ttid|screen=/home']!.sum, 120);
    });

    testWidgets('a route the observer waited for is displayed when reported',
        (tester) async {
      await tester.pumpWidget(const SizedBox());
      vitals.navigated('/CheckoutPage', 'push',
          DateTime.fromMicrosecondsSinceEpoch(nowUs - 40000),
          displayed: true);
      await r.recorder.flush();
      expect(r.decoded.histograms['app.screen.ttid|screen=/CheckoutPage']!.sum,
          40);
    });

    testWidgets('slow and frozen frames by screen', (tester) async {
      vitals.onTimings([
        frame(),
        frame(buildUs: 30000),
        frame(rasterUs: 25000),
        frame(totalUs: 800000, buildUs: 790000),
      ]);
      screen = null;
      vitals.onTimings([frame()]);
      await r.recorder.flush();
      expect(r.decoded.sums, {
        'app.frames.slow.total|screen=/cart': 4,
        'app.frames.slow|screen=/cart': 2,
        'app.frames.frozen.total|screen=/cart': 4,
        'app.frames.frozen|screen=/cart': 1,
        'app.frames.slow.total': 1,
        'app.frames.frozen.total': 1,
      });
    });

    test('a blocked UI isolate is a hang, only in the foreground', () async {
      vitals.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final until = DateTime.now().add(const Duration(milliseconds: 300));
      while (DateTime.now().isBefore(until)) {}
      await Future<void>.delayed(const Duration(milliseconds: 60));
      vitals.lifecycleChanged(AppLifecycleState.inactive);
      vitals.lifecycleChanged(AppLifecycleState.paused);
      await r.recorder.flush();
      expect(r.decoded.sums['app.hang|screen=/cart'], 1);
      final duration = r.decoded.histograms['app.hang.duration|screen=/cart']!;
      expect(duration.sum, inInclusiveRange(150, 400));

      // In the background the isolate may be suspended: no watchdog runs.
      r.bodies.clear();
      final later = DateTime.now().add(const Duration(milliseconds: 300));
      while (DateTime.now().isBefore(later)) {}
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await r.recorder.flush();
      expect(r.bodies, isEmpty);
    });
  });

  group('client', () {
    test('requests, sessions and unhandled errors reach the metrics endpoint',
        () async {
      final dir = await Directory.systemTemp.createTemp('traceway_metrics');
      final h = await startHarness(stateDirectory: dir);
      final client = h.client;
      client.recordNetworkEvent(NetworkEvent(
        method: 'GET',
        url: 'https://api.shop.test/orders/1',
        statusCode: 200,
        duration: const Duration(milliseconds: 180),
      ));
      client.recordNetworkEvent(NetworkEvent(
        method: 'GET',
        url: 'https://api.shop.test/orders/2',
        statusCode: 502,
        duration: const Duration(milliseconds: 20),
      ));
      client.captureUnhandledException(StateError('boom'));
      client.recordMetric('checkout.duration', 1200);
      await client.flush();
      final posts = h.requestsTo('/api/otel/v1/metrics');
      expect(posts, hasLength(1));
      expect(posts.single.headers['content-type'], 'application/x-protobuf');
      expect(posts.single.headers['authorization'], 'Bearer test-token');
      final decoded = Decoded([
        proto.ExportMetricsServiceRequest.fromBuffer(otlpBody(posts.single))
      ]);
      expect(decoded.sums, {
        'app.session': 1,
        'app.user': 1,
        'app.user.affected|issue=crash': 1,
        'app.user.affected|issue=failed_request': 1,
        'app.crash': 1,
        'app.request.failed.total|host=api.shop.test': 2,
        'app.request.failed|host=api.shop.test': 1,
      });
      expect(decoded.histograms.keys.toSet(), {
        'app.request.duration|host=api.shop.test',
        'checkout.duration',
      });
      expect(decoded.resource()['os.name'], 'test-os');
      // The exception itself is reported as always.
      expect(h.eventNames, contains('exception'));
      await TracewayClient.resetForTest();
      await dir.delete(recursive: true);
    });

    test('captureMetrics false sends no metrics and claims no aggregates',
        () async {
      final h = await startHarness(
          options: const TracewayOptions(
              remoteConfig: false, captureMetrics: false));
      h.client.recordNetworkEvent(NetworkEvent(
        method: 'GET',
        url: 'https://api.shop.test/',
        statusCode: 200,
        duration: const Duration(milliseconds: 5),
      ));
      h.client.captureUnhandledException(StateError('boom'));
      await h.client.flush();
      expect(h.requestsTo('/api/otel/v1/metrics'), isEmpty);
      final resource = (h.logs.records.first as ReadableLogRecord)
          .resource
          ?.attributes
          .toMap();
      expect(resource?.containsKey('traceway.metrics'), isFalse);
      await TracewayClient.resetForTest();
    });

    test(
        'a session that ended while the app was not running reports its peak memory',
        () async {
      final dir = await Directory.systemTemp.createTemp('traceway_memory');
      final initial = await startHarness(stateDirectory: dir);
      await initial.client.shutdown();
      final saved = File('${dir.path}/state.json');
      final previous =
          jsonDecode(await saved.readAsString()) as Map<String, dynamic>;
      final memoryKey =
          previous.keys.singleWhere((key) => key.startsWith('metricsMemory:'));
      await saved.writeAsString(jsonEncode({
        'destination': previous['destination'],
        memoryKey: {'s': 'killed-session', 'b': 123456789},
      }));
      final h = await startHarness(stateDirectory: dir);
      await h.client.flush();
      final decoded = Decoded([
        for (final post in h.requestsTo('/api/otel/v1/metrics'))
          proto.ExportMetricsServiceRequest.fromBuffer(otlpBody(post)),
      ]);
      final memory = decoded.histograms['app.memory.peak']!;
      expect(memory.count.toInt(), 1);
      expect(memory.sum, 123456789);

      // Going to the background keeps this session's peak for later.
      h.client.didChangeAppLifecycleState(AppLifecycleState.paused);
      await h.client.flush();
      final state =
          jsonDecode(await File('${dir.path}/state.json').readAsString());
      expect(state[memoryKey]['s'], h.client.currentSessionId);
      expect(state[memoryKey]['b'], greaterThan(0));
      await TracewayClient.resetForTest();
      await dir.delete(recursive: true);
    });

    test('a rule can switch metrics off', () async {
      final h = await startHarness(
          options: const TracewayOptions(remoteConfig: false, collection: {
        'metrics': {'enabled': false}
      }));
      h.client.captureUnhandledException(StateError('boom'));
      await h.client.flush();
      expect(h.requestsTo('/api/otel/v1/metrics'), isEmpty);
      await TracewayClient.resetForTest();
    });
  });

  test('every metric the SDK sends is one the server knows', () {
    // backend/app/clientmetrics/catalog.go
    const catalog = {
      'app.start.duration', 'app.screen.ttid', 'app.screen.ttfd', //
      'app.frames.slow', 'app.frames.slow.total', 'app.frames.frozen',
      'app.frames.frozen.total', 'app.hang', 'app.hang.duration', 'app.crash',
      'app.session', 'app.user', 'app.user.affected', 'app.memory.peak',
      'app.request.duration', 'app.request.bytes', 'app.request.failed',
      'app.request.failed.total',
    };
    final names = {
      metricAppStart,
      metricScreenTtid,
      metricScreenTtfd,
      metricFramesSlow,
      '$metricFramesSlow.total',
      metricFramesFrozen,
      '$metricFramesFrozen.total',
      metricHang,
      metricHangDuration,
      metricCrash,
      metricSession,
      metricUser,
      metricUserAffected,
      metricMemoryPeak,
      metricRequestDuration,
      metricRequestBytes,
      metricRequestFailed,
      '$metricRequestFailed.total',
    };
    expect(catalog.containsAll(names), isTrue);
  });
}
