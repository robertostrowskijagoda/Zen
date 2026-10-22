import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/media/media_vault.dart';

const int kAttachmentChunkSizeBytes = 64 * 1024;
const Object _outgoingAttachmentTransferUnset = Object();

/// Largest attachment taken from a peer, in bytes.
///
/// The app has no explicit size limit when sending, but every transfer has
/// to fit the binary store ([BinaryCodec.defaultMaxPayloadBytes]) on at
/// least one side, so nothing bigger ever arrives from a real sender. The
/// 10% headroom only keeps a borderline legitimate file from being refused.
const int kMaxIncomingAttachmentBytes =
    BinaryCodec.defaultMaxPayloadBytes * 11 ~/ 10;

/// Largest single chunk accepted (senders cut [kAttachmentChunkSizeBytes]).
const int kMaxIncomingAttachmentChunkBytes = 2 * kAttachmentChunkSizeBytes;

/// Most chunks one incoming transfer may announce.
const int kMaxIncomingAttachmentChunks =
    kMaxIncomingAttachmentBytes ~/ 1024 + 1;

/// Unfinished incoming transfers one peer may have at once.
const int kMaxConcurrentIncomingTransfersPerPeer = 8;

/// An unfinished incoming transfer nobody wrote to for this long is dropped.
const Duration kIncomingAttachmentTransferExpiry = Duration(days: 2);

/// Whether a transfer announced as [transferBytes] in [chunkCount] chunks is
/// one a real sender could have produced and this app could store.
bool isPlausibleIncomingTransfer({
  required int transferBytes,
  required int chunkCount,
}) {
  return transferBytes > 0 &&
      transferBytes <= kMaxIncomingAttachmentBytes &&
      chunkCount > 0 &&
      chunkCount <= kMaxIncomingAttachmentChunks &&
      chunkCount <= transferBytes &&
      chunkCount * kMaxIncomingAttachmentChunkBytes >= transferBytes;
}

final class OutgoingAttachmentTransfer {
  OutgoingAttachmentTransfer({
    required this.peerAddress,
    required this.messageId,
    required this.text,
    required this.sentAtMillis,
    required this.type,
    this.attachmentBytes,
    this.attachmentPath,
    this.fileName,
    this.mimeType,
    this.attachmentSizeBytes,
    this.durationMs,
    this.chunkSizeBytes = kAttachmentChunkSizeBytes,
    this.placeholderSent = false,
    this.ackedChunkIndexes = const <int>[],
  }) : assert(
         (attachmentBytes != null && attachmentBytes.isNotEmpty) ||
             ((attachmentPath?.trim().isNotEmpty ?? false) &&
                 (attachmentSizeBytes ?? 0) > 0),
         'Outgoing attachment transfer requires bytes or a file path with size.',
       );

  final String peerAddress;
  final String messageId;
  final String text;
  final int sentAtMillis;
  final ChatMessageType type;
  final Uint8List? attachmentBytes;
  final String? attachmentPath;
  final String? fileName;
  final String? mimeType;
  final int? attachmentSizeBytes;
  final int? durationMs;
  final int chunkSizeBytes;
  final bool placeholderSent;
  final List<int> ackedChunkIndexes;

  String get storageKey =>
      AttachmentTransferStore.scopeKey(peerAddress, messageId);

  int get transferBytes => attachmentSizeBytes ?? attachmentBytes?.length ?? 0;

  int get chunkCount => transferBytes == 0
      ? 0
      : (transferBytes + chunkSizeBytes - 1) ~/ chunkSizeBytes;

  bool get isComplete =>
      chunkCount > 0 && ackedChunkIndexes.toSet().length >= chunkCount;

