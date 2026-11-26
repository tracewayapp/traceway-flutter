// Fields, toggles, sliders, buttons and chips, then the pickers: date,
// time, autocomplete, dropdown menu and search.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

final formScenarios = [
  Scenario(
    id: 'forms',
    title: 'Forms & controls',
    subtitle: 'Fields, toggles, sliders, buttons',
    icon: Icons.edit_note,
    page: () => const FormsPage(),
    script: (d) async {
      await d.checkpoint('forms',
          shows: ['Name', 'I agree to the terms', 'Notifications'], hides: ['hunter2']);
      await d.tapKey(FormsPage.nameKey);
      await d.checkpoint('forms-focused', shows: ['Name']);
      await d.type(FormsPage.name, 'Charles Babbage');
      await d.tapKey(FormsPage.checkboxKey);
      await d.tapKey(FormsPage.switchKey);
      await d.tap('Large');
      await d.checkpoint('forms-filled',
          shows: ['******* *******'], hides: ['Charles Babbage', 'hunter2']);
      final slider = d.keyRect(FormsPage.sliderKey);
      final track = slider.width - 48;
      final from = Offset(slider.left + 24 + track * 0.3, slider.center.dy);
      await d.drag(from, Offset(track * 0.5, 0), steps: 16);
      await d.checkpoint('forms-slider');
      await d.scrollTo('Bold');
      await d.checkpoint('forms-more', shows: ['Elevated', 'Bold']);
      await d.tap('Bold');
      await d.tap('Weekly');
      await d.checkpoint('forms-toggled');
    },
  ),
  Scenario(
    id: 'pickers',
    title: 'Pickers',
    subtitle: 'Date, time, autocomplete, dropdown menu, search',
    icon: Icons.event,
    page: () => const PickersPage(),
    script: (d) async {
      await d.checkpoint('pickers', shows: ['Pick a date', 'Pick a time']);
      await d.tap('Pick a date');
      await d.checkpoint('pickers-date', shows: ['OK', 'Cancel']);
      await d.tap('15');
      await d.tap('OK');
      await d.settle();
      await d.tap('Pick a time');
      await d.checkpoint('pickers-time', shows: ['OK', 'Cancel']);
      await d.tap('Cancel');
      await d.settle();
      await d.tapKey(PickersPage.autocompleteKey);
      await d.type(PickersPage.fruit!, 'ap');
      await d.checkpoint('pickers-autocomplete', shows: ['apricot', 'apple']);
      await d.tap('apricot');
      await d.settle();
      await d.tapKey(PickersPage.menuKey);
      await d.checkpoint('pickers-dropdown-menu', shows: ['Green', 'Blue']);
      await d.tap('Green');
      await d.settle();
      await d.tapKey(PickersPage.searchKey);
      await d.checkpoint('pickers-search', shows: ['Recent: invoices']);
      await d.back();
      await d.checkpoint('pickers-picked', shows: ['Mar 15'], hides: ['apricot']);
    },
  ),
];

class FormsPage extends StatefulWidget {
  const FormsPage({super.key});

  static final nameKey = GlobalKey();
  static final checkboxKey = GlobalKey();
  static final switchKey = GlobalKey();
  static final sliderKey = GlobalKey();
  static final name = TextEditingController();

  @override
  State<FormsPage> createState() => _FormsPageState();
}

class _FormsPageState extends State<FormsPage> {
  bool _agree = false;
  bool _notify = false;
  bool? _tristate;
  String _size = 'Medium';
  double _volume = 0.3;
  RangeValues _range = const RangeValues(20, 70);
  Set<String> _view = {'Day'};
  final _styles = [false, false, false];
  final _filters = <String>{'Daily'};
  final _password = TextEditingController(text: 'hunter2');

