import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../app.dart' show pageBar;
import '../data/models.dart';
import '../labels.dart';
import '../scope.dart';
import '../widgets/net_image.dart';

/// Recent searches outlive the page, as an app keeps them.
final List<String> _recent = ['boots', 'lamp', 'tent'];

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  Timer? _debounce;
  List<Product> _results = const [];
  String _query = '';
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _field.addListener(_onText);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onText() {
    final q = _field.text.trim();
    if (q == _query) return;
    _query = q;
    _debounce?.cancel();
    // 250 ms after the last keystroke.
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await Fieldmart.of(context).api.search(q);
      if (!mounted || q != _query) return;
      setState(() {
        _searched = true;
        _results = results.take(50).toList();
        _recent.remove(q);
        _recent.insert(0, q);
        if (_recent.length > 6) _recent.removeLast();
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = Fieldmart.of(context).api;
    return Scaffold(
      appBar: pageBar(context, L.searchTitle),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const ValueKey('fm-search-field'),
            controller: _field,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: L.searchField,
              border: const OutlineInputBorder(),
              suffixIcon: _loading
                  ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(alignment: Alignment.centerLeft, child: Text(L.recent, style: TextStyle(fontSize: 12))),
        ),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _recent.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => ActionChip(
              key: ValueKey('fm-search-recent-$i'),
              avatar: const Icon(Icons.history, size: 16),
              label: Text(_recent[i]),
              onPressed: () {
                _field.text = _recent[i];
                _field.selection = TextSelection.collapsed(offset: _field.text.length);
              },
            ),
          ),
        ),
        if (_searched && _results.isEmpty && !_loading) const Padding(padding: EdgeInsets.all(24), child: Text(L.empty)),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('fm-search-results'),
            itemCount: _results.length,
            itemExtent: 76,
            itemBuilder: (context, i) {
              final p = _results[i];
              return ListTile(
                key: ValueKey('fm-search-result-$i'),
                leading: NetImage(api.productImage(p.id, 0, 160), width: 56, height: 56, radius: 6),
                title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${p.brand} · ${L.price(p.priceCents)}'),
                onTap: () => Navigator.of(context).pushNamed('/product/${p.id}'),
              );
            },
          ),
        ),
      ]),
    );
  }
}