  /// Bytes of chunk [chunkIndex]: from memory, or from the file (an
  /// encrypted one through [vault], by default [MediaVault.current]).
  Future<Uint8List> chunkAt(int chunkIndex, {MediaVault? vault}) async {
    final int totalBytes = transferBytes;
    final int start = chunkIndex * chunkSizeBytes;
    final int end = start + chunkSizeBytes < totalBytes
        ? start + chunkSizeBytes
        : totalBytes;
    if (chunkIndex < 0 || start >= end || end > totalBytes) {
      throw RangeError.index(chunkIndex, ackedChunkIndexes, 'chunkIndex');
    }
    final Uint8List? bytes = attachmentBytes;
    if (bytes != null) {
      return Uint8List.sublistView(bytes, start, end);
    }
    final String? path = attachmentPath;
    if (path == null || path.isEmpty) {
      throw StateError('Outgoing attachment payload is unavailable.');
    }
    final File file = File(path);
    if (!await file.exists()) {
      throw StateError('Outgoing attachment file no longer exists.');
    }
    if (isMediaVaultPath(path)) {
      final MediaVault? reader = vault ?? MediaVault.current;
      if (reader == null) {
        throw StateError('Encrypted attachment cannot be read here.');
      }
      return reader.readRange(path, start, end);
    }
    final RandomAccessFile handle = await file.open(mode: FileMode.read);
    try {
      await handle.setPosition(start);
      return Uint8List.fromList(await handle.read(end - start));
    } finally {
      await handle.close();
    }
  }

  OutgoingAttachmentTransfer copyWith({
    Object? attachmentBytes = _outgoingAttachmentTransferUnset,
    Object? attachmentPath = _outgoingAttachmentTransferUnset,
    String? fileName,
    String? mimeType,
    int? attachmentSizeBytes,
    Object? durationMs = _outgoingAttachmentTransferUnset,
    int? chunkSizeBytes,
    bool? placeholderSent,
    List<int>? ackedChunkIndexes,
  }) {
    return OutgoingAttachmentTransfer(
      peerAddress: peerAddress,
      messageId: messageId,
      text: text,
      sentAtMillis: sentAtMillis,
      type: type,
      attachmentBytes:
          identical(attachmentBytes, _outgoingAttachmentTransferUnset)
          ? this.attachmentBytes
          : castCopyWithValue<Uint8List>(
              attachmentBytes,
              fieldName: 'attachmentBytes',
            ),
      attachmentPath:
          identical(attachmentPath, _outgoingAttachmentTransferUnset)
          ? this.attachmentPath
          : castCopyWithValue<String>(
              attachmentPath,
              fieldName: 'attachmentPath',
            ),
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      attachmentSizeBytes: attachmentSizeBytes ?? this.attachmentSizeBytes,
      durationMs: identical(durationMs, _outgoingAttachmentTransferUnset)
          ? this.durationMs
          : castCopyWithValue<int>(durationMs, fieldName: 'durationMs'),
      chunkSizeBytes: chunkSizeBytes ?? this.chunkSizeBytes,
      placeholderSent: placeholderSent ?? this.placeholderSent,
      ackedChunkIndexes: ackedChunkIndexes ?? this.ackedChunkIndexes,
    );
  }
}

final class IncomingAttachmentTransfer {
  const IncomingAttachmentTransfer({
    required this.peerAddress,
    required this.messageId,
    required this.text,
    required this.sentAtMillis,
    required this.type,
    required this.transferBytes,
    required this.chunkCount,
    this.fileName,
    this.mimeType,
    this.attachmentSizeBytes,
    this.durationMs,
    this.receivedChunks = const <int, Uint8List>{},
  });

  final String peerAddress;
  final String messageId;
  final String text;
  final int sentAtMillis;
  final ChatMessageType type;
  final int transferBytes;
  final int chunkCount;
  final String? fileName;
  final String? mimeType;
  final int? attachmentSizeBytes;
  final int? durationMs;
  final Map<int, Uint8List> receivedChunks;

  String get storageKey =>
      AttachmentTransferStore.scopeKey(peerAddress, messageId);

  bool get isComplete => chunkCount > 0 && receivedChunks.length >= chunkCount;

  /// Bytes received so far.
  int get receivedBytes => receivedChunks.values.fold<int>(
    0,
    (int sum, Uint8List chunk) => sum + chunk.length,
  );

  /// Whether chunk [chunkIndex] of [byteCount] bytes fits this transfer: a
  /// real index, a sane size, and never more in total than announced.
  bool acceptsChunk(int chunkIndex, int byteCount) {
    if (chunkIndex < 0 ||
        chunkIndex >= chunkCount ||
        byteCount <= 0 ||
        byteCount > kMaxIncomingAttachmentChunkBytes) {
      return false;
    }
    if (receivedChunks.containsKey(chunkIndex)) {
      // A re-sent chunk: already stored, only the ack is repeated.
      return true;
    }
    return receivedBytes + byteCount <= transferBytes;
  }

