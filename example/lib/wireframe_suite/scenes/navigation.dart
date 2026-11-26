// Tabs, pages, bottom navigation, a navigation rail and drawer, and the
// kinds of routes.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

final navigationScenarios = [
  Scenario(
    id: 'tabs',
    title: 'Tabs, pages & navigation',
    subtitle: 'TabBar, PageView, NavigationBar',
    icon: Icons.tab,
    page: () => const TabsPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('tabs', shows: ['Flights page 1', 'Flights', 'Trips']);
      await d.tap('Trips');
      await d.checkpoint('tabs-second', shows: ['Trips page 1'], hides: ['Flights page 1']);
      await d.fling(Offset(s.width * 0.8, s.height * 0.5), Offset(-s.width * 0.6, 0));
      await d.checkpoint('tabs-swiped', shows: ['Trips page 2']);
      await d.tap('Saved');
      await d.checkpoint('tabs-bottom-nav', shows: ['Saved items'], hides: ['Trips page 2']);
    },
  ),
  Scenario(
    id: 'navigation',
    title: 'Rail, drawer & routes',
    subtitle: 'NavigationRail, drawer, Cupertino and dialog routes',
    icon: Icons.alt_route,
    page: () => const NavigationPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('navigation', shows: ['Mail', 'Inbox zero']);
      await d.tapKey(NavigationPage.extendKey);
      await d.checkpoint('navigation-rail-extended', shows: ['Photos']);
      await d.tap('Photos');
      await d.checkpoint('navigation-photos', shows: ['12 photos']);
      await d.tapAt(const Offset(28, 28));
      await d.checkpoint('navigation-drawer', shows: ['Folders', 'Starred']);
      await d.tapAt(Offset(s.width - 20, s.height * 0.5));
      await d.settle();
      await d.tap('Open details');
      await d.checkpoint('navigation-cupertino-route', shows: ['Details']);
      await d.back();
      await d.tap('Compose');
      await d.checkpoint('navigation-fullscreen-dialog', shows: ['New message', 'Send']);
      await d.back();
    },
  ),
];

class TabsPage extends StatefulWidget {
  const TabsPage({super.key});

  @override
  State<TabsPage> createState() => _TabsPageState();
}

class _TabsPageState extends State<TabsPage> {
  int _destination = 0;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tabs, pages & navigation'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.flight), text: 'Flights'),
            Tab(icon: Icon(Icons.luggage), text: 'Trips'),
            Tab(icon: Icon(Icons.explore), text: 'Explore'),
          ]),
        ),
        body: IndexedStack(
          index: _destination,
          children: [
            TabBarView(children: [
              for (final name in ['Flights', 'Trips', 'Explore'])
                PageView(
                  children: [
                    for (var p = 1; p <= 3; p++)
                      Container(
                        margin: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.primaries[(name.length * p) % Colors.primaries.length]
                              .shade100,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        alignment: Alignment.center,
                        child: Text('$name page $p', style: const TextStyle(fontSize: 22)),
                      ),
                  ],
                ),
            ]),
            const Center(child: Text('Saved items', style: TextStyle(fontSize: 22))),
            const Center(child: Text('Profile')),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _destination,
          onDestinationSelected: (i) => setState(() => _destination = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.bookmark), label: 'Saved'),
            NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key});

  static final extendKey = GlobalKey();

  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  int _index = 0;
  bool _extended = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rail, drawer & routes')),
      drawer: NavigationDrawer(
        selectedIndex: 0,
        onDestinationSelected: (_) => Navigator.of(context).pop(),
        children: const [
          Padding(
            padding: EdgeInsets.fromLTRB(28, 16, 16, 10),
            child: Text('Folders', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          NavigationDrawerDestination(icon: Icon(Icons.inbox), label: Text('All mail')),
          NavigationDrawerDestination(icon: Icon(Icons.star), label: Text('Starred')),
          NavigationDrawerDestination(icon: Icon(Icons.send), label: Text('Sent')),
          Divider(indent: 28, endIndent: 28),
          NavigationDrawerDestination(icon: Icon(Icons.delete), label: Text('Trash')),
        ],
      ),
      drawerEdgeDragWidth: 40,
      body: Row(children: [
        NavigationRail(
          extended: _extended,
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          leading: IconButton(
            key: NavigationPage.extendKey,
            icon: Icon(_extended ? Icons.menu_open : Icons.menu),
            onPressed: () => setState(() => _extended = !_extended),
          ),
          destinations: const [
            NavigationRailDestination(icon: Icon(Icons.mail_outline), label: Text('Mail')),
            NavigationRailDestination(icon: Icon(Icons.photo_outlined), label: Text('Photos')),
            NavigationRailDestination(icon: Icon(Icons.settings_outlined), label: Text('Settings')),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(['Inbox zero', '12 photos', 'Settings'][_index],
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).push(CupertinoPageRoute<void>(
                  builder: (_) => const _Details(),
                )),
                child: const Text('Open details'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => const _Compose(),
                )),
                child: const Text('Compose'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details();

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Details')),
      child: SafeArea(
        child: CupertinoListSection.insetGrouped(children: const [
          CupertinoListTile(title: Text('Pushed with a CupertinoPageRoute')),
          CupertinoListTile(title: Text('Swipes in from the right')),
        ]),
      ),
    );
  }
}

class _Compose extends StatelessWidget {
  const _Compose();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New message'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Send')),
        ],
      ),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(children: [
          TextField(decoration: InputDecoration(labelText: 'To')),
          TextField(decoration: InputDecoration(labelText: 'Subject')),
          Expanded(
              child: TextField(
                  maxLines: null,
                  expands: true,
                  decoration: InputDecoration(hintText: 'Write something'))),
        ]),
      ),
    );
  }
}
