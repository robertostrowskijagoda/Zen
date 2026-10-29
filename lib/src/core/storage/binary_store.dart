import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart'
    show SecretBoxAuthenticationError;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/core/storage/storage_health.dart';
import 'package:zstandard/zstandard.dart';

const int kZenBinaryCompressionLevel = 4;

abstract interface class BinaryPayloadProtector {
  Future<Uint8List> seal(Uint8List payload);

  Future<Uint8List> unseal(Uint8List payload);

  bool isSealed(Uint8List payload);
}

/// A [BinaryPayloadProtector] that also binds what it seals to the key it
/// is stored under ([storageKey], authenticated but not stored): a file
/// copied over another key's file no longer opens.
abstract interface class KeyedBinaryPayloadProtector
    implements BinaryPayloadProtector {
  Future<Uint8List> sealFor(String storageKey, Uint8List payload);

  Future<Uint8List> unsealFor(String storageKey, Uint8List payload);
}

/// A stored payload in a format this version does not open (plaintext, or
/// sealed without its storage key). [FileBinaryStore] reads such a file as
/// missing.
final class UnsupportedStoredPayloadException implements Exception {
  const UnsupportedStoredPayloadException(this.message);

  final String message;

  @override
  String toString() => 'UnsupportedStoredPayloadException: $message';
}

/// Gives the key that hides file names (derived from the data key), or
/// `null` while there is none (the app is locked).
abstract interface class BinaryStoreNameKeySource {
  Future<Uint8List?> fileNameKey();
}

/// Keys whose readable file name would tell who the user talks to (a
/// friend's address is part of the key). In a store whose protector is a
/// [BinaryStoreNameKeySource] their files are named by a keyed hash
/// (HMAC-SHA256 with a key derived from the data key) in
/// [kHiddenNamesFolder]. `transfers/` is not here: the attachment store
/// lists its folders
/// (resuming uploads, per-friend limits, the stale sweep), so it names its
/// keys with [FileBinaryStore.nameSegmentFor] instead.
const Set<String> kZenHiddenNamePrefixes = <String>{
  'threads/',
  'relay/mail/',
  'meet/list/',
  'ledger/',
};

/// A stored file bigger than this part of the size limit is reported to
/// [ZenStorageHealth] (and logged) while it can still be written.
const double kStorageWarnFraction = 0.5;

/// Past this part of the limit a payload is recompressed harder before it
/// is written (the file format is the same).
const double kStorageCompactFraction = 0.75;

/// Zstd level used when a payload is close to the limit.
const int kZenBinaryHeavyCompressionLevel = 12;

/// `*.tmp` files left by a write that was killed are removed once they are
/// older than this.
const Duration kOrphanTemporaryAge = Duration(hours: 1);

/// The folder of the files whose names are hidden.
const String kHiddenNamesFolder = 'hidden';

abstract interface class BinaryCompressor {
  Future<Uint8List?> compress(Uint8List payload, int level);

  Future<Uint8List?> decompress(Uint8List payload);
}

final class ZstdBinaryCompressor implements BinaryCompressor {
  ZstdBinaryCompressor({Zstandard? zstandard})
    : _zstandard = zstandard ?? Zstandard();

  final Zstandard _zstandard;

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) {
    return _zstandard.compress(payload, level);
  }

  @override
  Future<Uint8List?> decompress(Uint8List payload) {
    return _zstandard.decompress(payload);
  }
}

final class BinaryCodec {
  BinaryCodec({
    BinaryCompressor? compressor,
    this.maxPayloadBytes = defaultMaxPayloadBytes,
  }) : assert(maxPayloadBytes > 0),
       _compressor = compressor ?? ZstdBinaryCompressor();

  static const int currentVersion = 2;
  static const int defaultMaxPayloadBytes = 20 * 1024 * 1024;
  static const int maxEnvelopeOverheadBytes = 64 * 1024;
  static const int _headerLength = 48;
  static const int _checksumLength = 32;
  static const int _checksumOffset = 16;
  static const List<int> _magic = <int>[0x5A, 0x45, 0x4E, 0x31];

  final BinaryCompressor _compressor;
  final int maxPayloadBytes;

  int get maxEnvelopeBytes => maxPayloadBytes + maxEnvelopeOverheadBytes;

