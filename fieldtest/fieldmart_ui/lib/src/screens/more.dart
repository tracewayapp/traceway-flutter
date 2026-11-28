// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../labels.dart';
import '../scope.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = Fieldmart.of(context);
    return ListView(children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(L.moreTitle, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
      ),
      const ListTile(leading: Icon(Icons.person_outline), title: Text('Account')),
      const ListTile(leading: Icon(Icons.receipt_long_outlined), title: Text('Orders')),
      const ListTile(leading: Icon(Icons.favorite_border), title: Text('Saved items')),
      const ListTile(leading: Icon(Icons.help_outline), title: Text('Help')),
      const Divider(),
      ListTile(
        key: const ValueKey('fm-more-diag'),
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text(L.diagnostics),
        subtitle: Text('Run ${scope.settings.run}'),
        onTap: () => Navigator.of(context).pushNamed('/diag'),
      ),
    ]);
  }
}
