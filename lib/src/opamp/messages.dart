import 'dart:typed_data';

import 'wire.dart';

/// AgentCapabilities from the OpAMP spec.
abstract final class AgentCapabilities {
  static const int reportsStatus = 0x1;
  static const int acceptsRemoteConfig = 0x2;
  static const int reportsRemoteConfig = 0x1000;
  static const int reportsHeartbeat = 0x2000;
}

const int serverFlagReportFullState = 0x1;

abstract final class RemoteConfigStatuses {
  static const int unset = 0;
  static const int applied = 1;
  static const int applying = 2;
  static const int failed = 3;
}

abstract final class ServerErrorTypes {
  static const int unknown = 0;
  static const int badRequest = 1;
  static const int unavailable = 2;
}

class AgentDescription {
  AgentDescription({required this.identifying, required this.nonIdentifying});

  /// Values are `String`, `bool`, `int`, `double` or `List<String>`.
  final Map<String, Object> identifying;
  final Map<String, Object> nonIdentifying;
}

class RemoteConfigStatus {
  RemoteConfigStatus({
    required this.lastRemoteConfigHash,
    required this.status,
    this.errorMessage,
  });

  final Uint8List lastRemoteConfigHash;
  final int status;
  final String? errorMessage;
}

class AgentToServer {
  AgentToServer({
    required this.instanceUid,
    required this.sequenceNum,
    this.agentDescription,
    required this.capabilities,
    this.remoteConfigStatus,
    this.agentDisconnect = false,
    this.flags = 0,
    this.customCapabilities = const [],
  });

  final Uint8List instanceUid;
  final int sequenceNum;
  final AgentDescription? agentDescription;
  final int capabilities;
  final RemoteConfigStatus? remoteConfigStatus;
  final bool agentDisconnect;
  final int flags;
  final List<String> customCapabilities;
}

class AgentConfigObject {
  AgentConfigObject({Uint8List? body, this.contentType = ''})
      : body = body ?? Uint8List(0);
  Uint8List body;
  String contentType;
}

class RemoteConfig {
  RemoteConfig({Map<String, AgentConfigObject>? configMap, Uint8List? configHash})
      : configMap = configMap ?? {},
        configHash = configHash ?? Uint8List(0);
  final Map<String, AgentConfigObject> configMap;
  Uint8List configHash;
}

class ServerErrorResponse {
  int type = ServerErrorTypes.unknown;
  String message = '';
  int? retryAfterMs;
}

class ServerToAgent {
  Uint8List? instanceUid;
  ServerErrorResponse? errorResponse;
  RemoteConfig? remoteConfig;
  int? heartbeatIntervalSeconds;
  int flags = 0;
  int capabilities = 0;
  Uint8List? newInstanceUid;
}

void _writeAnyValue(Writer w, Object value) {
  if (value is String) {
    w.string(1, value, always: true);
  } else if (value is bool) {
    w.uint(2, value ? 1 : 0, always: true);
  } else if (value is int && value >= 0) {
    w.uint(3, value, always: true);
  } else if (value is num) {
    w.float64(4, value.toDouble());
  } else if (value is List) {
    w.message(5, (array) {
      for (final item in value) {
        array.message(1, (v) => v.string(1, '$item', always: true),
            always: true);
      }
    }, always: true);
  } else {
    w.string(1, '$value', always: true);
  }
}

void _writeAttributes(Writer w, int field, Map<String, Object> attrs) {
  attrs.forEach((key, value) {
    w.message(field, (kv) {
      kv.string(1, key);
      kv.message(2, (v) => _writeAnyValue(v, value), always: true);
    });
  });
}

Uint8List encodeAgentToServer(AgentToServer msg) {
  final w = Writer();
  w.bytes(1, msg.instanceUid);
  w.uint(2, msg.sequenceNum);
  final description = msg.agentDescription;
  if (description != null) {
    w.message(3, (d) {
      _writeAttributes(d, 1, description.identifying);
      _writeAttributes(d, 2, description.nonIdentifying);
    });
  }
  w.uint(4, msg.capabilities);
  final status = msg.remoteConfigStatus;
  if (status != null) {
    w.message(7, (s) {
      s.bytes(1, status.lastRemoteConfigHash);
      s.uint(2, status.status);
      final error = status.errorMessage;
      if (error != null && error.isNotEmpty) s.string(3, error);
    });
  }
  if (msg.agentDisconnect) w.message(9, (_) {}, always: true);
  w.uint(10, msg.flags);
  if (msg.customCapabilities.isNotEmpty) {
    w.message(12, (c) {
      for (final capability in msg.customCapabilities) {
        c.string(1, capability);
      }
    });
  }
  return w.finish();
}