  Future<Uint8List> encode(
    Uint8List payload, {
    int level = kZenBinaryCompressionLevel,
  }) async {
    _validatePayloadLength(
      payload.length,
      message: 'Binary payload exceeds the configured limit.',
    );
    final Uint8List? compressed = await _compressor.compress(payload, level);
    final bool isCompressed =
        compressed != null &&
        compressed.isNotEmpty &&
        compressed.length < payload.length;
    final Uint8List body = isCompressed ? compressed : payload;
    if (body.length > maxEnvelopeBytes) {
      throw const FormatException(
        'Binary envelope exceeds the configured limit.',
      );
    }

    final ByteData header = ByteData(_headerLength)
      ..setUint8(0, _magic[0])
      ..setUint8(1, _magic[1])
      ..setUint8(2, _magic[2])
      ..setUint8(3, _magic[3])
      ..setUint8(4, currentVersion)
      ..setUint8(5, isCompressed ? 1 : 0)
      ..setUint8(6, level)
      ..setUint8(7, _headerLength)
      ..setUint32(8, payload.length, Endian.little)
      ..setUint32(12, body.length, Endian.little);

    final List<int> checksum = sha256.convert(payload).bytes;
    for (int index = 0; index < checksum.length; index += 1) {
      header.setUint8(_checksumOffset + index, checksum[index]);
    }

    final Uint8List envelope = Uint8List(_headerLength + body.length);
    envelope.setRange(0, _headerLength, header.buffer.asUint8List());
    envelope.setRange(_headerLength, envelope.length, body);
    return envelope;
  }

  /// The payload of [envelope]; a [NewerFormatException] for an envelope
  /// a newer build wrote, a [FormatException] for anything else but a
  /// well-formed envelope of [currentVersion].
  Future<Uint8List> decode(Uint8List envelope) async {
    if (envelope.length < _headerLength) {
      throw const FormatException('Binary envelope is too short.');
    }
    _validateMagic(envelope);
    final int version = envelope[4];
    if (version > currentVersion) {
      throw NewerFormatException(
        'binary envelope',
        found: version,
        supported: currentVersion,
      );
    }
    if (version != currentVersion) {
      throw FormatException('Unsupported binary envelope version: $version.');
    }
    final ByteData header = ByteData.sublistView(envelope, 0, _headerLength);
    final int headerLength = header.getUint8(7);
    if (headerLength != _headerLength) {
      throw const FormatException('Binary envelope header length mismatch.');
    }
    final int compressionFlag = header.getUint8(5);
    if (compressionFlag > 1) {
      throw const FormatException(
        'Binary envelope has an invalid compression flag.',
      );
    }
    final bool isCompressed = compressionFlag == 1;
    if (isCompressed && header.getUint8(6) == 0) {
      throw const FormatException(
        'Binary envelope is missing compression metadata.',
      );
    }
    final int originalLength = header.getUint32(8, Endian.little);
    final int storedLength = header.getUint32(12, Endian.little);
    _validatePayloadLength(
      originalLength,
      message: 'Binary envelope exceeds the configured limit.',
    );
    if (storedLength > maxEnvelopeBytes) {
      throw const FormatException(
        'Binary envelope exceeds the configured limit.',
      );
    }
    final Uint8List body = envelope.sublist(_headerLength);
    if (body.length != storedLength) {
      throw const FormatException('Binary envelope length mismatch.');
    }

    final Uint8List payload;
    if (!isCompressed) {
      if (body.length != originalLength) {
        throw const FormatException('Binary envelope payload mismatch.');
      }
      payload = body;
    } else {
      final Uint8List? decoded = await _compressor.decompress(body);
      if (decoded == null || decoded.length != originalLength) {
        throw const FormatException('Could not decompress binary envelope.');
      }
      payload = decoded;
    }

    final Uint8List expectedChecksum = Uint8List.sublistView(
      envelope,
      _checksumOffset,
      _checksumOffset + _checksumLength,
    );
    final List<int> actualChecksum = sha256.convert(payload).bytes;
    if (!_constantTimeEquals(expectedChecksum, actualChecksum)) {
      throw const FormatException('Binary envelope checksum mismatch.');
    }
    return payload;
  }

  void _validateMagic(Uint8List envelope) {
    for (int index = 0; index < _magic.length; index += 1) {
      if (envelope[index] != _magic[index]) {
        throw const FormatException('Binary envelope has an invalid header.');
      }
    }
  }

  void _validatePayloadLength(int length, {required String message}) {
    if (length < 0 || length > maxPayloadBytes) {
      throw FormatException(message);
    }
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) {
      return false;
    }
    int diff = 0;
    for (int index = 0; index < left.length; index += 1) {
      diff |= left[index] ^ right[index];
    }
    return diff == 0;
  }
}

