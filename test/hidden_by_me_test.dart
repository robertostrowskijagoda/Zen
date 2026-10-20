import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  test('hidden content is found by id, by text hash and by dating key', () {
    final HiddenByMe mine = HiddenByMe(
      keys: <String>{
        HiddenByMe.idKey('p1'),
        HiddenByMe.textKey('Kup tanio'),
        HiddenByMe.datingKeyOf('dk1'),
      },
    );
    expect(mine.hides(id: 'p1'), isTrue);
    expect(mine.hides(id: 'p2'), isFalse);
    expect(mine.hides(text: 'Kup tanio'), isTrue);
    expect(mine.hides(text: 'Cześć'), isFalse);
    // With an id the text does not matter: equal texts are not hidden.
    expect(mine.hides(id: 'p9', text: 'Kup tanio'), isFalse);
    expect(mine.hides(datingKey: 'dk1'), isTrue);
    expect(
      mine.copyWith(shown: <String>{HiddenByMe.idKey('p1')}).hides(id: 'p1'),
      isFalse,
      reason: 'shown anyway',
    );
    expect(
      isContentHidden(const <String>{}, 'x', id: 'p1', mine: mine),
      isTrue,
    );
    expect(
      isContentHidden(const <String>{}, 'x', id: 'p2', mine: mine),
      isFalse,
    );
  });

  test(
    'a report hides, it is kept on disk and read back; shown is not kept',
    () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ProviderContainer c = ProviderContainer(
        overrides: [ledgerDiskProvider.overrideWithValue(disk)],
      );
      addTearDown(c.dispose);
      c.read(hiddenByMeProvider);
      await _settle();
      final HiddenByMeNotifier n = c.read(hiddenByMeProvider.notifier);
      await n.hide(HiddenByMe.keysFor(id: 'm1', datingKey: 'dk1'));
      expect(c.read(hiddenByMeProvider).hides(id: 'm1'), isTrue);
      n.showContent(id: 'm1');
      expect(c.read(hiddenByMeProvider).hides(id: 'm1'), isFalse);
      expect(c.read(hiddenByMeProvider).hides(datingKey: 'dk1'), isTrue);
      final List<dynamic> saved =
          jsonDecode(utf8.decode(disk.files[HiddenByMeNotifier.diskKey]!))
              as List<dynamic>;
      expect(saved, <String>['id:m1', 'dk:dk1']);

      // A new start: hidden again, even what was shown anyway.
      final ProviderContainer c2 = ProviderContainer(
        overrides: [ledgerDiskProvider.overrideWithValue(disk)],
      );
      addTearDown(c2.dispose);
      c2.read(hiddenByMeProvider);
      await _settle();
      expect(c2.read(hiddenByMeProvider).hides(id: 'm1'), isTrue);
    },
  );

  testWidgets('the placeholder says why and shows the content on a tap', (
    WidgetTester tester,
  ) async {
    int shown = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HiddenContentPlaceholder(byMe: true, onShow: () => shown++),
        ),
      ),
    );
    expect(find.text(kHiddenByMeLabel), findsOneWidget);
    await tester.tap(find.text('Pokaż mimo to'));
    expect(shown, 1);
  });
}
