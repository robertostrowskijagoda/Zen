import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// A walk through every place of the app: each tab of the rail and each
/// page of the settings, on a small phone, a big phone and a computer, in
/// the dark and the light look. A page that throws, or whose layout runs
/// out of room, fails the walk (the test framework reports both).

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A pushed route has finished coming in (or going away).
Future<void> _route(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// The places of the rail, top to bottom, then the alarm.
const List<String> _railIds = <String>[
  'graph', 'chats', 'profile', //
  'feed', 'films', //
  'meet', 'nearby', 'neighbors', 'dating', //
  'pyramid', 'wallet', //
  'alarm',
];

/// The settings' pages, as listed; the links out (GitHub, Discord) leave
/// the app and are not walked.
const List<String> _settingsIds = <String>[
  'passwords', //
  'invite', 'about', 'account', 'accounts', 'devices', 'security', //
  'appearance', 'notifications', 'muted-post-authors', 'contact', //
  'delivery', 'network', 'public-peers', 'nearby-look', 'permissions', //
  'data', 'recordings', 'gifs', 'updates', 'health', 'diagnostics', //
  'ios-background', 'reset',
];

const Map<String, Size> _screens = <String, Size>{
  'small phone': Size(320, 568),
  'big phone': Size(430, 932),
  'computer': Size(1280, 800),
};

Future<void> _pumpApp(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerNodeEnabledProvider.overrideWithValue(true),
        ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
      ],
      child: MaterialApp(theme: theme, home: const AppShellScreen()),
    ),
  );
  await tester.runAsync(() => _settle());
  await tester.pump();
}

Future<void> _tearDown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => _settle());
}

/// Back from a pushed page: the app bar's back button, else the system's.
Future<void> _back(WidgetTester tester) async {
  final NavigatorState navigator = tester.state<NavigatorState>(
    find.byType(Navigator).first,
  );
  await navigator.maybePop();
  await _route(tester);
}

void main() {
  for (final MapEntry<String, Size> screen in _screens.entries) {
    for (final (String look, ThemeData theme) in <(String, ThemeData)>[
      ('dark', ZenTheme.dark()),
      ('light', ZenTheme.light()),
    ]) {
      final String where = '${screen.key}, $look';

      testWidgets('every tab of the rail opens on a $where', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = screen.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pumpApp(tester, theme);
        for (final String id in _railIds) {
          final Finder tab = find.byKey(Key('side-tab-$id'));
          if (tab.evaluate().isEmpty) {
            continue;
          }
          await tester.ensureVisible(tab);
          await tester.tap(tab);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull, reason: '$where: $id');
        }
        await _tearDown(tester);
      });

      testWidgets('every page of the settings opens and closes on a $where', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = screen.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pumpApp(tester, theme);
        await tester.tap(find.byKey(const Key('chats-status-chip')));
        await _route(tester);
        final Finder list = find.descendant(
          of: find.byKey(const Key('settings-tab-body')),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        );
        final List<String> walked = <String>[];
        final List<String> skipped = <String>[];
        for (final String id in _settingsIds) {
          final Finder entry = find.byKey(Key('settings-nav-$id'));
          // From the top each time: the list above is in its own order.
          tester.state<ScrollableState>(list.first).position.jumpTo(0);
          await tester.pump();
          if (entry.evaluate().isEmpty) {
            try {
              await tester.scrollUntilVisible(
                entry,
                200,
                scrollable: list.first,
                maxScrolls: 60,
              );
            } on Object {
              skipped.add(id); // Not on this platform or screen.
              continue;
            }
          }
          if (entry.evaluate().isEmpty) {
            continue;
          }
          await tester.ensureVisible(entry);
          await tester.pump();
          await tester.tap(entry, warnIfMissed: false);
          await _route(tester);
          expect(tester.takeException(), isNull, reason: '$where: $id');
          walked.add(id);
          if (find
              .byKey(const Key('settings-tab-body'))
              .hitTestable()
              .evaluate()
              .isEmpty) {
            await _back(tester);
          }
        }
        // Most of the pages are there on every screen.
        expect(walked, contains('passwords'));
        expect(
          walked.length,
          greaterThanOrEqualTo(15),
          reason: 'walked $walked, skipped $skipped',
        );
        await _tearDown(tester);
      });
    }
  }
}
