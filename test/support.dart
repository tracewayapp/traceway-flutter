import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/opamp/messages.dart';
import 'package:traceway/src/replay/replay_source.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';

const connectionString = 'test-token@https://traceway.test/api/report';

class Harness {
  Harness(this.client, this.logs, this.spans, this.requests);

  final TracewayClient client;
  final InMemoryLogExporter logs;
  final InMemorySpanExporter spans;
  final List<http.Request> requests;

  List<String?> get eventNames => logs.records.map((r) => r.eventName).toList();

  Iterable<LogRecord> named(String? eventName) =>
      logs.records.where((r) => r.eventName == eventName);

  List<http.Request> requestsTo(String pathSuffix) =>
      requests.where((r) => r.url.path.endsWith(pathSuffix)).toList();

  /// The decoded `{segments: [...]}` bodies posted to `/api/recordings`.
  List<Map<String, dynamic>> get recordingBodies => [
        for (final request in requestsTo('/api/recordings'))
          jsonDecode(utf8.decode(gzip.decode(request.bodyBytes)))
              as Map<String, dynamic>,
      ];
}

/// The OTLP body of [request], gunzipped when it was sent compressed.
List<int> otlpBody(http.Request request) =>
    request.headers['Content-Encoding'] == 'gzip'
        ? gzip.decode(request.bodyBytes)
        : request.bodyBytes;

Object? attr(LogRecord record, String key) =>
    record.attributes?.toMap()[key]?.value;

typedef Handler = Future<http.Response?> Function(http.Request request);

/// A remote-config answer carrying [settings] under the `traceway` key.
http.Response opampConfig(Map<String, dynamic> settings, List<int> hash) =>
    http.Response.bytes(
      encodeServerToAgent(
        heartbeatIntervalSeconds: 300,
        remoteConfig: RemoteConfig(
          configMap: {
            'traceway': AgentConfigObject(
              body: utf8.encode(jsonEncode(settings)),
              contentType: 'application/json',
            ),
          },
          configHash: Uint8List.fromList(hash),
        ),
      ),
      200,
    );

Future<Harness> startHarness({
  TracewayOptions options = const TracewayOptions(remoteConfig: false),
  Handler? handler,
  Directory? stateDirectory,
  double Function()? random,
  int? collectionHealthDelayMs,
}) async {
  final logs = InMemoryLogExporter();
  final spans = InMemorySpanExporter();
  final requests = <http.Request>[];
  final mock = MockClient((request) async {
    requests.add(request);
    final custom = handler == null ? null : await handler(request);
    if (custom != null) return custom;
    if (request.url.path.endsWith('/opamp')) {
      return http.Response.bytes(
          encodeServerToAgent(heartbeatIntervalSeconds: 300), 200);
    }
    return http.Response('{}', 200);
  });
  final client = await TracewayClient.initializeForTest(
    connectionString,
    options,
    overrides: TracewayTestOverrides(
      logExporter: logs,
      spanExporter: spans,
      httpClient: mock,
      stateDirectory: stateDirectory,
      deviceAttributes: const {'os.name': 'test-os'},
      random: random,
      collectionHealthDelayMs: collectionHealthDelayMs,
    ),
  );
  return Harness(client, logs, spans, requests);
}

class FakeReplaySource implements ReplaySource {
  bool running = false;
  int clears = 0;
  final List<({String clipId, DateTime? since, DateTime? until})> captures = [];

  /// No frames at all: every clip comes back empty.
  bool empty = false;

  @override
  bool get isRunning => running;

  @override
  void start() => running = true;

  @override
  void stop() => running = false;

  @override
  void clearBuffer() => clears++;

  @override
  bool hasFrames({DateTime? since, DateTime? until}) =>
      !empty && (since == null || until == null || since.isBefore(until));

  @override
  Future<SessionRecordingPayload?> captureRecording(
    String clipId, {
    DateTime? since,
    DateTime? until,
  }) async {
    captures.add((clipId: clipId, since: since, until: until));
    if (empty) return null;
    final end = until ?? DateTime.now();
    return SessionRecordingPayload(
      clipId: clipId,
      events: [
        {
          'type': 'flutter_video',
          'data': base64Encode([0, 1, 2, 3]),
          'format': 'mp4',
          'fps': 15,
          'durationSeconds': 10.0,
        }
      ],
      startedAt: since ?? end.subtract(const Duration(seconds: 10)),
      endedAt: end,
    );
  }
}
