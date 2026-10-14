import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/ed25519_group.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

Future<PyramidRecord> rec(
  String type,
  String py,
  int at,
  List<LedgerKeyPair> signers,
  Map<String, dynamic> fields,
) async {
  PyramidRecord r = PyramidRecord(
    body: <String, dynamic>{
      't': type,
      'py': py,
      'at': at,
      'by': <String>[for (final LedgerKeyPair k in signers) k.id],
      ...fields,
    },
  );
  for (final LedgerKeyPair k in signers) {
    r = await r.signedBy(k);
  }
  return r;
}

Map<String, dynamic> member(
  LedgerKeyPair k,
  String name, {
  String nat = 'PL',
}) => <String, dynamic>{'k': k.id, 'n': name, 'nat': nat, 'dc': 'x'};

void main() {
  test('the Ed25519 scalar of a seed gives its public key', () async {
    final LedgerKeyPair k = await LedgerKeyPair.generate();
    final BigInt a = Ed25519Group.scalarFromSeed(k.seed);
    expect(Ed25519Group.base.times(a).encode(), k.publicKey);
    expect(Ed25519Group.decode(k.publicKey)!.encode(), k.publicKey);
  });

  test(
    'a linkable ring signature hides the signer but links repeats',
    () async {
      final List<LedgerKeyPair> keys = <LedgerKeyPair>[
        await LedgerKeyPair.generate(),
        await LedgerKeyPair.generate(),
        await LedgerKeyPair.generate(),
      ];
      final List<Uint8List> ring = keys
          .map((LedgerKeyPair k) => k.publicKey)
          .toList();
      final List<int> msg = <int>[1, 2, 3];
      final RingSignature sig = RingSignature.sign(
        seed: keys[1].seed,
        ring: ring,
        context: 'c1',
        message: msg,
      );
      expect(sig.verify(ring: ring, context: 'c1', message: msg), isTrue);
      expect(
        sig.verify(ring: ring, context: 'c1', message: <int>[1, 2, 4]),
        isFalse,
      );
      expect(sig.verify(ring: ring, context: 'c2', message: msg), isFalse);
      final RingSignature again = RingSignature.sign(
        seed: keys[1].seed,
        ring: ring,
        context: 'c1',
        message: <int>[9],
      );
      final RingSignature other = RingSignature.sign(
        seed: keys[2].seed,
        ring: ring,
        context: 'c1',
        message: msg,
      );
      final RingSignature elsewhere = RingSignature.sign(
        seed: keys[1].seed,
        ring: ring,
        context: 'c2',
        message: msg,
      );
      expect(again.keyImage, sig.keyImage);
      expect(other.keyImage, isNot(sig.keyImage));
      expect(elsewhere.keyImage, isNot(sig.keyImage));
      final RingSignature back = RingSignature.fromJson(sig.toJson())!;
      expect(back.verify(ring: ring, context: 'c1', message: msg), isTrue);
      final LedgerKeyPair outsider = await LedgerKeyPair.generate();
      expect(
        () => RingSignature.sign(
          seed: outsider.seed,
          ring: ring,
          context: 'c1',
          message: msg,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'admitting, swapping up through cells and a new term at the top',
    () async {
      final LedgerKeyPair s = await LedgerKeyPair.generate();
      final LedgerKeyPair a = await LedgerKeyPair.generate();
      final LedgerKeyPair b = await LedgerKeyPair.generate();
      final LedgerKeyPair a1 = await LedgerKeyPair.generate();
      final LedgerKeyPair a2 = await LedgerKeyPair.generate();
      final PyramidRecord g = await rec(
        PyrT.genesis,
        '',
        1,
        <LedgerKeyPair>[s],
        <String, dynamic>{'name': 'Test', 'founder': member(s, 'S')},
      );
      final String py = g.id;
      final List<PyramidRecord> all = <PyramidRecord>[
        g,
        await rec(
          PyrT.admit,
          py,
          2,
          <LedgerKeyPair>[s, a],
          <String, dynamic>{'head': s.id, 'm': member(a, 'A')},
        ),
        await rec(
          PyrT.admit,
          py,
          3,
          <LedgerKeyPair>[s, b],
          <String, dynamic>{'head': s.id, 'm': member(b, 'B')},
        ),
        await rec(
          PyrT.admit,
          py,
          4,
          <LedgerKeyPair>[a, a1],
          <String, dynamic>{'head': a.id, 'm': member(a1, 'A1')},
        ),
        await rec(
          PyrT.admit,
          py,
          5,
          <LedgerKeyPair>[a, a2],
          <String, dynamic>{'head': a.id, 'm': member(a2, 'A2')},
        ),
        // A third one under A: no room.
        await rec(
          PyrT.admit,
          py,
          6,
          <LedgerKeyPair>[a, s],
          <String, dynamic>{'head': a.id, 'm': member(s, 'X')},
        ),
      ];
      PyramidState st = PyramidState.fold(py, all, now: 100);
      expect(st.pathOf(a.id), '0');
      expect(st.pathOf(b.id), '1');
      expect(st.pathOf(a1.id), '00');
      expect(st.pathOf(a2.id), '01');
      expect(st.rejected.values, contains('już jest w piramidzie'));
      expect(st.treasurers.length, 5);

      // A1 and A2 make A1 the head of cell A: A goes down.
      all.add(
        await rec(
          PyrT.swap,
          py,
          10,
          <LedgerKeyPair>[a1, a2],
          <String, dynamic>{'cell': '0', 'head': a.id, 'up': a1.id},
        ),
      );
      st = PyramidState.fold(py, all, now: 100);
      expect(st.pathOf(a1.id), '0');
      expect(st.pathOf(a.id), '00');
      // One signature is not enough.
      all.add(
        await rec(
          PyrT.swap,
          py,
          11,
          <LedgerKeyPair>[a],
          <String, dynamic>{'cell': '0', 'head': a1.id, 'up': a.id},
        ),
      );
      st = PyramidState.fold(py, all, now: 100);
      expect(st.pathOf(a1.id), '0');
      // A1 and B replace S at the top: a new term.
      all.add(
        await rec(
          PyrT.swap,
          py,
          12,
          <LedgerKeyPair>[a1, b],
          <String, dynamic>{'cell': '', 'head': s.id, 'up': a1.id},
        ),
      );
      st = PyramidState.fold(py, all, now: 100);
      expect(st.head, a1.id);
      expect(st.pathOf(s.id), '0');
      expect(st.term, 2);
      expect(st.lineUp(a2.id), <String>[s.id, a1.id]);
      expect(b64(a.publicKey), a.id);
    },
  );
}
