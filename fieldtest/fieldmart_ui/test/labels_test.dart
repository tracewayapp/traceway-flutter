// The app's fixed texts are shared/labels.json's, verbatim.
import 'dart:convert';
import 'dart:io';

import 'package:fieldmart_ui/src/labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final j = jsonDecode(File('../shared/labels.json').readAsStringSync()) as Map<String, Object?>;
  Object? at(String path) {
    Object? v = j;
    for (final k in path.split('.')) {
      v = (v as Map<String, Object?>)[k];
    }
    return v;
  }

  test('labels match shared/labels.json', () {
    final pairs = <String, Object>{
      'app.name': L.appName,
      'nav.home': L.navHome, 'nav.markets': L.navMarkets, 'nav.feed': L.navFeed,
      'nav.checkout': L.navCheckout, 'nav.more': L.navMore, 'nav.back': L.navBack,
      'home.title': L.homeTitle, 'home.search': L.homeSearch, 'home.deals': L.homeDeals,
      'home.grid': L.homeGrid, 'home.new': L.homeNew, 'home.sale': L.homeSale,
      'home.reviews': L.homeReviews(7).replaceAll('7', '{n}'),
      'product.galleryCounter': L.galleryCounter(3, 8).replaceFirst('3', '{i}').replaceFirst('8', '{total}'),
      'product.readMore': L.readMore, 'product.readLess': L.readLess, 'product.size': L.size,
      'product.colour': L.colour, 'product.quantity': L.quantity(7).replaceAll('7', '{n}'),
      'product.stock': L.stock(7).replaceAll('7', '{n}'), 'product.reviews': L.reviews,
      'product.helpful': L.helpful, 'product.add': L.add, 'product.added': L.added,
      'markets.title': L.marketsTitle, 'markets.polls': L.polls(7).replaceAll('7', '{n}'),
      'markets.timeframes': L.timeframes, 'markets.watchlist': L.watchlist, 'markets.orderBook': L.orderBook,
      'markets.openBook': L.openBook, 'markets.bids': L.bids, 'markets.asks': L.asks, 'markets.close': L.close,
      'feed.title': L.feedTitle, 'feed.jumpEnd': L.jumpEnd, 'feed.jumpStart': L.jumpStart, 'feed.goTo': L.goTo,
      'feed.go': L.go, 'feed.refresh': L.refresh, 'feed.header': L.week(7).replaceAll('7', '{n}'),
      'checkout.title': L.checkoutTitle, 'checkout.sections': L.sections, 'checkout.name': L.name,
      'checkout.email': L.email, 'checkout.phone': L.phone, 'checkout.account': L.account,
      'checkout.password': L.password, 'checkout.address': L.address, 'checkout.city': L.city,
      'checkout.postcode': L.postcode, 'checkout.country': L.country, 'checkout.countryPicker': L.countryPicker,
      'checkout.date': L.date, 'checkout.datePicker': L.datePicker, 'checkout.window': L.window,
      'checkout.windows': L.windows, 'checkout.door': L.door, 'checkout.gift': L.gift,
      'checkout.giftNote': L.giftNote, 'checkout.card': L.card, 'checkout.expiry': L.expiry, 'checkout.cvv': L.cvv,
      'checkout.cardName': L.cardName, 'checkout.saveCard': L.saveCard, 'checkout.tip': L.tip,
      'checkout.tipValue': L.tipValue(7).replaceAll('7', '{n}'), 'checkout.promo': L.promo,
      'checkout.summary': L.summary, 'checkout.loyalty': L.loyalty, 'checkout.terms': L.terms,
      'checkout.agree': L.agree, 'checkout.menu': L.menu, 'checkout.menuItems': L.menuItems,
      'checkout.edit': L.edit, 'checkout.done': L.done, 'checkout.rating': L.rating, 'checkout.notes': L.notes,
      'checkout.place': L.place, 'checkout.success': L.success,
      'checkout.successDetail': L.successDetail('{order}'),
      'search.title': L.searchTitle, 'search.field': L.searchField, 'search.recent': L.recent, 'search.empty': L.empty,
      'more.title': L.moreTitle, 'more.diagnostics': L.diagnostics,
      'diag.title': L.diagTitle, 'diag.run': L.diagRun, 'diag.variant': L.diagVariant,
      'diag.scenario': L.diagScenario, 'diag.build': L.diagBuild, 'diag.session': L.diagSession,
      'diag.buttons': L.diagButtons,
    };
    for (final e in pairs.entries) {
      expect(e.value, at(e.key), reason: e.key);
    }
  });

  test('prices are shown as \$<dollars>.<cents>', () {
    expect(L.price(10400), r'$104.00');
    expect(L.price(45849), r'$458.49');
    expect(L.price(5), r'$0.05');
  });
}
