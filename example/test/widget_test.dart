import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway_example/main.dart';

void main() {
  testWidgets('Counter increments and the flush button is reachable', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Counter: 0'), findsOneWidget);

    await tester.tap(find.text('Increment Counter'));
    await tester.pump();
    expect(find.text('Counter: 1'), findsOneWidget);

    final flush = find.text('Flush (Force Send)');
    await tester.scrollUntilVisible(
      flush,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(flush);
    await tester.pump();
    expect(find.textContaining('Flush completed'), findsOneWidget);
  });
}
