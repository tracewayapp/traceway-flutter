/// The protobuf wire format, only as much as OpAMP needs: varints, length-
/// delimited fields and fixed 64-bit doubles.
library;

import 'dart:convert';
import 'dart:typed_data';

const int wireVarint = 0;
const int wireFixed64 = 1;
const int wireLength = 2;
const int wireFixed32 = 5;

class Writer {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void varint(int value) {
    var v = value < 0 ? 0 : value;
    while (v >= 0x80) {
      _out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _out.addByte(v);
  }

  void tag(int field, int wireType) => varint(field * 8 + wireType);

  /// Writes a varint field; zero is the proto3 default and is omitted unless
  /// [always] is set (needed inside a oneof, where presence matters).
  void uint(int field, int value, {bool always = false}) {
    if (value == 0 && !always) return;
    tag(field, wireVarint);
    varint(value);
  }

  void bytes(int field, List<int> value) {
    if (value.isEmpty) return;
    tag(field, wireLength);
    varint(value.length);
    _out.add(value);
  }

  void string(int field, String value, {bool always = false}) {
    final encoded = utf8.encode(value);
    if (encoded.isEmpty && always) {
      tag(field, wireLength);
      varint(0);
      return;
    }
    bytes(field, encoded);
  }

  void float64(int field, double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    tag(field, wireFixed64);
    _out.add(data.buffer.asUint8List());
  }

  /// Writes a nested message. An empty message is still written when
  /// [always] is set.
  void message(int field, void Function(Writer) build, {bool always = false}) {
    final inner = Writer();
    build(inner);
    final encoded = inner.finish();
    if (encoded.isEmpty && !always) return;
    tag(field, wireLength);
    varint(encoded.length);
    _out.add(encoded);
  }

  Uint8List finish() => _out.toBytes();
}

class Reader {
  Reader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get done => _pos >= _buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _buf.length) throw const FormatException('truncated varint');
      final byte = _buf[_pos++];
      if (shift < 63) result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
      if (shift > 70) throw const FormatException('varint too long');
    }
  }

  (int field, int wireType) tag() {
    final value = varint();
    return (value >> 3, value & 7);
  }

  Uint8List bytes() {
    final length = varint();
    if (length < 0 || _pos + length > _buf.length) {
      throw const FormatException('truncated field');
    }
    final out = Uint8List.sublistView(_buf, _pos, _pos + length);
    _pos += length;
    return out;
  }

  String string() => utf8.decode(bytes(), allowMalformed: true);

  void skip(int wireType) {
    switch (wireType) {
      case wireVarint:
        varint();
        return;
      case wireFixed64:
        _pos += 8;
        return;
      case wireLength:
        bytes();
        return;
      case wireFixed32:
        _pos += 4;
        return;
    }
    throw FormatException('unsupported wire type $wireType');
  }
}

/// Walks the fields of a message. [handle] returns false for a field it did
/// not consume, which is then skipped.
void eachField(
  Uint8List buf,
  bool Function(int field, int wireType, Reader reader) handle,
) {
  final reader = Reader(buf);
  while (!reader.done) {
    final (field, wireType) = reader.tag();
    if (!handle(field, wireType, reader)) reader.skip(wireType);
  }
}
