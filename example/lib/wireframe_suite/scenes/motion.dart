// Animations (implicit, explicit held halfway, lists, switchers, Hero)
// and gestures: drag and drop, reordering, swipe to dismiss, pinch, pan,
// double tap and long press.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

final motionScenarios = [
  Scenario(
    id: 'animations',
    title: 'Animations',
    subtitle: 'Implicit, explicit, lists, switchers, Hero',
    icon: Icons.animation,
    page: () => const AnimationsPage(),
    script: (d) async {
      await d.checkpoint('animations', shows: ['AnimatedContainer', 'Fading text']);
      await d.tap('Animate');
      await d.checkpoint('animations-toggled', minMutations: 4);
      await d.tap('Halfway');
      await d.checkpoint('animations-half');
      await d.tap('Play');
      await d.checkpoint('animations-played', minMutations: 3);
      await d.tap('Switch');
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.55));
      await d.checkpoint('animations-switched', shows: ['Switched in'], hides: ['Switched out']);
      await d.tap('Add item');
      await d.pause(200);
      await d.tap('Add item');
      await d.checkpoint('animations-list', shows: ['List item 4', 'List item 5']);
      await d.tap('Remove item');
      await d.checkpoint('animations-list-removed', hides: ['List item 5']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.4));
      await d.settle();
      await d.tapKey(AnimationsPage.heroKey);
      await d.checkpoint('animations-hero', shows: ['The avatar flew here.']);
      await d.back();
    },
  ),
  Scenario(
    id: 'drag-drop',
    title: 'Drag & drop',
    subtitle: 'Draggable, reorderable list, swipe to dismiss',
    icon: Icons.pan_tool,
    page: () => const DragDropPage(),
    script: (d) async {
      await d.checkpoint('drag-drop', shows: ['Apple', 'Basket: empty', 'Task 1', 'Swipe me 1']);
      var held = await d.press(d.textCenter('Apple'));
      await d.pause(700);
      await held.moveTo(d.keyCenter(DragDropPage.basketKey), steps: 24);
      await d.checkpoint('drag-drop-dragging', shows: ['Drop it here']);
      await held.up();
      await d.checkpoint('drag-drop-dropped', shows: ['Basket: Apple']);
      final task = d.findText('Task 1')!;
      final row = d.rectOf(task);
      held = await d.press(row.center);
      await d.pause(700);
      await held.moveBy(const Offset(0, 112), steps: 24);
      await d.checkpoint('drag-drop-reordering', shows: ['Task 1']);
      await held.up();
      await d.checkpoint('drag-drop-reordered', shows: ['Task 1']);
      held = await d.press(d.textCenter('Swipe me 1'));
      await held.moveBy(Offset(-d.screen.width * 0.55, 0), steps: 20);
      await d.checkpoint('drag-drop-swiping', shows: ['Delete']);
      await held.up();
      await d.checkpoint('drag-drop-dismissed', hides: ['Swipe me 1']);
    },
  ),
  Scenario(
    id: 'zoom-pan',
    title: 'Zoom & pan',
    subtitle: 'InteractiveViewer, pan, double tap, long press',
    icon: Icons.zoom_in,
    page: () => const ZoomPanPage(),
    script: (d) async {
      await d.checkpoint('zoom-pan', shows: ['A1', 'B2', 'Double tap me', 'Hold me']);
      final viewer = d.keyRect(ZoomPanPage.viewerKey);
      await d.pinch(viewer.center, 80, 200);
      await d.checkpoint('zoom-pan-zoomed');
      await d.drag(viewer.center, const Offset(60, 40), steps: 20);
      await d.checkpoint('zoom-pan-panned');
      await d.drag(d.keyCenter(ZoomPanPage.boxKey), const Offset(140, 30), steps: 20);
      await d.checkpoint('zoom-pan-box-moved', shows: ['Drag me']);
      await d.doubleTapAt(d.textCenter('Double tap me'));
      await d.checkpoint('zoom-pan-double-tapped', shows: ['Double tapped']);
      await d.longPressAt(d.textCenter('Hold me'));
      await d.checkpoint('zoom-pan-long-pressed', shows: ['Held!']);
    },
  ),
];

