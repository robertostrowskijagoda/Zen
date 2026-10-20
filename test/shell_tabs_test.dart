import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _pumpApp(
  WidgetTester tester, {
  LedgerDisk? disk,
  AppSecurityService? security,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerNodeEnabledProvider.overrideWithValue(true),
        ledgerDiskProvider.overrideWithValue(disk ?? MemoryLedgerDisk()),
        if (security != null)
          appSecurityServiceProvider.overrideWithValue(security),
      ],
      child: MaterialApp(theme: ZenTheme.dark(), home: const AppShellScreen()),
    ),
  );
  await tester.runAsync(() => _settle());
  await tester.pump();
}

Future<void> _tearDown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => _settle());
}

void main() {
  testWidgets('vertical tabs: profile, chats, wall, invite; settings up top', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);

    expect(find.byKey(const Key('tabbed-shell')), findsOneWidget);
    // The connection status bar stays across the top, above the rail.
    expect(find.byKey(const Key('chats-status-chip')), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byKey(const Key('chats-status-chip'))).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const Key('side-tabs-hide'))).dy,
      ),
    );
    expect(find.byKey(const Key('chats-page')), findsOneWidget);
    // Collapsed by default: icons only, the rail stays narrow.
    expect(find.text('Tablica'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('side-tab-chats'))).width,
      lessThan(60),
    );

    await tester.tap(find.byKey(const Key('side-tab-feed')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('feed-screen')), findsOneWidget);

    await tester.tap(find.byKey(const Key('side-tab-profile')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('profile-screen')), findsOneWidget);

    // No assistant any more.
    expect(find.byKey(const Key('side-tab-assistant')), findsNothing);

    // Profile first in the rail; no settings tab there (the status bar
    // opens settings).
    expect(
      tester.getTopLeft(find.byKey(const Key('side-tab-profile'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('side-tab-chats'))).dy),
    );
    expect(find.byKey(const Key('side-tab-settings')), findsNothing);
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('settings-tab-body')), findsOneWidget);
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // The invitation (QR and code) is a rarely used tab: under "Więcej".
    expect(find.byKey(const Key('side-tab-invite')), findsNothing);
    await tester.tap(find.byKey(const Key('side-tab-more')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('more-tab-invite')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Zaproś'), findsOneWidget);
    // Someone without the app gets it from hand to hand.
    expect(find.byKey(const Key('invite-share-app')), findsOneWidget);

    // The status is set on your profile (the top bar stays as it was).
    expect(find.byKey(const Key('my-status-chip')), findsNothing);
    await tester.tap(find.byKey(const Key('side-tab-profile')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('profile-status-button')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('status-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('status-preset-1')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('💼 W pracy'), findsOneWidget);

    // Back to chats keeps the page that was there.
    await tester.tap(find.byKey(const Key('side-tab-chats')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);

    await _tearDown(tester);
  });

  testWidgets('every rail button fits on a small phone', (
    WidgetTester tester,
  ) async {
    // 360 × 640 with the status and navigation bars taken off: a small
    // Android phone, conservatively.
    tester.view.physicalSize = const Size(360, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // With a password, so "Zablokuj teraz" takes its place too.
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      hasPassword: true,
      passwordIterations: 10,
    );
    await _pumpApp(tester, security: security);
    expect(find.byKey(const Key('side-tabs-lock')), findsOneWidget);

    const List<String> ids = <String>[
      'graph', 'profile', 'chats', 'feed', 'meet', 'neighbors', 'more', //
      'alarm',
    ];
    double bottom = 0;
    for (final String id in ids) {
      final Finder tab = find.byKey(Key('side-tab-$id'));
      expect(tab, findsOneWidget, reason: id);
      final Rect r = tester.getRect(tab);
      expect(r.height, greaterThanOrEqualTo(32), reason: '$id: tappable');
      bottom = r.bottom > bottom ? r.bottom : bottom;
    }
    expect(bottom, lessThanOrEqualTo(568), reason: 'nothing below the edge');

    // The rail's lock button locks at once.
    tester
        .widget<IconButton>(find.byKey(const Key('side-tabs-lock')))
        .onPressed!
        .call();
    expect(security.isLocked, isTrue);

    await _tearDown(tester);
  });

  testWidgets('rarely used tabs sit in groups under "Więcej"', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Pyramid and wallet are on by default (§2.5.1).
    await _pumpApp(tester);

    for (final String id in <String>[
      'dating', 'pyramid', 'wallet', 'nearby', 'invite', 'about', //
    ]) {
      expect(find.byKey(Key('side-tab-$id')), findsNothing, reason: id);
    }
    await tester.tap(find.byKey(const Key('side-tab-more')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('more-sheet')), findsOneWidget);
    for (final String id in <String>[
      'dating', 'pyramid', 'wallet', 'nearby', 'invite', 'about', //
    ]) {
      expect(find.byKey(Key('more-tab-$id')), findsOneWidget, reason: id);
    }
    // Grouped as in the plan (§25).
    expect(find.text('WSPÓLNOTA'), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-tab-about')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('more-sheet')), findsNothing);
    expect(find.byKey(const Key('tab-page-about')), findsOneWidget);
    await _tearDown(tester);
  });

  testWidgets('every rail icon has a label for screen readers', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    final SemanticsHandle handle = tester.ensureSemantics();
    for (final String label in <String>[
      'Graf znajomych', 'Więcej', 'Alarm', //
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    handle.dispose();
    await _tearDown(tester);
  });

  testWidgets('the rail hides completely and comes back', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);

    expect(find.byKey(const Key('side-tab-feed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('side-tabs-hide')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('side-tab-feed')), findsNothing);
    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    // The handle lies over the content: the page gets the full width (on
    // a wide window the page then keeps a centred reading width itself).
    expect(tester.getTopLeft(find.byKey(const Key('tab-page-chats'))).dx, 0);
    // The show button sits at the top, within the thumb's reach.
    expect(
      tester.getTopLeft(find.byKey(const Key('side-tabs-show'))).dy,
      lessThan(70), // right under the status bar
    );
    await tester.tap(find.byKey(const Key('side-tabs-show')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('side-tab-feed')), findsOneWidget);
    await _tearDown(tester);
  });

  testWidgets('the rail remembers being hidden', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await _pumpApp(tester, disk: disk);
    expect(
      tester.getTopLeft(find.byKey(const Key('side-tabs-hide'))).dy,
      lessThan(70), // right under the status bar
    );
    await tester.tap(find.byKey(const Key('side-tabs-hide')));
    await tester.runAsync(() => _settle());
    await _tearDown(tester);

    await _pumpApp(tester, disk: disk);
    await tester.pump();
    expect(find.byKey(const Key('side-tab-feed')), findsNothing);
    expect(find.byKey(const Key('side-tabs-show')), findsOneWidget);
    await _tearDown(tester);
  });
}