  IncomingAttachmentTransfer addChunk(int chunkIndex, Uint8List bytes) {
    final Map<int, Uint8List> next = <int, Uint8List>{
      for (final MapEntry<int, Uint8List> entry in receivedChunks.entries)
        entry.key: Uint8List.fromList(entry.value),
    };
    next.putIfAbsent(chunkIndex, () => Uint8List.fromList(bytes));
    return IncomingAttachmentTransfer(
      peerAddress: peerAddress,
      messageId: messageId,
      text: text,
      sentAtMillis: sentAtMillis,
      type: type,
      transferBytes: transferBytes,
      chunkCount: chunkCount,
      fileName: fileName,
      mimeType: mimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: durationMs,
      receivedChunks: next,
    );
  }

  Uint8List assembleBytes() {
    final BytesBuilder builder = BytesBuilder(copy: false);
    for (int index = 0; index < chunkCount; index += 1) {
      final Uint8List? chunk = receivedChunks[index];
      if (chunk == null) {
        throw StateError('Attachment chunk $index is missing.');
      }
      builder.add(chunk);
    }
    final Uint8List bytes = builder.takeBytes();
    if (transferBytes > 0 && bytes.length != transferBytes) {
      throw StateError(
        'Attachment transfer assembled to an unexpected length.',
      );
    }
    return bytes;
  }
}

abstract interface class AttachmentTransferStore {
  Future<OutgoingAttachmentTransfer?> loadOutgoing(
    String peerAddress,
    String messageId,
  );

  Future<List<OutgoingAttachmentTransfer>> loadAllOutgoing();

  Future<void> saveOutgoing(OutgoingAttachmentTransfer transfer);

  Future<void> deleteOutgoing(String peerAddress, String messageId);

  Future<IncomingAttachmentTransfer?> loadIncoming(
    String peerAddress,
    String messageId,
  );

  Future<void> saveIncoming(IncomingAttachmentTransfer transfer);

  Future<void> deleteIncoming(String peerAddress, String messageId);

  /// How many unfinished incoming transfers [peerAddress] has stored.
  Future<int> countIncoming(String peerAddress);

  /// Deletes unfinished incoming transfers not written to since
  /// [olderThanMillis] (wall clock). Returns how many went.
  Future<int> deleteStaleIncoming({required int olderThanMillis});

  /// Common prefix of every [scopeKey] of [peerAddress].
  static String peerScopePrefix(String peerAddress) {
    final String encodedPeer = base64Url
        .encode(utf8.encode(peerAddress))
        .replaceAll('=', '');
    return '$encodedPeer/';
  }

  static String scopeKey(String peerAddress, String messageId) {
    final String encodedPeer = base64Url
        .encode(utf8.encode(peerAddress))
        .replaceAll('=', '');
    final String encodedMessage = base64Url
        .encode(utf8.encode(messageId))
        .replaceAll('=', '');
    return '$encodedPeer/$encodedMessage';
  }
}

/// Transfers in the encrypted store. A transfer's key is made of keyed
/// hashes ([FileBinaryStore.nameSegmentFor]) of the friend's address and
/// the message id, so no file or folder name shows who it is with; the
/// friend's hash is a folder of its own, which keeps the per-friend limit
/// and the stale sweep a matter of listing folders.
final class FileAttachmentTransferStore implements AttachmentTransferStore {
  FileAttachmentTransferStore({
    required this.store,
    this.storagePrefix = 'transfers',
  });

  static const int _versionMarker = 255;
  static const int _currentVersion = 3;
  static const String _incomingFolder = 'in';
  static const String _outgoingFolder = 'out';

  final FileBinaryStore store;
  final String storagePrefix;

  @override
  Future<void> deleteIncoming(String peerAddress, String messageId) async {
    await store.delete(await _key(_incomingFolder, peerAddress, messageId));
  }