/// Whether [error], thrown while reading a stored file, says the file is
/// damaged (cut short, overwritten, failing its check, past the size
/// limit): such a file will never read, so it is set aside rather than
/// tried at every start. A newer build's file is not damaged (it is held),
/// and neither is a locked store or a failing disk.
bool isDamagedStoredFile(Object error) =>
    error is FormatException && error is! NewerFormatException;

final class FileBinaryStore {
  FileBinaryStore(
    Directory rootDirectory, {
    BinaryCodec? codec,
    BinaryPayloadProtector? protector,
    int? maxFileBytes,
    Set<String> hiddenNamePrefixes = kZenHiddenNamePrefixes,
  }) : this._(
         rootDirectory,
         codec ?? BinaryCodec(),
         protector,
         maxFileBytes,
         hiddenNamePrefixes,
       );

  FileBinaryStore._(
    this.rootDirectory,
    BinaryCodec codec,
    BinaryPayloadProtector? protector,
    int? maxFileBytes,
    this._hiddenNamePrefixes,
  ) : _codec = codec,
      _protector = protector,
      _names = _nameKeySourceOf(protector),
      _maxFileBytes =
          maxFileBytes ?? codec.maxEnvelopeBytes + _sealedPayloadHeadroomBytes;

  static const int _sealedPayloadHeadroomBytes = 64 * 1024;
  static final RegExp _windowsDrivePrefix = RegExp(r'^[A-Za-z]:');
  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1F]');
  static final RegExp _plainSafeSegment = RegExp(r'^[A-Za-z0-9._-]+$');
  static const Set<String> _reservedWindowsNames = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  final Directory rootDirectory;
  final BinaryCodec _codec;
  final BinaryPayloadProtector? _protector;
  final BinaryStoreNameKeySource? _names;
  final Set<String> _hiddenNamePrefixes;
  final int _maxFileBytes;

  /// Files (by path) whose save is under way in this isolate, for every
  /// store: see [_locked].
  static final Map<String, Future<void>> _writeQueues =
      <String, Future<void>>{};

  /// Files (by path) a read found unreadable while an earlier generation
  /// still read: the next save sets them aside instead of keeping them as
  /// the backup ([_writeLocked]).
  static final Set<String> _unreadable = <String>{};

  /// Keys (canonical) whose file a newer build wrote: never written over or
  /// deleted while this build runs ([holdNewer]).
  final Set<String> _heldNewer = <String>{};

  static BinaryStoreNameKeySource? _nameKeySourceOf(Object? protector) =>
      protector is BinaryStoreNameKeySource ? protector : null;

  /// Keeps the file of [key] exactly as it is: a newer build wrote it in a
  /// format this one cannot read. Writes and deletes of [key] are skipped
  /// from now on (the app works with defaults for it), and
  /// [ZenFormatGuard] tells the user to update.
  void holdNewer(String key) {
    final String canonical = _canonicalKey(key);
    if (_heldNewer.add(canonical)) {
      ZenFormatGuard.instance.noteNewer(canonical);
    }
  }

  /// Whether [key] is held by [holdNewer].
  bool isHeldNewer(String key) => _heldNewer.contains(_canonicalKey(key));

  /// Whether the JSON document [json] read from [key] names (in `v`) a
  /// format above [current]; the key is then held ([holdNewer]) and the
  /// caller reads it as missing.
  bool heldAsNewer(String key, Object? json, {required int current}) {
    if (jsonFormatAge(json, current: current) != FormatAge.newer) {
      return false;
    }
    holdNewer(key);
    return true;
  }

  Future<File> write(String key, Uint8List payload) async {
    if (_heldNewer.contains(_canonicalKey(key))) {
      logZenWarning('Save skipped: a newer Zen wrote the file.');
      return _fileFor(key);
    }
    final _StorePlace place = await _placeOf(key);
    return _locked(place.file.path, () => _writeLocked(place, payload));
  }

  /// Writes of one file, one at a time: in this isolate through a queue
  /// shared by every store on the same folder (two stores, or a store and
  /// a ledger disk on it, must not interleave the steps of [_writeLocked]),
  /// and across isolates and processes (the Android app and its background
  /// service share one process; a second desktop window has its own)
  /// through a lock file next to it ([_FileWriteLock]).
  Future<T> _locked<T>(String path, Future<T> Function() action) async {
    while (_writeQueues.containsKey(path)) {
      try {
        await _writeQueues[path];
      } catch (_) {}
    }
    final Completer<void> completer = Completer<void>();
    _writeQueues[path] = completer.future;
    try {
      final _FileWriteLock lock = await _FileWriteLock.take(path);
      try {
        return await action();
      } finally {
        await lock.release();
      }
    } finally {
      _writeQueues.remove(path);
      completer.complete();
    }
  }

  /// The steps of a save, in order, for tests that stop a save at each of
  /// them as a killed process would ([debugWriteStep]).
  static const List<String> writeSteps = <String>[
    'temporary written',
    'temporary checked',
    'older backup kept',
    'backup kept',
    'in place',
  ];

  /// Called at each of [writeSteps] with the file being written there;
  /// a test throws from it to leave the files as a process killed at that
  /// moment would.
  @visibleForTesting
  static void Function(String step, File file)? debugWriteStep;

  /// Up to this size a file keeps two earlier generations (`.bak`,
  /// `.bak2`): the small ones are what the app cannot do without (keys,
  /// the identity, settings, indexes, the friend list). Bigger ones keep
  /// one.
  static const int kTwoBackupsUpTo = 256 * 1024;

  /// A save that never leaves the key without a complete copy:
  ///
  /// 1. the sealed bytes go to a file of their own, flushed to the disk
  ///    (`fsync`), and are read back and compared: a short or failed write
  ///    never replaces anything;
  /// 2. the copies before it move down a generation (`.bak` to `.bak2`, the
  ///    file to `.bak`) — except a file this store found unreadable, which
  ///    is set aside instead, so it never pushes the last good copy out;
  /// 3. the new file is moved into place (an atomic rename).
  ///
  /// Killed at any point, a read finds the new file or an earlier complete
  /// generation ([read] tries the file, then `.bak`, then `.bak2`).
  Future<File> _writeLocked(_StorePlace place, Uint8List payload) async {
    final File file = place.file;
    await file.parent.create(recursive: true);
    if (payload.length > _codec.maxPayloadBytes) {
      _reportSize(place.canonicalKey, payload.length, _codec.maxPayloadBytes);
    }
    Uint8List encoded = await _codec.encode(payload);
    if (encoded.length > _maxFileBytes * kStorageCompactFraction) {
      // Close to the limit: squeeze harder before giving up space.
      final Uint8List tighter = await _codec.encode(
        payload,
        level: kZenBinaryHeavyCompressionLevel,
      );
      if (tighter.length < encoded.length) {
        encoded = tighter;
      }
    }
    final Uint8List sealed = await _seal(place.canonicalKey, encoded);
    _reportSize(place.canonicalKey, sealed.length, _maxFileBytes);
    if (sealed.length > _maxFileBytes) {
      throw const FormatException(
        'Stored binary payload exceeds the configured limit.',
      );
    }
    final File temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp',
    );
    try {
      await temporary.writeAsBytes(sealed, flush: true);
      debugWriteStep?.call(writeSteps[0], temporary);
      if (!_sameBytes(await temporary.readAsBytes(), sealed)) {
        throw FileSystemException(
          'The saved file does not read back as written.',
          temporary.path,
        );
      }
      debugWriteStep?.call(writeSteps[1], temporary);
    } on Object {
      await _deleteQuietly(temporary);
      rethrow;
    }
    final File backup = File('${file.path}.bak');
    final File older = File('${file.path}.bak2');
    final String path = file.path;
    if (_unreadable.remove(path)) {
      // Found unreadable here: it must not become the backup (that would
      // push the last good copy out). Kept aside for a look by hand.
      await _setAsideQuietly(file);
    } else if (await file.exists()) {
      if (sealed.length <= kTwoBackupsUpTo && await backup.exists()) {
        await _replace(backup, older);
        debugWriteStep?.call(writeSteps[2], older);
      }
      await _replace(file, backup);
      debugWriteStep?.call(writeSteps[3], backup);
    }
    await _replace(temporary, file, fallbackBytes: sealed);
    debugWriteStep?.call(writeSteps[4], file);
    return file;
  }

  /// Moves [from] over [to] (an atomic rename, replacing it), retrying a
  /// moment when the system holds a file (Windows, a reader or a virus
  /// scanner). Should the rename keep failing, [fallbackBytes] are written
  /// to [to] instead (flushed); without them [from] is copied.
  static Future<void> _replace(
    File from,
    File to, {
    Uint8List? fallbackBytes,
  }) async {
    Object? failure;
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await from.rename(to.path);
        return;
      } on FileSystemException catch (error) {
        failure = error;
        if (attempt < 4) {
          await Future<void>.delayed(
            Duration(milliseconds: 25 * (attempt + 1)),
          );
        }
      }
    }
    logZenWarning('Moving a saved file into place failed: $failure');
    if (fallbackBytes != null) {
      await to.writeAsBytes(fallbackBytes, flush: true);
    } else {
      await from.copy(to.path);
    }
    await _deleteQuietly(from);
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Swept with the leftovers later.
    }
  }

  static Future<void> _setAsideQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.rename(
          '${file.path}.damaged-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    } on FileSystemException catch (error) {
      logZenWarning('Setting a damaged file aside failed: $error');
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void _reportSize(String canonicalKey, int bytes, int limit) {
    final StorageFill before = ZenStorageHealth.instance.fillOf(canonicalKey);
    final StorageFill after = ZenStorageHealth.instance.record(
      canonicalKey,
      bytes: bytes,
      limit: limit,
      warnFraction: kStorageWarnFraction,
    );
    if (after.index > before.index && after != StorageFill.ok) {
      // Only the first part of the key: the rest may be a friend's address.
      final String area = ZenStorageHealth.categoryOf(canonicalKey);
      logZenWarning(
        after == StorageFill.full
            ? 'Magazyn "$area" przekroczył limit pliku '
                  '($bytes z $limit B); zapis się nie uda.'
            : 'Magazyn "$area" zajmuje ${bytes * 100 ~/ limit}% limitu '
                  'pliku ($bytes z $limit B).',
      );
    }
  }

  /// Removes `*.tmp` files under the store older than [olderThan]: what a
  /// write killed between creating and moving its file leaves behind.
  /// Returns how many were removed.
  ///
  /// The walk over every file runs at most once per [every] (a marker file
  /// in the store remembers when): starts stay quick with many files.
  Future<int> sweepOrphanTemporaries({
    Duration olderThan = kOrphanTemporaryAge,
    Duration every = Duration.zero,
  }) async {
    if (!await rootDirectory.exists()) {
      return 0;
    }
    if (every > Duration.zero) {
      final File marker = File(
        '${rootDirectory.path}${Platform.pathSeparator}.swept',
      );
      try {
        if (await marker.exists() &&
            DateTime.now().difference(await marker.lastModified()) < every) {
          return 0;
        }
        await marker.writeAsString('', flush: true);
      } on FileSystemException {
        // Sweep anyway.
      }
    }
    final DateTime cutoff = DateTime.now().subtract(olderThan);
    int removed = 0;
    try {
      await for (final FileSystemEntity entity in rootDirectory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.tmp')) {
          continue;
        }
        try {
          if ((await entity.lastModified()).isBefore(cutoff)) {
            await entity.delete();
            removed += 1;
          }
        } on FileSystemException {
          // In use or already gone.
        }
      }
    } on FileSystemException {
      // The folder changed while it was walked.
    }
    return removed;
  }

  /// The payload of [key]: from its file, or — when that is missing or
  /// cannot be read (a save killed halfway on a system without atomic
  /// renames, a bad sector) — from the newest earlier generation that
  /// reads (`.bak`, then `.bak2`). Null when nothing was ever saved.
  /// Throws the file's error when no copy reads: a caller must never take
  /// that for "nothing stored" and save emptiness over it.
  Future<Uint8List?> read(String key) async {
    final _StorePlace place = await _placeOf(key);
    final File file = place.file;
    Object? failure;
    StackTrace? failureStack;
    try {
      final Uint8List? primary = await _readFile(file, place.canonicalKey);
      if (primary != null) {
        return primary;
      }
    } on NewerFormatException {
      // Not damaged: written by a newer build. Kept as it is (an older
      // backup would be saved over it).
      holdNewer(key);
      rethrow;
    } on StateError {
      // Locked: no copy opens now, and none is damaged.
      rethrow;
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    for (final String suffix in const <String>['.bak', '.bak2']) {
      final File earlier = File('${file.path}$suffix');
      if (!await earlier.exists()) {
        continue;
      }
      try {
        final Uint8List? payload = await _readFile(earlier, place.canonicalKey);
        if (payload == null) {
          continue;
        }
        if (failure != null) {
          _unreadable.add(file.path);
          logZenWarning(
            'Plik "${ZenStorageHealth.categoryOf(place.canonicalKey)}" był '
            'nieczytelny; odczytany z wcześniejszej kopii ($suffix).',
          );
        }
        return payload;
      } on NewerFormatException {
        rethrow;
      } on StateError {
        rethrow;
      } catch (error, stackTrace) {
        failure ??= error;
        failureStack ??= stackTrace;
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    return null;
  }

  Future<Uint8List?> _readFile(File file, String storageKey) async {
    if (!await file.exists()) {
      return null;
    }
    final int fileLength = await file.length();
    if (fileLength > _maxFileBytes) {
      throw const FormatException(
        'Stored binary payload exceeds the configured limit.',
      );
    }
    final Uint8List bytesOnDisk = Uint8List.fromList(await file.readAsBytes());
    final Uint8List encoded;
    try {
      encoded = await _unseal(storageKey, bytesOnDisk);
    } on UnsupportedStoredPayloadException {
      // Plaintext or another seal: never trusted, read as missing.
      return null;
    } on SecretBoxAuthenticationError {
      // Cut short, a byte changed: damage like any other, reported the
      // same way ([isDamagedStoredFile]).
      throw const FormatException('Stored payload fails its check.');
    }
    return _codec.decode(encoded);
  }

  /// [key]'s payload, or null when there is none, when a newer build wrote
  /// it (held, see [holdNewer]) or when neither the file nor its backup can
  /// be read: the file is then set aside ([quarantine]) and the caller
  /// starts it afresh, instead of failing on it at every start. What is not
  /// damage (the store locked, the disk failing) still throws.
  Future<Uint8List?> readOrSetAside(String key) async {
    try {
      return await read(key);
    } on NewerFormatException {
      return null;
    } on FormatException catch (error) {
      logZenWarning(
        'Stored file "${ZenStorageHealth.categoryOf(_canonicalKey(key))}" '
        'is damaged: ${error.message}',
      );
      await quarantine(key);
      return null;
    }
  }

  Future<Uint8List> _seal(String storageKey, Uint8List encoded) async {
    final BinaryPayloadProtector? protector = _protector;
    if (protector == null) {
      return encoded;
    }
    if (protector is KeyedBinaryPayloadProtector) {
      return protector.sealFor(storageKey, encoded);
    }
    return protector.seal(encoded);
  }

  Future<Uint8List> _unseal(String storageKey, Uint8List bytes) async {
    final BinaryPayloadProtector? protector = _protector;
    if (protector == null) {
      return bytes;
    }
    if (protector is KeyedBinaryPayloadProtector) {
      return protector.unsealFor(storageKey, bytes);
    }
    return protector.unseal(bytes);
  }

  /// Whether anything is kept for [key] (its file or an earlier
  /// generation), without opening it.
  Future<bool> exists(String key) async {
    final File file = (await _placeOf(key)).file;
    for (final String suffix in const <String>['', '.bak', '.bak2']) {
      if (await File('${file.path}$suffix').exists()) {
        return true;
      }
    }
    return false;
  }

  /// Sets the file of [key] and its backup aside (renamed with
  /// `.damaged-<time>` after their names, never read again but kept for a
  /// look by hand) when neither can be read: the next read finds nothing
  /// and the next write starts afresh. For a store the app cannot start
  /// without, where an unreadable file must not ask for a wipe of the
  /// whole app. Returns how many files were set aside.
  Future<int> quarantine(String key) async {
    final _StorePlace place = await _placeOf(key);
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    int moved = 0;
    _unreadable.remove(place.file.path);
    for (final File file in <File>[
      place.file,
      File('${place.file.path}.bak'),
      File('${place.file.path}.bak2'),
    ]) {
      try {
        if (await file.exists()) {
          await file.rename('${file.path}.damaged-$stamp');
          moved += 1;
        }
      } on FileSystemException catch (error) {
        logZenWarning('Setting a damaged file aside failed: $error');
      }
    }
    if (moved > 0) {
      logZenWarning(
        'Plik "${ZenStorageHealth.categoryOf(place.canonicalKey)}" był '
        'nieczytelny; odłożony na bok, Zen zaczyna go od nowa.',
      );
    }
    return moved;
  }

  Future<void> delete(String key) async {
    if (_heldNewer.contains(_canonicalKey(key))) {
      return;
    }
    final _StorePlace place = await _placeOf(key);
    await _locked(place.file.path, () => _deleteWithExtras(place.file));
  }

  Future<void> _deleteWithExtras(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
    _unreadable.remove(file.path);
    for (final String suffix in const <String>['.bak', '.bak2', '.tmp']) {
      final File extra = File('${file.path}$suffix');
      if (await extra.exists()) {
        await extra.delete();
      }
    }
  }

  // ---- Hidden file names -------------------------------------------------

  /// [value] as one key segment that does not show it: a keyed hash (with
  /// the same name key as [kZenHiddenNamePrefixes]) when this store hides
  /// names, otherwise its base64url form. For keys found by listing their
  /// folder, which a hidden name would break. Throws while the store is
  /// locked.
  Future<String> nameSegmentFor(String value) async {
    final BinaryStoreNameKeySource? names = _names;
    if (names == null) {
      return base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    }
    final Uint8List? nameKey = await names.fileNameKey();
    if (nameKey == null) {
      throw StateError(
        'Encrypted storage is locked: its file names are hidden as well.',
      );
    }
    return Hmac(
      sha256,
      nameKey,
    ).convert(utf8.encode('segment|$value')).toString().substring(0, 32);
  }

  /// [key] as callers mean it (`/`-separated, no empty or padded parts),
  /// folded to lower case on Windows like its file path. What a sealed
  /// payload is bound to, and what a hidden name is computed from.
  static String _canonicalKey(String key) {
    final String logical = key
        .trim()
        .replaceAll('\\', '/')
        .split('/')
        .map((String segment) => segment.trim())
        .where((String segment) => segment.isNotEmpty)
        .join('/');
    return Platform.isWindows ? logical.toLowerCase() : logical;
  }

  String? _hiddenPrefixOf(String canonicalKey) {
    if (_names == null) {
      return null;
    }
    for (final String prefix in _hiddenNamePrefixes) {
      final String folded = Platform.isWindows ? prefix.toLowerCase() : prefix;
      if (canonicalKey.length > folded.length &&
          canonicalKey.startsWith(folded)) {
        return folded;
      }
    }
    return null;
  }

  /// Where [key] is stored: its readable path, or for a hidden key its
  /// hashed name.
  Future<_StorePlace> _placeOf(String key) async {
    // Validates the key (traversal, control characters) in every case.
    final File readable = _fileFor(key);
    final String canonical = _canonicalKey(key);
    final String? prefix = _hiddenPrefixOf(canonical);
    final BinaryStoreNameKeySource? names = _names;
    if (prefix == null || names == null) {
      return _StorePlace(canonicalKey: canonical, file: readable);
    }
    final Uint8List? nameKey = await names.fileNameKey();
    if (nameKey == null) {
      throw StateError(
        'Encrypted storage is locked: its file names are hidden as well.',
      );
    }
    final String name = Hmac(
      sha256,
      nameKey,
    ).convert(utf8.encode(canonical)).toString().substring(0, 40);
    final String separator = Platform.pathSeparator;
    final String rootPath = _normalizedFileSystemPath(
      rootDirectory.absolute.path,
    );
    // In one of 256 subfolders (by the name's first two hex digits): tens
    // of thousands of files in one folder slow every listing down.
    final File hidden = File(
      _normalizedFileSystemPath(
        '$rootPath$separator$kHiddenNamesFolder$separator'
        '${name.substring(0, 2)}$separator$name.zenbin',
      ),
    );
    return _StorePlace(canonicalKey: canonical, file: hidden);
  }

  File _fileFor(String key) {
    final List<String> segments = _sanitizeKeySegments(key);
    final String rootPath = _normalizedFileSystemPath(
      rootDirectory.absolute.path,
    );
    final String relativePath = segments.join(Platform.pathSeparator);
    final String candidatePath = _normalizedFileSystemPath(
      '$rootPath${Platform.pathSeparator}$relativePath.zenbin',
    );
    final String allowedPrefix = '$rootPath${Platform.pathSeparator}';
    if (!candidatePath.startsWith(allowedPrefix)) {
      throw const FormatException(
        'Binary store key resolves outside of the base directory.',
      );
    }
    return File(candidatePath);
  }

  List<String> _sanitizeKeySegments(String key) {
    final String normalized = key.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) {
      throw const FormatException('Binary store key cannot be empty.');
    }
    if (normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        normalized.startsWith('~/') ||
        normalized.startsWith('~\\') ||
        _windowsDrivePrefix.hasMatch(normalized)) {
      throw const FormatException('Binary store keys must stay relative.');
    }
    if (_controlCharacters.hasMatch(normalized)) {
      throw const FormatException(
        'Binary store key contains unsupported control characters.',
      );
    }
    if (normalized.contains('..')) {
      throw const FormatException(
        'Binary store key contains path traversal syntax.',
      );
    }
    final List<String> rawSegments = normalized
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (rawSegments.isEmpty) {
      throw const FormatException('Binary store key cannot be empty.');
    }
    return rawSegments.map(_sanitizeKeySegment).toList(growable: false);
  }

  String _sanitizeKeySegment(String segment) {
    final String trimmed = segment.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      throw const FormatException(
        'Binary store key contains an unsafe segment.',
      );
    }
    if (_controlCharacters.hasMatch(trimmed)) {
      throw const FormatException(
        'Binary store key contains unsupported control characters.',
      );
    }
    if (_isPlainSafeSegment(trimmed)) {
      return trimmed;
    }
    // Percent-encode logical segments so peer addresses and message ids remain
    // stable without letting path syntax leak into the filesystem layout.
    return Uri.encodeComponent(trimmed);
  }

  bool _isPlainSafeSegment(String segment) {
    if (!_plainSafeSegment.hasMatch(segment)) {
      return false;
    }
    if (segment.endsWith('.') || segment.endsWith(' ')) {
      return false;
    }
    if (Platform.isWindows &&
        _reservedWindowsNames.contains(segment.toUpperCase())) {
      return false;
    }
    return true;
  }

  String _normalizedFileSystemPath(String path) {
    final String separator = Platform.pathSeparator;
    final String normalized = path
        .replaceAll('/', separator)
        .replaceAll('\\', separator);
    final String absolute = File(
      normalized,
    ).absolute.path.replaceAll('/', separator).replaceAll('\\', separator);
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }
}

