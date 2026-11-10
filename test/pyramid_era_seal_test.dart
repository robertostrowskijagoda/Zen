import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The time an operation or a change of the tree claims is no source of
/// power: the eras of the treasurers are sealed by the treasurers after
/// them, an operation dated into a sealed era counts only when its seal
/// lists it, a change of the tree dated back into one folds after the
/// seals, and a late change of the treasurers does not move the era of a
/// payment on the phones that were there. Every phone also counts only
/// what an honest treasurer would have signed.
void main() {
  const int t0 = FoldWorld.t0;
  const int h = FoldWorld.hour;
  const int day = FoldWorld.day;
  // S is funded at t0 + day, credited a day later (before start).
  const int start = t0 + 2 * day + h;
  // Z joins under B (level 2: a treasurer): the eighth era ends.
  const int zAt = start + 2 * h;

  late FoldWorld w;
  late LedgerKeyPair z;
  late PyramidRecord admitZ;

  setUp(() async {
    w = await FoldWorld.make();
    z = await LedgerKeyPair.generate();
    admitZ = await signedRecord(
      PyrT.admit,
      w.py,
      zAt,
      <LedgerKeyPair>[w['B'], z],
      <String, dynamic>{
        'sp': w.id('B'),
        'head': w.id('B'),
        'slot': '11',
        'm': memberData(z, 'Z'),
      },
    );
  });

  Future<PyramidRecord> order(
    int at,
    String from,
    String to,
    int amount,
    int seq, {
    FoldWorld? world,
  }) {
    final FoldWorld x = world ?? w;
    return x.rec(
      PyrT.transfer,
      at,
      <String>[from],
      <String, dynamic>{
        'from': x.id(from),
        'to': x.id(to),
        'amount': amount,
        'seq': seq,
        'memo': '',
      },
    );
  }

  /// [op] with the treasurer signatures of [who].
  Future<PyramidRecord> signed(
    PyramidRecord op,
    List<String> who, {
    FoldWorld? world,
  }) async {
    final FoldWorld x = world ?? w;
    PyramidRecord r = op;
    for (final String n in who) {
      r = r.withTreasurerSig(
        x.id(n),
        b64(await x[n].sign(PyramidRecord.treasurerBytes(op.id))),
      );
    }
    return r;
  }

  /// [amount] emitted to [who] at t0 + day, its note in [l].
  Future<PyramidRecord> fund(
    PyrLedger l,
    String who,
    int amount, {
    FoldWorld? world,
  }) {
    final FoldWorld x = world ?? w;
    final PyrEmitNote note = PyrEmitNote(
      rc: pyrEmitCommit(x.id(who), 'sol-$who'),
      to: x.id(who),
      salt: 'sol-$who',
    );
    l.mergeNote(note);
    return x.rec(
      PyrT.emit,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'rc': note.rc, 'amount': amount},
    );
  }

  /// The seals honest treasurers make, era after era, of [records] as
  /// they count with ledger [l] (all who sign of the next era sign, of
  /// [keys] and [more]): until [upTo] (the era's end), or every era that
  /// ended.
  Future<List<PyramidRecord>> sealEras(
    List<PyramidRecord> records,
    PyrLedger l, {
    FoldWorld? world,
    int now = t0 + 400 * day,
    Map<String, int> late = const <String, int>{},
    List<LedgerKeyPair> more = const <LedgerKeyPair>[],
    Set<String> refuse = const <String>{},
    int? upTo,
  }) async {
    final FoldWorld x = world ?? w;
    final Map<String, LedgerKeyPair> byId = <String, LedgerKeyPair>{
      for (final LedgerKeyPair k in x.keys.values) k.id: k,
      for (final LedgerKeyPair k in more) k.id: k,
    };
    final List<PyramidRecord> out = <PyramidRecord>[];
    while (true) {
      final PyramidState s = x.fold(
        <PyramidRecord>[...records, ...out],
        now: now,
        late: late,
      );
      final PyrEraToSeal? era = s.unsealedEra;
      if (era == null || (upTo != null && era.to > upTo)) {
        return out;
      }
      final PyrLedgerView v = l.compute(s, whole: true);
      PyramidRecord r = PyramidRecord(
        body: PyrSeal.body(
          pyramid: x.py,
          n: era.n,
          prev: era.prev,
          from: era.from,
          to: era.to,
          set: era.set,
          next: era.next,
          ops: l.countedBetween(v, era.from, era.to),
          changes: era.changes,
        ),
      );
      for (final String k in era.next) {
        final LedgerKeyPair? pair = byId[k];
        if (pair != null && !refuse.contains(k)) {
          r = await r.signedBy(pair);
        }
      }
      out.add(r);
    }
  }

  const List<String> five = <String>['S', 'A', 'B', 'A1', 'A2'];

  group('operations dated back into a sealed era count nowhere', () {
    test('the founder alone mints nothing by dating an order into the '
        'first era, which the era after sealed', () async {
      final PyrLedger l = PyrLedger();
      final List<PyramidRecord> seals = await sealEras(<PyramidRecord>[], l);
      expect(seals, hasLength(7));
      final PyramidState st = w.fold(seals, now: start);
      expect(st.seals, hasLength(7));
      expect(st.sealedTo, t0 + 7);
      expect(st.treasurersAt(t0), <String>[w.id('S')]);
      final PyramidRecord mint = await signed(
        await order(t0, 'S', 'Y', kPyrMaxAmount, 777),
        <String>['S'],
      );
      l.merge(mint);
      expect(PyrLedger.isFinal(mint, st), isFalse);
      for (final bool whole in <bool>[false, true]) {
        final PyrLedgerView v = l.compute(st, whole: whole);
        expect(v.balanceOf(w.id('Y')), 0);
        expect(v.balanceOf(w.id('S')), 0);
        expect(v.counted, isNot(contains(mint.id)));
      }
      // Y has nothing to spend: no honest treasurer signs.
      final PyramidRecord spend = await order(start, 'Y', 'B1', 5000, 1);
      expect(
        PyrLedger.problem(spend, st, l.compute(st, whole: true), start),
        'za mało środków',
      );
    });

    test('the first era\'s treasurer takes back no payment by dating its own '
        'copy of the number into its era: caught signing both', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'S', 1000);
      final List<PyramidRecord> seals = await sealEras(<PyramidRecord>[e], l);
      final PyramidState st = w.fold(<PyramidRecord>[e, ...seals], now: start);
      final PyramidRecord honest = await order(start, 'S', 'B1', 800, 1);
      expect(PyrLedger.problem(honest, st, l.compute(st), start), isNull);
      l.merge(await signed(honest, five));
      final PyramidRecord back = await signed(
        await order(t0, 'S', 'Y', 800, 1),
        <String>['S'],
      );
      l.merge(back);
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('B1')), 800);
      expect(v.balanceOf(w.id('Y')), 0);
      expect(v.balanceOf(w.id('S')), 200);
      expect(v.counted, contains(honest.id));
      expect(v.cheaters.keys, contains(w.id('S')));
    });

    test('a payer and the first era\'s treasurer take back no payment the '
        'first era\'s treasurer never signed', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'B1', 1000);
      final List<PyramidRecord> seals = await sealEras(<PyramidRecord>[e], l);
      final PyramidState st = w.fold(<PyramidRecord>[e, ...seals], now: start);
      final PyramidRecord honest = await order(start, 'B1', 'A2', 800, 1);
      l.merge(await signed(honest, <String>['A', 'B', 'A1', 'A2', 'X']));
      l.merge(await signed(await order(t0, 'B1', 'Y', 800, 1), <String>['S']));
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('A2')), 800);
      expect(v.balanceOf(w.id('Y')), 0);
    });

    test('a former majority of an era with money in it replaces no payment: '
        'only the seal stops it, and they are caught', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'S', 1000);
      // The eighth era (all eight) ends when Z joins; the ninth seals it.
      final List<PyramidRecord> seals = await sealEras(
        <PyramidRecord>[e, admitZ],
        l,
        more: <LedgerKeyPair>[z],
        now: zAt + day,
      );
      expect(seals, hasLength(8));
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        admitZ,
        ...seals,
      ], now: zAt + day);
      expect(st.sealedTo, zAt);
      // S pays B1, number 1, in the ninth era: five of nine sign.
      final PyramidRecord honest = await order(zAt + h, 'S', 'B1', 800, 1);
      l.merge(await signed(honest, five));
      // Later the same five, a majority of the eighth era, date S's
      // number 1 into their era (S had the money then).
      final PyramidRecord back = await signed(
        await order(start, 'S', 'Y', 800, 1),
        five,
      );
      l.merge(back);
      expect(PyrLedger.breaks(back, st), isNull);
      expect(PyrLedger.isFinal(back, st), isFalse);
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('B1')), 800);
      expect(v.balanceOf(w.id('Y')), 0);
      expect(v.broken[back.id], 'poza pieczęcią swojej ery');
      expect(
        v.cheaters.keys,
        containsAll(<String>[for (final String n in five) w.id(n)]),
      );
    });

    test('an operation that counted in its era counts on a phone that gets '
        'it after the seal; one that did not count in time never does, '
        'and its number is free again', () async {
      final PyrLedger treasurer = PyrLedger();
      final PyramidRecord e = await fund(treasurer, 'S', 1000);
      // Final in the eighth era.
      final PyramidRecord paid = await signed(
        await order(start, 'S', 'B1', 300, 1),
        five,
      );
      treasurer.merge(paid);
      // Signed by only four of eight before the era ended.
      final PyramidRecord unfinished = await order(start + h, 'S', 'A2', 50, 2);
      treasurer.merge(await signed(unfinished, <String>['S', 'A', 'B', 'A1']));
      final List<PyramidRecord> seals = await sealEras(
        <PyramidRecord>[e, admitZ],
        treasurer,
        more: <LedgerKeyPair>[z],
        now: zAt + day,
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        admitZ,
        ...seals,
      ], now: zAt + day);
      expect(st.seals.last.ops, <String>{paid.id});
      // B1 keeps only what concerns it; the payment reaches it late.
      final PyrLedger b1 = PyrLedger()..merge(paid);
      expect(b1.compute(st).balanceOf(w.id('B1')), 300);
      // A fifth signature, made in time, comes after the seal: still
      // nothing.
      treasurer.merge(await signed(unfinished, <String>['A2']));
      expect(PyrLedger.isFinal(treasurer.ops[unfinished.id]!, st), isFalse);
      final PyrLedgerView v = treasurer.compute(st, whole: true);
      expect(v.balanceOf(w.id('A2')), 0);
      expect(v.balanceOf(w.id('S')), 700);
      expect(v.counted, isNot(contains(unfinished.id)));
      // S orders again now, with the number that stayed free.
      expect(v.seqOf(w.id('S')), 1);
      final PyramidRecord again = await order(zAt + h, 'S', 'A2', 50, 2);
      expect(PyrLedger.problem(again, st, v, zAt + h), isNull);
    });
  });

  group('a late change of the treasurers undoes no payment', () {
    /// B1 admits two keys of its own under itself (level 3: treasurers),
    /// dated an hour before [at].
    Future<List<PyramidRecord>> admitTwo(
      int at,
      List<LedgerKeyPair> keys,
    ) async => <PyramidRecord>[
      for (final (int i, LedgerKeyPair p) in keys.indexed)
        await signedRecord(
          PyrT.admit,
          w.py,
          at - h,
          <LedgerKeyPair>[w['B1'], p],
          <String, dynamic>{
            'sp': w.id('B1'),
            'head': w.id('B1'),
            'slot': '10$i',
            'm': memberData(p, 'P$i'),
          },
        ),
    ];

    test(
      'admissions dated back by a head: the phones that were there fold '
      'them when they came, the seal then fixes it for every phone',
      () async {
        final PyrLedger l = PyrLedger();
        final PyramidRecord e = await fund(l, 'B1', 1000);
        final PyramidRecord pay = await order(start, 'B1', 'A2', 800, 1);
        final PyramidState before = w.fold(<PyramidRecord>[e], now: start);
        expect(
          PyrLedger.problem(pay, before, l.compute(before), start),
          isNull,
        );
        l.merge(await signed(pay, five));
        final List<LedgerKeyPair> keys = <LedgerKeyPair>[
          await LedgerKeyPair.generate(),
          await LedgerKeyPair.generate(),
        ];
        final List<PyramidRecord> admits = await admitTwo(start, keys);
        final List<PyramidRecord> all = <PyramidRecord>[e, ...admits];
        // A phone that was there saw them a day later.
        final Map<String, int> late = <String, int>{
          for (final PyramidRecord a in admits) a.id: start + day,
        };
        final PyramidState there = w.fold(all, now: start + day, late: late);
        expect(there.rejected, isEmpty);
        expect(there.treasurers, hasLength(10));
        expect(there.treasurersAt(start), hasLength(8));
        expect(PyrLedger.isFinal(l.ops[pay.id]!, there), isTrue);
        expect(l.compute(there).balanceOf(w.id('A2')), 800);
        expect(l.compute(there).balanceOf(w.id('B1')), 200);
        // The ten seal the eighth era (the head's own two do not sign); a
        // phone that was not there folds the records and the seals.
        final List<PyramidRecord> seals = await sealEras(
          all,
          l,
          late: late,
          now: start + day + h,
          more: keys,
          refuse: <String>{for (final LedgerKeyPair k in keys) k.id},
        );
        expect(
          seals.last.body['ch'],
          unorderedEquals(<String>[for (final PyramidRecord a in admits) a.id]),
        );
        final PyramidState fresh = w.fold(<PyramidRecord>[
          ...all,
          ...seals,
        ], now: start + day + h);
        expect(fresh.seals, hasLength(8));
        expect(fresh.treasurersAt(start), hasLength(8));
        expect(fresh.treasurers, hasLength(10));
        expect(PyrLedger.isFinal(l.ops[pay.id]!, fresh), isTrue);
        expect(l.compute(fresh).balanceOf(w.id('A2')), 800);
        expect(l.compute(fresh).balanceOf(w.id('B1')), 200);
      },
    );

    test('admissions dated back into an era already sealed fold after the '
        'seals on every phone', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'B1', 1000);
      final PyramidRecord pay = await signed(
        await order(start, 'B1', 'A2', 800, 1),
        five,
      );
      l.merge(pay);
      final List<PyramidRecord> seals = await sealEras(
        <PyramidRecord>[e, admitZ],
        l,
        more: <LedgerKeyPair>[z],
        now: zAt + h,
      );
      expect(seals.last.body['ops'], <String>[pay.id]);
      final List<LedgerKeyPair> keys = <LedgerKeyPair>[
        await LedgerKeyPair.generate(),
        await LedgerKeyPair.generate(),
      ];
      final List<PyramidRecord> admits = await admitTwo(start, keys);
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        admitZ,
        ...seals,
        ...admits,
      ], now: zAt + day);
      expect(st.seals, hasLength(8));
      for (final PyramidRecord a in admits) {
        expect(st.applied, contains(a.id));
      }
      expect(st.treasurers, hasLength(11));
      expect(st.treasurersAt(start), hasLength(8));
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('A2')), 800);
      expect(v.balanceOf(w.id('B1')), 200);
      expect(v.seqOf(w.id('B1')), 1);
    });

    test('a treasurer who co-signed leaves with a time before the payment: '
        'the payment stands', () async {
      final FoldWorld w7 = await FoldWorld.make(tree: kFoldTree.sublist(0, 7));
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'B1', 1000, world: w7);
      final PyramidRecord pay = await signed(
        await order(start, 'B1', 'A2', 800, 1, world: w7),
        <String>['S', 'A', 'B', 'X'],
        world: w7,
      );
      l.merge(pay);
      final PyramidRecord leave = await w7.rec(
        PyrT.leave,
        start - h,
        <String>['X'],
        <String, dynamic>{'k': w7.id('X')},
      );
      // The phones that were there.
      final Map<String, int> late = <String, int>{leave.id: start + day};
      final PyramidState there = w7.fold(
        <PyramidRecord>[e, leave],
        now: start + day,
        late: late,
      );
      expect(there.rejected, isEmpty);
      expect(l.compute(there).balanceOf(w7.id('A2')), 800);
      expect(l.compute(there).balanceOf(w7.id('B1')), 200);
      // Every phone, once the six after it sealed the era.
      final List<PyramidRecord> seals = await sealEras(
        <PyramidRecord>[e, leave],
        l,
        world: w7,
        late: late,
        now: start + day + h,
      );
      final PyramidState fresh = w7.fold(<PyramidRecord>[
        e,
        leave,
        ...seals,
      ], now: start + day + h);
      expect(fresh.treasurers, hasLength(6));
      expect(l.compute(fresh).balanceOf(w7.id('A2')), 800);
      expect(l.compute(fresh).balanceOf(w7.id('B1')), 200);
    });

    test(
      'a leave dated back into a sealed era folds after the seals',
      () async {
        final FoldWorld w7 = await FoldWorld.make(
          tree: kFoldTree.sublist(0, 7),
        );
        final PyrLedger l = PyrLedger();
        final PyramidRecord e = await fund(l, 'B1', 1000, world: w7);
        final PyramidRecord pay = await signed(
          await order(start, 'B1', 'A2', 800, 1, world: w7),
          <String>['S', 'A', 'B', 'X'],
          world: w7,
        );
        l.merge(pay);
        // Y joins under A1 (level 3) at zAt: the seventh era ends.
        final PyramidRecord admitY = await signedRecord(
          PyrT.admit,
          w7.py,
          zAt,
          <LedgerKeyPair>[w7['A1'], z],
          <String, dynamic>{
            'sp': w7.id('A1'),
            'head': w7.id('A1'),
            'slot': '001',
            'm': memberData(z, 'Z'),
          },
        );
        final List<PyramidRecord> seals = await sealEras(
          <PyramidRecord>[e, admitY],
          l,
          world: w7,
          more: <LedgerKeyPair>[z],
          now: zAt + h,
        );
        final PyramidRecord leave = await w7.rec(
          PyrT.leave,
          start - h,
          <String>['X'],
          <String, dynamic>{'k': w7.id('X')},
        );
        final PyramidState st = w7.fold(<PyramidRecord>[
          e,
          admitY,
          ...seals,
          leave,
        ], now: zAt + day);
        expect(st.seals, hasLength(seals.length));
        expect(st.applied, contains(leave.id));
        expect(st.isMember(w7.id('X')), isFalse);
        expect(l.compute(st).balanceOf(w7.id('A2')), 800);
        expect(l.compute(st).balanceOf(w7.id('B1')), 200);
      },
    );
  });

  group('seals', () {
    test('a seal holds only as the era it seals: signed by most of the '
        'treasurers after it, the treasurers of the tree, one after the '
        'other', () async {
      final List<PyramidRecord> good = await sealEras(
        <PyramidRecord>[],
        PyrLedger(),
        upTo: t0 + 1,
      );
      expect(good, hasLength(1));
      // Signed by S alone: one of the two after the first era.
      final PyramidRecord half = await PyramidRecord(
        body: good.single.body,
      ).signedBy(w['S']);
      expect(
        w.fold(<PyramidRecord>[half]).rejected[half.id],
        'pieczęć podpisuje większość następnych skarbników',
      );
      // Names others as the next treasurers, who sign it.
      final PyramidRecord forged = await PyramidRecord(
        body: <String, dynamic>{
          ...good.single.body,
          'by': <String>[w.id('Y')],
        },
      ).signedBy(w['Y']);
      expect(
        w.fold(<PyramidRecord>[forged]).rejected[forged.id],
        'pieczęć nie zgadza się z drzewem',
      );
      // The second era before the first.
      final List<PyramidRecord> two = await sealEras(
        <PyramidRecord>[],
        PyrLedger(),
        upTo: t0 + 2,
      );
      final PyramidState alone = w.fold(<PyramidRecord>[two.last]);
      expect(alone.rejected[two.last.id], 'pieczęć nie po kolei');
      expect(alone.seals, isEmpty);
      expect(w.fold(two).seals, hasLength(2));
    });

    test('two seals of one era: the first stands, who signed both is '
        'caught', () async {
      final PyramidRecord one = await sealEras(
        <PyramidRecord>[],
        PyrLedger(),
        upTo: t0 + 1,
      ).then((List<PyramidRecord> l) => l.single);
      PyramidRecord other = PyramidRecord(
        body: <String, dynamic>{
          ...one.body,
          'ops': <String>['0' * 64],
        },
      );
      other = await (await other.signedBy(w['S'])).signedBy(w['A']);
      final PyramidState st = w.fold(<PyramidRecord>[one, other]);
      final String first = one.id.compareTo(other.id) < 0 ? one.id : other.id;
      final String second = first == one.id ? other.id : one.id;
      expect(st.seals.single.id, first);
      expect(st.rejected[second], 'era już zapieczętowana');
      expect(
        st.sealCheaters.keys,
        unorderedEquals(<String>[w.id('S'), w.id('A')]),
      );
      expect(st.sealCheaters[w.id('S')], <String>{first, second});
    });

    test('a member who joins after several sealed eras reads the sealed '
        'past and sees what is paid to them count', () async {
      final PyrLedger treasurer = PyrLedger();
      final PyramidRecord e = await fund(treasurer, 'S', 1000);
      final PyramidRecord old = await signed(
        await order(start, 'S', 'B1', 100, 1),
        five,
      );
      treasurer.merge(old);
      final List<PyramidRecord> seals = await sealEras(
        <PyramidRecord>[e, admitZ],
        treasurer,
        more: <LedgerKeyPair>[z],
        now: zAt + h,
      );
      // Q joins under A2 a day later (level 3: a treasurer).
      final LedgerKeyPair q = await LedgerKeyPair.generate();
      final PyramidRecord admitQ = await signedRecord(
        PyrT.admit,
        w.py,
        zAt + day,
        <LedgerKeyPair>[w['A2'], q],
        <String, dynamic>{
          'sp': w.id('A2'),
          'head': w.id('A2'),
          'slot': '010',
          'm': memberData(q, 'Q'),
        },
      );
      // What Q's phone gets: every record, and its own payments.
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        admitZ,
        ...seals,
        admitQ,
      ], now: zAt + 2 * day);
      expect(st.seals, hasLength(8));
      expect(st.treasurers, contains(q.id));
      expect(st.treasurersAt(t0), <String>[w.id('S')]);
      expect(st.treasurersAt(start), hasLength(8));
      expect(st.treasurersAt(zAt + h), hasLength(9));
      expect(PyrLedger.isFinal(old, st), isTrue);
      expect(st.unsealedEra?.n, 9);
      expect(st.unsealedEra?.to, zAt + day);
      // Paid by S after Q joined.
      final PyramidRecord toQ = PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.transfer,
          'py': w.py,
          'at': zAt + day + h,
          'by': <String>[w.id('S')],
          'from': w.id('S'),
          'to': q.id,
          'amount': 200,
          'seq': 2,
          'memo': '',
        },
      );
      final PyramidRecord paid = await signed(
        await toQ.signedBy(w['S']),
        <String>[...five, 'X'],
      );
      final PyrLedger mine = PyrLedger()..merge(paid);
      expect(mine.compute(st).balanceOf(q.id), 200);
      treasurer.merge(paid);
      final PyrLedgerView v = treasurer.compute(st, whole: true);
      expect(v.balanceOf(q.id), 200);
      expect(v.balanceOf(w.id('S')), 700);
    });
  });

  test('the treasurers\' apps seal every era that ended; a phone that was '
      'offline meanwhile gets the seals and reads the same past', () async {
    final PyramidWorld net = await PyramidWorld.six();
    // Five eras: S and A (admitted at the founding's millisecond), then
    // one more treasurer at each admission. B1 is away while the others
    // seal.
    net.net.holdForOffline = false;
    net.net.setOnline(net.net['B1'], false);
    await net.net.advance(const Duration(hours: 2));
    // The treasurers offer their ledgers to each other, then seal.
    await net.duties(rounds: 1);
    expect(net['S'].state!.seals, isEmpty);
    await net.net.advance(const Duration(minutes: 15));
    await net.duties(rounds: 8);
    await net.sync();
    final PyramidState s = net['S'].state!;
    expect(s.seals, hasLength(4));
    expect(s.unsealedEra, isNull);
    expect(
      s.seals.first.set,
      <String>[net['S'].myKey!, net['A'].myKey!]..sort(),
    );
    expect(s.treasurersAt(s.seals.first.from), s.seals.first.set);
    for (final String n in <String>['A', 'B', 'A1', 'A2']) {
      expect(
        <String>[for (final PyrSeal x in net[n].state!.seals) x.id],
        <String>[for (final PyrSeal x in s.seals) x.id],
        reason: n,
      );
    }
    expect(net['B1'].state!.seals, isEmpty);
    net.net.setOnline(net.net['B1'], true);
    await net.sync();
    expect(
      <String>[for (final PyrSeal x in net['B1'].state!.seals) x.id],
      <String>[for (final PyrSeal x in s.seals) x.id],
    );
    expect(net.views().values.toSet(), hasLength(1));
  });

  test('every phone counts only what an honest treasurer would sign: an '
      'uncovered order with a gap in its numbers, or to an outsider, counts '
      'nowhere however many treasurers signed it', () async {
    final PyrLedger l = PyrLedger();
    final PyramidState st = w.fold(<PyramidRecord>[], now: start);
    // To somebody who is no member: refused on every phone.
    final LedgerKeyPair outsider = await LedgerKeyPair.generate();
    final PyramidRecord x = await signed(
      await w.rec(
        PyrT.transfer,
        start,
        <String>['A1'],
        <String, dynamic>{
          'from': w.id('A1'),
          'to': outsider.id,
          'amount': 123456,
          'seq': 50,
          'memo': '',
        },
      ),
      five,
    );
    expect(PyrLedger.problem(x, st, l.compute(st), start), isNotNull);
    l.merge(x);
    for (final bool whole in <bool>[false, true]) {
      final PyrLedgerView v = l.compute(st, whole: whole);
      expect(v.counted, isNot(contains(x.id)));
      expect(v.balanceOf(outsider.id), 0);
      expect(v.balanceOf(w.id('A1')), 0);
      expect(v.broken[x.id], 'zły przelew');
    }
    // To a member, with nothing there and number 50: refused on the
    // treasurers' whole ledgers, whose statements every member goes by.
    final PyramidRecord y = await signed(
      await order(start + 1, 'A1', 'B1', 123456, 50),
      five,
    );
    l.merge(y);
    PyrLedgerView v = l.compute(st, whole: true);
    expect(v.counted, isNot(contains(y.id)));
    expect(v.balanceOf(w.id('B1')), 0);
    expect(v.broken[y.id], 'zły numer kolejny');
    final PyramidRecord y1 = await signed(
      await order(start + 2, 'A1', 'B1', 123456, 1),
      five,
    );
    l.merge(y1);
    v = l.compute(st, whole: true);
    expect(v.broken[y1.id], 'za mało środków');
    expect(v.balanceOf(w.id('A1')), 0);
    // An order of somebody's who has left by now still counts as of its
    // time.
    final PyrLedger m = PyrLedger();
    final PyramidRecord e = await fund(m, 'A1', 1000);
    final PyramidRecord pay = await signed(
      await order(start, 'A1', 'X', 100, 1),
      five,
    );
    m.merge(pay);
    final PyramidRecord leave = await w.rec(
      PyrT.leave,
      start + h,
      <String>['X'],
      <String, dynamic>{'k': w.id('X')},
    );
    final PyramidState after = w.fold(<PyramidRecord>[
      e,
      leave,
    ], now: start + day);
    expect(after.isMember(w.id('X')), isFalse);
    expect(m.compute(after, whole: true).balanceOf(w.id('X')), 100);
  });
}
