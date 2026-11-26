// Scroll behavior: drags, flings, the mouse wheel, programmatic scrolls,
// overscroll physics, pull to refresh, reversed and nested scrollables,
// wheels, sheets and slivers.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

final scrollingScenarios = [
  Scenario(
    id: 'lists',
    title: 'Lists',
    subtitle: 'Drag, fling, wheel, jump, horizontal',
    icon: Icons.list,
    page: () => const ListsPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('lists', shows: ['Item 0', 'Card 0'], hides: ['Item 40']);
      await d.drag(Offset(s.width / 2, s.height * 0.8), Offset(0, -s.height * 0.3));
      await d.checkpoint('lists-dragged', hides: ['Item 0']);
      await d.fling(Offset(s.width / 2, s.height * 0.8), Offset(0, -s.height * 0.35));
      // Where a fling stops depends on how fast the finger seemed to move:
      // compared with the app, not with the baseline.
      await d.checkpoint('lists-flung', minMutations: 3, maxChange: 1);
      await d.tapKey(ListsPage.topKey);
      await d.settle();
      await d.wheel(Offset(s.width / 2, s.height * 0.6), const Offset(0, 120), notches: 3);
      await d.checkpoint('lists-wheel');
      await d.tapKey(ListsPage.jumpKey);
      await d.checkpoint('lists-jumped', shows: ['Item 120'], minMutations: 2);
      final card = d.textCenter('Card 1');
      await d.drag(card, Offset(-s.width * 0.55, 0));
      await d.checkpoint('lists-horizontal', shows: ['Card 4'], hides: ['Card 0']);
      await d.tapKey(ListsPage.topKey);
      await d.checkpoint('lists-top', shows: ['Item 0']);
    },
  ),
  Scenario(
    id: 'physics',
    title: 'Scroll physics',
    subtitle: 'Bounce, stretch, pull to refresh, chat',
    icon: Icons.swipe_vertical,
    page: () => const PhysicsPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('physics', shows: ['Bouncing 0']);
      // Pulled past the top and held there: the list hangs below its edge.
      var held = await d.press(Offset(s.width / 2, s.height * 0.4));
      await held.moveBy(Offset(0, s.height * 0.25), steps: 20);
      await d.checkpoint('physics-bounce-held', shows: ['Bouncing 0']);
      await held.up();
      await d.settle();
      await d.tap('Stretch');
      await d.checkpoint('physics-stretch', shows: ['Stretching 0']);
      held = await d.press(Offset(s.width / 2, s.height * 0.4));
      await held.moveBy(Offset(0, s.height * 0.25), steps: 20);
      await d.checkpoint('physics-stretch-held', shows: ['Stretching 0']);
      await held.up();
      await d.settle();
      await d.tap('Refresh');
      await d.checkpoint('physics-refresh', shows: ['Message 1']);
      held = await d.press(Offset(s.width / 2, s.height * 0.35));
      await held.moveBy(Offset(0, s.height * 0.35), steps: 24);
      await d.pause(300);
      await held.up();
      await d.pause(500);
      await d.checkpoint('physics-refreshing',
          settle: false, ignore: [PhysicsPage.refreshKey], minMutations: 2);
      await d.pause(1600);
      await d.checkpoint('physics-refreshed', shows: ['Fresh message 1']);
      await d.tap('Chat');
      await d.checkpoint('physics-chat', shows: ['Newest message', 'Send']);
      await d.tap('Send');
      await d.checkpoint('physics-chat-sent', shows: ['Sent from the suite']);
    },
  ),
  Scenario(
    id: 'nested',
    title: 'Nested scrolling',
    subtitle: 'NestedScrollView, floating app bar, tabs',
    icon: Icons.vertical_split,
    page: () => const NestedPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('nested', shows: ['Nested scrolling', 'Inbox 0']);
      await d.drag(Offset(s.width / 2, s.height * 0.85), Offset(0, -s.height * 0.5));
      await d.checkpoint('nested-collapsed', hides: ['Inbox 0']);
      await d.drag(Offset(s.width / 2, s.height * 0.5), Offset(0, s.height * 0.1));
      await d.checkpoint('nested-snapped');
      await d.tap('Archive');
      await d.checkpoint('nested-archive', shows: ['Archived 0']);
    },
  ),
  Scenario(
    id: 'wheels',
    title: 'Wheels & sheets',
    subtitle: 'ListWheelScrollView, pickers, draggable sheet',
    icon: Icons.tune,
    page: () => const WheelsPage(),
    script: (d) async {
      await d.checkpoint('wheels', shows: ['Wheel 0', 'Sheet handle']);
      final wheel = d.keyCenter(WheelsPage.wheelKey);
      await d.drag(wheel, const Offset(0, -120));
      await d.checkpoint('wheels-turned', shows: ['Wheel 3']);
      final picker = d.keyCenter(WheelsPage.pickerKey);
      await d.drag(picker, const Offset(0, -64));
      await d.checkpoint('wheels-picked');
      final handle = d.textCenter('Sheet handle');
      await d.drag(handle, Offset(0, -d.screen.height * 0.4));
      await d.checkpoint('wheels-sheet-open', shows: ['Sheet row 6']);
    },
  ),
  Scenario(
    id: 'slivers',
    title: 'Slivers & grids',
    subtitle: 'SliverAppBar, grids, carousels',
    icon: Icons.grid_view,
    page: () => const SliversPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('slivers', shows: ['Slivers & grids', 'Card 0', 'Tile 0']);
      await d.drag(Offset(s.width / 2, s.height * 0.8), Offset(0, -s.height * 0.45));
      await d.checkpoint('slivers-scrolled', shows: ['Row 3']);
      await d.drag(Offset(s.width / 2, s.height * 0.3), Offset(0, s.height * 0.6));
      await d.settle();
      await d.drag(d.textCenter('Card 1'), Offset(-s.width * 0.6, 0));
      await d.checkpoint('slivers-carousel', shows: ['Card 2', 'Card 3'], hides: ['Card 0']);
    },
  ),
];

