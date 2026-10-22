import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Seals stored payloads with the master data key (AES-256-GCM).
///
/// One envelope opens: `ZENENC2`, bound to the key the payload is stored
/// under (authenticated, not stored), so a file copied over another key's
/// file does not open either. Plaintext is refused
/// ([UnsupportedStoredPayloadException], which the store reads as "nothing
/// stored"): with access to the files alone nobody can plant a
/// record — a node config, a cache of verified signatures.
///
/// It also gives the key that hides file names that would show who the
/// user talks to ([BinaryStoreNameKeySource]).
final class EncryptedBinaryPayloadProtector
    implements KeyedBinaryPayloadProtector, BinaryStoreNameKeySource {
  EncryptedBinaryPayloadProtector(this._security);

  /// `ZENENC2`: bound to the storage key.
  static const List<int> _boundMagic = <int>[
    0x5A,
    0x45,
    0x4E,
    0x45,
    0x4E,
    0x43,
    0x32,
  ];

  final AppSecurityService _security;

  Future<Uint8List> _key({required bool sealing}) async {
    final Uint8List? key = await _security.currentEncryptionKey();
    if (key == null) {
      throw StateError(
        sealing
            ? 'Encrypted storage is always on, but the app is locked.'
            : 'Encrypted storage is enabled but no decryption key is '
                  'available.',
      );
    }
    return key;
  }

  static List<int> _aad(String storageKey) =>
      utf8.encode('zen.store.v2|$storageKey');

  /// Not used: every payload is sealed for the key it is stored under
  /// ([sealFor]).
  @override
  Future<Uint8List> seal(Uint8List payload) {
    return Future<Uint8List>.error(
      UnsupportedError('Stored payloads are sealed with sealFor.'),
    );
  }

  /// Not used: every payload is opened for the key it is stored under
  /// ([unsealFor]).
  @override
  Future<Uint8List> unseal(Uint8List payload) {
    return Future<Uint8List>.error(
      UnsupportedError('Stored payloads are opened with unsealFor.'),
    );
  }

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async {
    final Uint8List encrypted = await encryptSecurityBytes(
      payload,
      await _key(sealing: true),
      aad: _aad(storageKey),
    );
    return Uint8List.fromList(<int>[..._boundMagic, ...encrypted]);
  }

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    if (_isNewerSeal(payload)) {
      // `ZENENC3`…: sealed by a newer build. Not "nothing stored", which
      // would be saved over.
      throw NewerFormatException(
        'sealed payload',
        found: payload[_boundMagic.length - 1] - 0x30,
        supported: 2,
      );
    }
    if (!_startsWith(payload, _boundMagic)) {
      throw const UnsupportedStoredPayloadException(
        'Only payloads sealed for their storage key open.',
      );
    }
    return decryptSecurityBytes(
      Uint8List.sublistView(payload, _boundMagic.length),
      await _key(sealing: false),
      aad: _aad(storageKey),
    );
  }

  @override
  bool isSealed(Uint8List payload) => _startsWith(payload, _boundMagic);

  @override
  Future<Uint8List?> fileNameKey() async {
    final Uint8List? key = await _security.currentEncryptionKey();
    return key == null ? null : securitySubkey(key, 'store.names');
  }

  /// `ZENENC` followed by a version digit above 2.
  static bool _isNewerSeal(Uint8List payload) {
    final int last = _boundMagic.length - 1;
    if (payload.length <= last) {
      return false;
    }
    for (int index = 0; index < last; index++) {
      if (payload[index] != _boundMagic[index]) {
        return false;
      }
    }
    return payload[last] > _boundMagic[last] && payload[last] <= 0x39;
  }

  static bool _startsWith(Uint8List payload, List<int> magic) {
    if (payload.length < magic.length) {
      return false;
    }
    for (int index = 0; index < magic.length; index++) {
      if (payload[index] != magic[index]) {
        return false;
      }
    }
    return true;
  }
}
