import 'dart:io';
import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';

class DeviceInfoCollector {
  const DeviceInfoCollector._();

  static Map<String, String> collectSync() {
    final info = <String, String>{};

    info['os.name'] = Platform.operatingSystem;
    info['os.version'] = Platform.operatingSystemVersion;
    info['device.locale'] = Platform.localeName;
    info['runtime.version'] = Platform.version;

    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize;
      info['screen.resolution'] =
          '${size.width.toInt()}x${size.height.toInt()}';
      info['screen.density'] = view.devicePixelRatio.toStringAsFixed(1);
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
      } else if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        info['device.model'] = android.model;
        info['device.manufacturer'] = android.manufacturer;
        info['device.brand'] = android.brand;
        info['device.systemVersion'] =
            'Android ${android.version.release} (SDK ${android.version.sdkInt})';
        info['device.modelId'] = android.device;
        info['device.isPhysical'] = android.isPhysicalDevice.toString();
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
}
