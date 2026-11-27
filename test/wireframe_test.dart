import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter, instantiateImageCodec;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart'
    show CupertinoAlertDialog, CupertinoDialogAction, showCupertinoDialog;
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:traceway/src/core/merge.dart';
import 'package:traceway/src/core/settings.dart';
import 'package:traceway/src/screen_recorder.dart';
import 'package:traceway/src/traceway_client.dart';
import 'package:traceway/src/traceway_options.dart';
import 'package:traceway/src/traceway_screen_capture_mode.dart';
import 'package:traceway/src/traceway_mask_mode.dart';
import 'package:traceway/src/traceway_privacy_mask.dart';
import 'package:traceway/src/traceway_widget.dart';
import 'package:traceway/src/wireframe/capture.dart';
import 'package:traceway/src/wireframe/diff.dart';
import 'package:traceway/src/wireframe/glyphs.dart';
import 'package:traceway/src/wireframe/vnode.dart';
import 'package:traceway/src/wireframe/wireframe_recorder.dart';

/// What rrweb's replayer does with a page, closely enough to tell whether
/// our events rebuild the screen: a mirror of ids to nodes, a full snapshot
/// builds the whole tree, a mutation applies removes, then adds (each
/// built without its children and inserted before `nextId`), then texts and
/// attributes. Stricter than rrweb: an add whose parent or next sibling is
/// not on the page yet fails instead of waiting in a queue, and an id that
/// is already on the page fails instead of orphaning the old node.
class Mirror {
  final Map<int, DomNode> byId = {};
  DomNode? document;

  void fullSnapshot(Map<String, Object?> node) {
    byId.clear();
    document = _build(node, withChildren: true);
  }

  DomNode _build(Map<String, Object?> n, {required bool withChildren}) {
    final id = n['id'] as int;
    expect(byId.containsKey(id), isFalse, reason: 'id $id added twice');
    final type = n['type'] as int;
    final node = DomNode(
      id,
      type == 2 ? n['tagName'] as String : null,
      type == 3 ? n['textContent'] as String : null,
      type == 2
          ? Map<String, String>.from(n['attributes'] as Map)
          : <String, String>{},
    );
    byId[id] = node;
    if (withChildren) {
      for (final child in (n['childNodes'] as List? ?? const [])) {
        final built = _build(Map<String, Object?>.from(child as Map),
            withChildren: true);
        built.parent = node;
        node.children.add(built);
      }
    }
    return node;
  }

  void _unmap(DomNode node) {
    byId.remove(node.id);
    for (final child in node.children) {
      _unmap(child);
    }
  }

  void mutation(Map<String, Object?> data) {
    expect(data['source'], 0);
    for (final key in ['removes', 'adds', 'texts', 'attributes']) {
      expect(data[key], isA<List>(), reason: '$key must be a list');
    }
    for (final r in (data['removes'] as List).cast<Map>()) {
      final node = byId[r['id']];
      final parent = byId[r['parentId']];
      expect(node, isNotNull, reason: 'remove of missing ${r['id']}');
      expect(parent, isNotNull, reason: 'remove from missing ${r['parentId']}');
      expect(parent!.children.contains(node), isTrue,
          reason: '${r['id']} is not a child of ${r['parentId']}');
      parent.children.remove(node);
      _unmap(node!);
    }
    for (final a in (data['adds'] as List).cast<Map>()) {
      final parent = byId[a['parentId']];
      expect(parent, isNotNull, reason: 'add under missing ${a['parentId']}');
      final nextId = a['nextId'] as int?;
      final node = _build(Map<String, Object?>.from(a['node'] as Map),
          withChildren: false);
      node.parent = parent;
      if (nextId == null) {
        parent!.children.add(node);
      } else {
        final next = byId[nextId];
        expect(next, isNotNull, reason: 'add before missing $nextId');
        final at = parent!.children.indexOf(next!);
        expect(at, greaterThanOrEqualTo(0),
            reason: '$nextId is not a child of ${a['parentId']}');
        parent.children.insert(at, node);
      }
    }
    for (final t in (data['texts'] as List).cast<Map>()) {
      final node = byId[t['id']];
      expect(node?.tag, isNull, reason: 'text change of a non-text node');
      node!.text = t['value'] as String;
    }
    for (final a in (data['attributes'] as List).cast<Map>()) {
      final node = byId[a['id']];
      expect(node, isNotNull);
      (a['attributes'] as Map).forEach((key, value) {
        if (value == null) {
          node!.attributes.remove(key);
        } else {
          node!.attributes[key as String] = value as String;
        }
      });
    }
  }

  /// Plays [events] in order.
  void play(List<Map<String, Object?>> events) {
    for (final event in events) {
      switch (event['type']) {
        case 2:
          fullSnapshot(Map<String, Object?>.from(
              (event['data'] as Map)['node'] as Map));
        case 3:
          final data = Map<String, Object?>.from(event['data'] as Map);
          if (data['source'] == 0) mutation(data);
          if (data['source'] == 2) {
            expect(byId.containsKey(data['id']), isTrue,
                reason: 'interaction with a node not on the page');
          }
      }
    }
  }

  DomNode get screen => byId[screenNodeId]!;
}

class DomNode {
  DomNode(this.id, this.tag, this.text, this.attributes);
  final int id;
  final String? tag;
  String? text;
  final Map<String, String> attributes;
  final List<DomNode> children = [];
  DomNode? parent;

  String dump() => tag == null
      ? '#$id"$text"'
      : '#$id<$tag ${(attributes.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(' ')}>'
          '[${children.map((c) => c.dump()).join(',')}]';
}

String dumpVNode(VNode n) => n.isText
    ? '#${n.id}"${n.text}"'
    : '#${n.id}<${n.tag} ${(n.attributes.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(' ')}>'
        '[${n.children.map(dumpVNode).join(',')}]';

Iterable<VNode> allNodes(VNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* allNodes(c);
  }
}

String allText(VNode n) =>
    allNodes(n).where((x) => x.isText).map((x) => x.text).join('|');

VNode? withText(VNode root, String text) {
  for (final n in allNodes(root)) {
    if (!n.isText && n.children.any((c) => c.isText && c.text == text)) return n;
  }
  return null;
}

