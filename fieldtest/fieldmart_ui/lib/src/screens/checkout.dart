import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../labels.dart';
import '../scope.dart';
import '../telemetry.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _scroll = ScrollController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _postcode = TextEditingController();
  final _giftNote = TextEditingController();
  final _card = TextEditingController();
  final _expiry = TextEditingController();
  final _cvv = TextEditingController();
  final _cardName = TextEditingController();
  final _promo = TextEditingController();
  final _notes = TextEditingController();

  bool _account = false;
  String? _country;
  DateTime? _date;
  int _window = 0;
  bool _door = false;
  bool _gift = false;
  bool _saveCard = false;
  double _tip = 10;
  List<Promo> _promos = const [];
  Timer? _promoDebounce;
  String? _instruction;
  int _rating = 0;
  bool _placing = false;
  String? _order;
  String? _error;
  List<String> _countries = const [];

  @override
  void initState() {
    super.initState();
    _promo.addListener(_onPromo);
    unawaited(_loadCountries());
  }

  Future<void> _loadCountries() async {
    try {
      final c = await Fieldmart.of(context).api.countries();
      if (mounted) setState(() => _countries = c);
    } catch (_) {}
  }

  @override
  void dispose() {
    _promoDebounce?.cancel();
    for (final c in [_name, _email, _phone, _password, _address, _city, _postcode, _giftNote, _card, _expiry, _cvv, _cardName, _promo, _notes]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  String _lastPromoQuery = '';

  void _onPromo() {
    final q = _promo.text.trim();
    if (q == _lastPromoQuery) return;
    _lastPromoQuery = q;
    _promoDebounce?.cancel();
    if (q.isEmpty) {
      setState(() => _promos = const []);
      return;
    }
    _promoDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final promos = await Fieldmart.of(context).api.promos(q);
        if (mounted && _promo.text.trim() == q) setState(() => _promos = promos.take(8).toList());
      } catch (_) {}
    });
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CountryPicker(countries: _countries),
    );
    if (picked != null && mounted) setState(() => _country = picked);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      helpText: L.datePicker,
      initialDate: _date ?? today,
      firstDate: today,
      lastDate: today.add(const Duration(days: 120)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  (String, String)? _termsText;

  Future<void> _terms() async {
    final api = Fieldmart.of(context).api;
    final terms = await showDialog<void>(
      context: context,
      builder: (context) => _TermsDialog(load: () async => _termsText ??= await api.terms()),
    );
    return terms;
  }

  Future<void> _editItems() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => _EditItems(cart: Fieldmart.of(this.context).cart),
      );

  Future<void> _place() async {
    final scope = Fieldmart.of(context);
    setState(() {
      _placing = true;
      _error = null;
    });
    try {
      final order = await scope.api.checkout({
        'name': _name.text,
        'email': _email.text,
        'phone': _phone.text,
        'account': _account,
        if (_account) 'password': _password.text,
        'address': _address.text,
        'city': _city.text,
        'postcode': _postcode.text,
        'country': _country,
        'date': _date?.toIso8601String(),
        'window': L.windows[_window],
        'leaveAtDoor': _door,
        'gift': _gift,
        'giftNote': _giftNote.text,
        'card': _card.text,
        'expiry': _expiry.text,
        'cvv': _cvv.text,
        'cardName': _cardName.text,
        'saveCard': _saveCard,
        'tipPercent': _tip.round(),
        'promo': _promo.text,
        'instructions': _instruction,
        'rating': _rating,
        'notes': _notes.text,
        'items': [for (final l in scope.cart.lines) {'id': l.productId, 'qty': l.quantity}],
      });
      if (mounted) setState(() => _order = order);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_order != null) return _success();
    final scope = Fieldmart.of(context);
    final t = scope.telemetry;
    return Column(children: [
      Material(
        elevation: 1,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: const Text(L.checkoutTitle, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
      ),
      Expanded(child: _form(scope, t)),
    ]);
  }

  Widget _form(Fieldmart scope, Telemetry t) {
    return SingleChildScrollView(
      key: const ValueKey('fm-checkout-form'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _section(L.sections[0]),
        _field(_name, 'fm-checkout-name', L.name, TextInputType.name),
        _field(_email, 'fm-checkout-email', L.email, TextInputType.emailAddress),
        _field(_phone, 'fm-checkout-phone', L.phone, TextInputType.phone),
        Row(children: [
          const Expanded(child: Text(L.account)),
          Switch(
            key: const ValueKey('fm-checkout-account'),
            value: _account,
            onChanged: (v) => setState(() => _account = v),
          ),
        ]),
        if (_account)
          _field(_password, 'fm-checkout-password', L.password, TextInputType.visiblePassword, obscure: true),
        _section(L.sections[1]),
        _field(_address, 'fm-checkout-address', L.address, TextInputType.streetAddress, lines: 3),
        Row(children: [
          Expanded(child: _field(_city, 'fm-checkout-city', L.city, TextInputType.text)),
          const SizedBox(width: 12),
          SizedBox(width: 130, child: _field(_postcode, 'fm-checkout-postcode', L.postcode, TextInputType.text)),
        ]),
        _tapField('fm-checkout-country', L.country, _country ?? '', Icons.public, _pickCountry),
        _tapField('fm-checkout-date', L.date, _date == null ? '' : _formatDate(_date!), Icons.calendar_today, _pickDate),
        const SizedBox(height: 8),
        const Text(L.window),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          segments: [
            for (var i = 0; i < 3; i++)
              ButtonSegment(value: i, label: Text(L.windows[i], key: ValueKey('fm-checkout-window-$i'))),
          ],
          selected: {_window},
          onSelectionChanged: (s) => setState(() => _window = s.first),
        ),
        _check('fm-checkout-door', L.door, _door, (v) => setState(() => _door = v)),
        _check('fm-checkout-gift', L.gift, _gift, (v) => setState(() => _gift = v)),
        if (_gift) _field(_giftNote, 'fm-checkout-giftnote', L.giftNote, TextInputType.multiline, lines: 3),
        _section(L.sections[2]),
        t.mask(_field(_card, 'fm-checkout-card', L.card, TextInputType.number)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: _field(_expiry, 'fm-checkout-expiry', L.expiry, TextInputType.datetime)),
          const SizedBox(width: 12),
          // Only the input is blanked; its label stays outside the mask.
          SizedBox(
            width: 120,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(L.cvv, style: TextStyle(fontSize: 12)),
              t.mask(_field(_cvv, 'fm-checkout-cvv', null, TextInputType.number), mode: MaskMode.blank),
            ]),
          ),
        ]),
        _field(_cardName, 'fm-checkout-cardname', L.cardName, TextInputType.name),
        _check('fm-checkout-savecard', L.saveCard, _saveCard, (v) => setState(() => _saveCard = v)),
        const SizedBox(height: 8),
        Row(children: [
          const Text(L.tip),
          const Spacer(),
          Text(L.tipValue(_tip.round())),
        ]),
        Slider(
          key: const ValueKey('fm-checkout-tip'),
          value: _tip,
          min: 0,
          max: 30,
          divisions: 30,
          label: '${_tip.round()} %',
          onChanged: (v) => setState(() => _tip = v),
        ),
        _field(_promo, 'fm-checkout-promo', L.promo, TextInputType.text),
        for (var i = 0; i < _promos.length; i++)
          ListTile(
            key: ValueKey('fm-checkout-promo-option-$i'),
            dense: true,
            leading: const Icon(Icons.local_offer_outlined),
            title: Text(_promos[i].code),
            subtitle: _promos[i].description.isEmpty ? null : Text(_promos[i].description),
            onTap: () {
              _promo.text = _promos[i].code;
              _lastPromoQuery = _promos[i].code;
              FocusScope.of(context).unfocus();
              setState(() => _promos = const []);
            },
          ),
        _section(L.sections[3]),
        const Text(L.summary, style: TextStyle(fontWeight: FontWeight.w600)),
        ListenableBuilder(
          listenable: scope.cart,
          builder: (context, _) => Column(children: [
            for (final l in scope.cart.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text('${l.quantity} × ${l.title}')),
                  Text(L.price(l.priceCents * l.quantity)),
                ]),
              ),
            const Divider(),
            Row(children: [
              const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))),
              Text(L.price(scope.cart.totalCents * (100 + _tip.round()) ~/ 100),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ]),
        ),
        const SizedBox(height: 8),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
          TextButton(
            key: const ValueKey('fm-checkout-terms'),
            onPressed: _terms,
            child: const Text(L.terms),
          ),
          PopupMenuButton<int>(
            key: const ValueKey('fm-checkout-menu'),
            tooltip: L.menu,
            onSelected: (i) => setState(() => _instruction = L.menuItems[i]),
            itemBuilder: (context) => [
              for (var i = 0; i < L.menuItems.length; i++)
                PopupMenuItem(value: i, key: ValueKey('fm-checkout-menu-item-$i'), child: Text(L.menuItems[i])),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.more_vert, size: 18),
                Text(_instruction ?? L.menu),
              ]),
            ),
          ),
          OutlinedButton(
            key: const ValueKey('fm-checkout-edit'),
            onPressed: _editItems,
            child: const Text(L.edit),
          ),
        ]),
        const SizedBox(height: 8),
        const Text(L.rating),
        Row(children: [
          for (var i = 1; i <= 5; i++)
            IconButton(
              key: ValueKey('fm-checkout-rating-$i'),
              onPressed: () => setState(() => _rating = i),
              icon: Icon(i <= _rating ? Icons.star : Icons.star_border, color: const Color(0xFFE0A100)),
            ),
        ]),
        _field(_notes, 'fm-checkout-notes', L.notes, TextInputType.multiline, lines: 3),
        Wrap(children: [
          const Text('${L.loyalty}: '),
          // The one element masked through the marker key, not the API.
          KeyedSubtree(
            key: const ValueKey('fm-checkout-loyalty'),
            child: const Text('LOY-88442211', key: ValueKey('traceway-mask')),
          ),
        ]),
        if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xFFC62828))),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('fm-checkout-place'),
          onPressed: _placing ? null : _place,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: _placing ? const CircularProgressIndicator() : const Text(L.place),
        ),
      ]),
    );
  }

  Widget _success() => Center(
        key: const ValueKey('fm-checkout-success'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle, size: 72, color: Color(0xFF1B8A3A)),
            const SizedBox(height: 12),
            const Text(L.success, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(L.successDetail(_order!), style: const TextStyle(fontSize: 16)),
          ]),
        ),
      );

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      );

  Widget _field(TextEditingController c, String id, String? label, TextInputType type,
          {int lines = 1, bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          key: ValueKey(id),
          controller: c,
          keyboardType: lines > 1 ? TextInputType.multiline : type,
          obscureText: obscure,
          minLines: lines > 1 ? lines : null,
          maxLines: lines > 1 ? lines + 2 : 1,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  Widget _tapField(String id, String label, String value, IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: InkWell(
          key: ValueKey(id),
          onTap: onTap,
          child: InputDecorator(
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixIcon: Icon(icon)),
            child: Text(value),
          ),
        ),
      );

  Widget _check(String id, String label, bool value, ValueChanged<bool> onChanged) => Row(children: [
        Checkbox(key: ValueKey(id), value: value, onChanged: (v) => onChanged(v ?? false)),
        Expanded(child: GestureDetector(onTap: () => onChanged(!value), child: Text(label))),
      ]);
}

