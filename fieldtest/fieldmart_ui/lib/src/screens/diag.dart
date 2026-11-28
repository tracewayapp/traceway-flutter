import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../app.dart' show pageBar, crashExit;
import '../labels.dart';
import '../scope.dart';

/// Errors the diagnostics buttons raise, named so issues are easy to find.
class FieldmartDiagnosticError extends Error {
  FieldmartDiagnosticError(this.message);
  final String message;
  @override
  String toString() => 'FieldmartDiagnosticError: $message';
}

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String _last = '';

  void _did(String what) => setState(() => _last = what);

  void _handled() {
    final scope = Fieldmart.of(context);
    try {
      throw FieldmartDiagnosticError('FM handled ${scope.settings.run}');
    } catch (e, st) {
      scope.telemetry.captureException(e, st, {'fm.diag': 'handled'});
    }
    _did('handled exception reported');
  }

  void _unhandled() {
    final scope = Fieldmart.of(context);
    _did('unhandled error thrown');
    if (scope.settings.crashExit) {
      // A real process death after the error, for the crash test.
      Timer(const Duration(milliseconds: 800), crashExit);
    }
    throw FieldmartDiagnosticError('FM unhandled ${scope.settings.run}');
  }

  void _reject() {
    final run = Fieldmart.of(context).settings.run;
    _did('uncaught async error');
    unawaited(Future<void>.delayed(const Duration(milliseconds: 10),
        () => throw FieldmartDiagnosticError('FM async $run')));
  }

  void _hang() {
    final until = DateTime.now().add(const Duration(milliseconds: 2500));
    var spins = 0;
    while (DateTime.now().isBefore(until)) {
      spins++;
    }
    _did('blocked the UI isolate for 2,500 ms ($spins spins)');
  }

  void _logs() {
    for (var i = 1; i <= 1000; i++) {
      // 50 characters per line, numbered.
      print('FM burst ${i.toString().padLeft(4, '0')} ${'x' * 36}');
    }
    _did('1,000 log lines written');
  }

  Future<void> _http500() async {
    final status = await Fieldmart.of(context).api.fail500();
    _did('GET /fx/api/fail/500 answered $status');
  }

  Future<void> _slow() async {
    final status = await Fieldmart.of(context).api.slow(1500);
    _did('GET /fx/api/slow answered $status');
  }

  void _event() {
    final scope = Fieldmart.of(context);
    scope.telemetry.track('fm.checkout.step', {'step': 'payment', 'fm.run': scope.settings.run});
    scope.telemetry.metric('fm.cart.value', scope.cart.totalCents / 100, {'currency': 'eur'});
    _did('event fm.checkout.step and metric fm.cart.value sent');
  }

  void _message() {
    final scope = Fieldmart.of(context);
    scope.telemetry.captureMessage('FM message ${scope.settings.run}');
    _did('message reported');
  }

  @override
  Widget build(BuildContext context) {
    final scope = Fieldmart.of(context);
    final s = scope.settings;
    Widget button(String id, VoidCallback onPressed) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: OutlinedButton(key: ValueKey(id), onPressed: onPressed, child: Text(L.diagButtons[id]!)),
        );
    Widget fact(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 80, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
            Expanded(child: value),
          ]),
        );
    return Scaffold(
      appBar: pageBar(context, L.diagTitle),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        fact(L.diagRun, SelectableText(s.run, key: const ValueKey('fm-diag-run'))),
        fact(L.diagVariant, Text('${s.variant} (${scope.telemetry.name})')),
        fact(L.diagScenario, Text(s.scenario ?? '-')),
        fact(L.diagBuild, const Text('fieldtest-2.1.0')),
        fact(L.diagSession, SelectableText(scope.telemetry.sessionId ?? '-', key: const ValueKey('fm-diag-session'))),
        const SizedBox(height: 8),
        button('fm-diag-handled', _handled),
        button('fm-diag-unhandled', _unhandled),
        button('fm-diag-reject', _reject),
        button('fm-diag-hang', _hang),
        button('fm-diag-logs', _logs),
        button('fm-diag-http500', _http500),
        button('fm-diag-slow', _slow),
        button('fm-diag-event', _event),
        button('fm-diag-message', _message),
        const SizedBox(height: 12),
        Text(_last),
      ]),
    );
  }
}
