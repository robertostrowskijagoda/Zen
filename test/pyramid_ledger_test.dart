import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The private ledger's rules without any network: what counts (most
/// treasurers of its time signed it), what a treasurer may sign (the next
/// number, the money, the daily limit, fresh, within its era), conditional
/// payments and announcements, emissions credited through their sealed
/// note, and the treasurers' statements.
void main() {
  const int t0 = FoldWorld.t0;
  const int h = FoldWorld.hour;
  const int day = FoldWorld.day;
  // Funded at t0 + day, credited a day later.
  const int start = t0 + 2 * day + h;

  late FoldWorld w;

  setUp(() async {
    w = await FoldWorld.make();
  });

  Future<PyramidRecord> order(
    int at,
    String from,
    String to,
    int amount,
    int seq, {
    Map<String, dynamic>? cond,
    String memo = '',
  }) => w.rec(
    PyrT.transfer,
    at,
    <String>[from],
    <String, dynamic>{
      'from': w.id(from),
      'to': w.id(to),
      'amount': amount,
      'seq': seq,
      'memo': memo,
      'cond': ?cond,
    },
  );

  Future<PyramidRecord> settle(
    int at,
    String by,
    String x,
    bool ok, {
    String? next,
  }) => w.rec(
    PyrT.settle,
    at,
    <String>[by],
    <String, dynamic>{'x': x, 'ok': ok, 'next': ?next},
  );

  /// [op] with the treasurer signatures of [who].
  Future<PyramidRecord> signed(PyramidRecord op, List<String> who) async {
    PyramidRecord r = op;
    for (final String n in who) {
      r = r.withTreasurerSig(
        w.id(n),
        b64(await w[n].sign(PyramidRecord.treasurerBytes(op.id))),
      );
    }
    return r;
  }

  // Everybody of kFoldTree is a treasurer (down to level 3): 5 of 8.
  const List<String> five = <String>['S', 'A', 'B', 'A1', 'A2'];
  const List<String> four = <String>['S', 'A', 'B', 'A1'];

  /// [amount] emitted to [who] at t0 + day, with its note in [l].
  Future<PyramidRecord> fund(PyrLedger l, String who, int amount) async {
    final PyrEmitNote note = PyrEmitNote(
      rc: pyrEmitCommit(w.id(who), 'sol-$who'),
      to: w.id(who),
      salt: 'sol-$who',
      why: 'Start',
    );
    expect(l.mergeNote(note), isTrue);
    return w.rec(
      PyrT.emit,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'rc': note.rc, 'amount': amount},
    );
  }

  test('an emission is credited to whom its note opens, after its wait, '
      'unless vetoed', () async {
    final PyrLedger l = PyrLedger();
    final PyramidRecord e = await fund(l, 'A1', 1000);
    // A note that does not open the commitment is not taken.
    expect(
      l.mergeNote(PyrEmitNote(rc: e.str('rc'), to: w.id('B1'), salt: 'sol-A1')),
      isFalse,
    );
    expect(
      PyrEmitNote.fromJson(<String, dynamic>{
        'rc': e.str('rc'),
        'to': w.id('B1'),
        'salt': 'sol-A1',
      }),
      isNull,
    );
    final PyramidState early = w.fold(<PyramidRecord>[e], now: t0 + day + h);
    expect(l.compute(early).balanceOf(w.id('A1')), 0, reason: 'still waits');
    final PyramidState st = w.fold(<PyramidRecord>[e], now: start);
    final PyrLedgerView v = l.compute(st);
    expect(v.balanceOf(w.id('A1')), 1000);
    expect(v.balanceOf(w.id('B1')), 0);
    expect(v.entries.single.kind, PyrEntryKind.emission);
    expect(v.entries.single.memo, 'Start');
    // Nobody else sees who got it: the public record has no name.
    expect(e.body.containsKey('to'), isFalse);
    expect(e.body.containsKey('why'), isFalse);
    final PyramidRecord veto = await w.rec(
      PyrT.veto,
      t0 + day + h,
      <String>['B'],
      <String, dynamic>{'emit': e.id},
    );
    final PyramidState vetoed = w.fold(<PyramidRecord>[e, veto], now: start);
    expect(l.compute(vetoed).balanceOf(w.id('A1')), 0);
  });

  test('an order counts once most treasurers of its time signed it; fewer '
      'signatures are only evidence', () async {
    final PyrLedger l = PyrLedger();
    final PyramidState st = w.fold(<PyramidRecord>[
      await fund(l, 'A1', 1000),
    ], now: start);
    final PyramidRecord x = await order(start, 'A1', 'B1', 300, 1);
    expect(PyrLedger.problem(x, st, l.compute(st), start), isNull);
    expect(l.merge(await signed(x, four)), isTrue);
    expect(PyrLedger.isFinal(l.ops[x.id]!, st), isFalse);
    expect(l.compute(st).balanceOf(w.id('B1')), 0);
    // One more signature, from another copy: merged, never replaced.
    expect(l.merge(await signed(x, <String>['A2'])), isTrue);
    expect(l.merge(await signed(x, <String>['A2'])), isFalse);
    expect(l.ops[x.id]!.tsigs.keys, hasLength(5));
    final PyrLedgerView v = l.compute(st);
    expect(v.balanceOf(w.id('A1')), 700);
    expect(v.balanceOf(w.id('B1')), 300);
    expect(v.seqOf(w.id('A1')), 1);
    // The same order again is not signed again as new: its number is
    // taken.
    expect(PyrLedger.problem(x, st, v, start), 'zły numer kolejny');
  });

  test('two orders for one number: the treasurer who signed both is caught, '
      'and only the first counts', () async {
    final PyrLedger l = PyrLedger();
    final PyramidState st = w.fold(<PyramidRecord>[
      await fund(l, 'A1', 1000),
    ], now: start);
    final PyramidRecord toB1 = await order(start, 'A1', 'B1', 800, 1);
    final PyramidRecord toA2 = await order(start + 1, 'A1', 'A2', 800, 1);
    // Honest treasurers sign one of them; A signs both. With five honest
    // of eight, the second can never reach five signatures.
    l
      ..merge(await signed(toB1, <String>['S', 'B', 'A1', 'A2', 'A']))
      ..merge(await signed(toA2, <String>['A', 'B1', 'X', 'Y']));
    PyrLedgerView v = l.compute(st);
    expect(v.cheaters.keys, <String>[w.id('A')]);
    expect(v.balanceOf(w.id('B1')), 800);
    expect(v.balanceOf(w.id('A2')), 0);
    expect(v.balanceOf(w.id('A1')), 200);
    // Even a dishonest majority gets no second spending: the first by
    // time stands.
    l.merge(await signed(toA2, <String>['S']));
    v = l.compute(st);
    expect(v.balanceOf(w.id('A2')), 0);
    expect(v.balanceOf(w.id('A1')), 200);
    expect(v.cheaters.keys, unorderedEquals(<String>[w.id('A'), w.id('S')]));
  });

  test('a treasurer signs only the next number, the money there, fresh, '
      'within its era, between members', () async {
    final PyrLedger l = PyrLedger();
    final PyramidState st = w.fold(<PyramidRecord>[
      await fund(l, 'A1', 1000),
    ], now: start);
    final PyrLedgerView v = l.compute(st);
    Future<String?> why(PyramidRecord op, {int now = start}) async =>
        PyrLedger.problem(op, st, v, now);

    expect(
      await why(await order(start, 'A1', 'B1', 300, 2)),
      'zły numer kolejny',
    );
    expect(
      await why(await order(start, 'A1', 'B1', 1001, 1)),
      'za mało środków',
    );
    expect(await why(await order(start, 'A1', 'B1', -9, 1)), 'zły przelew');
    expect(
      await why(await order(start, 'A1', 'B1', 1 << 62, 1)),
      'zły przelew',
    );
    expect(await why(await order(start, 'A1', 'A1', 10, 1)), 'zły przelew');
    // Signed by somebody else than the payer.
    final PyramidRecord forged = await w.rec(
      PyrT.transfer,
      start,
      <String>['B1'],
      <String, dynamic>{
        'from': w.id('A1'),
        'to': w.id('B1'),
        'amount': 10,
        'seq': 1,
        'memo': '',
      },
    );
    expect(await why(forged), 'zły przelew');
    // Too old, or from the future.
    expect(
      await why(
        await order(start, 'A1', 'B1', 10, 1),
        now: start + kPyrMaxOrderAgeMs + 1,
      ),
      contains('stare'),
    );
    expect(
      await why(await order(start + h, 'A1', 'B1', 10, 1)),
      contains('przyszłości'),
    );
    // A condition for a non-member or too far away.
    expect(
      await why(
        await order(
          start,
          'A1',
          'B1',
          10,
          1,
          cond: <String, dynamic>{'by': 'nikt', 'until': start + h},
        ),
      ),
      'zły warunek',
    );
    expect(
      await why(
        await order(
          start,
          'A1',
          'B1',
          10,
          1,
          cond: <String, dynamic>{
            'by': w.id('B1'),
            'until': start + kPyrMaxHoldMs + h,
          },
        ),
      ),
      'zły warunek',
    );
    expect(await why(await order(start, 'A1', 'B1', 10, 1)), isNull);

    // A new treasurer (Z under B, level 2): orders made before are not
    // signed any more (the old majority could have signed them).
    final LedgerKeyPair z = await LedgerKeyPair.generate();
    final PyramidRecord admitZ = await signedRecord(
      PyrT.admit,
      w.py,
      start + 2 * h,
      <LedgerKeyPair>[w['B'], z],
      <String, dynamic>{
        'sp': w.id('B'),
        'head': w.id('B'),
        'slot': '11',
        'm': memberData(z, 'Z'),
      },
    );
    final PyramidRecord e = await fund(PyrLedger(), 'A1', 1000);
    final PyramidState after = w.fold(<PyramidRecord>[
      e,
      admitZ,
    ], now: start + 3 * h);
    expect(after.treasurers, contains(z.id));
    expect(after.treasurersAt(start), isNot(contains(z.id)));
    expect(
      PyrLedger.problem(
        await order(start + h, 'A1', 'B1', 10, 1),
        after,
        l.compute(after),
        start + 3 * h,
      ),
      'zlecenie sprzed zmiany skarbników',
    );
  });

  test('the daily limit: set by the top within 5–200, by the orders\' days '
      'and by what this treasurer signed today', () async {
    final PyrLedger l = PyrLedger();
    // The top lowers it to 5: at once.
    final PyramidRecord lower = await w.rec(
      PyrT.emitRule,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'xfers': 5},
    );
    final PyramidState st = w.fold(<PyramidRecord>[
      lower,
      await fund(l, 'A1', 10000),
    ], now: start + day);
    expect(st.params.xferLimit, 5);
    for (int i = 1; i <= 5; i++) {
      final PyramidRecord x = await order(start + i, 'A1', 'B1', 10, i);
      expect(
        PyrLedger.problem(x, st, l.compute(st), start + 10),
        isNull,
        reason: 'order $i',
      );
      l.merge(await signed(x, five));
    }
    final PyramidRecord sixth = await order(start + 6, 'A1', 'B1', 10, 6);
    expect(
      PyrLedger.problem(sixth, st, l.compute(st), start + 10),
      'limit przelewów na dzień',
    );
    // A day later: again.
    final PyramidRecord tomorrow = await order(
      start + day + 10,
      'A1',
      'B1',
      10,
      6,
    );
    expect(
      PyrLedger.problem(tomorrow, st, l.compute(st), start + day + 10),
      isNull,
    );
    // Dated back into an empty day, it still meets what this treasurer
    // signed today by its own clock.
    final PyramidRecord back = await order(start - h, 'A1', 'B1', 10, 6);
    expect(
      PyrLedger.problem(back, st, l.compute(st), start + day, signedToday: 5),
      'limit przelewów na dzień',
    );
    // Outside the hard bounds the number is clamped.
    final PyramidRecord tooLow = await w.rec(
      PyrT.emitRule,
      t0 + day + 1,
      <String>['S', 'A'],
      <String, dynamic>{'xfers': 1},
    );
    expect(
      w.fold(<PyramidRecord>[tooLow], now: start).params.xferLimit,
      kPyrMinXfers,
    );
  });

  test('raising the daily limit waits 30 days and can be cancelled', () async {
    final PyramidRecord raise = await w.rec(
      PyrT.emitRule,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'xfers': 100},
    );
    PyramidState st = w.fold(<PyramidRecord>[raise], now: t0 + 2 * day);
    expect(st.params.xferLimit, kPyrDefaultXfers);
    expect(st.pendingEmitChanges.single.xfers, 100);
    expect(st.pendingEmitChanges.single.oldXfers, kPyrDefaultXfers);
    st = w.fold(<PyramidRecord>[raise], now: t0 + 32 * day);
    expect(st.params.xferLimit, 100);
    final PyramidRecord cancel = await w.rec(
      PyrT.emitCancel,
      t0 + 2 * day,
      <String>['S', 'B'],
      <String, dynamic>{'change': raise.id},
    );
    st = w.fold(<PyramidRecord>[raise, cancel], now: t0 + 32 * day);
    expect(st.params.xferLimit, kPyrDefaultXfers);
    // Over the hard bound: 200 at most.
    final PyramidRecord huge = await w.rec(
      PyrT.emitRule,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'xfers': 5000},
    );
    st = w.fold(<PyramidRecord>[huge], now: t0 + 32 * day);
    expect(st.params.xferLimit, kPyrMaxXfers);
    // Not through new rules in a day either.
    final PyramidRecord rules = await w.rec(
      PyrT.constitution,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{
        'params': <String, dynamic>{'xferLimit': 200},
      },
    );
    st = w.fold(<PyramidRecord>[rules], now: t0 + 3 * day);
    expect(st.rejected[rules.id], contains('limit emisji'));
    expect(st.params.xferLimit, kPyrDefaultXfers);
  });

  test('a conditional payment: kept by the one it waits for, back to the '
      'payer only after its time', () async {
    final PyrLedger l = PyrLedger();
    final PyramidState st = w.fold(<PyramidRecord>[
      await fund(l, 'A1', 2000),
    ], now: start + 10 * h);
    final PyramidRecord x = await order(
      start,
      'A1',
      'B1',
      1000,
      1,
      cond: <String, dynamic>{'by': w.id('B1'), 'until': start + 5 * h},
      memo: 'Brama',
    );
    l.merge(await signed(x, five));
    PyrLedgerView v = l.compute(st);
    expect(v.escrows[x.id]!.settled, isNull);
    expect(v.balanceOf(w.id('A1')), 1000);
    expect(v.balanceOf(w.id('B1')), 0, reason: 'waits for B1');
    // The payer cannot take it back before the time; B1 cannot accept
    // after it.
    final PyramidRecord early = await settle(start + h, 'A1', x.id, false);
    expect(PyrLedger.problem(early, st, v, start + h), contains('po terminie'));
    final PyramidRecord lateOk = await settle(start + 6 * h, 'B1', x.id, true);
    expect(
      PyrLedger.problem(lateOk, st, v, start + 6 * h),
      'za późno na przyjęcie',
    );
    final PyramidRecord refund = await settle(start + 6 * h, 'A1', x.id, false);
    expect(PyrLedger.problem(refund, st, v, start + 6 * h), isNull);
    l.merge(await signed(refund, five));
    v = l.compute(st);
    expect(v.escrows[x.id]!.settled, isFalse);
    expect(v.balanceOf(w.id('A1')), 2000);
    // Settled once: nothing more to settle.
    expect(
      PyrLedger.problem(
        await settle(start + 4 * h, 'B1', x.id, true),
        st,
        v,
        start + 4 * h,
      ),
      'nie ma czego rozliczyć',
    );
  });

  test(
    'an announcement never goes back to someone already on its way',
    () async {
      final PyrLedger l = PyrLedger();
      final PyramidState st = w.fold(<PyramidRecord>[
        await fund(l, 'A1', 1000),
      ], now: start + 3 * h);
      final PyramidRecord x = await order(
        start,
        'A1',
        'A',
        300,
        1,
        cond: <String, dynamic>{
          'by': w.id('A'),
          'until': start + day,
          'share': 100,
          'hops': 2,
          'h': 'tekst',
        },
      );
      final PyramidRecord s1 = await settle(
        start + h,
        'A',
        x.id,
        true,
        next: w.id('S'),
      );
      // S passes it back to A, who would keep a second share.
      final PyramidRecord s2 = await settle(
        start + 2 * h,
        'S',
        s1.id,
        true,
        next: w.id('A'),
      );
      for (final PyramidRecord op in <PyramidRecord>[x, s1, s2]) {
        l.merge(await signed(op, five));
      }
      final PyrLedgerView v = l.compute(st);
      expect(v.escrows[s1.id]!.to, w.id('S'));
      expect(v.escrows[s2.id], isNull);
      expect(v.balanceOf(w.id('A')), 100);
      expect(v.balanceOf(w.id('S')), 100);
      expect(v.balanceOf(w.id('A1')), 800);
      // What concerns S: its hop and what it rests on, not A1's other
      // business.
      final PyramidRecord other = await order(start + h, 'A1', 'B1', 10, 2);
      l.merge(await signed(other, five));
      final Set<String> forS = <String>{
        for (final PyramidRecord op in l.concerning(w.id('S'))) op.id,
      };
      expect(forS, containsAll(<String>[s1.id, s2.id]));
      expect(forS, isNot(contains(other.id)));
    },
  );

  test('a statement most treasurers agree on; one that differs stands '
      'alone', () async {
    Future<PyrStatement> statement(String by, int balance, int at) async {
      final PyrStatement unsigned = PyrStatement(
        pyramid: w.py,
        account: w.id('B1'),
        balance: balance,
        seq: 2,
        at: at,
        ids: const <String>['b', 'a'],
        by: w.id(by),
        sig: '',
      );
      return PyrStatement.fromJson(<String, dynamic>{
        ...unsigned.toJson(),
        'sig': b64(await w[by].sign(unsigned.signedBytes)),
      })!;
    }

    final List<String> treasurers = <String>[
      for (final (String n, String? _, String _) in kFoldTree) w.id(n),
    ];
    final Map<String, PyrStatement> all = <String, PyrStatement>{
      for (final String n in <String>['S', 'A', 'B', 'A1'])
        w.id(n): await statement(n, 500, start + 1),
      w.id('A2'): await statement('A2', 900, start + 2),
    };
    expect(pyrAgreedStatement(all, treasurers), isNull, reason: '4 of 8');
    all[w.id('X')] = await statement('X', 500, start + 3);
    final PyrStatement agreed = pyrAgreedStatement(all, treasurers)!;
    expect(agreed.balance, 500);
    expect(all[w.id('A2')]!.agreement, isNot(agreed.agreement));
    // The order of the operations does not matter; the signature holds.
    expect(agreed.body['ids'], <String>['a', 'b']);
    expect(
      await verifyLedgerSignature(
        publicKey: agreed.by,
        message: agreed.signedBytes,
        signature: agreed.sig,
      ),
      isTrue,
    );
    // Statements of somebody who is not a treasurer do not count.
    expect(
      pyrAgreedStatement(all, <String>[w.id('A2')])?.balance,
      900,
      reason: 'the only treasurer here',
    );
  });

  test('the ledger reads back as it was stored', () async {
    final PyrLedger l = PyrLedger();
    await fund(l, 'A1', 1000);
    final PyramidRecord x = await order(start, 'A1', 'B1', 300, 1);
    l.merge(await signed(x, five));
    final PyrLedger back = PyrLedger.fromJson(l.toJson());
    expect(back.ops.keys, <String>[x.id]);
    expect(back.ops[x.id]!.tsigs, hasLength(5));
    expect(back.notes.keys, l.notes.keys);
    expect(PyrLedger.slotOf(x), '${w.id('A1')}|1');
  });
}
