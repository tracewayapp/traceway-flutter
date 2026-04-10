import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/device_info_collector.dart';

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
