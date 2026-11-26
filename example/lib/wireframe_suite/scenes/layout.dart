// Text, flex, positioning, stacks and effects, tables and theming.
import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

final layoutScenarios = [
  Scenario(
    id: 'text',
    title: 'Text & typography',
    subtitle: 'Styles, rich text, wrapping, RTL, selection',
    icon: Icons.text_fields,
    page: () => const TextPage(),
    script: (d) async {
      await d.checkpoint('text',
          shows: ['Display small', 'Rich text with ', 'bold', 'monospace 0123456789']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.55));
      await d.checkpoint('text-scrolled',
          shows: ['Selectable text: press and hold a word', 'Text on a colored box']);
      final selectable = d.textCenter('Selectable text: press and hold a word');
      await d.longPressAt(selectable - const Offset(60, 0));
      await d.checkpoint('text-selected',
          shows: ['Selectable text: press and hold a word']);
      await d.tapAt(Offset(d.screen.width / 2, d.screen.height - 30));
    },
  ),
  Scenario(
    id: 'flex',
    title: 'Flex & wrap',
    subtitle: 'Row, Column, Expanded, Wrap, chips',
    icon: Icons.view_column,
    page: () => const FlexPage(),
    script: (d) async {
      await d.checkpoint('flex', shows: ['expanded', 'Chip', 'flex 2']);
    },
  ),
  Scenario(
    id: 'positioning',
    title: 'Positioning',
    subtitle: 'Align, fractions, FittedBox, transforms, Flow',
    icon: Icons.open_with,
    page: () => const PositioningPage(),
    script: (d) async {
      await d.checkpoint('positioning', shows: ['TL', 'BR', '16:9', 'contain']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.5));
      await d.checkpoint('positioning-scrolled', shows: ['3D card', 'Big']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.6));
      await d.checkpoint('positioning-bottom', shows: ['RTL row', 'OverflowBox']);
    },
  ),
  Scenario(
    id: 'stack',
    title: 'Stack & effects',
    subtitle: 'Positioned, clips, opacity, shadows, borders',
    icon: Icons.layers,
    page: () => const StackPage(),
    script: (d) async {
      await d.checkpoint('stack',
          shows: ['Positioned', 'Rotated', 'Oval', 'Card with elevation 6']);
    },
  ),
  Scenario(
    id: 'tables',
    title: 'Tables & cards',
    subtitle: 'DataTable, Table, ExpansionTile',
    icon: Icons.table_chart,
    page: () => const TablesPage(),
    script: (d) async {
      await d.checkpoint('tables', shows: ['Coffee', 'Order #1042']);
      await d.tap('Shipping details');
      await d.checkpoint('tables-expanded', shows: ['12 Analytical Engine Way']);
    },
  ),
  Scenario(
    id: 'theming',
    title: 'Theming',
    subtitle: 'Dark theme, large text, right to left',
    icon: Icons.palette,
    page: () => const ThemingPage(),
    script: (d) async {
      await d.checkpoint('theming', shows: ['Account', 'Save changes']);
      await d.tap('Dark');
      await d.checkpoint('theming-dark', shows: ['Account']);
      await d.tap('Large text');
      await d.checkpoint('theming-large-text', shows: ['Account']);
      await d.tap('RTL');
      await d.checkpoint('theming-rtl', shows: ['Account']);
    },
  ),
];

