import 'package:flutter/widgets.dart';

import 'data/api.dart';
import 'settings.dart';
import 'telemetry.dart';

/// What every screen needs: the data API, the telemetry seam, the launch
/// settings and the little state the screens share.
class Fieldmart extends InheritedWidget {
  const Fieldmart({
    super.key,
    required this.api,
    required this.telemetry,
    required this.settings,
    required this.cart,
    required this.screens,
    required this.tabs,
    required super.child,
  });

  final FieldmartApi api;
  final Telemetry telemetry;
  final LaunchSettings settings;
  final CartState cart;
  final ScreenTracker screens;
  final TabController2 tabs;

  static Fieldmart of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<Fieldmart>()!;

  @override
  bool updateShouldNotify(Fieldmart oldWidget) => false;
}

/// The bottom-navigation tabs, in order.
const List<String> tabNames = ['home', 'markets', 'feed', 'checkout', 'more'];

/// Which tab is selected; screens switch tabs through it.
class TabController2 extends ValueNotifier<int> {
  TabController2() : super(0);

  void select(String name) {
    final i = tabNames.indexOf(name);
    if (i >= 0) value = i;
  }
}

class CartLine {
  CartLine(this.productId, this.title, this.priceCents, this.quantity);
  final int productId;
  final String title;
  final int priceCents;
  int quantity;
}

class CartState extends ChangeNotifier {
  final List<CartLine> lines = [
    // Checkout always has three lines to edit, whatever the journey added.
    CartLine(3, 'Trail bottle 750 ml', 1899, 1),
    CartLine(8, 'Field socks, 3 pairs', 1450, 2),
    CartLine(12, 'Pocket lamp', 2999, 1),
  ];

  int get count => lines.fold(0, (n, l) => n + l.quantity);

  int get totalCents => lines.fold(0, (n, l) => n + l.priceCents * l.quantity);

  void add(int productId, String title, int priceCents, int quantity) {
    final existing = lines.where((l) => l.productId == productId).firstOrNull;
    if (existing != null) {
      existing.quantity += quantity;
    } else {
      lines.add(CartLine(productId, title, priceCents, quantity));
    }
    notifyListeners();
  }

  void changed() => notifyListeners();
}

/// Names the screen on top: `FM_SCREEN` markers, the `FM log <n>` line the
/// app prints on each screen change (check E-12), and the telemetry screen
/// call for tabs, which are not routes.
class ScreenTracker {
  ScreenTracker(this._onScreen);

  final void Function(String name) _onScreen;
  String? current;

  void show(String name) {
    if (name == current) return;
    current = name;
    _onScreen(name);
  }
}
