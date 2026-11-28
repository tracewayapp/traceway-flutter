import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'driver.dart';

/// One screen of the suite and the steps that take it through its states,
/// with a checkpoint at each.
class Scenario {
  const Scenario({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.page,
    required this.script,
    this.route,
  });

  /// Names the scenario's checkpoints and selects it in `E2E_ONLY`.
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() page;
  final Future<void> Function(Driver d) script;

  /// How the page is pushed; a [MaterialPageRoute] when null.
  final Route<void> Function(WidgetBuilder builder, RouteSettings settings)?
      route;
}

/// A picture the harness serves over HTTP, for network images.
final String? imageUrl = Platform.environment['E2E_IMAGE_URL'];

/// An address that answers 404, for an image that fails to load.
String? get brokenImageUrl => imageUrl?.replaceFirst('photo.png', 'missing.png');

Scaffold page(String title, Widget body,
        {List<Widget>? actions,
        Widget? floatingActionButton,
        PreferredSizeWidget? bottom}) =>
    Scaffold(
      appBar: AppBar(title: Text(title), actions: actions, bottom: bottom),
      body: body,
      floatingActionButton: floatingActionButton,
    );

/// A labeled colored box.
Widget box(Color color, String label,
        {double? width, double height = 48, Color text = Colors.white}) =>
    Container(
      width: width,
      height: height,
      color: color,
      alignment: Alignment.center,
      child: Text(label, style: TextStyle(color: text)),
    );
