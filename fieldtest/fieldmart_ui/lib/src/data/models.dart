/// The fixture data shapes of 02-APP-SPEC.md §3.1.
library;

int _int(Object? v, [int fallback = 0]) => switch (v) {
      final int i => i,
      final num n => n.round(),
      final String s => int.tryParse(s) ?? fallback,
      _ => fallback,
    };

double _double(Object? v, [double fallback = 0]) => switch (v) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s) ?? fallback,
      _ => fallback,
    };

String _str(Object? v, [String fallback = '']) => v == null ? fallback : '$v';

List<String> _strings(Object? v) =>
    v is List ? [for (final e in v) '$e'] : const [];

/// The first of [keys] present in [m].
Object? pick(Map<String, Object?> m, List<String> keys) {
  for (final k in keys) {
    if (m.containsKey(k)) return m[k];
  }
  return null;
}

/// The list in a response: the body itself, or its `items`/`data`/... field.
List<Object?> listIn(Object? body, [List<String> keys = const []]) {
  if (body is List) return body;
  if (body is Map<String, Object?>) {
    for (final k in [...keys, 'items', 'data', 'rows', 'results']) {
      final v = body[k];
      if (v is List) return v;
    }
  }
  return const [];
}

class Product {
  Product({
    required this.id,
    required this.title,
    required this.brand,
    required this.categoryId,
    required this.priceCents,
    required this.compareAtCents,
    required this.rating,
    required this.reviewCount,
    required this.badges,
    required this.imageCount,
  });

  factory Product.fromJson(Map<String, Object?> j) => Product(
        id: _int(j['id']),
        title: _str(j['title']),
        brand: _str(j['brand']),
        categoryId: _int(j['categoryId']),
        priceCents: _int(j['priceCents']),
        compareAtCents: j['compareAtCents'] == null ? null : _int(j['compareAtCents']),
        rating: _double(j['rating']),
        reviewCount: _int(j['reviewCount']),
        badges: _strings(j['badges']),
        imageCount: _int(j['imageCount'], 1),
      );

  final int id;
  final String title;
  final String brand;
  final int categoryId;
  final int priceCents;
  final int? compareAtCents;
  final double rating;
  final int reviewCount;
  final List<String> badges;
  final int imageCount;
}

class ProductDetail {
  ProductDetail({
    required this.product,
    required this.description,
    required this.sizes,
    required this.colours,
    required this.stock,
  });

  factory ProductDetail.fromJson(Map<String, Object?> j) => ProductDetail(
        product: Product.fromJson(j),
        description: _str(j['description']),
        sizes: _strings(j['sizes']),
        colours: [
          for (final c in (pick(j, ['colours', 'colors']) as List?) ?? const [])
            c is Map<String, Object?> ? Colour(_str(c['name']), _str(c['hex'], '#888888')) : Colour('$c', '#888888'),
        ],
        stock: _int(j['stock']),
      );

  final Product product;
  final String description;
  final List<String> sizes;
  final List<Colour> colours;
  final int stock;
}

class Colour {
  Colour(this.name, this.hex);
  final String name;
  final String hex;

  int get argb => 0xFF000000 | (int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x888888);
}

class Review {
  Review({
    required this.id,
    required this.author,
    required this.avatarId,
    required this.date,
    required this.rating,
    required this.text,
  });

  factory Review.fromJson(Map<String, Object?> j) => Review(
        id: _str(j['id']),
        author: _str(j['author']),
        avatarId: _int(j['avatarId'], 1),
        date: _str(j['date']),
        rating: _int(j['rating']),
        text: _str(j['text']),
      );

  final String id;
  final String author;
  final int avatarId;
  final String date;
  final int rating;
  final String text;
}

class Category {
  Category(this.id, this.name);

  factory Category.fromJson(Map<String, Object?> j) =>
      Category(_int(j['id']), _str(pick(j, ['name', 'title', 'label'])));

  final int id;
  final String name;
}

class Deal {
  Deal(this.productId, this.percent, this.badge);

  factory Deal.fromJson(Map<String, Object?> j) => Deal(
        _int(pick(j, ['productId', 'id'])),
        _int(pick(j, ['pct', 'percent', 'discountPercent'])),
        _str(j['badge'], 'sale'),
      );

  final int productId;
  final int percent;

  /// Names `/fx/img/badge/<badge>.png`.
  final String badge;
}

class HeroSlide {
  HeroSlide(this.id, this.title, this.subtitle, this.image);

  factory HeroSlide.fromJson(Map<String, Object?> j) =>
      HeroSlide(_int(j['id'], 1), _str(j['title']), _str(j['subtitle']), _str(j['image']));

  final int id;
  final String title;
  final String subtitle;

  /// Relative to `fmFixtures`.
  final String image;
}

/// One row of the 10,000-row feed: `header`, `order`, `shipment`, `alert` or
/// `message`; [label] is the row's main text. The index is the position.
class FeedRow {
  FeedRow(this.raw);

  factory FeedRow.fromJson(Map<String, Object?> j) => FeedRow(j);

  final Map<String, Object?> raw;

  String get type => _str(raw['type'], 'order');
  String get label => _str(raw['label']);
  String get time => _str(raw['time']);
  String get icon => _str(raw['icon']);
  String get detail => _str(raw['detail']);
  int get productId => _int(raw['productId'], 1);
  int get progress => _int(raw['progress']);
  String get symbol => _str(raw['symbol']);
  int get priceCents => _int(raw['priceCents']);
  int get changeBp => _int(raw['changeBp']);
  List<int> get spark => [for (final v in (raw['spark'] as List?) ?? const []) _int(v)];
  String get from => _str(raw['from']);
  int get avatarId => _int(raw['avatarId'], 1);
  List<String> get lines => _strings(raw['lines']);
}

class MarketSymbol {
  MarketSymbol({
    required this.symbol,
    required this.name,
    required this.seedIndex,
    required this.startCents,
  });

  factory MarketSymbol.fromJson(Map<String, Object?> j, int index) =>
      MarketSymbol(
        symbol: _str(j['symbol']),
        name: _str(j['name']),
        seedIndex: _int(j['seedIndex'], index),
        startCents: _int(j['startCents'], 10000),
      );

  final String symbol;
  final String name;
  final int seedIndex;
  final int startCents;
}

/// `[t, o, h, l, c]` in cents.
class Candle {
  Candle(this.t, this.o, this.h, this.l, this.c);

  factory Candle.fromJson(Object? v) {
    if (v is List && v.length >= 5) {
      return Candle(_int(v[0]), _int(v[1]), _int(v[2]), _int(v[3]), _int(v[4]));
    }
    if (v is Map<String, Object?>) {
      return Candle(_int(v['t']), _int(v['o']), _int(v['h']), _int(v['l']),
          _int(v['c']));
    }
    return Candle(0, 0, 0, 0, 0);
  }

  int t, o, h, l, c;
}

class Promo {
  Promo(this.code, this.description);

  factory Promo.fromJson(Object? v) => v is Map<String, Object?>
      ? Promo(_str(v['code']), _str(pick(v, ['description', 'label'])))
      : Promo('$v', '');

  final String code;
  final String description;
}
