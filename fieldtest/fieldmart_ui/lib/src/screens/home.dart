import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show ValueListenable;

import '../data/models.dart';
import '../labels.dart';
import '../markers.dart';
import '../scope.dart';
import '../widgets/net_image.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ScrollController();
  final _hero = PageController();
  Timer? _heroTimer;
  int _heroPage = 0;

  List<HeroSlide> _heroes = const [];
  List<Category> _categories = const [];
  List<Deal> _deals = const [];
  final Map<int, Product> _dealProducts = {};
  final List<Product> _products = [];
  int? _category;
  int _nextPage = 0;
  bool _loading = false;
  bool _exhausted = false;
  int _generation = 0;
  bool _replace = false;
  String? _error;

  // FM_FULLY: the pictures of Home's first screen at the phone size: the
  // first hero slide, the first two deal cards and the first grid row. (The
  // spec's "first eight grid pictures" are not built at 412 x 892 until the
  // grid is scrolled.)
  final Set<String> _decoded = {};
  bool _fully = false;

  ValueListenable<TickerModeData>? _ticker;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_loadTop());
    unawaited(_loadPage());
    _heroTimer = Timer.periodic(const Duration(seconds: 4), (_) => _advanceHero());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticker = TickerMode.getValuesNotifier(context);
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _scroll.dispose();
    _hero.dispose();
    super.dispose();
  }

  void _advanceHero() {
    if (!mounted || !(_ticker?.value.enabled ?? true) || !_hero.hasClients) return;
    _hero.nextPage(duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
  }

  Future<void> _loadTop() async {
    final api = Fieldmart.of(context).api;
    try {
      final results = await Future.wait([api.hero(), api.categories(), api.deals()]);
      final deals = results[2] as List<Deal>;
      if (!mounted) return;
      setState(() {
        _heroes = results[0] as List<HeroSlide>;
        _categories = results[1] as List<Category>;
        _deals = deals;
      });
      // The deals list names products: load the cards' products.
      for (final d in deals) {
        unawaited(api.product(d.productId).then((p) {
          if (mounted) setState(() => _dealProducts[d.productId] = p.product);
        }, onError: (Object _) {}));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadPage() async {
    if (_loading || _exhausted) return;
    _loading = true;
    final generation = _generation;
    final api = Fieldmart.of(context).api;
    try {
      final page = await api.products(page: _nextPage, category: _category);
      if (!mounted || generation != _generation) return;
      final replaced = _replace;
      setState(() {
        if (_replace) _products.clear();
        _replace = false;
        _products.addAll(page);
        _nextPage++;
        _exhausted = page.isEmpty || _products.length >= 2000;
      });
      if (replaced) WidgetsBinding.instance.addPostFrameCallback((_) => _showResults());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  void _onScroll() {
    final p = _scroll.position;
    if (p.maxScrollExtent - p.pixels < 1600) unawaited(_loadPage());
  }

  /// The filtered grid comes up: the chips at the top, the first results
  /// under the deals.
  void _showResults() {
    if (!mounted || !_scroll.hasClients) return;
    final chipsTop = MediaQuery.sizeOf(context).width * 9 / 16 + 24;
    _scroll.animateTo(chipsTop.clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  void _selectCategory(int? id) {
    setState(() {
      _category = _category == id ? null : id;
      // The old results stay until the new ones arrive.
      _replace = true;
      _nextPage = 0;
      _exhausted = false;
      _loading = false;
      _generation++;
    });
    unawaited(_loadPage());
  }

  void _decodedOne(String key) {
    if (_fully || !_decoded.add(key)) return;
    const need = {'hero-0', 'deal-0', 'deal-1', 'grid-0', 'grid-1'};
    if (_decoded.containsAll(need)) {
      _fully = true;
      Markers.mark('FM_FULLY');
      Fieldmart.of(context).telemetry.fullyDisplayed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = Fieldmart.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return Column(children: [
      _TopBar(
        onLogo: () => _scroll.animateTo(0,
            duration: const Duration(milliseconds: 600), curve: Curves.easeOutCubic),
        onSearch: () => Navigator.of(context).pushNamed('/search'),
        onCart: () => scope.tabs.select('checkout'),
      ),
      Expanded(
        child: CustomScrollView(
          key: const ValueKey('fm-home-grid'),
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _heroCarousel(scope, width)),
            SliverToBoxAdapter(child: _chips()),
            SliverToBoxAdapter(child: _dealsRow(scope)),
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(L.homeGrid, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: width >= 900 ? 4 : 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.62,
                ),
                itemCount: _products.length,
                itemBuilder: (context, i) => _ProductCell(
                  product: _products[i],
                  width: (width - 24 - 10 * ((width >= 900 ? 4 : 2) - 1)) / (width >= 900 ? 4 : 2),
                  onDecoded: i < 2 ? () => _decodedOne('grid-$i') : null,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: _error != null
                      ? Text('Could not load: $_error', textAlign: TextAlign.center)
                      : _exhausted
                          ? const Text('That is everything')
                          : const CircularProgressIndicator(),
                ),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _heroCarousel(Fieldmart scope, double width) {
    final height = width * 9 / 16;
    return SizedBox(
      height: height + 24,
      child: Column(children: [
        SizedBox(
          height: height,
          child: PageView.builder(
            key: const ValueKey('fm-home-hero'),
            controller: _hero,
            onPageChanged: (p) => setState(() => _heroPage = p),
            itemBuilder: (context, page) {
              if (_heroes.isEmpty) return Container(color: Theme.of(context).colorScheme.surfaceContainerHighest);
              final i = page % _heroes.length;
              final slide = _heroes[i];
              final (line1, line2) = (slide.title, slide.subtitle);
              return Stack(fit: StackFit.expand, children: [
                NetImage(scope.api.relative(slide.image),
                    width: width, height: height, onDecoded: i == 0 ? () => _decodedOne('hero-0') : null),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xAA000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(line1,
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                    Text(line2, style: const TextStyle(color: Colors.white, fontSize: 14)),
                  ]),
                ),
              ]);
            },
          ),
        ),
        SizedBox(
          height: 24,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < 8; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: _heroPage % 8 == i ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: _heroPage % 8 == i
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _chips() => SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: _categories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final c = _categories[i];
            return ChoiceChip(
              key: ValueKey('fm-home-chip-$i'),
              label: Text(c.name),
              selected: _category == c.id,
              onSelected: (_) => _selectCategory(c.id),
            );
          },
        ),
      );

  Widget _dealsRow(Fieldmart scope) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(L.homeDeals, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: 250,
          child: ListView.builder(
            key: const ValueKey('fm-home-deals'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _deals.length,
            itemBuilder: (context, i) => _DealCard(
              key: ValueKey('fm-home-deal-$i'),
              deal: _deals[i],
              product: _dealProducts[_deals[i].productId],
              onDecoded: i < 2 ? () => _decodedOne('deal-$i') : null,
            ),
          ),
        ),
      ]);
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onLogo, required this.onSearch, required this.onCart});

  final VoidCallback onLogo;
  final VoidCallback onSearch;
  final VoidCallback onCart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cart = Fieldmart.of(context).cart;
    return Material(
      color: scheme.surface,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(children: [
          InkWell(
            key: const ValueKey('fm-home-logo'),
            onTap: onLogo,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(children: [
                Icon(Icons.landscape, color: scheme.primary),
                const SizedBox(width: 4),
                Text(L.homeTitle,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: scheme.primary)),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              key: const ValueKey('fm-home-search'),
              onTap: onSearch,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(children: [
                  Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(L.homeSearch,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ]),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: cart,
            builder: (context, _) => IconButton(
              key: const ValueKey('fm-home-cart'),
              onPressed: onCart,
              icon: Badge(label: Text('${cart.count}'), child: const Icon(Icons.shopping_bag_outlined)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ProductCell extends StatelessWidget {
  const _ProductCell({required this.product, required this.width, this.onDecoded});

  final Product product;
  final double width;
  final VoidCallback? onDecoded;

  @override
  Widget build(BuildContext context) {
    final api = Fieldmart.of(context).api;
    final p = product;
    final badge = p.badges.isEmpty ? null : p.badges.first;
    return Card(
      key: ValueKey('fm-home-product-${p.id}'),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed('/product/${p.id}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            NetImage(api.productImage(p.id, 0, 320), width: width, height: width, onDecoded: onDecoded),
            if (badge != null)
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badge.toLowerCase() == 'sale' ? const Color(0xFFC62828) : const Color(0xFF1565C0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(badge.toLowerCase() == 'sale' ? L.homeSale : badge.toLowerCase() == 'new' ? L.homeNew : badge,
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(children: [
              Text(L.price(p.priceCents), style: const TextStyle(fontWeight: FontWeight.w700)),
              if (p.compareAtCents != null && p.compareAtCents! > p.priceCents) ...[
                const SizedBox(width: 6),
                Text(L.price(p.compareAtCents!),
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey, decoration: TextDecoration.lineThrough)),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(children: [
              Stars(p.rating, size: 13),
              const SizedBox(width: 4),
              Text(L.homeReviews(p.reviewCount), style: const TextStyle(fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _DealCard extends StatelessWidget {
  const _DealCard({super.key, required this.deal, required this.product, this.onDecoded});

  final Deal deal;
  final Product? product;
  final VoidCallback? onDecoded;

  @override
  Widget build(BuildContext context) {
    final api = Fieldmart.of(context).api;
    const width = 150.0;
    final p = product;
    return Container(
      width: width,
      margin: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed('/product/${deal.productId}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            NetImage(api.productImage(deal.productId, 0, 320), width: width, height: width, radius: 8, onDecoded: onDecoded),
            Positioned(
              right: 4,
              top: 4,
              // The percentage badge: a PNG with transparency.
              child: NetImage(api.badgeImage(deal.badge), width: 44, height: 44, fit: BoxFit.contain),
            ),
          ]),
          const SizedBox(height: 6),
          Text(p?.title ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          if (p != null)
            Wrap(spacing: 6, children: [
              Text(L.price(p.priceCents), style: const TextStyle(fontWeight: FontWeight.w700)),
              if (p.compareAtCents != null)
                Text(L.price(p.compareAtCents!),
                    style: const TextStyle(fontSize: 12, color: Colors.grey, decoration: TextDecoration.lineThrough)),
            ]),
        ]),
      ),
    );
  }
}