  @override
  Future<void> deleteOutgoing(String peerAddress, String messageId) async {
    await store.delete(await _key(_outgoingFolder, peerAddress, messageId));
  }

  Directory _folder(String direction) => Directory(
    '${store.rootDirectory.path}${Platform.pathSeparator}$storagePrefix'
    '${Platform.pathSeparator}$direction',
  );

  @override
  Future<int> countIncoming(String peerAddress) async {
    final Directory directory = Directory(
      '${_folder(_incomingFolder).path}${Platform.pathSeparator}'
      '${await store.nameSegmentFor(peerAddress)}',
    );
    if (!await directory.exists()) {
      return 0;
    }
    int count = 0;
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.zenbin')) {
        count += 1;
      }
    }
    return count;
  }

  @override
  Future<int> deleteStaleIncoming({required int olderThanMillis}) async {
    final Directory directory = _folder(_incomingFolder);
    if (!await directory.exists()) {
      return 0;
    }
    int deleted = 0;
    await for (final FileSystemEntity entity in directory.list(
      recursive: true,
    )) {
      if (entity is! File || !entity.path.endsWith('.zenbin')) {
        continue;
      }
      try {
        final DateTime modified = await entity.lastModified();
        if (modified.millisecondsSinceEpoch >= olderThanMillis) {
          continue;
        }
        await store.delete(_keyOfFile(entity));
        deleted += 1;
      } on FileSystemException {
        // Gone already, or busy: the next sweep gets it.
      }
    }
    return deleted;
  }

  @override
  Future<List<OutgoingAttachmentTransfer>> loadAllOutgoing() async {
    final Directory directory = _folder(_outgoingFolder);
    if (!await directory.exists()) {
      return const <OutgoingAttachmentTransfer>[];
    }
    final List<OutgoingAttachmentTransfer> transfers =
        <OutgoingAttachmentTransfer>[];
    await for (final FileSystemEntity entity in directory.list(
      recursive: true,
    )) {
      if (entity is! File || !entity.path.endsWith('.zenbin')) {
        continue;
      }
      final Uint8List? bytes = await store.read(_keyOfFile(entity));
      if (bytes == null || bytes.isEmpty) {
        continue;
      }
      final OutgoingAttachmentTransfer? transfer = _readOutgoing(bytes);
      if (transfer != null) {
        transfers.add(transfer);
      }
    }
    transfers.sort(
      (OutgoingAttachmentTransfer left, OutgoingAttachmentTransfer right) =>
          left.sentAtMillis.compareTo(right.sentAtMillis),
    );
    return List<OutgoingAttachmentTransfer>.unmodifiable(transfers);
  }

  @override
  Future<IncomingAttachmentTransfer?> loadIncoming(
    String peerAddress,
    String messageId,
  ) async {
    final Uint8List? bytes = await store.read(
      await _key(_incomingFolder, peerAddress, messageId),
    );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return _readIncoming(bytes);
  }

  @override
  Future<OutgoingAttachmentTransfer?> loadOutgoing(
    String peerAddress,
    String messageId,
  ) async {
    final Uint8List? bytes = await store.read(
      await _key(_outgoingFolder, peerAddress, messageId),
    );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return _readOutgoing(bytes);
  }

  @override
  Future<void> saveIncoming(IncomingAttachmentTransfer transfer) async {
    final BinaryWriter writer = BinaryWriter()
      ..writeUint8(_versionMarker)
      ..writeUint8(_currentVersion)
      ..writeString(transfer.peerAddress)
      ..writeString(transfer.messageId)
      ..writeString(transfer.text)
      ..writeInt64(transfer.sentAtMillis)
      ..writeUint8(transfer.type.index)
      ..writeNullableString(transfer.fileName)
      ..writeNullableString(transfer.mimeType)
      ..writeNullableUint32(transfer.attachmentSizeBytes)
      ..writeNullableInt64(transfer.durationMs)
      ..writeUint32(transfer.transferBytes)
      ..writeUint32(transfer.chunkCount)
      ..writeUint32(transfer.receivedChunks.length);
    final List<int> chunkIndexes = transfer.receivedChunks.keys.toList()
      ..sort();
    for (final int chunkIndex in chunkIndexes) {
      writer
        ..writeUint32(chunkIndex)
        ..writeBytes(transfer.receivedChunks[chunkIndex]!);
    }
    await store.write(
      await _key(_incomingFolder, transfer.peerAddress, transfer.messageId),
      writer.toBytes(),
    );
  }

  @override
  Future<void> saveOutgoing(OutgoingAttachmentTransfer transfer) async {
    final BinaryWriter writer = BinaryWriter()
      ..writeUint8(_versionMarker)
      ..writeUint8(_currentVersion)
      ..writeString(transfer.peerAddress)
      ..writeString(transfer.messageId)
      ..writeString(transfer.text)
      ..writeInt64(transfer.sentAtMillis)
      ..writeUint8(transfer.type.index)
      ..writeNullableBytes(transfer.attachmentBytes)
      ..writeNullableString(transfer.attachmentPath)
      ..writeNullableString(transfer.fileName)
      ..writeNullableString(transfer.mimeType)
      ..writeNullableUint32(transfer.attachmentSizeBytes)
      ..writeNullableInt64(transfer.durationMs)
      ..writeUint32(transfer.chunkSizeBytes)
      ..writeBool(transfer.placeholderSent)
      ..writeUint32(transfer.ackedChunkIndexes.length);
    final List<int> acked = transfer.ackedChunkIndexes.toSet().toList()..sort();
    for (final int chunkIndex in acked) {
      writer.writeUint32(chunkIndex);
    }
    await store.write(
      await _key(_outgoingFolder, transfer.peerAddress, transfer.messageId),
      writer.toBytes(),
    );
  }

  /// Only the current layout is read; anything else counts as missing.
  static bool _isCurrent(BinaryReader reader) =>
      reader.readUint8() == _versionMarker &&
      reader.readUint8() == _currentVersion;

  IncomingAttachmentTransfer? _readIncoming(Uint8List bytes) {
    final BinaryReader reader = BinaryReader(bytes);
    if (!_isCurrent(reader)) {
      return null;
    }
    final String peerAddress = reader.readString();
    final String messageId = reader.readString();
    final String text = reader.readString();
    final int sentAtMillis = reader.readInt64();
    final ChatMessageType type = enumAt(
      ChatMessageType.values,
      reader.readUint8(),
      ChatMessageType.file,
    );
    final String? fileName = reader.readNullableString();
    final String? mimeType = reader.readNullableString();
    final int? attachmentSizeBytes = reader.readNullableUint32();
    final int? durationMs = reader.readNullableInt64();
    final int transferBytes = reader.readUint32();
    final int chunkCount = reader.readUint32();
    final int storedChunkCount = reader.readUint32();
    final Map<int, Uint8List> receivedChunks = <int, Uint8List>{};
    for (int index = 0; index < storedChunkCount; index += 1) {
      receivedChunks[reader.readUint32()] = reader.readBytes();
    }
    return IncomingAttachmentTransfer(
      peerAddress: peerAddress,
      messageId: messageId,
      text: text,
      sentAtMillis: sentAtMillis,
      type: type,
      transferBytes: transferBytes,
      chunkCount: chunkCount,
      fileName: fileName,
      mimeType: mimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: durationMs,
      receivedChunks: receivedChunks,
    );
  }

  OutgoingAttachmentTransfer? _readOutgoing(Uint8List bytes) {
    final BinaryReader reader = BinaryReader(bytes);
    if (!_isCurrent(reader)) {
      return null;
    }
    final String peerAddress = reader.readString();
    final String messageId = reader.readString();
    final String text = reader.readString();
    final int sentAtMillis = reader.readInt64();
    final ChatMessageType type = enumAt(
      ChatMessageType.values,
      reader.readUint8(),
      ChatMessageType.file,
    );
    final Uint8List? attachmentBytes = reader.readNullableBytes();
    final String? attachmentPath = reader.readNullableString();
    final String? fileName = reader.readNullableString();
    final String? mimeType = reader.readNullableString();
    final int? attachmentSizeBytes = reader.readNullableUint32();
    final int? durationMs = reader.readNullableInt64();
    final int chunkSizeBytes = reader.readUint32();
    final bool placeholderSent = reader.readBool();
    final int ackCount = reader.readUint32();
    final List<int> ackedChunkIndexes = <int>[];
    for (int index = 0; index < ackCount; index += 1) {
      ackedChunkIndexes.add(reader.readUint32());
    }
    return OutgoingAttachmentTransfer(
      peerAddress: peerAddress,
      messageId: messageId,
      text: text,
      sentAtMillis: sentAtMillis,
      type: type,
      attachmentBytes: attachmentBytes,
      attachmentPath: attachmentPath,
      fileName: fileName,
      mimeType: mimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: durationMs,
      chunkSizeBytes: chunkSizeBytes,
      placeholderSent: placeholderSent,
      ackedChunkIndexes: ackedChunkIndexes,
    );
  }

  /// `transfers/<in|out>/<hash of the friend>/<hash of friend and message>`.
  Future<String> _key(
    String direction,
    String peerAddress,
    String messageId,
  ) async {
    final String peer = await store.nameSegmentFor(peerAddress);
    final String message = await store.nameSegmentFor(
      '$peerAddress|$messageId',
    );
    return '$storagePrefix/$direction/$peer/$message';
  }

  /// The store key of a listed transfer file.
  String _keyOfFile(File file) => file.path
      .substring(store.rootDirectory.path.length + 1)
      .replaceAll(Platform.pathSeparator, '/')
      .replaceFirst(RegExp(r'\.zenbin$'), '');
}

