import 'package:flutter_test/flutter_test.dart';
import 'package:traceway/src/stack_trace_formatter.dart';

void main() {
  group('formatException', () {
    test('formats error type and message', () {
      final error = Exception('test error');
      final trace = StackTrace.fromString(
        '#0      main (package:myapp/main.dart:10:5)\n'
        '#1      _startIsolate.<anonymous closure> (dart:isolate-patch/isolate_patch.dart:301:19)',
      );

      final result = formatException(error, trace);
      expect(result, contains('_Exception: Exception: test error'));
      expect(result, contains('main'));
      expect(result, contains('package:myapp/main.dart:10:5'));
    });

    test('handles empty stack trace', () {
      final error = Exception('test');
      final trace = StackTrace.fromString('');

      final result = formatException(error, trace);
      expect(result, contains('_Exception: Exception: test'));
    });
  });
}
