import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

class DeviceInfoCollector {
  const DeviceInfoCollector._();

  /// The operating system only (`os.name`, `os.version`): what is left
  /// when `captureDeviceInfo` is off. On iOS and Android
  /// [collectOsVersion] has the version the system reports.
  static Map<String, String> collectOs() {
    final version = osVersionIn(Platform.operatingSystemVersion);
    return {
      'os.name': Platform.operatingSystem,
      if (version != null) 'os.version': version,
    };
  }

  static final RegExp _version = RegExp(r'(?<![\w.])\d+(?:\.\d+)*(?!\w)');

  /// The bare version number in [description], which is what
  /// `Platform.operatingSystemVersion` gives: `17.4` in iOS's and macOS's
  /// `Version 17.4 (Build 21E219)`, `6.8.0` in Linux's
  /// `Linux 6.8.0-45-generic #45-Ubuntu SMP …`, `11` in Windows's
  /// `"Windows 11 Pro" 10.0 (Build 22631)`. Null when it names none:
  /// Android's is a build id (`UP1A.231005.007`).
  static String? osVersionIn(String description) =>
      _version.stringMatch(description);

  /// `os.version` as the system reports it (iOS `systemVersion`, Android
  /// `Build.VERSION.RELEASE`), without anything else of the device; empty
  /// on other platforms, where [collectOs] reads it.
  static Future<Map<String, String>> collectOsVersion([
    DeviceInfoPlugin? plugin,
    String? operatingSystem,
  ]) async {
    final os = operatingSystem ?? Platform.operatingSystem;
    try {
      final deviceInfo = plugin ?? DeviceInfoPlugin();
      final version = os == 'ios'
          ? (await deviceInfo.iosInfo).systemVersion
          : os == 'android'
              ? (await deviceInfo.androidInfo).version.release
              : '';
      if (version.isNotEmpty) return {'os.version': version};
    } catch (_) {}
    return {};
  }

  /// Where the views are read: the binding's dispatcher (the engine's, or
  /// the one a test drives), or the engine's when there is no binding.
  static ui.PlatformDispatcher get _dispatcher {
    try {
      return WidgetsBinding.instance.platformDispatcher;
    } catch (_) {
      return ui.PlatformDispatcher.instance;
    }
  }

  /// The first view, once the engine knows its size.
  static ui.FlutterView? _sizedView() {
    try {
      final views = _dispatcher.views;
      if (views.isEmpty) return null;
      final view = views.first;
      return view.physicalSize.isEmpty || view.devicePixelRatio <= 0
          ? null
          : view;
    } catch (_) {
      return null;
    }
  }

  /// Completes once the first view has a size, or after [timeout]. On
  /// Android the engine learns the window's metrics a moment after `main`
  /// started, which is where `Traceway.run` starts the SDK: until then the
  /// view is 0x0 at a ratio of 1.0. An app started without a window (in
  /// the background) gets none, and [collectSync] leaves the screen out.
  static Future<void> screenKnown({
    Duration timeout = const Duration(seconds: 2),
    Duration every = const Duration(milliseconds: 16),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_sizedView() == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(every);
    }
  }

  /// The screen is read as it is now: after [screenKnown] at start. Before
  /// the view has a size it is left out, not reported as 0x0.
  static Map<String, String> collectSync() {
    final info = collectOs();
    info['device.locale'] = Platform.localeName;
    info['runtime.version'] = Platform.version;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      info['device.form_factor'] = 'desktop';
    }
    final view = _sizedView();
    if (view != null) {
      final size = view.physicalSize;
      info['screen.resolution'] =
          '${size.width.toInt()}x${size.height.toInt()}';
      info['screen.density'] = view.devicePixelRatio.toStringAsFixed(1);
      if (Platform.isAndroid || Platform.isIOS) {
        final shortest = (size.width < size.height ? size.width : size.height) /
            view.devicePixelRatio;
        // Material's breakpoint between a phone and a tablet.
        info['device.form_factor'] = shortest >= 600 ? 'tablet' : 'phone';
      }
    }

    return info;
  }

  /// [operatingSystem] is `Platform.operatingSystem` unless a test names
  /// another.
  static Future<Map<String, String>> collectAsync([
    DeviceInfoPlugin? plugin,
    String? operatingSystem,
  ]) async {
    final info = <String, String>{};
    final os = operatingSystem ?? Platform.operatingSystem;

    try {
      final deviceInfo = plugin ?? DeviceInfoPlugin();
      if (os == 'ios') {
        final ios = await deviceInfo.iosInfo;
        if (ios.systemVersion.isNotEmpty) {
          info['os.version'] = ios.systemVersion;
        }
        info['device.model'] = ios.model;
        info['device.name'] = ios.name;
        info['device.systemVersion'] = ios.systemVersion;
        info['device.manufacturer'] = 'Apple';
        info['device.modelId'] = ios.utsname.machine;
        info['device.isPhysical'] = ios.isPhysicalDevice.toString();
        _addMajor(info, ios.systemVersion);
        _addClass(info, ios.physicalRamSize);
      } else if (os == 'android') {
        final android = await deviceInfo.androidInfo;
        if (android.version.release.isNotEmpty) {
          info['os.version'] = android.version.release;
        }
        info['device.model'] = android.model;
        info['device.manufacturer'] = android.manufacturer;
        info['device.brand'] = android.brand;
        info['device.systemVersion'] =
            'Android ${android.version.release} (SDK ${android.version.sdkInt})';
        info['device.modelId'] = android.device;
        info['device.isPhysical'] = android.isPhysicalDevice.toString();
        _addMajor(info, android.version.release);
        _addClass(info, android.physicalRamSize);
      }
    } catch (_) {}

    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            info['device.ip'] = addr.address;
            break;
          }
        }
        if (info.containsKey('device.ip')) break;
      }
    } catch (_) {}

    return info;
  }

  static void _addMajor(Map<String, String> info, String version) {
    final major = RegExp(r'^\d+').stringMatch(version.trim());
    if (major != null) info['os.major'] = major;
  }

  /// A coarse device class for the metrics dimension, from the RAM the
  /// system reports (in MB, a little under the nominal size).
  static void _addClass(Map<String, String> info, int ramMb) {
    if (ramMb <= 0) return;
    final gb = ramMb / 1024;
    info['device.class'] = gb < 3 ? 'low' : (gb < 6 ? 'mid' : 'high');
  }
}
