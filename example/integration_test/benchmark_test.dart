import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import 'benchmark_harness.dart';
import 'benchmark_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const workloads = [
    'idle',
    'scroll',
    'navigation',
    'fullInteraction',
    'exceptionBurst',
    'videoPlayback',
    'idleBurst',
    'scrollBurst',
    'navigationBurst',
    'videoPlaybackBurst',
  ];
  const configs = [
    'noSdk',
    'sdkNoCapture',
    'sdkCapture',
    'sdkCaptureDisk',
  ];

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
