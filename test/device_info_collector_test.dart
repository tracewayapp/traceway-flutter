import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/device_info_collector.dart';

/// What the plugin answers on an iPhone on iOS 17.4 and on a Pixel on
/// Android 14.
class _Device implements DeviceInfoPlugin {
  @override
  Future<IosDeviceInfo> get iosInfo async => IosDeviceInfo.fromMap({
        'name': 'iPhone',
        'systemName': 'iOS',
        'systemVersion': '17.4',
        'model': 'iPhone',
        'modelName': 'iPhone 15',
        'localizedModel': 'iPhone',
        'identifierForVendor': null,
        'freeDiskSize': 1,
        'totalDiskSize': 2,
        'isPhysicalDevice': true,
        'isiOSAppOnMac': false,
        'isiOSAppOnVision': false,
        'physicalRamSize': 6000,
        'availableRamSize': 3000,
        'utsname': {
          'sysname': 'Darwin',
          'nodename': 'iPhone',
          'release': '23.4.0',
          'version': 'Darwin Kernel Version 23.4.0',
          'machine': 'iPhone15,4',
        },
      });

  @override
  Future<AndroidDeviceInfo> get androidInfo async => AndroidDeviceInfo.fromMap({
        'version': {
          'baseOS': '',
          'sdkInt': 34,
          'release': '14',
          'codename': 'REL',
          'incremental': '11228894',
          'previewSdkInt': 0,
          'securityPatch': '2024-02-05',
        },
        'board': 'shiba',
        'bootloader': 'ripcurrent',
        'brand': 'google',
        'device': 'shiba',
        'display': 'UQ1A.240205.002',
        'fingerprint': 'google/shiba/shiba:14/UQ1A.240205.002/11224170:user',
        'hardware': 'shiba',
        'host': 'build',
        'id': 'UQ1A.240205.002',
        'manufacturer': 'Google',
        'model': 'Pixel 8',
        'product': 'shiba',
        'name': 'Pixel 8',
        'supported32BitAbis': <String>[],
        'supported64BitAbis': <String>['arm64-v8a'],
        'supportedAbis': <String>['arm64-v8a'],
        'tags': 'release-keys',
        'time': 0,
        'type': 'user',
        'isPhysicalDevice': true,
        'freeDiskSize': 1,
        'totalDiskSize': 2,
        'systemFeatures': <String>[],
        'isLowRamDevice': false,
        'physicalRamSize': 8000,
        'availableRamSize': 4000,
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A platform without the plugin: every question throws.
class _NoDevice implements DeviceInfoPlugin {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('DeviceInfoCollector.collectSync', () {
    test('collects platform info synchronously', () {
      final info = DeviceInfoCollector.collectSync();

      expect(info['os.name'], Platform.operatingSystem);
      expect(info['os.version'], isNotEmpty);
      expect(info['device.locale'], isNotEmpty);
      expect(info['runtime.version'], Platform.version);
    });

    test('always includes at least 4 fields', () {
      final info = DeviceInfoCollector.collectSync();
      expect(info.length, greaterThanOrEqualTo(4));
    });

    test('all values are non-null strings', () {
      final info = DeviceInfoCollector.collectSync();
      for (final entry in info.entries) {
        expect(entry.key, isA<String>());
        expect(entry.value, isA<String>());
      }
    });
  });

  group('os.version is the bare version number', () {
    final bare = RegExp(r'^\d+(\.\d+)*$');

    test('on this machine', () {
      expect(DeviceInfoCollector.collectSync()['os.version'], matches(bare),
          reason: Platform.operatingSystemVersion);
      expect(DeviceInfoCollector.collectOs()['os.version'], matches(bare));
    });

    test('read out of what Platform.operatingSystemVersion says', () {
      const described = {
        // iOS and macOS.
        'Version 17.4 (Build 21E219)': '17.4',
        'Version 18.0 (Build 22A3354)': '18.0',
        'Version 14.4.1 (Build 23E224)': '14.4.1',
        // Linux: `uname -srv`.
        'Linux 6.8.0-45-generic #45-Ubuntu SMP PREEMPT_DYNAMIC Fri Aug 30 '
            '12:02:04 UTC 2024': '6.8.0',
        'Linux 7.2.9-arch1-1 #1 SMP PREEMPT_DYNAMIC Sat, 03 Oct 2026 '
            '11:43:28 +0000': '7.2.9',
        '"Windows 10 Pro" 10.0 (Build 19045)': '10',
        '"Windows 11 Home" 10.0 (Build 22631)': '11',
      };
      described.forEach((description, version) {
        expect(DeviceInfoCollector.osVersionIn(description), version,
            reason: description);
      });
      // Android: the build's display id, which names no OS version.
      for (final id in [
        'UP1A.231005.007',
        'TP1A.220624.014.A525FXXU4CWB4',
        'RKQ1.211119.001 test-keys',
        '',
      ]) {
        expect(DeviceInfoCollector.osVersionIn(id), isNull, reason: id);
      }
    });

    test('on iOS and Android it is the version the system reports',
        () async {
      final plugin = _Device();
      final ios = await DeviceInfoCollector.collectAsync(plugin, 'ios');
      expect(ios['os.version'], '17.4');
      expect(ios['os.major'], '17');
      final android = await DeviceInfoCollector.collectAsync(plugin, 'android');
      expect(android['os.version'], '14');
      expect(android['os.major'], '14');
      expect(android['device.systemVersion'], 'Android 14 (SDK 34)');

      // With captureDeviceInfo off: the version and nothing of the device.
      expect(await DeviceInfoCollector.collectOsVersion(plugin, 'ios'),
          {'os.version': '17.4'});
      expect(await DeviceInfoCollector.collectOsVersion(plugin, 'android'),
          {'os.version': '14'});
      expect(await DeviceInfoCollector.collectOsVersion(plugin, 'linux'),
          isEmpty);
      expect(
          await DeviceInfoCollector.collectOsVersion(_NoDevice(), 'android'),
          isEmpty);
    });
  });

  group('DeviceInfoCollector.collectAsync', () {
    test('does not throw on collect', () async {
      expect(() => DeviceInfoCollector.collectAsync(), returnsNormally);
    });

    test('returns a map', () async {
      final info = await DeviceInfoCollector.collectAsync();
      expect(info, isA<Map<String, String>>());
    });

    test('all values are non-null strings', () async {
      final info = await DeviceInfoCollector.collectAsync();
      for (final entry in info.entries) {
        expect(entry.key, isA<String>());
        expect(entry.value, isA<String>());
      }
    });
  });

  group('DeviceInfoCollector sync/async split', () {
    test('sync and async produce disjoint keys', () async {
      final syncInfo = DeviceInfoCollector.collectSync();
      final asyncInfo = await DeviceInfoCollector.collectAsync();

      final syncKeys = syncInfo.keys.toSet();
      final asyncKeys = asyncInfo.keys.toSet();
      final overlap = syncKeys.intersection(asyncKeys);

      expect(overlap, isEmpty,
          reason: 'sync and async should not produce overlapping keys');
    });

    test('sync info is available immediately for early exceptions', () {
      final info = DeviceInfoCollector.collectSync();
      expect(info.containsKey('os.name'), isTrue);
      expect(info.containsKey('os.version'), isTrue);
      expect(info.containsKey('runtime.version'), isTrue);
    });
  });
}
