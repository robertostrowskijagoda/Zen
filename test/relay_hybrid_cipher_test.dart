import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

import 'support/counting_kem.dart';

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

RelayEnvelope _envelope(RelayHybridBox box, {String id = 'rid-1'}) =>
    RelayEnvelope(
      id: id,
      sender: '200::a',
      recipient: '200::b',
      createdAtMillis: 1000,
      expiresAtMillis: 2000,
      box: box,
    );

Uint8List _aad({String id = 'rid-1'}) => RelayEnvelope.associatedDataFor(
  id: id,
  sender: '200::a',
  recipient: '200::b',
  createdAtMillis: 1000,
  expiresAtMillis: 2000,
);

void main() {
  late CountingKem kem;

  setUp(() {
    kem = CountingKem();
    debugOverrideHybridKem(kem);
    RelayCipher.debugForgetKems();
  });

  tearDown(() {
    debugOverrideHybridKem(null);
    RelayCipher.debugForgetKems();
  });

  test('the mailbox key combines the hybrid secret and the static X25519 '
      'term (vector)', () async {
    // HKDF-SHA256(ikm = K || DH, salt = c || nonce, info = "zen.relay.v2"),
    // computed independently (RFC 5869).
    final SecretKey key = await RelayCipher.hybridKey(
      pqSecret: List<int>.filled(32, 1),
      staticShared: List<int>.filled(32, 2),
      pqCiphertext: List<int>.filled(kHybridCiphertextBytes, 3),
      nonce: List<int>.filled(12, 4),
    );
    expect(
      _hex(await key.extractBytes()),
      '221253722ba71ffa14822083cca0cae48302e81732079df7f90157ede3ef7c38',
    );
    // Either half alone gives another key.
    final SecretKey noPq = await RelayCipher.hybridKey(
      pqSecret: List<int>.filled(32, 0),
      staticShared: List<int>.filled(32, 2),
      pqCiphertext: List<int>.filled(kHybridCiphertextBytes, 3),
      nonce: List<int>.filled(12, 4),
    );
    expect(
      _hex(await noPq.extractBytes()),
      isNot(_hex(await key.extractBytes())),
    );
  });

  test('a mailbox deposit is sealed with the hybrid KEM and opens only for '
      'its recipient, from its sender, unchanged', () async {
    final RelayIdentity alice = await RelayIdentity.generateHybrid();
    final RelayIdentity bob = await RelayIdentity.generateHybrid();
    final RelayIdentity eve = await RelayIdentity.generateHybrid();
    final Uint8List plain = Uint8List.fromList(utf8.encode('tajne'));
    final RelayHybridBox box = await RelayCipher.sealHybrid(
      sender: alice,
      recipient: bob.publicKeys!,
      plaintext: plain,
      associatedData: _aad(),
    );
    expect(box.pqCiphertext, hasLength(kHybridCiphertextBytes));

    // The envelope as relays hold it: the KEM ciphertext travels as `q`.
    final Map<String, dynamic> wire = _envelope(box).toJson();
    expect(wire.containsKey('e'), isFalse);
    final RelayEnvelope parsed = RelayEnvelope.tryParse(
      jsonDecode(jsonEncode(wire)),
    )!;
    expect(
      await RelayCipher.openHybrid(
        recipient: bob,
        senderPublicKey: alice.publicKey,
        box: parsed.box,
        associatedData: parsed.associatedData,
      ),
      orderedEquals(plain),
    );

    Future<void> refused(
      RelayIdentity recipient,
      Uint8List sender,
      RelayHybridBox box,
      Uint8List aad,
    ) => expectLater(
      RelayCipher.openHybrid(
        recipient: recipient,
        senderPublicKey: sender,
        box: box,
        associatedData: aad,
      ),
      throwsA(anything),
    );
    // Someone else's key, another claimed sender, another header.
    await refused(eve, alice.publicKey, box, _aad());
    await refused(bob, eve.publicKey, box, _aad());
    await refused(bob, alice.publicKey, box, _aad(id: 'rid-2'));
    // A changed KEM ciphertext, nonce or body.
    await refused(
      bob,
      alice.publicKey,
      RelayHybridBox(
        pqCiphertext: Uint8List.fromList(box.pqCiphertext)..[9] ^= 1,
        nonce: box.nonce,
        cipherText: box.cipherText,
      ),
      _aad(),
    );
    await refused(
      bob,
      alice.publicKey,
      RelayHybridBox(
        pqCiphertext: box.pqCiphertext,
        nonce: Uint8List.fromList(box.nonce)..[0] ^= 1,
        cipherText: box.cipherText,
      ),
      _aad(),
    );
    await refused(
      bob,
      alice.publicKey,
      RelayHybridBox(
        pqCiphertext: box.pqCiphertext,
        nonce: box.nonce,
        cipherText: Uint8List.fromList(box.cipherText)..[0] ^= 1,
      ),
      _aad(),
    );
    // An envelope with a classical (X25519-only) box is not mail.
    expect(
      RelayEnvelope.tryParse(<String, dynamic>{
        ...wire,
        'q': base64Url.encode(Uint8List(32)),
      }),
      isNull,
    );
  });

  test('the KEM runs once per recipient key, not per envelope', () async {
    final RelayIdentity alice = await RelayIdentity.generateHybrid();
    final RelayIdentity bob = await RelayIdentity.generateHybrid();
    kem
      ..encapsulations = 0
      ..decapsulations = 0;
    final List<RelayHybridBox> boxes = <RelayHybridBox>[
      for (int i = 0; i < 5; i++)
        await RelayCipher.sealHybrid(
          sender: alice,
          recipient: bob.publicKeys!,
          plaintext: Uint8List.fromList(<int>[i]),
          associatedData: _aad(id: 'r$i'),
        ),
    ];
    expect(kem.encapsulations, 1);
    // Every envelope still gets its own key (its own random nonce).
    expect(
      boxes.map((RelayHybridBox b) => base64Url.encode(b.nonce)).toSet(),
      hasLength(5),
    );
    for (int i = 0; i < 5; i++) {
      expect(
        await RelayCipher.openHybrid(
          recipient: bob,
          senderPublicKey: alice.publicKey,
          box: boxes[i],
          associatedData: _aad(id: 'r$i'),
        ),
        orderedEquals(<int>[i]),
      );
    }
    expect(kem.decapsulations, 1);
  });

  test('a mailbox identity keeps its hybrid key through storage', () async {
    final RelayIdentity identity = await RelayIdentity.generateHybrid();
    final RelayIdentity? back = RelayIdentity.fromJson(
      jsonDecode(jsonEncode(identity.toJson())),
    );
    expect(back?.isHybrid, isTrue);
    expect(back!.pqSeed, orderedEquals(identity.pqSeed!));
    expect(back.pqPublicKey, orderedEquals(identity.pqPublicKey!));
    // Dating and one-off keys stay X25519 only.
    expect((await RelayIdentity.generate()).isHybrid, isFalse);
    expect(
      RelayIdentity.fromJson(<String, dynamic>{
        ...identity.toJson(),
        'qp': base64Url.encode(Uint8List(32)),
      }),
      isNull,
    );
    final RelayPeerInfo peer = RelayPeerInfo(
      address: '200::b',
      publicKey: identity.publicKey,
      pqPublicKey: identity.pqPublicKey,
    );
    expect(RelayPeerInfo.fromJson(peer.toJson())?.keys?.pq, hasLength(1216));
  });
}
