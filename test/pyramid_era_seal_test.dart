import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// Who signs payments comes from the seals of the treasurers' eras, never
/// from the time a record claims: the treasurers of an era are the `next`
/// of the seal before it, an operation names the last seal its payer knew
/// (`after`) and belongs to the era after it, and a change of the tree,
/// however it is dated, reaches the money only from the era after the
/// seal that names it. A seal is one content most of the era's own
/// treasurers co-sign; of several, the one later seals rest on, then the
/// one that dominates (more operations, then the lower id); who signs two
/// that neither dominates is caught.
void main() {
  const int t0 = FoldWorld.t0;
  const int h = FoldWorld.hour;
  const int day = FoldWorld.day;
  // S's era is sealed at t0 + h; B1 is funded at t0 + day, credited a day
  // later (before start).
  const int start = t0 + 2 * day + h;

  late FoldWorld w;
  late PyramidRecord first;

  setUp(() async {
    w = await FoldWorld.make();
    first = await w.sealFirst();
  });

  Future<PyramidRecord> order(
    int at,
    String from,
    String to,
    int amount,
    int seq, {
    int after = 1,
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
        'after': after,
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
  Future<PyramidRecord> fund(PyrLedger l, String who, int amount) {
    final PyrEmitNote note = PyrEmitNote(
      rc: pyrEmitCommit(w.id(who), 'sol-$who'),
      to: w.id(who),
      salt: 'sol-$who',
    );
    l.mergeNote(note);
    return w.rec(
      PyrT.emit,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'rc': note.rc, 'amount': amount},
    );
  }

  /// [who] (names) admit a key of their own each under themselves, at the
  /// third level (treasurers), dated [at].
  Future<List<(LedgerKeyPair, PyramidRecord)>> admitUnder(
    String who,
    List<String> slots,
    int at,
  ) async => <(LedgerKeyPair, PyramidRecord)>[
    for (final String slot in slots)
      await () async {
        final LedgerKeyPair p = await LedgerKeyPair.generate();
        return (
          p,
          await signedRecord(
            PyrT.admit,
            w.py,
            at,
            <LedgerKeyPair>[w[who], p],
            <String, dynamic>{
              'sp': w.id(who),
              'head': w.id(who),
              'slot': slot,
              'm': memberData(p, 'P$slot'),
            },
          ),
        );
      }(),
  ];

  const List<String> five = <String>['S', 'A', 'B', 'A1', 'A2'];

  group('the eras come from the seals', () {
    test('the founder alone seals its era; from then on the tree\'s '
        'treasurers sign, whatever an order claims', () async {
      final PyramidState before = w.fold(const <PyramidRecord>[], now: start);
      expect(before.seals, isEmpty);
      expect(before.treasurers, <String>[w.id('S')]);
      expect(before.treeTreasurers, hasLength(8));
      final PyramidState st = w.fold(<PyramidRecord>[first], now: start);
      expect(st.seals, hasLength(1));
      expect(st.seals.single.signers, <String>[w.id('S')]);
      expect(st.treasurersAt(t0), <String>[w.id('S')]);
      expect(st.treasurers, hasLength(8));
      expect(st.openEra, 2);
      // The founder dates an order into its own era after the seal: it
      // counts nowhere.
      final PyrLedger l = PyrLedger();
      final PyramidRecord mint = await signed(
        await order(t0 + 1, 'S', 'Y', kPyrMaxAmount, 777, after: 0),
        <String>['S'],
      );
      l.merge(mint);
      expect(PyrLedger.isFinal(mint, st), isFalse);
      expect(l.compute(st).balanceOf(w.id('Y')), 0);
      // An order of an era nobody sealed yet counts nowhere either.
      final PyramidRecord ahead = await signed(
        await order(start, 'S', 'Y', 1, 1, after: 5),
        <String>[...five, 'B1', 'X', 'Y'],
      );
      expect(PyrLedger.isFinal(ahead, st), isFalse);
      expect(PyrLedger.breaks(ahead, st), isNull);
      // An order naming no seal is no order.
      final PyramidRecord none = await signed(
        await w.rec(PyrT.transfer, start, <String>['S'], <String, dynamic>{
          'from': w.id('S'),
          'to': w.id('Y'),
          'amount': 1,
          'seq': 1,
          'memo': '',
        }),
        five,
      );
      expect(PyrLedger.breaks(none, st), 'zły przelew');
      // The treasurer of era 2 signs only orders of era 2.
      expect(
        l.problem(await order(start, 'S', 'Y', 1, 1, after: 0), st, start),
        kPyrOtherEra,
      );
    });

    test('an operation of a sealed era counts only when its seal lists '
        'it; its payer orders again in the next era, with the same number',
        () async {
      final PyrLedger treasurer = PyrLedger();
      final PyramidRecord e = await fund(treasurer, 'B1', 1000);
      final PyramidRecord paid = await signed(
        await order(start, 'B1', 'A2', 300, 1),
        five,
      );
      treasurer.merge(paid);
      // Four of eight: not final when the era is sealed.
      final PyramidRecord unfinished = await order(start + h, 'B1', 'S', 50, 2);
      treasurer.merge(
        await signed(unfinished, <String>['S', 'A', 'B', 'A1']),
      );
      final PyramidState open = w.fold(<PyramidRecord>[e, first], now: start);
      final PyramidRecord second = await w.seal(
        start + 6 * h,
        more: <PyramidRecord>[e, first],
        ops: treasurer.countedIn(treasurer.compute(open, whole: true), 2),
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        first,
        second,
      ], now: start + 7 * h);
      expect(st.seals, hasLength(2));
      expect(st.seals.last.ops, <String>{paid.id});
      // A fifth signature after the seal: still nothing.
      treasurer.merge(await signed(unfinished, <String>['A2']));
      expect(PyrLedger.isFinal(treasurer.ops[unfinished.id]!, st), isFalse);
      final PyrLedgerView v = treasurer.compute(st, whole: true);
      expect(v.balanceOf(w.id('S')), 0);
      expect(v.balanceOf(w.id('B1')), 700);
      expect(v.broken[unfinished.id], kPyrLeftOutOfSeal);
      // B1 orders again in era 3, with the number that stayed free; the
      // treasurers who signed the first may sign it.
      expect(v.seqOf(w.id('B1')), 1);
      final PyramidRecord again = await order(
        start + 7 * h,
        'B1',
        'S',
        50,
        2,
        after: 2,
      );
      expect(treasurer.problem(again, st, start + 7 * h), isNull);
      expect(PyrLedger.passed(treasurer.ops[unfinished.id]!, st), isTrue);
      // The payee who keeps only its own reads the seal the same way.
      final PyrLedger a2 = PyrLedger()..merge(paid);
      expect(a2.compute(st).balanceOf(w.id('A2')), 300);
    });

    test('a former majority of an era replaces no payment after its seal, '
        'and is caught', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'S', 1000);
      final PyramidRecord second = await w.seal(
        start,
        more: <PyramidRecord>[e, first],
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        first,
        second,
      ], now: start + day);
      // S pays B1, number 1, in era 3: five of eight sign.
      final PyramidRecord honest = await order(
        start + h,
        'S',
        'B1',
        800,
        1,
        after: 2,
      );
      l.merge(await signed(honest, five));
      // Later the same five sign S's number 1 for era 2, already sealed.
      final PyramidRecord back = await signed(
        await order(start - h, 'S', 'Y', 800, 1),
        five,
      );
      l.merge(back);
      expect(PyrLedger.breaks(back, st), isNull);
      expect(PyrLedger.isFinal(back, st), isFalse);
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('B1')), 800);
      expect(v.balanceOf(w.id('Y')), 0);
      expect(v.broken[back.id], kPyrLeftOutOfSeal);
      expect(
        v.cheaters.keys,
        containsAll(<String>[for (final String n in five) w.id(n)]),
      );
    });
  });

  group('a change of the tree, however dated, undoes no payment', () {
    test('two treasurers admitted with a time before a payment, in a quiet '
        'pyramid: the payment\'s era keeps its treasurers on every phone, '
        'the next seal takes them in', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'B1', 1000);
      final PyramidState st0 = w.fold(<PyramidRecord>[e, first], now: start);
      final PyramidRecord pay = await order(start, 'B1', 'A2', 800, 1);
      expect(l.problem(pay, st0, start), isNull);
      // Five of the eight of era 2.
      l.merge(await signed(pay, five));
      // Five hours later B1 admits two keys of its own (treasurers' level),
      // dated an hour before the payment.
      final List<(LedgerKeyPair, PyramidRecord)> two = await admitUnder(
        'B1',
        <String>['100', '101'],
        start - h,
      );
      final List<PyramidRecord> all = <PyramidRecord>[
        e,
        first,
        for (final (LedgerKeyPair _, PyramidRecord r) in two) r,
      ];
      final PyramidState st = w.fold(all, now: start + 5 * h);
      expect(st.rejected, isEmpty);
      expect(st.treeTreasurers, hasLength(10));
      expect(st.treasurers, hasLength(8));
      expect(PyrLedger.isFinal(l.ops[pay.id]!, st), isTrue);
      expect(l.compute(st).balanceOf(w.id('A2')), 800);
      expect(l.compute(st).balanceOf(w.id('B1')), 200);
      // The seal of era 2 names them; era 3 has ten treasurers, and the
      // payment, listed, stays.
      final PyramidRecord second = await w.seal(
        start + 5 * h,
        more: all.sublist(1),
        ops: <String>[pay.id],
      );
      expect(
        second.body['ch'],
        containsAll(<String>[
          for (final (LedgerKeyPair _, PyramidRecord r) in two) r.id,
        ]),
      );
      final PyramidState sealed = w.fold(<PyramidRecord>[
        ...all,
        second,
      ], now: start + 6 * h);
      expect(sealed.seals, hasLength(2));
      expect(sealed.treasurers, hasLength(10));
      expect(sealed.treasurersAt(start), hasLength(8));
      expect(l.compute(sealed).balanceOf(w.id('A2')), 800);
    });

    test('admissions dated back into a sealed era fold after the seals on '
        'every phone, and change no sealed treasurers', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'B1', 1000);
      final PyramidRecord pay = await signed(
        await order(start, 'B1', 'A2', 800, 1),
        five,
      );
      l.merge(pay);
      final PyramidRecord second = await w.seal(
        start + 6 * h,
        more: <PyramidRecord>[e, first],
        ops: <String>[pay.id],
      );
      final List<(LedgerKeyPair, PyramidRecord)> two = await admitUnder(
        'B1',
        <String>['100', '101'],
        start - h,
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        first,
        second,
        for (final (LedgerKeyPair _, PyramidRecord r) in two) r,
      ], now: start + day);
      expect(st.seals, hasLength(2));
      for (final (LedgerKeyPair _, PyramidRecord r) in two) {
        expect(st.applied, contains(r.id));
      }
      expect(st.treeTreasurers, hasLength(10));
      expect(st.treasurers, hasLength(8));
      expect(st.treasurersAt(start), hasLength(8));
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('A2')), 800);
      expect(v.balanceOf(w.id('B1')), 200);
    });

    test('a payer who leaves with a time before its payment takes nothing '
        'back; its departure counts from the era after the seal that names '
        'it', () async {
      final PyrLedger l = PyrLedger();
      final PyramidRecord e = await fund(l, 'B1', 1000);
      final PyramidRecord pay = await signed(
        await order(start, 'B1', 'A2', 800, 1),
        five,
      );
      l.merge(pay);
      final PyramidRecord leave = await w.rec(
        PyrT.leave,
        start - h,
        <String>['B1'],
        <String, dynamic>{'k': w.id('B1')},
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        first,
        leave,
      ], now: start + day);
      expect(st.applied, contains(leave.id));
      expect(st.isMember(w.id('B1')), isFalse);
      expect(PyrLedger.breaks(pay, st), isNull);
      expect(l.compute(st).balanceOf(w.id('A2')), 800);
      // Sealed with it named: the payment stands, an order of the next era
      // from B1 counts nowhere.
      final PyramidRecord second = await w.seal(
        start + day,
        more: <PyramidRecord>[e, first, leave],
        ops: <String>[pay.id],
      );
      expect(second.body['ch'], contains(leave.id));
      final PyramidState sealed = w.fold(<PyramidRecord>[
        e,
        first,
        leave,
        second,
      ], now: start + 2 * day);
      expect(l.compute(sealed).balanceOf(w.id('A2')), 800);
      final PyramidRecord later = await order(
        start + day + h,
        'B1',
        'A2',
        100,
        2,
        after: 2,
      );
      expect(PyrLedger.breaks(later, sealed), 'zły przelew');
    });
  });

  group('one seal per era, by dominance', () {
    test('a seal holds only as the era it seals: most of the era\'s '
        'treasurers, the tree\'s next treasurers, one after the other', () async {
      final PyramidRecord second = await w.seal(start, more: <PyramidRecord>[
        first,
      ]);
      // Signed by four of eight.
      final PyramidRecord half = await signedSeal(
        second.body,
        <LedgerKeyPair>[w['S'], w['A'], w['B'], w['A1']],
      );
      expect(
        w.fold(<PyramidRecord>[first, half]).rejected[half.id],
        'pieczęć podpisuje większość skarbników ery',
      );
      // Names others as the next treasurers: the tree disagrees.
      final PyramidRecord forged = await signedSeal(<String, dynamic>{
        ...second.body,
        'next': <String>[w.id('S')],
      }, <LedgerKeyPair>[for (final String n in five) w[n]]);
      expect(
        w.fold(<PyramidRecord>[first, forged]).rejected[forged.id],
        'pieczęć nie zgadza się z drzewem',
      );
      // The second era's seal without the first.
      final PyramidState alone = w.fold(<PyramidRecord>[second]);
      expect(alone.seals, isEmpty);
      expect(w.fold(<PyramidRecord>[first, second]).seals, hasLength(2));
    });

    test('two competing seals of one era: the one listing more counts, then '
        'the lower id; who signed two neither of which dominates is '
        'caught, who signed a smaller one and then a larger one is not',
        () async {
      final PyramidRecord second = await w.seal(start, more: <PyramidRecord>[
        first,
      ]);
      Future<PyramidRecord> withOps(
        List<String> ops,
        List<String> who, {
        int? to,
      }) => signedSeal(<String, dynamic>{
        ...second.body,
        'ops': ops,
        'at': ?to,
        'to': ?to,
      }, <LedgerKeyPair>[for (final String n in who) w[n]]);
      final String a = '0' * 64;
      final String b = '1' * 64;
      final String c = '2' * 64;
      final PyramidRecord small = await withOps(<String>[a], five);
      final PyramidRecord big = await withOps(<String>[
        a,
        b,
      ], <String>[...five, 'B1']);
      final PyramidRecord other = await withOps(<String>[c], <String>['X']);
      final PyramidRecord otherToo = await withOps(<String>[
        c,
      ], <String>['S', 'X']);
      final PyramidState st = w.fold(<PyramidRecord>[
        first,
        big,
        small,
        other,
        otherToo,
      ]);
      expect(st.seals.last.id, big.id);
      expect(st.rejected[small.id], 'era ma inną pieczęć');
      // S signed {a}, {a, b} and {c}: {c} and {a} dominate neither.
      expect(st.sealCheaters.keys, <String>[w.id('S')]);
      expect(st.sealCheaters[w.id('S')], containsAll(<String>[otherToo.id]));
      // The same operations at two ends: the lower id.
      final PyramidRecord early = await withOps(<String>[a], five);
      final PyramidRecord late = await withOps(<String>[
        a,
      ], five, to: start + 1);
      final String low = early.id.compareTo(late.id) < 0 ? early.id : late.id;
      final PyramidState tie = w.fold(<PyramidRecord>[first, late, early]);
      expect(tie.seals.last.id, low);
      expect(tie.sealCheaters, isEmpty);
    });

    test('a seal later eras rest on is not replaced by one that dominates '
        'it but came late', () async {
      final PyramidRecord second = await w.seal(start, more: <PyramidRecord>[
        first,
      ]);
      final PyramidRecord third = await w.seal(
        start + 6 * h,
        more: <PyramidRecord>[first, second],
      );
      final PyramidRecord bigger = await signedSeal(<String, dynamic>{
        ...second.body,
        'ops': <String>['0' * 64],
      }, <LedgerKeyPair>[for (final String n in five) w[n]]);
      final PyramidState st = w.fold(<PyramidRecord>[
        first,
        second,
        third,
        bigger,
      ]);
      expect(<String>[for (final PyrSeal x in st.seals) x.id], <String>[
        first.id,
        second.id,
        third.id,
      ]);
    });
  });

  group('on the phones', () {
    test('a treasurer leaves with a time 35 minutes back: the treasurers\' '
        'apps seal every later era, and every phone, also one that gets '
        'everything at once, agrees on who signed when', () async {
      final PyramidWorld w = await PyramidWorld.six();
      const List<String> stay = <String>['S', 'A', 'B', 'A1', 'A2'];
      expect(w['S'].state!.seals, hasLength(1));
      // Something newer is kept everywhere (a post), then B1 leaves with a
      // time 35 minutes before it (its phone was away, or a changed app).
      final int p = w.net.now;
      await w['S'].post('Dzień dobry');
      await w.net.run();
      await w.net.advance(const Duration(minutes: 40));
      final String py = w['S'].state!.id;
      final String b1 = w['B1'].myKey!;
      final PyramidRecord leave = await w['B1'].signAsMe(
        PyramidRecord(
          body: <String, dynamic>{
            't': PyrT.leave,
            'py': py,
            'at': p - 35 * 60 * 1000,
            'by': <String>[b1],
            'k': b1,
          },
        ),
      );
      await w['B1'].ingest(leave);
      await w.net.run();
      // Days of duties with everybody online.
      for (int i = 0; i < 6; i++) {
        await w.net.advance(const Duration(hours: 12));
        await w.duties(rounds: 1);
        await w.net.advance(const Duration(minutes: 15));
        await w.duties(rounds: 3);
        await w.sync();
      }
      final List<String> seals = <String>[
        for (final PyrSeal x in w['S'].state!.seals) x.id,
      ];
      expect(seals.length, greaterThanOrEqualTo(6));
      for (final String n in stay) {
        expect(<String>[
          for (final PyrSeal x in w[n].state!.seals) x.id,
        ], seals, reason: n);
        expect(w[n].state!.treasurers, hasLength(5), reason: n);
        expect(w[n].state!.sealCheaters, isEmpty, reason: n);
      }
      // The era the leave is dated in kept B1; the seal after named it.
      final PyramidState s = w['S'].state!;
      expect(s.treasurersAt(p - 10 * 60 * 1000), contains(b1));
      expect(s.seals[1].changes, contains(leave.id));
      // A phone that gets the same records in one sync (back after weeks,
      // or a newcomer) reads the same.
      final PyramidState fresh = PyramidState.fold(py, <PyramidRecord>[
        for (final String id in w['S'].recordIds) w['S'].recordOf(id)!,
      ], now: w.net.now);
      expect(<String>[for (final PyrSeal x in fresh.seals) x.id], seals);
      for (final int at in <int>[p - h, p - 10 * 60 * 1000, p + h]) {
        expect(fresh.treasurersAt(at), s.treasurersAt(at));
      }
    });

    test('in a quiet pyramid the payer admits two treasurers of its own five '
        'hours after its payment, dated a minute before it: the payment '
        'still counts on every treasurer\'s ledger', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      final String b1 = w['B1'].myKey!;
      await w.net.advance(const Duration(hours: 3));
      // S and B away: the payment counts with A, A1, A2, B1 (4 of 6).
      w.net.holdForOffline = false;
      for (final String n in <String>['S', 'B']) {
        w.net.setOnline(w.net[n], false);
      }
      final PyramidRecord? pay = await w['A1'].pay(b1, 800);
      await w.net.run();
      for (final String n in <String>['S', 'B']) {
        w.net.setOnline(w.net[n], true);
      }
      w.net.holdForOffline = true;
      await w.sync();
      expect(w['A1'].pendingPayments, isEmpty);
      await w.net.advance(const Duration(minutes: 31));
      await w.duties(rounds: 2);
      expect(w['A2'].ledgerBalanceOf(b1), 800);
      await w.net.advance(const Duration(hours: 5));
      final String py = w['S'].state!.id;
      final String a = w['A1'].myKey!;
      final List<String> free = w['S'].state!.freePlaces(
        w['S'].state!.pathOf(a)!,
      );
      final List<PyramidRecord> admits = <PyramidRecord>[];
      for (int i = 0; i < 2; i++) {
        final LedgerKeyPair k = await LedgerKeyPair.generate();
        PyramidRecord r = await w['A1'].signAsMe(
          PyramidRecord(
            body: <String, dynamic>{
              't': PyrT.admit,
              'py': py,
              'at': pay!.at - 60 * 1000 + i,
              'by': <String>{a, k.id}.toList()..sort(),
              'sp': a,
              'head': a,
              'slot': free[i],
              'm': memberData(k, 'P$i'),
            },
          ),
        );
        r = await r.signedBy(k);
        admits.add(r);
        await w['A1'].ingest(r);
      }
      await w.net.run();
      await w.sync();
      for (final String n in <String>['S', 'A', 'B', 'A2', 'B1']) {
        for (final PyramidRecord r in admits) {
          expect(w[n].state!.applied, contains(r.id), reason: n);
        }
        expect(w[n].ledgerBalanceOf(b1), 800, reason: n);
      }
      // The next seals take them in; the payment stays.
      for (int i = 0; i < 2; i++) {
        await w.net.advance(const Duration(hours: 7));
        await w.duties(rounds: 1);
        await w.net.advance(const Duration(minutes: 15));
        await w.duties(rounds: 3);
        await w.sync();
      }
      final PyramidState s = w['S'].state!;
      expect(s.treasurers, hasLength(8));
      expect(s.treasurersAt(pay!.at), hasLength(6));
      for (final String n in <String>['S', 'A', 'B', 'A2']) {
        expect(w[n].ledgerBalanceOf(b1), 800, reason: n);
      }
    });

    test('two treasurers propose seals of one era apart: they meet in one '
        'and nobody is caught', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.net.advance(const Duration(hours: 7));
      await w.duties(rounds: 1);
      await w.net.advance(const Duration(minutes: 11));
      w.net.holdForOffline = false;
      for (final String n in <String>['S', 'A', 'B', 'A1', 'A2', 'B1']) {
        w.net.setOnline(w.net[n], n == 'A');
      }
      await w['A'].duties();
      await w.net.run();
      await w.net.advance(const Duration(minutes: 1));
      w.net
        ..setOnline(w.net['A'], false)
        ..setOnline(w.net['B'], true);
      await w['B'].duties();
      await w.net.run();
      for (final String n in <String>['S', 'A', 'B', 'A1', 'A2', 'B1']) {
        w.net.setOnline(w.net[n], true);
      }
      w.net.holdForOffline = true;
      await w.sync();
      expect(
        <String>[
          for (final String id in w['S'].recordIds)
            if (w['S'].recordOf(id)!.type == PyrT.seal &&
                w['S'].recordOf(id)!.body['n'] == 2)
              id,
        ],
        hasLength(2),
      );
      await w.duties(rounds: 3);
      await w.sync();
      final PyramidState s = w['S'].state!;
      expect(s.seals, hasLength(2));
      expect(s.sealCheaters, isEmpty);
      for (final String n in <String>['A', 'B', 'A1', 'A2', 'B1']) {
        expect(w[n].state!.seals.last.id, s.seals.last.id, reason: n);
      }
    });

    test('the end of an era comes from the proposal: co-signed when it is no '
        'more than ten minutes ahead of a co-signer\'s clock and the era '
        'was due then, not otherwise', () async {
      final PyramidWorld w = await PyramidWorld.six();
      final int from = w['S'].state!.sealedTo;
      // Five minutes before the era is due by the treasurers' clocks: none
      // proposes a seal of its own yet.
      await w.net.advance(
        Duration(milliseconds: from + kPyrEraMs - 5 * 60 * 1000 - w.net.now),
      );
      Future<PyramidRecord> proposal(int to) async {
        final PyrEraToSeal e = w['A'].state!.eraToSeal(to)!;
        return w['A'].signAsMe(
          PyramidRecord(
            body: PyrSeal.body(
              pyramid: w['A'].state!.id,
              n: e.n,
              prev: e.prev,
              from: e.from,
              to: e.to,
              set: e.set,
              next: e.next,
              ops: const <String>[],
              changes: e.changes,
            ),
          ),
        );
      }

      // A clock behind ends the era before it was due; one eleven minutes
      // ahead ends it after the co-signers' clocks allow.
      final PyramidRecord behind = await proposal(w.net.now - 60 * 1000);
      final PyramidRecord ahead = await proposal(w.net.now + 11 * 60 * 1000);
      await w['A'].ingest(behind);
      await w['A'].ingest(ahead);
      await w.net.run();
      await w.duties(rounds: 3);
      expect(w['S'].state!.seals, hasLength(1));
      expect(w['S'].recordOf(behind.id)?.signers, <String>[w['A'].myKey!]);
      expect(w['S'].recordOf(ahead.id), isNull);
      // Nine minutes ahead: within what a clock may be off.
      final PyramidRecord near = await proposal(w.net.now + 9 * 60 * 1000);
      await w['A'].ingest(near);
      await w.net.run();
      await w.duties(rounds: 3);
      await w.sync();
      final PyramidState s = w['S'].state!;
      expect(s.seals, hasLength(2));
      expect(s.seals.last.id, near.id);
      expect(s.seals.last.signers.length, greaterThanOrEqualTo(4));
    });
  });

  test('every phone counts only what an honest treasurer would sign: an '
      'order to an outsider, or with a gap in its numbers, counts nowhere '
      'however many treasurers signed it', () async {
    final PyrLedger l = PyrLedger();
    final PyramidState st = w.fold(<PyramidRecord>[first], now: start);
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
          'after': 1,
          'memo': '',
        },
      ),
      five,
    );
    expect(l.problem(x, st, start), isNotNull);
    l.merge(x);
    for (final bool whole in <bool>[false, true]) {
      final PyrLedgerView v = l.compute(st, whole: whole);
      expect(v.counted, isNot(contains(x.id)));
      expect(v.broken[x.id], 'zły przelew');
    }
    final PyramidRecord y = await signed(
      await order(start + 1, 'A1', 'B1', 123456, 50),
      five,
    );
    l.merge(y);
    expect(l.compute(st, whole: true).broken[y.id], 'zły numer kolejny');
  });
}

/// A seal record of [body] signed by [who].
Future<PyramidRecord> signedSeal(
  Map<String, dynamic> body,
  List<LedgerKeyPair> who,
) async {
  PyramidRecord r = PyramidRecord(body: body);
  for (final LedgerKeyPair k in who) {
    r = await r.signedBy(k);
  }
  return r;
}