final class MemoryAttachmentTransferStore implements AttachmentTransferStore {
  final Map<String, OutgoingAttachmentTransfer> _outgoing =
      <String, OutgoingAttachmentTransfer>{};
  final Map<String, IncomingAttachmentTransfer> _incoming =
      <String, IncomingAttachmentTransfer>{};
  final Map<String, int> _incomingWrittenAt = <String, int>{};

  @override
  Future<void> deleteIncoming(String peerAddress, String messageId) async {
    final String key = AttachmentTransferStore.scopeKey(peerAddress, messageId);
    _incoming.remove(key);
    _incomingWrittenAt.remove(key);
  }

  @override
  Future<int> countIncoming(String peerAddress) async {
    final String prefix = AttachmentTransferStore.peerScopePrefix(peerAddress);
    return _incoming.keys.where((String key) => key.startsWith(prefix)).length;
  }

  @override
  Future<int> deleteStaleIncoming({required int olderThanMillis}) async {
    final List<String> stale = <String>[
      for (final String key in _incoming.keys)
        if ((_incomingWrittenAt[key] ?? 0) < olderThanMillis) key,
    ];
    for (final String key in stale) {
      _incoming.remove(key);
      _incomingWrittenAt.remove(key);
    }
    return stale.length;
  }

  @override
  Future<void> deleteOutgoing(String peerAddress, String messageId) async {
    _outgoing.remove(AttachmentTransferStore.scopeKey(peerAddress, messageId));
  }

