import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:traceway/src/replay/recordings_transport.dart';
import 'package:traceway/src/wireframe/vnode.dart';
import 'package:traceway/src/wireframe/wireframe_capture.dart';
import 'package:traceway/src/wireframe/wireframe_recorder.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  final start = DateTime.utc(2026, 1, 1);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));
  String url(int chars, {String mime = 'png', String char = 'A'}) =>
      'data:image/$mime;base64,${char * chars}';
  VNode rule(int id, String data, {bool glyph = false}) =>
      VNode.element(id, 'style', {
        '_cssText': glyph
            ? '.ic.g$id::before{mask:url($data) no-repeat}'
            : '.im.p$id{background:url($data) center/cover no-repeat}',
      }, []);
  VNode screen(List<VNode> rules) => VNode.element(screenNodeId, 'div', {}, [
    ...rules,
    VNode.element(100, 'div', {
      'class': 'im p20',
      'style': 'width:37px;height:29px',
    }, []),
    VNode.element(101, 'div', {'class': 'mk'}, [VNode.text(102, '****')]),
    VNode.element(103, 'img', {
      'src': 'https://images.example/a.jpg',
      'class': 'w',
      'style': 'width:20px;height:30px',
    }, []),
    VNode.element(104, 'div', {
      'style':
          'width:30px;background-image:url("https://images.example/b.jpg");',
    }, []),
  ]);
  WireframeRecorder recorder() =>
      WireframeRecorder(rootKey: GlobalKey(), maxFrames: 10, now: () => at(5));
  WireframeFrame frame(VNode s, int time, {double width = 200}) =>
      WireframeFrame(s, Size(width, 100), at(time), href: '/checkout');

  Future<List<dynamic>> send(WireframeRecorder r, int since, int until) async {
    final clip = (await r.captureRecording(
      'clip',
      since: at(since),
      until: at(until),
    ))!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dir = await Directory.systemTemp.createTemp('wireframe_segment_');
    final stored = File('${dir.path}/recordings.json.gz');
    final client = IOClient(_LocalHttp().createHttpClient(null));
    addTearDown(() async {
      client.close();
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
    server.listen((request) async {
      if (request.method != 'POST' || request.uri.path != '/api/recordings') {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        final sink = stored.openWrite();
        await sink.addStream(request);
        await sink.close();
        request.response.write('{}');
      }
      await request.response.close();
    });
    final transport = RecordingsTransport(
      url: 'http://127.0.0.1:${server.port}/api/recordings',
      token: 'test',
      httpClient: client,
      retryDelaysMs: const [],
    );
    transport.send([
      RecordingSegment(
        sessionId: 'demo',
        segmentIndex: 3,
        events: clip.events,
        approxBytes: clip.approxBytes,
      ),
    ]);
    await transport.flush();
    final doc = jsonDecode(
      utf8.decode(gzip.decode(await stored.readAsBytes())),
    );
    return doc['segments'].single['events'] as List;
  }

  test(
    'exactly 128 KiB of raster URL strings survives encoding and upload; one more character clears the segment',
    () async {
      // Four valid base64 strings and their MIME prefixes add to 131072. One
      // JPEG prefix instead of PNG makes 131073, independent of gzip size.
      for (final over in [false, true]) {
        final r = recorder();
        final pictures = [
          for (var i = 0; i < 4; i++)
            rule(
              20 + i,
              url(
                i == 3 ? 32752 : 32744,
                mime: i == 3 && over ? 'jpeg' : 'png',
              ),
              glyph: i == 0,
            ),
        ];
        r.addFrameForTest(frame(screen(pictures), 0));
        final events = await send(r, 0, 1);
        final json = jsonEncode(events);
        expect(json.contains('data:image'), !over);
        expect(json.contains('https://images.example/'), !over);
        expect(json, contains('width:37px;height:29px'));
        expect(json, contains('****'));
        expect(events.map((e) => e['type']), [4, 2, 5]);
      }
    },
  );

  test(
    'large text and reused image class names do not consume raster allowance',
    () async {
      final picture = url(16);
      final text = 'url(data:image/png;base64,${'A' * 138000})';
      final r = recorder();
      r.addFrameForTest(
        frame(
          screen([
            rule(20, picture),
            VNode.element(30, 'p', {'class': 'im p20'}, [VNode.text(31, text)]),
          ]),
          0,
        ),
      );
      final events = jsonEncode(await send(r, 0, 1));
      expect(events, contains(text));
      expect(events, contains('background:url($picture)'));
      expect(events, contains('https://images.example/a.jpg'));
    },
  );

  test(
    'snapshots, added styles and updated style attributes count their repeated occurrences; the next clip starts fresh',
    () async {
      final r = recorder();
      final a = url(44000);
      final b = url(44000, char: 'B');
      final first = screen([rule(20, a)]);
      final second = screen([rule(20, b), rule(21, a, glyph: true)]);
      r.addFrameForTest(frame(first, 0));
      r.addFrameForTest(frame(second, 1));
      r.addFrameForTest(frame(second, 2, width: 220));
      final mutated = await send(r, 0, 2);
      expect(jsonEncode(mutated), isNot(contains('data:image')));
      expect(mutated.map((e) => e['type']), [4, 2, 3, 5]);
      expect(mutated[2]['data']['adds'], isNotEmpty);
      expect(mutated[2]['data']['attributes'], isNotEmpty);
      final resized = await send(r, 1, 3);
      expect(jsonEncode(resized), isNot(contains('data:image')));
      expect(resized.map((e) => e['type']), [4, 2, 4, 2, 5]);
      final next = await send(r, 2, 3);
      expect(jsonEncode(next), contains(a));
      expect(jsonEncode(next), contains(b));
      expect(jsonEncode(await send(r, 0, 1)), contains(a));
    },
  );
}
