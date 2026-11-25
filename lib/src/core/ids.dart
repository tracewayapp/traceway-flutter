import 'dart:math';
import 'dart:typed_data';

final Random _random = _secureRandom();

Random _secureRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The bytes [hex] spells, or null when it is not an even run of hex digits.
Uint8List? hexToBytes(String hex) {
  if (hex.length.isOdd || !_hexDigits.hasMatch(hex)) return null;
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]+$');

String bytesToUuid(List<int> bytes) {
  final hex = bytesToHex(bytes);
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Uint8List? uuidToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  return hex.length == 32 ? hexToBytes(hex) : null;
}

/// RFC 9562 UUIDv7: a millisecond timestamp followed by random bits, as OpAMP
/// recommends for instance ids.
String uuidv7([int? nowMs]) {
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = _random.nextInt(256);
  }
  var ts = max(0, nowMs ?? DateTime.now().millisecondsSinceEpoch);
  for (var i = 5; i >= 0; i--) {
    bytes[i] = ts % 256;
    ts = ts ~/ 256;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return bytesToUuid(bytes);
}

String uuidv4() {
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = _random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return bytesToUuid(bytes);
}

/// FNV-1a mapped to [0, 1): a stable sampling decision for an id such as a
/// session id. Matches the browser SDK so both sample the same sessions.
double unitHash(String value) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < value.length; i++) {
    hash ^= value.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash / 0x100000000;
}