class AnimationsPage extends StatefulWidget {
  const AnimationsPage({super.key});

  static final heroKey = GlobalKey();

  @override
  State<AnimationsPage> createState() => _AnimationsPageState();
}

class _AnimationsPageState extends State<AnimationsPage> with SingleTickerProviderStateMixin {
  bool _big = false;
  bool _switched = false;
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  final _list = GlobalKey<AnimatedListState>();
  final _items = ['List item 1', 'List item 2', 'List item 3'];
  int _next = 4;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _listItem(String text, Animation<double> animation) => SizeTransition(
        sizeFactor: animation,
        child: FadeTransition(
          opacity: animation,
          child: Card(child: ListTile(dense: true, title: Text(text))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const ms800 = Duration(milliseconds: 800);
    const gap = SizedBox(height: 12);
    return page(
      'Animations',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(onPressed: () => setState(() => _big = !_big), child: const Text('Animate')),
            OutlinedButton(onPressed: () => _c.value = 0.5, child: const Text('Halfway')),
            OutlinedButton(onPressed: () => _c.forward(), child: const Text('Play')),
            OutlinedButton(onPressed: () => setState(() => _switched = !_switched), child: const Text('Switch')),
          ]),
          gap,
          AnimatedContainer(
            duration: ms800,
            width: _big ? 260 : 120,
            height: _big ? 90 : 56,
            decoration: BoxDecoration(
              color: _big ? Colors.orange : Colors.blueGrey,
              borderRadius: BorderRadius.circular(_big ? 32 : 8),
            ),
            alignment: Alignment.center,
            child: const Text('AnimatedContainer', style: TextStyle(color: Colors.white)),
          ),
          gap,
          AnimatedOpacity(
            duration: ms800,
            opacity: _big ? 0.25 : 1,
            child: const Text('Fading text', style: TextStyle(fontSize: 20)),
          ),
          gap,
          Container(
            height: 56,
            color: Colors.grey.shade200,
            child: AnimatedAlign(
              duration: ms800,
              alignment: _big ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(width: 48, height: 40, color: Colors.teal),
            ),
          ),
          gap,
          SizedBox(
            height: 60,
            child: Stack(children: [
              AnimatedPositioned(
                duration: ms800,
                left: _big ? 200 : 0,
                top: _big ? 20 : 0,
                child: Container(width: 60, height: 36, color: Colors.deepPurple),
              ),
            ]),
          ),
          AnimatedPadding(
            duration: ms800,
            padding: EdgeInsets.only(left: _big ? 80 : 0),
            child: AnimatedDefaultTextStyle(
              duration: ms800,
              style: TextStyle(
                  fontSize: _big ? 24 : 14,
                  color: _big ? Colors.red : Colors.black87,
                  fontWeight: _big ? FontWeight.bold : FontWeight.normal),
              child: const Text('Padding and style'),
            ),
          ),
          gap,
          AnimatedCrossFade(
            duration: ms800,
            crossFadeState: _big ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: Container(height: 40, color: Colors.amber, alignment: Alignment.center, child: const Text('First child')),
            secondChild: Container(height: 60, color: Colors.lightGreen, alignment: Alignment.center, child: const Text('Second child')),
          ),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            SlideTransition(
              position: Tween(begin: Offset.zero, end: const Offset(0.8, 0)).animate(_c),
              child: Container(width: 44, height: 44, color: Colors.red),
            ),
            ScaleTransition(
              scale: Tween(begin: 1.0, end: 0.4).animate(_c),
              child: Container(width: 44, height: 44, color: Colors.green),
            ),
            RotationTransition(
              turns: Tween(begin: 0.0, end: 0.25).animate(_c),
              child: Container(width: 60, height: 30, color: Colors.blue),
            ),
            FadeTransition(
              opacity: Tween(begin: 1.0, end: 0.15).animate(_c),
              child: Container(width: 44, height: 44, color: Colors.black),
            ),
          ]),
          gap,
          SizeTransition(
            sizeFactor: Tween(begin: 1.0, end: 0.3).animate(_c),
            alignment: Alignment.topCenter,
            child: Container(height: 60, color: Colors.cyan, alignment: Alignment.center, child: const Text('SizeTransition')),
          ),
          gap,
          DecoratedBoxTransition(
            decoration: DecorationTween(
              begin: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(0), border: Border.all(color: Colors.grey)),
              end: BoxDecoration(color: Colors.pink.shade100, borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.pink, width: 3)),
            ).animate(_c),
            child: const SizedBox(height: 50, child: Center(child: Text('DecoratedBoxTransition'))),
          ),
          gap,
          Row(children: [
            FilledButton.tonal(
              onPressed: () {
                _items.insert(0, 'List item ${_next++}');
                _list.currentState!.insertItem(0, duration: const Duration(milliseconds: 400));
              },
              child: const Text('Add item'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () {
                if (_items.isEmpty) return;
                final removed = _items.removeAt(0);
                _list.currentState!.removeItem(
                    0, (_, a) => _listItem(removed, a),
                    duration: const Duration(milliseconds: 400));
              },
              child: const Text('Remove item'),
            ),
          ]),
          AnimatedList(
            key: _list,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            initialItemCount: _items.length,
            itemBuilder: (_, i, a) => _listItem(_items[i], a),
          ),
          gap,
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: Container(
              key: ValueKey(_switched),
              height: 50,
              color: _switched ? Colors.indigo : Colors.orange,
              alignment: Alignment.center,
              child: Text(_switched ? 'Switched in' : 'Switched out',
                  style: const TextStyle(color: Colors.white)),
            ),
          ),
          gap,
          Center(
            child: GestureDetector(
              key: AnimationsPage.heroKey,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const _HeroDetail())),
              child: const Hero(
                  tag: 'hero',
                  child: CircleAvatar(radius: 30, backgroundColor: Colors.red, child: Text('Hero'))),
            ),
          ),
          const SizedBox(height: 300),
        ],
      ),
    );
  }
}

