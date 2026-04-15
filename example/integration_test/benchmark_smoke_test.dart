import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_harness.dart';
import 'benchmark_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Minimal smoke test: scrollBurst with capture configs only.
  const workloads = ['scrollBurst'];
  const configs = ['sdkCapture', 'sdkCaptureDisk'];

  for (final workload in workloads) {
    for (final config in configs) {
      testWidgets('Benchmark: ${workload}__$config', (tester) async {
        final metrics = await runScenario(
          tester: tester,
          workload: workload,
          config: config,
        );
        await BenchmarkCollector.emitResults(metrics);
      });
    }
  }
}
