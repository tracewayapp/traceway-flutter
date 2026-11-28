// ignore_for_file: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/interaction/tap_target.dart';
import 'package:traceway/src/interaction/widget_selector.dart';
import 'package:traceway/traceway.dart';

class CheckoutButton extends StatelessWidget {
  const CheckoutButton({super.key, required this.onPressed});
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) =>
      ElevatedButton(onPressed: onPressed, child: const Text('Pay now'));
}

class _PrivateCard extends StatelessWidget {
  const _PrivateCard();
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {},
        child: const SizedBox(width: 200, height: 40, child: Text('card')),
      );
}

Widget app(Widget body) => MaterialApp(
      home: Scaffold(
        body: Center(child: body),
      ),
    );

ElementPath pathAt(WidgetTester tester, Finder finder) =>
    elementPathAt(tester.getCenter(finder))!;

bool sel(String selector, ElementPath path) =>
    WidgetSelector.parse(selector)!.matches(path);

void main() {
  group('selector syntax', () {
    test('accepts what the dashboard accepts', () {
      for (final valid in [
        'ElevatedButton',
        '#checkout',
        '.button',
        '[key="42"]',
        "[text='Pay now']",
        '[label]',
        'ListTile[text^="Set"]',
        '#cart ElevatedButton',
        'Row > Text',
        'Text + Text',
        'Text ~ Text',
        '*[type="_PrivateCard"]',
        '[data-step="2"]',
        'a#b.c[d=e][f~="g"][h|="i"][j\$="k"][l*="m"]',
      ]) {
        expect(WidgetSelector.parse(valid), isNotNull, reason: valid);
      }
    });

    test('rejects pseudo-classes, lists, escapes and broken syntax', () {
      for (final invalid in [
        'Text:hover',
        'a, b',
        r'#a\:b',
        '[text="unterminated]',
        '[text=2]',
        '>',
        'a >',
        '',
        '   ',
        '#',
        'a"b',
        '[text="a\nb"]',
        'x' * 257,
      ]) {
        expect(WidgetSelector.parse(invalid), isNull, reason: invalid);
      }
    });
  });

  group('matching the widget under the pointer', () {
    testWidgets('a button matches by type, key, text, role and ancestor',
        (tester) async {
      await tester.pumpWidget(app(Column(
        key: const Key('cart'),
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton(
            key: const Key('pay'),
            onPressed: () {},
            child: const Text('Pay now'),
          ),
        ],
      )));
      final path = pathAt(tester, find.text('Pay now'));
      expect(sel('ElevatedButton', path), isTrue);
      expect(sel('elevatedbutton', path), isTrue);
      expect(sel('#pay', path), isTrue);
      expect(sel('ElevatedButton#pay', path), isTrue);
      expect(sel('ElevatedButton[text="Pay now"]', path), isTrue);
      expect(sel('[text^="Pay"]', path), isTrue);
      expect(sel('[text~="now"]', path), isTrue);
      expect(sel(r'[text$="now"]', path), isTrue);
      expect(sel('.button[text="Pay now"]', path), isTrue);
      expect(sel('#cart ElevatedButton', path), isTrue);
      expect(sel('#cart #pay', path), isTrue);
      expect(sel('Column ElevatedButton Text', path), isTrue);

      expect(sel('TextButton', path), isFalse);
      expect(sel('#other', path), isFalse);
      expect(sel('ElevatedButton[text="Pay"]', path), isFalse);
      expect(sel('ElevatedButton #cart', path), isFalse);
      expect(sel('ElevatedButton > Text', path), isFalse,
          reason: 'the Text is several elements below the button');
    });

    testWidgets('the space around a button is not the button', (tester) async {
      await tester.pumpWidget(app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton(onPressed: () {}, child: const Text('Pay')),
          const SizedBox(height: 100),
        ],
      )));
      final below = tester.getBottomLeft(find.byType(ElevatedButton)) +
          const Offset(10, 50);
      // Empty layout space is not hit: the pointer is on the Scaffold.
      final path = elementPathAt(below)!;
      expect(sel('ElevatedButton', path), isFalse);
      expect(sel('Scaffold', path), isTrue);
    });

    testWidgets('Semantics identifiers, labels and tooltips', (tester) async {
      await tester.pumpWidget(app(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            identifier: 'open-user',
            child: GestureDetector(
              onTap: () {},
              child: const SizedBox(width: 60, height: 60, child: Text('Ann')),
            ),
          ),
          IconButton(
            tooltip: 'Delete',
            onPressed: () {},
            icon: const Icon(Icons.delete),
          ),
          const Icon(Icons.star, semanticLabel: 'Favorite'),
        ],
      )));
      final user = pathAt(tester, find.text('Ann'));
      expect(sel('#open-user', user), isTrue);
      expect(sel('[identifier="open-user"]', user), isTrue);

      final delete = pathAt(tester, find.byIcon(Icons.delete));
      expect(sel('IconButton[label="Delete"]', delete), isTrue);
      expect(sel('[label="Delete"]', delete), isTrue);
      expect(sel('IconButton[label="Remove"]', delete), isFalse);

      final star = pathAt(tester, find.byIcon(Icons.star));
      expect(sel('Icon[label="Favorite"]', star), isTrue);
    });

    testWidgets('sibling combinators follow the order of children',
        (tester) async {
      await tester.pumpWidget(app(const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('first', key: Key('first')),
          Text('second', key: Key('second')),
          Text('third', key: Key('third')),
        ],
      )));
      final third = pathAt(tester, find.text('third'));
      expect(sel('#second + #third', third), isTrue);
      expect(sel('#first ~ #third', third), isTrue);
      expect(sel('#first + #third', third), isFalse);
      expect(sel('#third ~ #first', third), isFalse);
    });

    testWidgets('text inside inputs is never matched', (tester) async {
      final controller = TextEditingController(text: 'secret-password');
      await tester.pumpWidget(app(SizedBox(
        width: 300,
        child: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
      )));
      final path = pathAt(tester, find.byType(TextField));
      expect(sel('TextField[text*="secret"]', path), isFalse);
      expect(sel('TextField[text*="Password"]', path), isTrue);
    });
  });

  group('describing a tap', () {
    testWidgets('names the control, not the InkWell or Text inside it',
        (tester) async {
      await tester.pumpWidget(app(ElevatedButton(
        onPressed: () {},
        child: const Text('Pay now'),
      )));
      final target = describeTap(pathAt(tester, find.text('Pay now')))!;
      expect(target.tag, 'ElevatedButton');
      expect(target.selector, 'ElevatedButton[text="Pay now"]');
      expect(target.text, 'Pay now');
    });

    testWidgets('prefers an id on the app widget around the control',
        (tester) async {
      await tester.pumpWidget(
          app(CheckoutButton(key: const Key('checkout'), onPressed: () {})));
      final path = pathAt(tester, find.text('Pay now'));
      final target = describeTap(path)!;
      expect(target.selector, 'CheckoutButton#checkout');
      expect(target.id, 'checkout');
      expect(sel(target.selector, path), isTrue);
    });

    testWidgets('an icon button is named by its tooltip', (tester) async {
      await tester.pumpWidget(app(IconButton(
        tooltip: 'Delete',
        onPressed: () {},
        icon: const Icon(Icons.delete),
      )));
      final target = describeTap(pathAt(tester, find.byIcon(Icons.delete)))!;
      expect(target.selector, 'IconButton[label="Delete"]');
    });

    testWidgets('an icon button inside a list tile is the icon button',
        (tester) async {
      await tester.pumpWidget(app(SizedBox(
        width: 400,
        child: ListTile(
          title: const Text('Settings'),
          onTap: () {},
          trailing: IconButton(
            tooltip: 'More',
            onPressed: () {},
            icon: const Icon(Icons.more_vert),
          ),
        ),
      )));
      expect(describeTap(pathAt(tester, find.byIcon(Icons.more_vert)))!.tag,
          'IconButton');
      final tile = describeTap(pathAt(tester, find.text('Settings')))!;
      expect(tile.selector, 'ListTile[text="Settings"]');
    });

    testWidgets('a gesture detector inside a list tile is not the list tile',
        (tester) async {
      await tester.pumpWidget(app(SizedBox(
        width: 400,
        child: ListTile(
          onTap: () {},
          title: GestureDetector(
            onTap: () {},
            child: const Text('inner'),
          ),
        ),
      )));
      final target = describeTap(pathAt(tester, find.text('inner')))!;
      expect(target.tag, 'GestureDetector');
      expect(target.selector, 'GestureDetector[text="inner"]');
    });

    testWidgets('cupertino buttons and private widgets', (tester) async {
      await tester.pumpWidget(app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(onPressed: () {}, child: const Text('Done')),
          const _PrivateCard(),
        ],
      )));
      expect(describeTap(pathAt(tester, find.text('Done')))!.selector,
          'CupertinoButton[text="Done"]');
      final card = describeTap(pathAt(tester, find.text('card')))!;
      expect(card.tag, 'GestureDetector');
    });

    testWidgets('text unsafe for the dashboard becomes a prefix',
        (tester) async {
      await tester.pumpWidget(app(TextButton(
        onPressed: () {},
        child: const Text('Yes, continue'),
      )));
      final path = pathAt(tester, find.text('Yes, continue'));
      final target = describeTap(path)!;
      expect(target.selector, 'TextButton[text^="Yes"]');
      expect(sel(target.selector, path), isTrue);
    });

    testWidgets('masked text is not reported', (tester) async {
      await tester.pumpWidget(app(TracewayMask(
        child: ElevatedButton(
          onPressed: () {},
          child: const Text('4242 4242 4242 4242'),
        ),
      )));
      final target =
          describeTap(pathAt(tester, find.text('4242 4242 4242 4242')))!;
      expect(target.text, isNull);
      expect(target.selector, 'ElevatedButton');
    });

    testWidgets('a masked control keeps its label too', (tester) async {
      await tester.pumpWidget(app(TracewayMask(
        child: IconButton(
          tooltip: 'Call Ann Smith',
          onPressed: () {},
          icon: const Icon(Icons.call),
        ),
      )));
      final target = describeTap(pathAt(tester, find.byIcon(Icons.call)))!;
      expect(target.label, isNull);
      expect(target.selector, 'IconButton');
    });

    testWidgets('a key under a mask is not reported either', (tester) async {
      await tester.pumpWidget(app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TracewayMask(
            child: ListTile(
              key: const ValueKey('Ann Smith'),
              onTap: () {},
              title: const Text('Ann Smith'),
            ),
          ),
          Container(
            key: const Key('contacts'),
            child: TracewayMask(
              child: KeyedSubtree(
                key: const Key('AnnSmith'),
                child: GestureDetector(
                  onTap: () {},
                  child: const SizedBox(
                      width: 100, height: 40, child: Text('Mail')),
                ),
              ),
            ),
          ),
        ],
      )));
      final tile = describeTap(pathAt(tester, find.text('Ann Smith')))!;
      expect(tile.id, isNull);
      expect(tile.selector, isNot(contains('Ann')));
      final mail = describeTap(pathAt(tester, find.text('Mail')))!;
      expect(mail.selector, isNot(contains('Ann')));
      // An id above the mask is the app's own, not masked content.
      expect(mail.id, 'contacts');
    });

    testWidgets('a mask inside a control hides its label', (tester) async {
      await tester.pumpWidget(app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () {},
            icon: const TracewayMask(
              child: Icon(Icons.call, semanticLabel: 'Call Ann Smith'),
            ),
          ),
          GestureDetector(
            onTap: () {},
            child: const TracewayMask(
              child: Icon(Icons.mail, semanticLabel: 'Mail Ann Smith'),
            ),
          ),
        ],
      )));
      for (final icon in [Icons.call, Icons.mail]) {
        final target = describeTap(pathAt(tester, find.byIcon(icon)))!;
        expect(target.label, isNull, reason: '$icon');
        expect(target.selector, isNot(contains('Ann')), reason: '$icon');
      }
    });

    testWidgets('a marker key masks like TracewayMask and is not an id',
        (tester) async {
      await tester.pumpWidget(app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ElevatedButton(
            key: const ValueKey('traceway-mask'),
            onPressed: () {},
            child: const Text('4242 4242'),
          ),
          IconButton(
            key: const ValueKey('traceway-blank'),
            tooltip: 'Call Ann Smith',
            onPressed: () {},
            icon: const Icon(Icons.call),
          ),
          Container(
            key: const Key('contacts'),
            child: GestureDetector(
              onTap: () {},
              child: const SizedBox(
                width: 100,
                height: 40,
                child: Text('Ann Smith', key: ValueKey('traceway-mask')),
              ),
            ),
          ),
        ],
      )));
      final card = describeTap(pathAt(tester, find.text('4242 4242')))!;
      expect(card.text, isNull);
      expect(card.id, isNull);
      expect(card.selector, 'ElevatedButton');
      final call = describeTap(pathAt(tester, find.byIcon(Icons.call)))!;
      expect(call.label, isNull);
      expect(call.id, isNull);
      expect(call.selector, 'IconButton');
      final name = describeTap(pathAt(tester, find.text('Ann Smith')))!;
      expect(name.text, isNull);
      expect(name.id, 'contacts');
      expect(name.selector, isNot(contains('Ann')));
      expect(name.selector, isNot(contains('traceway')));
    });

    testWidgets('TracewayPrivacyMask still masks', (tester) async {
      // ignore: deprecated_member_use_from_same_package
      await tester.pumpWidget(app(TracewayPrivacyMask(
        child: ElevatedButton(
          onPressed: () {},
          child: const Text('4242 4242 4242 4242'),
        ),
      )));
      final target =
          describeTap(pathAt(tester, find.text('4242 4242 4242 4242')))!;
      expect(target.text, isNull);
      expect(target.selector, 'ElevatedButton');
    });

    testWidgets('a tap on plain text names the text', (tester) async {
      await tester.pumpWidget(app(const Text('Hello there')));
      final target = describeTap(pathAt(tester, find.text('Hello there')))!;
      expect(target.tag, 'Text');
      expect(target.selector, 'Text[text="Hello there"]');
    });

    testWidgets('a key that is not a name becomes a key attribute',
        (tester) async {
      await tester.pumpWidget(app(ElevatedButton(
        key: const ValueKey('order.42'),
        onPressed: () {},
        child: const Text('Open'),
      )));
      final path = pathAt(tester, find.text('Open'));
      final target = describeTap(path)!;
      expect(target.selector, 'ElevatedButton[key="order.42"]');
      expect(sel(target.selector, path), isTrue);
    });
  });
}
