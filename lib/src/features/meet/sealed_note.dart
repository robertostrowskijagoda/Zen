import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

/// A short note sealed for one key only, for things passed on by a friend
/// in between who must not read them (an address, a place): a hybrid KEM
/// (ML-KEM-768 + X25519, hybrid_kem.dart) to the recipient's public key,
/// the key derived from the secret and bound to [context], AES-256-GCM.
@immutable
final class SealedNote {
  const SealedNote({required this.kemCiphertext, required this.box});

  final Uint8List kemCiphertext;
  final Uint8List box;

  Map<String, String> toJson() => <String, String>{
    'kc': base64Url.encode(kemCiphertext),
    'b': base64Url.encode(box),
  };

  static SealedNote? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Uint8List? kc = _bytes(json['kc'], 2000);
    final Uint8List? b = _bytes(json['b'], 4000);
    return kc == null || b == null
        ? null
        : SealedNote(kemCiphertext: kc, box: b);
  }
}

Uint8List? _bytes(Object? value, int maxChars) {
  if (value is! String || value.isEmpty || value.length > maxChars) {
    return null;
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}

Uint8List _key(Uint8List secret, Uint8List kemCiphertext, String context) =>
    securitySubkey(
      Uint8List.fromList(<int>[...secret, ...kemCiphertext]),
      'note|$context',
    );

/// [json] sealed for [publicKey] in [context].
Future<SealedNote> sealNote(
  Uint8List publicKey,
  String context,
  Map<String, dynamic> json,
) async {
  final HybridEncapsulation kem = await hybridKem.encapsulate(
    publicKey,
    info: utf8.encode('zen.note.v1|$context'),
  );
  final Uint8List box = await encryptSecurityBytes(
    Uint8List.fromList(utf8.encode(jsonEncode(json))),
    _key(kem.secret, kem.ciphertext, context),
    aad: utf8.encode('zen.note.v1|$context'),
  );
  return SealedNote(kemCiphertext: kem.ciphertext, box: box);
}

/// [note] opened with [seed] in [context]; `null` when it does not open.
Future<Map<String, dynamic>?> openNote(
  Uint8List seed,
  String context,
  SealedNote note,
) async {
  try {
    final Uint8List secret = await hybridKem.decapsulate(
      seed,
      note.kemCiphertext,
      info: utf8.encode('zen.note.v1|$context'),
    );
    final Object? json = jsonDecode(
      utf8.decode(
        await decryptSecurityBytes(
          note.box,
          _key(secret, note.kemCiphertext, context),
          aad: utf8.encode('zen.note.v1|$context'),
        ),
      ),
    );
    return json is Map<String, dynamic> ? json : null;
  } on Object {
    return null;
  }
}

/// [value] as base64url bytes of at most [maxChars] characters, or `null`.
Uint8List? noteBytes(Object? value, {int maxChars = 4000}) =>
    _bytes(value, maxChars);
