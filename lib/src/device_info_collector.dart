import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';

class DeviceInfoCollector {
  const DeviceInfoCollector._();

  /// The operating system only (`os.name`, `os.version`): what is left
  /// when `captureDeviceInfo` is off.
  static Map<String, String> collectOs() => {
        'os.name': Platform.operatingSystem,
        'os.version': Platform.operatingSystemVersion,
      };

  static Map<String, String> collectSync() {
    final info = collectOs();
    info['device.locale'] = Platform.localeName;
    info['runtime.version'] = Platform.version;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      info['device.form_factor'] = 'desktop';
    }
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize;
      info['screen.resolution'] =
          '${size.width.toInt()}x${size.height.toInt()}';
      info['screen.density'] = view.devicePixelRatio.toStringAsFixed(1);
      if ((Platform.isAndroid || Platform.isIOS) && view.devicePixelRatio > 0) {
        final shortest = (size.width < size.height ? size.width : size.height) /
            view.devicePixelRatio;
        // Material's breakpoint between a phone and a tablet.
        info['device.form_factor'] = shortest >= 600 ? 'tablet' : 'phone';
      }
    } catch (_) {}

    return info;
  }

  static Future<Map<String, String>> collectAsync([
    DeviceInfoPlugin? plugin,
  ]) async {
    final info = <String, String>{};

    try {
      final deviceInfo = plugin ?? DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        info['device.model'] = ios.model;
        info['device.name'] = ios.name;
        info['device.systemVersion'] = ios.systemVersion;
        info['device.manufacturer'] = 'Apple';
        info['device.modelId'] = ios.utsname.machine;
        info['device.isPhysical'] = ios.isPhysicalDevice.toString();
        _addMajor(info, ios.systemVersion);
        _addClass(info, ios.physicalRamSize);
      } else if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
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
