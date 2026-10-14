import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'pyramid_security_test.dart' show Six, day, h, rec, t0;
import 'support/pyramid_world.dart';

/// Money and the inboxes of the pyramid: reports and appeals only from
/// members and within limits (S1), treasurer signatures never replaced
/// (S12), money of a pyramid that joins another (§20.5) and money paid
/// from one pyramid to another through someone in both (§23.5).
void main() {
  /// Emits [amount] to [who] (S proposes, B signs) and waits the 24 h.
  Future<void> fund(PyramidWorld w, String who, int amount) async {
    await w['S'].emit(w[who].myKey!, amount, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
  }

  Map<String, dynamic> stored(PyramidService s, String key) =>
      jsonDecode(utf8.decode((s.disk as MemoryLedgerDisk).files[key]!))
          as Map<String, dynamic>;

  test('conversion never wraps and rounds the right way', () {
    expect(pyrConvert(10000, 1, 2), 5000);
    expect(pyrConvert(3, 1, 2), 1);
    expect(pyrConvert(-5, 1, 1), 0);
    expect(pyrConvert(kPyrMaxBalance, kPyrMaxRate, 1), kPyrMaxAmount);
    expect(pyrConvertUp(1, 1, 2), 2);
    expect(pyrConvertUp(1000, 5000, 10000), 2000);
    expect(pyrConvertUp(kPyrMaxAmount, 1, kPyrMaxRate), kPyrMaxAmount);
    final String lock = sha256Hex(utf8.encode('klucz'));
    expect(pyrIsLock(lock), isTrue);
    expect(pyrUnlocks(lock, 'klucz'), isTrue);
    expect(pyrUnlocks(lock, 'inny'), isFalse);
    // What the wallet shows reads back (grouped with non-breaking spaces).
    expect(parseMoney(formatMoney(123456789)), 123456789);
    expect(formatMoney(123456789), contains(','));
  });

  group('reports and appeals (S1)', () {
    test(
      'only members, only to those who take them, cut to size and counted',
      () async {
        final PyramidWorld w = await PyramidWorld.six();
        final PyramidService s = w['S'];
        final SimPhone z = w.add('Z');
        await w['Z'].load();
        final String b1 = w['B1'].myKey!;
        Map<String, dynamic> report(String id, {String evidence = 'x'}) =>
            <String, dynamic>{
              'type': PyramidTypes.report,
              'id': id,
              'why': 'spam',
              'at': w.net.now,
              't': '',
              'ev': evidence,
            };

        // A stranger: neither reports nor appeals get in.
        await z.send(w.net['S'].address, report('obcy'));
        await z.send(w.net['S'].address, <String, dynamic>{
          'type': PyramidTypes.appeal,
          'rep': 'r',
          't': 'odwołanie',
          'k': b1,
        });
        await w.net.run();
        expect(s.inbox, isEmpty);
        expect(s.appeals, isEmpty);

        // A member floods the top with huge reports: a few are kept, cut.
        final String huge = 'x' * 100000;
        for (int i = 0; i < 15; i++) {
          await w.net['B1'].send(
            w.net['S'].address,
            report('r$i', evidence: huge),
          );
        }
        // A member who is neither the top nor a delegate takes none.
        await w.net['B1'].send(w.net['A1'].address, report('boczny'));
        await w.net.run();
        expect(s.inbox, hasLength(kPyrReportsPerSender));
        expect(
          s.inbox.values.every(
            (PyrReport r) => r.evidence.length <= kPyrReportEvidenceChars,
          ),
          isTrue,
        );
        expect(w['A1'].inbox, isEmpty);

        // Appeals: the key must be the sender's own; one per report.
        for (final String k in <String>[w['A2'].myKey!, b1, b1]) {
          await w.net['B1'].send(w.net['S'].address, <String, dynamic>{
            'type': PyramidTypes.appeal,
            'rep': 'r1',
            't': 'y' * 50000,
            'k': k,
          });
        }
        await w.net.run();
        expect(s.appeals, hasLength(1));
        expect(s.appeals.single['k'], b1);
        expect((s.appeals.single['t'] as String).length, kPyrAppealChars);

        // Kept under their own key, never in the main state.
        expect(stored(s, 'pyramid/me').containsKey('in'), isFalse);
        expect(stored(s, 'pyramid/me').containsKey('ap'), isFalse);
        expect(
          stored(s, 'pyramid/reports')['in'] as List,
          hasLength(kPyrReportsPerSender),
        );
        await s.load();
        expect(s.inbox, hasLength(kPyrReportsPerSender));
        expect(s.appeals, hasLength(1));
      },
    );
  });

  test(
    'a stranger cannot erase or replace a treasurer signature (S12)',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      await fund(w, 'A1', 10000);
      final String b1 = w['B1'].myKey!;
      // Most treasurers are away: the order waits with A1's and A2's.
      const List<String> away = <String>['S', 'A', 'B', 'B1'];
      w.net.holdForOffline = false;
      for (final String who in away) {
        w.net.setOnline(w.net[who], false);
      }
      final PyramidRecord? order = await w['A1'].pay(b1, 2500);
      await w.net.run();
      final String a2 = w['A2'].myKey!;
      final String good = w['A1'].pendingPayments.single.tsigs[a2]!;
      final SimPhone z = w.add('Z');
      await w['Z'].load();
      for (final String k in <String>[a2, w['S'].myKey!]) {
        await z.send(w.net['A1'].address, <String, dynamic>{
          'type': PyramidTypes.paySig,
          'id': order!.id,
          'k': k,
          's': b64(List<int>.filled(64, 7)),
        });
      }
      await w.net.run();
      final PyramidRecord after = w['A1'].pendingPayments.single;
      expect(after.tsigs[a2], good);
      expect(after.tsigs.containsKey(w['S'].myKey), isFalse);
      expect(
        order!.withTreasurerSig(a2, 'x').withTreasurerSig(a2, 'y').tsigs[a2],
        'x',
      );
      // The real treasurers come back: the order goes out again, through.
      for (final String who in away) {
        w.net.setOnline(w.net[who], true);
      }
      w.net.holdForOffline = true;
      await w.net.advance(const Duration(minutes: 31));
      await w.duties(rounds: 1);
      await w.sync();
      expect(w['S'].state!.balanceOf(b1), 2500);
    },
  );

  group('money of a pyramid that joins another (§20.5)', () {
    late Six w;

    setUp(() async {
      w = await Six.make();
    });

    Map<String, dynamic> entry(String p, LedgerKeyPair k, int bal) =>
        <String, dynamic>{
          'p': p,
          'k': k.id,
          'n': 'X',
          'nat': 'PL',
          'dc': '',
          'addr': '',
          if (bal > 0) 'bal': bal,
        };

    test(
      'balances come over at the agreed rate, like an emission: 2 of the top, limit, wait, veto',
      () async {
        const int at = t0 + day;
        final LedgerKeyPair t = await LedgerKeyPair.generate();
        final LedgerKeyPair t1 = await LedgerKeyPair.generate();
        final Map<String, dynamic> fields = <String, dynamic>{
          'from': 'mala',
          'under': w.a1.id,
          'snap': <Map<String, dynamic>>[
            entry('', t, 10000),
            entry('0', t1, 5000),
          ],
          'rate': <String, int>{'n': 1, 'd': 2},
          'cut': at,
        };
        // Without this top it would be money printed by somebody else.
        final PyramidRecord alone = await rec(
          PyrT.merge,
          w.py,
          at,
          <LedgerKeyPair>[w.a1, t, t1],
          fields,
        );
        PyramidState st = w.fold(<PyramidRecord>[alone]);
        expect(
          st.rejected[alone.id],
          'przeliczenie pieniędzy: zgoda 2 z 3 szczytu tej piramidy',
        );
        expect(st.isMember(t.id), isFalse);

        final PyramidRecord agreed = await rec(
          PyrT.merge,
          w.py,
          at + 1,
          <LedgerKeyPair>[w.a1, t, t1, w.s, w.a],
          fields,
        );
        st = w.fold(<PyramidRecord>[agreed], now: at + h);
        expect(st.applied, contains(agreed.id));
        expect(st.pathOf(t.id), '000');
        expect(st.balanceOf(t.id), 0, reason: 'it waits like an emission');
        expect(st.emittedWithin(at + h), 7500);
        st = w.fold(<PyramidRecord>[agreed], now: at + 25 * h);
        expect(st.balanceOf(t.id), 5000);
        expect(st.balanceOf(t1.id), 2500);

        // The third of the top vetoes one part: all of it stops.
        final PyramidRecord veto = await rec(
          PyrT.veto,
          w.py,
          at + 2 * h,
          <LedgerKeyPair>[w.b],
          <String, dynamic>{'emit': '${agreed.id}|${t1.id}'},
        );
        st = w.fold(<PyramidRecord>[agreed, veto], now: at + 25 * h);
        expect(st.applied, contains(veto.id));
        expect(st.balanceOf(t.id), 0);
        expect(st.balanceOf(t1.id), 0);
        expect(st.isMember(t.id), isTrue, reason: 'the people stay');
      },
    );

    test(
      'more than the emission limit, or a broken rate, is refused',
      () async {
        const int at = t0 + day;
        final LedgerKeyPair t = await LedgerKeyPair.generate();
        Future<PyramidRecord> merge(int dt, Map<String, dynamic> extra) => rec(
          PyrT.merge,
          w.py,
          at + dt,
          <LedgerKeyPair>[w.a1, t, w.s, w.a],
          <String, dynamic>{
            'from': 'mala',
            'under': w.a1.id,
            'snap': <Map<String, dynamic>>[
              entry('', t, 2 * PyrParams().emitLimit),
            ],
            ...extra,
          },
        );
        // No rate: 1:1.
        final PyramidRecord big = await merge(1, const <String, dynamic>{});
        final PyramidRecord broken = await merge(2, <String, dynamic>{
          'rate': <String, int>{'n': 0, 'd': 1},
        });
        final PyramidRecord fits = await merge(3, <String, dynamic>{
          'rate': <String, int>{'n': 1, 'd': 4},
        });
        final PyramidState st = w.fold(<PyramidRecord>[big, broken, fits]);
        expect(
          st.rejected[big.id],
          'przeliczenie przekracza limit emisji (30 dni)',
        );
        expect(st.rejected[broken.id], 'zły kurs');
        expect(st.applied, contains(fits.id));
        expect(st.balanceOf(t.id), PyrParams().emitLimit ~/ 2);
      },
    );

    test('the pyramid that joined counts no money after the cut', () async {
      const int at = t0 + day;
      final PyramidRecord e = await w.emit(at, w.a1, 10000);
      final PyramidRecord before = await w.pay(
        at + 25 * h,
        w.a1,
        w.a2,
        1000,
        1,
      );
      const int cut = at + 26 * h;
      final PyramidRecord after = await w.pay(at + 27 * h, w.a1, w.a2, 2000, 2);
      final PyramidRecord closing = await rec(
        PyrT.merged,
        w.py,
        at + 28 * h,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{'into': 'inna', 'cut': cut},
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        e,
        before,
        after,
        closing,
      ], tsigs: w.treasurersSigned(<PyramidRecord>[before, after]));
      expect(st.mergedInto, 'inna');
      expect(st.mergeCut, cut);
      expect(st.applied, contains(before.id));
      expect(
        st.rejected[after.id],
        'po przeliczeniu pieniędzy przy połączeniu',
      );
      expect(st.balanceOf(w.a1.id), 9000);
      expect(st.balanceOf(w.a2.id), 1000);
    });
  });

  group('exchange payments (§23.5)', () {
    late Six w;

    setUp(() async {
      w = await Six.make();
    });

    test(
      'a locked payment is taken only with its key; bad conditions are refused',
      () async {
        const int at = t0 + day;
        const String key = 'tajny-klucz';
        final String lock = sha256Hex(utf8.encode(key));
        final PyramidRecord e = await w.emit(at, w.a1, 10000);
        final PyramidRecord pay = await w.pay(
          at + 25 * h,
          w.a1,
          w.b1,
          3000,
          1,
          cond: <String, dynamic>{
            'by': w.b1.id,
            'until': at + 5 * day,
            'hl': lock,
            'fx': <String, dynamic>{'py': 'inna', 'to': w.a2.id, 'a': 1500},
          },
        );
        final PyramidRecord noKey = await w.settle(
          at + 26 * h,
          w.b1,
          pay.id,
          true,
        );
        final PyramidRecord wrong = await rec(
          PyrT.settle,
          w.py,
          at + 27 * h,
          <LedgerKeyPair>[w.b1],
          <String, dynamic>{'x': pay.id, 'ok': true, 'pre': 'zły'},
        );
        final PyramidRecord right = await rec(
          PyrT.settle,
          w.py,
          at + 28 * h,
          <LedgerKeyPair>[w.b1],
          <String, dynamic>{'x': pay.id, 'ok': true, 'pre': key},
        );
        final PyramidRecord chain = await w.pay(
          at + 29 * h,
          w.a1,
          w.b1,
          100,
          2,
          cond: <String, dynamic>{
            'by': w.b1.id,
            'hl': lock,
            'share': 50,
            'hops': 1,
          },
        );
        final PyramidRecord badLock = await w.pay(
          at + 30 * h,
          w.a1,
          w.b1,
          100,
          2,
          cond: <String, dynamic>{'by': w.b1.id, 'hl': 'xyz'},
        );
        final List<PyramidRecord> all = <PyramidRecord>[
          e,
          pay,
          noKey,
          wrong,
          right,
          chain,
          badLock,
        ];
        final PyramidState st = w.fold(
          all,
          tsigs: w.treasurersSigned(all.skip(1)),
        );
        expect(st.escrows[pay.id]!.fxAmount, 1500);
        expect(st.escrows[pay.id]!.fxTo, w.a2.id);
        expect(st.rejected[noKey.id], 'zły klucz wymiany');
        expect(st.rejected[wrong.id], 'zły klucz wymiany');
        expect(st.applied, contains(right.id));
        expect(st.escrows[pay.id]!.pre, key);
        expect(st.balanceOf(w.b1.id), 3000);
        expect(st.rejected[chain.id], 'wymiana nie idzie przez pośredników');
        expect(st.rejected[badLock.id], 'zła blokada wymiany');
      },
    );

    test('an exchange rate is a member\'s own record', () async {
      const int at = t0 + day;
      final LedgerKeyPair x = await LedgerKeyPair.generate();
      Future<PyramidRecord> rate(int dt, LedgerKeyPair by, String k, int n) =>
          rec(
            PyrT.fxRate,
            w.py,
            at + dt,
            <LedgerKeyPair>[by],
            <String, dynamic>{
              'k': k,
              'from': 'inna',
              'n': n,
              'd': 10000,
              'max': 0,
            },
          );
      final PyramidRecord mine = await rate(0, w.b1, w.b1.id, 5000);
      final PyramidRecord stranger = await rate(1, x, x.id, 5000);
      final PyramidRecord forOther = await rate(2, w.a1, w.b1.id, 1);
      PyramidState st = w.fold(<PyramidRecord>[mine, stranger, forOther]);
      expect(st.fxRates[w.b1.id]!['inna']!.payout(10000), 5000);
      expect(st.rejected[stranger.id], 'nie członek');
      expect(st.rejected[forOther.id], 'nie członek');
      final PyramidRecord off = await rate(3, w.b1, w.b1.id, 0);
      st = w.fold(<PyramidRecord>[mine, off]);
      expect(st.fxRates[w.b1.id]?['inna'], isNull);
    });
  });

  test(
    'a small pyramid joins with its money: converted, waits, the old one stops at the cut',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String ruch = w['S'].current!;
      final SimPhone t = w.add('T');
      final SimPhone t1 = w.add('T1');
      final SimPhone t2 = w.add('T2');
      await w.pyr(t).load();
      final String small = await w
          .pyr(t)
          .createPyramid(
            name: 'Mała',
            myName: 'T',
            nat: 'PL',
            birthYear: 1985,
            gender: 'k',
          );
      await w.join(t, t1);
      await w.join(t, t2);
      final String t1Key = w['T1'].myKey!;
      // T1 has money in the small pyramid.
      await w['T'].emit(t1Key, 10000, 'Start');
      await w.net.run();
      await w.approve('T2', PyrT.emit);
      await w.net.advance(const Duration(hours: 25));
      expect(w['T'].state!.balanceOf(t1Key), 10000);

      w.net.befriend(t, w.net['A1']);
      await w.sync();
      expect(await w['T'].fetchFriendsPyramids(), 1);
      await w.net.run();
      final ({int total, int converted, int room, int waiting})? money = w['T']
          .mergeMoney(ruch, numer: 5000, denom: 10000);
      expect(money?.total, 10000);
      expect(money?.converted, 5000);

      final String a1 = w['A1'].myKey!;
      await w['T'].proposeMerge(
        ruch,
        a1,
        w['S'].state!.members[a1]!.addr,
        rate: (numer: 5000, denom: 10000),
      );
      await w.net.run();
      await w.approve('T1', PyrT.merge);
      await w.approve('A1', PyrT.merge);
      expect(
        w['S'].state!.members,
        hasLength(6),
        reason: 'the top of the bigger pyramid has not agreed yet',
      );
      await w.approve('S', PyrT.merge);
      await w.approve('A', PyrT.merge);
      await w.sync();
      expect(w['S'].state!.members, hasLength(9));
      expect(w['S'].state!.balanceOf(t1Key), 0, reason: 'waits 24 h');

      await w.approve('T1', PyrT.merged);
      await w.sync();
      expect(w['T2'].stateOf(small)!.mergedInto, ruch);
      expect(w['T2'].stateOf(small)!.mergeCut, isNotNull);

      await w.net.advance(const Duration(hours: 25));
      expect(w['S'].state!.balanceOf(t1Key), 5000);
      expect(w['B1'].state!.balanceOf(t1Key), 5000);
    },
  );

  test(
    'money goes from one pyramid to another through someone in both',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String p1 = w['S'].current!;
      // A second pyramid: T on top, T1 and T2 under it; B1 joins it too.
      final SimPhone t = w.add('T');
      final SimPhone t1 = w.add('T1');
      final SimPhone t2 = w.add('T2');
      await w.pyr(t).load();
      final String p2 = await w
          .pyr(t)
          .createPyramid(
            name: 'Druga',
            myName: 'T',
            nat: 'PL',
            birthYear: 1985,
            gender: 'k',
          );
      await w.join(t, t1);
      await w.join(t, t2);
      await w.join(t1, w.net['B1']);
      await w.sync();
      final String a1 = w['A1'].myKey!;
      final String b1 = w['B1'].myKey!;
      final String t2Key = w['T2'].myKey!;
      expect(w['T'].state!.isMember(b1), isTrue);
      expect(w['S'].state!.isMember(b1), isTrue);

      await fund(w, 'A1', 100000);
      // B1 exchanges: for 100,00 of the first pyramid, 50,00 in the second.
      await w['B1'].setFxRate(payoutPy: p2, fromPy: p1, numer: 5000);
      await w.net.run();
      // A1 gets to know the second pyramid from a friend who keeps it.
      w.net.befriend(w.net['A1'], t);
      await w.sync();
      expect(await w['A1'].fetchFriendsPyramids(), 1);
      await w.net.run();
      expect(
        w['A1']
            .exchangers(p2)
            .map((({String key, String name, PyrFxRate? rate}) x) => x.key)
            .toList(),
        <String>[b1],
      );

      // B1 has no money there yet: the exchange is returned at once.
      final ({PyramidRecord order, int cost})? first = await w['A1'].payAcross(
        other: p2,
        to: t2Key,
        via: b1,
        amount: 1000,
      );
      expect(first?.cost, 2000);
      await w.net.run();
      expect(w['S'].state!.balanceOf(a1), 98000);
      await w.duties(rounds: 3);
      await w.sync();
      expect(w['S'].state!.balanceOf(a1), 100000);
      expect(w['T'].state!.balanceOf(t2Key), 0);

      // B1 gets money in the second pyramid; now it goes through.
      await w['T'].emit(b1, 100000, 'Start');
      await w.net.run();
      await w.approve('T1', PyrT.emit);
      await w.net.advance(const Duration(hours: 25));
      expect(w['T'].state!.balanceOf(b1), 100000);
      final ({PyramidRecord order, int cost})? second = await w['A1'].payAcross(
        other: p2,
        to: t2Key,
        via: b1,
        amount: 1000,
      );
      expect(second, isNotNull);
      await w.net.run();
      await w.duties(rounds: 4);
      await w.sync();
      // There: T2 got 10,00 from B1. Here: B1 got 20,00 from A1.
      expect(w['T'].state!.balanceOf(t2Key), 1000);
      expect(w['T'].state!.balanceOf(b1), 99000);
      expect(w['S'].state!.balanceOf(a1), 98000);
      expect(w['S'].state!.balanceOf(b1), 2000);
    },
  );
}
