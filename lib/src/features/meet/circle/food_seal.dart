import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

/// The place of shared food (and the small chat about it) only for the one
/// the cook accepted — not for the friend in between who passes requests
/// and answers on for a friend of a friend.
///
/// The one who asks makes a fresh hybrid key pair for the request
/// (ML-KEM-768 + X25519, hybrid_kem.dart) and sends its public key with
/// "Biorę". On "Przyjmij" the cook encapsulates a secret to it; from the
/// secret come two keys (HMAC-SHA256 as the HKDF-Expand step, bound to the
/// KEM ciphertext): one seals the place (AES-256-GCM, bound to the offer),
/// the other the chat messages both ways. The friend in between carries
/// only ciphertext. It protects against a curious friend in between, not
/// against one who would swap the key in the request (the cook cannot tell
/// the key of someone they do not know).
const String _kemContext = 'zen.food.kem.v1';
const String _placeContext = 'zen.food.place.v1';
const String _chatContext = 'zen.food.chat.v1';

List<int> _kemInfo(String offerId) => utf8.encode('$_kemContext|$offerId');

Uint8List _derive(Uint8List secret, Uint8List kemCiphertext, String purpose) =>
    securitySubkey(
      Uint8List.fromList(<int>[...secret, ...kemCiphertext]),
      purpose,
    );

/// What the cook sends on "Przyjmij": the KEM ciphertext and the sealed
/// place; the chat key stays on the cook's phone.
@immutable
final class FoodPlaceSeal {
  const FoodPlaceSeal({
    required this.kemCiphertext,
    required this.box,
    required this.chatKey,
  });

  final Uint8List kemCiphertext;
  final Uint8List box;
  final Uint8List chatKey;
}

/// A fresh key pair for one request ("Biorę").
Future<HybridKeyPair> newFoodRequestKeys() => HybridKeyPair.generate();

/// Seals [place] of offer [offerId] for the asker's [publicKey].
Future<FoodPlaceSeal> sealFoodPlace({
  required String offerId,
  required String place,
  required Uint8List publicKey,
}) async {
  final HybridEncapsulation kem = await hybridKem.encapsulate(
    publicKey,
    info: _kemInfo(offerId),
  );
  final Uint8List box = await encryptSecurityBytes(
    Uint8List.fromList(utf8.encode(place)),
    _derive(kem.secret, kem.ciphertext, _placeContext),
    aad: utf8.encode('$_placeContext|$offerId'),
  );
  return FoodPlaceSeal(
    kemCiphertext: kem.ciphertext,
    box: box,
    chatKey: _derive(kem.secret, kem.ciphertext, _chatContext),
  );
}

/// The place and the chat key, opened with the request's [seed]; `null`
/// when it does not open (another key, damage).
Future<(String, Uint8List)?> openFoodPlace({
  required String offerId,
  required Uint8List seed,
  required Uint8List kemCiphertext,
  required Uint8List box,
}) async {
  try {
    final Uint8List secret = await hybridKem.decapsulate(
      seed,
      kemCiphertext,
      info: _kemInfo(offerId),
    );
    final Uint8List plain = await decryptSecurityBytes(
      box,
      _derive(secret, kemCiphertext, _placeContext),
      aad: utf8.encode('$_placeContext|$offerId'),
    );
    return (utf8.decode(plain), _derive(secret, kemCiphertext, _chatContext));
  } on Object {
    return null;
  }
}

List<int> _chatAad(String offerId, bool fromCook) =>
    utf8.encode('$_chatContext|$offerId|${fromCook ? 'c' : 'a'}');

/// One chat message ([json]) sealed with the pair's [chatKey]; the
/// direction is bound in, so a message cannot be played back to its
/// writer.
Future<Uint8List> sealFoodChat(
  Uint8List chatKey,
  String offerId, {
  required bool fromCook,
  required Map<String, dynamic> json,
}) => encryptSecurityBytes(
  Uint8List.fromList(utf8.encode(jsonEncode(json))),
  chatKey,
  aad: _chatAad(offerId, fromCook),
);

/// A sealed chat message opened, or `null`.
Future<Map<String, dynamic>?> openFoodChat(
  Uint8List chatKey,
  String offerId, {
  required bool fromCook,
  required Uint8List box,
}) async {
  try {
    final Object? json = jsonDecode(
      utf8.decode(
        await decryptSecurityBytes(
          box,
          chatKey,
          aad: _chatAad(offerId, fromCook),
        ),
      ),
    );
    return json is Map<String, dynamic> ? json : null;
  } on Object {
    return null;
  }
}

/// Base64url, or `null` for anything that is not; longer than [maxChars]
/// is not taken either.
Uint8List? foodBytes(Object? value, {int maxChars = 8000}) {
  if (value is! String || value.isEmpty || value.length > maxChars) {
    return null;
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}

String foodB64(List<int> bytes) => base64Url.encode(bytes);