/// Where one key lives on disk.
final class _StorePlace {
  const _StorePlace({required this.canonicalKey, required this.file});

  /// The key (see `FileBinaryStore._canonicalKey`): what writes of one key
  /// wait on, and what its sealed payload is bound to.
  final String canonicalKey;

  /// The file the key is written to and read from.
  final File file;
}

/// The lock of one file's saves across isolates and processes: a
/// `<file>.lock` created exclusively (which the system does atomically for
/// every process), holding its owner ([_owner]: the process id and this
/// isolate's own token), removed when the save is done. A lock nobody
/// holds any more is taken over at once: one of another process (on a
/// phone the app and its service share one, so it is from before a
/// restart), one of this very isolate (each of its saves waits its turn in
/// `FileBinaryStore._writeQueues` before it takes the lock, so none of
/// them holds it: a release that failed — Windows refuses to delete a file
/// another program has open — or a folder put back from a copy), and one
/// still empty a while after it was made (its owner died before it wrote
/// its name). Another isolate's lock is waited for, up to [waitAtMost], or
/// taken over once older than [staleAfter].
final class _FileWriteLock {
  _FileWriteLock._(this._file);

  final File _file;

  /// Longer than any save takes; a lock older than this was left behind.
  static const Duration staleAfter = Duration(seconds: 30);