double styleNumber(VNode n, String property) {
  final match = RegExp('(?:^|;)$property:(-?[0-9.]+)px')
      .firstMatch(n.attributes['style'] ?? '');
  expect(match, isNotNull, reason: '$property in ${n.attributes['style']}');
  return double.parse(match!.group(1)!);
}

/// The position of [node] on screen, summing the offsets of its ancestors.
Offset screenPosition(VNode root, VNode node) {
  Offset? walk(VNode at, Offset origin) {
    final style = at.attributes['style'] ?? '';
    final left = RegExp(r'(?:^|;)left:(-?[0-9.]+)px').firstMatch(style);
    final top = RegExp(r'(?:^|;)top:(-?[0-9.]+)px').firstMatch(style);
    final here = origin +
        Offset(left == null ? 0 : double.parse(left.group(1)!),
            top == null ? 0 : double.parse(top.group(1)!));
    if (identical(at, node)) return here;
    for (final c in at.children) {
      final found = walk(c, here);
      if (found != null) return found;
    }
    return null;
  }

  return walk(root, Offset.zero)!;
}

// ---- random trees for the diff ------------------------------------------------

class _TreeGen {
  _TreeGen(this.random);
  final Random random;
  int nextId = 100;
  static const tags = ['div', 'span', 'img'];

  VNode node(int depth) {
    if (depth > 0 && random.nextInt(4) == 0) {
      return VNode.text(nextId++, 'text${random.nextInt(50)}');
    }
    final children = depth >= 4
        ? <VNode>[]
        : [for (var i = random.nextInt(4); i > 0; i--) node(depth + 1)];
    return VNode.element(nextId++, tags[random.nextInt(tags.length)],
        {'style': 'left:${random.nextInt(9)}px'}, children);
  }

  VNode screen() => VNode.element(screenNodeId, 'div', const {'id': 'tw'},
      [for (var i = 1 + random.nextInt(4); i > 0; i--) node(1)]);

  /// [tree] with one random edit, sharing every subtree the edit does not
  /// touch.
  VNode edit(VNode tree) {
    final nodes = allNodes(tree).toList();
    final target = nodes[random.nextInt(nodes.length)];
    switch (random.nextInt(7)) {
      case 0: // attribute
        if (target.isText) return _replace(tree, target, VNode.text(target.id, 'edited${random.nextInt(9)}'));
        return _replace(
            tree,
            target,
            VNode.element(target.id, target.tag!,
                {'style': 'left:${random.nextInt(99)}px', if (random.nextBool()) 'class': 'c'}, target.children));
      case 1: // insert a new subtree
        if (target.isText) return tree;
        final children = List.of(target.children)
          ..insert(random.nextInt(target.children.length + 1), node(2));
        return _replace(tree, target, _withChildren(target, children));
      case 2: // delete a subtree
        if (identical(target, tree)) return tree;
        return _remove(tree, target);
      case 3: // reorder children
        if (target.isText || target.children.length < 2) return tree;
        return _replace(
            tree, target, _withChildren(target, List.of(target.children)..shuffle(random)));
      case 4: // move a subtree under another parent
        if (identical(target, tree)) return tree;
        final without = _remove(tree, target);
        final hosts = allNodes(without).where((n) => !n.isText).toList();
        final host = hosts[random.nextInt(hosts.length)];
        final children = List.of(host.children)
          ..insert(random.nextInt(host.children.length + 1), target);
        return _replace(without, host, _withChildren(host, children));
      case 5: // same id, different tag
        if (target.isText || identical(target, tree)) return tree;
        return _replace(tree, target,
            VNode.element(target.id, target.tag == 'div' ? 'span' : 'div', target.attributes, target.children));
      default: // a text node becomes an element with the same id
        if (!target.isText) return tree;
        return _replace(tree, target, VNode.element(target.id, 'div', const {}, const []));
    }
  }

  static VNode _withChildren(VNode n, List<VNode> children) =>
      VNode.element(n.id, n.tag!, n.attributes, children);

  static VNode _replace(VNode tree, VNode target, VNode replacement) {
    if (identical(tree, target)) return replacement;
    if (tree.isText) return tree;
    var changed = false;
    final children = [
      for (final c in tree.children)
        () {
          final r = _replace(c, target, replacement);
          if (!identical(r, c)) changed = true;
          return r;
        }(),
    ];
    return changed ? _withChildren(tree, children) : tree;
  }

  static VNode _remove(VNode tree, VNode target) {
    if (tree.isText) return tree;
    var changed = false;
    final children = <VNode>[];
    for (final c in tree.children) {
      if (identical(c, target)) {
        changed = true;
        continue;
      }
      final r = _remove(c, target);
      if (!identical(r, c)) changed = true;
      children.add(r);
    }
    return changed ? _withChildren(tree, children) : tree;
  }
}

Map<String, Object?> _fullSnapshotOf(VNode screen) => {
      'type': 2,
      'data': {'node': serializeDocument(screen)},
    };

// ---- widget helpers -------------------------------------------------------

final _rootKey = GlobalKey();

Widget _app(Widget home, {ThemeData? theme}) => RepaintBoundary(
      key: _rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: home,
      ),
    );

VNode _capture(WireframeCapture capture) =>
    capture.capture(_rootKey.currentContext! as Element, DateTime.now())!.screen!;