class TextPage extends StatelessWidget {
  const TextPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return page(
      'Text & typography',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Display small', style: theme.displaySmall),
          Text('Headline medium', style: theme.headlineMedium),
          Text('Title large, bold',
              style: theme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'A long paragraph wraps over several lines: the wireframe keeps each '
            'line as tall as Flutter laid it out, so the text sits where it did '
            'even though the browser renders it with its own font.',
          ),
          const SizedBox(height: 8),
          const Text.rich(TextSpan(
            text: 'Rich text with ',
            children: [
              TextSpan(text: 'bold', style: TextStyle(fontWeight: FontWeight.bold)),
              TextSpan(text: ', '),
              TextSpan(text: 'italic', style: TextStyle(fontStyle: FontStyle.italic)),
              TextSpan(text: ', '),
              TextSpan(text: 'colored', style: TextStyle(color: Colors.deepOrange)),
              TextSpan(text: ' and '),
              TextSpan(
                  text: 'underlined',
                  style: TextStyle(decoration: TextDecoration.underline)),
              TextSpan(text: ' runs.'),
            ],
          )),
          const SizedBox(height: 8),
          const Text(
            'This single line is far too long to fit and ends with an ellipsis at the edge',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const Text(
            'Two lines at most: this text goes on for long enough that it has to '
            'be cut off at the end of the second line with an ellipsis.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          const SizedBox(
              width: double.infinity,
              child: Text('Centered', textAlign: TextAlign.center)),
          const SizedBox(
              width: double.infinity,
              child: Text('Right aligned', textAlign: TextAlign.right)),
          const Directionality(
            textDirection: TextDirection.rtl,
            child: Text('مرحبا بالعالم — right to left'),
          ),
          const Text('monospace 0123456789', style: TextStyle(fontFamily: 'monospace')),
          const Text('Struck through',
              style: TextStyle(decoration: TextDecoration.lineThrough)),
          Text('Letter spacing', style: theme.labelLarge?.copyWith(letterSpacing: 4)),
          const Text('Shadowed title',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(color: Colors.black38, blurRadius: 4, offset: Offset(2, 2))])),
          const Text('Emoji 🎉 🚀 ✅ and symbols ★ ♥ →'),
          const SizedBox(height: 8),
          Container(
            color: Colors.yellow.shade200,
            padding: const EdgeInsets.all(8),
            child: const Text('Text on a colored box', style: TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: 8),
          const DefaultTextStyle(
            style: TextStyle(color: Colors.teal, fontSize: 16, fontWeight: FontWeight.w600),
            child: Text('Inherited from DefaultTextStyle'),
          ),
          MediaQuery.withClampedTextScaling(
            minScaleFactor: 1.5,
            maxScaleFactor: 1.5,
            child: const Text('Scaled 150%'),
          ),
          const SizedBox(height: 12),
          const SelectableText('Selectable text: press and hold a word',
              style: TextStyle(fontSize: 16)),
          const SizedBox(height: 240),
        ],
      ),
    );
  }
}

class FlexPage extends StatelessWidget {
  const FlexPage({super.key});

