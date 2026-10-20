import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:zen/src/core/utils/background_work.dart';

const String _securityVerifyTag = 'zen.security.verify';
const String _securityMasterTag = 'zen.security.master';

/// Deterministic verification digest of a derived key. It is domain-separated
/// from the key itself so the stored verifier can never be used directly as
/// an encryption key.
Uint8List securityVerifyDigest(Uint8List key) {
  return Uint8List.fromList(
    crypto.sha256.convert(<int>[
      ...utf8.encode(_securityVerifyTag),
      ...key,
    ]).bytes,
  );
}

/// Fingerprint of the master data key, used to check that a stored biometric
/// token still matches the active master key.
Uint8List securityMasterFingerprint(Uint8List masterKey) {
  return Uint8List.fromList(
    crypto.sha256.convert(<int>[
      ...utf8.encode(_securityMasterTag),
      ...masterKey,
    ]).bytes,
  );
}

/// A key for one [purpose] derived from the master data key
/// (HMAC-SHA256, the HKDF-Expand step for a uniformly random key), so the
/// master key itself is never used for two things.
Uint8List securitySubkey(Uint8List masterKey, String purpose) {
  return Uint8List.fromList(
    crypto.Hmac(
      crypto.sha256,
      masterKey,
    ).convert(<int>[...utf8.encode('zen.subkey.$purpose'), 1]).bytes,
  );
}

/// Constant-time comparison to avoid timing side channels when checking
/// digests and tokens.
bool securityConstantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  int difference = 0;
  for (int index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

/// AES-256-GCM: `nonce | ciphertext | tag`. [aad] (authenticated, not
/// stored) binds the result to its context, e.g. the storage key.
///
/// AES-GCM runs in pure Dart here, so payloads over
/// [kBackgroundWorkThresholdBytes] are sealed in a short-lived isolate
/// instead of blocking the UI thread; the result is the same.
Future<Uint8List> encryptSecurityBytes(
  Uint8List plaintext,
  Uint8List key, {
  List<int> aad = const <int>[],
}) {
  final Uint8List nonce = randomSecurityBytes(12);
  final List<int> boundAad = aad.isEmpty ? const <int>[] : _sendable(aad);
  return runSizedWork<Uint8List>(
    plaintext.length,
    () => _encryptAesGcm(plaintext, key, nonce, boundAad),
  );
}

Future<Uint8List> _encryptAesGcm(
  Uint8List plaintext,
  Uint8List key,
  Uint8List nonce,
  List<int> aad,
) async {
  final SecretBox secretBox = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: aad,
  );
  final List<int> cipherText = secretBox.cipherText;
  final List<int> mac = secretBox.mac.bytes;
  final Uint8List out = Uint8List(12 + cipherText.length + mac.length);
  out
    ..setRange(0, 12, secretBox.nonce)
    ..setRange(12, 12 + cipherText.length, cipherText)
    ..setRange(12 + cipherText.length, out.length, mac);
  return out;
}

Future<Uint8List> decryptSecurityBytes(
  Uint8List ciphertext,
  Uint8List key, {
  List<int> aad = const <int>[],
}) {
  if (ciphertext.length < 28) {
    return Future<Uint8List>.error(
      const FormatException('Encrypted payload is too short.'),
    );
  }
  final List<int> boundAad = aad.isEmpty ? const <int>[] : _sendable(aad);
  return runSizedWork<Uint8List>(
    ciphertext.length - 28,
    () => _decryptAesGcm(ciphertext, key, boundAad),
  );
}

Future<Uint8List> _decryptAesGcm(
  Uint8List ciphertext,
  Uint8List key,
  List<int> aad,
) async {
  final int macOffset = ciphertext.length - 16;
  final SecretBox secretBox = SecretBox(
    ciphertext.sublist(12, macOffset),
    nonce: ciphertext.sublist(0, 12),
    mac: Mac(ciphertext.sublist(macOffset)),
  );
  final List<int> plaintext = await AesGcm.with256bits().decrypt(
    secretBox,
    secretKey: SecretKey(key),
    aad: aad,
  );
  return Uint8List.fromList(plaintext);
}

/// [bytes] as a plain byte list, safe to hand to another isolate whatever
/// list type the caller passed.
Uint8List _sendable(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

Uint8List randomSecurityBytes(int length) {
  final Random random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

String securityHexFromBytes(Uint8List bytes) {
  return bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List securityBytesFromHex(String value) {
  return Uint8List.fromList(
    List<int>.generate(
      value.length ~/ 2,
      (int index) =>
          int.parse(value.substring(index * 2, index * 2 + 2), radix: 16),
    ),
  );
}
