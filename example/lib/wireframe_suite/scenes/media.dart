// Images of every source and fit, spinners and progress, painting and
// shapes, and views the platform draws.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../scenario.dart';

/// Platform views exist in the engines of Android, iOS and macOS; on Linux
/// and Windows a stand-in controller paints nothing where the view would
/// be, which is all the wireframe needs to place its placeholder.
bool get fakePlatformViews => Platform.isLinux || Platform.isWindows;

final mediaScenarios = [
  Scenario(
    id: 'images',
    title: 'Images',
    subtitle: 'Network, memory, file, fits, filters, errors',
    icon: Icons.image,
    page: () => const ImagesPage(),
    script: (d) async {
      await d.pause(800);
      await d.checkpoint('images', shows: ['cover', 'contain', 'fill']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.5));
      await d.checkpoint('images-middle', shows: ['Memory', 'File']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.6));
      await d.checkpoint('images-bottom', shows: ['Failed to load', 'Ink.image']);
    },
  ),
  Scenario(
    id: 'spinners',
    title: 'Spinners & progress',
    subtitle: 'Indeterminate, determinate, Cupertino, custom',
    icon: Icons.hourglass_top,
    page: () => const SpinnersPage(),
    script: (d) async {
      final spinning = SpinnersPage.indeterminate;
      await d.pause(600);
      await d.checkpoint('spinners',
          settle: false, ignore: spinning, minMutations: 4, shows: ['Saving…']);
      await d.tap('Advance');
      await d.checkpoint('spinners-advanced', settle: false, ignore: spinning);
      await d.tap('Stop');
      await d.checkpoint('spinners-stopped', shows: ['Saved']);
    },
  ),
  Scenario(
    id: 'painting',
    title: 'Painting & shapes',
    subtitle: 'CustomPaint, clips, gradients, shapes, icons',
    icon: Icons.brush,
    page: () => const PaintingPage(),
    script: (d) async {
      await d.checkpoint('painting', shows: ['Stadium', 'Beveled']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.55));
      await d.checkpoint('painting-scrolled', shows: ['Elevation 8']);
      await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
          Offset(0, -d.screen.height * 0.6));
      await d.checkpoint('painting-bottom', shows: ['Frosted']);
    },
  ),
  if (fakePlatformViews)
    Scenario(
      id: 'native',
      title: 'Native views',
      subtitle: 'Web view, map, native control, video texture',
      icon: Icons.web,
      page: () => const NativePage(),
      script: (d) async {
        final native = NativePage.views;
        await d.checkpoint('native',
            shows: ['Web view', 'Map', 'Native view'], appIgnore: native);
        await d.drag(Offset(d.screen.width / 2, d.screen.height * 0.85),
            Offset(0, -d.screen.height * 0.4));
        await d.checkpoint('native-scrolled', shows: ['Video'], appIgnore: native);
      },
    ),
];

// ---- images ------------------------------------------------------------------

class ImagesPage extends StatefulWidget {
  const ImagesPage({super.key});

  @override
  State<ImagesPage> createState() => _ImagesPageState();
}

class _ImagesPageState extends State<ImagesPage> {
  Uint8List? _png;
  File? _file;

  @override
  void initState() {
    super.initState();
    unawaited(_draw());
  }

