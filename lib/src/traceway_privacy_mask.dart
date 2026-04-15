import 'package:flutter/widgets.dart';

import 'screen_recorder.dart';
import 'traceway_client.dart';
import 'traceway_mask_mode.dart';

class TracewayPrivacyMask extends StatefulWidget {
  final Widget child;
  final TracewayMaskMode mode;

  const TracewayPrivacyMask({
    super.key,
    required this.child,
    this.mode = const TracewayMaskBlur(),
  });

  @override
  State<TracewayPrivacyMask> createState() => _TracewayPrivacyMaskState();
}

class _TracewayPrivacyMaskState extends State<TracewayPrivacyMask>
    with WidgetsBindingObserver {
  final Key _maskKey = UniqueKey();
  Rect? _lastRect;

  ScreenRecorder? get _screenRecorder =>
      TracewayClient.instance?.screenRecorder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenRecorder?.removeMaskRegion(_maskKey);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scheduleUpdate();
  }

  void _scheduleUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateRect();
    });
  }

  void _updateRect() {
    final recorder = _screenRecorder;
    if (recorder == null) return;

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;

    final boundaryContext = recorder.repaintBoundaryKey.currentContext;
    if (boundaryContext == null) return;
    final boundaryBox = boundaryContext.findRenderObject();
    if (boundaryBox is! RenderBox) return;

    final topLeft = boundaryBox.globalToLocal(
      renderObject.localToGlobal(Offset.zero),
    );
    final rect = topLeft & renderObject.size;

    if (rect != _lastRect) {
      _lastRect = rect;
      recorder.addMaskRegion(_maskKey, rect, widget.mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleUpdate();
    return widget.child;
  }
}
