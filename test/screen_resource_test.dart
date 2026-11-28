import 'dart:io';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/device_info_collector.dart';
import 'package:traceway/traceway.dart';

class _LoopbackHttp extends HttpOverrides {}

// On Android the engine learns the window's metrics a moment after `main`
// started, which is where `Traceway.run` starts the SDK: until then the view
// is 0x0 at a ratio of 1.0 (field-test finding flutter-003). The test window
// starts that way here, and gets its size 50 ms after the start.
void main() {
  test('the resource has the screen the window reports once it has a size',
      () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final view = binding.platformDispatcher.views.first;
    view.physicalSize = Size.zero;
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);

    final collector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => collector.close(force: true));
    final resources = <Map<String, String>>[];
    void keep(Iterable<proto.KeyValue> attributes) => resources
        .add({for (final a in attributes) a.key: a.value.stringValue});
    collector.listen((request) async {
      final body = await gzip.decoder
          .bind(request)
          .fold(<int>[], (List<int> acc, part) => acc..addAll(part));
      if (request.uri.path.endsWith('/logs')) {
        for (final r
            in proto.ExportLogsServiceRequest.fromBuffer(body).resourceLogs) {
          keep(r.resource.attributes);
        }
      } else if (request.uri.path.endsWith('/traces')) {
        for (final r in proto.ExportTraceServiceRequest.fromBuffer(body)
            .resourceSpans) {
          keep(r.resource.attributes);
        }
      }
      await request.response.close();
    });
    await TracewayClient.resetForTest();
    addTearDown(TracewayClient.resetForTest);

    await HttpOverrides.runWithHttpOverrides(() async {
      // The production start, device collection included.
      final client = TracewayClient.initialize(
          options: TracewayOptions(
        telemetry: TracewayTelemetry(url: 'http://127.0.0.1:${collector.port}'),
        captureMetrics: false,
        persistToDisk: false,
        collection: const {
          'signals': {
            'network': {'mode': 'stream'}
          }
        },
      ))!;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      view.physicalSize = const Size(1080, 2400);
      view.devicePixelRatio = 2.625;
      await client.ready;
      client.captureMessage('after the start');
      client.recordNetworkEvent(NetworkEvent(
          method: 'GET',
          url: 'https://example.test',
          statusCode: 200,
          duration: Duration.zero));
      await client.flush();
      await client.shutdown();
    }, _LoopbackHttp());

    expect(resources, isNotEmpty);
    for (final resource in resources) {
      expect(resource['screen.resolution'], '1080x2400');
      expect(resource['screen.density'], 2.625.toStringAsFixed(1));
    }
  });

  test('a window that never gets a size is left out, not reported as 0x0',
      () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final view = binding.platformDispatcher.views.first;
    view.physicalSize = Size.zero;
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
    final waited = Stopwatch()..start();
    await DeviceInfoCollector.screenKnown(
        timeout: const Duration(milliseconds: 100));
    expect(waited.elapsedMilliseconds, greaterThanOrEqualTo(100));
    final info = DeviceInfoCollector.collectSync();
    expect(info.keys, isNot(contains('screen.resolution')));
    expect(info.keys, isNot(contains('screen.density')));
    expect(info['os.name'], Platform.operatingSystem);

    view.physicalSize = const Size(1600, 2560);
    view.devicePixelRatio = 2.0;
    await DeviceInfoCollector.screenKnown();
    expect(DeviceInfoCollector.collectSync()['screen.resolution'], '1600x2560');
  });
}