  /// Longer than an owner takes to write its name into the lock it made.
  static const Duration unnamedAfter = Duration(seconds: 2);

  /// The longest a save waits for another one before it goes ahead
  /// anyway (still atomic: it only risks the backups' order).
  static const Duration waitAtMost = Duration(seconds: 10);

  /// Who holds a lock this isolate took: the process and a token of this
  /// isolate (statics are one per isolate), so two isolates of one process
  /// tell their locks apart.
  static final String _owner =
      '$pid ${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${Random.secure().nextInt(1 << 32).toRadixString(36)}';

  static Future<_FileWriteLock> take(String path) async {
    final File file = File('$path.lock');
    final Stopwatch waited = Stopwatch()..start();
    int pause = 2;
    while (true) {
      try {
        await file.create(exclusive: true);
        try {
          await file.writeAsString(_owner, flush: false);
        } on FileSystemException {
          // The lock holds by existing; the name only helps after a crash.
        }
        return _FileWriteLock._(file);
      } on FileSystemException {
        if (!await file.parent.exists()) {
          await file.parent.create(recursive: true);
          continue;
        }
        if (await _isStale(file) || waited.elapsed > waitAtMost) {
          try {
            await file.delete();
          } on FileSystemException {
            // Someone else took it over first.
          }
          continue;
        }
        await Future<void>.delayed(Duration(milliseconds: pause));
        pause = pause >= 50 ? 50 : pause * 2;
      }
    }
  }

  static Future<bool> _isStale(File file) async {
    try {
      final String owner = (await file.readAsString()).trim();
      if (owner == _owner) {
        return true;
      }
      final Duration age = DateTime.now().difference(await file.lastModified());
      if (owner.isEmpty) {
        return age > unnamedAfter;
      }
      if (owner.split(' ').first != '$pid') {
        return true;
      }
      return age > staleAfter;
    } on FileSystemException {
      return false;
    } on FormatException {
      return true;
    }
  }

  Future<void> release() async {
    try {
      await _file.delete();
    } on FileSystemException {
      // Taken over as stale meanwhile; nothing to give back.
    }
  }
}
