// CONTRACT §17: video replay is the traceway_video add-on. The core package
// records wireframes, and video without the add-on warns once and records a
// wireframe.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/traceway_client.dart' show TracewayTestOverrides;
import 'package:traceway/src/wireframe/wireframe_recorder.dart';
import 'package:traceway/traceway.dart';
import 'package:traceway/video.dart';

import 'support.dart';

Future<TracewayClient> _client(TracewayOptions options) =>
    TracewayClient.initializeForTest(
      connectionString,
      options,
      overrides: TracewayTestOverrides(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        videoSupported: null,
      ),
    );

const _video = TracewayOptions(
  remoteConfig: false,
  screenCapture: true,
  screenCaptureMode: TracewayScreenCaptureMode.video,
);

void main() {
  late List<String> printed;
  late DebugPrintCallback previous;

  setUp(() {
    printed = [];
    previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    TracewayClient.resetVideoWarningForTest();
  });
  tearDown(() async {
    debugPrint = previous;
    registerTracewayVideoBackend(null);
    await TracewayClient.resetForTest();
  });

  test('the core package has no video encoder and no native code', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('flutter_quick_video_encoder')));
    expect(pubspec, isNot(contains(RegExp(r'^\s+plugin:', multiLine: true))));
    for (final dir in ['android', 'ios', 'macos', 'linux', 'windows']) {
      expect(Directory(dir).existsSync(), isFalse, reason: dir);
    }
    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.readAsStringSync());
    expect(sources.where((s) => s.contains('flutter_quick_video_encoder')),
        isEmpty);
    // The example no longer patches the encoder's Gradle project.
    expect(File('example/android/build.gradle.kts').readAsStringSync(),
        isNot(contains('flutter_quick_video_encoder')));
  });

  test('wireframe is the default mode', () {
    expect(const TracewayOptions().screenCaptureMode,
        TracewayScreenCaptureMode.wireframe);
  });

  test('video without the add-on records a wireframe, after one warning that '
      'says what to add', () async {
    final client = await _client(_video);
    expect(client.captureMode.value, TracewayScreenCaptureMode.wireframe);
    // The dashboard asking for video changes nothing either.
    client.control.applyRemote({
      'replay': {'captureMode': 'video'}
    });
    expect(client.captureMode.value, TracewayScreenCaptureMode.wireframe);
    await client.shutdown();
    final again = await _client(_video);
    expect(again.captureMode.value, TracewayScreenCaptureMode.wireframe);
    final warnings = printed.where((l) => l.contains('traceway_video'));
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('TracewayVideo.register()'));
    expect(warnings.single, contains('wireframe'));
  });

  test('a wireframe app without the add-on hears nothing about it', () async {
    final client = await _client(
        const TracewayOptions(remoteConfig: false, screenCapture: true));
    expect(client.captureMode.value, TracewayScreenCaptureMode.wireframe);
    expect(printed.where((l) => l.contains('traceway_video')), isEmpty);
  });

  test('an add-on that cannot encode here gives a wireframe, without the '
      'warning', () async {
    registerTracewayVideoBackend(FakeVideoBackend(isSupported: false));
    final client = await _client(_video);
    expect(client.captureMode.value, TracewayScreenCaptureMode.wireframe);
    expect(printed.where((l) => l.contains('traceway_video')), isEmpty);
  });

  testWidgets('with the add-on the Traceway widget records through it, with '
      'the options, and follows replay.maskAllInputs and touches',
      (tester) async {
    final backend = FakeVideoBackend();
    registerTracewayVideoBackend(backend);
    final client = (await tester.runAsync(() => _client(const TracewayOptions(
          remoteConfig: false,
          screenCapture: true,
          screenCaptureMode: TracewayScreenCaptureMode.video,
          fps: 12,
          maxBufferFrames: 60,
          capturePixelRatio: 0.5,
          debug: true,
        ))))!;
    expect(client.captureMode.value, TracewayScreenCaptureMode.video);
    await tester.pumpWidget(const Traceway(
        child: Directionality(
            textDirection: TextDirection.ltr, child: Text('screen'))));
    await tester.pump();
    final recorder = backend.made.single;
    expect(client.screenRecorder, same(recorder));
    expect(recorder.config.fps, 12);
    expect(recorder.config.maxFrames, 60);
    expect(recorder.config.pixelRatio, 0.5);
    expect(recorder.config.debug, isTrue);
    expect(recorder.config.repaintBoundaryKey.currentContext, isNotNull);
    expect(recorder.masked, isTrue);
    client.control.applyRemote({
      'replay': {'maskAllInputs': false}
    });
    expect(recorder.masked, isFalse);

    final gesture = await tester.startGesture(const Offset(10, 10));
    expect(recorder.touch, const Offset(10, 10));
    await gesture.up();
    expect(recorder.touch, isNull);

    // The dashboard switches to a wireframe: the add-on's recorder goes.
    client.control.applyRemote({
      'replay': {'captureMode': 'wireframe'}
    });
    expect(client.screenRecorder, isA<WireframeRecorder>());
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.shutdown);
    // Before the binding checks its debug variables.
    debugPrint = previous;
  });
}