  @override
  Future<List<OutgoingAttachmentTransfer>> loadAllOutgoing() async {
    final List<OutgoingAttachmentTransfer> transfers = _outgoing.values.toList()
      ..sort(
        (OutgoingAttachmentTransfer left, OutgoingAttachmentTransfer right) =>
            left.sentAtMillis.compareTo(right.sentAtMillis),
      );
    return List<OutgoingAttachmentTransfer>.unmodifiable(transfers);
  }

  @override
  Future<IncomingAttachmentTransfer?> loadIncoming(
    String peerAddress,
    String messageId,
  ) async {
    return _incoming[AttachmentTransferStore.scopeKey(peerAddress, messageId)];
  }

  @override
  Future<OutgoingAttachmentTransfer?> loadOutgoing(
    String peerAddress,
    String messageId,
  ) async {
    return _outgoing[AttachmentTransferStore.scopeKey(peerAddress, messageId)];
  }

  @override
  Future<void> saveIncoming(IncomingAttachmentTransfer transfer) async {
    _incoming[transfer.storageKey] = transfer;
    _incomingWrittenAt[transfer.storageKey] =
        DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<void> saveOutgoing(OutgoingAttachmentTransfer transfer) async {
    _outgoing[transfer.storageKey] = transfer;
  }
}