  /// A picture made on the device: a memory image and, saved, a file one.
  Future<void> _draw() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(160, 100);
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.linear(
              Offset.zero, const Offset(160, 100), [Colors.teal, Colors.amber]));
    canvas.drawCircle(const Offset(120, 30), 18, Paint()..color = Colors.white);
    final image = await recorder.endRecording().toImage(160, 100);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final png = data!.buffer.asUint8List();
    final file = File('${Directory.systemTemp.path}/wireframe-suite-$pid.png');
    await file.writeAsBytes(png);
    if (!mounted) return;
    setState(() {
      _png = png;
      _file = file;
    });
  }

  Widget _framed(String label, Widget child, {double width = 110, double height = 80}) =>
      Column(children: [
        Container(width: width, height: height, color: Colors.grey.shade300, child: child),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final png = _png;
    final file = _file;
    Widget network({BoxFit? fit, Alignment alignment = Alignment.center, ImageRepeat repeat = ImageRepeat.noRepeat, double? width}) =>
        url == null
            ? const SizedBox()
            : Image.network(url, fit: fit, alignment: alignment, repeat: repeat, width: width);
    const gap = SizedBox(height: 16);
    return page(
      'Images',
      ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            for (final fit in [BoxFit.cover, BoxFit.contain, BoxFit.fill])
              _framed(fit.name, network(fit: fit)),
          ]),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _framed('none', network(fit: BoxFit.none)),
            _framed('scaleDown', network(fit: BoxFit.scaleDown)),
            _framed('fitWidth, top', network(fit: BoxFit.fitWidth, alignment: Alignment.topCenter)),
          ]),
          gap,
          _framed('repeat', network(repeat: ImageRepeat.repeatX, width: 60, fit: BoxFit.contain),
              width: 360, height: 50),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _framed('Memory', png == null ? const SizedBox() : Image.memory(png, fit: BoxFit.cover)),
            _framed('File', file == null ? const SizedBox() : Image.file(file, fit: BoxFit.cover)),
            _framed(
                'FadeInImage',
                png == null || url == null
                    ? const SizedBox()
                    : FadeInImage.memoryNetwork(placeholder: png, image: url, fit: BoxFit.cover)),
          ]),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            if (url != null) ...[
              ClipOval(child: Image.network(url, width: 80, height: 80, fit: BoxFit.cover)),
              ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.network(url, width: 110, height: 80, fit: BoxFit.cover)),
              CircleAvatar(radius: 36, backgroundImage: NetworkImage(url)),
            ],
          ]),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _framed(
                'grayscale',
                // A luminance matrix: ColorFilter.mode(…, BlendMode.saturation)
                // paints a gray slab over the page above it on Linux.
                ColorFiltered(
                  colorFilter: const ColorFilter.matrix([
                    0.2126, 0.7152, 0.0722, 0, 0,
                    0.2126, 0.7152, 0.0722, 0, 0,
                    0.2126, 0.7152, 0.0722, 0, 0,
                    0, 0, 0, 1, 0,
                  ]),
                  child: network(fit: BoxFit.cover),
                )),
            _framed(
                'blurred',
                ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                  child: network(fit: BoxFit.cover),
                )),
            _framed(
                'shader mask',
                ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    colors: [Colors.white, Colors.transparent],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: network(fit: BoxFit.cover),
                )),
          ]),
          gap,
          if (url != null)
            Row(children: [
              Expanded(
                child: Container(
                  height: 90,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    image: DecorationImage(image: NetworkImage(url), fit: BoxFit.cover),
                  ),
                  alignment: Alignment.bottomLeft,
                  padding: const EdgeInsets.all(8),
                  child: const Text('DecorationImage',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 90,
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: NetworkImage(url),
                      repeat: ImageRepeat.repeat,
                      scale: 6,
                      colorFilter: ColorFilter.mode(
                          Colors.indigo.withValues(alpha: 0.5), BlendMode.srcATop),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: const Text('Tiled, tinted', style: TextStyle(color: Colors.white)),
                ),
              ),
            ]),
          gap,
          if (brokenImageUrl != null)
            SizedBox(
              height: 80,
              child: Image.network(
                brokenImageUrl!,
                errorBuilder: (_, _, _) => Container(
                  color: Colors.red.shade50,
                  alignment: Alignment.center,
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.broken_image, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Failed to load'),
                  ]),
                ),
              ),
            ),
          gap,
          if (url != null)
            Material(
              child: Ink.image(
                image: NetworkImage(url),
                height: 100,
                fit: BoxFit.cover,
                child: InkWell(
                  onTap: () {},
                  child: const Center(
                    child: Text('Ink.image',
                        style: TextStyle(color: Colors.white, fontSize: 20)),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 260),
        ],
      ),
    );
  }
}

// ---- spinners ----------------------------------------------------------------

class SpinnersPage extends StatefulWidget {
  const SpinnersPage({super.key});

  static final _keys = List.generate(10, (_) => GlobalKey());

  /// The spinners that never come to rest while loading.
  static List<Object> get indeterminate => _keys;

  @override
  State<SpinnersPage> createState() => _SpinnersPageState();
}