void main() {
  group('diffScreens', () {
    test('is null between the same screen', () {
      final a = _TreeGen(Random(1)).screen();
      expect(diffScreens(a, a), isNull);
    });

    test('turns every random screen into its edit, as rrweb replays it', () {
      final random = Random(42);
      for (var round = 0; round < 400; round++) {
        final gen = _TreeGen(random)..nextId = 100 + round * 1000;
        var before = gen.screen();
        var after = before;
        for (var i = random.nextInt(6) + 1; i > 0; i--) {
          after = gen.edit(after);
        }
        final mirror = Mirror()..play([_fullSnapshotOf(before)]);
        expect(mirror.screen.dump(), dumpVNode(before));
        final mutation = diffScreens(before, after);
        if (mutation == null) {
          expect(dumpVNode(after), dumpVNode(before));
          continue;
        }
        mirror.mutation(mutation);
        expect(mirror.screen.dump(), dumpVNode(after), reason: 'round $round');
        before = after;
      }
    });

    test('changes one attribute without touching the rest', () {
      final text = VNode.text(101, 'hi');
      final a = VNode.element(screenNodeId, 'div', const {}, [
        VNode.element(100, 'div', const {'style': 'left:1px'}, [text]),
      ]);
      final b = VNode.element(screenNodeId, 'div', const {}, [
        VNode.element(100, 'div', const {'style': 'left:2px'}, [text]),
      ]);
      final m = diffScreens(a, b)!;
      expect(m['adds'], isEmpty);
      expect(m['removes'], isEmpty);
      expect(m['attributes'], [
        {
          'id': 100,
          'attributes': {'style': 'left:2px'},
        }
      ]);
    });
  });

  group('WireframeCapture', () {
    testWidgets('draws boxes, text, decorations and their positions',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(Scaffold(
        appBar: AppBar(title: const Text('Wireframe')),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Container(width: 50, height: 20, color: const Color(0xFFFF0000)),
            Container(
              margin: const EdgeInsets.only(left: 30),
              width: 100,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF00FF00),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF0000FF), width: 2),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Color(0x40000000))],
              ),
            ),
            Container(
              width: 60,
              height: 30,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFFFFFFFF), Color(0xFF000000)]),
              ),
            ),
            const Text('Hello', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
      )));
      final screen = _capture(WireframeCapture());
      final styles = allNodes(screen).map((n) => n.attributes['style'] ?? '').toList();
      expect(styles.any((s) => s.contains('background-color:#ff0000') && s.contains('width:50px')), isTrue);
      final green = allNodes(screen).firstWhere(
          (n) => (n.attributes['style'] ?? '').contains('background-color:#00ff00'));
      expect(green.attributes['style'], contains('border-radius:8px'));
      expect(green.attributes['style'], contains('inset 0 0 0 2px #0000ff'));
      expect(green.attributes['style'], contains('0px 0px 4px 0px rgba(0,0,0,0.251)'));
      expect(styles.any((s) => s.contains('linear-gradient(90deg,#ffffff,#000000)')), isTrue);

      final hello = withText(screen, 'Hello')!;
      expect(hello.attributes['class'], 't n');
      expect(hello.attributes['style'], contains('font-size:20px'));
      expect(hello.attributes['style'], contains('font-weight:700'));
      final bodyTop = tester.getTopLeft(find.text('Hello'));
      expect(screenPosition(screen, hello), Offset(bodyTop.dx, bodyTop.dy));
      expect(screenPosition(screen, green).dx, 30);
      expect(allText(screen), contains('Wireframe'));
    });

    testWidgets('scrolls a list by moving one content node', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      await tester.pumpWidget(_app(Scaffold(
        body: ListView.builder(
          controller: controller,
          itemCount: 100,
          itemExtent: 50,
          itemBuilder: (_, i) => Text('Item $i'),
        ),
      )));
      final capture = WireframeCapture();
      final before = _capture(capture);
      expect(allText(before), contains('Item 0'));
      expect(allText(before), isNot(contains('Item 40')));
      controller.jumpTo(20);
      await tester.pump();
      final after = _capture(capture);
      final m = diffScreens(before, after)!;
      // The items keep their place in the content node; only the row that
      // scrolled into view is new.
      expect(m['removes'], isEmpty);
      expect(m['attributes'], hasLength(1));
      expect(((m['attributes'] as List).single as Map)['attributes'],
          {'style': 'left:0px;top:-20px;'});
      expect([
        for (final add in (m['adds'] as List).cast<Map>())
          if ((add['node'] as Map)['type'] == 3) (add['node'] as Map)['textContent']
      ], ['Item 16']);

      controller.jumpTo(2000);
      await tester.pump();
      final far = _capture(capture);
      expect(allText(far), contains('Item 40'));
      expect(allText(far), isNot(contains('Item 0|')));
      final mirror = Mirror()..play([_fullSnapshotOf(after)]);
      mirror.mutation(diffScreens(after, far)!);
      expect(mirror.screen.dump(), dumpVNode(far));
      final item = withText(far, 'Item 40')!;
      expect(screenPosition(far, item).dy, tester.getTopLeft(find.text('Item 40')).dy);
    });

    testWidgets('leaves out what is not painted', (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: Column(children: [
          const IndexedStack(index: 1, children: [Text('tab A'), Text('tab B')]),
          const Offstage(child: Text('offstage')),
          const Opacity(opacity: 0, child: Text('invisible')),
          const Visibility(visible: false, maintainState: true, child: Text('hidden')),
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const Scaffold(body: Text('second page')))),
              child: const Text('open'),
            ),
          ),
        ]),
      )));
      var screen = _capture(WireframeCapture());
      final text = allText(screen);
      expect(text, contains('tab B'));
      expect(text, isNot(contains('tab A')));
      expect(text, isNot(contains('offstage')));
      expect(text, isNot(contains('invisible')));
      expect(text, isNot(contains('hidden')));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      screen = _capture(WireframeCapture());
      expect(allText(screen), contains('second page'));
      expect(allText(screen), isNot(contains('tab B')),
          reason: 'the page under an opaque route is not painted');
    });

    testWidgets('a dialog shows over the page', (tester) async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AlertDialog(title: Text('Sure?')),
            ),
            child: const Text('page'),
          ),
        ),
      )));
      await tester.tap(find.text('page'));
      await tester.pumpAndSettle();
      final screen = _capture(WireframeCapture());
      final text = allText(screen);
      expect(text, contains('page'));
      expect(text, contains('Sure?'));
      expect(text.indexOf('page'), lessThan(text.indexOf('Sure?')),
          reason: 'the dialog is above the page');
    });

    testWidgets('masks what privacy masks and text fields hold',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: Column(children: [
          const TracewayPrivacyMask(
            mode: TracewayMaskBlank(color: Color(0xFF123456)),
            child: Text('secret blank'),
          ),
          const TracewayPrivacyMask(child: Text('secret blur')),
          TextField(controller: TextEditingController(text: 'typed text')),
          TextField(
            obscureText: true,
            controller: TextEditingController(text: 'hunter2'),
          ),
        ]),
      )));
      final capture = WireframeCapture();
      var screen = _capture(capture);
      final text = allText(screen);
      expect(text, isNot(contains('secret')));
      expect(text, contains('****** ****'));
      expect(text, contains('***** ****'));
      expect(text, isNot(contains('typed')));
      expect(text, isNot(contains('hunter2')));
      expect(text, contains('•••••••'));
      expect(
          allNodes(screen).any((n) =>
              (n.attributes['style'] ?? '').contains('background:#123456')),
          isTrue);

      capture.maskAllInputs = false;
      screen = _capture(capture);
      expect(allText(screen), contains('typed text'));
      expect(allText(screen), isNot(contains('hunter2')));
    });

    testWidgets('transforms, fades, toggles, icons and rich text',
        (tester) async {
      final image = (await tester.runAsync(() => createTestImage(width: 2, height: 2)))!;
      await tester.pumpWidget(_app(Scaffold(
        body: Column(children: [
          Transform.rotate(
            angle: pi / 2,
            child: Container(width: 40, height: 20, color: const Color(0xFF00FFFF)),
          ),
          const Opacity(
            opacity: 0.5,
            child: SizedBox(width: 40, height: 20, child: ColoredBox(color: Color(0xFFFF00FF))),
          ),
          Checkbox(value: true, onChanged: (_) {}),
          Switch(value: false, onChanged: (_) {}),
          const Icon(Icons.home, color: Color(0xFF112233)),
          const Text.rich(TextSpan(text: 'plain ', children: [
            TextSpan(text: 'bold', style: TextStyle(fontWeight: FontWeight.bold)),
          ])),
          RawImage(image: image, width: 30, height: 30),
          const CircularProgressIndicator(value: 0.25),
        ]),
      )));
      await tester.pump(const Duration(seconds: 1));
      final screen = _capture(WireframeCapture());
      final styles = allNodes(screen).map((n) => n.attributes['style'] ?? '').toList();
      final rotated = styles.firstWhere((s) => s.contains('#00ffff'));
      expect(rotated, contains('transform:matrix(0,1,-1,0,'));
      final faded = allNodes(screen).firstWhere((n) =>
          (n.attributes['style'] ?? '').contains('opacity:0.5'));
      expect(allNodes(faded).any((n) => (n.attributes['style'] ?? '').contains('#ff00ff')), isTrue);
      expect(styles.any((s) => s.contains('width:18px;height:18px') && s.contains('background-color')), isTrue,
          reason: 'a checked checkbox');
      expect(styles.any((s) => s.contains('width:52px;height:32px')), isTrue, reason: 'a switch track');
      expect(allNodes(screen).any((n) => n.attributes['class'] == 'ic' &&
          n.attributes['style']!.contains('color:#112233')), isTrue);
      final bold = allNodes(screen).firstWhere((n) => n.tag == 'span' &&
          n.children.single.text == 'bold');
      expect(bold.attributes['style'], contains('font-weight:700'));
      expect(allNodes(screen).any((n) => n.attributes['class'] == 'im'), isTrue);
      expect(styles.any((s) => s.contains('conic-gradient') && s.contains('25%')), isTrue);
    });

    testWidgets('an OverlayPortal child is placed on top of the screen',
        (tester) async {
      final controller = OverlayPortalController()..show();
      await tester.pumpWidget(_app(Scaffold(
        body: ClipRect(
          child: SizedBox(
            width: 50,
            height: 50,
            child: OverlayPortal(
              controller: controller,
              overlayChildBuilder: (_) => const Positioned(
                left: 200,
                top: 300,
                child: Text('menu'),
              ),
              child: const Text('anchor'),
            ),
          ),
        ),
      )));
      await tester.pump();
      final screen = _capture(WireframeCapture());
      final menu = withText(screen, 'menu')!;
      expect(screen.children.last.id, menu.id,
          reason: 'last child of the screen, outside the clip');
      expect(screenPosition(screen, menu), const Offset(200, 300));
    });
    testWidgets('a table draws its row backgrounds and its border',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: Table(
          border: TableBorder.all(color: const Color(0xFF00AA00), width: 2),
          children: const [
            TableRow(
                decoration: BoxDecoration(color: Color(0xFFEEEEFF)),
                children: [Text('a'), Text('b')]),
            TableRow(children: [Text('c'), Text('d')]),
          ],
        ),
      )));
      final screen = _capture(WireframeCapture());
      final styles = allNodes(screen).map((n) => n.attributes['style'] ?? '').toList();
      expect(styles.where((s) => s.contains('background-color:#eeeeff')), hasLength(1));
      expect(styles.where((s) => s.contains('background-color:#00aa00')), hasLength(2),
          reason: 'one line between the rows, one between the columns');
      expect(styles.where((s) => s.contains('inset 0 0 0 2px #00aa00')), hasLength(1));
      expect(allText(screen), 'a|b|c|d');
    });

    testWidgets('a pinned app bar paints over the content under it',
        (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(_app(Scaffold(
        body: CustomScrollView(controller: controller, slivers: [
          const SliverAppBar(pinned: true, title: Text('Pinned')),
          SliverList.builder(
            itemCount: 50,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('Line $i')),
          ),
        ]),
      )));
      controller.jumpTo(200);
      await tester.pump();
      final screen = _capture(WireframeCapture());
      final order = allNodes(screen).where((n) => n.isText).map((n) => n.text).toList();
      expect(order.last, 'Pinned', reason: 'the header paints last, on top');
      expect(order, contains('Line 4'));
    });

    testWidgets('a field paints its fill under its label', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: TextField(decoration: InputDecoration(labelText: 'Filled', filled: true)),
        ),
      )));
      final screen = _capture(WireframeCapture());
      final nodes = allNodes(screen).toList();
      final fill = nodes.indexWhere((n) =>
          (n.attributes['style'] ?? '').contains('background-color') &&
          (n.attributes['style'] ?? '').contains('box-shadow:inset'));
      final label = nodes.indexOf(withText(screen, 'Filled')!);
      expect(fill, greaterThanOrEqualTo(0));
      expect(fill, lessThan(label));
    });

    testWidgets('a line of text spills over instead of being cut, unless '
        'Flutter cut it', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: SizedBox(
          width: 120,
          child: Column(children: [
            SizedBox(width: 120, child: Text('Centered', textAlign: TextAlign.center)),
            Text('A line far too long for its box', maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('Two lines that wrap around in the narrow box'),
          ]),
        ),
      )));
      final screen = _capture(WireframeCapture());
      final centered = withText(screen, 'Centered')!;
      expect(centered.attributes['class'], 't n');
      expect(centered.attributes['style'], contains('justify-content:center'));
      expect(withText(screen, 'A line far too long for its box')!.attributes['class'], 't n e');
      expect(withText(screen, 'Two lines that wrap around in the narrow box')!.attributes['class'], 't');
    });

    testWidgets('perspective, odd shapes, filters and segmented buttons',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(children: [
          Transform(
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.002)
              ..rotateY(0.6),
            child: Container(
                key: const ValueKey('card'), width: 200, height: 80, color: Colors.indigo),
          ),
          Container(
            width: 120,
            height: 60,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.red),
          ),
          const SizedBox(
            width: 60,
            height: 60,
            child: DecoratedBox(
                decoration: ShapeDecoration(color: Colors.amber, shape: StarBorder())),
          ),
          ClipPath(
            clipper: const _Triangle(),
            child: Container(width: 100, height: 50, color: Colors.green),
          ),
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
            child: Container(width: 50, height: 20, color: Colors.blue),
          ),
          ColorFiltered(
            colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation),
            child: Container(width: 50, height: 20, color: Colors.orange),
          ),
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: const SizedBox(width: 80, height: 30),
            ),
          ),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('One')),
              ButtonSegment(value: 2, label: Text('Two')),
              ButtonSegment(value: 3, label: Text('Three')),
            ],
            selected: const {1},
            onSelectionChanged: (_) {},
          ),
          const SelectableText('Read-only words'),
        ]),
      )));
      final screen = _capture(WireframeCapture());
      String styles() => allNodes(screen).map((n) => n.attributes['style'] ?? '').join('\n');
      final all = styles();
      // The card keeps its perspective.
      expect(all, contains('transform:matrix3d('));
      final m3d = RegExp(r'matrix3d\(([^)]*)\)').firstMatch(all)![1]!.split(',');
      expect(m3d, hasLength(16));
      expect(double.parse(m3d[3]), isNot(0), reason: 'the perspective row');
      // A circle in a wide box (a list makes it 800 wide) is a circle in
      // its middle.
      expect(all, contains('left:370px;top:0px;width:60px;height:60px;background-color:#f44336;border-radius:50%;'));
      expect(all, contains("clip-path:path('M"));
      expect(RegExp("clip-path:path").allMatches(all), hasLength(2));
      expect(all, contains('filter:blur(3px);'));
      expect(all, contains('filter:grayscale(1);'));
      expect(all, contains('backdrop-filter:blur(8px);'));
      // Two lines between three segments, and the outline round them.
      expect(RegExp(r'width:1px;height:40px;background-color:').allMatches(all), hasLength(2));
      expect(all, contains('top:4px;width:800px;height:40px;border-radius:20px;box-shadow:inset 0 0 0 1px'));
      expect(allText(screen), contains('Read-only words'));
    });

    testWidgets('rich text under perspective keeps every node id unique',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: Transform(
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..rotateY(0.4),
          child: const Text.rich(TextSpan(text: 'one ', children: [
            TextSpan(text: 'two ', style: TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: 'three ', style: TextStyle(fontStyle: FontStyle.italic)),
            TextSpan(text: 'four', style: TextStyle(color: Color(0xFFFF0000))),
          ])),
        ),
      )));
      final screen = _capture(WireframeCapture());
      expect(allNodes(screen).map((n) => n.attributes['style'] ?? '').join(),
          contains('matrix3d('));
      expect(allText(screen), 'one |two |three |four');
      final ids = allNodes(screen).map((n) => n.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids $ids');
      // rrweb's mirror holds one node per id.
      Mirror().play([_fullSnapshotOf(screen)]);
    });

    testWidgets('a Cupertino alert keeps its frosted backdrop', (tester) async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showCupertinoDialog<void>(
              context: context,
              builder: (_) => const CupertinoAlertDialog(
                title: Text('Sign out?'),
                actions: [CupertinoDialogAction(child: Text('Stay'))],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final capture = WireframeCapture();
      final screen = _capture(capture);
      expect(capture.lastError, isNull);
      expect(allText(screen), allOf(contains('Sign out?'), contains('Stay')));
      expect(allNodes(screen).map((n) => n.attributes['style'] ?? '').join(),
          contains('backdrop-filter:blur('));
    });

    testWidgets('a widget that fails costs its own node, not the frame',
        (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: Column(children: [
          Text('before'),
          _Throwing(child: Text('inside')),
          Text('after'),
        ]),
      )));
      final capture = WireframeCapture();
      final screen = _capture(capture);
      expect(allText(screen), allOf(contains('before'), contains('after')));
      expect(allText(screen), isNot(contains('inside')));
      expect(capture.lastError, isA<StateError>());
    });

    testWidgets('an icon is drawn with a picture of its glyph', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
        body: Column(children: [
          Icon(Icons.favorite, size: 32, color: Colors.red),
          Icon(Icons.favorite, size: 32, color: Colors.blue),
          Icon(Icons.star, size: 32),
        ]),
      )));
      final ready = <Glyph>[];
      final glyphs = IconGlyphs();
      final capture = WireframeCapture()..glyphs = glyphs;
      late VNode screen;
      await tester.runAsync(() async {
        glyphs.onReady = () => ready.add(glyphs.all.last);
        screen = _capture(capture);
        // The pictures are drawn off the capture.
        for (var i = 0; i < 100 && glyphs.all.any((g) => g.css == null); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      List<String?> classes(VNode screen) => [
            for (final n in allNodes(screen))
              if ((n.attributes['class'] ?? '').startsWith('ic')) n.attributes['class']
          ];
      // One glyph for both colors of the heart.
      expect(classes(screen), ['ic g0', 'ic g0', 'ic g1']);
      expect(screen.children.where((n) => n.tag == 'style'), isEmpty);
      expect(ready, hasLength(2));

      screen = _capture(capture);
      final styles = screen.children.takeWhile((n) => n.tag == 'style').toList();
      expect(styles, hasLength(2));
      expect(styles.first.attributes['_cssText'],
          allOf(startsWith('.ic.g0::before{'), contains('mask:url(data:image/png;base64,')));
      // A style stays a while after its icons have gone.
      await tester.pumpWidget(_app(const Scaffold(body: Text('no icons'))));
      final later = capture.capture(_rootKey.currentContext! as Element,
          DateTime.now().add(const Duration(seconds: 5)))!.screen!;
      expect(later.children.where((n) => n.tag == 'style'), hasLength(2));
      final gone = capture.capture(_rootKey.currentContext! as Element,
          DateTime.now().add(const Duration(minutes: 1)))!.screen!;
      expect(gone.children.where((n) => n.tag == 'style'), isEmpty);
      // The picture is a valid PNG: a luminance mask in 4-bit gray.
      final css = styles.first.attributes['_cssText']!;
      expect(css, endsWith('no-repeat luminance}'));
      final png = base64Decode(RegExp(r'base64,([^)]+)\)').firstMatch(css)![1]!);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(png.sublist(24, 26), [4, 0], reason: '4-bit grayscale');
      final decoded = await tester.runAsync(() async {
        final codec = await instantiateImageCodec(png);
        return (await codec.getNextFrame()).image;
      });
      expect(decoded!.width, 48, reason: '32 px at 1.5x');
    });

    testWidgets('a platform view or texture is a labeled placeholder',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(children: [
          SizedBox(
            height: 200,
            child: PlatformViewLink(
              viewType: 'plugins.flutter.io/webview',
              onCreatePlatformView: _createFakePlatformView,
              surfaceFactory: (context, controller) => PlatformViewSurface(
                controller: controller,
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                gestureRecognizers: const {},
              ),
            ),
          ),
          SizedBox(
            height: 120,
            child: PlatformViewLink(
              viewType: 'com.example/rating_bar',
              onCreatePlatformView: _createFakePlatformView,
              surfaceFactory: (context, controller) => PlatformViewSurface(
                controller: controller,
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                gestureRecognizers: const {},
              ),
            ),
          ),
          const SizedBox(height: 90, child: Texture(textureId: 7)),
        ]),
      )));
      await tester.pump();
      final screen = _capture(WireframeCapture());
      final web = withText(screen, 'Web view')!;
      expect(web.attributes['class'], 'pv');
      expect(styleNumber(web, 'height'), 200);
      expect(screenPosition(screen, web).dy, 0);
      expect(screenPosition(screen, withText(screen, 'Native view')!).dy, 200);
      final video = withText(screen, 'Video')!;
      expect(screenPosition(screen, video).dy, 320);
      expect(styleNumber(video, 'height'), 90);
      expect(nativeViewLabel('plugins.flutter.dev/google_maps_android'), 'Map');
      expect(nativeViewLabel('com.pichillilorenzo/flutter_inappwebview'), 'Web view');
    });
  });

  group('WireframeRecorder', () {
    testWidgets('a clip replays to the last screen, touches included',
        (tester) async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final counter = ValueNotifier(0);
      await tester.pumpWidget(_app(Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: counter,
          builder: (_, n, __) => Column(children: [
            for (var i = 0; i <= n; i++) Text('row $i'),
          ]),
        ),
      )));
      final recorder = WireframeRecorder(
        rootKey: _rootKey,
        maxFrames: 50,
        fps: 10,
        now: () => now,
        screenName: () => '/home',
      );
      final start = now;
      recorder.start();
      await tester.pump(const Duration(milliseconds: 1));
      expect(recorder.bufferedFrameCount, 1);
      for (var i = 1; i <= 3; i++) {
        now = now.add(const Duration(milliseconds: 500));
        counter.value = i;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      }
      recorder.pointerDown(1, const Offset(10, 20), touch: true);
      recorder.pointerUp(1, const Offset(10, 20), touch: true, tap: true);
      expect(recorder.bufferedFrameCount, 4);
      now = now.add(const Duration(seconds: 2));
      final end = now;

      final clip = (await recorder.captureRecording('c', since: start, until: end))!;
      final events = clip.events.cast<Map<String, Object?>>();
      expect(events.map((e) => e['type']).toList(), [4, 2, 3, 3, 3, 3, 3, 3, 5]);
      expect(events.first['data'], {'href': '/home', 'width': 800, 'height': 600});
      final times = events.map((e) => e['timestamp'] as int).toList();
      expect(times, orderedEquals([...times]..sort()));
      expect(times.first, start.millisecondsSinceEpoch);
      expect(times.last, end.millisecondsSinceEpoch);
      expect(clip.approxBytes, greaterThan(1000));
      final mirror = Mirror()..play(events);
      expect(mirror.screen.children, isNotEmpty);
      final shown = <String>[];
      void texts(DomNode n) {
        if (n.text != null) shown.add(n.text!);
        n.children.forEach(texts);
      }
      texts(mirror.screen);
      expect(shown, containsAllInOrder(['row 0', 'row 1', 'row 2', 'row 3']));

      // A window that starts after the last change still shows the screen.
      final later = end.subtract(const Duration(seconds: 1));
      expect(recorder.hasFrames(since: later, until: end), isTrue);
      final tail = (await recorder.captureRecording('t', since: later, until: end))!;
      expect(tail.events.map((e) => e['type']).toList(), [4, 2, 5]);
      expect(tail.startedAt, later);

      // In the background nothing is on screen.
      recorder.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 5));
      expect(
          recorder.hasFrames(
              since: now.subtract(const Duration(seconds: 1)), until: now),
          isFalse);
      recorder.stop();
    });

    testWidgets('masking inputs again drops the frames that showed them',
        (tester) async {
      var now = DateTime.utc(2026, 1, 1, 12);
      await tester.pumpWidget(_app(Scaffold(
        body: TextField(controller: TextEditingController(text: 'typed text')),
      )));
      final recorder = WireframeRecorder(
          rootKey: _rootKey, maxFrames: 50, now: () => now)
        ..maskAllInputs = false;
      final start = now;
      recorder.start();
      await tester.pump(const Duration(milliseconds: 1));
      expect(recorder.bufferedFrameCount, 1);

      now = now.add(const Duration(seconds: 1));
      recorder.maskAllInputs = true;
      // The screen is taken again at once, though the app draws nothing.
      await tester.pump(const Duration(milliseconds: 1));
      expect(recorder.bufferedFrameCount, 1);
      now = now.add(const Duration(seconds: 1));
      final clip =
          (await recorder.captureRecording('c', since: start, until: now))!;
      final json = jsonEncode(clip.events);
      expect(json, isNot(contains('typed text')));
      expect(json, contains('***** ****'));
      // Unmasking keeps what was masked.
      recorder.maskAllInputs = false;
      expect(recorder.bufferedFrameCount, 1);
      recorder.stop();
    });

    testWidgets(
        'a route change is a mutation, never a Meta event without its '
        'snapshot', (tester) async {
      var now = DateTime.utc(2026, 1, 1, 12);
      var href = '/home';
      final counter = ValueNotifier(0);
      await tester.pumpWidget(_app(Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: counter,
          builder: (_, n, __) => Text('count $n'),
        ),
      )));
      final recorder = WireframeRecorder(
        rootKey: _rootKey,
        maxFrames: 50,
        fps: 10,
        now: () => now,
        screenName: () => href,
      );
      final start = now;
      recorder.start();
      await tester.pump(const Duration(milliseconds: 1));

      // Only the route's name changes; the screen stays as it was.
      now = now.add(const Duration(milliseconds: 500));
      href = '/details';
      tester.binding.scheduleFrame();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // The route and the screen change together.
      now = now.add(const Duration(milliseconds: 500));
      href = '/settings';
      counter.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      now = now.add(const Duration(seconds: 1));

      final clip =
          (await recorder.captureRecording('c', since: start, until: now))!;
      final events = clip.events.cast<Map<String, Object?>>();
      // rrweb's player seeks from the last Meta event and takes the full
      // snapshot after it as the screen: a Meta on its own would leave the
      // next mutations without their nodes.
      expect(events.map((e) => e['type']).toList(), [4, 2, 3, 5]);
      for (var i = 0; i < events.length; i++) {
        if (events[i]['type'] == 4) {
          expect(events[i + 1]['type'], 2, reason: 'event $i');
          expect(events[i + 1]['timestamp'], events[i]['timestamp']);
        }
      }
      expect((events.first['data'] as Map)['href'], '/home');
      final mirror = Mirror()..play(events);
      expect(mirror.screen.dump(), contains('"count 1"'));
      recorder.stop();
    });

    testWidgets('pointer moves go up in batches, as rrweb sends them',
        (tester) async {
      var now = DateTime.utc(2026, 1, 1, 12);
      await tester.pumpWidget(_app(const Scaffold(body: Text('drag'))));
      final recorder =
          WireframeRecorder(rootKey: _rootKey, maxFrames: 50, now: () => now);
      final start = now;
      recorder.start();
      await tester.pump(const Duration(milliseconds: 1));
      int ms() => now.millisecondsSinceEpoch;

      now = now.add(const Duration(milliseconds: 100));
      recorder.pointerDown(1, const Offset(10, 10), touch: true);
      final down = ms();
      final moved = <int>[];
      for (var i = 1; i <= 20; i++) {
        now = now.add(const Duration(milliseconds: 60));
        recorder.pointerMove(1, Offset(10.0 + i, 10), touch: true);
        moved.add(ms());
      }
      now = now.add(const Duration(milliseconds: 60));
      recorder.pointerUp(1, const Offset(30, 10), touch: true, tap: false);
      final up = ms();
      // Then a mouse hovers.
      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(milliseconds: 60));
        recorder.pointerMove(2, Offset(50.0 + i, 50), touch: false);
      }
      final hovered = ms();
      now = now.add(const Duration(seconds: 1));

      final clip =
          (await recorder.captureRecording('c', since: start, until: now))!;
      final pointer = [
        for (final e in clip.events)
          if (e['type'] == 3 && (e['data'] as Map)['source'] != 0)
            e.cast<String, Object?>(),
      ];
      Map<String, Object?> data(Map<String, Object?> e) =>
          (e['data'] as Map).cast<String, Object?>();
      List<Map> positions(Map<String, Object?> e) =>
          (data(e)['positions'] as List).cast<Map>();
      expect(pointer.map((e) => data(e)['source']).toList(), [2, 6, 6, 6, 2, 1]);
      expect(pointer.first['timestamp'], down);
      expect(pointer[4]['timestamp'], up);

      // Positions at most 500 ms apart share an event, stamped at the last.
      final drags = pointer.where((e) => data(e)['source'] == 6).toList();
      expect(drags.map((e) => positions(e).length).toList(), [9, 9, 2]);
      for (final e in drags) {
        final offsets = positions(e).map((p) => p['timeOffset'] as int).toList();
        expect(offsets.last, 0);
        expect(offsets.every((o) => o <= 0 && o >= -500), isTrue);
      }
      // The replayer moves the pointer at the event's time plus the offset:
      // when it moved.
      expect([
        for (final e in drags)
          for (final p in positions(e)) (e['timestamp'] as int) + (p['timeOffset'] as int),
      ], moved);
      expect(positions(drags.first).first, {
        'x': 11,
        'y': 10,
        'id': screenNodeId,
        'timeOffset': -480,
      });

      final hover = pointer.last;
      expect(hover['timestamp'], hovered);
      expect(positions(hover).map((p) => p['timeOffset']).toList(), [-60, 0]);

      final times = clip.events.map((e) => e['timestamp'] as int).toList();
      expect(times, orderedEquals([...times]..sort()));
      recorder.stop();
    });

    test('the move throttle forgets pointers that went up', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      final recorder =
          WireframeRecorder(rootKey: GlobalKey(), maxFrames: 2, now: () => now);
      for (var pointer = 1; pointer <= 20; pointer++) {
        now = now.add(const Duration(seconds: 1));
        recorder
          ..pointerDown(pointer, Offset.zero, touch: false)
          ..pointerMove(pointer, const Offset(5, 5), touch: false)
          ..pointerUp(pointer, const Offset(5, 5), touch: false, tap: false);
        // A mouse hovers on with the id of its last press.
        now = now.add(const Duration(milliseconds: 100));
        recorder.pointerMove(pointer, const Offset(9, 9), touch: false);
      }
      expect(recorder.trackedPointerCount, 1);
    });
  });

  group('settings and client', () {
    test('replay.maskAllInputs is a remote setting, on by default', () {
      expect(defaultSettings().replayMaskAllInputs, isTrue);
      final off = applyOverlay(defaultSettings(),
          parseSettingsDocument('{"replay": {"maskAllInputs": false}}'));
      expect(off.replayMaskAllInputs, isFalse);
      expect(off.copy().replayMaskAllInputs, isFalse);
    });

    test('replay.captureMode is a remote setting, unset by default', () {
      expect(defaultSettings().replayCaptureMode, isNull);
      Settings apply(String doc) =>
          applyOverlay(defaultSettings(), parseSettingsDocument(doc));
      expect(apply('{"replay": {"captureMode": "wireframe"}}').replayCaptureMode,
          'wireframe');
      expect(apply('{"replay": {"captureMode": "video"}}').copy().replayCaptureMode,
          'video');
      expect(apply('{"replay": {"captureMode": "pixels"}}').replayCaptureMode,
          isNull);
    });

    Future<TracewayClient> client(TracewayOptions options,
            {bool video = true, Directory? dir}) =>
        TracewayClient.initializeForTest(
          'token@https://traceway.test',
          options,
          overrides: TracewayTestOverrides(
            httpClient: MockClient((_) async => http.Response('{}', 200)),
            videoSupported: video,
            stateDirectory: dir,
          ),
        );
    const video = TracewayScreenCaptureMode.video;
    const wireframe = TracewayScreenCaptureMode.wireframe;
    const capture = TracewayOptions(remoteConfig: false, screenCapture: true);
    Map<String, Object?> asWireframe = {
      'replay': {'captureMode': 'wireframe'}
    };

    test('video falls back to a wireframe where it cannot be encoded',
        () async {
      final noEncoder = await client(capture, video: false);
      expect(noEncoder.recordsScreen, isTrue);
      expect(noEncoder.captureMode.value, wireframe);
      // Asking for video from the dashboard changes nothing there.
      noEncoder.control.applyRemote(
          parseSettingsDocument('{"replay": {"captureMode": "video"}}'));
      expect(noEncoder.captureMode.value, wireframe);
      await noEncoder.shutdown();

      final encoder = await client(capture);
      expect(encoder.captureMode.value, video);
      await encoder.shutdown();

      final off = await client(const TracewayOptions(remoteConfig: false));
      expect(off.recordsScreen, isFalse);
      expect(off.captureMode.value, isNull);
      await off.shutdown();
    });

    test('remote settings switch between video and wireframe', () async {
      final app = await client(capture);
      expect(app.captureMode.value, video);
      final seen = <TracewayScreenCaptureMode?>[];
      app.captureMode.addListener(() => seen.add(app.captureMode.value));
      app.control.applyRemote(asWireframe);
      expect(app.captureMode.value, wireframe);
      // Without the setting the app's own choice is back.
      app.control.applyRemote({});
      expect(app.captureMode.value, video);
      expect(seen, [wireframe, video]);
      await app.shutdown();

      final local = await client(const TracewayOptions(
        remoteConfig: false,
        screenCapture: true,
        collection: {
          'replay': {'captureMode': 'wireframe'}
        },
      ));
      expect(local.captureMode.value, wireframe);
      await local.shutdown();
    });

    test('a session that uploaded replay keeps its mode until the next one',
        () async {
      final dir = await Directory.systemTemp.createTemp('tw-capture-mode');
      addTearDown(() => dir.delete(recursive: true));
      final first = await client(capture, dir: dir);
      final session = first.currentSessionId!;
      expect(first.captureMode.value, video);
      first.replay.budget.admit(session, 4096);
      first.control.applyRemote(asWireframe);
      expect(first.captureMode.value, video);
      await first.shutdown();

      // The session goes on after a restart, and so does its video, though
      // the app now asks for a wireframe.
      const wants = TracewayOptions(
          remoteConfig: false, screenCapture: true, screenCaptureMode: wireframe);
      final second = await client(wants, dir: dir);
      expect(second.currentSessionId, session);
      expect(second.captureMode.value, video);
      await second.shutdown();

      // Once it has expired, the next session records a wireframe.
      final file = File('${dir.path}/state.json');
      final state = jsonDecode(file.readAsStringSync()) as Map;
      (state['session'] as Map)['lastActivityMs'] = 0;
      file.writeAsStringSync(jsonEncode(state));
      final third = await client(wants, dir: dir);
      expect(third.currentSessionId, isNot(session));
      expect(third.captureMode.value, wireframe);
      await third.shutdown();
    });

    test('a session that uploaded nothing switches at once', () async {
      final app = await client(capture);
      final other = '${app.currentSessionId}-other';
      // Replay of another session does not hold this one back.
      app.replay.budget.admit(other, 4096);
      app.control.applyRemote(asWireframe);
      expect(app.captureMode.value, wireframe);
      await app.shutdown();
    });

    testWidgets('the Traceway widget swaps its recorder with the mode',
        (tester) async {
      final app = (await tester.runAsync(() => client(capture)))!;
      await tester.pumpWidget(const Traceway(
          child: Directionality(
              textDirection: TextDirection.ltr, child: Text('screen'))));
      await tester.pump();
      expect(app.screenRecorder, isA<ScreenRecorder>());
      app.control.applyRemote(asWireframe);
      expect(app.screenRecorder, isA<WireframeRecorder>());
      expect(app.screenRecorder!.isRunning, isTrue);
      app.control.applyRemote({});
      expect(app.screenRecorder, isA<ScreenRecorder>());
      await tester.pumpWidget(const SizedBox());
      expect(app.screenRecorder, isNull);
      await tester.runAsync(app.shutdown);
    });
  });
}

class _FakePlatformView extends PlatformViewController {
  _FakePlatformView(this.viewId);


  @override
  final int viewId;

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> dispose() async {}
}

/// A platform view that is created at once, as the platform reports.
PlatformViewController _createFakePlatformView(
    PlatformViewCreationParams params) {
  scheduleMicrotask(() => params.onPlatformViewCreated(params.id));
  return _FakePlatformView(params.id);
}

class _Triangle extends CustomClipper<Path> {
  const _Triangle();

  @override
  Path getClip(Size size) => Path()
    ..moveTo(size.width / 2, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(_Triangle oldClipper) => false;
}

/// Throws when asked how it paints its child, as a widget the capture does
/// not expect might.
class _Throwing extends SingleChildRenderObjectWidget {
  const _Throwing({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderThrowing();
}

class _RenderThrowing extends RenderProxyBox {
  @override
  Size get size {
    if (StackTrace.current.toString().contains('WireframeCapture')) {
      throw StateError('not today');
    }
    return super.size;
  }
}
