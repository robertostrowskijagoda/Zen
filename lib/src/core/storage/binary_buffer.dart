import 'dart:convert';
import 'dart:typed_data';

final class BinaryWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeBool(bool value) => writeUint8(value ? 1 : 0);

  void writeUint8(int value) {
    _builder.add(<int>[value]);
  }

  void writeUint32(int value) {
    final ByteData data = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void writeNullableUint32(int? value) {
    writeBool(value != null);
    if (value != null) {
      writeUint32(value);
    }
  }

  void writeInt64(int value) {
    final ByteData data = ByteData(8)..setInt64(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void writeNullableInt64(int? value) {
    writeBool(value != null);
    if (value != null) {
      writeInt64(value);
    }
  }

  void writeString(String value) {
    final List<int> bytes = utf8.encode(value);
    writeUint32(bytes.length);
    _builder.add(bytes);
  }

  void writeNullableString(String? value) {
    writeBool(value != null);
    if (value != null) {
      writeString(value);
    }
  }

  void writeBytes(Uint8List value) {
    writeUint32(value.length);
    _builder.add(value);
  }

  void writeNullableBytes(Uint8List? value) {
    writeBool(value != null);
    if (value != null) {
      writeBytes(value);
    }
  }

  Uint8List toBytes() => _builder.takeBytes();
}

final class BinaryReader {
  BinaryReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _offset = 0;

  bool get isAtEnd => _offset >= _bytes.lengthInBytes;

  bool readBool() => readUint8() == 1;

  int readUint8() {
    _ensureAvailable(1);
    final int value = _data.getUint8(_offset);
    _offset += 1;
    return value;
  }

  int readUint32() {
    _ensureAvailable(4);
    final int value = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int? readNullableUint32() {
    if (!readBool()) {
      return null;
    }
    return readUint32();
  }

  int readInt64() {
    _ensureAvailable(8);
    final int value = _data.getInt64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  int? readNullableInt64() {
    if (!readBool()) {
      return null;
    }
    return readInt64();
  }

  String readString() {
    final int length = readUint32();
    _ensureAvailable(length);
    final String value = utf8.decode(_bytes.sublist(_offset, _offset + length));
    _offset += length;
    return value;
  }

  String? readNullableString() {
    if (!readBool()) {
      return null;
    }
    return readString();
  }

  Uint8List readBytes() {
    final int length = readUint32();
    _ensureAvailable(length);
    final Uint8List value = Uint8List.fromList(
      _bytes.sublist(_offset, _offset + length),
    );
    _offset += length;
    return value;
  }

  Uint8List? readNullableBytes() {
    if (!readBool()) {
      return null;
    }
    return readBytes();
  }

  void _ensureAvailable(int length) {
    final int limit = _offset + length;
    if (limit > _bytes.lengthInBytes) {
      throw StateError('Binary buffer ended unexpectedly.');
    }
  }
}
