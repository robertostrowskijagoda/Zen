import 'dart:io';
import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';

/// A store in [root] sealed like the app's (AES-GCM for the storage key,
/// hidden names), without compression.
FileBinaryStore sealedStore(Directory root) => FileBinaryStore(
  root,
  codec: BinaryCodec(compressor: const _PassThrough()),
  protector: EncryptedBinaryPayloadProtector(
    MemoryAppSecurityService(
      passwordIterations: 10,
      encryptionKey: Uint8List.fromList(List<int>.filled(32, 7)),
    ),
  ),
);

/// Damages what [store] keeps under [key] the way a killed write or a bad
/// sector does: the file is cut in half (its seal no longer opens) and its
/// backup is gone, so nothing good is left of it. Returns the file.
Future<File> damageStored(FileBinaryStore store, String key) async {
  final Uint8List? payload = await store.read(key);
  if (payload == null) {
    throw StateError('Nothing stored under $key.');
  }
  // Written again: the write says which file the key lives in.
  final File file = await store.write(key, payload);
  final File backup = File('${file.path}.bak');
  if (backup.existsSync()) {
    backup.deleteSync();
  }
  final Uint8List bytes = file.readAsBytesSync();
  file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
  return file;
}

/// Files under [root] set aside as damaged (`*.damaged-<time>`).
List<String> setAsideUnder(Directory root) => <String>[
  for (final FileSystemEntity e in root.listSync(recursive: true))
    if (e is File && e.path.contains('.damaged-')) e.path,
];

final class _PassThrough implements BinaryCompressor {
  const _PassThrough();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
