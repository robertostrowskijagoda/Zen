import 'dart:typed_data';

import 'package:zen/src/features/security/hybrid_kem.dart';

/// A [HybridKem] that counts its operations, over the bridge's KEM when the
/// test run has one and the classical stand-in otherwise.
final class CountingKem implements HybridKem {
  CountingKem([HybridKem? inner]) : _inner = inner ?? hybridKem;

  final HybridKem _inner;
  int encapsulations = 0;
  int decapsulations = 0;

  @override
  Future<Uint8List> publicKeyOf(Uint8List seed) => _inner.publicKeyOf(seed);

  @override
  Future<HybridEncapsulation> encapsulate(
    Uint8List publicKey, {
    required List<int> info,
  }) {
    encapsulations += 1;
    return _inner.encapsulate(publicKey, info: info);
  }

  @override
  Future<Uint8List> decapsulate(
    Uint8List seed,
    Uint8List ciphertext, {
    required List<int> info,
  }) {
    decapsulations += 1;
    return _inner.decapsulate(seed, ciphertext, info: info);
  }
}
