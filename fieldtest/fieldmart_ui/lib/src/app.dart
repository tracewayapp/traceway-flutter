import 'dart:async';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'autopilot/autopilot.dart';
import 'data/api.dart';
import 'markers.dart';
import 'probe.dart';
import 'scope.dart';
import 'screens/checkout.dart';
import 'screens/diag.dart';
import 'screens/feed.dart';
import 'screens/home.dart';
import 'screens/markets.dart';
import 'screens/more.dart';
import 'screens/product.dart';
import 'screens/search.dart';
import 'settings.dart';
import 'telemetry.dart';

/// The whole app. `app_off` and `app_sdk` differ only in [telemetry] and in
/// how they start it.
class FieldmartApp extends StatefulWidget {
  const FieldmartApp({super.key, required this.settings, required this.telemetry});

  final LaunchSettings settings;
  final Telemetry telemetry;

  @override
  State<FieldmartApp> createState() => _FieldmartAppState();
}

class _FieldmartAppState extends State<FieldmartApp> {
  late final FieldmartApi _api =
      FieldmartApi(fixtures: widget.settings.fixtures, client: widget.telemetry.httpClient());
  late final Probe _probe = Probe(widget.settings);
  final _navigator = GlobalKey<NavigatorState>();
  final _cart = CartState();
  final _tabs = TabController2();
  late final ScreenTracker _screens = ScreenTracker(_onScreen);
  late final ScreenObserver _observer = ScreenObserver(_screens, _tabs);
  int _screenChanges = 0;
  Autopilot? _autopilot;

  @override
  void initState() {
    super.initState();
    _probe.start();
    if (Platform.isLinux) {
      // The harness's standard ending: Home, as the engine would report it.
      ProcessSignal.sigusr1.watch().listen((_) => Autopilot.simulatedHome(_probe));
    }
    Markers.emit('FM_START ${widget.telemetry.name} ${widget.settings} '
        'pid=$pid ${DateTime.now().millisecondsSinceEpoch}');
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) => _ready());
  }

  void _ready() {
    final t0 = Markers.mark('FM_READY');
    final binding = WidgetsBinding.instance;
    final view = binding.platformDispatcher.implicitView;
    Markers.emit('FM_INFO lifecycle=${binding.lifecycleState?.name} '
        'size=${view == null ? '?' : '${view.physicalSize.width}x${view.physicalSize.height}'} '
        'dpr=${view?.devicePixelRatio} '
        // System bars the window lies under (physical px): which side of the
        // screen the window starts on, for cropping screenshots to it.
        'padTop=${view?.viewPadding.top} padBottom=${view?.viewPadding.bottom}');
    unawaited(_reportSession());
    if (widget.settings.autopilot) {
      _autopilot = Autopilot(
        settings: widget.settings,
        probe: _probe,
        navigator: _navigator,
        t0EpochMs: t0,
      );
      unawaited(_autopilot!.run());
    }
  }

  Future<void> _reportSession() async {
    for (var i = 0; i < 40; i++) {
      final id = widget.telemetry.sessionId;
      if (id != null) {
        Markers.emit('FM_SESSION $id');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _onScreen(String name) {
    Markers.mark('FM_SCREEN', extra: name);
    _screenChanges++;
    // Through the platform's normal logger: the SDK records printed lines.
    print('FM log $_screenChanges');
  }

  @override
  Widget build(BuildContext context) {
    return Fieldmart(
      api: _api,
      telemetry: widget.telemetry,
      settings: widget.settings,
      cart: _cart,
      screens: _screens,
      tabs: _tabs,
      child: MaterialApp(
        title: 'Fieldmart',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigator,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E4F)),
          visualDensity: VisualDensity.standard,
        ),
        navigatorObservers: [...widget.telemetry.navigatorObservers, _observer],
        onGenerateRoute: _route,
        initialRoute: '/',
      ),
    );
  }

  Route<void>? _route(RouteSettings settings) {
    final name = settings.name ?? '/';
    final product = RegExp(r'^/product/(\d+)$').firstMatch(name);
    final Widget page;
    if (name == '/') {
      page = const Shell();
    } else if (product != null) {
      page = ProductScreen(productId: int.parse(product.group(1)!));
    } else if (name == '/search') {
      page = const SearchScreen();
    } else {
      return null;
    }
    return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
  }
}

