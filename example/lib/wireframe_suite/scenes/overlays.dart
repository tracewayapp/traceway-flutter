// Things that show above the page: dialogs, sheets, snackbars, menus,
// drawers, tooltips, banners, blurs and overlay entries; and their
// Cupertino counterparts.
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../scenario.dart';

final overlayScenarios = [
  Scenario(
    id: 'overlays',
    title: 'Overlays',
    subtitle: 'Dialogs, sheets, menus, drawer, tooltip',
    icon: Icons.open_in_new,
    page: () => const OverlaysPage(),
    script: (d) async {
      final s = d.screen;
      await d.checkpoint('overlays', shows: ['Open dialog', 'Open menu'], hides: ['Delete everything?']);
      await d.tap('Open dialog');
      await d.checkpoint('overlays-dialog', shows: ['Delete everything?', 'Open dialog']);
      await d.tap('Cancel');
      await d.settle();
      await d.tap('Open bottom sheet');
      await d.checkpoint('overlays-sheet', shows: ['Copy link']);
      await d.tapAt(Offset(s.width / 2, 40));
      await d.settle();
      await d.tap('Show snackbar');
      await d.checkpoint('overlays-snackbar', shows: ['Saved to your library']);
      // A snackbar with an action stays until it is used.
      await d.tap('Undo');
      await d.settle();
      await d.tap('Open menu');
      await d.checkpoint('overlays-menu', shows: ['Duplicate', 'Archive']);
      await d.tap('Duplicate');
      await d.settle();
      await d.tapKey(OverlaysPage.popupKey);
      await d.checkpoint('overlays-popup', shows: ['Rename', 'Move to']);
      await d.tap('Rename');
      await d.settle();
      await d.longPressAt(d.keyCenter(OverlaysPage.tooltipKey));
      await d.checkpoint('overlays-tooltip', shows: ['More about this page']);
      await d.pause(1800);
      await d.settle();
      await d.tap('Show banner');
      await d.checkpoint('overlays-banner', shows: ['You are offline']);
      await d.tap('Dismiss');
      await d.settle();
      await d.tap('Blurred dialog');
      await d.checkpoint('overlays-blur', shows: ['Behind frosted glass']);
      await d.tap('Close');
      await d.settle();
      await d.tap('Show toast');
      await d.checkpoint('overlays-toast', shows: ['Copied to the clipboard']);
      await d.pause(1500);
      await d.tapKey(OverlaysPage.drawerButtonKey);
      await d.checkpoint('overlays-drawer', shows: ['Drawer header', 'Inbox']);
      // The scrim left of the end drawer closes it.
      await d.tapAt(Offset(20, s.height / 2));
      await d.settle();
    },
  ),
  Scenario(
    id: 'cupertino',
    title: 'Cupertino',
    subtitle: 'iOS-style widgets, sheets and alerts',
    icon: Icons.phone_iphone,
    page: () => const CupertinoGalleryPage(),
    script: (d) async {
      await d.checkpoint('cupertino', shows: ['Airplane mode', 'Continue']);
      await d.tap('Two');
      await d.tapKey(CupertinoGalleryPage.switchKey);
      await d.checkpoint('cupertino-toggled', shows: ['Airplane mode']);
      await d.tap('Share…');
      await d.checkpoint('cupertino-action-sheet', shows: ['Copy', 'Cancel']);
      await d.tap('Cancel');
      await d.settle();
      await d.tap('Sign out…');
      await d.checkpoint('cupertino-alert', shows: ['Sign out?', 'Stay']);
      await d.tap('Stay');
      await d.settle();
    },
    route: (builder, settings) => CupertinoPageRoute<void>(builder: builder, settings: settings),
  ),
];

class OverlaysPage extends StatelessWidget {
  const OverlaysPage({super.key});

