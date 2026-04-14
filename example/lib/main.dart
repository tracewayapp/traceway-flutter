import 'dart:io';

import 'package:flutter/material.dart';
import 'package:traceway/traceway.dart';

// Pass via: flutter run --dart-define=TRACEWAY_DSN=token@https://...
// Falls back to local dev server if not set.
const _dsn = String.fromEnvironment('TRACEWAY_DSN');
String get _fallbackDsn =>
    'frontend-dev-token@http://${Platform.isAndroid ? '10.0.2.2' : 'localhost'}:8082/api/report';

void main() {
  Traceway.run(
    connectionString: _dsn.isNotEmpty ? _dsn : _fallbackDsn,
    options: const TracewayOptions(
      screenCapture: true,
      debug: true,
      version: '1.0.0',
      sampleRate: 1.0,
    ),
    child: const MyApp(),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Traceway Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _counter = 0;
  final List<String> _log = [];

  void _addLog(String msg) {
    setState(() {
      _log.insert(0, '[${TimeOfDay.now().format(context)}] $msg');
      if (_log.length > 50) _log.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traceway Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TracewayPrivacyMask(
              child: Text(
                'Counter: $_counter',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () {
                setState(() => _counter++);
                _addLog('Counter incremented to $_counter');
              },
              icon: const Icon(Icons.add),
              label: const Text('Increment Counter'),
            ),
            const SizedBox(height: 24),
            Text(
              'Error Testing',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: 'Capture Caught Exception',
              icon: Icons.bug_report,
              color: Colors.orange,
              onPressed: () {
                try {
                  throw FormatException(
                    'Invalid input: user entered "abc" for age field',
                  );
                } catch (e, st) {
                  TracewayClient.instance?.captureException(e, st);
                  _addLog('Caught exception sent to Traceway');
                }
              },
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: 'Capture Message',
              icon: Icons.message,
              color: Colors.blue,
              onPressed: () {
                TracewayClient.instance?.captureMessage(
                  'User opened settings page',
                );
                _addLog('Message sent to Traceway');
              },
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: 'Throw Uncaught Exception',
              icon: Icons.error,
              color: Colors.red,
              onPressed: () {
                _addLog('Throwing uncaught StateError...');
                // This will be caught by the Zone error handler
                Future.microtask(() {
                  throw StateError('Simulated uncaught async error');
                });
              },
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: 'Trigger Null Error',
              icon: Icons.warning,
              color: Colors.deepOrange,
              onPressed: () {
                _addLog('Triggering null error...');
                // ignore: avoid_dynamic_calls
                (null as dynamic).someMethod();
              },
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: 'Flush (Force Send)',
              icon: Icons.send,
              color: Colors.green,
              onPressed: () async {
                await TracewayClient.instance?.flush(5000);
                _addLog('Flush completed');
              },
            ),
            const SizedBox(height: 16),
            Text('Event Log',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _log.isEmpty
                    ? const Center(
                        child: Text(
                          'Interact with the app, then trigger an error.\n'
                          'The screen recording captures the last ~10 seconds.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _log.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            _log[i],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: color,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}
