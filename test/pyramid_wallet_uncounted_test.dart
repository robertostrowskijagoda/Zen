import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// What the documents call visible is shown: a payment most treasurers
/// signed that the seal of its era left out stays in its payee's history,
/// said to count nowhere and why; the treasurers' wallet counts such
/// operations; and treasurers who signed two seals of one era are named
/// to every member.
void main() {
  testWidgets('a payment a seal left out shows in the payee\'s history; who '
      'signed two seals of one era is named', (WidgetTester tester) async {
    late PyramidWorld w;
    late PyramidRecord pay;
    await tester.runAsync(() async {
      w = await PyramidWorld.six();
      // The first eras sealed, as the treasurers' apps do.
      await w.net.advance(const Duration(hours: 2));
      await w.duties(rounds: 1);
      await w.net.advance(const Duration(minutes: 15));
      await w.duties(rounds: 8);
      await w.sync();
      await w.fund('A1', 10000);
      pay = (await w['A1'].pay(w['B1'].myKey!, 800, memo: 'Rower'))!;
      await w.net.run();
      expect(w['B1'].myEntries.map((PyrLedgerEntry e) => e.id), <String>[
        pay.id,
      ]);
      // A newcomer at the treasurers' levels ends the payment's era.
      final SimPhone x = w.add('X');
      await w.join(w.net['A2'], x);
      await w.sync();
      final PyramidState s = w['B1'].state!;
      final PyrEraToSeal era = s.unsealedEra!;
      expect(pay.at, inInclusiveRange(era.from, era.to - 1));
      // Most of the next treasurers seal it without the payment — twice,
      // differently: both leave it out, and those four signed two seals.
      Future<PyramidRecord> seal(List<String> ops) async {
        PyramidRecord r = PyramidRecord(
          body: PyrSeal.body(
            pyramid: s.id,
            n: era.n,
            prev: era.prev,
            from: era.from,
            to: era.to,
            set: era.set,
            next: era.next,
            ops: ops,
            changes: era.changes,
          ),
        );
        for (final String n in <String>['S', 'A', 'B', 'A1']) {
          r = await w[n].signAsMe(r);
        }
        return r;
      }

      await w['S'].ingest(await seal(const <String>[]));
      await w['S'].ingest(await seal(<String>['0' * 64]));
      await w.net.run();
      await w.sync();
    });
    final PyramidService b1 = w['B1'];
    final PyramidState s = b1.state!;
    expect(s.seals.last.ops, isNot(contains(pay.id)));
    expect(b1.myEntries, isEmpty);
    expect(b1.myUncounted.single.entry.id, pay.id);
    expect(b1.myUncounted.single.leftOutOfSeal, isTrue);
    expect(s.sealCheaters.keys, hasLength(4));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: Scaffold(
            body: PyramidWallet(pyr: b1, s: s, me: b1.myKey!),
          ),
        ),
      ),
    );
    final Finder line = find.byKey(Key('pyr-uncounted-${pay.id}'));
    await tester.scrollUntilVisible(
      line,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(line, findsOneWidget);
    expect(
      find.descendant(
        of: line,
        matching: find.byWidgetPredicate(
          (Widget x) =>
              x is SelectableText &&
              (x.data ?? '').contains('pominęli ją w pieczęci'),
        ),
      ),
      findsOneWidget,
    );
    // B1 is a treasurer: the count of everybody's.
    for (final String k in <String>['pyr-seal-cheaters', 'pyr-uncounted']) {
      await tester.scrollUntilVisible(
        find.byKey(Key(k)),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(Key(k)), findsOneWidget);
    }
    expect(find.textContaining('Pieczęć ery pominęła 1 operację'), findsOne);
  });
}
