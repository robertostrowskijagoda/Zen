import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/presentation/encounters_section.dart';

const int _minute = 60 * 1000;
const int _day = 24 * 60 * _minute;

void main() {
  test('"Spotkani?" may be confirmed up to 7 days after passing', () {
    final int now = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
    Encounter passed(int ago) => Encounter(
      friend: 'ania',
      start: now - ago - 20 * _minute,
      end: now - ago,
    );

    expect(kEncounterMetWindow, const Duration(days: 7));
    expect(encounterMayConfirm(passed(0), now), isTrue);
    expect(encounterMayConfirm(passed(6 * _day), now), isTrue);
    expect(encounterMayConfirm(passed(7 * _day), now), isTrue);
    expect(encounterMayConfirm(passed(7 * _day + _minute), now), isFalse);
    expect(encounterMayConfirm(passed(20 * _day), now), isFalse);
  });

  testWidgets('"Mijani" offers "Spotkani?" only for the last week', (
    WidgetTester tester,
  ) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final int now = DateTime(2026, 10, 21, 15).millisecondsSinceEpoch;
    final EncounterLog log = EncounterLog(disk: disk, now: () => now);
    addTearDown(log.dispose);
    log
      ..saw(token: 'aa' * 16, at: now - 2 * _day, friend: 'ania')
      ..saw(token: 'bb' * 16, at: now - 9 * _day, friend: 'ola');
    await log.flush();
    final List<String> met = <String>[];

    tester.view.physicalSize = const Size(720, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              EncountersSection(
                log: log,
                now: () => DateTime.fromMillisecondsSinceEpoch(now),
                nameOf: (String f) => f == 'ania' ? 'Ania' : 'Ola',
                hasMet: (String f) => false,
                onOpen: (String _) {},
                onMet: met.add,
                onPlace: (EncounterPlace _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Both are still in "Mijani"; only the recent one can be confirmed.
    expect(find.text('Ania'), findsOneWidget);
    expect(find.text('Ola'), findsOneWidget);
    expect(find.text('Spotkani?'), findsOneWidget);
    await tester.tap(find.text('Spotkani?'));
    expect(met, <String>['ania']);
  });
}
