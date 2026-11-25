// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/screen_recorder.dart';
import 'package:traceway/src/traceway_privacy_mask.dart';
import 'package:traceway/traceway.dart';

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

  RenderBox box() => boundary.currentContext!.findRenderObject()! as RenderBox;

  Widget app(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(key: boundary, child: child),
      );

  Widget list({double dx = 0}) => ListView(children: [
        const SizedBox(height: 300),
        Transform.translate(
          offset: Offset(dx, 0),
          child: TracewayPrivacyMask(
            mode: const TracewayMaskMode.blank(color: Color(0xFFFF0000)),
            child: Container(
                key: secret, height: 50, color: const Color(0xFF00FF00)),
          ),
        ),
        const SizedBox(height: 2000),
      ]);

  testWidgets('a mask stays on its widget when that scrolls or moves',
      (tester) async {
    await tester.pumpWidget(app(list()));
    expect(maskRegionsIn(box()).single.rect, tester.getRect(find.byKey(secret)));
    expect(maskRegionsIn(box()).single.rect.top, 300);

    // Scrolling does not rebuild the mask: its place is read when a frame
    // is captured, not when the widget is built.
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(maskRegionsIn(box()).single.rect.top, 100);
    expect(maskRegionsIn(box()).single.rect, tester.getRect(find.byKey(secret)));

    // Nor does a transform above it.
    await tester.pumpWidget(app(list(dx: 40)));
    expect(maskRegionsIn(box()).single.rect.left, 40);

    await tester.pumpWidget(app(const SizedBox()));
    expect(maskRegionsIn(box()), isEmpty);
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
