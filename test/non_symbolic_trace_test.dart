import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/stack_trace_formatter.dart';

const _releaseTrace = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 58347, tid: 8806539456, name io.flutter.platform
os: macos arch: arm64 comp: no sim: no
build_id: 'fe664295997135e7b67b648ba66ca9eb'
isolate_dso_base: 1130a0000, vm_dso_base: 1130a0000
    #00 abs 00000001131eca6b _kDartIsolateSnapshotInstructions+0x141e6b
    #01 abs 00000001131ec99b _kDartIsolateSnapshotInstructions+0x141d9b''';

const _debugTrace =
    '#0      chargeCard (package:flutter_demo/main.dart:20:3)\n'
    '#1      main (package:flutter_demo/main.dart:42:3)';

void main() {
  group('isNonSymbolicTrace', () {
    test('true for release/AOT trace', () {
      expect(isNonSymbolicTrace(_releaseTrace), isTrue);
    });

    test('false for debug/JIT trace', () {
      expect(isNonSymbolicTrace(_debugTrace), isFalse);
    });
  });

  group('extractBuildId', () {
    test('reads the header build id', () {
      expect(extractBuildId(_releaseTrace), 'fe664295997135e7b67b648ba66ca9eb');
    });

    test('null when absent', () {
      expect(extractBuildId(_debugTrace), isNull);
    });
  });

  group('formatFlutterError on a release trace', () {
    test('sends the raw trace without a runtimeType prefix', () {
      final result = formatFlutterError(
        StateError('card declined'),
        StackTrace.fromString(_releaseTrace),
      );
      expect(result.split('\n').first, 'Bad state: card declined');
      expect(result, isNot(startsWith('StateError:')));
      expect(result, contains('_kDartIsolateSnapshotInstructions+0x141e6b'));
      expect(result, contains('_kDartIsolateSnapshotInstructions+0x141d9b'));
      expect(result, contains("build_id: 'fe664295997135e7b67b648ba66ca9eb'"));
    });

    test('still symbolic-formats a debug trace', () {
      final result = formatFlutterError(
        StateError('x'),
        StackTrace.fromString(_debugTrace),
      );
      expect(result, contains('chargeCard'));
      expect(result, contains('package:flutter_demo/main.dart:20:3'));
      expect(result, isNot(contains('SnapshotInstructions')));
    });
  });
}
