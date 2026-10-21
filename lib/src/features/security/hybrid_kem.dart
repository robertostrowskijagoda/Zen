import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/hybrid_kem_ffi.dart';

/// The hybrid post-quantum key encapsulation behind Zen's own seals
/// (mailbox mail, the locked inbox): MLKEM768-X25519 ("X-Wing") through
/// HPKE, from Go's standard library (crypto/hpke, crypto/mlkem) in the
/// bridge (`native/yggdrasil_bridge/pq_kem.go`), on every platform — there
/// is no Dart implementation of ML-KEM. A secret stays safe while either
/// ML-KEM-768 or X25519 holds.
///
/// A key pair is a 32-byte seed; the public key is 1216 bytes, a
/// ciphertext 1120, the secret 32. The secret is bound to the `info` both
/// sides give. A wrong key or a damaged ciphertext gives another secret
/// (no error): the AEAD keyed with it refuses the box.
const int kHybridSeedBytes = 32;
const int kHybridPublicKeyBytes = 1216;
const int kHybridCiphertextBytes = 1120;
const int kHybridSecretBytes = 32;

@immutable
final class HybridEncapsulation {
  const HybridEncapsulation({required this.ciphertext, required this.secret});

  final Uint8List ciphertext;
  final Uint8List secret;
}

abstract interface class HybridKem {
  /// The public key of [seed].
  Future<Uint8List> publicKeyOf(Uint8List seed);

  /// A fresh secret for [publicKey] and the ciphertext that carries it.
  Future<HybridEncapsulation> encapsulate(
    Uint8List publicKey, {
    required List<int> info,
  });

  /// The secret [ciphertext] carries for [seed] and [info].
  Future<Uint8List> decapsulate(
    Uint8List seed,
    Uint8List ciphertext, {
    required List<int> info,
  });
}

HybridKem? _override;
HybridKem? _loaded;

/// The KEM of this process: the bridge's. Throws when the bridge cannot be
/// loaded — nothing is then sealed (there is no weaker fallback), except in
/// `flutter test` runs without a built bridge, which use the classical
/// [kClassicalStandInHybridKem] (never in a release build).
HybridKem get hybridKem => _override ?? (_loaded ??= _loadHybridKem());

/// Replaces [hybridKem] (tests); `null` restores it.
@visibleForTesting
void debugOverrideHybridKem(HybridKem? kem) {
  _override = kem;
}

HybridKem _loadHybridKem() {
  try {
    return BridgeHybridKem.load();
  } on Object catch (error) {
    if (!kReleaseMode && Platform.environment.containsKey('FLUTTER_TEST')) {
      logZenWarning(
        'No bridge in this test run; seals use the classical stand-in KEM: '
        '$error',
      );
      return kClassicalStandInHybridKem;
    }
    rethrow;
  }
}

/// 32 random bytes: a new key pair's seed.
Uint8List randomHybridSeed() => _randomBytes(kHybridSeedBytes);

Uint8List _randomBytes(int length) {
  final Random random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// A hybrid public key (base64url), or `null` for anything that is not one.
Uint8List? decodeHybridPublicKey(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  try {
    final Uint8List bytes = base64Url.decode(base64Url.normalize(value));
    return bytes.length == kHybridPublicKeyBytes ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// A seed with its public key.
@immutable
final class HybridKeyPair {
  const HybridKeyPair({required this.seed, required this.publicKey});

  final Uint8List seed;
  final Uint8List publicKey;

  static Future<HybridKeyPair> fromSeed(Uint8List seed) async =>
      HybridKeyPair(seed: seed, publicKey: await hybridKem.publicKeyOf(seed));

  static Future<HybridKeyPair> generate() => fromSeed(randomHybridSeed());
}

/// A KEM with the sizes and behaviour of the hybrid one, built on X25519
/// alone: for `flutter test` runs without the bridge. Not post-quantum.
@visibleForTesting
const HybridKem kClassicalStandInHybridKem = _ClassicalStandInKem();

final class _ClassicalStandInKem implements HybridKem {
  const _ClassicalStandInKem();

  static const int _filler = kHybridPublicKeyBytes - 32;
  static const int _random = kHybridCiphertextBytes - 32;

  static Uint8List _expand(List<int> seed, int length) {
    final Uint8List out = Uint8List(length);
    int offset = 0;
    for (int block = 0; offset < length; block++) {
      final List<int> bytes = crypto.sha256.convert(<int>[
        ...seed,
        block,
      ]).bytes;
      final int take = min(bytes.length, length - offset);
      out.setRange(offset, offset + take, bytes);
      offset += take;
    }
    return out;
  }

  static void _check(int length, int expected, String what) {
    if (length != expected) {
      throw FormatException('$what of $length bytes');
    }
  }

  static Future<Uint8List> _secret(
    List<int> shared,
    Uint8List publicKey,
    Uint8List ciphertext,
    List<int> info,
  ) async {
    final Mac mac = await Hmac.sha256().calculateMac(<int>[
      ...utf8.encode('zen.standin.v1'),
      ...crypto.sha256.convert(publicKey).bytes,
      ...ciphertext,
      ...info,
    ], secretKey: SecretKey(shared));
    return Uint8List.fromList(mac.bytes);
  }

  /// The X25519 key of [seed]: hashed first, as the hybrid KEM expands
  /// its seed, so every bit of the seed matters (X25519 itself ignores
  /// the bits its clamping clears).
  static Future<SimpleKeyPair> _pair(Uint8List seed) =>
      X25519().newKeyPairFromSeed(crypto.sha256.convert(seed).bytes);

  @override
  Future<Uint8List> publicKeyOf(Uint8List seed) async {
    _check(seed.length, kHybridSeedBytes, 'seed');
    final SimpleKeyPair pair = await _pair(seed);
    final List<int> x = (await pair.extractPublicKey()).bytes;
    return Uint8List.fromList(<int>[..._expand(x, _filler), ...x]);
  }

  @override
  Future<HybridEncapsulation> encapsulate(
    Uint8List publicKey, {
    required List<int> info,
  }) async {
    _check(publicKey.length, kHybridPublicKeyBytes, 'public key');
    final SimpleKeyPair ephemeral = await X25519().newKeyPair();
    final SecretKey shared = await X25519().sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        publicKey.sublist(_filler),
        type: KeyPairType.x25519,
      ),
    );
    final Uint8List ciphertext = Uint8List.fromList(<int>[
      ..._randomBytes(_random),
      ...(await ephemeral.extractPublicKey()).bytes,
    ]);
    return HybridEncapsulation(
      ciphertext: ciphertext,
      secret: await _secret(
        await shared.extractBytes(),
        publicKey,
        ciphertext,
        info,
      ),
    );
  }

  @override
  Future<Uint8List> decapsulate(
    Uint8List seed,
    Uint8List ciphertext, {
    required List<int> info,
  }) async {
    _check(ciphertext.length, kHybridCiphertextBytes, 'ciphertext');
    final Uint8List publicKey = await publicKeyOf(seed);
    final SecretKey shared = await X25519().sharedSecretKey(
      keyPair: await _pair(seed),
      remotePublicKey: SimplePublicKey(
        ciphertext.sublist(_random),
        type: KeyPairType.x25519,
      ),
    );
    return _secret(await shared.extractBytes(), publicKey, ciphertext, info);
  }
}