  @override
  void initState() {
    super.initState();
    FormsPage.name.clear();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return page(
      'Forms & controls',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: FormsPage.nameKey,
            controller: FormsPage.name,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          const TextField(
              decoration:
                  InputDecoration(labelText: 'Email (underline)', hintText: 'you@example.com')),
          const SizedBox(height: 12),
          const TextField(decoration: InputDecoration(labelText: 'Filled', filled: true)),
          const SizedBox(height: 12),
          TextField(
            obscureText: true,
            controller: _password,
            decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
          ),
          CheckboxListTile(
            key: FormsPage.checkboxKey,
            value: _agree,
            onChanged: (v) => setState(() => _agree = v ?? false),
            title: const Text('I agree to the terms'),
          ),
          SwitchListTile(
            key: FormsPage.switchKey,
            value: _notify,
            onChanged: (v) => setState(() => _notify = v),
            title: const Text('Notifications'),
          ),
          RadioGroup<String>(
            groupValue: _size,
            onChanged: (v) => setState(() => _size = v ?? _size),
            child: Row(children: [
              for (final s in ['Small', 'Medium', 'Large'])
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _size = s),
                    child: Row(children: [Radio<String>(value: s), Text(s)]),
                  ),
                ),
            ]),
          ),
          Slider(
              key: FormsPage.sliderKey,
              value: _volume,
              onChanged: (v) => setState(() => _volume = v)),
          RangeSlider(
              values: _range, min: 0, max: 100, onChanged: (v) => setState(() => _range = v)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Day', label: Text('Day')),
              ButtonSegment(value: 'Week', label: Text('Week')),
              ButtonSegment(value: 'Month', label: Text('Month')),
            ],
            selected: _view,
            onSelectionChanged: (v) => setState(() => _view = v),
          ),
          const SizedBox(height: 16),
          const TextField(
            decoration: InputDecoration(
              labelText: 'Search with icons',
              prefixIcon: Icon(Icons.search),
              suffixIcon: Icon(Icons.clear),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const TextField(
            maxLength: 40,
            decoration: InputDecoration(
              labelText: 'With helper',
              helperText: 'Shown under the field',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const TextField(
            decoration: InputDecoration(
              labelText: 'With an error',
              errorText: 'This field is required',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const TextField(
            minLines: 3,
            maxLines: 3,
            decoration: InputDecoration(labelText: 'Multiline', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ElevatedButton(onPressed: () {}, child: const Text('Elevated')),
            FilledButton(onPressed: () {}, child: const Text('Filled')),
            FilledButton.tonal(onPressed: () {}, child: const Text('Tonal')),
            OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
            TextButton(onPressed: () {}, child: const Text('Text')),
            ElevatedButton.icon(
                onPressed: () {}, icon: const Icon(Icons.send), label: const Text('Icon')),
            IconButton.filled(onPressed: () {}, icon: const Icon(Icons.favorite)),
            IconButton.filledTonal(onPressed: () {}, icon: const Icon(Icons.share)),
            IconButton.outlined(onPressed: () {}, icon: const Icon(Icons.bookmark)),
            const FilledButton(onPressed: null, child: Text('Disabled')),
            FloatingActionButton.small(
                heroTag: null, onPressed: () {}, child: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 12),
          ToggleButtons(
            isSelected: _styles,
            onPressed: (i) => setState(() => _styles[i] = !_styles[i]),
            children: const [Text('Bold'), Text('Italic'), Text('Under')],
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final f in ['Daily', 'Weekly', 'Monthly'])
              FilterChip(
                label: Text(f),
                selected: _filters.contains(f),
                onSelected: (on) => setState(() => on ? _filters.add(f) : _filters.remove(f)),
              ),
          ]),
          CheckboxListTile(
            tristate: true,
            value: _tristate,
            onChanged: (v) => setState(() => _tristate = v),
            title: const Text('Tristate checkbox'),
          ),
          DropdownButton<String>(
            value: 'Apple',
            onChanged: (_) {},
            items: const [
              DropdownMenuItem(value: 'Apple', child: Text('Apple')),
              DropdownMenuItem(value: 'Pear', child: Text('Pear')),
            ],
          ),
          const SizedBox(height: 240),
        ],
      ),
    );
  }
}

class PickersPage extends StatefulWidget {
  const PickersPage({super.key});

  static final autocompleteKey = GlobalKey();
  static final menuKey = GlobalKey();
  static final searchKey = GlobalKey();
  static TextEditingController? fruit;

  @override
  State<PickersPage> createState() => _PickersPageState();
}

class _PickersPageState extends State<PickersPage> {
  DateTime? _date;
  TimeOfDay? _time;
  String _color = 'Blue';

  static const _fruits = ['apple', 'apricot', 'banana', 'cherry', 'grape', 'papaya'];

  @override
  Widget build(BuildContext context) {
    return page(
      'Pickers',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            FilledButton(
              onPressed: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 3, 10),
                  currentDate: DateTime(2026, 3, 18),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (date != null) setState(() => _date = date);
              },
              child: const Text('Pick a date'),
            ),
            const SizedBox(width: 12),
            Text(_date == null
                ? 'No date'
                : MaterialLocalizations.of(context).formatMediumDate(_date!)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.tonal(
              onPressed: () async {
                final time = await showTimePicker(
                    context: context, initialTime: const TimeOfDay(hour: 9, minute: 30));
                if (time != null) setState(() => _time = time);
              },
              child: const Text('Pick a time'),
            ),
            const SizedBox(width: 12),
            Text(_time == null ? 'No time' : _time!.format(context)),
          ]),
          const SizedBox(height: 20),
          Autocomplete<String>(
            key: PickersPage.autocompleteKey,
            optionsBuilder: (value) => value.text.isEmpty
                ? const Iterable<String>.empty()
                : _fruits.where((f) => f.startsWith(value.text.toLowerCase())),
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              PickersPage.fruit = controller;
              return TextField(
                controller: controller,
                focusNode: focusNode,
                decoration:
                    const InputDecoration(labelText: 'Fruit', border: OutlineInputBorder()),
              );
            },
          ),
          const SizedBox(height: 20),
          DropdownMenu<String>(
            key: PickersPage.menuKey,
            initialSelection: _color,
            label: const Text('Color'),
            onSelected: (v) => setState(() => _color = v ?? _color),
            dropdownMenuEntries: const [
              DropdownMenuEntry(value: 'Red', label: 'Red'),
              DropdownMenuEntry(value: 'Green', label: 'Green'),
              DropdownMenuEntry(value: 'Blue', label: 'Blue'),
            ],
          ),
          const SizedBox(height: 20),
          KeyedSubtree(
            key: PickersPage.searchKey,
            child: SearchAnchor.bar(
              barHintText: 'Search mail',
              suggestionsBuilder: (context, controller) => [
                for (final s in ['Recent: invoices', 'Recent: travel', 'Recent: receipts'])
                  ListTile(leading: const Icon(Icons.history), title: Text(s)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
