import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

/// An order's time decides the money and the number it is counted with:
/// the treasurers sign only what they count at that time, a payer's wallet
/// never dates an order before the money it spends (and dates one again
/// when the treasurers say so), and a payee's wallet shows money only once
/// the treasurers' agreed statement lists it.
void main() {
  const List<String> treasurers = <String>[
    'S',
    'A',
    'B',
    'A1',
    'A2',
    'B1',
    'X',
  ];

  /// A phone like [PyramidWorld.add], whose clock is [slowMs] behind.
  SimPhone addSlow(PyramidWorld w, String name, int slowMs) {
    final SimPhone p = w.net.phone(name);
    final MemoryLedgerDisk d = MemoryLedgerDisk();
    final PyramidService s = PyramidService(
      host: p,
      disk: d,
      root: w.root,
      identitySeed: w.seedOf(d),
      now: () => w.net.now - slowMs,
      tallyWait: const Duration(minutes: 30),
    );
    p.services['pyr'] = s;
    p.attach(s.handle);
    return p;
  }

  /// The six, X under A1 (a treasurer), Y (its clock 9 minutes slow) and
  /// Z under X (not treasurers); A1 has 10000.
  Future<PyramidWorld> world() async {
    final PyramidWorld w = await PyramidWorld.six();
    await w.join(w.net['A1'], w.add('X'));
    // Y's admission carries Y's (slow) time: after X is in.
    await w.net.advance(const Duration(minutes: 20));
    await w.join(w.net['X'], addSlow(w, 'Y', 9 * 60 * 1000));
    await w.join(w.net['X'], w.add('Z'));
    await w.sync();
    await w.fund('A1', 10000);
    expect(w['Y'].isTreasurer, isFalse);
    expect(w['Z'].isTreasurer, isFalse);
    return w;
  }

  test('a payer whose clock is 9 minutes slow pays on money just received: '
      'the order is dated after that money, every treasurer counts it, the '
      'payee is paid and the payer\'s next number goes through', () async {
    final PyramidWorld w = await world();
    final String y = w['Y'].myKey!;
    final String z = w['Z'].myKey!;
    final PyramidRecord? toY = await w['A1'].pay(y, 1000);
    await w.net.run();
    expect(w['Y'].balance, 1000);
    final PyramidRecord? toZ = await w['Y'].pay(z, 1000);
    await w.net.run();
    expect(toZ!.at, greaterThan(toY!.at));
    expect(w['Y'].pendingPayments, isEmpty);
    for (final String t in treasurers) {
      expect(w[t].ledgerBalanceOf(z), 1000, reason: t);
      expect(w[t].ledgerBalanceOf(y), 0, reason: t);
    }
    expect(w['Z'].balance, 1000);
    expect(w['Z'].receivedPayment(toZ.id, from: y, amount: 1000), isTrue);
    expect(w.net['Z'].notificationTitles, contains('Wpłata'));
    // Y's next order takes the next number and counts.
    await w.fund('Y', 100);
    await w.net.advance(const Duration(days: 2));
    await w.duties(rounds: 2);
    final PyramidRecord? next = await w['Y'].pay(w['X'].myKey!, 10);
    await w.net.run();
    expect(next!.integer('seq'), 2);
    expect(w['Y'].pendingPayments, isEmpty);
    expect(w['S'].ledgerBalanceOf(w['X'].myKey!), 10);
  });

  test('an order dated before the money it spends is refused by every '
      'treasurer with the reason, and the wallet sends it again dated after '
      'that money: it counts and the number is not stuck', () async {
    final PyramidWorld w = await world();
    final String y = w['Y'].myKey!;
    final String z = w['Z'].myKey!;
    // Y's wallet does not know when its money came: it dates by its slow
    // clock alone.
    w['Y'].orderTimeFromClock = true;
    final PyramidRecord? toY = await w['A1'].pay(y, 1000);
    await w.net.run();
    final PyramidRecord? first = await w['Y'].pay(z, 1000);
    expect(first!.at, lessThan(toY!.at));
    await w.net.run();
    expect(w['Y'].pendingPayments, isEmpty);
    for (final String t in treasurers) {
      expect(w[t].ledgerIds, isNot(contains(first.id)), reason: t);
      expect(w[t].ledgerBalanceOf(z), 1000, reason: t);
    }
    final PyrLedgerEntry paid = w['Z'].myEntries.singleWhere(
      (PyrLedgerEntry e) => e.to == z,
    );
    expect(paid.id, isNot(first.id));
    expect(paid.at, greaterThan(toY.at));
    expect(w['Z'].balance, 1000);
    expect(w['Z'].receivedPayment(paid.id, from: y, amount: 1000), isTrue);
  });

  test('an order a changed app dates before its money is signed by no '
      'treasurer and is never money on the payee\'s phone', () async {
    final PyramidWorld w = await world();
    final String y = w['Y'].myKey!;
    final String z = w['Z'].myKey!;
    final PyramidRecord? toY = await w['A1'].pay(y, 1000);
    await w.net.run();
    final PyramidRecord back = await w['Y'].signAsMe(
      PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.transfer,
          'py': w['Y'].state!.id,
          'at': toY!.at - 9 * 60 * 1000,
          'by': <String>[y],
          'from': y,
          'to': z,
          'amount': 1000,
          'seq': 1,
          'memo': '',
          'nc': 'changed-app',
        },
      ),
    );
    for (final String t in treasurers) {
      await w['Y'].sendSealed(w[t].myKey!, <String, dynamic>{
        'k': 'ord',
        'r': back.toJson(),
      });
    }
    await w.net.run();
    for (final String t in treasurers) {
      expect(w[t].ledgerIds, isNot(contains(back.id)), reason: t);
      expect(w[t].ledgerBalanceOf(y), 1000, reason: t);
    }
    expect(w['Z'].balance, 0);
    expect(w['Z'].receivedPayment(back.id), isFalse);
    expect(w.net['Z'].notificationTitles, isNot(contains('Wpłata')));
  });

  test('a payment that came in waits for the treasurers: no money, not '
      'paid, no notice — until their agreed statement lists it', () async {
    final PyramidWorld w = await world();
    final String z = w['Z'].myKey!;
    // Z hears only from the payer, a treasurer: one statement is not most.
    w.net.partition(
      <SimPhone>[w.net['Z']],
      <SimPhone>[
        for (final String t in treasurers)
          if (t != 'A1') w.net[t],
      ],
    );
    final PyramidRecord? toZ = await w['A1'].pay(z, 1000);
    await w.net.run();
    expect(w['Z'].myEntries.map((PyrLedgerEntry e) => e.id), contains(toZ!.id));
    expect(w['Z'].awaitingConfirmation(toZ.id), isTrue);
    expect(w['Z'].balance, 0);
    expect(w['Z'].receivedPayment(toZ.id), isFalse);
    expect(w.net['Z'].notificationTitles, isNot(contains('Wpłata')));
    // The others are reached again: the wallet asks again while it waits.
    w.net.heal();
    await w.net.advance(const Duration(minutes: 11));
    await w['Z'].ledgerDuties();
    await w.net.run();
    expect(w['Z'].awaitingConfirmation(toZ.id), isFalse);
    expect(w['Z'].balance, 1000);
    expect(w['Z'].receivedPayment(toZ.id, amount: 1000), isTrue);
    expect(w.net['Z'].notificationTitles, contains('Wpłata'));
  });

  test('a treasurer forgets the spans it signed once their operations '
      'count, also when another device of the account hands them back; one '
      'not counted is kept', () async {
    final PyramidWorld w = await world();
    final String y = w['Y'].myKey!;
    final PyramidRecord? toY = await w['A1'].pay(y, 1000);
    await w.net.run();
    final String span = PyrLedger.spanOf(toY!);
    expect(w['S'].signedSpans[span], toY.id);
    await w.net.advance(const Duration(minutes: 31));
    await w['S'].ledgerDuties();
    expect(w['S'].signedSpans, isNot(contains(span)));
    // Handed back by another device: not taken again.
    final Map<String, dynamic> shared = w['S'].sharedState()!;
    shared['so'] = <String, String>{span: toY.id};
    shared['sow'] = <String, int>{span: toY.at};
    await w['S'].mergeFromOwnDevice(shared);
    expect(w['S'].signedSpans, isNot(contains(span)));
    // An order only S signs (the others are cut off) is kept.
    w.net.partition(
      <SimPhone>[w.net['A1']],
      <SimPhone>[
        for (final String t in treasurers)
          if (t != 'S' && t != 'A1') w.net[t],
      ],
    );
    final PyramidRecord? waits = await w['A1'].pay(y, 10);
    await w.net.run();
    expect(w['A1'].pendingPayments, isNotEmpty);
    await w.net.advance(const Duration(minutes: 31));
    await w['S'].ledgerDuties();
    expect(w['S'].signedSpans[PyrLedger.spanOf(waits!)], waits.id);
  });
}
