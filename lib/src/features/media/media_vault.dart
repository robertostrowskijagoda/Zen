import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/media_temp_folder.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart'
    show SupportDirectoryResolver, supportDirectoryResolverProvider;

export 'package:zen/src/features/media/media_temp_folder.dart'
    show
        kMediaTemporaryFolder,
        mediaTemporaryDirectory,
        mediaTemporaryFolderName,
        newTemporaryMediaPath,
        wipeMediaTemporaryFiles;

/// Extension of an encrypted media file.
const String kMediaVaultExtension = '.zmedia';

/// Folder of the encrypted media files, in the app's support folder.
const String kMediaVaultFolder = 'vault';

/// Plain bytes in one encrypted segment.
const int kMediaVaultSegmentBytes = 64 * 1024;

/// Magic (6), version (1), reserved (1), segment size (4), plain length
/// (8: a recording of a long call can pass 4 GiB).
const int _headerBytes = 20;

/// Nonce (12) and tag (16) of one AES-GCM segment.
const int _sealOverheadBytes = 28;

/// `ZENMED`.
const List<int> _magic = <int>[0x5A, 0x45, 0x4E, 0x4D, 0x45, 0x44];
const int _formatVersion = 1;

/// Bigger payloads are encrypted and decrypted in a separate isolate
/// (AES-GCM runs in pure Dart here).
const int _isolateThresholdBytes = 256 * 1024;

final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _extensionPattern = RegExp(r'^\.[A-Za-z0-9]{1,8}$');

/// Whether [path] names an encrypted media file (by its extension).
bool isMediaVaultPath(String? path) =>
    path != null && path.toLowerCase().endsWith(kMediaVaultExtension);

