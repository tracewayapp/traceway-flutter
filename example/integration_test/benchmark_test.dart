import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_harness.dart';
import 'benchmark_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Benchmark: baseline', (tester) async {
    final metrics = await runBaseline(tester);
    BenchmarkCollector.emitResults(metrics);
  });

  testWidgets('Benchmark: sdk_idle_no_capture', (tester) async {
    final metrics = await runSdkIdleNoCapture(tester);
    BenchmarkCollector.emitResults(metrics);
  });

  testWidgets('Benchmark: sdk_burst_no_capture', (tester) async {
    final metrics = await runSdkBurstNoCapture(tester);
    BenchmarkCollector.emitResults(metrics);
  });

  testWidgets('Benchmark: sdk_idle_with_capture', (tester) async {
    final metrics = await runSdkIdleWithCapture(tester);
    BenchmarkCollector.emitResults(metrics);
  });

  testWidgets('Benchmark: sdk_burst_with_capture', (tester) async {
    final metrics = await runSdkBurstWithCapture(tester);
    BenchmarkCollector.emitResults(metrics);
  });

  testWidgets('Benchmark: video_burst_with_capture', (tester) async {
    final metrics = await runVideoBurstWithCapture(tester);
    BenchmarkCollector.emitResults(metrics);
  });
}
