import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The treasurers' side of the money on simulated phones and on bare
/// ledgers: a number split between orders is not lost, an order that
/// counts is never replaced, what anybody sends a treasurer is kept only
/// when treasurers made it, the ledger goes only to who asked for it, and
/// no balance wraps around.
void main() {
  void online(PyramidWorld w, List<String> who, bool on) {
    for (final String n in who) {
      w.net.setOnline(w.net[n], on);
    }
  }

  /// Days pass with every duty run and every phone in touch.
  Future<void> settle(PyramidWorld w, {int days = 2}) async {
    for (int d = 0; d < 2 * days; d++) {
      await w.net.advance(const Duration(hours: 12));
      await w.duties(rounds: 2);
      await w.sync();
    }
  }

  const List<String> treasurers = <String>['S', 'A', 'B', 'A1', 'A2', 'B1'];

  group('a number split between orders', () {
    test('split between two cancelled orders, three signatures each of the '
        'four needed: the next order with the number counts', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      final String b1 = w['B1'].myKey!;
      expect(w['S'].state!.treasurers, hasLength(6));
      w.net.holdForOffline = false;
      // S, A, B away: the order gets A1, A2, B1 (3 of 6, needs 4).
      online(w, <String>['S', 'A', 'B'], false);
      final PyramidRecord? o1 = await w['A1'].pay(b1, 100);
      await w.net.run();
      expect(w['A1'].pendingPayments.single.tsigs, hasLength(3));
      w['A1'].cancelPending(o1!.id);
      // A2 and B1 away, S, A, B back: a new order, the same number.
      online(w, <String>['S', 'A', 'B'], true);
      online(w, <String>['A2', 'B1'], false);
      final PyramidRecord? o2 = await w['A1'].pay(b1, 100);
      expect(o2!.integer('seq'), o1.integer('seq'));
      await w.net.run();
      expect(w['A1'].pendingPayments.single.tsigs, hasLength(3));
      w['A1'].cancelPending(o2.id);
      // Everybody back: the third order with the number counts.
      online(w, <String>['A2', 'B1'], true);
      w.net.holdForOffline = true;
      final PyramidRecord? o3 = await w['A1'].pay(b1, 100);
      expect(o3!.integer('seq'), o1.integer('seq'));
      await settle(w);
      expect(w['A1'].pendingPayments, isEmpty);
      for (final String t in treasurers) {
        expect(w[t].ledgerBalanceOf(b1), 100, reason: t);
        expect(w[t].ledgerCheaters, isEmpty, reason: t);
      }
      expect(w['A1'].balance, 9900);
      // The number after it is free.
      final PyramidRecord? next = await w['A1'].pay(b1, 50);
      expect(next!.integer('seq'), o1.integer('seq') + 1);
      await w.net.run();
      expect(w['S'].ledgerBalanceOf(b1), 150);
    });

    test('a cancelled order that can no longer count is replaced: the new '
        'one counts with the signatures of those who signed the old one', () {
      return () async {
        final PyramidWorld w = await PyramidWorld.six();
        await w.fund('A1', 10000);
        final String b1 = w['B1'].myKey!;
        w.net.holdForOffline = false;
        online(w, <String>['S', 'A', 'B'], false);
        final PyramidRecord? o1 = await w['A1'].pay(b1, 100);
        await w.net.run();
        expect(w['A1'].pendingPayments.single.tsigs, hasLength(3));
        w['A1'].cancelPending(o1!.id);
        online(w, <String>['S', 'A', 'B'], true);
        w.net.holdForOffline = true;
        final PyramidRecord? o2 = await w['A1'].pay(b1, 100);
        expect(o2!.integer('seq'), o1.integer('seq'));
        await settle(w, days: 1);
        expect(w['S'].ledgerBalanceOf(b1), 100);
        expect(w['A1'].balance, 9900);
        expect(w['A1'].pendingPayments, isEmpty);
        expect(w['S'].ledgerCheaters, isEmpty);
      }();
    });

    test(
      'an order that counts is never replaced: a second order with its '
      'number gets only the signatures of those who signed nothing',
      () async {
        final PyramidWorld w = await PyramidWorld.six();
        await w.fund('A1', 10000);
        final String b1 = w['B1'].myKey!;
        final String a2 = w['A2'].myKey!;
        // S and A away: the order counts with A1, A2, B, B1.
        w.net.holdForOffline = false;
        online(w, <String>['S', 'A'], false);
        final PyramidRecord? paid = await w['A1'].pay(b1, 100);
        await w.net.run();
        expect(w['A1'].pendingPayments, isEmpty);
        online(w, <String>['S', 'A'], true);
        w.net.holdForOffline = true;
        // A1's other device (or a changed app) orders the same number again,
        // later, to someone else, and sends it to every treasurer.
        final PyramidRecord again = await w['A1'].signAsMe(
          PyramidRecord(
            body: <String, dynamic>{
              ...paid!.body,
              'at': w.net.now + 1000,
              'to': a2,
              'nc': 'another',
            },
          ),
        );
        for (final String t in treasurers) {
          await w['A1'].sendSealed(w[t].myKey!, <String, dynamic>{
            'k': 'ord',
            'r': again.toJson(),
          });
        }
        await w.net.run();
        await settle(w);
        for (final String t in treasurers) {
          expect(w[t].ledgerBalanceOf(b1), 100, reason: t);
          expect(w[t].ledgerBalanceOf(a2), 0, reason: t);
          expect(w[t].ledgerCheaters, isEmpty, reason: t);
        }
        expect(w['A1'].balance, 9900);
      },
    );

    test(
      'two devices of one account take the same number at once: one of '
      'the orders counts, the other is dropped, the next number is free',
      () async {
        final PyramidWorld w = await PyramidWorld.six();
        await w.fund('A1', 10000);
        final String b1 = w['B1'].myKey!;
        final String a2 = w['A2'].myKey!;
        w.net.holdForOffline = false;
        // This device reaches A1, A2, B1; the other device S, A, B (its
        // signatures come back to this device's address, which does not know
        // that order).
        online(w, <String>['S', 'A', 'B'], false);
        final PyramidRecord? here = await w['A1'].pay(b1, 100);
        await w.net.run();
        expect(w['A1'].pendingPayments.single.tsigs, hasLength(3));
        online(w, <String>['S', 'A', 'B'], true);
        online(w, <String>['A2', 'B1'], false);
        final PyramidRecord there = await w['A1'].signAsMe(
          PyramidRecord(
            body: <String, dynamic>{
              ...here!.body,
              'at': w.net.now + 1000,
              'to': a2,
              'nc': 'other-device',
            },
          ),
        );
        for (final String t in <String>['S', 'A', 'B']) {
          await w['A1'].sendSealed(w[t].myKey!, <String, dynamic>{
            'k': 'ord',
            'r': there.toJson(),
          });
        }
        await w.net.run();
        online(w, <String>['A2', 'B1'], true);
        w.net.holdForOffline = true;
        await settle(w);
        // The later one counts on every treasurer's ledger; the earlier one
        // waits no more.
        for (final String t in treasurers) {
          expect(w[t].ledgerBalanceOf(a2), 100, reason: t);
          expect(w[t].ledgerBalanceOf(b1), 0, reason: t);
          expect(w[t].ledgerCheaters, isEmpty, reason: t);
        }
        await w.net.advance(const Duration(hours: 13));
        await w.duties(rounds: 2);
        expect(w['A1'].balance, 9900);
        expect(w['A1'].pendingPayments, isEmpty);
        final PyramidRecord? next = await w['A1'].pay(b1, 50);
        expect(next!.integer('seq'), here.integer('seq') + 1);
        await w.net.run();
        expect(w['S'].ledgerBalanceOf(b1), 50);
      },
    );

    test('a conditional payment accepted late by some treasurers and taken '
        'back by the others around its time is not frozen', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      final String b1 = w['B1'].myKey!;
      final PyramidRecord? hold = await w['A1'].pay(
        b1,
        700,
        condBy: b1,
        condUntil: w.net.now + 3600 * 1000,
      );
      await w.net.run();
      expect(w['S'].ledgerBalanceOf(w['A1'].myKey!), 9300);
      // Just before the time: the payee accepts, only A1, A2, B1 get it.
      await w.net.advance(const Duration(minutes: 59));
      w.net.holdForOffline = false;
      online(w, <String>['S', 'A', 'B'], false);
      await w['B1'].settle(hold!.id, true);
      await w.net.run();
      // After the time: the payer takes it back, only S, A, B get it.
      online(w, <String>['S', 'A', 'B'], true);
      online(w, <String>['A2', 'B1'], false);
      await w.net.advance(const Duration(minutes: 15));
      await w['A1'].settle(hold.id, false);
      await w.net.run();
      online(w, <String>['A2', 'B1'], true);
      w.net.holdForOffline = true;
      await settle(w);
      final int payer = w['S'].ledgerBalanceOf(w['A1'].myKey!);
      final int payee = w['S'].ledgerBalanceOf(b1);
      // The acceptance can no longer count once the three who did not
      // sign it took the later refund: those who signed it take that too.
      expect(payer, 10000);
      expect(payee, 0);
      for (final String t in treasurers) {
        expect(w[t].ledgerBalanceOf(b1), payee, reason: t);
        expect(w[t].ledgerCheaters, isEmpty, reason: t);
      }
    });
  });

  group('what a treasurer keeps', () {
    Future<PyramidRecord> junk(
      PyramidWorld w,
      String who,
      int seq, {
      int size = 1000 * 1000,
    }) => w[who].signAsMe(
      PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.transfer,
          'py': w['S'].state!.id,
          'at': 1,
          'by': <String>[w[who].myKey!],
          'from': w[who].myKey!,
          'to': w[who].myKey!,
          'amount': -1,
          'seq': seq,
          'memo': 'x' * size,
        },
      ),
    );

    test('operations no treasurer signed, sent as counting, are kept by '
        'nobody, and the treasurers\' ledgers stay the same', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      await w['A1'].pay(w['B1'].myKey!, 100);
      await w.net.run();
      final PyramidService b1 = w['B1'];
      final Set<String> before = w['S'].ledgerIds;
      for (int i = 0; i < 7; i++) {
        final PyramidRecord j = await junk(w, 'B1', i);
        for (final String t in treasurers.where((String t) => t != 'B1')) {
          await b1.sendSealed(w[t].myKey!, <String, dynamic>{
            'k': 'fin',
            'ops': <Map<String, dynamic>>[j.toJson()],
          });
          // Through the treasurers' own sync too.
          await b1.sendSealed(w[t].myKey!, <String, dynamic>{
            'k': 'lops',
            'ops': <Map<String, dynamic>>[j.toJson()],
          });
        }
      }
      // A small order of B1's own, never sent to a treasurer.
      final PyramidRecord small = await junk(w, 'B1', 1, size: 10);
      await b1.sendSealed(w['S'].myKey!, <String, dynamic>{
        'k': 'fin',
        'ops': <Map<String, dynamic>>[small.toJson()],
      });
      await w.net.run();
      expect(w['S'].ledgerIds, before);
      await settle(w, days: 1);
      final Set<String> s = w['S'].ledgerIds;
      for (final String t in treasurers) {
        expect(w[t].ledgerIds, s, reason: t);
      }
    });

    test('junk stored before is dropped, and the ledgers meet again', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      await w['A1'].pay(w['B1'].myKey!, 100);
      await w.net.run();
      final Set<String> clean = w['S'].ledgerIds;
      // S's stored ledger with junk in it, as an older build kept it.
      final PyramidService s = w['S'];
      final Map<String, dynamic> stored = Map<String, dynamic>.from(
        jsonDecode(utf8.decode((await s.disk.read('pyramid/ledger'))!)) as Map,
      );
      final Map<String, dynamic> l = Map<String, dynamic>.from(
        stored['l'] as Map,
      );
      l['ops'] = <Object?>[
        ...l['ops'] as List,
        for (int i = 0; i < 3; i++) (await junk(w, 'B1', i)).toJson(),
      ];
      stored['l'] = l;
      await s.disk.write('pyramid/ledger', utf8.encode(jsonEncode(stored)));
      await s.load();
      expect(s.ledgerIds.length, clean.length + 3);
      await settle(w, days: 1);
      for (final String t in treasurers) {
        expect(w[t].ledgerIds, clean, reason: t);
      }
    });

    test('of one payer\'s operations that do not count, even signed by a '
        'treasurer, every treasurer keeps the same few dozen newest', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      // Treasurer A, dishonest, signs a heap of B1's orders that count
      // nowhere and spreads them as its ledger.
      final LedgerKeyPair a = await LedgerKeyPair.fromSeed(
        (await w.seedOf(w['A'].disk)())!,
      );
      expect(a.id, w['A'].myKey);
      final List<Map<String, dynamic>> heap = <Map<String, dynamic>>[];
      final List<String> ids = <String>[];
      for (int i = 0; i < kPyrMaxEvidencePerPayer + 8; i++) {
        final PyramidRecord op = await w['B1'].signAsMe(
          PyramidRecord(
            body: <String, dynamic>{
              't': PyrT.transfer,
              'py': w['S'].state!.id,
              'at': w.net.now - 1000 + i,
              'by': <String>[w['B1'].myKey!],
              'from': w['B1'].myKey!,
              'to': w['A2'].myKey!,
              'amount': 5,
              'seq': 1,
              'memo': '',
              'nc': 'heap-$i',
            },
          ),
        );
        ids.add(op.id);
        heap.add(
          op
              .withTreasurerSig(
                a.id,
                b64(await a.sign(PyramidRecord.treasurerBytes(op.id))),
              )
              .toJson(),
        );
      }
      for (final String t in treasurers.where((String t) => t != 'A')) {
        await w['A'].sendSealed(w[t].myKey!, <String, dynamic>{
          'k': 'lops',
          'ops': heap,
        });
      }
      await w.net.run();
      await settle(w, days: 1);
      final Set<String> newest = ids.reversed
          .take(kPyrMaxEvidencePerPayer)
          .toSet();
      for (final String t in treasurers) {
        expect(w[t].ledgerIds.intersection(ids.toSet()), newest, reason: t);
      }
      final Set<String> s = w['S'].ledgerIds;
      for (final String t in treasurers) {
        expect(w[t].ledgerIds, s, reason: t);
      }
    });
  });

  group('the treasurers\' sync', () {
    test(
      'a ledger goes only to the treasurer who asks for it itself',
      () async {
        final PyramidWorld w = await PyramidWorld.six();
        await w.fund('A1', 10000);
        await w['A1'].pay(w['B1'].myKey!, 100);
        await w.net.run();
        final SimPhone s = w.net['S'];
        int before = s.outbox.length;
        // B1 names A as the one who wants.
        for (int i = 0; i < 5; i++) {
          await w['B1'].sendSealed(w['S'].myKey!, <String, dynamic>{
            'k': 'lwant',
            'f': w['A'].myKey!,
            'b': <String>[
              for (final String c in '0123456789abcdef'.split('')) c,
              'n',
            ],
          });
          await w['B1'].sendSealed(w['S'].myKey!, <String, dynamic>{
            'k': 'ldig',
            'f': w['A'].myKey!,
            'd': <String, String>{},
          });
        }
        await w.net.run();
        expect(s.outbox.length - before, 0);
        // A asks for itself: answered.
        before = s.outbox.length;
        await w['A'].sendSealed(w['S'].myKey!, <String, dynamic>{
          'k': 'lwant',
          'f': w['A'].myKey!,
          'b': <String>[for (final String c in '0123456789abcdef'.split('')) c],
        });
        await w.net.run();
        expect(s.outbox.length - before, greaterThan(0));
      },
    );
  });

  group('rules on bare ledgers', () {
    const int t0 = FoldWorld.t0;
    const int h = FoldWorld.hour;
    const int day = FoldWorld.day;
    const int start = t0 + 2 * day + h;
    late FoldWorld w;

    setUp(() async => w = await FoldWorld.make());

    Future<PyramidRecord> order(
      int at,
      String from,
      String to,
      int amount,
      int seq, {
      String nc = '',
    }) => w.rec(
      PyrT.transfer,
      at,
      <String>[from],
      <String, dynamic>{
        'from': w.id(from),
        'to': w.id(to),
        'amount': amount,
        'seq': seq,
        'memo': '',
        if (nc.isNotEmpty) 'nc': nc,
      },
    );

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

    test('an order with a majority of its era is never left behind, '
        'whoever signs later ones; one without it is, once enough of the '
        'others signed later ones', () async {
      final PyramidState st = w.fold(<PyramidRecord>[], now: start);
      expect(st.treasurersAt(start), hasLength(8));
      // Eight treasurers, five needed: three may move on.
      final PyramidRecord counted = await signed(
        await order(start, 'A1', 'B1', 1, 1),
        <String>['S', 'A', 'B', 'A1', 'A2'],
      );
      final PyramidRecord later = await signed(
        await order(start + 1, 'A1', 'X', 1, 1),
        <String>['B1', 'X', 'Y'],
      );
      expect(PyrLedger.passed(counted, <PyramidRecord>[later], st), isFalse);
      final PyramidRecord four = await signed(
        await order(start, 'A1', 'B1', 1, 1, nc: 'four'),
        <String>['S', 'A', 'B', 'A1'],
      );
      // Three moved on: four plus the three can never be five... unless
      // one of the three signed both, which is proof against it.
      expect(PyrLedger.passed(four, <PyramidRecord>[later], st), isFalse);
      final PyramidRecord three = await signed(
        await order(start, 'A1', 'B1', 1, 1, nc: 'three'),
        <String>['S', 'A', 'B'],
      );
      final PyramidRecord moved = await signed(
        await order(start + 1, 'A1', 'X', 1, 1, nc: 'moved'),
        <String>['A1', 'A2', 'B1', 'X'],
      );
      expect(PyrLedger.passed(three, <PyramidRecord>[moved], st), isTrue);
      // Only later ones count: an earlier order never frees a later one.
      expect(PyrLedger.passed(moved, <PyramidRecord>[three], st), isFalse);
      // Those who moved on are not caught; who signed both while the first
      // could still count is.
      final PyrLedger l = PyrLedger()
        ..merge(three)
        ..merge(moved)
        ..merge(await signed(moved, <String>['S']));
      expect(l.compute(st).cheaters, isEmpty);
      final PyrLedger m = PyrLedger()
        ..merge(four)
        ..merge(await signed(later, <String>['S']));
      expect(m.compute(st).cheaters.keys, <String>[w.id('S')]);
    });

    test('no balance passes the limit, however many treasurers sign: the '
        'order counts nowhere', () async {
      final PyramidState st = w.fold(<PyramidRecord>[], now: start);
      // All the money there is, nearly: emitted to Y (as if over a century
      // of the largest emissions).
      final PyrLedger l = PyrLedger();
      final PyrEmitNote note = PyrEmitNote(
        rc: pyrEmitCommit(w.id('Y'), 'salt'),
        to: w.id('Y'),
        salt: 'salt',
      );
      l.mergeNote(note);
      st.emissions['e1'] = PyrEmission(
        id: 'e1',
        rc: note.rc,
        amount: kPyrMaxBalance - 500,
        term: 1,
        at: t0 + day,
        signedAt: t0 + day,
        effectiveAt: t0 + day,
        signers: const <String>[],
      )..done = true;
      // One more emission would pass all the money there may be: it is
      // not credited.
      final PyrEmitNote more = PyrEmitNote(
        rc: pyrEmitCommit(w.id('X'), 'salt2'),
        to: w.id('X'),
        salt: 'salt2',
      );
      l.mergeNote(more);
      st.emissions['e2'] = PyrEmission(
        id: 'e2',
        rc: more.rc,
        amount: 1000,
        term: 1,
        at: t0 + day + 1,
        signedAt: t0 + day + 1,
        effectiveAt: t0 + day + 1,
        signers: const <String>[],
      )..done = true;
      // Most treasurers sign A1 paying Y, with nothing behind it: a phone
      // that keeps only its own operations cannot check the money.
      final PyramidRecord over = await signed(
        await order(start, 'A1', 'Y', 1000, 1),
        <String>['S', 'A', 'B', 'A1', 'A2'],
      );
      l.merge(over);
      final PyrLedgerView v = l.compute(st);
      expect(v.balanceOf(w.id('Y')), kPyrMaxBalance - 500);
      expect(v.balanceOf(w.id('X')), 0);
      expect(v.broken[over.id], 'saldo poza zakresem');
      // A number past the highest counts nowhere either.
      final PyramidRecord far = await signed(
        await order(start + 1, 'A1', 'B1', 10, kPyrMaxSeq + 1),
        <String>['S', 'A', 'B', 'A1', 'A2'],
      );
      expect(PyrLedger.breaks(far, st), 'zły przelew');
      // A statement past the limit is not even read.
      final LedgerKeyPair k = w['S'];
      expect(
        PyrStatement.fromJson(<String, dynamic>{
          'py': w.py,
          'a': w.id('Y'),
          'bal': kPyrMaxBalance + 1,
          'seq': 1,
          'at': start,
          'ids': <String>[],
          'by': k.id,
          'sig': '',
        }),
        isNull,
      );
    });
  });
}
