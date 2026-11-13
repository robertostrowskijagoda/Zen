import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';

import 'support/pyramid_world.dart';

/// What a treasurer signs is what it counts: one rule, the ledger's own
/// counting, decides both. And what a treasurer sends a member stays
/// within a signal, whatever the number of treasurers.
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
  }) => w.rec(
    PyrT.transfer,
    at,
    <String>[from],
    <String, dynamic>{
      'from': w.id(from),
      'to': to.length > 4 ? to : w.id(to),
      'amount': amount,
      'seq': seq,
      'memo': '',
      'cond': ?cond,
    },
  );

  Future<PyramidRecord> settle(int at, String by, String x, bool ok) =>
      w.rec(PyrT.settle, at, <String>[by], <String, dynamic>{'x': x, 'ok': ok});

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

  // Everybody of kFoldTree is a treasurer: five of eight make a majority.
  const List<String> five = <String>['S', 'A', 'B', 'A1', 'A2'];
  const List<String> all = <String>['S', 'A', 'B', 'A1', 'A2', 'B1', 'X', 'Y'];

  Future<PyramidRecord> fund(PyrLedger l, String who, int amount) async {
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

  test('a treasurer signs exactly what it would count once most signed it: '
      'a good order and settlement, and none dated before its money, '
      'uncovered, out of sequence, over the day\'s limit, to a non-member, '
      'or settling before its payment', () async {
    final PyrLedger base = PyrLedger();
    final PyramidRecord e = await fund(base, 'A1', 1000);
    // B1 got 300 from A1 at [start]; a payment waits for B1's word.
    final PyramidRecord toB1 = await order(start, 'A1', 'B1', 300, 1);
    base.merge(await signed(toB1, five));
    final PyramidRecord hold = await order(
      start + 10,
      'A1',
      'B1',
      100,
      2,
      cond: <String, dynamic>{'by': w.id('B1'), 'until': start + day},
    );
    base.merge(await signed(hold, five));
    final PyramidRecord lower = await w.rec(
      PyrT.emitRule,
      t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'xfers': kPyrMinXfers},
    );
    final PyramidState st = w.fold(<PyramidRecord>[e], now: start + h);
    final PyramidState limited = w.fold(<PyramidRecord>[
      e,
      lower,
    ], now: start + h);
    expect(limited.params.xferLimit, kPyrMinXfers);
    final PyrLedgerView v = base.compute(st, whole: true);
    expect(v.balanceOf(w.id('B1')), 300);
    expect(v.escrows[hold.id], isNotNull);
    // Three more of A1's orders today: with [lower] the next is over the
    // limit.
    final PyrLedger busy = PyrLedger.fromJson(base.toJson());
    for (int seq = 3; seq <= kPyrMinXfers; seq++) {
      busy.merge(
        await signed(await order(start + 10 + seq, 'A1', 'A2', 1, seq), five),
      );
    }
    final LedgerKeyPair outsider = await LedgerKeyPair.generate();

    final List<(String, PyrLedger, PyramidState, PyramidRecord, bool)> rows =
        <(String, PyrLedger, PyramidState, PyramidRecord, bool)>[
          ('good', base, st, await order(start + 20, 'A1', 'A2', 100, 3), true),
          (
            'dated before its money',
            base,
            st,
            await order(start - 9 * 60 * 1000, 'B1', 'A2', 300, 1),
            false,
          ),
          (
            'uncovered',
            base,
            st,
            await order(start + 20, 'A1', 'A2', 5000, 3),
            false,
          ),
          (
            'out of sequence',
            base,
            st,
            await order(start + 20, 'A1', 'A2', 10, 7),
            false,
          ),
          (
            'over the day\'s limit',
            busy,
            limited,
            await order(start + 30, 'A1', 'A2', 1, kPyrMinXfers + 1),
            false,
          ),
          (
            'to a non-member',
            base,
            st,
            await order(start + 20, 'A1', outsider.id, 10, 3),
            false,
          ),
          (
            'settling before its payment',
            base,
            st,
            await settle(start + 5, 'B1', hold.id, true),
            false,
          ),
          (
            'a good settlement',
            base,
            st,
            await settle(start + 20, 'B1', hold.id, true),
            true,
          ),
        ];
    for (final (
          String name,
          PyrLedger l,
          PyramidState s,
          PyramidRecord op,
          bool good,
        )
        in rows) {
      final String? why = l.problem(op, s, start + h);
      final PyrLedger after = PyrLedger.fromJson(l.toJson())
        ..merge(await signed(op, all));
      final bool counts = after.compute(s, whole: true).counted.contains(op.id);
      expect(
        why == null,
        counts,
        reason: '$name: signed $why, counted $counts',
      );
      expect(counts, good, reason: name);
    }

    // The payee of the order dated before its money keeps only its own
    // operations and would count it: it waits there, no money, until a
    // statement of the treasurers lists it — which none does.
    final PyramidRecord back = await signed(rows[1].$4, all);
    final PyrLedger payee = PyrLedger()
      ..merge(await signed(toB1, five))
      ..merge(back);
    final PyrLedgerView there = payee.compute(st, hold: w.id('A2'));
    expect(there.counted, contains(back.id));
    expect(there.held, contains(back.id));
    expect(there.balanceOf(w.id('A2')), 0);
  });

  test('a treasurer\'s statement fits a signal: a majority of signatures '
      'per operation, the newest operations while they fit, the newest ids '
      'only', () async {
    final PyrLedger l = PyrLedger();
    final PyramidRecord e = await fund(l, 'A1', 100000);
    // 55 payments to Y over two days, each signed by all eight.
    int last = start;
    for (int i = 1; i <= 55; i++) {
      last = start + (i > 25 ? day : 0) + i;
      l.merge(await signed(await order(last, 'A1', 'Y', 10, i), all));
    }
    final PyramidState st = w.fold(<PyramidRecord>[e], now: last + h);
    expect(l.compute(st, whole: true).balanceOf(w.id('Y')), 550);
    final Map<String, dynamic> frame = await PyramidService.statementFrame(
      l,
      st,
      w.id('Y'),
      w['S'],
      last + h,
    );
    // Sealed, a frame grows by a third (base64) and a key's ciphertext.
    final int sealed = utf8.encode(jsonEncode(frame)).length * 4 ~/ 3 + 4096;
    expect(sealed, lessThan(kRuntimeSignalMaxBytes));
    final List<Object?> ops = frame['ops'] as List<Object?>;
    expect(ops, isNotEmpty);
    for (final Object? o in ops) {
      expect(PyramidRecord.fromJson(o)!.tsigs, hasLength(5));
    }
    final PyrStatement s = PyrStatement.fromJson(frame['st'])!;
    expect(s.ids, hasLength(55));
    expect(s.balance, 550);
    expect(s.from, 0);
    // A long history: only the newest ids, and from when all are listed.
    final Map<String, int> many = <String, int>{
      for (int i = 0; i < kPyrStatementIds + 500; i++) 'op$i': i ~/ 2,
    };
    final (List<String> ids, int from) = PyrStatement.window(many);
    expect(ids.length, lessThanOrEqualTo(kPyrStatementIds));
    expect(ids.toSet(), <String>{
      for (final MapEntry<String, int> x in many.entries)
        if (x.value >= from) x.key,
    });
  });
}
