import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Seals stored payloads with the master data key (AES-256-GCM).
///
/// One envelope opens: `ZENENC2`, bound to the key the payload is stored
/// under (authenticated, not stored), so a file copied over another key's
/// file does not open either. Plaintext and the older unbound `ZENENC1`
/// are refused ([UnsupportedStoredPayloadException], which the store reads
/// as "nothing stored"): with access to the files alone nobody can plant a
/// record — a node config, a cache of verified signatures.
///
/// It also gives the key that hides file names that would show who the
/// user talks to ([BinaryStoreNameKeySource]).
final class EncryptedBinaryPayloadProtector
    implements KeyedBinaryPayloadProtector, BinaryStoreNameKeySource {
  EncryptedBinaryPayloadProtector(this._security);

  /// `ZENENC1`: sealed without a storage key (older versions).
  static const List<int> _unboundMagic = <int>[
    0x5A,
    0x45,
    0x4E,
    0x45,
    0x4E,
    0x43,
    0x31,
  ];

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

  /// Whether [payload] was sealed the older way, without a storage key.
  bool isUnboundSeal(Uint8List payload) => _startsWith(payload, _unboundMagic);

  /// Opens a payload sealed the older way (`ZENENC1`). Only the one-time
  /// upgrade of the node config uses it: a lost node key would be a new
  /// address for every friend. Kept on purpose: the only compatibility path
  /// left.
  Future<Uint8List> unsealUnbound(Uint8List payload) async {
    if (!isUnboundSeal(payload)) {
      throw const UnsupportedStoredPayloadException(
        'Not a payload sealed without a storage key.',
      );
    }
    return decryptSecurityBytes(
      Uint8List.sublistView(payload, _unboundMagic.length),
      await _key(sealing: false),
    );
  }

  @override
  Future<Uint8List?> fileNameKey() async {
    final Uint8List? key = await _security.currentEncryptionKey();
    return key == null ? null : securitySubkey(key, 'store.names');
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