AgentConfigObject _decodeConfigObject(Uint8List buf) {
  final object = AgentConfigObject();
  eachField(buf, (field, wireType, r) {
    if (wireType != wireLength) return false;
    if (field == 1) {
      object.body = Uint8List.fromList(r.bytes());
    } else if (field == 2) {
      object.contentType = r.string();
    } else {
      return false;
    }
    return true;
  });
  return object;
}

RemoteConfig _decodeRemoteConfig(Uint8List buf) {
  final config = RemoteConfig();
  eachField(buf, (field, wireType, r) {
    if (wireType != wireLength) return false;
    if (field == 2) {
      config.configHash = Uint8List.fromList(r.bytes());
      return true;
    }
    if (field != 1) return false;
    eachField(r.bytes(), (mapField, mapWire, mapReader) {
      if (mapField != 1 || mapWire != wireLength) return false;
      var key = '';
      var value = AgentConfigObject();
      eachField(mapReader.bytes(), (entryField, entryWire, entryReader) {
        if (entryWire != wireLength) return false;
        if (entryField == 1) {
          key = entryReader.string();
        } else if (entryField == 2) {
          value = _decodeConfigObject(entryReader.bytes());
        } else {
          return false;
        }
        return true;
      });
      config.configMap[key] = value;
      return true;
    });
    return true;
  });
  return config;
}

ServerToAgent decodeServerToAgent(Uint8List buf) {
  final msg = ServerToAgent();
  eachField(buf, (field, wireType, r) {
    switch (field) {
      case 1:
        if (wireType != wireLength) return false;
        msg.instanceUid = Uint8List.fromList(r.bytes());
        return true;
      case 2:
        if (wireType != wireLength) return false;
        final error = ServerErrorResponse();
        eachField(r.bytes(), (f, w, er) {
          if (f == 1 && w == wireVarint) {
            error.type = er.varint();
          } else if (f == 2 && w == wireLength) {
            error.message = er.string();
          } else if (f == 3 && w == wireLength) {
            eachField(er.bytes(), (rf, rw, rr) {
              if (rf != 1 || rw != wireVarint) return false;
              error.retryAfterMs = rr.varint() ~/ 1000000;
              return true;
            });
          } else {
            return false;
          }
          return true;
        });
        msg.errorResponse = error;
        return true;
      case 3:
        if (wireType != wireLength) return false;
        msg.remoteConfig = _decodeRemoteConfig(r.bytes());
        return true;
      case 4:
        if (wireType != wireLength) return false;
        eachField(r.bytes(), (f, w, cr) {
          if (f != 2 || w != wireLength) return false;
          eachField(cr.bytes(), (of, ow, or) {
            if (of != 4 || ow != wireVarint) return false;
            msg.heartbeatIntervalSeconds = or.varint();
            return true;
          });
          return true;
        });
        return true;
      case 6:
        if (wireType != wireVarint) return false;
        msg.flags = r.varint();
        return true;
      case 7:
        if (wireType != wireVarint) return false;
        msg.capabilities = r.varint();
        return true;
      case 8:
        if (wireType != wireLength) return false;
        eachField(r.bytes(), (f, w, ir) {
          if (f != 1 || w != wireLength) return false;
          msg.newInstanceUid = Uint8List.fromList(ir.bytes());
          return true;
        });
        return true;
    }
    return false;
  });
  return msg;
}

/// Encodes the parts of a ServerToAgent this client reads; for mock servers
/// in tests.
Uint8List encodeServerToAgent({
  Uint8List? instanceUid,
  RemoteConfig? remoteConfig,
  int? heartbeatIntervalSeconds,
  int flags = 0,
  int capabilities = 0,
  Uint8List? newInstanceUid,
}) {
  final w = Writer();
  if (instanceUid != null) w.bytes(1, instanceUid);
  if (remoteConfig != null) {
    w.message(3, (rc) {
      rc.message(1, (map) {
        remoteConfig.configMap.forEach((key, object) {
          map.message(1, (entry) {
            entry.string(1, key);
            entry.message(2, (o) {
              o.bytes(1, object.body);
              o.string(2, object.contentType);
            }, always: true);
          });
        });
      });
      rc.bytes(2, remoteConfig.configHash);
    });
  }
  if (heartbeatIntervalSeconds != null && heartbeatIntervalSeconds > 0) {
    w.message(
        4, (cs) => cs.message(2, (o) => o.uint(4, heartbeatIntervalSeconds)));
  }
  w.uint(6, flags);
  w.uint(7, capabilities);
  if (newInstanceUid != null) {
    w.message(8, (id) => id.bytes(1, newInstanceUid));
  }
  return w.finish();
}
