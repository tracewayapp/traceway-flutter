import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/opamp/client.dart';
import 'package:traceway/src/opamp/messages.dart';

// Produced by opamp-go v0.25.0's generated types (proto.Marshal,
// deterministic) for the same messages; shared with the browser SDK's tests.
const goAgentToServer =
    '0a100195f2a000007000800000000000000110031a6f0a1a0a0c736572766963652e6e616d65120a0a0873686f702d776562121a0a0f736572766963652e76657273696f6e12070a05322e332e3112140a0e62726f777365722e6d6f62696c6512021001120b0a0573656174731202180c12120a05726174696f120921000000000000d03f2083603a060a02abcd100162370a19696f2e74726163657761792e73646b2e6275666665722f76310a1a696f2e74726163657761792e73646b2e636170747572652f7631';
const goServerToAgent =
    '0a100195f2a00000700080000000000000011a570a500a4e0a08747261636577617912420a2e7b22736368656d6156657273696f6e223a312c227265706c6179223a7b226d6f6465223a2273747265616d227d7d12106170706c69636174696f6e2f6a736f6e120301020322080a0109120320ac023001382342120a10ffeeddccbbaa99887766554433221100';
const goServerError = '121108021204627573791a070880b09dc2df01';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List fromHex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

final uid = fromHex('0195f2a0000070008000000000000001');