  @override
  Widget build(BuildContext context) {
    return page(
      'Flex & wrap',
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              box(Colors.red, 'fixed', width: 60),
              Expanded(child: box(Colors.green, 'expanded')),
              const Spacer(),
              box(Colors.blue, 'end', width: 50),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(flex: 2, child: box(Colors.purple, 'flex 2')),
              const SizedBox(width: 8),
              Expanded(child: box(Colors.teal, 'flex 1')),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (var i = 0; i < 4; i++) box(Colors.blueGrey, 'sb$i', width: 50, height: 32),
            ]),
            const Divider(height: 24),
            const Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(label: Text('Chip')),
                Chip(avatar: Icon(Icons.star, size: 18), label: Text('With avatar')),
                InputChip(label: Text('Input')),
                FilterChip(label: Text('Filter'), selected: true, onSelected: null),
                ChoiceChip(label: Text('Choice'), selected: false),
                ActionChip(label: Text('Action'), onPressed: null),
              ],
            ),
            const Divider(height: 24),
            SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Container(
                      color: Colors.grey.shade300,
                      child: Align(
                          alignment: Alignment.topLeft,
                          child: box(Colors.orange, 'TL', width: 36, height: 36)),
                    ),
                  ),
                  const VerticalDivider(),
                  Expanded(
                    child: Container(
                      color: Colors.grey.shade300,
                      child: Center(child: box(Colors.indigo, 'C', width: 36, height: 36)),
                    ),
                  ),
                  const VerticalDivider(),
                  Expanded(
                    child: Container(
                      color: Colors.grey.shade300,
                      child: Align(
                          alignment: Alignment.bottomRight,
                          child: box(Colors.brown, 'BR', width: 36, height: 36)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < 5; i++) CircleAvatar(radius: 18, child: Text('${i + 1}'))
              ],
            ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: Container(color: Colors.pink.shade100, padding: const EdgeInsets.all(8), child: const Text('Intrinsic height: as tall as the tallest of the row'))),
                const SizedBox(width: 8),
                Expanded(child: Container(color: Colors.pink.shade200, padding: const EdgeInsets.all(8), child: const Text('short'))),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class PositioningPage extends StatelessWidget {
  const PositioningPage({super.key});

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return page(
      'Positioning',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            height: 150,
            color: Colors.grey.shade200,
            child: Stack(children: [
              for (final (alignment, label) in [
                (Alignment.topLeft, 'TL'),
                (Alignment.topCenter, 'TC'),
                (Alignment.topRight, 'TR'),
                (Alignment.centerLeft, 'CL'),
                (Alignment.center, 'C'),
                (Alignment.centerRight, 'CR'),
                (Alignment.bottomLeft, 'BL'),
                (Alignment.bottomCenter, 'BC'),
                (Alignment.bottomRight, 'BR'),
              ])
                Align(alignment: alignment, child: box(Colors.indigo, label, width: 36, height: 28)),
            ]),
          ),
          gap,
          Row(children: [
            Expanded(
              child: Container(
                height: 80,
                color: Colors.teal.shade50,
                child: FractionallySizedBox(
                  widthFactor: 0.6,
                  heightFactor: 0.5,
                  alignment: Alignment.bottomLeft,
                  child: box(Colors.teal, '60% × 50%'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
                width: 110,
                child: AspectRatio(aspectRatio: 16 / 9, child: box(Colors.deepOrange, '16:9'))),
          ]),
          gap,
          Row(children: [
            for (final fit in [BoxFit.contain, BoxFit.cover, BoxFit.fill, BoxFit.scaleDown])
              Expanded(
                child: Container(
                  height: 56,
                  margin: const EdgeInsets.all(3),
                  color: Colors.amber.shade100,
                  child: FittedBox(
                      fit: fit,
                      child: Text(fit.name, style: const TextStyle(fontSize: 30))),
                ),
              ),
          ]),
          gap,
          SizedBox(
            height: 100,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              Transform.rotate(
                  angle: math.pi / 6, child: box(Colors.pink, 'rotate', width: 70, height: 40)),
              Transform.scale(
                  scaleX: 1.4,
                  scaleY: 0.8,
                  child: box(Colors.cyan.shade700, 'scale', width: 56, height: 40)),
              Transform(
                  transform: Matrix4.skewX(-0.4),
                  child: box(Colors.lime.shade800, 'skew', width: 56, height: 40)),
              Transform.translate(
                  offset: const Offset(0, 20),
                  child: box(Colors.brown, 'move', width: 56, height: 40)),
            ]),
          ),
          SizedBox(
            height: 130,
            child: Center(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.002)
                  ..rotateY(0.6),
                child: Container(
                  width: 200,
                  height: 100,
                  decoration: BoxDecoration(
                      color: Colors.indigo, borderRadius: BorderRadius.circular(12)),
                  alignment: Alignment.center,
                  child: const Text('3D card', style: TextStyle(color: Colors.white, fontSize: 20)),
                ),
              ),
            ),
          ),
          gap,
          Row(children: [
            RotatedBox(quarterTurns: 1, child: box(Colors.green, 'quarter turn', width: 110, height: 36)),
            const SizedBox(width: 16),
            const RotatedBox(quarterTurns: 3, child: Text('up the side')),
            const SizedBox(width: 16),
            const Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('Big', style: TextStyle(fontSize: 36)),
                  Text(' small', style: TextStyle(fontSize: 13)),
                  Text(' mid', style: TextStyle(fontSize: 22)),
                ],
              ),
            ),
          ]),
          gap,
          SizedBox(
            height: 130,
            child: Flow(
              delegate: const _FanDelegate(),
              children: [
                for (var i = 0; i < 6; i++)
                  CircleAvatar(
                      radius: 20,
                      backgroundColor: Colors.primaries[i * 2],
                      child: Text('$i', style: const TextStyle(color: Colors.white))),
              ],
            ),
          ),
          SizedBox(
            height: 90,
            child: CustomMultiChildLayout(
              delegate: _CornersDelegate(),
              children: [
                LayoutId(id: 'a', child: box(Colors.red, 'A', width: 60, height: 30)),
                LayoutId(id: 'b', child: box(Colors.blue, 'B', width: 60, height: 30)),
                LayoutId(id: 'c', child: box(Colors.green, 'C', width: 60, height: 30)),
              ],
            ),
          ),
          gap,
          Directionality(
            textDirection: TextDirection.rtl,
            child: Row(children: [
              box(Colors.red, 'first', width: 80),
              const SizedBox(width: 8),
              box(Colors.blue, 'second', width: 80),
              const Spacer(),
              const Text('RTL row'),
            ]),
          ),
          gap,
          SizedBox(
            height: 70,
            child: Center(
              child: SizedBox(
                width: 120,
                height: 30,
                child: OverflowBox(
                  maxWidth: 220,
                  maxHeight: 54,
                  child: box(Colors.deepPurple.withValues(alpha: 0.6), 'OverflowBox',
                      width: 220, height: 54),
                ),
              ),
            ),
          ),
          gap,
          LayoutBuilder(
            builder: (context, constraints) => box(
                Colors.blueGrey, 'LayoutBuilder: ${constraints.maxWidth.round()} wide',
                height: 36),
          ),
          const SizedBox(height: 200),
        ],
      ),
    );
  }
}

