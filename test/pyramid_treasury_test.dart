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

    test('a number split three and three is free again within two hours of '
        'the treasurers meeting, and not before they waited for the order '
        'held back to come out', () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w.fund('A1', 10000);
      final String b1 = w['B1'].myKey!;
      w.net.holdForOffline = false;
      online(w, <String>['S', 'A', 'B'], false);
      final PyramidRecord? o1 = await w['A1'].pay(b1, 100);
      await w.net.run();
      w['A1'].cancelPending(o1!.id);
      online(w, <String>['S', 'A', 'B'], true);
      online(w, <String>['A2', 'B1'], false);
      await w['A1'].pay(b1, 100);
      await w.net.run();
      online(w, <String>['A2', 'B1'], true);
      w.net.holdForOffline = true;
      final int met = w.net.now;
      int? freed;
      for (int i = 0; i < 16 && freed == null; i++) {
        await w.net.advance(const Duration(minutes: 15));
        await w.duties(rounds: 1);
        if (w['S'].ledgerBalanceOf(b1) == 100) {
          freed = w.net.now - met;
        }
      }
      expect(freed, isNotNull);
      expect(freed, greaterThanOrEqualTo(kPyrReleaseWaitMs));
      expect(freed, lessThanOrEqualTo(kPyrReleaseWaitMs + 3600 * 1000));
      await settle(w, days: 1);
      for (final String t in treasurers) {
        expect(w[t].ledgerBalanceOf(b1), 100, reason: t);
        expect(w[t].ledgerCheaters, isEmpty, reason: t);
      }
      expect(w['A1'].balance, 9900);
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
        // Neither could reach four: most treasurers released the number,
        // and the order still waiting on this device went out again after
        // the release and counts on every treasurer's ledger; the other
        // device's counts nowhere.
        for (final String t in treasurers) {
          expect(w[t].ledgerBalanceOf(b1), 100, reason: t);
          expect(w[t].ledgerBalanceOf(a2), 0, reason: t);
          expect(w[t].ledgerCheaters, isEmpty, reason: t);
        }
        await w.net.advance(const Duration(hours: 13));
        await w.duties(rounds: 2);
        expect(w['A1'].balance, 9900);
        expect(w['A1'].pendingPayments, isEmpty);
        final PyramidRecord? next = await w['A1'].pay(b1, 50);
        expect(next!.integer('seq'), here.integer('seq') + 1);
        await w.net.run();
        expect(w['S'].ledgerBalanceOf(b1), 150);
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

  group('a dishonest treasurer among six', () {
    /// [op] with treasurer [who]'s signature made with its key outside its
    /// app: no other treasurer sees it until somebody shows the operation.
    Future<PyramidRecord> hiddenSig(
      PyramidWorld w,
      String who,
      PyramidRecord op,
    ) async {
      final LedgerKeyPair k = await LedgerKeyPair.fromSeed(
        (await w.seedOf(w[who].disk)())!,
      );
      expect(k.id, w[who].myKey);
      return op.withTreasurerSig(
        k.id,
        b64(await k.sign(PyramidRecord.treasurerBytes(op.id))),
      );
    }

    /// A1 pays B1 while S, A and B are away (A1, A2, B1 sign: three of the
    /// four needed); A signs it too out of sight — a majority, which A and
    /// the payer keep to themselves; the payer gives the order up and pays
    /// the same number to A2 while A2 and B1 are away (S, A, B sign).
    Future<PyramidRecord> splitWithHidden(PyramidWorld w) async {
      await w.fund('A1', 10000);
      w.net.holdForOffline = false;
      online(w, <String>['S', 'A', 'B'], false);
      final PyramidRecord? x = await w['A1'].pay(w['B1'].myKey!, 100);
      await w.net.run();
      final PyramidRecord signed = w['A1'].pendingPayments.single;
      expect(signed.tsigs, hasLength(3));
      final PyramidRecord held = await hiddenSig(w, 'A', signed);
      expect(PyrLedger.isFinal(held, w['S'].state!), isTrue);
      w['A1'].cancelPending(x!.id);
      online(w, <String>['S', 'A', 'B'], true);
      online(w, <String>['A2', 'B1'], false);
      final PyramidRecord? y = await w['A1'].pay(w['A2'].myKey!, 100);
      expect(y!.integer('seq'), x.integer('seq'));
      await w.net.run();
      online(w, <String>['A2', 'B1'], true);
      w.net.holdForOffline = true;
      return held;
    }

    Future<void> show(PyramidWorld w, PyramidRecord op) async {
      for (final String t in treasurers) {
        await w['A1'].sendSealed(w[t].myKey!, <String, dynamic>{
          'k': 'fin',
          'ops': <Map<String, dynamic>>[op.toJson()],
        });
      }
      await w.net.run();
    }

    test('one of six signs an order out of sight and the next order for '
        'its number too: the order shown later takes nothing from the one '
        'that counted, and only that treasurer is named', () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String b1 = w['B1'].myKey!;
      final String a2 = w['A2'].myKey!;
      final String payer = w['A1'].myKey!;
      final PyramidRecord held = await splitWithHidden(w);
      await settle(w);
      final Map<String, (int, int)> before = <String, (int, int)>{
        for (final String t in treasurers)
          t: (w[t].ledgerBalanceOf(b1), w[t].ledgerBalanceOf(a2)),
      };
      // The order with four signatures comes out after the number moved
      // on.
      await show(w, held);
      await settle(w, days: 1);
      for (final String t in treasurers) {
        expect(
          (w[t].ledgerBalanceOf(b1), w[t].ledgerBalanceOf(a2)),
          before[t],
          reason: t,
        );
        expect(
          w[t].ledgerBalanceOf(b1) + w[t].ledgerBalanceOf(a2),
          100,
          reason: t,
        );
        expect(w[t].ledgerBalanceOf(payer), 9900, reason: t);
        expect(w[t].ledgerCheaters.keys, <String>[w['A'].myKey!], reason: t);
      }
    });

    test('the order signed out of sight, shown before the number moved on, '
        'counts; the other never does, and the one who signed both is '
        'named', () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String b1 = w['B1'].myKey!;
      final String a2 = w['A2'].myKey!;
      final PyramidRecord held = await splitWithHidden(w);
      await show(w, held);
      await settle(w);
      for (final String t in treasurers) {
        expect(w[t].ledgerBalanceOf(b1), 100, reason: t);
        expect(w[t].ledgerBalanceOf(a2), 0, reason: t);
        expect(w[t].ledgerCheaters.keys, <String>[w['A'].myKey!], reason: t);
      }
      expect(w['A1'].pendingPayments, isEmpty);
      expect(w['A1'].balance, 9900);
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
              'after': w['S'].state!.seals.length,
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

    setUp(() async {
      w = await FoldWorld.make();
      // The founder sealed its era: the eight sign (orders of era 2).
      w.records.add(await w.sealFirst());
    });

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
        'after': 1,
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

    /// The release of the first span of A1's number 1, voted for by [who].
    Future<PyramidRecord> release(
      PyramidState st,
      List<String> who, {
      int? at,
    }) async {
      final PyramidRecord r = PyrLedger.releaseOf(
        pyramid: w.py,
        slot: '${w.id('A1')}|1',
        prev: '',
        at: at ?? st.sealedTo,
      );
      return signed(r, who);
    }

    test('a span of a number is split only when no order of it can reach a '
        'majority whoever signs; nothing frees it but a release most '
        'treasurers vote for', () async {
      final PyramidState st = w.fold(<PyramidRecord>[], now: start);
      expect(st.treasurersAt(start), hasLength(8));
      final List<String> t = st.treasurersAt(start);
      // Eight treasurers, five needed.
      final PyramidRecord counted = await signed(
        await order(start, 'A1', 'B1', 1, 1),
        <String>['S', 'A', 'B', 'A1', 'A2'],
      );
      final PyramidRecord later = await signed(
        await order(start + 1, 'A1', 'X', 1, 1),
        <String>['B1', 'X', 'Y'],
      );
      expect(PyrLedger.isSplit(<PyramidRecord>[counted, later], t), isFalse);
      // Four and three, A2 has signed nothing: the four may still count.
      final PyramidRecord four = await signed(
        await order(start, 'A1', 'B1', 1, 1, nc: 'four'),
        <String>['S', 'A', 'B', 'A1'],
      );
      expect(PyrLedger.isSplit(<PyramidRecord>[four, later], t), isFalse);
      // Three and four, Y has signed nothing: the four may still count.
      final PyramidRecord three = await signed(
        await order(start, 'A1', 'B1', 1, 1, nc: 'three'),
        <String>['S', 'A', 'B'],
      );
      final PyramidRecord moved = await signed(
        await order(start + 1, 'A1', 'X', 1, 1, nc: 'moved'),
        <String>['A1', 'A2', 'B1', 'X'],
      );
      expect(PyrLedger.isSplit(<PyramidRecord>[three, moved], t), isFalse);
      // Y signs a third order: none of them can reach five any more.
      final PyramidRecord third = await signed(
        await order(start + 2, 'A1', 'A2', 1, 1, nc: 'third'),
        <String>['Y'],
      );
      final List<PyramidRecord> split = <PyramidRecord>[three, moved, third];
      expect(PyrLedger.isSplit(split, t), isTrue);
      final PyrLedger l = PyrLedger();
      split.forEach(l.merge);
      // Four votes are not enough: the span stays, nothing counts.
      l.mergeRelease(await release(st, <String>['S', 'A', 'B', 'A1']));
      expect(l.compute(st).releases, isEmpty);
      // The fifth: the span is left behind; the order after the release
      // counts, signed by those who signed the orders before it.
      l.mergeRelease(await release(st, <String>['A2']));
      final PyrLedgerView v = l.compute(st);
      final String rel = v.releases['${w.id('A1')}|1']!;
      expect(v.counted, isEmpty);
      final PyramidRecord after = await signed(
        await w.rec(
          PyrT.transfer,
          start + 3,
          <String>['A1'],
          <String, dynamic>{
            'from': w.id('A1'),
            'to': w.id('B1'),
            'amount': 1,
            'seq': 1,
            'after': 1,
            'memo': '',
            'rel': rel,
          },
        ),
        <String>['S', 'A', 'A1', 'A2', 'Y'],
      );
      l.merge(after);
      final PyrLedgerView again = l.compute(st);
      expect(again.counted, <String>{after.id});
      expect(again.leftBehind(three, st), isTrue);
      expect(again.leftBehind(after, st), isFalse);
      // Nobody signed two operations of one span.
      expect(again.cheaters, isEmpty);
      // Who signs two of one span is caught, whether they counted or not.
      final PyrLedger m = PyrLedger()
        ..merge(four)
        ..merge(await signed(later, <String>['S']));
      expect(m.compute(st).cheaters.keys, <String>[w.id('S')]);
      // So is who votes for two releases of one span.
      m
        ..mergeRelease(await release(st, <String>['S', 'B']))
        ..mergeRelease(await release(st, <String>['B'], at: start));
      expect(
        m.compute(st).cheaters.keys,
        unorderedEquals(<String>[w.id('S'), w.id('B')]),
      );
    });

    test('two dishonest treasurers of eight get two orders of one number '
        'counted, as they could before; they are named, and they cannot '
        'release a number one order took', () async {
      final PyramidState st = w.fold(<PyramidRecord>[], now: start);
      final List<String> t = st.treasurersAt(start);
      // A and B sign both; three honest ones sign each.
      final PyramidRecord x = await signed(
        await order(start, 'A1', 'B1', 1, 1, nc: 'x'),
        <String>['S', 'A1', 'A2', 'A', 'B'],
      );
      final PyramidRecord y = await signed(
        await order(start + 1, 'A1', 'X', 1, 1, nc: 'y'),
        <String>['B1', 'X', 'Y', 'A', 'B'],
      );
      expect(PyrLedger.isFinal(x, st), isTrue);
      expect(PyrLedger.isFinal(y, st), isTrue);
      // A phone that holds only one counts it; one that holds both counts
      // the earlier, and names the two.
      expect((PyrLedger()..merge(y)).compute(st).counted, <String>{y.id});
      final PyrLedger both = PyrLedger()
        ..merge(x)
        ..merge(y);
      final PyrLedgerView v = both.compute(st);
      expect(v.counted, <String>{x.id});
      expect(v.cheaters.keys, unorderedEquals(<String>[w.id('A'), w.id('B')]));
      // One dishonest treasurer alone gets no second order to a majority.
      final PyramidRecord z = await signed(
        await order(start + 2, 'A1', 'Y', 1, 1, nc: 'z'),
        <String>['B1', 'X', 'Y', 'A'],
      );
      expect(PyrLedger.isFinal(z, st), isFalse);
      // No honest treasurer votes to release a span with an order that
      // counts, and the two alone release nothing.
      expect(PyrLedger.isSplit(<PyramidRecord>[x, y], t), isFalse);
      both.mergeRelease(await release(st, <String>['A', 'B']));
      expect(both.compute(st).counted, <String>{x.id});
      expect(both.compute(st).releases, isEmpty);
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
