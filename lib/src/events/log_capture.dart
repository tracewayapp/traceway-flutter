import 'dart:async';

import '../guarded.dart';
import '../traceway_client.dart';

/// Builds a [ZoneSpecification] that mirrors every [print] call into the
/// Traceway event buffer while still forwarding the output to the parent zone.
///
/// `debugPrint` ultimately routes through `print`, so this also captures
/// framework debug output. `dart:developer.log` is *not* captured — it does
/// not flow through the Zone print hook.
ZoneSpecification buildLogZoneSpec() {
  return ZoneSpecification(
    print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
      // Never let log capture break the host app.
      guarded('print capture', () => TracewayClient.instance?.recordLog(line));
      parent.print(zone, line);
    },
  );
}