class _HeroDetail extends StatelessWidget {
  const _HeroDetail();

  @override
  Widget build(BuildContext context) {
    return page(
      'Hero detail',
      const Column(children: [
        SizedBox(height: 40),
        Center(
            child: Hero(
                tag: 'hero',
                child: CircleAvatar(
                    radius: 80,
                    backgroundColor: Colors.red,
                    child: Text('Hero', style: TextStyle(fontSize: 28))))),
        SizedBox(height: 24),
        Text('The avatar flew here.'),
      ]),
    );
  }
}

class DragDropPage extends StatefulWidget {
  const DragDropPage({super.key});

  static final basketKey = GlobalKey();

  @override
  State<DragDropPage> createState() => _DragDropPageState();
}

class _DragDropPageState extends State<DragDropPage> {
  final _basket = <String>[];
  final _tasks = ['Task 1', 'Task 2', 'Task 3', 'Task 4'];
  final _swipes = ['Swipe me 1', 'Swipe me 2', 'Swipe me 3'];

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    return page(
      'Drag & drop',
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header('Drag a fruit into the basket'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final fruit in ['Apple', 'Banana', 'Cherry'])
              if (!_basket.contains(fruit))
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: LongPressDraggable<String>(
                    data: fruit,
                    feedback: Material(
                      color: Colors.transparent,
                      child: Chip(label: Text(fruit), backgroundColor: Colors.amber),
                    ),
                    childWhenDragging: Opacity(opacity: 0.3, child: Chip(label: Text(fruit))),
                    child: Chip(label: Text(fruit)),
                  ),
                ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: DragTarget<String>(
            key: DragDropPage.basketKey,
            onAcceptWithDetails: (details) => setState(() => _basket.add(details.data)),
            builder: (context, candidates, _) => Container(
              height: 80,
              decoration: BoxDecoration(
                color: candidates.isEmpty ? Colors.grey.shade200 : Colors.green.shade100,
                border: Border.all(
                    color: candidates.isEmpty ? Colors.grey : Colors.green, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(candidates.isNotEmpty
                  ? 'Drop it here'
                  : 'Basket: ${_basket.isEmpty ? 'empty' : _basket.join(', ')}'),
            ),
          ),
        ),
        _header('Hold a task to move it'),
        SizedBox(
          height: 4 * 56,
          child: ReorderableListView(
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => setState(() => _tasks.insert(to, _tasks.removeAt(from))),
            children: [
              for (final (i, task) in _tasks.indexed)
                ReorderableDelayedDragStartListener(
                  key: ValueKey(task),
                  index: i,
                  child: Material(
                    child: SizedBox(
                      height: 56,
                      child: ListTile(
                        leading: const Icon(Icons.drag_indicator),
                        title: Text(task),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _header('Swipe to delete'),
        for (final item in _swipes)
          Dismissible(
            key: ValueKey(item),
            direction: DismissDirection.endToStart,
            onDismissed: (_) => setState(() => _swipes.remove(item)),
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Text('Delete', style: TextStyle(color: Colors.white)),
            ),
            child: Material(child: ListTile(title: Text(item))),
          ),
      ]),
    );
  }
}

class ZoomPanPage extends StatefulWidget {
  const ZoomPanPage({super.key});

  static final viewerKey = GlobalKey();
  static final boxKey = GlobalKey();

  @override
  State<ZoomPanPage> createState() => _ZoomPanPageState();
}

class _ZoomPanPageState extends State<ZoomPanPage> {
  Offset _box = const Offset(16, 16);
  bool _doubleTapped = false;
  bool _held = false;

  @override
  Widget build(BuildContext context) {
    return page(
      'Zoom & pan',
      Column(children: [
        const Padding(padding: EdgeInsets.all(8), child: Text('Pinch to zoom, drag to pan')),
        Container(
          key: ZoomPanPage.viewerKey,
          height: 240,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
          child: ClipRect(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: GridView.count(
                crossAxisCount: 4,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final row in ['A', 'B', 'C', 'D'])
                    for (var col = 1; col <= 4; col++)
                      Container(
                        margin: const EdgeInsets.all(2),
                        color: Colors.primaries[(row.codeUnitAt(0) * 3 + col) % Colors.primaries.length]
                            .shade200,
                        alignment: Alignment.center,
                        child: Text('$row$col'),
                      ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Stack(children: [
            Positioned(
              left: _box.dx,
              top: _box.dy,
              child: GestureDetector(
                key: ZoomPanPage.boxKey,
                onPanUpdate: (details) => setState(() => _box += details.delta),
                child: Container(
                  width: 100,
                  height: 60,
                  decoration: BoxDecoration(
                      color: Colors.indigo, borderRadius: BorderRadius.circular(8)),
                  alignment: Alignment.center,
                  child: const Text('Drag me', style: TextStyle(color: Colors.white)),
                ),
              ),
            ),
            Positioned(
              left: 16,
              bottom: 24,
              child: GestureDetector(
                onDoubleTap: () => setState(() => _doubleTapped = !_doubleTapped),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  color: _doubleTapped ? Colors.green : Colors.orange,
                  child: Text(_doubleTapped ? 'Double tapped' : 'Double tap me'),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 24,
              child: GestureDetector(
                onLongPress: () => setState(() => _held = true),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  color: _held ? Colors.purple.shade200 : Colors.blueGrey.shade100,
                  child: Text(_held ? 'Held!' : 'Hold me'),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
