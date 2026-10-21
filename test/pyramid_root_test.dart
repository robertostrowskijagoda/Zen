import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// One original pyramid pinned in the app, its power key handed from head
/// to head, and "Polecenie": every member brings people in, to a free place
/// of their branch they pick, the head of the cell there co-signs.
const int t0 = 1700000000000;
const int h = 3600 * 1000;

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

Map<String, dynamic> member(LedgerKeyPair k, String name) => <String, dynamic>{
  'k': k.id,
  'pq': k.pqId,
  'n': name,
  'nat': 'PL',
  'yr': 1990,
  'dc': 'x',
};

/// S founds the pyramid with [power]; A and B under S, A1 and A2 under A.
final class Top {
  Top._(this.power, this.s, this.a, this.b, this.a1, this.a2, this.records);

  final LedgerKeyPair power;
  final LedgerKeyPair s;
  final LedgerKeyPair a;
  final LedgerKeyPair b;
  final LedgerKeyPair a1;
  final LedgerKeyPair a2;
  final List<PyramidRecord> records;

  String get py => records.first.id;

  static Future<Top> make() async {
    final List<LedgerKeyPair> k = <LedgerKeyPair>[
      for (int i = 0; i < 6; i++) await LedgerKeyPair.generate(),
    ];
    final PyramidRecord g = await rec(
      PyrT.genesis,
      '',
      t0,
      <LedgerKeyPair>[k[0]],
      <String, dynamic>{'name': 'Test', 'pk': k[0].id},
    );
    final String py = g.id;
    Future<PyramidRecord> admit(int at, int head, int who, String slot) => rec(
      PyrT.admit,
      py,
      at,
      <LedgerKeyPair>[k[head], k[who]],
      <String, dynamic>{
        'sp': k[head].id,
        'head': k[head].id,
        'slot': slot,
        'm': member(k[who], 'P$who'),
      },
    );
    return Top._(k[0], k[1], k[2], k[3], k[4], k[5], <PyramidRecord>[
      g,
      await rec(
        PyrT.found,
        py,
        t0,
        <LedgerKeyPair>[k[0], k[1]],
        <String, dynamic>{'m': member(k[1], 'S')},
      ),
      await admit(t0 + 1, 1, 2, '0'),
      await admit(t0 + 2, 1, 3, '1'),
      await admit(t0 + 3, 2, 4, '00'),
      await admit(t0 + 4, 2, 5, '01'),
    ]);
  }

  PyramidState fold(List<PyramidRecord> more, {int now = t0 + 400 * h}) =>
      PyramidState.fold(py, <PyramidRecord>[...records, ...more], now: now);

  /// A and B make A the head of the pyramid at [at].
  Future<PyramidRecord> swapTop(int at) => rec(
    PyrT.swap,
    py,
    at,
    <LedgerKeyPair>[a, b],
    <String, dynamic>{'cell': '', 'head': s.id, 'up': a.id},
  );

  Future<PyramidRecord> handover(
    int at,
    LedgerKeyPair from,
    LedgerKeyPair to,
    LedgerKeyPair head,
    List<LedgerKeyPair> signers,
  ) => rec(PyrT.handover, py, at, signers, <String, dynamic>{
    'from': from.id,
    'to': to.id,
    'tpq': to.pqId,
    'head': head.id,
  });
}