void main() {
  group('OpAMP codec', () {
    test('encodes AgentToServer byte for byte like opamp-go', () {
      final bytes = encodeAgentToServer(AgentToServer(
        instanceUid: uid,
        sequenceNum: 3,
        agentDescription: AgentDescription(
          identifying: {'service.name': 'shop-web'},
          nonIdentifying: {
            'service.version': '2.3.1',
            'browser.mobile': true,
            'seats': 12,
            'ratio': 0.25,
          },
        ),
        capabilities: 0x1 | 0x2 | 0x1000 | 0x2000,
        remoteConfigStatus: RemoteConfigStatus(
          lastRemoteConfigHash: fromHex('abcd'),
          status: RemoteConfigStatuses.applied,
        ),
        customCapabilities: const [
          'io.traceway.sdk.buffer/v1',
          'io.traceway.sdk.capture/v1',
        ],
      ));
      expect(hex(bytes), goAgentToServer);
    });

    test('writes false, zero and empty values explicitly', () {
      final bytes = encodeAgentToServer(AgentToServer(
        instanceUid: uid,
        sequenceNum: 0,
        agentDescription: AgentDescription(
          identifying: const {},
          nonIdentifying: {'flag': false, 'n': 0},
        ),
        capabilities: 0,
      ));
      // KeyValue{key:"flag", value:AnyValue{bool_value:false}}
      expect(hex(bytes), contains('0a04666c616712021000'));
      // KeyValue{key:"n", value:AnyValue{int_value:0}}
      expect(hex(bytes), contains('0a016e12021800'));
    });

    test('decodes a ServerToAgent written by opamp-go', () {
      final msg = decodeServerToAgent(fromHex(goServerToAgent));
      expect(hex(msg.instanceUid!), hex(uid));
      expect(msg.flags, 1);
      expect(msg.capabilities, 0x23);
      expect(msg.heartbeatIntervalSeconds, 300);
      expect(hex(msg.newInstanceUid!), 'ffeeddccbbaa99887766554433221100');
      expect(hex(msg.remoteConfig!.configHash), '010203');
      final doc = msg.remoteConfig!.configMap['traceway']!;
      expect(doc.contentType, 'application/json');
      expect(jsonDecode(utf8.decode(doc.body)), {
        'schemaVersion': 1,
        'replay': {'mode': 'stream'},
      });
    });

    test('decodes an error response with retry info', () {
      final error = decodeServerToAgent(fromHex(goServerError)).errorResponse!;
      expect(error.type, ServerErrorTypes.unavailable);
      expect(error.message, 'busy');
      expect(error.retryAfterMs, 60000);
    });

    test('skips fields it does not know', () {
      expect(decodeServerToAgent(fromHex('f801073001')).flags, 1);
    });

    test('rejects a message cut off inside a field it skips', () {
      // Field 31 as fixed32 and fixed64, with fewer bytes than they take.
      expect(() => decodeServerToAgent(fromHex('fd010000')), throwsFormatException);
      expect(() => decodeServerToAgent(fromHex('f901000000')), throwsFormatException);
    });

    test('rejects a varint longer than ten bytes', () {
      expect(() => decodeServerToAgent(fromHex('f801${'ff' * 10}01')),
          throwsFormatException);
    });

    test('encodeServerToAgent round-trips through the decoder', () {
      final msg = decodeServerToAgent(encodeServerToAgent(
        flags: 1,
        capabilities: 0x23,
        heartbeatIntervalSeconds: 120,
        remoteConfig: RemoteConfig(
          configMap: {
            'traceway': AgentConfigObject(
              body: Uint8List.fromList(utf8.encode('{"schemaVersion":1}')),
              contentType: 'application/json',
            ),
          },
          configHash: fromHex('0a0b'),
        ),
      ));
      expect(msg.flags, 1);
      expect(msg.heartbeatIntervalSeconds, 120);
      expect(hex(msg.remoteConfig!.configHash), '0a0b');
      expect(utf8.decode(msg.remoteConfig!.configMap['traceway']!.body),
          '{"schemaVersion":1}');
    });
  });

  group('OpampHttpClient', () {
    late List<http.Request> requests;

    OpampHttpClient client(
      Future<http.Response> Function(http.Request, int index) respond, {
      ApplyResult Function(RemoteConfig)? onRemoteConfig,
      void Function(int)? onStopped,
      Uint8List? appliedConfigHash,
    }) {
      requests = [];
      return OpampHttpClient(
        endpoint: 'https://traceway.test/api/otel/v1/opamp',
        headers: const {'Authorization': 'Bearer tok'},
        instanceUid: uid,
        capabilities: 0x3003,
        describe: () => AgentDescription(
            identifying: {'service.name': 'app'}, nonIdentifying: const {}),
        onRemoteConfig: onRemoteConfig ?? (_) => const ApplyResult.applied(),
        onStopped: onStopped,
        appliedConfigHash: appliedConfigHash,
        httpClient: MockClient((request) {
          requests.add(request);
          return respond(request, requests.length - 1);
        }),
      );
    }

    http.Response config(List<int> hash) => http.Response.bytes(
          encodeServerToAgent(
            heartbeatIntervalSeconds: 60,
            remoteConfig: RemoteConfig(
              configMap: {
                'traceway': AgentConfigObject(
                    body: Uint8List.fromList(utf8.encode('{}')),
                    contentType: 'application/json'),
              },
              configHash: Uint8List.fromList(hash),
            ),
          ),
          200,
        );

    test('sends the protobuf headers and the instance uid', () async {
      final c = client((_, __) async => http.Response.bytes(
          encodeServerToAgent(heartbeatIntervalSeconds: 300), 200));
      c.start();
      await c.poll();
      c.stop();
      final request = requests.first;
      expect(request.headers['Content-Type'], 'application/x-protobuf');
      expect(request.headers['Authorization'], 'Bearer tok');
      expect(request.headers['OpAMP-Instance-UID'],
          '0195f2a0-0000-7000-8000-000000000001');
      expect(hex(request.bodyBytes).startsWith('0a10${hex(uid)}'), isTrue);
      expect(c.pollIntervalMs, 300000);
    });

    test('applies a new config and reports it on an immediate second poll',
        () async {
      final applied = <String>[];
      final c = client(
        (_, index) async => index == 0
            ? config([1, 2, 3])
            : http.Response.bytes(
                encodeServerToAgent(heartbeatIntervalSeconds: 60), 200),
        onRemoteConfig: (cfg) {
          applied.add(hex(cfg.configHash));
          return const ApplyResult.applied();
        },
      );
      c.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.stop();
      expect(applied, ['010203']);
      expect(requests, hasLength(2));
      // remote_config_status{last_remote_config_hash: 010203, status: APPLIED}
      expect(hex(requests[1].bodyBytes), contains('3a070a030102031001'));
      expect(c.pollIntervalMs, 60000);
    });

    test('reports FAILED with the error when the config cannot be applied',
        () async {
      final c = client(
        (_, index) async => index == 0
            ? config([9])
            : http.Response.bytes(encodeServerToAgent(), 200),
        onRemoteConfig: (_) => const ApplyResult.failed('bad'),
      );
      c.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.stop();
      expect(hex(requests[1].bodyBytes),
          contains('3a0a0a010910031a03${hex(utf8.encode('bad'))}'));
    });

    test('does not re-apply a config whose hash is already applied', () async {
      var applied = 0;
      final c = client(
        (_, __) async => config([1, 2, 3]),
        appliedConfigHash: Uint8List.fromList([1, 2, 3]),
        onRemoteConfig: (_) {
          applied++;
          return const ApplyResult.applied();
        },
      );
      c.start();
      await c.poll();
      c.stop();
      expect(applied, 0);
      expect(requests, hasLength(1));
    });

    test('stops for good on 401, 403 and 404', () async {
      for (final status in [401, 403, 404]) {
        int? stopped;
        final c = client((_, __) async => http.Response('', status),
            onStopped: (code) => stopped = code);
        c.start();
        await c.poll();
        expect(stopped, status);
        expect(c.isRunning, isFalse);
        await c.poll();
        expect(requests, hasLength(1));
      }
    });

    test('backs off instead of polling again after a server error', () async {
      final c = client((_, __) async =>
          http.Response('', 503, headers: {'retry-after': '60'}));
      c.start();
      await c.poll();
      await c.poll();
      expect(requests, hasLength(1));
      expect(c.isRunning, isTrue);
      c.stop();
    });
  });
}
