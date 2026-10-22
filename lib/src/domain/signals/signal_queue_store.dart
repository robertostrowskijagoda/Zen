import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';

abstract interface class SignalQueueStore {
  Future<List<QueuedSignal>> load();

  Future<void> save(List<QueuedSignal> entries);
}

final class FileSignalQueueStore implements SignalQueueStore {
  FileSignalQueueStore({
    required this.store,
    this.storageKey = 'signals/pending',
  });

  static const List<int> _magicPrefix = <int>[0x5A, 0x53, 0x51];

  /// The layout written and read.
  static const int _currentVersion = 3;

  final FileBinaryStore store;
  final String storageKey;

  @override
  Future<List<QueuedSignal>> load() async {
    final Uint8List? bytes = await store.read(storageKey);
    if (bytes == null || bytes.isEmpty) {
      return const <QueuedSignal>[];
    }

    if (_isNewer(bytes)) {
      // A newer build's queue: kept as it is (never written over) and read
      // as empty until this build is updated.
      store.holdNewer(storageKey);
      return const <QueuedSignal>[];
    }
    if (!_isCurrent(bytes)) {
      // Damaged: the queue only holds signals in transit, so it is read as
      // empty (and written over with the next save).
      return const <QueuedSignal>[];
    }
    final BinaryReader reader = BinaryReader(bytes);
    for (int index = 0; index <= _magicPrefix.length; index += 1) {
      reader.readUint8();
    }
    final int count = reader.readUint32();
    final List<QueuedSignal> entries = <QueuedSignal>[];
    for (int index = 0; index < count; index += 1) {
      entries.add(QueuedSignal.readFrom(reader));
    }
    return List<QueuedSignal>.unmodifiable(entries);
  }

  @override
  Future<void> save(List<QueuedSignal> entries) async {
    if (entries.isEmpty) {
      await store.delete(storageKey);
      return;
    }

    final BinaryWriter writer = BinaryWriter();
    for (final int byte in _magicPrefix) {
      writer.writeUint8(byte);
    }
    writer.writeUint8(_currentVersion);
    writer.writeUint32(entries.length);
    for (final QueuedSignal entry in entries) {
      entry.writeTo(writer);
    }
    await store.write(storageKey, writer.toBytes());
  }

  bool _hasMagic(Uint8List bytes) {
    if (bytes.length <= _magicPrefix.length) {
      return false;
    }
    for (int index = 0; index < _magicPrefix.length; index += 1) {
      if (bytes[index] != _magicPrefix[index]) {
        return false;
      }
    }
    return true;
  }

  bool _isNewer(Uint8List bytes) =>
      _hasMagic(bytes) && bytes[_magicPrefix.length] > _currentVersion;

  bool _isCurrent(Uint8List bytes) {
    if (bytes.length <= _magicPrefix.length) {
      return false;
    }
    for (int index = 0; index < _magicPrefix.length; index += 1) {
      if (bytes[index] != _magicPrefix[index]) {
        return false;
      }
    }
    return bytes[_magicPrefix.length] == _currentVersion;
  }
}

final class MemorySignalQueueStore implements SignalQueueStore {
  List<QueuedSignal> _entries = const <QueuedSignal>[];

  @override
  Future<List<QueuedSignal>> load() async {
    return List<QueuedSignal>.unmodifiable(_entries);
  }

  @override
  Future<void> save(List<QueuedSignal> entries) async {
    _entries = List<QueuedSignal>.from(entries, growable: false);
  }
}
