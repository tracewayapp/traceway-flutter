// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/screen_recorder.dart';
import 'package:traceway/src/traceway_mask.dart';
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

  BuildContext root() => boundary.currentContext!;

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

  testWidgets('a mask stays on its widget when that scrolls or moves',
      (tester) async {
    await tester.pumpWidget(app(list()));
    expect(maskRegionsIn(root()).single.rect, tester.getRect(find.byKey(secret)));
    expect(maskRegionsIn(root()).single.rect.top, 300);

    // Scrolling does not rebuild the mask: its place is read when a frame
    // is captured, not when the widget is built.
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(maskRegionsIn(root()).single.rect.top, 100);
    expect(maskRegionsIn(root()).single.rect, tester.getRect(find.byKey(secret)));

    // Nor does a transform above it.
    await tester.pumpWidget(app(list(dx: 40)));
    expect(maskRegionsIn(root()).single.rect.left, 40);

    await tester.pumpWidget(app(const SizedBox()));
    expect(maskRegionsIn(root()), isEmpty);
  });

  testWidgets('a marker key masks a widget like TracewayMask does',
      (tester) async {
    final blurred = GlobalKey();
    final blanked = GlobalKey();
    await tester.pumpWidget(app(Column(children: [
      const SizedBox(height: 10),
      Container(
        key: const ValueKey('traceway-mask'),
        height: 40,
        child: SizedBox(key: blurred, width: 100),
      ),
      Container(
        key: const ValueKey('traceway-blank'),
        height: 30,
        // Nothing under a blank mask is listed: its box covers it.
        child: TracewayMask(child: SizedBox(key: blanked, width: 100)),
      ),
      // Deprecated, and the same widget.
      // ignore: deprecated_member_use_from_same_package
      const TracewayPrivacyMask(child: SizedBox(height: 20)),
      const SizedBox(key: ValueKey('not-a-mask'), height: 20),
    ])));
    final regions = maskRegionsIn(root());
    expect(regions.map((r) => r.mode.runtimeType).toList(),
        [TracewayMaskBlur, TracewayMaskBlank, TracewayMaskBlur]);
    expect(regions[0].rect, tester.getRect(find.byKey(blurred)));
    expect(regions[0].rect.top, 10);
    expect(regions[1].rect, tester.getRect(find.byKey(blanked)));
    expect((regions[1].mode as TracewayMaskBlank).color,
        const Color(0xFF000000));
    expect(regions[2].rect.top, 80);
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
