// Every id in shared/ids.json is found by key on its screen, and every
// screen lays out at the phone size without errors. The data is synthetic,
// shaped like shared/fixtures-api.md (not the shared fixtures themselves).
import 'dart:convert';
import 'dart:io';

import 'package:fieldmart_ui/fieldmart_ui.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _product(int id) => {
      'id': id, 'title': 'Product $id', 'brand': 'Brand ${id % 9}', 'categoryId': id % 12,
      'priceCents': 1000 + id * 7, 'compareAtCents': id % 3 == 0 ? null : 1500 + id * 7,
      'rating': 3.5, 'reviewCount': 20, 'badges': id % 5 == 0 ? ['sale'] : <String>[], 'imageCount': 8,
    };

Map<String, Object?> _row(int i) {
  if (i % 50 == 0) return {'type': 'header', 'label': 'Week ${i ~/ 50 + 1}'};
  return switch (i % 4) {
    0 => {'type': 'order', 'label': 'Payment received for FM-$i', 'icon': 'check', 'time': 'Thu 22:22'},
    1 => {'type': 'message', 'label': 'Message from P$i', 'from': 'P$i', 'avatarId': 1 + i % 64,
          'lines': ['Line one of $i.', 'Line two.', 'Line three.', 'Line four.'], 'time': 'Mon 13:16'},
    2 => {'type': 'shipment', 'label': 'Out for delivery: Product $i', 'productId': 1 + i % 2000,
          'detail': 'Carrier · Sat 16:13', 'progress': i % 100},
    _ => {'type': 'alert', 'label': 'SYM moved up 0.18 %', 'symbol': 'SYM', 'priceCents': 18308, 'changeBp': 18,
          'spark': [1, 3, 2, 4, 3], 'time': 'Wed 15:07'},
  };
}

class _Fake extends NoTelemetry {
  const _Fake();
  @override
  http.Client httpClient() => MockClient((req) async {
        final p = req.url.path.replaceFirst('/fx/api/', '');
        final q = req.url.queryParameters;
        Object? body;
        if (p == 'categories') {
          body = [for (var i = 0; i < 12; i++) {'id': i, 'name': 'Category $i', 'productCount': 160}];
        } else if (p == 'deals') {
          body = [for (var i = 0; i < 20; i++) {'productId': i == 0 ? 17 : i * 3, 'pct': 25, 'badge': 'pct-25'}];
        } else if (p == 'hero') {
          body = [for (var i = 1; i <= 8; i++) {'id': i, 'title': 'Hero $i', 'subtitle': 'Sub $i', 'image': 'img/hero/$i/1600.jpg'}];
        } else if (p == 'products') {
          final page = int.parse(q['page'] ?? '0');
          body = {'page': page, 'size': 40, 'total': 2000, 'items': [for (var i = 1; i <= 40; i++) _product(page * 40 + i)], 'next': page + 1};
        } else if (RegExp(r'^products/\d+$').hasMatch(p)) {
          final id = int.parse(p.split('/')[1]);
          body = {..._product(id), 'description': 'Words ' * 200, 'sizes': ['XS', 'S', 'M', 'L', 'XL', 'XXL'],
                  'colours': [for (var i = 0; i < 8; i++) {'name': 'C$i', 'hex': '#5b6770'}], 'stock': 12};
        } else if (p.endsWith('/reviews')) {
          final id = p.split('/')[1];
          body = {'productId': int.parse(id), 'page': 0, 'size': 50, 'total': 50, 'next': null, 'items': [
            for (var i = 0; i < 50; i++) {'id': 'r$id-$i', 'author': 'Reviewer $i', 'avatarId': 1 + i % 64, 'date': '2026-11-01', 'rating': 1 + i % 5, 'text': 'Text ' * (5 + i % 30)}]};
        } else if (p == 'symbols') {
          body = [for (var i = 0; i < 300; i++) {'symbol': 'S$i', 'name': 'Symbol company $i', 'seedIndex': i, 'startCents': 10000 + i}];
        } else if (p == 'candles') {
          body = [for (var i = 0; i < 5000; i++) [1672404060 + i * 60, 10000 + i % 50, 10060 + i % 50, 9950 + i % 50, 10010 + i % 50]];
        } else if (p == 'quotes') {
          body = {'n': 1, 'count': 300};
        } else if (p == 'feed') {
          final c = int.parse(q['cursor'] ?? '0');
          body = {'cursor': c, 'size': 100, 'total': 10000, 'rows': [for (var i = c; i < c + 100; i++) _row(i)], 'next': c + 100};
        } else if (p == 'countries') {
          body = [for (var i = 0; i < 200; i++) i == 130 ? 'Norway' : 'Country $i'];
        } else if (p == 'promos') {
          body = {'q': q['q'], 'items': [for (var i = 0; i < 8; i++) {'code': 'FIELD1$i', 'description': '$i % off'}]};
        } else if (p == 'search') {
          body = {'q': q['q'], 'items': [for (var i = 1; i <= 50; i++) _product(i)]};
        } else if (p == 'terms') {
          body = {'title': 'Terms and conditions', 'text': 'Terms. ' * 400};
        } else if (p == 'checkout') {
          body = {'order': 'FM-123456'};
        } else {
          return http.Response('not found', 404);
        }
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      });
}

