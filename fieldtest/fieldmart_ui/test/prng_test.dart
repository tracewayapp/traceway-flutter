import 'dart:convert';
import 'dart:io';

import 'package:fieldmart_ui/fieldmart_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the generator matches mulberry32 as JavaScript computes it', () {
    final r = FmRandom(1);
    // Math.imul-based reference, computed with Node.
    expect(r.next(), 0.6270739405881613);
    expect(r.next(), 0.002735721180215478);
    expect(r.next(), 0.5274470399599522);
  });

  test('symbol seeds', () {
    expect(symbolSeed(0), 20261128);
    expect(symbolSeed(1), 2667729081);
    expect(symbolSeed(299), 3422423219);
  });

  test('the tick model from 100.00 (Node reference)', () {
    final m = TickModel(1, 10000);
    expect([for (var i = 0; i < 5; i++) m.tick()], [10006, 9986, 9970, 9953, 9969]);
    expect(TickModel(299, 10000).advanceTo(200), 9775);
    expect(TickModel(0, 10000).advanceTo(200), 9855);
  });

  test('prices are formatted from integer cents', () {
    expect(formatCents(12345), '123.45');
    expect(formatCents(5), '0.05');
    expect(formatCents(123456789), '1,234,567.89');
  });

  // fixtures/reference/ticks.json, vendored by sync-shared.
  test('the tick model reproduces shared/reference/ticks.json', () {
    final j = jsonDecode(File('../shared/reference/ticks.json').readAsStringSync()) as Map<String, Object?>;
    final symbols = j['symbols'] as List;
    expect(symbols, isNotEmpty);
    for (final s in symbols.cast<Map<String, Object?>>()) {
      final model = TickModel((s['k'] as num).toInt(), (s['startCents'] as num).toInt());
      final want = (s['ticks'] as List).cast<num>().map((v) => v.toInt()).toList();
      expect([for (var i = 0; i < want.length; i++) model.tick()], want, reason: 'symbol ${s['symbol']}');
    }
  });
}