class _SpinnersPageState extends State<SpinnersPage> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  bool _loading = true;
  double _progress = 0.2;

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = SpinnersPage._keys;
    Widget spinner(int i, Widget child) => _loading
        ? KeyedSubtree(key: k[i], child: child)
        : Icon(Icons.check_circle, key: k[i], color: Colors.green, size: 36);
    const gap = SizedBox(height: 20);
    return page(
      'Spinners & progress',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            spinner(0, const CircularProgressIndicator()),
            spinner(1, const CircularProgressIndicator(color: Colors.red, strokeWidth: 8)),
            spinner(2, const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            spinner(3, const RefreshProgressIndicator()),
          ]),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            const CircularProgressIndicator(value: 0.25),
            CircularProgressIndicator(value: 0.6, backgroundColor: Colors.grey.shade300),
            CircularProgressIndicator(value: _progress, strokeWidth: 6),
          ]),
          gap,
          spinner(4, const LinearProgressIndicator()),
          const SizedBox(height: 12),
          const LinearProgressIndicator(value: 0.3),
          const SizedBox(height: 12),
          LinearProgressIndicator(
              value: _progress, minHeight: 10, borderRadius: BorderRadius.circular(5)),
          gap,
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            spinner(5, const CupertinoActivityIndicator()),
            spinner(6, const CupertinoActivityIndicator(radius: 20)),
            const CupertinoActivityIndicator.partiallyRevealed(progress: 0.5, radius: 16),
            spinner(7, RotationTransition(turns: _spin, child: const Icon(Icons.sync, size: 36))),
          ]),
          gap,
          spinner(
            8,
            AnimatedBuilder(
              animation: _spin,
              builder: (_, _) => Container(
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  gradient: LinearGradient(
                    begin: Alignment(-1 + 3 * _spin.value - 1, 0),
                    end: Alignment(1 + 3 * _spin.value - 1, 0),
                    colors: [Colors.grey.shade300, Colors.grey.shade100, Colors.grey.shade300],
                  ),
                ),
              ),
            ),
          ),
          gap,
          Row(children: [
            _loading
                ? FilledButton.icon(
                    key: k[9],
                    onPressed: null,
                    icon: const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    label: const Text('Saving…'),
                  )
                : FilledButton.icon(
                    key: k[9],
                    onPressed: () {},
                    icon: const Icon(Icons.done),
                    label: const Text('Saved')),
            const Spacer(),
            OutlinedButton(
              onPressed: () => setState(() => _progress = (_progress + 0.3).clamp(0, 1)),
              child: const Text('Advance'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => setState(() {
                _loading = false;
                _spin.stop();
              }),
              child: const Text('Stop'),
            ),
          ]),
        ],
      ),
    );
  }
}

// ---- painting ----------------------------------------------------------------