void main() {
  testWidgets('every id of shared/ids.json is on its screen', (tester) async {
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ids = (jsonDecode(File('../shared/ids.json').readAsStringSync()) as List).cast<String>();
    final seen = <String>{};
    void collect() {
      void visit(Element e) {
        final k = e.widget.key;
        if (k is ValueKey && k.value is String && (k.value as String).startsWith('fm-')) seen.add(k.value as String);
        e.visitChildElements(visit);
      }
      tester.binding.rootElement?.visitChildElements(visit);
    }

    Future<void> pump([int frames = 8]) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      collect();
    }

    Future<void> tap(String id) async {
      final f = find.byKey(ValueKey(id)).last;
      await tester.ensureVisible(f);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(f);
      await pump();
    }

    Future<void> type(String id, String text) async {
      await tap(id);
      await tester.enterText(find.byKey(ValueKey(id)).last, text);
      await pump(5);
    }

    await tester.pumpWidget(FieldmartApp(settings: LaunchSettings.read(const [], const {}), telemetry: const _Fake()));
    await pump(12);
    // The horizontal lists build their items as they scroll.
    for (final (first, last) in [('fm-home-chip-0', 'fm-home-chip-11'), ('fm-home-deal-0', 'fm-home-deal-19')]) {
      final at = tester.getCenter(find.byKey(ValueKey(first)));
      for (var i = 0; i < 40 && find.byKey(ValueKey(last)).evaluate().isEmpty; i++) {
        await tester.dragFrom(at, const Offset(-200, 0));
        await pump(2);
      }
    }
    // Home, and product 17 with its reviews.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('fm-home-product-17')), 300,
        scrollable: find.descendant(of: find.byKey(const ValueKey('fm-home-grid')), matching: find.byType(Scrollable)).first);
    await tap('fm-home-product-17');
    await tap('fm-product-readmore');
    await tester.ensureVisible(find.byKey(const ValueKey('fm-product-helpful-r17-2')));
    await pump();
    await tap('fm-nav-back');
    // Search.
    await tap('fm-home-search');
    await tester.enterText(find.byKey(const ValueKey('fm-search-field')), 'trail');
    await pump(6);
    await tap('fm-nav-back');
    // Markets and its order book.
    await tap('fm-nav-markets');
    await tap('fm-markets-book-open');
    await tap('fm-markets-book-close');
    // Feed: row 5000 and the messages after it.
    await tap('fm-nav-feed');
    await type('fm-feed-goto-field', '5000');
    await tap('fm-feed-goto-go');
    await tester.drag(find.byKey(const ValueKey('fm-feed-list')), const Offset(0, -700));
    await pump();
    // Checkout, every control.
    await tap('fm-nav-checkout');
    await tap('fm-checkout-account');
    await tap('fm-checkout-gift');
    await type('fm-checkout-promo', 'FIELD1');
    await tap('fm-checkout-terms');
    await tap('fm-checkout-terms-agree');
    await tap('fm-checkout-menu');
    await tap('fm-checkout-menu-item-2');
    await tap('fm-checkout-edit');
    await tap('fm-checkout-edit-done');
    await tap('fm-checkout-place');
    // More and Diagnostics.
    await tap('fm-nav-more');
    await tap('fm-more-diag');
    await tap('fm-nav-back');

    final missing = ids.where((id) => !seen.contains(id)).toList();
    expect(missing, isEmpty, reason: 'ids not found by key: $missing');
    expect(tester.takeException(), isNull);
    // Stop the timers.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
