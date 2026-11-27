// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/traceway.dart';
import 'package:traceway_video/src/screen_recorder.dart';

class _RecordingEncoder implements VideoEncoder {
  final List<Uint8List> frames = [];
  late int width;

  @override
  Future<void> setup({
    required int width,
    required int height,
    required int fps,
    required String filepath,
    required bool debug,
  }) async {
    this.width = width;
  }

  @override
  Future<void> appendFrame(Uint8List rgba) async => frames.add(rgba);

  @override
  Future<void> finish() async => throw StateError('frames are all we need');
}

void main() {
  final boundary = GlobalKey();
  final secret = GlobalKey();

  Widget app(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(key: boundary, child: child),
      );

  Widget list({double dx = 0}) => ListView(children: [
        const SizedBox(height: 300),
        Transform.translate(
          offset: Offset(dx, 0),
          child: TracewayMask(
            mode: const TracewayMaskMode.blank(color: Color(0xFFFF0000)),
            child: Container(
                key: secret, height: 50, color: const Color(0xFF00FF00)),
          ),
        ),
        const SizedBox(height: 2000),
      ]);

  testWidgets('tightening masking during readback discards that image',
      (tester) async {
    await tester.pumpWidget(app(const ColoredBox(color: Colors.blue)));
    await tester.runAsync(() async {
      final recorder = ScreenRecorder(repaintBoundaryKey: boundary,
          maxFrames: 2, fps: 20)..maskAllInputs = false;
      // Capture has selected its masks and yielded on the image readback.
      final capture = recorder.captureFrameForTest();
      recorder.maskAllInputs = true;
      await capture;
      expect(recorder.hasFrames(), isFalse);
      await recorder.captureFrameForTest();
      expect(recorder.hasFrames(), isTrue);
    });
  });

  testWidgets('a typed password field is opaque in encoded Android frames',
      (tester) async {
    tester.platformDispatcher.brieflyShowPasswordTestValue = true;
    addTearDown(tester.platformDispatcher.resetBrieflyShowPassword);
    final field = find.byType(TextField);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: Scaffold(body: RepaintBoundary(key: boundary,
          child: const TextField(obscureText: true,
              decoration: InputDecoration(filled: true, fillColor: Colors.white)))),
    ));
    await tester.tap(field);
    await tester.enterText(field, 'ab');
    await tester.pump();
    await tester.enterText(field, 'abx');
    await tester.pump(const Duration(milliseconds: 1));
    final editable = tester.renderObject<RenderEditable>(
        find.byElementPredicate((e) =>
            e is RenderObjectElement && e.renderObject is RenderEditable));
    expect(editable.text?.toPlainText(), '••x',
        reason: 'the rendered field is briefly displaying the typed character');
    final bounds = MatrixUtils.transformRect(editable.getTransformTo(
        boundary.currentContext!.findRenderObject()), Offset.zero & editable.size);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => Directory.systemTemp.path);
    await tester.runAsync(() async {
      for (final maskInputs in [false, true]) {
        final encoder = _RecordingEncoder();
        final recorder = ScreenRecorder(repaintBoundaryKey: boundary,
            maxFrames: 1, pixelRatio: 1, encoder: encoder)..maskAllInputs = maskInputs;
        await recorder.captureFrameForTest();
        await recorder.captureRecording('obscured');
        final frame = encoder.frames.single;
        for (var y = bounds.top.ceil(); y < bounds.bottom.floor(); y++) {
          for (var x = bounds.left.ceil(); x < bounds.right.floor(); x++) {
            final offset = (y * encoder.width + x) * 4;
            if (frame[offset] != 0 || frame[offset + 1] != 0 ||
                frame[offset + 2] != 0 || frame[offset + 3] != 255) {
              fail('Unmasked pixel at ($x, $y) with maskAllInputs=$maskInputs');
            }
          }
        }
      }
    });
  });

  testWidgets('the recorded frame is masked where the widget was painted',
      (tester) async {
    final encoder = _RecordingEncoder();
    ScreenRecorder.encoderOverride = encoder;
    addTearDown(() => ScreenRecorder.encoderOverride = null);
    await tester.pumpWidget(app(list()));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => Directory.systemTemp.path);
    await tester.runAsync(() async {
      final recorder = ScreenRecorder(
          repaintBoundaryKey: boundary, maxFrames: 2, pixelRatio: 1, fps: 20);
      recorder.start();
      for (var i = 0; i < 40 && recorder.bufferedFrameCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      recorder.stop();
      await recorder.captureRecording('clip');
    });
    expect(encoder.frames, isNotEmpty);

    List<int> pixel(int x, int y) {
      final offset = (y * encoder.width + x) * 4;
      return encoder.frames.first.sublist(offset, offset + 3);
    }

    // The widget is green; where it is now, the frame holds the red mask.
    expect(pixel(400, 125), [255, 0, 0]);
    // Where it was before the scroll, nothing is masked.
    expect(pixel(400, 325), isNot([255, 0, 0]));
  });
}