/// The screen name of a route: `/product/17` is `product`, `/` the tab.
String? screenOfRoute(Route<dynamic>? route) {
  final name = route?.settings.name;
  if (name == null) return null;
  if (name == '/') return '';
  if (name.startsWith('/product/')) return 'product';
  return name.substring(1);
}

class ScreenObserver extends NavigatorObserver {
  ScreenObserver(this.screens, this.tabs);

  final ScreenTracker screens;
  final TabController2 tabs;

  void _show(Route<dynamic>? route) {
    if (route is! PageRoute) return;
    final screen = screenOfRoute(route);
    if (screen == null) return;
    screens.show(screen.isEmpty ? tabNames[tabs.value] : screen);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _show(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _show(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _show(newRoute);
}

/// The bottom navigation: Home, Markets, Feed, Checkout, More. Each tab is
/// built the first time it is opened and kept afterwards, so a form keeps
/// what was typed while the user is away; a tab that is not selected has
/// its tickers off. The More tab has its own navigator, so Diagnostics
/// opens inside the tab with the bottom bar still there.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final Set<int> _built = {0};
  late TabController2 _tabs;
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listening) {
      final scope = Fieldmart.of(context);
      _tabs = scope.tabs..addListener(_onTab);
      _listening = true;
      scope.screens.show(tabNames[_tabs.value]);
      scope.telemetry.screen('/${tabNames[_tabs.value]}');
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    final scope = Fieldmart.of(context);
    setState(() => _built.add(_tabs.value));
    final name = tabNames[_tabs.value];
    // A tab is visible only when no page route covers the shell.
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      scope.screens.show(name);
      scope.telemetry.screen('/$name');
    }
  }

  static const _icons = [
    Icons.storefront_outlined,
    Icons.candlestick_chart_outlined,
    Icons.dynamic_feed_outlined,
    Icons.shopping_cart_checkout,
    Icons.more_horiz,
  ];
  static const _labels = ['Home', 'Markets', 'Feed', 'Checkout', 'More'];

  final _moreNavigator = GlobalKey<NavigatorState>();

  Widget _tab(int i) => switch (i) {
        0 => const HomeScreen(),
        1 => const MarketsScreen(),
        2 => const FeedScreen(),
        3 => const CheckoutScreen(),
        _ => _moreTab(),
      };

  /// Made once: a navigator's observers must stay the same objects.
  late final List<NavigatorObserver> _moreObservers = [
    ...Fieldmart.of(context).telemetry.nestedNavigatorObservers(),
    ScreenObserver(Fieldmart.of(context).screens, Fieldmart.of(context).tabs),
  ];

  Widget _moreTab() {
    return NavigatorPopHandler<Object?>(
      onPopWithResult: (_) => _moreNavigator.currentState?.maybePop(),
      child: Navigator(
        key: _moreNavigator,
        observers: _moreObservers,
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => settings.name == '/diag' ? const DiagnosticsScreen() : const MoreScreen(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = _tabs.value;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: index,
          children: [
            for (var i = 0; i < tabNames.length; i++)
              _built.contains(i)
                  ? TickerMode(enabled: i == index, child: _tab(i))
                  : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => _tabs.value = i,
        destinations: [
          for (var i = 0; i < tabNames.length; i++)
            NavigationDestination(
              key: ValueKey('fm-nav-${tabNames[i]}'),
              icon: Icon(_icons[i]),
              label: _labels[i],
            ),
        ],
      ),
    );
  }
}

/// The app bar of a pushed page, with the journey's back button.
PreferredSizeWidget pageBar(BuildContext context, String title, {List<Widget>? actions}) =>
    AppBar(
      leading: BackButton(key: const ValueKey('fm-nav-back'), onPressed: () => Navigator.maybePop(context)),
      title: Text(title),
      actions: actions,
    );

/// Exits the process the way an app that dies does, for the crash test.
Never crashExit() => exit(1);
