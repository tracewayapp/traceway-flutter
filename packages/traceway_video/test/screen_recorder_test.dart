import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway_video/src/screen_recorder.dart';

/// Keeps what it is given and writes a stand-in MP4.
class _FakeEncoder implements VideoEncoder {
  final List<Uint8List> frames = [];
  late String filepath;
  late int fps;
  final started = Completer<void>();
  Future<void>? pause;

  @override
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required String filepath,
    required bool debug,
  }) async {
    this.filepath = filepath;
    this.fps = fps;
    if (!started.isCompleted) started.complete();
    await pause;
  }

  @override
  Future<void> appendFrame(Uint8List rgba) async => frames.add(rgba);

  @override
  Future<void> finish() => File(filepath).writeAsBytes(const [0, 0, 0, 0]);
}

/// A 4×4 PNG.
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = const Color(0xFF336699));
  final image = await recorder.endRecording().toImage(4, 4);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Sends [state] the way the platform does.
Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.lifecycle.name,
      SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
      (_) {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenRecorder clips', () {
    late _FakeEncoder encoder;
    late Uint8List png;

    setUpAll(() async => png = await _png());

    setUp(() {
      encoder = _FakeEncoder();
      ScreenRecorder.encoderOverride = encoder;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => Directory.systemTemp.path);
    });

    tearDown(() => ScreenRecorder.encoderOverride = null);

    final t0 = DateTime.utc(2026, 1, 1, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
    CapturedFrame frame(int ms) =>
        CapturedFrame(pngBytes: png, width: 4, height: 4, timestamp: at(ms));

    /// Which appended frame each one repeats: the same picture, not one
    /// decoded again.
    List<int> repeats() => [
          for (final f in encoder.frames)
            encoder.frames.indexWhere((other) => identical(other, f)),
        ];

    test('tightening masking invalidates buffered, encoding and queued clips',
        () async {
      final recorder = ScreenRecorder(repaintBoundaryKey: GlobalKey(), maxFrames: 3)
        ..maskAllInputs = false
        ..addFrame(frame(0));
      final resume = Completer<void>();
      encoder.pause = resume.future;
      final active = recorder.captureRecording('active');
      await encoder.started.future;
      final queued = recorder.captureRecording('queued');
      recorder.maskAllInputs = true;
      resume.complete();
      expect(await active, isNull);
      expect(await queued, isNull);
      expect(recorder.hasFrames(), isFalse);
      expect(await recorder.captureRecording('lookback'), isNull);
      recorder.addFrame(frame(100));
      recorder.maskAllInputs = true;
      expect(await recorder.captureRecording('fresh'), isNotNull);
    });

    test('each frame is held as long as it was on screen', () async {
      final recorder = ScreenRecorder(
          repaintBoundaryKey: GlobalKey(), maxFrames: 10, pixelRatio: 1, fps: 10);
      // On time, then 300 ms late (a slow device), then 60 ms after.
      for (final ms in [0, 100, 400, 460]) {
        recorder.addFrame(frame(ms));
      }
      final clip = (await recorder.captureRecording('c',
          since: t0, until: at(1000)))!;
      // 100 ms per encoder frame: 1, 3 and 1, then the last until the end.
      expect(repeats(), [0, 1, 1, 1, 4, 5, 5, 5, 5, 5]);
      final video = clip.events.single;
      expect(video['fps'], 10);
      expect(encoder.fps, 10);
      expect(video['durationSeconds'], 1.0);
      expect(clip.startedAt, t0);
      expect(clip.endedAt, at(1000));
    });

    test('a clip never runs past the end of its window', () async {
      // The 66 ms capture timer takes frames a little faster than 15 fps
      // plays them.
      final recorder = ScreenRecorder(
          repaintBoundaryKey: GlobalKey(), maxFrames: 300, pixelRatio: 1, fps: 15);
      for (var ms = 0; ms < 16000; ms += 66) {
        recorder.addFrame(frame(ms));
      }
      final first = (await recorder.captureRecording('a',
          since: t0, until: at(8000)))!;
      final second = (await recorder.captureRecording('b',
          since: at(8000), until: at(16000)))!;
      expect(first.startedAt, t0);
      expect(first.endedAt!.isAfter(at(8000)), isFalse,
          reason: 'ended at ${first.endedAt}');
      expect(second.startedAt!.isBefore(first.endedAt!), isFalse,
          reason: '${second.startedAt} starts before ${first.endedAt}');
      expect(second.endedAt!.isAfter(at(16000)), isFalse,
          reason: 'ended at ${second.endedAt}');
      expect(first.events.single['durationSeconds'], closeTo(8.0, 1 / 15));
    });

    test('a frame taken right before the end does not lengthen the clip',
        () async {
      final recorder = ScreenRecorder(
          repaintBoundaryKey: GlobalKey(), maxFrames: 20, pixelRatio: 1, fps: 10);
      for (final ms in [0, 100, 200, 300, 390]) {
        recorder.addFrame(frame(ms));
      }
      final clip = (await recorder.captureRecording('c',
          since: t0, until: at(400)))!;
      expect(clip.events.single['durationSeconds'], 0.4);
      expect(clip.endedAt, at(400));
      expect(encoder.frames, hasLength(4));
    });

    test('without an end the last frame is shown once', () async {
      final recorder = ScreenRecorder(
          repaintBoundaryKey: GlobalKey(), maxFrames: 10, pixelRatio: 1, fps: 10);
      recorder
        ..addFrame(frame(0))
        ..addFrame(frame(240));
      final clip = (await recorder.captureRecording('c'))!;
      expect(repeats(), [0, 0, 2]);
      expect(clip.events.single['durationSeconds'], 0.3);
      expect(clip.endedAt, at(300));
    });

    test('a clip runs at most maxClipSeconds and keeps its end', () async {
      // At 1 fps the cap is 60 encoder frames.
      final recorder = ScreenRecorder(
          repaintBoundaryKey: GlobalKey(), maxFrames: 10, pixelRatio: 1, fps: 1);
      expect(ScreenRecorder.maxClipSeconds, 60);

      // Five minutes in the background between two frames: what came
      // before is left out.
      for (final s in [0, 1, 300, 301]) {
        recorder.addFrame(frame(s * 1000));
      }
      var clip = (await recorder.captureRecording('a',
          since: t0, until: at(302000)))!;
      expect(repeats(), [0, 1]);
      expect(clip.events.single['durationSeconds'], 2.0);
      expect(clip.startedAt, at(300000));
      expect(clip.endedAt, at(302000));

      // Ten minutes after the last frame: every frame is kept and the last
      // is held for what is left.
      recorder.clearBuffer();
      encoder.frames.clear();
      for (final s in [0, 1, 2]) {
        recorder.addFrame(frame(s * 1000));
      }
      clip = (await recorder.captureRecording('b',
          since: t0, until: at(600000)))!;
      expect(encoder.frames, hasLength(60));
      expect(repeats().toSet(), {0, 1, 2});
      expect(clip.events.single['durationSeconds'], 60.0);
      expect(clip.startedAt, t0);
      expect(clip.endedAt, at(60000));
    });
  });

  group('ScreenRecorder lifecycle', () {
    final boundary = GlobalKey();

    Future<void> waitForFrames(ScreenRecorder recorder) async {
      for (var i = 0; i < 40 && recorder.bufferedFrameCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    ScreenRecorder recorder() => ScreenRecorder(
        repaintBoundaryKey: boundary, maxFrames: 5, pixelRatio: 0.25, fps: 20);

    Widget app() => RepaintBoundary(
          key: boundary,
          child: const ColoredBox(color: Color(0xFF00FF00)),
        );

    testWidgets('a recorder started in the background waits for the app',
        (tester) async {
      await tester.pumpWidget(app());
      await _lifecycle(tester, AppLifecycleState.paused);
      final r = recorder();
      await tester.runAsync(() async {
        r.start();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      expect(r.bufferedFrameCount, 0);

      await _lifecycle(tester, AppLifecycleState.resumed);
      await tester.runAsync(() => waitForFrames(r));
      r.stop();
      expect(r.bufferedFrameCount, greaterThan(0));
    });

    testWidgets('a recorder stopped in the background records once it is back',
        (tester) async {
      await tester.pumpWidget(app());
      await _lifecycle(tester, AppLifecycleState.resumed);
      final r = recorder();
      r.start();
      await _lifecycle(tester, AppLifecycleState.paused);
      r
        ..stop()
        ..clearBuffer();
      // The app comes back while the recorder is not observing it.
      await _lifecycle(tester, AppLifecycleState.resumed);
      await tester.runAsync(() async {
        r.start();
        await waitForFrames(r);
      });
      r.stop();
      expect(r.bufferedFrameCount, greaterThan(0));
    });
  });
}