class _FanDelegate extends FlowDelegate {
  const _FanDelegate();

  @override
  void paintChildren(FlowPaintingContext context) {
    final center = Offset(context.size.width / 2 - 20, context.size.height - 44);
    for (var i = 0; i < context.childCount; i++) {
      final angle = math.pi * (0.1 + 0.8 * i / (context.childCount - 1));
      final at = center + Offset(-math.cos(angle) * 110, -math.sin(angle) * 80);
      context.paintChild(i, transform: Matrix4.translationValues(at.dx, at.dy, 0));
    }
  }

  @override
  bool shouldRepaint(_FanDelegate oldDelegate) => false;
}

class _CornersDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final a = layoutChild('a', BoxConstraints.loose(size));
    positionChild('a', Offset.zero);
    final b = layoutChild('b', BoxConstraints.loose(size));
    positionChild('b', Offset((size.width - b.width) / 2, (size.height - b.height) / 2));
    final c = layoutChild('c', BoxConstraints.loose(size));
    positionChild('c', Offset(size.width - c.width, size.height - c.height));
    assert(a.width > 0);
  }

  @override
  bool shouldRelayout(_CornersDelegate oldDelegate) => false;
}

class StackPage extends StatelessWidget {
  const StackPage({super.key});

  @override
  Widget build(BuildContext context) {
    return page(
      'Stack & effects',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            height: 160,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF7C4DFF), Color(0xFF18FFFF)]),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  top: 16,
                  child: Container(
                    width: 120,
                    height: 70,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text('Positioned'),
                  ),
                ),
                Positioned(
                  right: 24,
                  bottom: 20,
                  child: Transform.rotate(
                    angle: -0.3,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      color: Colors.amber,
                      child: const Text('Rotated'),
                    ),
                  ),
                ),
                const Positioned(
                  right: 12,
                  top: 12,
                  child: Badge(
                      label: Text('3'),
                      child: Icon(Icons.notifications, size: 32, color: Colors.white)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              ClipOval(
                  child: Container(
                      width: 70,
                      height: 70,
                      color: Colors.pink,
                      alignment: Alignment.center,
                      child: const Text('Oval'))),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Container(
                    width: 90,
                    height: 70,
                    color: Colors.green,
                    alignment: Alignment.center,
                    child: const Text('RRect')),
              ),
              Opacity(
                opacity: 0.4,
                child: Container(
                    width: 70,
                    height: 70,
                    color: Colors.blue,
                    alignment: Alignment.center,
                    child: const Text('40%')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Transform.scale(
                scale: 0.7,
                child: Container(
                    width: 80,
                    height: 80,
                    color: Colors.deepPurple,
                    alignment: Alignment.center,
                    child: const Text('70%', style: TextStyle(color: Colors.white))),
              ),
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Colors.yellow, Colors.red]),
                ),
              ),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black, width: 3),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: const Text('Border'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 60,
            decoration: const BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: Colors.red, width: 4),
                  left: BorderSide(color: Colors.blue, width: 8)),
              color: Color(0xFFF5F5F5),
            ),
            alignment: Alignment.center,
            child: const Text('Different sides'),
          ),
          const SizedBox(height: 16),
          const Card(
            elevation: 6,
            child: Padding(padding: EdgeInsets.all(20), child: Text('Card with elevation 6')),
          ),
        ],
      ),
    );
  }
}

