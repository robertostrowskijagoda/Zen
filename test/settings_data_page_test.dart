import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/storage_breakdown.dart';

Finder _settingsList() => find
    .descendant(
      of: find.byKey(const Key('settings-tab-body')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsStoreProvider.overrideWithValue(
          MemoryAppSettingsStore(const AppSettings()),
        ),
        storageBreakdownProvider.overrideWith(
          (Ref ref) async => const StorageBreakdown(
            feedBytes: 5 * 1024 * 1024,
            otherBytes: 20 * 1024 * 1024,
          ),
        ),
      ],
      child: const ZenRewriteApp(),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('chats-status-chip')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the setup can be run again from the very top of the settings', (
    WidgetTester tester,
  ) async {
    await _openSettings(tester);
    final Finder rerun = find.byKey(const Key('settings-rerun-setup'));
    expect(rerun, findsOneWidget);
    expect(
      tester.getTopLeft(rerun).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('settings-nav-invite'))).dy,
      ),
    );
    expect(find.text('Ponownie przeprowadź konfigurację'), findsOneWidget);
  });

  testWidgets('storage limits and data live on one page without repeats', (
    WidgetTester tester,
  ) async {
    await _openSettings(tester);
    // The limits page is gone from the list; the data page holds it all.
    expect(find.byKey(const Key('settings-nav-storage-limits')), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-nav-data')),
      220,
      scrollable: _settingsList(),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-nav-data')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('storage-usage')), findsOneWidget);
    expect(find.text('Zen zajmuje 25 MB z 1 GB'), findsOneWidget);
    expect(find.byKey(const Key('storage-usage-bar')), findsOneWidget);
    final Finder page = find
        .descendant(
          of: find.byKey(const Key('settings-page-body')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('storage-limits')),
      220,
      scrollable: page,
    );
    expect(find.byKey(const Key('settings-preferences-panel')), findsOneWidget);
    expect(find.byKey(const Key('storage-limits')), findsOneWidget);
    // One control for the total limit, one list of the fixed limits.
    expect(
      find.byKey(const Key('settings-inbox-unlimited-switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-inbox-limit-slider')),
      findsOneWidget,
    );
    expect(find.text('Zdarzenia w skrzynce'), findsNothing);
  });
}
