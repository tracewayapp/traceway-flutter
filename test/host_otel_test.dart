import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/traceway.dart';

class _LoopbackHttp extends HttpOverrides {}

void main() {
  test(
      'Traceway uses its installation resource and leaves host OTel running across restarts',
      () async {
    final collector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => collector.close(force: true));
    final logs = <proto.ResourceLogs>[];
    final spans = <proto.ResourceSpans>[];
    collector.listen((request) async {
      final body = await gzip.decoder
          .bind(request)
          .fold(<int>[], (List<int> acc, part) => acc..addAll(part));
      if (request.uri.path.endsWith('/logs')) {
        logs.addAll(
            proto.ExportLogsServiceRequest.fromBuffer(body).resourceLogs);
      } else if (request.uri.path.endsWith('/traces')) {
        spans.addAll(
            proto.ExportTraceServiceRequest.fromBuffer(body).resourceSpans);
      }
      await request.response.close();
    });
    await TracewayClient.resetForTest();
    addTearDown(TracewayClient.resetForTest);
    final hostSpans = InMemorySpanExporter();
    final hostLogs = InMemoryLogExporter();
    await OTel.initialize(
        serviceName: 'host-service',
        enableMetrics: false,
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(hostSpans),
        logRecordProcessor: SimpleLogRecordProcessor(hostLogs));
    final tracer = OTel.tracerProvider().getTracer('host');
    await HttpOverrides.runWithHttpOverrides(() async {
      for (var run = 0; run < 2; run++) {
        final client = TracewayClient.initialize(
            null,
            TracewayOptions(
              telemetry:
                  TracewayTelemetry(url: 'http://127.0.0.1:${collector.port}'),
              captureMetrics: false,
              persistToDisk: false,
              serviceName: 'flutter-app',
              collection: const {
                'signals': {
                  'network': {'mode': 'stream'}
                }
              },
            ));
        await client.ready;
        client.captureMessage('from Traceway');
        client.recordNetworkEvent(NetworkEvent(
            method: 'GET',
            url: 'https://example.test',
            statusCode: 200,
            duration: Duration.zero));
        tracer.startSpan('host during', root: true).end();
        await client.shutdown();
        tracer.startSpan('host after', root: true).end();
        for (final resource in [logs.single.resource, spans.single.resource]) {
          final fields = {
            for (final a in resource.attributes) a.key: a.value.stringValue
          };
          expect(fields['service.instance.id'], client.getInstanceId());
          expect(fields['service.name'], 'flutter-app');
        }
        expect(logs.single.scopeLogs.single.scope.name, 'traceway-flutter');
        expect(spans.single.scopeSpans.single.spans.single.name, 'GET');
        logs.clear();
        spans.clear();
      }
    }, _LoopbackHttp());
    expect(hostLogs.records, isEmpty);
    expect(hostSpans.spans, hasLength(4));
    for (final span in hostSpans.spans) {
      expect(span.attributes.toMap(),
          isNot(contains('traceway.collection.source')));
    }
  });
}