class TablesPage extends StatelessWidget {
  const TablesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return page(
      'Tables & cards',
      ListView(
        padding: const EdgeInsets.all(12),
        children: [
          DataTable(
            columnSpacing: 24,
            columns: const [
              DataColumn(label: Text('Name')),
              DataColumn(label: Text('Qty'), numeric: true),
              DataColumn(label: Text('Price'), numeric: true),
            ],
            rows: const [
              DataRow(cells: [DataCell(Text('Coffee')), DataCell(Text('2')), DataCell(Text('6.00'))]),
              DataRow(cells: [DataCell(Text('Bagel')), DataCell(Text('1')), DataCell(Text('3.50'))]),
              DataRow(
                  selected: true,
                  cells: [DataCell(Text('Juice')), DataCell(Text('3')), DataCell(Text('9.75'))]),
            ],
          ),
          const SizedBox(height: 12),
          Table(
            border: TableBorder.all(color: Colors.grey),
            columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth()},
            children: const [
              TableRow(decoration: BoxDecoration(color: Color(0xFFE8EAF6)), children: [
                Padding(padding: EdgeInsets.all(8), child: Text('Plan')),
                Padding(padding: EdgeInsets.all(8), child: Text('Seats')),
              ]),
              TableRow(children: [
                Padding(padding: EdgeInsets.all(8), child: Text('Team')),
                Padding(padding: EdgeInsets.all(8), child: Text('10')),
              ]),
              TableRow(children: [
                Padding(padding: EdgeInsets.all(8), child: Text('Enterprise')),
                Padding(padding: EdgeInsets.all(8), child: Text('Unlimited')),
              ]),
            ],
          ),
          const SizedBox(height: 12),
          const Card(
            child: Column(children: [
              ListTile(
                  leading: Icon(Icons.receipt_long),
                  title: Text('Order #1042'),
                  subtitle: Text('3 items · 19.25')),
              ExpansionTile(
                title: Text('Shipping details'),
                children: [
                  ListTile(title: Text('Ada Lovelace')),
                  ListTile(title: Text('12 Analytical Engine Way')),
                ],
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class ThemingPage extends StatefulWidget {
  const ThemingPage({super.key});

  @override
  State<ThemingPage> createState() => _ThemingPageState();
}

class _ThemingPageState extends State<ThemingPage> {
  Set<String> _variant = {'Light'};
  bool _switch = true;

  @override
  Widget build(BuildContext context) {
    final variant = _variant.single;
    final base = Theme.of(context);
    final dark = ThemeData(brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF3F51B5));
    Widget sample = Builder(builder: (context) {
      final theme = Theme.of(context);
      return Material(
        color: theme.colorScheme.surface,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Account', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Text('AL')),
                title: const Text('Ada Lovelace'),
                subtitle: const Text('Analyst'),
                trailing: Switch(value: _switch, onChanged: (v) => setState(() => _switch = v)),
              ),
            ),
            const SizedBox(height: 8),
            const TextField(
                decoration: InputDecoration(labelText: 'Display name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            const Wrap(spacing: 8, children: [
              Chip(label: Text('Admin')),
              Chip(label: Text('Billing')),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton(onPressed: () {}, child: const Text('Save changes')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
            ]),
          ],
        ),
      );
    });
    if (variant == 'Dark') sample = Theme(data: dark, child: sample);
    if (variant == 'Large text') {
      sample = MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.6, maxScaleFactor: 1.6, child: sample);
    }
    if (variant == 'RTL') {
      sample = Directionality(textDirection: TextDirection.rtl, child: sample);
    }
    return page(
      'Theming',
      Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'Light', label: Text('Light')),
              ButtonSegment(value: 'Dark', label: Text('Dark')),
              ButtonSegment(value: 'Large text', label: Text('Large text')),
              ButtonSegment(value: 'RTL', label: Text('RTL')),
            ],
            selected: _variant,
            onSelectionChanged: (v) => setState(() => _variant = v),
          ),
        ),
        Expanded(child: Theme(data: variant == 'Dark' ? dark : base, child: sample)),
      ]),
    );
  }
}
