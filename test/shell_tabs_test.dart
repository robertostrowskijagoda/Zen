import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
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

/// The places of the rail, top to bottom, then the alarm.
const List<String> _railIds = <String>[
  'graph', 'chats', 'profile', //
  'feed', 'films', //
  'meet', 'nearby', 'neighbors', 'dating', //
  'pyramid', 'wallet', //
  'alarm',
];

/// A pushed route has finished coming in (or going away).
Future<void> _route(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Whether a tap at the middle of [finder] lands on it (nothing covers it,
/// it is on screen).
bool _tappable(WidgetTester tester, Finder finder) {
  final RenderObject target = tester.renderObject(finder);
  final HitTestResult result = tester.hitTestOnBinding(
    tester.getCenter(finder),
  );
  return result.path.any((HitTestEntry e) => e.target == target);
}

/// Every place of the rail can be tapped right away, without scrolling.
void _expectAllOneTapAway(WidgetTester tester, {required String where}) {
  final Rect rail = tester.getRect(find.byKey(const Key('side-tabs')));
  for (final String id in _railIds) {
    final Finder tab = find.byKey(Key('side-tab-$id'));
    expect(tab, findsOneWidget, reason: '$where: $id');
    final Rect r = tester.getRect(tab);
    expect(r.height, greaterThanOrEqualTo(30), reason: '$where: $id tall');
    expect(r.bottom, lessThanOrEqualTo(rail.bottom + 0.5), reason: id);
    expect(_tappable(tester, tab), isTrue, reason: '$where: $id tappable');
  }
  final ScrollableState scroll = tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const Key('side-tabs-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  expect(scroll.position.maxScrollExtent, lessThan(1), reason: where);
}

void main() {
  testWidgets('the rail: every main place in four groups and the alarm, '
      'nothing under "more"', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);

    expect(find.byKey(const Key('tabbed-shell')), findsOneWidget);
    for (int i = 1; i < _railIds.length; i++) {
      expect(
        tester.getTopLeft(find.byKey(Key('side-tab-${_railIds[i - 1]}'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(Key('side-tab-${_railIds[i]}'))).dy,
        ),
        reason: '${_railIds[i - 1]} above ${_railIds[i]}',
      );
    }
    // Each group opens with its line: before Graf, Tablica, Spotkania and
    // Piramida.
    for (final (String group, String first) in <(String, String)>[
      ('people', 'graph'),
      ('posts', 'feed'),
      ('meeting', 'meet'),
      ('community', 'pyramid'),
    ]) {
      final Rect line = tester.getRect(
        find.byKey(Key('side-tabs-group-$group')),
      );
      expect(
        line.bottom,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byKey(Key('side-tab-$first'))).dy + 0.5,
        ),
        reason: group,
      );
    }
    for (final String gone in <String>['more', 'invite', 'about', 'settings']) {
      expect(find.byKey(Key('side-tab-$gone')), findsNothing, reason: gone);
    }
    // The alarm sits at the bottom.
    expect(
      tester.getRect(find.byKey(const Key('side-tab-alarm'))).bottom,
      greaterThan(
        tester.getRect(find.byKey(const Key('side-tabs'))).bottom - 70,
      ),
    );
    await _tearDown(tester);
  });

  testWidgets('icons only; the open tab shows its name; every tab a tooltip', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);

    // The app opens on the chats: only their name is written.
    expect(find.byKey(const Key('side-tab-label-chats')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-label-feed')), findsNothing);
    expect(find.text('Tablica'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('side-tab-chats'))).width,
      lessThan(60),
    );
    await tester.tap(find.byKey(const Key('side-tab-feed')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('feed-screen')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-label-feed')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-label-chats')), findsNothing);

    final List<String> tips = <String>[
      for (final String id in _railIds)
        tester
                .widget<Tooltip>(
                  find
                      .ancestor(
                        of: find.byKey(Key('side-tab-$id')),
                        matching: find.byType(Tooltip),
                      )
                      .first,
                )
                .message ??
            '',
    ];
    expect(
      tips,
      containsAll(<String>[
        'Graf znajomych', 'Filmy', 'Osoby w pobliżu', 'Portfel', 'Alarm', //
      ]),
    );
    await _tearDown(tester);
  });

  testWidgets('a tab opens its page; Filmy is its own section', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);

    await tester.tap(find.byKey(const Key('side-tab-films')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('films-screen')), findsOneWidget);

    await tester.tap(find.byKey(const Key('side-tab-profile')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('profile-screen')), findsOneWidget);

    // Back to chats keeps the page that was there.
    await tester.tap(find.byKey(const Key('side-tab-chats')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    await _tearDown(tester);
  });

  testWidgets('settings open from the top bar; "Zaproś" and "O aplikacji" '
      'lead them', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);

    // The connection status bar stays across the top, above the rail.
    expect(
      tester.getBottomLeft(find.byKey(const Key('chats-status-chip'))).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const Key('side-tabs'))).dy,
      ),
    );
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await _route(tester);
    expect(find.byKey(const Key('settings-tab-body')), findsOneWidget);
    // At the very top, above every other row.
    final double invite = tester
        .getTopLeft(find.byKey(const Key('settings-nav-invite')))
        .dy;
    final double about = tester
        .getTopLeft(find.byKey(const Key('settings-nav-about')))
        .dy;
    expect(invite, lessThan(about));
    expect(
      about,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('settings-nav-security'))).dy,
      ),
    );
    // No experimental features any more.
    expect(find.byKey(const Key('settings-nav-experimental')), findsNothing);

    await tester.tap(find.byKey(const Key('settings-nav-invite')));
    await _route(tester);
    expect(find.text('Mój kod'), findsOneWidget);
    // Someone without the app gets it from hand to hand.
    expect(find.byKey(const Key('invite-share-app')), findsOneWidget);
    await tester.pageBack();
    await _route(tester);

    await tester.tap(find.byKey(const Key('settings-nav-about')));
    await _route(tester);
    expect(find.byKey(const Key('about-screen')), findsOneWidget);
    await _tearDown(tester);
  });

  testWidgets('every place is one tap away on a small phone, a big phone '
      'and a computer, without scrolling', (WidgetTester tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    // With a password, so "Zablokuj teraz" takes its place in the top bar.
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      hasPassword: true,
      passwordIterations: 10,
    );
    for (final Size size in const <Size>[
      Size(320, 568), // the smallest phone
      Size(360, 640),
      Size(430, 930), // a big phone
      Size(1280, 800), // a computer window
    ]) {
      tester.view.physicalSize = size;
      await _pumpApp(tester, security: security);
      _expectAllOneTapAway(tester, where: '$size');
      expect(tester.takeException(), isNull, reason: '$size');
      await _tearDown(tester);
    }
  });

  testWidgets('a phone on its side: the rail scrolls, every place still '
      'reachable', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    expect(tester.takeException(), isNull);
    for (final String id in _railIds) {
      final Finder tab = find.byKey(Key('side-tab-$id'));
      await tester.ensureVisible(tab);
      await tester.pump();
      expect(_tappable(tester, tab), isTrue, reason: id);
    }
    await _tearDown(tester);
  });

  testWidgets('the top bar: settings, accounts, lock and the rail button', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      hasPassword: true,
      passwordIterations: 10,
    );
    await _pumpApp(tester, security: security);
    expect(find.byKey(const Key('account-menu-button')), findsOneWidget);
    expect(find.byKey(const Key('side-tabs-hide')), findsOneWidget);
    // "Zablokuj teraz" locks at once.
    tester
        .widget<IconButton>(find.byKey(const Key('side-tabs-lock')))
        .onPressed!
        .call();
    expect(security.isLocked, isTrue);
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
      'Graf znajomych', 'Filmy', 'Osoby w pobliżu', 'Randki', 'Portfel', //
      'Alarm',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    expect(find.bySemanticsLabel('Więcej'), findsNothing);
    handle.dispose();
    await _tearDown(tester);
  });

  testWidgets('links and other screens open a tab of the rail', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    // A notification of the pyramid's posts, zen://feed?f=…
    openFeed(FeedFilter.close);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('feed-screen')), findsOneWidget);
    expect(find.byKey(const Key('side-tab-label-feed')), findsOneWidget);
    // Any tab by its id; an unknown one changes nothing.
    openShellTab('films');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('side-tab-label-films')), findsOneWidget);
    openShellTab('nonsense');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('side-tab-label-films')), findsOneWidget);
    await _tearDown(tester);
  });

  testWidgets('the chats can show close friends only', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    expect(find.byKey(const Key('chats-filter-close')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chats-filter-close')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await _tearDown(tester);
  });

  testWidgets('the rail hides completely and comes back from the top bar', (
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
    // The page gets the full width (on a wide window it then keeps a
    // centred reading width itself).
    expect(tester.getTopLeft(find.byKey(const Key('tab-page-chats'))).dx, 0);
    // The button to bring it back is at the top, within the thumb's reach.
    expect(
      tester.getTopLeft(find.byKey(const Key('side-tabs-show'))).dy,
      lessThan(70),
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