class ListsPage extends StatefulWidget {
  const ListsPage({super.key});

  static final jumpKey = GlobalKey();
  static final topKey = GlobalKey();

  @override
  State<ListsPage> createState() => _ListsPageState();
}

class _ListsPageState extends State<ListsPage> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return page(
      'Lists',
      actions: [
        TextButton(
          key: ListsPage.jumpKey,
          onPressed: () => _controller.animateTo(120 * 56.0,
              duration: const Duration(milliseconds: 600), curve: Curves.easeOut),
          child: const Text('Jump'),
        ),
        IconButton(
          key: ListsPage.topKey,
          icon: const Icon(Icons.vertical_align_top),
          onPressed: () => _controller.jumpTo(0),
        ),
      ],
      Column(children: [
        SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            itemCount: 20,
            itemBuilder: (_, i) => Container(
              width: 110,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.primaries[i % Colors.primaries.length].shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text('Card $i'),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: true,
            child: ListView.builder(
              controller: _controller,
              itemExtent: 56,
              itemCount: 300,
              itemBuilder: (_, i) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.primaries[i % Colors.primaries.length],
                  child: Text('${i % 10}', style: const TextStyle(color: Colors.white)),
                ),
                title: Text('Item $i'),
                trailing: i % 3 == 0 ? const Icon(Icons.star_border) : null,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class PhysicsPage extends StatefulWidget {
  const PhysicsPage({super.key});

  static final refreshKey = GlobalKey();

  @override
  State<PhysicsPage> createState() => _PhysicsPageState();
}

class _PhysicsPageState extends State<PhysicsPage> {
  Set<String> _demo = {'Bounce'};
  List<String> _messages = [for (var i = 1; i <= 12; i++) 'Message $i'];
  final _chat = <String>[
    'Newest message',
    for (var i = 1; i <= 20; i++) 'Older message $i',
  ];

  Future<void> _refresh() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() => _messages = [
          for (var i = 1; i <= 3; i++) 'Fresh message $i',
          ..._messages,
        ]);
  }

  Widget _tile(String text, Color color) => Container(
        height: 64,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(text),
      );

  @override
  Widget build(BuildContext context) {
    final demo = _demo.single;
    final Widget body = switch (demo) {
      'Bounce' => ListView.builder(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          itemCount: 30,
          itemBuilder: (_, i) => _tile('Bouncing $i', Colors.lightBlue.shade100),
        ),
      'Stretch' => ScrollConfiguration(
          behavior: const _StretchBehavior(),
          child: ListView.builder(
            physics: const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            itemCount: 30,
            itemBuilder: (_, i) => _tile('Stretching $i', Colors.lightGreen.shade100),
          ),
        ),
      'Refresh' => RefreshIndicator(
          key: PhysicsPage.refreshKey,
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [for (final m in _messages) _tile(m, Colors.orange.shade100)],
          ),
        ),
      _ => Column(children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _chat.length,
              itemBuilder: (_, i) {
                final mine = i.isEven;
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: const BoxConstraints(maxWidth: 260),
                    decoration: BoxDecoration(
                      color: mine ? Colors.indigo : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(_chat[i],
                        style: TextStyle(color: mine ? Colors.white : Colors.black87)),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              const Expanded(
                  child: TextField(
                      decoration: InputDecoration(
                          hintText: 'Message', border: OutlineInputBorder(), isDense: true))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => setState(() => _chat.insert(0, 'Sent from the suite')),
                child: const Text('Send'),
              ),
            ]),
          ),
        ]),
    };
    return page(
      'Scroll physics',
      Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'Bounce', label: Text('Bounce')),
              ButtonSegment(value: 'Stretch', label: Text('Stretch')),
              ButtonSegment(value: 'Refresh', label: Text('Refresh')),
              ButtonSegment(value: 'Chat', label: Text('Chat')),
            ],
            selected: _demo,
            onSelectionChanged: (v) => setState(() => _demo = v),
          ),
        ),
        Expanded(child: body),
      ]),
    );
  }
}

