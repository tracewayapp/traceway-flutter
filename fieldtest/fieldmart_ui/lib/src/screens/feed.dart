import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../labels.dart';
import '../scope.dart';
import '../widgets/net_image.dart';

const int _rows = 10000;
const int _perWeek = 50;
const int _pageSize = 100;
const double _headerExtent = 36;
const double _rowExtent = 88;

/// 10,000 mixed rows, virtualized. Every 50th row is a "Week N" header that
/// sticks to the top while its week scrolls by. Every other row is
/// [_rowExtent] tall except an expanded message, so any row's offset is
/// known before its page has loaded and "Go to row" lands exactly.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final _scroll = ScrollController();
  final _goto = TextEditingController();
  final Map<int, List<FeedRow>> _pages = {};
  final Set<int> _loading = {};
  final Map<int, double> _expanded = {};
  int _generation = 0;
  bool _refreshing = false;

  @override
  void dispose() {
    _scroll.dispose();
    _goto.dispose();
    super.dispose();
  }

  FeedRow? _row(int index) {
    final page = index ~/ _pageSize;
    final rows = _pages[page];
    if (rows == null) {
      unawaited(_load(page));
      return null;
    }
    final i = index - page * _pageSize;
    return i < rows.length ? rows[i] : null;
  }

  Future<void> _load(int page) async {
    if (_loading.contains(page)) return;
    _loading.add(page);
    final generation = _generation;
    try {
      final rows = await Fieldmart.of(context).api.feed(cursor: page * _pageSize, size: _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() => _pages[page] = rows);
    } catch (_) {
      // Shown as a placeholder row; scrolling past it asks again.
    } finally {
      _loading.remove(page);
    }
  }

  double _extent(int index) => _expanded[index] ?? _rowExtent;

  static const double _weekSpan = _headerExtent + (_perWeek - 1) * _rowExtent;

  /// The scroll offset that puts row [index] right under the pinned header
  /// of its week (a header row: at the top).
  double _offsetOf(int index) {
    final week = index ~/ _perWeek;
    final inWeek = index - week * _perWeek;
    var offset = week * _weekSpan + (inWeek == 0 ? 0 : (inWeek - 1) * _rowExtent);
    for (final e in _expanded.entries) {
      if (e.key < index) offset += e.value - _rowExtent;
    }
    return offset;
  }

  void _jumpTo(int index) {
    if (!_scroll.hasClients) return;
    final target = _offsetOf(index.clamp(0, _rows - 1));
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
  }

  void _jumpEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _generation++;
      _pages.clear();
      _loading.clear();
    });
    final first = _scroll.hasClients ? _indexAt(_scroll.offset) : 0;
    await _load(first ~/ _pageSize);
    if (mounted) setState(() => _refreshing = false);
  }

  int _indexAt(double offset) {
    final week = (offset / _weekSpan).floor().clamp(0, _rows ~/ _perWeek - 1);
    final inWeek = ((offset - week * _weekSpan) / _rowExtent).floor().clamp(0, _perWeek - 2);
    return week * _perWeek + 1 + inWeek;
  }

  void _toggle(int index, FeedRow row, double width) {
    setState(() {
      if (_expanded.containsKey(index)) {
        _expanded.remove(index);
      } else {
        final painter = TextPainter(
          text: TextSpan(text: row.lines.join('\n'), style: const TextStyle(fontSize: 14)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width - 16 * 2 - 56 - 12);
        _expanded[index] = (12 + 22 + painter.height + 12).clamp(_rowExtent, 600);
        painter.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final dense = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      textStyle: const TextStyle(fontSize: 13),
    );
    return Column(children: [
      Material(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Column(children: [
            Row(children: [
              const Expanded(child: Text(L.feedTitle, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
              IconButton(
                key: const ValueKey('fm-feed-refresh'),
                tooltip: L.refresh,
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
            ]),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
              TextButton(
                key: const ValueKey('fm-feed-jump-start'),
                style: dense,
                onPressed: () => _jumpTo(0),
                child: const Text(L.jumpStart),
              ),
              TextButton(
                key: const ValueKey('fm-feed-jump-end'),
                style: dense,
                onPressed: _jumpEnd,
                child: const Text(L.jumpEnd),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 140,
                child: TextField(
                  key: const ValueKey('fm-feed-goto-field'),
                  controller: _goto,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: L.goTo,
                  ),
                  onSubmitted: (v) => _jumpTo(int.tryParse(v) ?? 0),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                key: const ValueKey('fm-feed-goto-go'),
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  _jumpTo(int.tryParse(_goto.text.trim()) ?? 0);
                },
                child: const Text(L.go),
              ),
            ]),
          ]),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            key: const ValueKey('fm-feed-list'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              for (var week = 0; week < _rows ~/ _perWeek; week++)
                SliverMainAxisGroup(slivers: [
                  PinnedHeaderSliver(
                    child: _WeekHeader(
                      key: ValueKey('fm-feed-row-${week * _perWeek}'),
                      label: _row(week * _perWeek)?.label ?? L.week(week + 1),
                    ),
                  ),
                  SliverVariedExtentList.builder(
                    itemCount: _perWeek - 1,
                    itemExtentBuilder: (i, _) => _extent(week * _perWeek + 1 + i),
                    itemBuilder: (context, i) {
                      final index = week * _perWeek + 1 + i;
                      final row = _row(index);
                      return _FeedRowView(
                        key: ValueKey('fm-feed-row-$index'),
                        row: row,
                        expanded: _expanded.containsKey(index),
                        onTap: row != null && row.type == 'message' ? () => _toggle(index, row, width) : null,
                      );
                    },
                  ),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        height: _headerExtent,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
}

const _orderIcons = {
  'check': Icons.check_circle_outline,
  'box': Icons.inventory_2_outlined,
  'truck': Icons.local_shipping_outlined,
  'card': Icons.credit_card,
  'undo': Icons.undo,
};

class _FeedRowView extends StatelessWidget {
  const _FeedRowView({super.key, required this.row, required this.expanded, this.onTap});

  final FeedRow? row;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final api = Fieldmart.of(context).api;
    final scheme = Theme.of(context).colorScheme;
    final r = row;
    if (r == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Container(width: 40, height: 40, color: scheme.surfaceContainerHighest),
          const SizedBox(width: 12),
          Expanded(child: Container(height: 14, color: scheme.surfaceContainerHighest)),
        ]),
      );
    }
    const small = TextStyle(fontSize: 12, color: Colors.grey);
    final Widget leading;
    final Widget body;
    switch (r.type) {
      case 'shipment':
        leading = NetImage(api.productImage(r.productId, 0, 160), width: 56, height: 56, radius: 6);
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(r.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (r.progress / 100).clamp(0, 1)),
        ]);
      case 'alert':
        leading = CircleAvatar(child: Text(r.symbol.isEmpty ? '?' : r.symbol.substring(0, 1)));
        body = Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(r.time, style: small),
            ]),
          ),
          Sparkline(r.spark, width: 56, height: 22, up: r.changeBp >= 0),
          const SizedBox(width: 8),
          Text(L.price(r.priceCents)),
        ]);
      case 'message':
        leading = ClipOval(child: NetImage(api.avatarImage(r.avatarId), width: 40, height: 40));
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.label, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600))),
            Text(r.time, style: small),
          ]),
          Expanded(
            child: Text(r.lines.join('\n'),
                maxLines: expanded ? null : 2, overflow: expanded ? TextOverflow.clip : TextOverflow.ellipsis),
          ),
        ]);
      default:
        leading = CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(_orderIcons[r.icon] ?? Icons.receipt_long, color: scheme.onPrimaryContainer, size: 20),
        );
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(r.time, style: small),
        ]);
    }
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant, width: 0.5))),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 56, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(child: body),
        ]),
      ),
    );
  }
}