void main() {
  group('the pinned pyramid', () {
    test('the test pin is a genesis its own power key signed', () async {
      final PyramidRoot root = kZenTestPyramidRoot;
      expect(root.genesis.signers, <String>[root.powerKey]);
      // Signed hybrid by the bridge's Go (tool/zen_pyramid.dart test-pin):
      // the Ed25519 half checks out with this app's composition of what
      // both halves sign, and the ML-DSA key it carries is the one Go
      // derives from the public test seed (the stand-in signer of these
      // tests derives another; the full check needs the bridge).
      final String sig = root.genesis.sigs[root.powerKey]!;
      // Keyed: the genesis is where the power key's ML-DSA key appears.
      expect(sig, hasLength(kKeyedHybridSignatureChars));
      expect(
        await verifyHybridEd25519Half(
          unb64(root.powerKey, length: 32)!,
          hybridDigest(root.genesis.signedBytes),
          decodeHybridSignature(sig)!,
        ),
        isTrue,
      );
      expect(
        hybridSignaturePqId(sig),
        'rFb65WU6BBjm1aJaVwt5m4qoMxCxrhjz9yV4zCdNVB8=',
      );
      // The test pyramid's key is public: its genesis anchors no ML-DSA
      // key. The original pyramid's genesis must (`pq`), or it is no pin.
      expect(root.genesis.body.containsKey('pq'), isFalse);
      expect(PyramidRoot.parse(kZenTestPyramidGenesis), isNull);
      final Map<String, dynamic> anchored =
          jsonDecode(kZenTestPyramidGenesis) as Map<String, dynamic>;
      (anchored['b'] as Map<String, dynamic>)['pq'] =
          'rFb65WU6BBjm1aJaVwt5m4qoMxCxrhjz9yV4zCdNVB8=';
      expect(PyramidRoot.parse(jsonEncode(anchored)), isNotNull);
      final LedgerKeyPair power = await LedgerKeyPair.fromSeed(root.powerSeed!);
      expect(power.id, root.powerKey);
      expect(
        PyramidRoot.parse(
          kZenTestPyramidGenesis,
          powerSeed: root.powerSeed,
        )!.id,
        root.id,
      );
      // Not pinned yet: tests and debug builds use the test pyramid.
      expect(kZenPyramidGenesis, isEmpty);
      expect(zenPyramidRoot?.id, root.id);
    });

    test(
      'the first head is seated once, by the power key and the founder',
      () async {
        final Top w = await Top.make();
        final LedgerKeyPair x = await LedgerKeyPair.generate();
        final PyramidRecord second = await rec(
          PyrT.found,
          w.py,
          t0 + 10,
          <LedgerKeyPair>[w.power, x],
          <String, dynamic>{'m': member(x, 'X')},
        );
        final PyramidState st = w.fold(<PyramidRecord>[second]);
        expect(st.head, w.s.id);
        expect(st.members[w.s.id]!.founder, isTrue);
        expect(st.powerKey, w.power.id);
        expect(st.powerHead, w.s.id);
        expect(st.rejected[second.id], 'piramida ma już szefa');
        // Without the power key nobody founds it.
        final PyramidRecord g = w.records.first;
        final PyramidRecord alone = await rec(
          PyrT.found,
          w.py,
          t0,
          <LedgerKeyPair>[x],
          <String, dynamic>{'m': member(x, 'X')},
        );
        final PyramidState empty = PyramidState.fold(w.py, <PyramidRecord>[
          g,
          alone,
        ], now: t0 + h);
        expect(empty.position, isEmpty);
        expect(empty.rejected[alone.id], 'podpisują klucz władzy i założyciel');
      },
    );

    test('a phone keeps only the pinned pyramid: no other genesis, no other '
        'invitation', () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService b1 = w['B1'];
      final LedgerKeyPair x = await LedgerKeyPair.generate();
      final PyramidRecord other = await rec(
        PyrT.genesis,
        '',
        w.net.now,
        <LedgerKeyPair>[x],
        <String, dynamic>{'name': 'Podróbka', 'pk': x.id},
      );
      expect(await b1.ingest(other), isFalse);
      final PyramidRecord post = await rec(
        PyrT.post,
        other.id,
        w.net.now,
        <LedgerKeyPair>[x],
        <String, dynamic>{'text': 'x', 'lvl': 0},
      );
      expect(await b1.ingest(post), isFalse);
      final String code = w['A'].inviteCode()!;
      expect(b1.invitesHere(code), isTrue);
      final Map<String, String> inv = PyramidService.parseInvite(code)!;
      expect(inv['py'], b1.current);
      // The same invitation to another "pyramid": refused, nothing sent.
      final String elsewhere =
          'zen-pyr:${base64Url.encode(utf8.encode(jsonEncode(<String, String>{...inv, 'py': other.id})))}';
      expect(PyramidService.parseInvite(elsewhere), isNotNull);
      expect(b1.invitesHere(elsewhere), isFalse);
      final int sent = w.net['B1'].outbox.length;
      expect(
        await b1.askToJoin(
          invite: elsewhere,
          myName: 'B1',
          nat: 'PL',
          birthYear: 1990,
          gender: 'k',
        ),
        isFalse,
      );
      expect(w.net['B1'].outbox, hasLength(sent));
    });
  });

  group('the power key', () {
    test('passes to the new head, signed by the old key', () async {
      final Top w = await Top.make();
      final LedgerKeyPair next = await LedgerKeyPair.generate();
      final PyramidRecord swap = await w.swapTop(t0 + h);
      final PyramidRecord byOld = await w.handover(
        t0 + 2 * h,
        w.power,
        next,
        w.a,
        <LedgerKeyPair>[w.power, next, w.a],
      );
      final PyramidState st = w.fold(<PyramidRecord>[swap, byOld]);
      expect(st.head, w.a.id);
      expect(st.powerKey, next.id);
      expect(st.powerHead, w.a.id);
      expect(st.handoverDue, isFalse);
      // An old key never comes back.
      final PyramidRecord back = await w.handover(
        t0 + 3 * h,
        next,
        w.power,
        w.a,
        <LedgerKeyPair>[next, w.power, w.a],
      );
      expect(
        w.fold(<PyramidRecord>[swap, byOld, back]).rejected[back.id],
        'zły nowy klucz władzy',
      );
    });

    test('without the old key: most of the top, but only 72 h after the new '
        'head took the top', () async {
      final Top w = await Top.make();
      final LedgerKeyPair next = await LedgerKeyPair.generate();
      final PyramidRecord swap = await w.swapTop(t0 + h);
      final PyramidRecord early = await w.handover(
        t0 + 2 * h,
        w.power,
        next,
        w.a,
        <LedgerKeyPair>[next, w.a, w.b],
      );
      final PyramidRecord late = await w.handover(
        t0 + h + kPyrHandoverWaitMs,
        w.power,
        next,
        w.a,
        <LedgerKeyPair>[next, w.a, w.b],
      );
      final PyramidState st = w.fold(<PyramidRecord>[swap, early, late]);
      expect(
        st.rejected[early.id],
        'podpisuje dawny klucz władzy (po 72 h: większość szczytu)',
      );
      expect(st.applied, contains(late.id));
      expect(st.powerKey, next.id);
      expect(st.headSince, t0 + h);
    });

    test(
      'only for the head now at the top, signed by the new key and him',
      () async {
        final Top w = await Top.make();
        final LedgerKeyPair next = await LedgerKeyPair.generate();
        final PyramidRecord swap = await w.swapTop(t0 + h);
        final PyramidRecord toB = await w.handover(
          t0 + 2 * h,
          w.power,
          next,
          w.b,
          <LedgerKeyPair>[w.power, next, w.b],
        );
        final PyramidRecord noNewKey = await w.handover(
          t0 + 2 * h + 1,
          w.power,
          next,
          w.a,
          <LedgerKeyPair>[w.power, w.a],
        );
        final PyramidRecord memberKey = await w.handover(
          t0 + 2 * h + 2,
          w.power,
          w.a1,
          w.a,
          <LedgerKeyPair>[w.power, w.a1, w.a],
        );
        final PyramidState st = w.fold(<PyramidRecord>[
          swap,
          toB,
          noNewKey,
          memberKey,
        ]);
        expect(
          st.rejected[toB.id],
          'klucz władzy dostaje obecny szef piramidy',
        );
        expect(
          st.rejected[noNewKey.id],
          'podpisują nowy klucz i szef piramidy',
        );
        expect(st.rejected[memberKey.id], 'zły nowy klucz władzy');
        expect(st.handoverDue, isTrue);
        expect(st.powerKey, w.power.id);
      },
    );

    test(
      'the heads change bottom-up, one cell at a time (a sift-up)',
      () async {
        final Top w = await Top.make();
        // A1 can only reach the top through A's cell first.
        final PyramidRecord jump = await rec(
          PyrT.swap,
          w.py,
          t0 + h,
          <LedgerKeyPair>[w.a1, w.b],
          <String, dynamic>{'cell': '', 'head': w.s.id, 'up': w.a1.id},
        );
        final PyramidRecord upA = await rec(
          PyrT.swap,
          w.py,
          t0 + 2 * h,
          <LedgerKeyPair>[w.a1, w.a2],
          <String, dynamic>{'cell': '0', 'head': w.a.id, 'up': w.a1.id},
        );
        // The next step up a week after the last one.
        final PyramidRecord upTop = await rec(
          PyrT.swap,
          w.py,
          t0 + 2 * h + kPyrRiseCooldownMs,
          <LedgerKeyPair>[w.a1, w.b],
          <String, dynamic>{'cell': '', 'head': w.s.id, 'up': w.a1.id},
        );
        final PyramidState st = w.fold(<PyramidRecord>[jump, upA, upTop]);
        expect(
          st.rejected[jump.id],
          'nowy szef nie jest członkiem tej komórki',
        );
        expect(st.head, w.a1.id);
        expect(st.pathOf(w.s.id), '0', reason: 'one level down');
        expect(st.pathOf(w.a.id), '00');
        expect(st.handoverDue, isTrue);
        expect(st.headSince, t0 + 2 * h + kPyrRiseCooldownMs);
      },
    );
  });

  group('"Polecenie"', () {
    test('a sponsor picks a free place of its own branch; the head of the '
        'cell there co-signs', () async {
      final Top w = await Top.make();
      final LedgerKeyPair z = await LedgerKeyPair.generate();
      Future<PyramidRecord> admit(
        int at,
        LedgerKeyPair sponsor,
        LedgerKeyPair head,
        String slot,
        List<LedgerKeyPair> signers,
      ) => rec(PyrT.admit, w.py, at, signers, <String, dynamic>{
        'sp': sponsor.id,
        'head': head.id,
        'slot': slot,
        'm': member(z, 'Z'),
      });
      final PyramidState before = w.fold(const <PyramidRecord>[]);
      expect(before.freePlaces(''), <String>[
        '10',
        '11',
        '000',
        '001',
        '010',
        '011',
      ]);
      expect(before.freePlaces('1'), <String>['10', '11']);
      final PyramidRecord outside = await admit(
        t0 + 10,
        w.b,
        w.a1,
        '000',
        <LedgerKeyPair>[w.b, w.a1, z],
      );
      final PyramidRecord taken = await admit(
        t0 + 11,
        w.s,
        w.a,
        '01',
        <LedgerKeyPair>[w.s, w.a, z],
      );
      final PyramidRecord wrongHead = await admit(
        t0 + 12,
        w.s,
        w.a,
        '000',
        <LedgerKeyPair>[w.s, w.a, z],
      );
      final PyramidRecord noHead = await admit(
        t0 + 13,
        w.s,
        w.a1,
        '000',
        <LedgerKeyPair>[w.s, z],
      );
      final PyramidRecord ok = await admit(
        t0 + 14,
        w.s,
        w.a1,
        '000',
        <LedgerKeyPair>[w.s, w.a1, z],
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        outside,
        taken,
        wrongHead,
        noHead,
        ok,
      ]);
      expect(st.rejected[outside.id], 'miejsce spoza gałęzi polecającego');
      expect(st.rejected[taken.id], 'to miejsce nie jest wolne');
      expect(st.rejected[wrongHead.id], 'szef komórki już inny');
      expect(
        st.rejected[noHead.id],
        'podpisują polecający, nowa osoba i szef komórki',
      );
      expect(st.pathOf(z.id), '000');
      expect(st.members[z.id]!.admittedBy, w.s.id);
      expect(st.canVote(z.id, t0 + 14), isFalse);
    });

    test('no limit: the head of the pyramid brings in one after another; '
        'a ban on admitting stops it', () async {
      final Top w = await Top.make();
      final List<PyramidRecord> more = <PyramidRecord>[];
      final PyramidState start = w.fold(const <PyramidRecord>[]);
      final List<String> places = start.freePlaces('', limit: 6);
      for (int i = 0; i < places.length; i++) {
        final LedgerKeyPair z = await LedgerKeyPair.generate();
        final String head = start.occupant[PyrPath.parent(places[i])]!;
        final LedgerKeyPair headKey = <LedgerKeyPair>[
          w.s,
          w.a,
          w.b,
          w.a1,
          w.a2,
        ].firstWhere((LedgerKeyPair k) => k.id == head);
        more.add(
          await rec(
            PyrT.admit,
            w.py,
            t0 + 10 + i,
            <LedgerKeyPair>{w.s, headKey, z}.toList(),
            <String, dynamic>{
              'sp': w.s.id,
              'head': head,
              'slot': places[i],
              'm': member(z, 'Z$i'),
            },
          ),
        );
      }
      PyramidState st = w.fold(more);
      expect(st.members, hasLength(5 + places.length));
      final PyramidRecord ban = await rec(
        PyrT.ban,
        w.py,
        t0 + 100,
        // 2 of the top, and A2's own cell (immunity).
        <LedgerKeyPair>[w.s, w.a, w.a1],
        <String, dynamic>{'target': w.a2.id, 'kind': 'noadmit', 'reason': ''},
      );
      final LedgerKeyPair y = await LedgerKeyPair.generate();
      final PyramidRecord byA2 = await rec(
        PyrT.admit,
        w.py,
        t0 + 101,
        <LedgerKeyPair>[w.a2, y],
        <String, dynamic>{
          'sp': w.a2.id,
          'head': w.a2.id,
          'slot': st.freePlaces(st.pathOf(w.a2.id)!).first,
          'm': member(y, 'Y'),
        },
      );
      st = w.fold(<PyramidRecord>[...more, ban, byA2]);
      expect(st.rejected[byA2.id], 'polecający ma zakaz przyjmowania');
    });
  });

  group('the ML-DSA half of every key is fixed by the records', () {
    /// [r] with [key]'s signature swapped for one by [other]: what a
    /// forger who can make Ed25519 signatures (a quantum computer) but
    /// not the ML-DSA half of [key] would bring — the fold only compares
    /// which ML-DSA key a signature carries (signatures are checked on
    /// arrival).
    Future<PyramidRecord> foreign(
      PyramidRecord r,
      String key,
      LedgerKeyPair other,
    ) async => r.withSig(key, (await r.signedBy(other)).sigs[other.id]!);

    test('a member signs with the ML-DSA key it was admitted with', () async {
      final Top w = await Top.make();
      final LedgerKeyPair forger = await LedgerKeyPair.generate();
      final PyramidState before = w.fold(const <PyramidRecord>[]);
      expect(before.members[w.a.id]!.pq, w.a.pqId);
      final PyramidRecord swap = await w.swapTop(t0 + h);
      final PyramidRecord forged = await foreign(swap, w.a.id, forger);
      final PyramidState st = w.fold(<PyramidRecord>[forged]);
      expect(
        st.rejected[forged.id],
        'podpis innym kluczem ML-DSA niż klucz osoby',
      );
      expect(st.head, w.s.id);
      expect(w.fold(<PyramidRecord>[swap]).head, w.a.id);
    });

    test(
      'a newcomer signs the admission with the ML-DSA key it names',
      () async {
        final Top w = await Top.make();
        final LedgerKeyPair x = await LedgerKeyPair.generate();
        final LedgerKeyPair forger = await LedgerKeyPair.generate();
        final PyramidRecord admit = await rec(
          PyrT.admit,
          w.py,
          t0 + h,
          <LedgerKeyPair>[w.a1, x],
          <String, dynamic>{
            'sp': w.a1.id,
            'head': w.a1.id,
            'slot': '000',
            'm': member(x, 'X'),
          },
        );
        final PyramidRecord forged = await foreign(admit, x.id, forger);
        expect(
          w.fold(<PyramidRecord>[forged]).rejected[forged.id],
          'nowa osoba podpisuje innym kluczem ML-DSA',
        );
        // Without its ML-DSA fingerprint nobody is admitted.
        final PyramidRecord bare = await rec(
          PyrT.admit,
          w.py,
          t0 + h,
          <LedgerKeyPair>[w.a1, x],
          <String, dynamic>{
            'sp': w.a1.id,
            'head': w.a1.id,
            'slot': '000',
            'm': member(x, 'X')..remove('pq'),
          },
        );
        expect(w.fold(<PyramidRecord>[bare]).isMember(x.id), isFalse);
        expect(w.fold(<PyramidRecord>[admit]).isMember(x.id), isTrue);
      },
    );

    test(
      'the power key: anchored by the genesis and by every handover',
      () async {
        final List<LedgerKeyPair> k = <LedgerKeyPair>[
          for (int i = 0; i < 2; i++) await LedgerKeyPair.generate(),
        ];
        final LedgerKeyPair forger = await LedgerKeyPair.generate();
        final PyramidRecord g = await rec(
          PyrT.genesis,
          '',
          t0,
          <LedgerKeyPair>[k[0]],
          <String, dynamic>{'name': 'Test', 'pk': k[0].id, 'pq': k[0].pqId},
        );
        final PyramidRecord found = await rec(
          PyrT.found,
          g.id,
          t0 + 1,
          <LedgerKeyPair>[k[0], k[1]],
          <String, dynamic>{'m': member(k[1], 'S')},
        );
        PyramidState fold(List<PyramidRecord> more) => PyramidState.fold(
          g.id,
          <PyramidRecord>[g, ...more],
          now: t0 + 400 * h,
        );
        expect(fold(<PyramidRecord>[found]).powerKeyPq, k[0].pqId);
        expect(fold(<PyramidRecord>[found]).head, k[1].id);
        final PyramidRecord forged = await foreign(found, k[0].id, forger);
        final PyramidState st = fold(<PyramidRecord>[forged]);
        expect(
          st.rejected[forged.id],
          'podpis innym kluczem ML-DSA niż klucz osoby',
        );
        expect(st.head, isNull);

        // A handover names the new key's ML-DSA half; its signature must
        // carry that very key.
        final Top w = await Top.make();
        final LedgerKeyPair next = await LedgerKeyPair.generate();
        final PyramidRecord swap = await w.swapTop(t0 + h);
        final PyramidRecord byOld = await w.handover(
          t0 + 2 * h,
          w.power,
          next,
          w.a,
          <LedgerKeyPair>[w.power, next, w.a],
        );
        final PyramidState handed = w.fold(<PyramidRecord>[swap, byOld]);
        expect(handed.powerKey, next.id);
        expect(handed.powerKeyPq, next.pqId);
        final PyramidRecord wrongPq = await rec(
          PyrT.handover,
          w.py,
          t0 + 2 * h,
          <LedgerKeyPair>[w.power, next, w.a],
          <String, dynamic>{
            'from': w.power.id,
            'to': next.id,
            'tpq': forger.pqId,
            'head': w.a.id,
          },
        );
        expect(
          w.fold(<PyramidRecord>[swap, wrongPq]).rejected[wrongPq.id],
          'zły odcisk nowego klucza władzy',
        );
        final PyramidRecord forgedNew = await foreign(byOld, next.id, forger);
        expect(
          w.fold(<PyramidRecord>[swap, forgedNew]).rejected[forgedNew.id],
          'zły odcisk nowego klucza władzy',
        );
      },
    );
  });
}