/// The Android 12 overscroll: the content stretches instead of glowing.
class _StretchBehavior extends MaterialScrollBehavior {
  const _StretchBehavior();

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      StretchingOverscrollIndicator(axisDirection: details.direction, child: child);
}

class NestedPage extends StatelessWidget {
  const NestedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: NestedScrollView(
          floatHeaderSlivers: true,
          headerSliverBuilder: (context, scrolled) => [
            SliverAppBar(
              title: const Text('Nested scrolling'),
              floating: true,
              snap: true,
              pinned: false,
              forceElevated: scrolled,
              leading: BackButton(onPressed: () => Navigator.of(context).pop()),
              bottom: const TabBar(tabs: [Tab(text: 'Inbox'), Tab(text: 'Archive')]),
            ),
          ],
          body: TabBarView(children: [
            for (final name in ['Inbox', 'Archived'])
              Builder(
                builder: (context) => ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: 40,
                  itemBuilder: (_, i) => ListTile(
                    leading: Icon(name == 'Inbox' ? Icons.mail_outline : Icons.archive_outlined),
                    title: Text('$name $i'),
                    subtitle: Text('Preview of $name message $i'),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class WheelsPage extends StatelessWidget {
  const WheelsPage({super.key});

  static final wheelKey = GlobalKey();
  static final pickerKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return page(
      'Wheels & sheets',
      Stack(children: [
        Column(children: [
          SizedBox(
            key: wheelKey,
            height: 200,
            child: ListWheelScrollView.useDelegate(
              itemExtent: 40,
              diameterRatio: 1.6,
              physics: const FixedExtentScrollPhysics(),
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: 30,
                builder: (_, i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  color: Colors.primaries[i % Colors.primaries.length].shade200,
                  alignment: Alignment.center,
                  child: Text('Wheel $i'),
                ),
              ),
            ),
          ),
          const Divider(),
          SizedBox(
            key: pickerKey,
            height: 160,
            child: CupertinoPicker(
              itemExtent: 32,
              onSelectedItemChanged: (_) {},
              children: [for (final m in _months) Center(child: Text(m))],
            ),
          ),
        ]),
        DraggableScrollableSheet(
          initialChildSize: 0.18,
          minChildSize: 0.12,
          maxChildSize: 0.85,
          builder: (context, controller) => Material(
            elevation: 8,
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: ListView.builder(
              controller: controller,
              itemCount: 20,
              itemBuilder: (_, i) => i == 0
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(children: [
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                              color: Colors.grey, borderRadius: BorderRadius.circular(2)),
                        ),
                        const SizedBox(height: 8),
                        const Text('Sheet handle'),
                      ]),
                    )
                  : ListTile(title: Text('Sheet row $i'), leading: const Icon(Icons.place)),
            ),
          ),
        ),
      ]),
    );
  }
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

class SliversPage extends StatelessWidget {
  const SliversPage({super.key});

  @override
  Widget build(BuildContext context) {
    const colors = Colors.primaries;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 140,
            flexibleSpace: const FlexibleSpaceBar(title: Text('Slivers & grids')),
            leading: BackButton(onPressed: () => Navigator.of(context).pop()),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 110,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(8),
                itemCount: 12,
                itemBuilder: (_, i) => Container(
                  width: 140,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                      color: colors[i % colors.length].shade200,
                      borderRadius: BorderRadius.circular(12)),
                  alignment: Alignment.center,
                  child: Text('Card $i'),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: SliverGrid.count(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var i = 0; i < 9; i++)
                  Container(
                    color: colors[(i * 3) % colors.length],
                    alignment: Alignment.center,
                    child: Text('Tile $i', style: const TextStyle(color: Colors.white)),
                  ),
              ],
            ),
          ),
          SliverList.builder(
            itemCount: 40,
            itemBuilder: (_, i) => ListTile(
              leading: Icon(i.isEven ? Icons.inbox : Icons.mail),
              title: Text('Row $i'),
              subtitle: Text('Subtitle of row $i'),
            ),
          ),
        ],
      ),
    );
  }
}
