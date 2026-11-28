import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: implementation_imports
import 'package:traceway/src/sdk_version.dart';
// ignore: implementation_imports
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;
import 'package:traceway/traceway.dart';
import 'package:traceway/video.dart';
import 'package:traceway_video/src/screen_recorder.dart';
import 'package:traceway_video/traceway_video.dart';

class _NullEncoder implements VideoEncoder {
  @override
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required String filepath,
    required bool debug,
  }) async {}

  @override
  Future<void> appendFrame(Uint8List rgba) async {}

  @override
  Future<void> finish() async {}
}

Future<TracewayClient> _client() => TracewayClient.initializeForTest(
      null,
      const TracewayOptions(
        remoteConfig: false,
        screenCapture: true,
        screenCaptureMode: TracewayScreenCaptureMode.video,
        fps: 10,
        maxBufferFrames: 40,
        capturePixelRatio: 0.5,
      ),
      token: 'tok',
      baseUrl: 'https://traceway.test',
      overrides: TracewayTestOverrides(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        // Ask the add-on whether it can encode here.
        videoSupported: null,
      ),
    );

void main() {
  tearDown(() async {
    registerTracewayVideoBackend(null);
    await TracewayClient.resetForTest();
  });

  test('register() makes the add-on the video backend', () {
    expect(tracewayVideoBackend, isNull);
    TracewayVideo.register();
    final backend = tracewayVideoBackend!;
    expect(backend.isSupported,
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
    final recorder = backend.createRecorder(TracewayVideoRecorderConfig(
      repaintBoundaryKey: GlobalKey(),
      maxFrames: 30,
      pixelRatio: 0.5,
      fps: 12,
      debug: false,
    )) as ScreenRecorder;
    expect(recorder.fps, 12);
    expect(recorder.pixelRatio, 0.5);
  });

  test('an encoder of the app\'s makes video work where there is no '
      'hardware encoder', () {
    TracewayVideo.register(encoder: _NullEncoder());
    expect(tracewayVideoBackend!.isSupported, isTrue);
  });

  testWidgets('with the add-on the Traceway widget records video',
      (tester) async {
    TracewayVideo.register(encoder: _NullEncoder());
    final client = (await tester.runAsync(_client))!;
    expect(client.captureMode.value, TracewayScreenCaptureMode.video);
    await tester.pumpWidget(const Traceway(
        child: Directionality(
            textDirection: TextDirection.ltr, child: Text('screen'))));
    await tester.pump();
    final recorder = client.screenRecorder;
    expect(recorder, isA<ScreenRecorder>());
    expect((recorder as ScreenRecorder).fps, 10);
    expect(recorder.maskAllInputs, isTrue);
    client.control.applyRemote({
      'replay': {'maskAllInputs': false}
    });
    expect(recorder.maskAllInputs, isFalse);
    recorder.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.shutdown);
  });

  test('without register() the core records a wireframe', () async {
    final client = await _client();
    expect(client.captureMode.value, TracewayScreenCaptureMode.wireframe);
  });

  test('the add-on carries the encoder; its version is the core\'s', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('flutter_quick_video_encoder:'));
    final version = RegExp(r'^version: (\S+)$', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(version, tracewaySdkVersion);
  });
}
