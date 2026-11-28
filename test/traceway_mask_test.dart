// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/traceway_mask.dart';
import 'package:traceway/traceway.dart';

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
      SizedBox(
        key: const ValueKey('traceway-mask'),
        height: 40,
        child: SizedBox(key: blurred, width: 100),
      ),
      SizedBox(
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

  testWidgets('a mask on a sliver covers what the sliver paints',
      (tester) async {
    final inner = GlobalKey();
    await tester.pumpWidget(app(CustomScrollView(slivers: [
      const SliverToBoxAdapter(child: SizedBox(height: 100)),
      const SliverToBoxAdapter(
        key: ValueKey('traceway-mask'),
        child: SizedBox(height: 60),
      ),
      TracewayMask(
        mode: const TracewayMaskMode.blank(color: Color(0xFFFF0000)),
        child: SliverList(
          delegate: SliverChildListDelegate([
            SizedBox(
                height: 40, child: TracewayMask(child: SizedBox(key: inner))),
            const SizedBox(height: 40),
          ]),
        ),
      ),
      const SliverPadding(
        key: ValueKey('traceway-blank'),
        padding: EdgeInsets.all(10),
        sliver: SliverToBoxAdapter(child: SizedBox(height: 30)),
      ),
      const TracewayMask(
        child: SliverToBoxAdapter(child: SizedBox(height: 2000)),
      ),
    ])));
    var regions = maskRegionsIn(root());
    expect(regions.map((r) => r.mode.runtimeType).toList(), [
      TracewayMaskBlur,
      TracewayMaskBlank,
      TracewayMaskBlank,
      TracewayMaskBlur,
    ]);
    expect(regions.map((r) => r.rect).toList(), const [
      Rect.fromLTWH(0, 100, 800, 60),
      Rect.fromLTWH(0, 160, 800, 80),
      Rect.fromLTWH(0, 240, 800, 50),
      // What is on screen of a sliver that goes on below it.
      Rect.fromLTWH(0, 290, 800, 310),
    ]);
    expect((regions[1].mode as TracewayMaskBlank).color,
        const Color(0xFFFF0000));

    // Partly scrolled off the top, the mask is what is left on screen.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -130));
    await tester.pumpAndSettle();
    regions = maskRegionsIn(root());
    expect(regions.map((r) => r.rect).toList(), const [
      Rect.fromLTWH(0, 0, 800, 30),
      Rect.fromLTWH(0, 30, 800, 80),
      Rect.fromLTWH(0, 110, 800, 50),
      Rect.fromLTWH(0, 160, 800, 440),
    ]);

    // Scrolled away, a sliver paints nothing and has no mask.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    regions = maskRegionsIn(root());
    expect(regions.map((r) => r.rect).toList(),
        const [Rect.fromLTWH(0, 0, 800, 600)]);
  });

  testWidgets('a mask on a sliver of a horizontal scroll view',
      (tester) async {
    await tester.pumpWidget(app(const CustomScrollView(
      scrollDirection: Axis.horizontal,
      slivers: [
        SliverToBoxAdapter(child: SizedBox(width: 50)),
        SliverToBoxAdapter(
          key: ValueKey('traceway-blank'),
          child: SizedBox(width: 120),
        ),
      ],
    )));
    final region = maskRegionsIn(root()).single;
    expect(region.mode, isA<TracewayMaskBlank>());
    expect(region.rect, const Rect.fromLTWH(50, 0, 120, 600));
  });
}
