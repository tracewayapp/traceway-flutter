// The soft keyboard: a focused field with the keyboard up, then typing,
// then the keyboard down. The keyboard is the platform's: the replay draws
// a neutral box where it is, which the app's own picture does not have.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

const _keyboardHeight = 300.0;

final keyboardScenarios = [
  Scenario(
    id: 'keyboard',
    title: 'Soft keyboard',
    subtitle: 'A focused field with the keyboard up',
    icon: Icons.keyboard,
    page: () => const KeyboardPage(),
    script: (d) async {
      d.secret('See you at noon');
      await d.tapKey(KeyboardPage.fieldKey);
      await d.keyboard(_keyboardHeight);
      // The app's picture has no keyboard: left out of that comparison.
      Rect keys() => Rect.fromLTWH(0, d.screen.height - _keyboardHeight,
          d.screen.width, _keyboardHeight);
      await d.checkpoint('keyboard',
          shows: ['Keyboard', 'Message', 'Write a message to the team', 'Messages'],
          appIgnore: [keys()]);
      await d.type(KeyboardPage.message, 'See you at noon');
      await d.checkpoint('keyboard-typed',
          shows: ['Keyboard', '*** *** ** ****', 'Send message'],
          hides: ['See you at noon'],
          appIgnore: [keys()]);
      await d.keyboard(0);
      await d.checkpoint('keyboard-hidden',
          shows: ['Send message', '*** *** ** ****'], hides: ['Keyboard']);
    },
  ),
];

class KeyboardPage extends StatelessWidget {
  const KeyboardPage({super.key});

  static final fieldKey = GlobalKey();
  static final message = TextEditingController();

  @override
  Widget build(BuildContext context) {
    message.clear();
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Write a message to the team', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            TextField(
              key: fieldKey,
              controller: message,
              decoration: const InputDecoration(
                  hintText: 'Message', border: OutlineInputBorder()),
            ),
            const Spacer(),
            // Above the keyboard while it is up, as the body shrinks.
            FilledButton(onPressed: () {}, child: const Text('Send message')),
          ],
        ),
      ),
    );
  }
}
