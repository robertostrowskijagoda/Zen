import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Files between the account's own devices, piece by piece: sealed into
/// the ledger's file store and opened from it one segment at a time, so a
/// film of any size never sits whole in memory. The format is the one of
/// `storeMedia` (segments of [kMediaSegmentBytes] sealed with
/// ChaCha20-Poly1305, one segment per piece of the blob).

final Chacha20 _aead = Chacha20.poly1305Aead();

Uint8List _segmentNonce(Uint8List nonce, int index) {
  final Uint8List out = Uint8List.fromList(nonce);
  for (int i = 0; i < 4; i++) {
    out[11 - i] ^= (index >> (8 * i)) & 0xFF;
  }
  return out;
}

/// The largest plain file that fits one blob once sealed.
const int kMaxStreamedMediaBytes =
    kMaxBlobBytes - 16 * (kMaxBlobBytes ~/ kBlobChunkSize + 1);

/// Seals [size] plain bytes read by [range] into [blobs] segment by
/// segment and returns the reference (`{id, k, n, mime}`), or null when
/// the file is too big, cannot be read or was refused on this device.
Future<Map<String, dynamic>?> storeMediaStreamed(
  BlobStore blobs, {
  required int size,
  required Future<Uint8List?> Function(int start, int end) range,
  String mime = 'application/octet-stream',
}) async {
  if (size < 0 || size > kMaxStreamedMediaBytes) {
    return null;
  }
  final Uint8List key = randomBytes(32);
  final Uint8List nonce = randomBytes(12);
  final SecretKey secret = SecretKey(key);
  final int segments = size == 0
      ? 1
      : (size + kMediaSegmentBytes - 1) ~/ kMediaSegmentBytes;
  final List<String> chunks = <String>[];
  int sealedSize = 0;
  for (int i = 0; i < segments; i++) {
    final int from = i * kMediaSegmentBytes;
    final int to = math.min(from + kMediaSegmentBytes, size);
    final Uint8List? plain = to == from ? Uint8List(0) : await range(from, to);
    if (plain == null || plain.length != to - from) {
      return null;
    }
    final SecretBox box = await _aead.encrypt(
      plain,
      secretKey: secret,
      nonce: _segmentNonce(nonce, i),
    );
    final int n = box.cipherText.length;
    final Uint8List piece = Uint8List(n + 16)
      ..setRange(0, n, box.cipherText)
      ..setRange(n, n + 16, box.mac.bytes);
    final String hash = sha256Hex(piece);
    if (!blobs.backend.has(hash)) {
      await blobs.backend.write(hash, piece);
    }
    chunks.add(hash);
    sealedSize += piece.length;
  }
  final Map<String, dynamic> manifest = <String, dynamic>{
    't': 'blob',
    'size': sealedSize,
    'mime': 'application/octet-stream',
    'chunk': kBlobChunkSize,
    'chunks': chunks,
  };
  final BlobManifest? described = BlobManifest.fromJson(manifest);
  if (described == null) {
    return null;
  }
  // Registered like a file that arrived: its pieces are all here already.
  blobs.want(described.id);
  final bool taken =
      blobs.hasManifest(described.id) ||
      blobs.acceptManifest(described.id, manifest);
  blobs.markDone(described.id);
  if (!taken) {
    return null;
  }
  return <String, dynamic>{
    'id': described.id,
    'k': b64(key),
    'n': b64(nonce),
    'mime': mime,
  };
}

/// The plain bytes of media [ref] segment by segment; throws when a piece
/// is missing or does not open.
Stream<Uint8List> openMediaStreamed(BlobStore blobs, MediaRef ref) async* {
  final BlobManifest? manifest = blobs.manifest(ref.id);
  if (manifest == null) {
    throw StateError('The file is not here.');
  }
  for (int i = 0; i < manifest.chunks.length; i++) {
    final Uint8List? plain = await openMediaSegment(blobs, ref, i);
    if (plain == null) {
      throw StateError('A piece of the file is missing.');
    }
    yield plain;
  }
}

/// Reads a file the app keeps ([path]: in the media vault or plain)
/// piece by piece.
final class AccountFileReader {
  const AccountFileReader(this.vault);

  final MediaVault? vault;

  /// Plain bytes in the file, or null when it is not there.
  Future<int?> size(String path) async {
    try {
      if (!await File(path).exists()) {
        return null;
      }
      final MediaVault? v = vault ?? MediaVault.current;
      if (isMediaVaultPath(path)) {
        return v == null ? null : await v.length(path);
      }
      return await File(path).length();
    } on Object catch (error) {
      logZenWarning('A file of the account was not measured: $error');
      return null;
    }
  }

  /// Bytes [start] to [end] (plain), or null when they cannot be read.
  Future<Uint8List?> range(String path, int start, int end) async {
    try {
      final MediaVault? v = vault ?? MediaVault.current;
      if (isMediaVaultPath(path)) {
        return v == null ? null : await v.readRange(path, start, end);
      }
      final RandomAccessFile handle = await File(path).open();
      try {
        await handle.setPosition(start);
        return await handle.read(end - start);
      } finally {
        await handle.close();
      }
    } on Object catch (error) {
      logZenWarning('A file of the account was not read: $error');
      return null;
    }
  }
}

/// Whether files between the account's devices may travel now: always
/// on Wi-Fi or a wired network, over mobile data only when "Media tylko
/// przez Wi-Fi" is off. What waits goes as soon as it may.
abstract interface class AccountMediaPolicy {
  Future<bool> mayFetchNow();
}

/// Interface names of mobile data connections (Android, iOS).
final RegExp _mobileInterface = RegExp(
  r'^(rmnet|ccmni|pdp_ip|wwan|rev_rmnet|v4-rmnet|clat)',
  caseSensitive: false,
);

/// Interface names of Wi-Fi or wired networks.
final RegExp _localInterface = RegExp(
  r'^(wlan|wlp|wl|en|eth|ap|swlan|p2p|bridge)',
  caseSensitive: false,
);

/// Whether this device is on Wi-Fi or a wired network (a computer always
/// counts as such; a phone by the names of its network interfaces).
Future<bool> onUnmeteredNetwork({
  Future<List<NetworkInterface>> Function()? interfaces,
  bool? phone,
}) async {
  final bool isPhone = phone ?? (Platform.isAndroid || Platform.isIOS);
  if (!isPhone) {
    return true;
  }
  try {
    final Future<List<NetworkInterface>> Function() lister =
        interfaces ?? () => NetworkInterface.list(includeLoopback: false);
    for (final NetworkInterface i in await lister()) {
      if (_mobileInterface.hasMatch(i.name)) {
        continue;
      }
      if (_localInterface.hasMatch(i.name) && i.addresses.isNotEmpty) {
        return true;
      }
    }
    return false;
  } on Object {
    return false;
  }
}

/// The app's policy: the "Media tylko przez Wi-Fi" setting and the
/// network this device is on.
final class AppAccountMediaPolicy implements AccountMediaPolicy {
  AppAccountMediaPolicy(this.ref);

  final Ref ref;

  @override
  Future<bool> mayFetchNow() async {
    if (!ref.read(appSettingsControllerProvider).mediaOnlyOnWifi) {
      return true;
    }
    return onUnmeteredNetwork();
  }
}

final Provider<AccountMediaPolicy> accountMediaPolicyProvider =
    Provider<AccountMediaPolicy>((Ref ref) => AppAccountMediaPolicy(ref));
