import 'dart:async';
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show ValueListenable;

import '../data/models.dart';
import '../labels.dart';
import '../prng.dart';
import '../scope.dart';
import '../widgets/net_image.dart';

const _timeframes = L.timeframes;
const _tickMs = 100;
const _ticksPerCandle = 50; // a new candle every 5 s
const _roundRobin = 30;
const _visibleCandles = 80;

/// The live market state: every symbol's price follows the shared tick
/// model (02-APP-SPEC.md §3.4). Tick n happens n × 100 ms after the screen
/// first appeared; ticks missed while it was hidden are caught up on return.
class _Market extends ChangeNotifier {
  _Market(this.symbols)
      : models = [for (final s in symbols) TickModel(s.seedIndex, s.startCents)],
        history = [for (final s in symbols) <int>[s.startCents]];

  final List<MarketSymbol> symbols;
  final List<TickModel> models;
  final List<List<int>> history;
  int selected = 0;

  /// Ticks applied so far (tick n is the (n+1)-th).
  int ticks = 0;
  int lastDirection = 0;

  List<Candle> candles = const [];
  int _candleBaseClose = 0;
  int _candleBaseCents = 1;
  int _ticksInCandle = 0;

  void setCandles(List<Candle> c) {
    candles = c;
    _ticksInCandle = 0;
    if (c.isNotEmpty) {
      _candleBaseClose = c.last.c;
      _candleBaseCents = models[selected].cents;
    }
    notifyListeners();
  }

  /// Applies ticks up to [target] (exclusive count) and notifies once.
  void advanceTo(int target) {
    if (target <= ticks) return;
    while (ticks < target) {
      final n = ticks;
      final sel = models[selected];
      final before = sel.cents;
      sel.advanceTo(n + 1);
      lastDirection = sel.cents.compareTo(before);
      _record(selected);
      for (var j = 0; j < _roundRobin; j++) {
        final k = (n * _roundRobin + j) % models.length;
        if (k == selected) continue;
        models[k].advanceTo(n + 1);
        _record(k);
      }
      _candleTick();
      ticks++;
    }
    notifyListeners();
  }

  void _record(int k) {
    final h = history[k];
    h.add(models[k].cents);
    if (h.length > 24) h.removeAt(0);
    // A new list so the sparkline painter repaints.
    history[k] = List<int>.of(h);
  }

  void _candleTick() {
    if (candles.isEmpty) return;
    final price = _candleBaseCents == 0
        ? models[selected].cents
        : (_candleBaseClose * models[selected].cents / _candleBaseCents).round();
    _ticksInCandle++;
    if (_ticksInCandle >= _ticksPerCandle) {
      _ticksInCandle = 0;
      final last = candles.last;
      final step = candles.length > 1 ? candles.last.t - candles[candles.length - 2].t : 60;
      candles.removeAt(0);
      candles.add(Candle(last.t + step, last.c, math.max(last.c, price), math.min(last.c, price), price));
      return;
    }
    final last = candles.last
      ..c = price
      ..h = math.max(candles.last.h, price)
      ..l = math.min(candles.last.l, price);
    candles[candles.length - 1] = last;
  }
}

class MarketsScreen extends StatefulWidget {
  const MarketsScreen({super.key});

  @override
  State<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends State<MarketsScreen> {
  final _clock = Stopwatch();
  _Market? _market;
  String _tf = '1H';
  String? _error;
  Timer? _ticker;
  Timer? _poll;
  int _polls = 0;
  int _serverTick = 0;
  double? _crosshairX;
  ValueListenable<TickerModeData>? _visible;

  @override
  void initState() {
    super.initState();
    _clock.start();
    unawaited(_load());
    _ticker = Timer.periodic(const Duration(milliseconds: _tickMs), (_) => _onTimer());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _onPoll());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.getValuesNotifier(context);
  }

  bool get _isVisible => _visible?.value.enabled ?? true;

