import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => 'ApiException: $message';
}

/// The data API served by the gateway under `/fx/api/` (02-APP-SPEC.md §3.1),
/// and the picture URLs under `/fx/img/`.
class FieldmartApi {
  FieldmartApi({required String fixtures, required http.Client client})
      : base = fixtures.endsWith('/')
            ? fixtures.substring(0, fixtures.length - 1)
            : fixtures,
        _client = client;

  final String base;
  final http.Client _client;

  /// Data requests answered, for the Markets poll counter.
  int requests = 0;

  Uri _api(String path, [Map<String, String>? query]) =>
      Uri.parse('$base/api/$path').replace(queryParameters: query);

  Future<Object?> _get(String path, [Map<String, String>? query]) async {
    final response = await _client.get(_api(path, query));
    requests++;
    if (response.statusCode != 200) {
      throw ApiException('GET $path: ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<List<Product>> products({required int page, int size = 40, int? category}) async {
    final body = await _get('products', {
      'page': '$page',
      'size': '$size',
      if (category != null) 'category': '$category',
    });
    return [
      for (final p in listIn(body, ['products']))
        if (p is Map<String, Object?>) Product.fromJson(p),
    ];
  }

  Future<ProductDetail> product(int id) async {
    final body = await _get('products/$id');
    final map = body is Map<String, Object?>
        ? (body['product'] is Map<String, Object?>
            ? body['product'] as Map<String, Object?>
            : body)
        : <String, Object?>{};
    return ProductDetail.fromJson(map);
  }

  Future<List<Review>> reviews(int productId, {required int page, int size = 50}) async {
    final body = await _get('products/$productId/reviews', {'page': '$page', 'size': '$size'});
    return [
      for (final r in listIn(body, ['reviews']))
        if (r is Map<String, Object?>) Review.fromJson(r),
    ];
  }

  Future<List<Category>> categories() async {
    final body = await _get('categories');
    return [
      for (final c in listIn(body, ['categories']))
        if (c is Map<String, Object?>) Category.fromJson(c),
    ];
  }

  Future<List<Deal>> deals() async {
    final body = await _get('deals');
    return [
      for (final d in listIn(body, ['deals']))
        if (d is Map<String, Object?>) Deal.fromJson(d),
    ];
  }

  Future<List<FeedRow>> feed({required int cursor, int size = 100}) async {
    final body = await _get('feed', {'cursor': '$cursor', 'size': '$size'});
    return [
      for (final r in listIn(body, ['rows', 'feed']))
        FeedRow.fromJson(r is Map<String, Object?> ? r : const {}),
    ];
  }

  Future<List<HeroSlide>> hero() async {
    final body = await _get('hero');
    return [
      for (final h in listIn(body, ['slides']))
        if (h is Map<String, Object?>) HeroSlide.fromJson(h),
    ];
  }

  /// `{title, text}` for the terms dialog.
  Future<(String, String)> terms() async {
    final body = await _get('terms');
    final m = body is Map<String, Object?> ? body : const <String, Object?>{};
    return ('${m['title'] ?? ''}', '${m['text'] ?? ''}');
  }

  Future<List<MarketSymbol>> symbols() async {
    final body = await _get('symbols');
    final rows = listIn(body, ['symbols']);
    return [
      for (var i = 0; i < rows.length; i++)
        if (rows[i] is Map<String, Object?>)
          MarketSymbol.fromJson(rows[i] as Map<String, Object?>, i),
    ];
  }

  Future<List<Candle>> candles(String symbol, String timeframe) async {
    final body = await _get('candles', {'symbol': symbol, 'tf': timeframe});
    return [for (final c in listIn(body, ['candles'])) Candle.fromJson(c)];
  }

  /// `{ "n": <server tick>, "count": 300 }`
  Future<int> quotes(int since) async {
    final body = await _get('quotes', {'since': '$since'});
    return body is Map<String, Object?> && body['n'] is num ? (body['n'] as num).toInt() : since;
  }

  Future<List<Product>> search(String q) async {
    final body = await _get('search', {'q': q});
    return [
      for (final p in listIn(body, ['products']))
        if (p is Map<String, Object?>) Product.fromJson(p),
    ];
  }

  Future<List<Promo>> promos(String q) async {
    final body = await _get('promos', {'q': q});
    return [for (final p in listIn(body, ['promos', 'codes'])) Promo.fromJson(p)];
  }

  Future<List<String>> countries() async {
    final body = await _get('countries');
    return [
      for (final c in listIn(body, ['countries']))
        c is Map<String, Object?> ? '${pick(c, ['name', 'label'])}' : '$c',
    ];
  }

  /// `{ "order": "FM-<6 digits>" }`
  Future<String> checkout(Map<String, Object?> form) async {
    final response = await _client.post(_api('checkout'),
        headers: {'content-type': 'application/json'}, body: jsonEncode(form));
    requests++;
    if (response.statusCode != 200) {
      throw ApiException('POST checkout: ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body is Map<String, Object?> ? '${body['order']}' : '$body';
  }

  Future<int> fail500() async {
    final response = await _client.get(_api('fail/500'));
    requests++;
    return response.statusCode;
  }

  Future<int> slow(int ms) async {
    final response = await _client.get(_api('slow', {'ms': '$ms'}));
    requests++;
    return response.statusCode;
  }

  // ---- pictures -------------------------------------------------------------

  String productImage(int productId, int index, int size) =>
      '$base/img/p/$productId/$index/$size.jpg';

  String heroImage(int n) => '$base/img/hero/$n/1600.jpg';

  /// A picture path the data gives relative to `fmFixtures`.
  String relative(String path) => '$base/${path.startsWith('/') ? path.substring(1) : path}';

  String avatarImage(int id) => '$base/img/avatar/$id/96.jpg';

  String badgeImage(String name) => '$base/img/badge/$name.png';
}
