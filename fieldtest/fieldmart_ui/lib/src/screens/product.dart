import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../app.dart' show pageBar;
import '../data/models.dart';
import '../labels.dart';
import '../scope.dart';
import '../widgets/net_image.dart';

class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.productId});

  final int productId;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  ProductDetail? _detail;
  String? _error;
  final _gallery = PageController();
  int _galleryPage = 0;
  int _size = -1;
  int _colour = -1;
  int _quantity = 1;
  bool _expanded = false;
  final List<Review> _reviews = [];
  int _reviewPage = 0;
  bool _reviewsLoading = false;
  bool _reviewsDone = false;
  final Set<String> _helpful = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _gallery.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = Fieldmart.of(context).api;
    try {
      final detail = await api.product(widget.productId);
      if (mounted) setState(() => _detail = detail);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    unawaited(_loadReviews());
  }

  Future<void> _loadReviews() async {
    if (_reviewsLoading || _reviewsDone) return;
    _reviewsLoading = true;
    try {
      final page = await Fieldmart.of(context).api.reviews(widget.productId, page: _reviewPage);
      if (!mounted) return;
      setState(() {
        _reviews.addAll(page);
        _reviewPage++;
        _reviewsDone = page.length < 50;
      });
    } catch (_) {
      _reviewsDone = true;
    } finally {
      _reviewsLoading = false;
    }
  }

  void _add() {
    final scope = Fieldmart.of(context);
    final p = _detail?.product;
    scope.cart.add(widget.productId, p?.title ?? 'Product ${widget.productId}', p?.priceCents ?? 0, _quantity);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text(L.added),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final scope = Fieldmart.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final d = _detail;
    final p = d?.product;
    final images = (p?.imageCount ?? 8).clamp(1, 8);
    return Scaffold(
      appBar: pageBar(context, p?.brand ?? 'Product'),
      body: d == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : CustomScrollView(
              key: const ValueKey('fm-product-page'),
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: width,
                    child: Stack(children: [
                      PageView.builder(
                        key: const ValueKey('fm-product-gallery'),
                        controller: _gallery,
                        itemCount: images,
                        onPageChanged: (i) => setState(() => _galleryPage = i),
                        itemBuilder: (context, i) =>
                            NetImage(scope.api.productImage(widget.productId, i, 800), width: width, height: width),
                      ),
                      Positioned(
                        right: 12,
                        top: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: const Color(0x99000000), borderRadius: BorderRadius.circular(12)),
                          child: Text(L.galleryCounter(_galleryPage + 1, images),
                              style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 10,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          for (var i = 0; i < images; i++)
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _galleryPage ? Colors.white : const Color(0x88FFFFFF),
                              ),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                ),
                // The details are few: built at once, so every control exists.
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p!.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(p.brand, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Text(L.price(p.priceCents), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 12),
                      Stars(p.rating, size: 16),
                      const SizedBox(width: 4),
                      Text('${p.rating.toStringAsFixed(1)} (${p.reviewCount})'),
                    ]),
                    const SizedBox(height: 4),
                    Text(L.stock(d.stock),
                        style: TextStyle(color: d.stock > 0 ? const Color(0xFF1B8A3A) : const Color(0xFFC62828))),
                    const SizedBox(height: 16),
                    const Text(L.size, style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (var i = 0; i < d.sizes.length && i < 6; i++)
                        ChoiceChip(
                          key: ValueKey('fm-product-size-$i'),
                          label: Text(d.sizes[i]),
                          selected: _size == i,
                          onSelected: (_) => setState(() => _size = i),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    Row(children: [
                      const Text(L.colour, style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      if (_colour >= 0 && _colour < d.colours.length) Text(d.colours[_colour].name),
                    ]),
                    const SizedBox(height: 6),
                    Wrap(spacing: 10, children: [
                      for (var i = 0; i < d.colours.length && i < 8; i++)
                        InkWell(
                          key: ValueKey('fm-product-colour-$i'),
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _colour = i),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(d.colours[i].argb),
                              border: Border.all(
                                width: _colour == i ? 3 : 1,
                                color: _colour == i
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    Row(children: [
                      const Spacer(),
                      IconButton.outlined(
                        key: const ValueKey('fm-product-qty-minus'),
                        onPressed: _quantity > 1 ? () => setState(() => _quantity--) : null,
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(L.quantity(_quantity), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                      ),
                      IconButton.outlined(
                        key: const ValueKey('fm-product-qty-plus'),
                        onPressed: _quantity < 10 ? () => setState(() => _quantity++) : null,
                        icon: const Icon(Icons.add),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    const Text('Description', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(d.description, maxLines: _expanded ? null : 4,
                        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('fm-product-readmore'),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        child: Text(_expanded ? L.readLess : L.readMore),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(L.reviews, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 520,
                      child: _reviewsList(scope),
                    ),
                    const SizedBox(height: 80),
                  ])),
                ),
              ],
            ),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: FilledButton.icon(
                  key: const ValueKey('fm-product-add'),
                  onPressed: _add,
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text(L.add),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
              ),
            ),
    );
  }

  Widget _reviewsList(Fieldmart scope) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListView.builder(
          key: const ValueKey('fm-product-reviews'),
          itemCount: _reviews.length + (_reviewsDone ? 0 : 1),
          itemBuilder: (context, i) {
            if (i >= _reviews.length) {
              unawaited(_loadReviews());
              return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            }
            final r = _reviews[i];
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipOval(child: NetImage(scope.api.avatarImage(r.avatarId), width: 40, height: 40)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(r.author, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(r.date, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                    Stars(r.rating.toDouble(), size: 13),
                    const SizedBox(height: 4),
                    Text(r.text),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: ValueKey('fm-product-helpful-${r.id}'),
                        onPressed: () => setState(() => _helpful.contains(r.id) ? _helpful.remove(r.id) : _helpful.add(r.id)),
                        icon: Icon(_helpful.contains(r.id) ? Icons.thumb_up : Icons.thumb_up_outlined, size: 16),
                        label: const Text(L.helpful),
                      ),
                    ),
                  ]),
                ),
              ]),
            );
          },
        ),
      );
}
