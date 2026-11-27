import 'package:flutter/widgets.dart';

/// Finds what the wireframe recorder captures.
///
/// A Flutter app draws into one root: the `RepaintBoundary` the `Traceway`
/// widget puts around the app. Routes, dialogs, sheets, menus and overlay
/// entries are all inside it, in the `Navigator`'s overlay, so a single walk
/// from that root sees every window the app shows, in paint order. What the
/// platform draws outside Flutter (the keyboard, system dialogs) is not in
/// it.
class WireframeRoots {
  WireframeRoots(this.rootKey);

  /// The key of the widget whose subtree is recorded.
  final GlobalKey rootKey;

  /// The element the capture starts from, or null while the widget is not
  /// mounted (before the first frame, after the app was torn down).
  Element? get root {
    final context = rootKey.currentContext;
    if (context is! Element || !context.mounted) return null;
    return context;
  }
}
