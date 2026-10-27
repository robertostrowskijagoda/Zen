import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
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
  bool? nearbyShown,
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
        if (nearbyShown != null)
          nearbyTabShownProvider.overrideWithValue(nearbyShown),
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
    // The wallet opens from your own profile too.
    expect(find.byKey(const Key('profile-open-wallet')), findsOneWidget);

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
    // The project's GitHub page and its Discord server, in the top group.
    final double github = tester
        .getTopLeft(find.byKey(const Key('settings-nav-github')))
        .dy;
    final double discord = tester
        .getTopLeft(find.byKey(const Key('settings-nav-discord')))
        .dy;
    expect(about, lessThan(github));
    expect(github, lessThan(discord));
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

  testWidgets('where "W pobliżu" cannot work (iPhone), it is not on the rail', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester, nearbyShown: false);
    expect(find.byKey(const Key('side-tab-nearby')), findsNothing);
    for (final String id in _railIds) {
      if (id != 'nearby') {
        expect(find.byKey(Key('side-tab-$id')), findsOneWidget, reason: id);
      }
    }
    // Asked for anyway (a link): nothing changes.
    openShellTab('nearby');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('side-tab-label-chats')), findsOneWidget);
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

  testWidgets('the lock is in one place, the top bar: not in the account '
      'menu, not in the settings', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      hasPassword: true,
      passwordIterations: 10,
    );
    await _pumpApp(tester, security: security);
    expect(find.byKey(const Key('side-tabs-lock')), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-menu-button')));
    await _route(tester);
    expect(find.byKey(const Key('account-menu')), findsOneWidget);
    expect(find.byKey(const Key('account-menu-lock')), findsNothing);
    expect(find.text('Zablokuj'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await _route(tester);

    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await _route(tester);
    expect(find.byKey(const Key('settings-tab-body')), findsOneWidget);
    // With a password the settings do not repeat the lock button or the
    // "set a password" card.
    expect(find.byKey(const Key('settings-lock-now-button')), findsNothing);
    expect(find.text('Zablokuj teraz'), findsNothing);
    await tester.pageBack();
    await _route(tester);

    tester
        .widget<IconButton>(find.byKey(const Key('side-tabs-lock')))
        .onPressed!
        .call();
    expect(security.isLocked, isTrue);
    await _tearDown(tester);
  });

  testWidgets('without a password the top bar has no lock and the settings '
      'offer to set one', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester, security: MemoryAppSecurityService());
    expect(find.byKey(const Key('side-tabs-lock')), findsNothing);
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await _route(tester);
    expect(find.byKey(const Key('settings-lock-now-button')), findsOneWidget);
    expect(find.text('Ustaw hasło'), findsWidgets);
    await _tearDown(tester);
  });

  testWidgets('an additional account locks from the top bar by going back to '
      'the default account', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ZenAccountHost host = ZenAccountHost();
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      hasPassword: true,
      passwordIterations: 10,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          appSecurityServiceProvider.overrideWithValue(security),
          zenAccountHostProvider.overrideWithValue(host),
          zenAccountProvider.overrideWithValue(
            ZenAccountScope.derive('TEST-ACCOUNT', Uint8List(32)),
          ),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const AppShellScreen(),
        ),
      ),
    );
    await tester.runAsync(() => _settle());
    await tester.pump();

    await tester.tap(find.byKey(const Key('side-tabs-lock')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    // Asked for: the default account's (locked) opening, and this account's
    // key is gone from memory.
    expect(host.switching, isTrue);
    final ZenAccountOpening opening = host.take()!;
    expect(opening.scope.isDefault, isTrue);
    expect(security.isLocked, isTrue);
    await _tearDown(tester);
  });

  testWidgets('"Mój kod" is one tap from the top bar, also on the smallest '
      'phone', (WidgetTester tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    for (final Size size in const <Size>[Size(320, 568), Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await _pumpApp(
        tester,
        security: MemoryAppSecurityService(
          hasPassword: true,
          passwordIterations: 10,
        ),
      );
      final Finder myCode = find.byKey(const Key('status-my-code'));
      expect(myCode, findsOneWidget, reason: '$size');
      expect(_tappable(tester, myCode), isTrue, reason: '$size');
      expect(tester.takeException(), isNull, reason: '$size');

      await tester.tap(myCode);
      await _route(tester);
      // The invite screen: the QR / invite code, adding someone by theirs.
      expect(find.text('Mój kod'), findsWidgets, reason: '$size');
      expect(find.byKey(const Key('invite-add-friend')), findsOneWidget);
      await tester.pageBack();
      await _route(tester);
      await _tearDown(tester);
    }
  });

  group('"Nigdy" in the security settings', () {
    Future<void> openSecurity(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('chats-status-chip')));
      await _route(tester);
      final Finder security = find.byKey(const Key('settings-nav-security'));
      await tester.ensureVisible(security);
      await tester.pump();
      await tester.tap(security);
      await _route(tester);
    }

    Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.runAsync(() => _settle());
      await _route(tester);
    }

    final Finder note = find.byKey(const Key('settings-lock-never-note'));
    final Finder never = find.byKey(const Key('settings-lock-mode-never'));
    final Finder dialog = find.byKey(const Key('settings-never-lock-dialog'));
    final Finder field = find.byKey(
      const Key('settings-never-lock-password-field'),
    );
    final Finder confirm = find.byKey(const Key('settings-never-lock-confirm'));

    testWidgets('the password once, after the warning; the note says Zen '
        'opens without it; another mode takes the key away again', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        passwordIterations: 10,
      );
      await tester.runAsync(() async {
        await security.setPassword('sekret12');
        await security.setPanicPassword('panika123');
      });
      await _pumpApp(tester, security: security);
      await openSecurity(tester);
      expect(note, findsNothing);

      // Cancelled: nothing changes.
      await tapAndSettle(tester, never);
      expect(dialog, findsOneWidget);
      expect(
        find.byKey(const Key('settings-never-lock-panic-note')),
        findsOneWidget,
      );
      await tester.tap(find.text('Anuluj'));
      await _route(tester);
      expect(dialog, findsNothing);
      expect(security.lockMode, isNot(AppLockMode.never));
      expect(security.keepsNeverLockKey, isFalse);
      expect(note, findsNothing);

      // A wrong password keeps nothing.
      await tapAndSettle(tester, never);
      await tester.enterText(field, 'zle-haslo');
      await tapAndSettle(tester, confirm);
      expect(dialog, findsOneWidget);
      expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
      expect(security.keepsNeverLockKey, isFalse);

      await tester.enterText(field, 'sekret12');
      await tapAndSettle(tester, confirm);
      expect(dialog, findsNothing);
      expect(security.lockMode, AppLockMode.never);
      expect(security.keepsNeverLockKey, isTrue);
      expect(
        await tester.runAsync(
          () => security.credentialsStore.read(
            appSecurityNeverLockMasterKeyStorageKey,
          ),
        ),
        isNotNull,
      );
      expect(note, findsOneWidget);
      expect(
        tester.widget<Text>(note).data,
        allOf(
          contains('otwiera się bez hasła, także po restarcie'),
          contains('zobaczy Twoje rozmowy'),
          contains('blokada ekranu telefonu'),
          contains('Zablokuj teraz'),
        ),
      );

      // Changing the security settings still asks for the password.
      await tapAndSettle(
        tester,
        find.byKey(const Key('settings-change-password-button')),
      );
      expect(
        find.byKey(const Key('settings-current-password-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('Anuluj'));
      await _route(tester);

      await tapAndSettle(
        tester,
        find.byKey(const Key('settings-lock-mode-appClose')),
      );
      expect(note, findsNothing);
      expect(security.lockMode, AppLockMode.appClose);
      expect(security.keepsNeverLockKey, isFalse);
      expect(
        await tester.runAsync(
          () => security.credentialsStore.read(
            appSecurityNeverLockMasterKeyStorageKey,
          ),
        ),
        isNull,
      );
      await _tearDown(tester);
    });

    testWidgets('with nothing kept the note names the catch: the password '
        'still opens the data after a restart', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpApp(
        tester,
        security: MemoryAppSecurityService(
          hasPassword: true,
          passwordIterations: 10,
        ),
      );
      // "Nigdy" chosen, but no key kept (locked by hand since, say).
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );
      await tester.runAsync(
        () => container
            .read(appSettingsControllerProvider.notifier)
            .setLockMode(AppLockMode.never),
      );
      await openSecurity(tester);
      await tester.ensureVisible(never);
      await tester.pump();
      expect(note, findsOneWidget);
      expect(
        tester.widget<Text>(note).data,
        allOf(contains('nie blokuje się sam'), contains('hasło i tak')),
      );
      await _tearDown(tester);
    });
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
