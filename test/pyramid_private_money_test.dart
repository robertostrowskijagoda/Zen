import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// Private payments on the simulated network: sealed to the treasurers
/// and the one paid, never a record; the treasurers' ledger kept in sync
/// and handed to a new treasurer; the daily limit; statements and a
/// dispute about one.
void main() {
  /// The six of [PyramidWorld.six], X under A1 (level 3: still a
  /// treasurer), and Y and Z under X (level 4: not treasurers).
  Future<PyramidWorld> world() async {
    final PyramidWorld w = await PyramidWorld.six();
    for (final (String head, String name) in <(String, String)>[
      ('A1', 'X'),
      ('X', 'Y'),
      ('X', 'Z'),
    ]) {
      final SimPhone p = w.add(name);
      await w.join(w.net[head], p);
    }
    await w.sync();
    return w;
  }

  test('nobody but the payer, the one paid and the treasurers learns of a '
      'payment', () async {
    final PyramidWorld w = await world();
    final String y = w['Y'].myKey!;
    final String b1 = w['B1'].myKey!;
    expect(w['X'].isTreasurer, isTrue);
    expect(w['Y'].isTreasurer, isFalse);
    expect(w['Z'].isTreasurer, isFalse);

    // New money for Y: the record shows the amount; who gets it only the
    // top who sign (from the proposal), the treasurers and Y know.
    await w.sealKeys();
    await w['S'].emit(y, 10000, 'Na start');
    await w.net.run();
    final PyrProposal p = w['B'].proposals.values.single;
    expect(
      w['B'].recordDetails(p.record, extra: p.extra).join('\n'),
      contains('Dla: Y'),
    );
    expect(
      w['B'].recordDetails(p.record).join('\n'),
      contains('tylko skarbnicy'),
    );
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
    final PyrEmission e = w['Z'].state!.emissions.values.single;
    expect(w['Z'].recordOf(e.id)!.body.containsKey('to'), isFalse);
    expect(w['Z'].ledgerNotes, isEmpty);
    expect(w['B1'].ledgerNotes, contains(e.rc));
    expect(w['Y'].balance, 10000);
    expect(w['Z'].balance, 0);

    // Y pays B1: only sealed frames, none to Z, the title never in the
    // clear.
    w.net
      ..tracing = true
      ..trace.clear();
    final PyramidRecord order = (await w['Y'].pay(
      b1,
      2500,
      memo: 'Tajny tytuł',
    ))!;
    await w.net.run();
    w.net.tracing = false;
    expect(w.net.trace, isNotEmpty);
    expect(
      w.net.trace.every((String l) => l.endsWith(PyramidTypes.priv)),
      isTrue,
    );
    expect(w.net.trace.where((String l) => l.contains('→Z ')), isEmpty);
    expect(jsonEncode(w.net['Y'].outbox), isNot(contains('Tajny tytuł')));
    // Never a record anywhere; Z's ledger knows nothing.
    for (final SimPhone phone in w.net.phones) {
      expect(w.pyr(phone).keeps(order.id), isFalse, reason: phone.name);
    }
    expect(w['Z'].ledgerIds, isEmpty);
    // The receipt: B1 has the order with most treasurers' signatures.
    expect(w['Y'].pendingPayments, isEmpty);
    expect(w['B1'].myEntries.last.id, order.id);
    expect(w['B1'].myEntries.last.memo, 'Tajny tytuł');
    expect(w.net['B1'].notificationTitles, contains('Wpłata'));
    expect(w['S'].ledgerBalanceOf(y), 7500);
    expect(w['X'].ledgerBalanceOf(b1), 2500);

    // Y's statement: most treasurers sign the same balance and number.
    await w['Y'].refreshStatement();
    await w.net.run();
    final PyrStatement st = w['Y'].agreedStatement!;
    expect(st.balance, 7500);
    expect(st.seq, 1);
    expect(w['Y'].statements.length, w['Y'].state!.treasurers.length);
    expect(w['Y'].balance, 7500);
    expect(w['Y'].disagreeingTreasurers, isEmpty);
  });

  test('treasurers keep one ledger: one who missed a payment gets it in the '
      'sync, a new treasurer gets it all', () async {
    final PyramidWorld w = await world();
    final String y = w['Y'].myKey!;
    final String z = w['Z'].myKey!;
    await w.fund('Y', 10000);
    w.net.holdForOffline = false;
    w.net.setOnline(w.net['B1'], false);
    final PyramidRecord? order = await w['Y'].pay(z, 1000);
    await w.net.run();
    expect(w['S'].ledgerIds, contains(order!.id));
    expect(w['Z'].balance, 1000);
    w.net.setOnline(w.net['B1'], true);
    w.net.holdForOffline = true;
    expect(w['B1'].ledgerIds, isNot(contains(order.id)));

    await w.net.advance(const Duration(minutes: 31));
    await w.duties(rounds: 1);
    expect(w['B1'].ledgerIds, containsAll(w['S'].ledgerIds));
    expect(w['B1'].ledgerBalanceOf(y), 9000);

    // A new treasurer: Q under A2 (level 3) gets the whole ledger.
    final SimPhone q = w.add('Q');
    await w.join(w.net['A2'], q);
    await w.sync();
    await w.sealKeys();
    // Publishing its key already offered its (empty) ledger for sync.
    expect(w['Q'].isTreasurer, isTrue);
    await w.net.advance(const Duration(minutes: 31));
    await w.duties(rounds: 1);
    expect(w['Q'].ledgerIds, containsAll(w['S'].ledgerIds));
    expect(w['Q'].ledgerNotes, containsAll(w['S'].ledgerNotes));
    expect(w['Q'].ledgerBalanceOf(y), 9000);
    expect(w['Q'].ledgerBalanceOf(z), 1000);
    // And signs with the others from now on.
    expect(await w['Y'].pay(z, 500), isNotNull);
    await w.net.run();
    expect(w['Q'].ledgerBalanceOf(z), 1500);
  });

  test('the daily limit: the top lowers it at once, the treasurers sign no '
      'more orders that day', () async {
    final PyramidWorld w = await world();
    final String z = w['Z'].myKey!;
    await w.fund('Y', 10000);
    expect(await w['S'].proposeEmitRule(xfers: 5), isNotNull);
    expect(w['S'].emitRuleLowers(xfers: 5), isTrue);
    expect(w['S'].emitRuleLowers(xfers: 50), isFalse);
    await w.net.run();
    await w.approve('A', PyrT.emitRule);
    await w.sync();
    expect(w['Y'].state!.params.xferLimit, 5);
    for (int i = 0; i < 5; i++) {
      expect(await w['Y'].pay(z, 10), isNotNull, reason: 'order $i');
      await w.net.run();
      expect(w['Y'].pendingPayments, isEmpty, reason: 'order $i');
    }
    final PyramidRecord? sixth = await w['Y'].pay(z, 10);
    await w.net.run();
    expect(w['Y'].pendingPayments.single.id, sixth!.id);
    expect(w['S'].ledgerBalanceOf(z), 50);
    // The next day a new order (the same number) goes through.
    w['Y'].cancelPending(sixth.id);
    await w.net.advance(const Duration(hours: 25));
    final PyramidRecord? tomorrow = await w['Y'].pay(z, 10);
    expect(tomorrow!.integer('seq'), 6);
    await w.net.run();
    expect(w['Y'].pendingPayments, isEmpty);
    expect(w['S'].ledgerBalanceOf(z), 60);
  });

  testWidgets('the wallet shows the confirmed statement and a treasurer who '
      'states another balance, with a dispute for the court', (
    WidgetTester tester,
  ) async {
    late PyramidWorld w;
    late String b1;
    await tester.runAsync(() async {
      w = await world();
      b1 = w['B1'].myKey!;
      await w.fund('Y', 10000);
      // B1 is away while Y pays: its copy keeps the old balance.
      w.net.holdForOffline = false;
      w.net.setOnline(w.net['B1'], false);
      await w['Y'].pay(w['Z'].myKey!, 2500, memo: 'Rower');
      await w.net.run();
      w.net.setOnline(w.net['B1'], true);
      w.net.holdForOffline = true;
      await w['Y'].refreshStatement();
      await w.net.run();
    });
    final PyramidService y = w['Y'];
    expect(y.agreedStatement!.balance, 7500);
    expect(y.disagreeingTreasurers, <String>[b1]);
    expect(y.statements[b1]!.balance, 10000);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: Scaffold(
            body: PyramidWallet(pyr: y, s: y.state!, me: y.myKey!),
          ),
        ),
      ),
    );
    expect(find.text(formatMoney(7500)), findsWidgets);
    expect(find.textContaining('Wyciąg potwierdziło'), findsOneWidget);
    expect(find.text('Skarbnicy podają różne salda'), findsOneWidget);
    final Finder dispute = find.byKey(Key('pyr-dispute-$b1'));
    await tester.ensureVisible(dispute);
    await tester.pump();
    await tester.tap(dispute);
    await tester.pumpAndSettle();
    expect(find.text('Skarga przeciw B1'), findsOneWidget);
    expect(find.text(pyrVerdictLabel('ledger')), findsOneWidget);
    expect(find.textContaining('przelewy prywatne'), findsOneWidget);
  });
}
