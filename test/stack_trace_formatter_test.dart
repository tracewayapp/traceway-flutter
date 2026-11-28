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

    test('keeps the frames of a package:stack_trace trace', () {
      final trace = StackTrace.fromString(
        'package:shop/cart.dart 12:5        Cart.add\n'
        'dart:async                         _Future._complete\n'
        'package:shop/checkout.dart 88      Checkout.pay.<fn>\n'
        '===== asynchronous gap ===========================\n'
        'package:shop/main.dart 7:3         main\n',
      );
      final result = formatException(StateError('empty cart'), trace);
      expect(result.split('\n'), [
        'StateError: Bad state: empty cart',
        'Cart.add',
        '    package:shop/cart.dart:12:5',
        '_Future._complete',
        '    dart:async',
        'Checkout.pay.<fn>',
        '    package:shop/checkout.dart:88',
        'main',
        '    package:shop/main.dart:7:3',
      ]);
    });

    test('keeps a trace in a format of its own as it is', () {
      final trace = StackTrace.fromString('at someFrame (weird:1)\nat other');
      final result = formatException(StateError('x'), trace);
      expect(result, contains('at someFrame (weird:1)'));
      expect(result, contains('at other'));
    });

    test('handles empty stack trace', () {
      final error = Exception('test');
      final trace = StackTrace.fromString('');

      final result = formatException(error, trace);
      expect(result, contains('_Exception: Exception: test'));
    });
  });
}