  @override
  void dispose() {
    _ticker?.cancel();
    _poll?.cancel();
    _market?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = Fieldmart.of(context).api;
    try {
      final symbols = await api.symbols();
      if (!mounted || symbols.isEmpty) return;
      setState(() => _market = _Market(symbols));
      await _loadCandles(_tf);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadCandles(String tf) async {
    final market = _market;
    if (market == null) return;
    final candles = await Fieldmart.of(context).api.candles(market.symbols[market.selected].symbol, tf);
    if (!mounted || tf != _tf) return;
    market.setCandles(candles);
  }

  void _onTimer() {
    final market = _market;
    if (market == null || !_isVisible) return;
    market.advanceTo(_clock.elapsedMilliseconds ~/ _tickMs);
  }

  Future<void> _onPoll() async {
    if (!_isVisible || !mounted) return;
    try {
      _serverTick = await Fieldmart.of(context).api.quotes(_serverTick);
      if (mounted) setState(() => _polls++);
    } catch (_) {}
  }

  void _openBook() {
    final market = _market;
    if (market == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _OrderBook(market: market),
    );
  }

  @override
  Widget build(BuildContext context) {
    final market = _market;
    if (market == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
        child: Row(children: [
          const Expanded(child: Text(L.marketsTitle, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
          Text(L.polls(_polls), style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          TextButton.icon(
            key: const ValueKey('fm-markets-book-open'),
            onPressed: _openBook,
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text(L.openBook),
          ),
        ]),
      ),
      ListenableBuilder(listenable: market, builder: (context, _) => _header(market)),
      SizedBox(height: 210, child: _chart(market)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            for (final tf in _timeframes)
              ButtonSegment(value: tf, label: Text(tf, key: ValueKey('fm-markets-tf-$tf'))),
          ],
          selected: {_tf},
          onSelectionChanged: (s) {
            setState(() => _tf = s.first);
            unawaited(_loadCandles(s.first));
          },
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(children: [
          Expanded(child: Text(L.watchlist, style: TextStyle(fontWeight: FontWeight.w700))),
          Text('Price', style: TextStyle(fontSize: 12)),
          SizedBox(width: 56, child: Text('Change', textAlign: TextAlign.right, style: TextStyle(fontSize: 12))),
        ]),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: market,
          builder: (context, _) => ListView.builder(
            key: const ValueKey('fm-markets-watchlist'),
            itemExtent: 56,
            itemCount: market.symbols.length,
            itemBuilder: (context, k) => _WatchRow(market: market, k: k),
          ),
        ),
      ),
    ]);
  }

  Widget _header(_Market market) {
    final s = market.symbols[market.selected];
    final cents = market.models[market.selected].cents;
    final change = (cents - s.startCents) * 10000 ~/ (s.startCents == 0 ? 1 : s.startCents);
    final up = change >= 0;
    final flash = market.lastDirection > 0
        ? const Color(0x331B8A3A)
        : market.lastDirection < 0
            ? const Color(0x33C62828)
            : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.symbol, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: flash, borderRadius: BorderRadius.circular(4)),
            child: Text(L.price(cents),
                key: const ValueKey('fm-markets-price'),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          Text('${up ? '+' : '-'}${formatCents(change.abs())}%',
              style: TextStyle(fontSize: 12, color: up ? const Color(0xFF1B8A3A) : const Color(0xFFC62828))),
        ]),
      ]),
    );
  }

  Widget _chart(_Market market) => LayoutBuilder(builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          key: const ValueKey('fm-markets-chart'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => setState(() => _crosshairX = d.localPosition.dx),
          onPanUpdate: (d) => setState(() => _crosshairX = d.localPosition.dx.clamp(0, size.width - 56)),
          onPanEnd: (_) => setState(() => _crosshairX = null),
          onPanCancel: () => setState(() => _crosshairX = null),
          child: ListenableBuilder(
            listenable: market,
            builder: (context, _) => Stack(children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ChartPainter(market, _crosshairX, Theme.of(context).colorScheme),
                ),
              ),
              ..._axisLabels(market, size),
              if (_crosshairX != null) _tooltip(market, size),
            ]),
          ),
        );
      });

  /// The window of candles the chart shows, and its price range.
  static (List<Candle>, int, int) _window(_Market market) {
    final c = market.candles;
    final w = c.length <= _visibleCandles ? c : c.sublist(c.length - _visibleCandles);
    var lo = 1 << 62, hi = -1;
    for (final k in w) {
      lo = math.min(lo, k.l);
      hi = math.max(hi, k.h);
    }
    if (hi <= lo) hi = lo + 1;
    return (w, lo, hi);
  }

  List<Widget> _axisLabels(_Market market, Size size) {
    if (market.candles.isEmpty) return const [];
    final (_, lo, hi) = _window(market);
    const style = TextStyle(fontSize: 10, color: Colors.grey);
    final chartH = size.height - 18;
    final labels = <Widget>[
      for (var i = 0; i <= 3; i++)
        Positioned(
          right: 4,
          top: 4 + (chartH - 8) * i / 3 - 6,
          child: Text(L.price(hi - (hi - lo) * i ~/ 3), style: style),
        ),
    ];
    final last = market.candles.last.c;
    final y = 4 + (chartH - 8) * (hi - last) / (hi - lo);
    labels.add(Positioned(
      right: 0,
      top: y.clamp(0, chartH) - 9,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: Theme.of(context).colorScheme.primary,
        child: Text(L.price(last), style: const TextStyle(fontSize: 11, color: Colors.white)),
      ),
    ));
    final (w, _, _) = _window(market);
    for (var i = 0; i < 4; i++) {
      final idx = (w.length - 1) * i ~/ 3;
      labels.add(Positioned(
        left: 4 + (size.width - 60) * i / 3,
        bottom: 2,
        child: Text(_date(w[idx].t, _tf), style: style),
      ));
    }
    return labels;
  }

  Widget _tooltip(_Market market, Size size) {
    final (w, _, _) = _window(market);
    final x = _crosshairX!;
    final slot = (size.width - 56) / w.length;
    final i = (x / slot).floor().clamp(0, w.length - 1);
    final k = w[i];
    return Positioned(
      left: x < size.width / 2 ? x + 8 : x - 136,
      top: 6,
      child: Container(
        width: 128,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: DefaultTextStyle(
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onInverseSurface),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_date(k.t, _tf, full: true)),
            Text('O ${L.price(k.o)}'),
            Text('H ${L.price(k.h)}'),
            Text('L ${L.price(k.l)}'),
            Text('C ${L.price(k.c)}'),
          ]),
        ),
      ),
    );
  }

  static String _date(int t, String tf, {bool full = false}) {
    // Candle times are seconds (or milliseconds) since the epoch, in UTC.
    final ms = t > 100000000000 ? t : t * 1000;
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${d.year}-${two(d.month)}-${two(d.day)}';
    final time = '${two(d.hour)}:${two(d.minute)}';
    if (full) return '$date $time';
    return tf == '1H' || tf == '1D' ? time : date.substring(2);
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.market, this.crosshairX, this.scheme) : super(repaint: market);

  final _Market market;
  final double? crosshairX;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final (w, lo, hi) = _MarketsScreenState._window(market);
    if (w.isEmpty) return;
    final chartW = size.width - 56;
    final chartH = size.height - 18;
    final grid = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 0.5;
    for (var i = 0; i <= 3; i++) {
      final y = 4 + (chartH - 8) * i / 3;
      canvas.drawLine(Offset(0, y), Offset(chartW, y), grid);
    }
    double yOf(int cents) => 4 + (chartH - 8) * (hi - cents) / (hi - lo);
    final slot = chartW / w.length;
    final up = Paint()..color = const Color(0xFF1B8A3A);
    final down = Paint()..color = const Color(0xFFC62828);
    for (var i = 0; i < w.length; i++) {
      final k = w[i];
      final paint = k.c >= k.o ? up : down;
      final cx = slot * i + slot / 2;
      canvas.drawLine(Offset(cx, yOf(k.h)), Offset(cx, yOf(k.l)), paint..strokeWidth = 1);
      final top = yOf(math.max(k.o, k.c));
      final bottom = yOf(math.min(k.o, k.c));
      canvas.drawRect(Rect.fromLTRB(cx - slot * 0.35, top, cx + slot * 0.35, math.max(bottom, top + 1)), paint);
    }
    final lastY = yOf(w.last.c);
    canvas.drawLine(
        Offset(0, lastY),
        Offset(chartW, lastY),
        Paint()
          ..color = scheme.primary
          ..strokeWidth = 0.8);
    if (crosshairX != null) {
      canvas.drawLine(
          Offset(crosshairX!, 0),
          Offset(crosshairX!, chartH),
          Paint()
            ..color = scheme.onSurface
            ..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) => true;
}

