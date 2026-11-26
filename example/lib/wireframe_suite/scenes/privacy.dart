// What must never be recorded: masked widgets, typed and obscured text.
// Every secret here is printed for the harness, which fails if any of them
// appears anywhere in the recording.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:traceway/traceway.dart';

import '../scenario.dart';

/// Text the recording must never contain, wherever it is shown.
const secrets = [
  '4242 4242',
  'Expires 12/29',
  'Grace Hopper',
  'grace@example.com',
  'typed but masked',
  'correct horse',
  'hunter2',
  'Charles Babbage',
  'Account 9001',
];

final privacyScenarios = [
  Scenario(
    id: 'privacy',
    title: 'Privacy masks',
    subtitle: 'TracewayPrivacyMask, inputs and passwords',
    icon: Icons.lock,
    page: () => const PrivacyPage(),
    script: (d) async {
      await d.checkpoint('privacy',
          shows: ['Visible: order total 19.25'],
          hides: ['4242', 'Grace Hopper', 'grace@example.com', 'typed but masked']);
      await d.tapKey(PrivacyPage.passwordKey);
      await d.type(PrivacyPage.password, 'correct horse');
      final list = d.keyRect(PrivacyPage.listKey);
      await d.drag(list.center + const Offset(0, 40), const Offset(0, -120));
      await d.checkpoint('privacy-scrolled',
          shows: ['Visible row 4'], hides: ['correct horse', 'Account 9001']);
    },
  ),
];

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  static final passwordKey = GlobalKey();
  static final listKey = GlobalKey();
  static final password = TextEditingController();

  @override
  Widget build(BuildContext context) {
    password.clear();
    final url = imageUrl;
    return page(
      'Privacy masks',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Visible: order total 19.25'),
          const SizedBox(height: 12),
          const TracewayPrivacyMask(
            mode: TracewayMaskMode.blank(color: Color(0xFF263238)),
            child: ListTile(
                title: Text('Card 4242 4242 4242 4242'), subtitle: Text('Expires 12/29')),
          ),
          const SizedBox(height: 12),
          const TracewayPrivacyMask(
            child: Card(
                child: ListTile(
                    leading: Icon(Icons.person),
                    title: Text('Grace Hopper'),
                    subtitle: Text('grace@example.com'))),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: TextEditingController(text: 'typed but masked'),
            decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            key: passwordKey,
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          if (url != null)
            TracewayPrivacyMask(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(url, height: 90, width: double.infinity, fit: BoxFit.cover),
              ),
            ),
          const SizedBox(height: 12),
          Container(
            key: listKey,
            height: 180,
            decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
            child: ListView.builder(
              itemCount: 12,
              itemBuilder: (_, i) => i.isOdd
                  ? TracewayPrivacyMask(
                      mode: const TracewayMaskMode.blank(color: Color(0xFF455A64)),
                      child: ListTile(title: Text('Account 9001-$i')),
                    )
                  : ListTile(title: Text('Visible row $i')),
            ),
          ),
          const SizedBox(height: 200),
        ],
      ),
    );
  }
}