  static final drawerButtonKey = GlobalKey();
  static final popupKey = GlobalKey();
  static final tooltipKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Overlays'),
        actions: [
          PopupMenuButton<String>(
            key: popupKey,
            onSelected: (_) {},
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'move', child: Text('Move to')),
              PopupMenuDivider(),
              CheckedPopupMenuItem(value: 'pin', checked: true, child: Text('Pinned')),
            ],
          ),
          Builder(
            builder: (context) => IconButton(
              key: drawerButtonKey,
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: Drawer(
        child: ListView(children: const [
          DrawerHeader(
              decoration: BoxDecoration(color: Colors.indigo),
              child: Text('Drawer header', style: TextStyle(color: Colors.white, fontSize: 20))),
          ListTile(leading: Icon(Icons.inbox), title: Text('Inbox')),
          ListTile(leading: Icon(Icons.send), title: Text('Sent')),
          ListTile(leading: Icon(Icons.delete), title: Text('Trash')),
        ]),
      ),
      body: Builder(
        builder: (context) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  icon: const Icon(Icons.warning_amber),
                  title: const Text('Delete everything?'),
                  content: const Text('This dialog sits on a scrim above the page.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Delete')),
                  ],
                ),
              ),
              child: const Text('Open dialog'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => const SizedBox(
                  height: 220,
                  child: Column(children: [
                    ListTile(leading: Icon(Icons.share), title: Text('Share')),
                    ListTile(leading: Icon(Icons.link), title: Text('Copy link')),
                    ListTile(leading: Icon(Icons.edit), title: Text('Edit')),
                  ]),
                ),
              ),
              child: const Text('Open bottom sheet'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: const Text('Saved to your library'),
                    duration: const Duration(seconds: 2),
                    action: SnackBarAction(label: 'Undo', onPressed: () {})),
              ),
              child: const Text('Show snackbar'),
            ),
            const SizedBox(height: 8),
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                    leadingIcon: const Icon(Icons.copy), onPressed: () {}, child: const Text('Duplicate')),
                MenuItemButton(
                    leadingIcon: const Icon(Icons.archive), onPressed: () {}, child: const Text('Archive')),
              ],
              builder: (context, controller, _) => OutlinedButton(
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                child: const Text('Open menu'),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => ScaffoldMessenger.of(context).showMaterialBanner(MaterialBanner(
                leading: const Icon(Icons.wifi_off),
                content: const Text('You are offline'),
                actions: [
                  TextButton(
                    onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
                    child: const Text('Dismiss'),
                  ),
                ],
              )),
              child: const Text('Show banner'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => showGeneralDialog<void>(
                context: context,
                barrierDismissible: false,
                barrierColor: Colors.transparent,
                pageBuilder: (context, _, _) => BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('Behind frosted glass'),
                          const SizedBox(height: 12),
                          TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Close')),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('Blurred dialog'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _toast(context),
              child: const Text('Show toast'),
            ),
            const SizedBox(height: 24),
            Tooltip(
              key: tooltipKey,
              message: 'More about this page',
              child: const Icon(Icons.info_outline, size: 32),
            ),
          ],
        ),
      ),
    );
  }

  static void _toast(BuildContext context) {
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 40,
        right: 40,
        bottom: 80,
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(24),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('Copied to the clipboard',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    Future<void>.delayed(const Duration(milliseconds: 1500), entry.remove);
  }
}

class CupertinoGalleryPage extends StatefulWidget {
  const CupertinoGalleryPage({super.key});

  static final switchKey = GlobalKey();

  @override
  State<CupertinoGalleryPage> createState() => _CupertinoGalleryPageState();
}

class _CupertinoGalleryPageState extends State<CupertinoGalleryPage> {
  bool _on = true;
  double _value = 0.6;
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Cupertino'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Icon(CupertinoIcons.back),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CupertinoSlidingSegmentedControl<int>(
              groupValue: _segment,
              onValueChanged: (v) => setState(() => _segment = v ?? 0),
              children: const {0: Text('One'), 1: Text('Two'), 2: Text('Three')},
            ),
            const SizedBox(height: 16),
            CupertinoListSection.insetGrouped(
              header: const Text('SETTINGS'),
              children: [
                CupertinoListTile(
                  title: const Text('Airplane mode'),
                  trailing: CupertinoSwitch(
                      key: CupertinoGalleryPage.switchKey,
                      value: _on,
                      onChanged: (v) => setState(() => _on = v)),
                ),
                const CupertinoListTile(
                    title: Text('Wi-Fi'),
                    additionalInfo: Text('Home'),
                    trailing: CupertinoListTileChevron()),
              ],
            ),
            CupertinoSlider(value: _value, onChanged: (v) => setState(() => _value = v)),
            const SizedBox(height: 12),
            const CupertinoTextField(placeholder: 'Search'),
            const SizedBox(height: 12),
            const CupertinoSearchTextField(),
            const SizedBox(height: 12),
            CupertinoButton.filled(onPressed: () {}, child: const Text('Continue')),
            const SizedBox(height: 8),
            CupertinoButton(
              onPressed: () => showCupertinoModalPopup<void>(
                context: context,
                builder: (context) => CupertinoActionSheet(
                  title: const Text('Share the page'),
                  actions: [
                    CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(context), child: const Text('Copy')),
                    CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(context), child: const Text('Mail')),
                  ],
                  cancelButton: CupertinoActionSheetAction(
                      onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                ),
              ),
              child: const Text('Share…'),
            ),
            CupertinoButton(
              onPressed: () => showCupertinoDialog<void>(
                context: context,
                builder: (context) => CupertinoAlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text('You can sign in again at any time.'),
                  actions: [
                    CupertinoDialogAction(
                        onPressed: () => Navigator.pop(context), child: const Text('Stay')),
                    CupertinoDialogAction(
                        isDestructiveAction: true,
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Sign out')),
                  ],
                ),
              ),
              child: const Text('Sign out…'),
            ),
            const SizedBox(height: 12),
            const CupertinoActivityIndicator(radius: 14, animating: false),
          ],
        ),
      ),
    );
  }
}