class _WatchRow extends StatelessWidget {
  const _WatchRow({required this.market, required this.k});

  final _Market market;
  final int k;

  @override
  Widget build(BuildContext context) {
    final s = market.symbols[k];
    final cents = market.models[k].cents;
    final change = (cents - s.startCents) * 10000 ~/ (s.startCents == 0 ? 1 : s.startCents);
    final up = change >= 0;
    return InkWell(
      key: ValueKey('fm-markets-row-${s.symbol}'),
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SizedBox(
            width: 120,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.symbol, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
            ]),
          ),
          const SizedBox(width: 8),
          Sparkline(market.history[k], width: 70, height: 24, up: up),
          const Spacer(),
          Text(L.price(cents), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          SizedBox(
            width: 64,
            child: Text('${up ? '+' : '-'}${formatCents(change.abs())}%',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: up ? const Color(0xFF1B8A3A) : const Color(0xFFC62828))),
          ),
        ]),
      ),
    );
  }
}

/// 20 bids and 20 asks around the price; every size changes 5 times a
/// second.
class _OrderBook extends StatefulWidget {
  const _OrderBook({required this.market});

  final _Market market;

  @override
  State<_OrderBook> createState() => _OrderBookState();
}

class _OrderBookState extends State<_OrderBook> {
  final _random = FmRandom(fmTickSeed ^ 0x00B00C);
  late List<int> _bids = _sizes();
  late List<int> _asks = _sizes();
  Timer? _timer;

  List<int> _sizes() => [for (var i = 0; i < 20; i++) 1 + (_random.next() * 4000).floor()];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) {
        setState(() {
          _bids = _sizes();
          _asks = _sizes();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final price = widget.market.models[widget.market.selected].cents;
    final tick = math.max(1, price ~/ 2000);
    Widget side(String title, List<int> sizes, bool bid) => Expanded(
          child: Column(children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            for (var i = 0; i < 20; i++)
              SizedBox(
                height: 18,
                child: Row(children: [
                  Expanded(
                    child: Text(L.price(bid ? price - tick * (i + 1) : price + tick * (i + 1)),
                        style: TextStyle(fontSize: 12, color: bid ? const Color(0xFF1B8A3A) : const Color(0xFFC62828))),
                  ),
                  Text('${sizes[i]}', style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                ]),
              ),
          ]),
        );
    return SafeArea(
      child: Padding(
        key: const ValueKey('fm-markets-book'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Expanded(child: Text(L.orderBook, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            TextButton(
              key: const ValueKey('fm-markets-book-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(L.close),
            ),
          ]),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            side(L.bids, _bids, true),
            const SizedBox(width: 16),
            side(L.asks, _asks, false),
          ]),
        ]),
      ),
    );
  }
}