class _CountryPicker extends StatefulWidget {
  const _CountryPicker({required this.countries});

  final List<String> countries;

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.text.trim().toLowerCase();
    final shown = [for (final c in widget.countries) if (q.isEmpty || c.toLowerCase().contains(q)) c];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(children: [
        const Text(L.countryPicker, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: const ValueKey('fm-picker-search'),
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search countries',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('fm-picker-list'),
            itemCount: shown.length,
            itemExtent: 48,
            itemBuilder: (context, i) => ListTile(
              key: ValueKey('fm-picker-option-${shown[i]}'),
              title: Text(shown[i]),
              onTap: () => Navigator.of(context).pop(shown[i]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _EditItems extends StatefulWidget {
  const _EditItems({required this.cart});

  final CartState cart;

  @override
  State<_EditItems> createState() => _EditItemsState();
}

class _EditItemsState extends State<_EditItems> {
  @override
  Widget build(BuildContext context) {
    final lines = widget.cart.lines;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(L.edit, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          for (var i = 0; i < lines.length && i < 3; i++)
            Row(children: [
              Expanded(child: Text(lines[i].title)),
              IconButton(
                onPressed: lines[i].quantity > 1
                    ? () => setState(() {
                          lines[i].quantity--;
                          widget.cart.changed();
                        })
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('${lines[i].quantity}'),
              IconButton(
                key: ValueKey('fm-checkout-edit-plus-$i'),
                onPressed: () => setState(() {
                  lines[i].quantity++;
                  widget.cart.changed();
                }),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ]),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey('fm-checkout-edit-done'),
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            child: const Text(L.done),
          ),
        ]),
      ),
    );
  }
}

class _TermsDialog extends StatefulWidget {
  const _TermsDialog({required this.load});

  final Future<(String, String)> Function() load;

  @override
  State<_TermsDialog> createState() => _TermsDialogState();
}

class _TermsDialogState extends State<_TermsDialog> {
  (String, String)? _terms;

  @override
  void initState() {
    super.initState();
    widget.load().then((t) {
      if (mounted) setState(() => _terms = t);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(L.terms),
        content: SizedBox(
          width: 340,
          height: 420,
          child: SingleChildScrollView(
            key: const ValueKey('fm-checkout-terms-text'),
            child: _terms == null ? const LinearProgressIndicator() : Text(_terms!.$2),
          ),
        ),
        actions: [
          FilledButton(
            key: const ValueKey('fm-checkout-terms-agree'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(L.agree),
          ),
        ],
      );
}