class PaintingPage extends StatelessWidget {
  const PaintingPage({super.key});

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    Widget shape(String label, ShapeBorder border, Color color) => Container(
          width: 100,
          height: 56,
          decoration: ShapeDecoration(color: color, shape: border),
          alignment: Alignment.center,
          child: Text(label, style: const TextStyle(color: Colors.white)),
        );
    return page(
      'Painting & shapes',
      ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(height: 120, child: CustomPaint(painter: _ChartPainter(), size: Size.infinite)),
          gap,
          Wrap(spacing: 12, runSpacing: 12, children: [
            shape('Stadium', const StadiumBorder(), Colors.indigo),
            shape('Beveled', BeveledRectangleBorder(borderRadius: BorderRadius.circular(14)), Colors.teal),
            shape('Squircle', ContinuousRectangleBorder(borderRadius: BorderRadius.circular(28)), Colors.orange),
            shape('Outlined', const StadiumBorder(side: BorderSide(color: Colors.black, width: 2)), Colors.pink),
            const SizedBox(width: 56, height: 56, child: DecoratedBox(decoration: ShapeDecoration(color: Colors.purple, shape: CircleBorder()))),
            const SizedBox(width: 56, height: 56, child: DecoratedBox(decoration: ShapeDecoration(color: Colors.amber, shape: StarBorder(points: 5, innerRadiusRatio: 0.45)))),
          ]),
          gap,
          Row(children: [
            Expanded(
              child: Container(
                height: 70,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.red, Colors.yellow, Colors.green],
                    stops: [0, 0.5, 1],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 70,
                decoration: const BoxDecoration(
                  gradient: RadialGradient(colors: [Colors.white, Colors.blue], radius: 0.8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 70,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: [Colors.red, Colors.blue, Colors.green, Colors.red]),
                ),
              ),
            ),
          ]),
          gap,
          SizedBox(
            height: 90,
            child: ClipPath(
              clipper: const _StarClipper(),
              child: Container(
                decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.deepPurple, Colors.cyan])),
                alignment: Alignment.center,
                child: const Text('ClipPath', style: TextStyle(color: Colors.white)),
              ),
            ),
          ),
          gap,
          Container(
            height: 60,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
              boxShadow: [
                BoxShadow(color: Colors.indigo.withValues(alpha: 0.4), blurRadius: 16, spreadRadius: 2, offset: const Offset(0, 6)),
              ],
            ),
            alignment: Alignment.center,
            child: const Text('Two rounded corners, colored shadow'),
          ),
          gap,
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final e in [0.0, 1.0, 3.0, 8.0])
              Material(
                elevation: e,
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
                child: SizedBox(
                  width: 76,
                  height: 56,
                  child: Center(child: Text('Elevation ${e.round()}', style: const TextStyle(fontSize: 11))),
                ),
              ),
          ]),
          gap,
          const PhysicalModel(
            color: Colors.white,
            elevation: 6,
            shape: BoxShape.circle,
            child: SizedBox(width: 64, height: 64, child: Center(child: Text('Model'))),
          ),
          gap,
          Wrap(spacing: 16, runSpacing: 12, children: [
            for (final (icon, color) in [
              (Icons.alarm, Colors.teal),
              (Icons.camera_alt, Colors.red),
              (Icons.directions_bike, Colors.indigo),
              (Icons.eco, Colors.green),
              (Icons.favorite, Colors.pink),
              (Icons.wifi, Colors.blue),
              (CupertinoIcons.heart_fill, Colors.purple),
              (CupertinoIcons.settings, Colors.grey),
            ])
              Icon(icon, size: 32, color: color),
          ]),
          gap,
          Container(
            foregroundDecoration: BoxDecoration(
                border: Border.all(color: Colors.red, width: 3),
                borderRadius: BorderRadius.circular(8)),
            height: 50,
            color: Colors.yellow.shade100,
            alignment: Alignment.center,
            child: const Text('Foreground decoration'),
          ),
          gap,
          SizedBox(
            height: 110,
            child: Stack(fit: StackFit.expand, children: [
              Row(children: [
                for (final c in [Colors.red, Colors.green, Colors.blue, Colors.orange])
                  Expanded(child: ColoredBox(color: c)),
              ]),
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      width: 200,
                      height: 70,
                      color: Colors.white.withValues(alpha: 0.3),
                      alignment: Alignment.center,
                      child: const Text('Frosted', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 300),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.indigo
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(0, size.height);
    for (var x = 0.0; x <= size.width; x += 8) {
      path.lineTo(x, size.height / 2 + math.sin(x / 30) * size.height / 3);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _StarClipper extends CustomClipper<Path> {
  const _StarClipper();

  @override
  Path getClip(Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? r : r * 0.45;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final p = c + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  bool shouldReclip(_StarClipper oldClipper) => false;
}

// ---- native views ------------------------------------------------------------

class NativePage extends StatelessWidget {
  const NativePage({super.key});

  static final _web = GlobalKey();
  static final _map = GlobalKey();
  static final _button = GlobalKey();
  static final _video = GlobalKey();
  static List<Object> get views => [_web, _map, _button, _video];

  @override
  Widget build(BuildContext context) {
    Widget label(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        );
    return page(
      'Native views',
      ListView(
        padding: const EdgeInsets.all(12),
        children: [
          label('A web view (webview_flutter)'),
          SizedBox(key: _web, height: 220, child: const _FakePlatformView('plugins.flutter.io/webview')),
          label('A map (google_maps_flutter)'),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
                key: _map,
                height: 160,
                child: const _FakePlatformView('plugins.flutter.dev/google_maps_android')),
          ),
          label('A native control'),
          SizedBox(key: _button, height: 56, child: const _FakePlatformView('com.example/native_button')),
          label('A video texture'),
          SizedBox(key: _video, height: 180, child: const Texture(textureId: 0)),
          const SizedBox(height: 320),
        ],
      ),
    );
  }
}

/// A [PlatformViewLink] whose controller stands in for the platform's.
class _FakePlatformView extends StatelessWidget {
  const _FakePlatformView(this.viewType);
  final String viewType;

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: viewType,
      onCreatePlatformView: (params) {
        scheduleMicrotask(() => params.onPlatformViewCreated(params.id));
        return _StandInController(params.id);
      },
      surfaceFactory: (context, controller) => PlatformViewSurface(
        controller: controller,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
    );
  }
}

class _StandInController extends PlatformViewController {
  _StandInController(this.viewId);

  @override
  final int viewId;

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> dispose() async {}
}