/// Encrypted files for media: attachments, voice messages and friends'
/// photos.
///
/// A file is AES-256-GCM in [kMediaVaultSegmentBytes] segments under a key
/// derived from the master data key, so a part of it (one chunk of an
/// attachment being sent) opens without decrypting all of it. Every
/// segment is bound to the file's random name, its place and the file's
/// length: a renamed, cut or spliced file does not open. Names are random,
/// so the folder tells nothing about who sent what.
///
/// A path that is not a vault file (a file the user picked to send) is
/// read as it is.
final class MediaVault {
  MediaVault({
    required Future<Uint8List?> Function() masterKey,
    required Future<Directory> Function() supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _masterKey = masterKey,
       _supportDirectory = supportDirectory,
       _temporaryDirectory = temporaryDirectory ?? mediaTemporaryDirectory;

  /// The vault of this isolate (set by [mediaVaultProvider]), for code
  /// without a provider container: image providers and players.
  static MediaVault? current;

  final Future<Uint8List?> Function() _masterKey;
  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function() _temporaryDirectory;

  Future<Uint8List> _key() async {
    final Uint8List? master = await _masterKey();
    if (master == null) {
      throw StateError('Encrypted media is locked: no data key.');
    }
    return securitySubkey(master, 'media.vault');
  }

  Future<Directory> _folder() async {
    final Directory support = await _supportDirectory();
    final Directory folder = Directory(
      '${support.path}${Platform.pathSeparator}$kMediaVaultFolder',
    );
    await folder.create(recursive: true);
    return folder;
  }

  /// Encrypts [bytes] into a new file; returns its path.
  Future<String> put(Uint8List bytes) async {
    final Uint8List key = await _key();
    final Directory folder = await _folder();
    final String id = _newId();
    final String path =
        '${folder.path}${Platform.pathSeparator}$id$kMediaVaultExtension';
    await _sealToFileIn(
      key,
      id,
      bytes,
      path,
      background: bytes.length > _isolateThresholdBytes,
    );
    return path;
  }

  /// Encrypts the plain file [source] into a new file, segment by segment
  /// (memory stays at one segment whatever the size), and by default
  /// deletes [source] once the new file is complete; returns the new path.
  /// On failure nothing new is left behind and [source] stays.
  Future<String> putFile(File source, {bool deleteSource = true}) async {
    final Uint8List key = await _key();
    final Directory folder = await _folder();
    final String id = _newId();
    final String path =
        '${folder.path}${Platform.pathSeparator}$id$kMediaVaultExtension';
    await _sealFileToFileIn(
      key,
      id,
      source.path,
      path,
      background: await source.length() > _isolateThresholdBytes,
    );
    if (deleteSource) {
      await _deleteQuietly(source);
    }
    return path;
  }

  /// The name of the vault file at [path]: what an index keeps instead of
  /// the whole path, which changes when the app's folder moves.
  static String fileNameOf(String path) {
    final String id = _idOf(path);
    return '$id$kMediaVaultExtension';
  }

  /// The path of the vault file [name] (see [fileNameOf]) in this vault.
  Future<String> pathOf(String name) async {
    final String id = _idOf(name);
    final Directory folder = await _folder();
    return '${folder.path}${Platform.pathSeparator}$id$kMediaVaultExtension';
  }

  /// Encrypts [length] plain bytes arriving as [plain] (pieces of any
  /// size) into a new file, segment by segment, so memory stays at one
  /// segment whatever the size; returns its path. Throws (and leaves
  /// nothing behind) when [plain] brings more or fewer bytes.
  Future<String> putStream(int length, Stream<List<int>> plain) async {
    _checkLength(length);
    final Uint8List key = await _key();
    final Directory folder = await _folder();
    final String id = _newId();
    final String path =
        '${folder.path}${Platform.pathSeparator}$id$kMediaVaultExtension';
    final File temporary = File('$path.tmp');
    final IOSink out = temporary.openWrite();
    final int count = _segmentCount(length);
    int index = 0;
    Future<void> seal(Uint8List bytes) async {
      out.add(
        await encryptSecurityBytes(
          bytes,
          key,
          aad: _segmentAad(id, index, count, length),
        ),
      );
      index++;
    }

    try {
      out.add(_headerFor(length));
      final BytesBuilder segment = BytesBuilder(copy: false);
      int seen = 0;
      await for (final List<int> part in plain) {
        seen += part.length;
        if (seen > length) {
          throw const FormatException('More bytes than announced.');
        }
        int at = 0;
        while (at < part.length) {
          final int k = min(
            kMediaVaultSegmentBytes - segment.length,
            part.length - at,
          );
          segment.add(part.sublist(at, at + k));
          at += k;
          if (segment.length == kMediaVaultSegmentBytes) {
            await seal(segment.takeBytes());
          }
        }
      }
      if (seen != length) {
        throw const FormatException('Fewer bytes than announced.');
      }
      if (segment.length > 0 || index == 0) {
        await seal(segment.takeBytes());
      }
      await out.flush();
      await out.close();
      await temporary.rename(path);
      return path;
    } on Object {
      try {
        await out.close();
      } on Object {
        // Already closed.
      }
      await _deleteQuietly(temporary);
      rethrow;
    }
  }

  /// The plain bytes of the file at [path].
  Future<Uint8List> read(String path) async {
    if (!isMediaVaultPath(path)) {
      return File(path).readAsBytes();
    }
    final String id = _idOf(path);
    final Uint8List key = await _key();
    final int size = await File(path).length();
    return _openFileIn(
      key,
      id,
      path,
      background: size > _isolateThresholdBytes,
    );
  }

  /// How many plain bytes the file at [path] holds.
  Future<int> length(String path) async {
    if (!isMediaVaultPath(path)) {
      return File(path).length();
    }
    _idOf(path);
    final RandomAccessFile handle = await File(path).open();
    try {
      final Uint8List header = await handle.read(_headerBytes);
      return _readHeader(header, await handle.length()).length;
    } finally {
      await handle.close();
    }
  }

  /// Plain bytes [start] (inclusive) to [end] (exclusive) of the file at
  /// [path]; only the segments that hold them are decrypted.
  Future<Uint8List> readRange(String path, int start, int end) async {
    if (start < 0 || end < start) {
      throw RangeError('Invalid range $start-$end.');
    }
    if (!isMediaVaultPath(path)) {
      final RandomAccessFile handle = await File(path).open();
      try {
        if (end > await handle.length()) {
          throw RangeError('Range $start-$end is past the end of the file.');
        }
        await handle.setPosition(start);
        return await handle.read(end - start);
      } finally {
        await handle.close();
      }
    }
    final String id = _idOf(path);
    final Uint8List key = await _key();
    final RandomAccessFile handle = await File(path).open();
    try {
      final ({int length, int count}) header = _readHeader(
        await handle.read(_headerBytes),
        await handle.length(),
      );
      if (end > header.length) {
        throw RangeError('Range $start-$end is past the end of the file.');
      }
      if (start == end) {
        return Uint8List(0);
      }
      final BytesBuilder out = BytesBuilder(copy: false);
      final int first = start ~/ kMediaVaultSegmentBytes;
      final int last = (end - 1) ~/ kMediaVaultSegmentBytes;
      for (int index = first; index <= last; index++) {
        final int plainStart = index * kMediaVaultSegmentBytes;
        final int plainLength = min(
          kMediaVaultSegmentBytes,
          header.length - plainStart,
        );
        await handle.setPosition(
          _headerBytes + index * (kMediaVaultSegmentBytes + _sealOverheadBytes),
        );
        final Uint8List sealed = await handle.read(
          plainLength + _sealOverheadBytes,
        );
        final Uint8List plain = await decryptSecurityBytes(
          sealed,
          key,
          aad: _segmentAad(id, index, header.count, header.length),
        );
        if (plain.length != plainLength) {
          throw const FormatException('Encrypted media segment is damaged.');
        }
        final int from = max(start, plainStart) - plainStart;
        final int to = min(end, plainStart + plainLength) - plainStart;
        out.add(Uint8List.sublistView(plain, from, to));
      }
      return out.takeBytes();
    } finally {
      await handle.close();
    }
  }

  /// A plain copy of the vault file at [path] for a player that needs a
  /// path, in the temporary media folder under a random name with
  /// [extension]. The caller deletes it after use; whatever is left is
  /// removed at the next start.
  Future<File> openTemporary(String path, {String extension = ''}) async {
    if (!isMediaVaultPath(path)) {
      throw ArgumentError.value(path, 'path', 'Not an encrypted media file.');
    }
    final String id = _idOf(path);
    final Uint8List key = await _key();
    final int size = await File(path).length();
    final Directory folder = await _temporaryDirectory();
    final File target = await createPrivateTemporaryFile(
      '${folder.path}${Platform.pathSeparator}'
      '${_newId()}${_cleanExtension(extension)}',
    );
    try {
      await _openToFileIn(
        key,
        id,
        path,
        target.path,
        background: size > _isolateThresholdBytes,
      );
    } on Object {
      await _deleteQuietly(target);
      rethrow;
    }
    return target;
  }

  /// Decrypts the vault file at [path] into the plain file [target] (made
  /// or emptied), segment by segment: memory stays at one segment whatever
  /// the size. On failure the half-written [target] is deleted.
  Future<void> decryptToFile(String path, File target) async {
    if (!isMediaVaultPath(path)) {
      throw ArgumentError.value(path, 'path', 'Not an encrypted media file.');
    }
    final String id = _idOf(path);
    final Uint8List key = await _key();
    final int size = await File(path).length();
    try {
      await _openToFileIn(
        key,
        id,
        path,
        target.path,
        background: size > _isolateThresholdBytes,
      );
    } on Object {
      await _deleteQuietly(target);
      rethrow;
    }
  }

  /// Deletes the vault file at [path]. Anything else (a file the user
  /// picked) is left alone.
  Future<void> delete(String path) async {
    if (!isMediaVaultPath(path)) {
      return;
    }
    await _deleteQuietly(File(path));
    await _deleteQuietly(File('$path.tmp'));
  }
}

/// The vault of this isolate's container: opens with the master data key
/// of [appSecurityServiceProvider], keeps its files in the support folder.
final Provider<MediaVault> mediaVaultProvider = Provider<MediaVault>((Ref ref) {
  final AppSecurityService security = ref.watch(appSecurityServiceProvider);
  final SupportDirectoryResolver supportDirectory = ref.watch(
    supportDirectoryResolverProvider,
  );
  final MediaVault vault = MediaVault(
    masterKey: security.currentEncryptionKey,
    supportDirectory: supportDirectory,
  );
  MediaVault.current = vault;
  ref.onDispose(() {
    if (identical(MediaVault.current, vault)) {
      MediaVault.current = null;
    }
  });
  return vault;
});

/// The plain bytes of the media file at [path], through [MediaVault.current]
/// for a vault file.
Future<Uint8List> readMediaFile(String path) {
  final MediaVault? vault = MediaVault.current;
  if (vault != null) {
    return vault.read(path);
  }
  if (isMediaVaultPath(path)) {
    return Future<Uint8List>.error(
      StateError('Encrypted media is not available here.'),
    );
  }
  return File(path).readAsBytes();
}

/// The image at [path]: a vault file decrypted in memory, or a plain file.
ImageProvider<Object> mediaFileImage(String path) =>
    isMediaVaultPath(path) ? VaultFileImage(path) : FileImage(File(path));

/// [bytes] as a plain file in the temporary media folder (random name,
/// [extension]), for a player that needs a path. Delete it after use.
Future<File> writeTemporaryMedia(
  Uint8List bytes, {
  String extension = '',
}) async {
  final Directory folder = await mediaTemporaryDirectory();
  final File file = await createPrivateTemporaryFile(
    '${folder.path}${Platform.pathSeparator}'
    '${_newId()}${_cleanExtension(extension)}',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// An image kept in the [MediaVault]: decrypted in memory, never written
/// out in plain form.
@immutable
final class VaultFileImage extends ImageProvider<VaultFileImage> {
  const VaultFileImage(this.path, {this.scale = 1.0});

  final String path;
  final double scale;

  @override
  Future<VaultFileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<VaultFileImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    VaultFileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: 'vault image',
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('An encrypted image could not be shown.'),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    VaultFileImage key,
    ImageDecoderCallback decode,
  ) async {
    final Uint8List bytes = await readMediaFile(key.path);
    if (bytes.isEmpty) {
      throw StateError('The encrypted image is empty.');
    }
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is VaultFileImage && other.path == path && other.scale == scale;

  @override
  int get hashCode => Object.hash(path, scale);

  @override
  String toString() => 'VaultFileImage(scale: $scale)';
}

// ---- Format ------------------------------------------------------------

String _newId() => securityHexFromBytes(randomSecurityBytes(16));

String _cleanExtension(String extension) {
  final String trimmed = extension.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final String dotted = trimmed.startsWith('.') ? trimmed : '.$trimmed';
  return _extensionPattern.hasMatch(dotted) ? dotted.toLowerCase() : '';
}

/// The random id a vault file is named by (and its segments bound to).
String _idOf(String path) {
  final int slash = max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  final String name = path.substring(slash + 1).toLowerCase();
  if (!name.endsWith(kMediaVaultExtension)) {
    throw const FormatException('Not an encrypted media file.');
  }
  final String id = name.substring(
    0,
    name.length - kMediaVaultExtension.length,
  );
  if (!_idPattern.hasMatch(id)) {
    throw const FormatException('Encrypted media file has a foreign name.');
  }
  return id;
}

/// Largest plain length a vault file holds (far beyond any recording).
const int _maxPlainBytes = 1 << 46;

void _checkLength(int length) {
  if (length < 0 || length > _maxPlainBytes) {
    throw const FormatException('Encrypted media file is too large.');
  }
}

int _segmentCount(int length) => length == 0
    ? 1
    : (length + kMediaVaultSegmentBytes - 1) ~/ kMediaVaultSegmentBytes;

List<int> _segmentAad(String id, int index, int count, int length) =>
    utf8.encode('zen.media.v1|$id|$index|$count|$length');

({int length, int count}) _readHeader(Uint8List header, int fileLength) {
  if (header.length < _headerBytes) {
    throw const FormatException('Encrypted media file is too short.');
  }
  for (int index = 0; index < _magic.length; index++) {
    if (header[index] != _magic[index]) {
      throw const FormatException('Not an encrypted media file.');
    }
  }
  if (header[6] != _formatVersion) {
    throw const FormatException('Unsupported encrypted media version.');
  }
  final ByteData data = ByteData.sublistView(header, 0, _headerBytes);
  if (data.getUint32(8, Endian.little) != kMediaVaultSegmentBytes) {
    throw const FormatException('Unsupported encrypted media segment size.');
  }
  final int length = data.getUint64(12, Endian.little);
  _checkLength(length);
  final int count = _segmentCount(length);
  if (fileLength != _headerBytes + count * _sealOverheadBytes + length) {
    throw const FormatException('Encrypted media file has the wrong size.');
  }
  return (length: length, count: count);
}

/// The header of a file of [length] plain bytes.
Uint8List _headerFor(int length) {
  _checkLength(length);
  final ByteData header = ByteData(_headerBytes);
  for (int index = 0; index < _magic.length; index++) {
    header.setUint8(index, _magic[index]);
  }
  header
    ..setUint8(6, _formatVersion)
    ..setUint8(7, 0)
    ..setUint32(8, kMediaVaultSegmentBytes, Endian.little)
    ..setUint64(12, length, Endian.little);
  return header.buffer.asUint8List();
}

Future<Uint8List> _sealMedia(Uint8List key, String id, Uint8List plain) async {
  final int length = plain.length;
  final int count = _segmentCount(length);
  final BytesBuilder out = BytesBuilder(copy: false)..add(_headerFor(length));
  for (int index = 0; index < count; index++) {
    final int start = index * kMediaVaultSegmentBytes;
    final int end = min(start + kMediaVaultSegmentBytes, length);
    out.add(
      await encryptSecurityBytes(
        Uint8List.sublistView(plain, start, end),
        key,
        aad: _segmentAad(id, index, count, length),
      ),
    );
  }
  return out.takeBytes();
}

Future<Uint8List> _openMedia(Uint8List key, String id, Uint8List sealed) async {
  final ({int length, int count}) header = _readHeader(sealed, sealed.length);
  final Uint8List out = Uint8List(header.length);
  int offset = _headerBytes;
  for (int index = 0; index < header.count; index++) {
    final int plainStart = index * kMediaVaultSegmentBytes;
    final int plainLength = min(
      kMediaVaultSegmentBytes,
      header.length - plainStart,
    );
    final int sealedLength = plainLength + _sealOverheadBytes;
    final Uint8List plain = await decryptSecurityBytes(
      Uint8List.sublistView(sealed, offset, offset + sealedLength),
      key,
      aad: _segmentAad(id, index, header.count, header.length),
    );
    if (plain.length != plainLength) {
      throw const FormatException('Encrypted media segment is damaged.');
    }
    out.setRange(plainStart, plainStart + plainLength, plain);
    offset += sealedLength;
  }
  return out;
}

Future<void> _sealToFile(
  Uint8List key,
  String id,
  Uint8List plain,
  String path,
) async {
  final Uint8List sealed = await _sealMedia(key, id, plain);
  final File temporary = File('$path.tmp');
  await temporary.writeAsBytes(sealed, flush: true);
  await temporary.rename(path);
}

Future<Uint8List> _openFile(Uint8List key, String id, String path) async {
  return _openMedia(key, id, await File(path).readAsBytes());
}

/// Encrypts the plain file [source] into [path] one segment at a time,
/// through `<path>.tmp` (removed on failure).
Future<void> _sealFileToFile(
  Uint8List key,
  String id,
  String source,
  String path,
) async {
  final File temporary = File('$path.tmp');
  final RandomAccessFile input = await File(source).open();
  bool done = false;
  try {
    final RandomAccessFile output = await temporary.open(mode: FileMode.write);
    try {
      final int length = await input.length();
      final int count = _segmentCount(length);
      await output.writeFrom(_headerFor(length));
      for (int index = 0; index < count; index++) {
        final int plainLength = min(
          kMediaVaultSegmentBytes,
          length - index * kMediaVaultSegmentBytes,
        );
        final Uint8List plain = await input.read(plainLength);
        if (plain.length != plainLength) {
          throw FileSystemException('The file changed while sealing.', source);
        }
        await output.writeFrom(
          await encryptSecurityBytes(
            plain,
            key,
            aad: _segmentAad(id, index, count, length),
          ),
        );
      }
      await output.flush();
    } finally {
      await output.close();
    }
    await temporary.rename(path);
    done = true;
  } finally {
    await input.close();
    if (!done) {
      await _deleteQuietly(temporary);
    }
  }
}

/// Decrypts the vault file at [path] into the plain file [target] one
/// segment at a time.
Future<void> _openToFile(
  Uint8List key,
  String id,
  String path,
  String target,
) async {
  final RandomAccessFile input = await File(path).open();
  try {
    final ({int length, int count}) header = _readHeader(
      await input.read(_headerBytes),
      await input.length(),
    );
    final RandomAccessFile output = await File(
      target,
    ).open(mode: FileMode.write);
    try {
      for (int index = 0; index < header.count; index++) {
        final int plainLength = min(
          kMediaVaultSegmentBytes,
          header.length - index * kMediaVaultSegmentBytes,
        );
        final Uint8List plain = await decryptSecurityBytes(
          await input.read(plainLength + _sealOverheadBytes),
          key,
          aad: _segmentAad(id, index, header.count, header.length),
        );
        if (plain.length != plainLength) {
          throw const FormatException('Encrypted media segment is damaged.');
        }
        await output.writeFrom(plain);
      }
      await output.flush();
    } finally {
      await output.close();
    }
  } finally {
    await input.close();
  }
}

// Top-level, so the closures sent to another isolate capture only these
// arguments.

Future<void> _sealToFileIn(
  Uint8List key,
  String id,
  Uint8List plain,
  String path, {
  required bool background,
}) {
  if (!background) {
    return _sealToFile(key, id, plain, path);
  }
  return Isolate.run<void>(() => _sealToFile(key, id, plain, path));
}

Future<void> _sealFileToFileIn(
  Uint8List key,
  String id,
  String source,
  String path, {
  required bool background,
}) {
  if (!background) {
    return _sealFileToFile(key, id, source, path);
  }
  return Isolate.run<void>(() => _sealFileToFile(key, id, source, path));
}

Future<Uint8List> _openFileIn(
  Uint8List key,
  String id,
  String path, {
  required bool background,
}) {
  if (!background) {
    return _openFile(key, id, path);
  }
  return Isolate.run<Uint8List>(() => _openFile(key, id, path));
}

Future<void> _openToFileIn(
  Uint8List key,
  String id,
  String path,
  String target, {
  required bool background,
}) {
  if (!background) {
    return _openToFile(key, id, path, target);
  }
  return Isolate.run<void>(() => _openToFile(key, id, path, target));
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException catch (error) {
    logZenWarning('Deleting a media file failed: $error');
  }
}
