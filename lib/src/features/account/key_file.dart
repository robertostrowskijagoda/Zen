import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/account/account_recovery.dart';

/// The encrypted backup file of the account key (`zen-klucz-<date>.zenkey`).
///
/// Layout (big endian), the whole header is authenticated as AES-GCM data:
///
/// | bytes | what                                   |
/// |-------|----------------------------------------|
/// | 6     | magic `ZENKEY`                         |
/// | 1     | format version ([kKeyFileVersion])     |
/// | 4     | Argon2id memory, KiB                   |
/// | 1     | Argon2id passes                        |
/// | 1     | Argon2id parallelism                   |
/// | 16    | Argon2id salt                          |
/// | 12    | AES-GCM nonce                          |
/// | 32+16 | the 32-byte seed, then the GCM tag     |
///
/// The key is Argon2id of the password. Anyone who has the file and the
/// password owns the account.
const int kKeyFileVersion = 1;

/// Extension of the backup file.
const String kKeyFileExtension = 'zenkey';

/// Shortest password the backup file accepts.
const int kKeyFileMinPasswordLength = kMinAccountPasswordLength;

const String _magic = 'ZENKEY';
const int _seedLength = 32;
const int _saltLength = 16;
const int _nonceLength = 12;
const int _tagLength = 16;
const int _headerLength = 6 + 1 + 4 + 1 + 1 + _saltLength + _nonceLength;
const int _fileLength = _headerLength + _seedLength + _tagLength;

/// Why a backup file did not open.
enum KeyFileError {
  /// Not a Zen key file, a newer version, or damaged.
  format,

  /// The password is wrong (or the file was changed).
  password,
}

/// The seed of a file that opened, or the reason it did not.
final class KeyFileDecoded {
  const KeyFileDecoded.ok(Uint8List this.seed) : error = null;
  const KeyFileDecoded.failed(KeyFileError this.error) : seed = null;

  final Uint8List? seed;
  final KeyFileError? error;

  bool get isOk => seed != null;
}

/// `zen-klucz-2026-10-21.zenkey` for [date].
String keyFileName(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'zen-klucz-${date.year.toString().padLeft(4, '0')}-'
      '${two(date.month)}-${two(date.day)}.$kKeyFileExtension';
}

Uint8List _header(PasswordCost cost, Uint8List salt, Uint8List nonce) {
  final ByteData head = ByteData(_headerLength);
  final Uint8List out = head.buffer.asUint8List();
  out.setRange(0, 6, ascii.encode(_magic));
  head.setUint8(6, kKeyFileVersion);
  head.setUint32(7, cost.memoryKiB);
  head.setUint8(11, cost.iterations);
  head.setUint8(12, cost.parallelism);
  out.setRange(13, 13 + _saltLength, salt);
  out.setRange(13 + _saltLength, _headerLength, nonce);
  return out;
}

/// Encrypts [seed] with [password] into the bytes of a backup file.
/// [cost] defaults to the heavy one used for things that leave the device;
/// tests pass a light one.
Future<Uint8List> encryptKeyFile(
  Uint8List seed,
  String password, {
  PasswordCost cost = kRecoveryPasswordCost,
}) async {
  if (seed.length != _seedLength) {
    throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
  }
  final Uint8List salt = randomBytes(_saltLength);
  final Uint8List nonce = randomBytes(_nonceLength);
  final Uint8List header = _header(cost, salt, nonce);
  final Uint8List key = await derivePasswordKey(password, salt, cost: cost);
  final SecretBox box = await AesGcm.with256bits().encrypt(
    seed,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: header,
  );
  return Uint8List.fromList(<int>[
    ...header,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

/// Opens the backup file [data] with [password].
Future<KeyFileDecoded> decryptKeyFile(Uint8List data, String password) async {
  if (data.length != _fileLength ||
      ascii.decode(data.sublist(0, 6), allowInvalid: true) != _magic ||
      data[6] != kKeyFileVersion) {
    return const KeyFileDecoded.failed(KeyFileError.format);
  }
  final ByteData head = ByteData.sublistView(data, 0, _headerLength);
  // Bounded costs only: a hostile file must not freeze the app.
  final PasswordCost? cost = PasswordCost.fromJson(<String, int>{
    'm': head.getUint32(7),
    't': head.getUint8(11),
    'p': head.getUint8(12),
  });
  if (cost == null) {
    return const KeyFileDecoded.failed(KeyFileError.format);
  }
  final Uint8List header = Uint8List.fromList(data.sublist(0, _headerLength));
  final Uint8List salt = Uint8List.fromList(data.sublist(13, 13 + _saltLength));
  final Uint8List nonce = Uint8List.fromList(
    data.sublist(13 + _saltLength, _headerLength),
  );
  final Uint8List key = await derivePasswordKey(password, salt, cost: cost);
  try {
    final List<int> seed = await AesGcm.with256bits().decrypt(
      SecretBox(
        data.sublist(_headerLength, _headerLength + _seedLength),
        nonce: nonce,
        mac: Mac(data.sublist(_headerLength + _seedLength)),
      ),
      secretKey: SecretKey(key),
      aad: header,
    );
    return KeyFileDecoded.ok(Uint8List.fromList(seed));
  } on SecretBoxAuthenticationError {
    return const KeyFileDecoded.failed(KeyFileError.password);
  }
}
