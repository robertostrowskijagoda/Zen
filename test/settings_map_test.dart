import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/settings/settings_search_index.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

// The map of the settings (docs/guide/settings-and-peers.md): every setting
// lives on exactly one page, and every setting of Zen 1.14.0 is still there.

/// The rows of the settings list, top to bottom.
const List<String> _rows = <String>[
  'settings-rerun-setup',
  'settings-nav-invite',
  'settings-nav-about',
  'settings-nav-github',
  'settings-nav-discord',
  'settings-lock-now-button',
  // Konto i odzyskiwanie
  'settings-nav-account',
  'settings-nav-accounts',
  'settings-nav-devices',
  // Prywatność i bezpieczeństwo
  'settings-nav-security',
  'settings-nav-contact',
  'settings-blocked-button',
  // Wiadomości i połączenia
  'settings-nav-notifications',
  'settings-nav-recordings',
  'settings-nav-gifs',
  // Sieć
  'settings-relay-button',
  'settings-nav-network',
  'settings-nav-public-peers',
  // Aplikacja
  'settings-nav-appearance',
  'settings-language-tile',
  'settings-nav-data',
  'settings-nav-permissions',
  'settings-nav-updates',
  // Zaawansowane
  'settings-nav-health',
  'settings-nav-diagnostics',
  'settings-nav-reset',
];

/// What each page holds, by the rows tapped to reach it ('' is the list).
final Map<String, List<String>> _pages = <String, List<String>>{
  '': _rows,
  'settings-nav-security': <String>[
    'settings-security-section',
    'settings-change-password-button',
    'settings-panic-password-button',
    'settings-biometric-unlock-switch',
    'settings-lock-mode-dropdown',
    'settings-secure-screens-switch',
    'settings-allow-no-password-switch',
  ],
  'settings-nav-contact': <String>[
    'settings-show-last-opened',
    'stranger-messages-from',
    'group-invite-from',
  ],
  'settings-blocked-button': <String>['blocked-friends-screen'],
  'settings-nav-notifications': <String>[
    'settings-notification-privacy',
    'notification-privacy-choice',
    'settings-in-app-sounds',
    'settings-notification-sounds',
    for (final NoticeKind kind in NoticeKind.values)
      kind == NoticeKind.friendPost
          ? 'settings-post-notifications'
          : 'settings-notice-${kind.name}',
    'settings-nav-muted-post-authors',
  ],
  'settings-nav-notifications/settings-nav-muted-post-authors': <String>[
    'muted-post-authors-empty',
  ],
  'settings-nav-gifs': <String>[
    'settings-gif-search',
    'settings-gif-keyboard-note',
    'settings-gif-key-field',
  ],
  'settings-nav-network': <String>[
    'settings-network-card',
    'settings-tech-info-tile',
    'settings-lan-discovery-switch',
    'settings-serve-pebbles-switch',
  ],
  'settings-nav-public-peers': <String>['public-peers'],
  'settings-nav-appearance': <String>[
    'settings-palette-picker',
    'settings-theme-mode-segmented',
    'settings-animations-choice',
    'settings-accent-picker',
  ],
  'settings-nav-data': <String>[
    'storage-usage',
    'settings-preferences-panel',
    'settings-inbox-unlimited-switch',
    'settings-auto-cleanup-field',
    'settings-auto-media',
    'settings-media-wifi-only',
    'storage-limits',
  ],
  'settings-nav-reset': <String>['desktop-reset-data-button'],
};

/// The rows and the settings only one system shows, and the page they are
/// on there.
const Map<String, String> _androidOnly = <String, String>{
  'settings-nav-delivery': 'settings-nav-notifications',
  'settings-nav-nearby-look': '',
  'settings-disguise-icon-switch': 'settings-nav-security',
};
const Map<String, String> _iosOnly = <String, String>{
  'settings-nav-ios-background': 'settings-nav-notifications',
};

/// Every row and setting of the settings in Zen 1.14.0.
const List<String> _before = <String>[
  'settings-rerun-setup',
  'settings-nav-invite',
  'settings-nav-about',
  'settings-nav-github',
  'settings-nav-discord',
  'settings-lock-now-button',
  'settings-nav-security',
  'settings-security-section',
  'settings-change-password-button',
  'settings-panic-password-button',
  'settings-biometric-unlock-switch',
  'settings-lock-mode-dropdown',
  'settings-secure-screens-switch',
  'settings-allow-no-password-switch',
  'settings-disguise-icon-switch',
  'settings-notification-privacy',
  'notification-privacy-choice',
  'settings-nav-account',
  'settings-nav-accounts',
  'settings-nav-devices',
  'settings-blocked-button',
  'blocked-friends-screen',
  'settings-nav-group-invites',
  'group-invite-from',
  'settings-show-last-opened',
  'settings-nav-stranger-messages',
  'stranger-messages-from',
  'settings-relay-button',
  'settings-nav-recordings',
  'settings-nav-gifs',
  'settings-gif-search',
  'settings-gif-keyboard-note',
  'settings-gif-key-field',
  'settings-auto-media',
  'settings-media-wifi-only',
  'settings-nav-notifications',
  'settings-in-app-sounds',
  'settings-notification-sounds',
  'settings-post-notifications',
  'settings-notice-message',
  'settings-notice-groupMessage',
  'settings-notice-call',
  'settings-notice-mention',
  'settings-notice-reaction',
  'settings-notice-farPost',
  'settings-notice-invitation',
  'settings-notice-update',
  'settings-nav-muted-post-authors',
  'muted-post-authors-empty',
  'settings-nav-delivery',
  'settings-nav-ios-background',
  'settings-nav-permissions',
  'settings-nav-nearby-look',
  'settings-nav-health',
  'settings-nav-appearance',
  'settings-palette-picker',
  'settings-theme-mode-segmented',
  'settings-animations-choice',
  'settings-accent-picker',
  'settings-language-tile',
  'settings-nav-data',
  'storage-usage',
  'settings-preferences-panel',
  'settings-inbox-unlimited-switch',
  'settings-auto-cleanup-field',
  'storage-limits',
  'settings-nav-updates',
  'settings-nav-network',
  'settings-network-card',
  'settings-tech-info-tile',
  'settings-lan-discovery-switch',
  'settings-nav-public-peers',
  'public-peers',
  'settings-nav-diagnostics',
  'settings-nav-reset',
  'desktop-reset-data-button',
];

/// The rows of 1.14.0 that were only a door to one setting: the setting
/// is now on the merged page.
const Map<String, String> _mergedRows = <String, String>{
  'settings-nav-group-invites': 'group-invite-from',
  'settings-nav-stranger-messages': 'stranger-messages-from',
};

/// Keys of the map that are no setting of their own, so the settings
/// search does not list them: a whole page, a part of another setting, a
/// note, a screen.
const Map<String, String> _notSearched = <String, String>{
  'settings-security-section': 'the whole Bezpieczeństwo page',
  'notification-privacy-choice': 'part of settings-notification-privacy',
  'muted-post-authors-empty': 'what an empty page says',
  'blocked-friends-screen': 'a screen of its own (its row is found)',
  'settings-gif-keyboard-note': 'a note',
  'settings-network-card': 'holds settings-tech-info-tile',
  'public-peers': 'the whole Publiczne węzły page (its row is found)',
  'storage-usage': 'holds storage-feed-limit-switch',
  'settings-preferences-panel': 'holds its switches and the cleanup field',
};

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ledgerNodeEnabledProvider.overrideWithValue(true),
        ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
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

Future<void> _route(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// The list of the page on top: the settings list or a settings page.
ScrollableState? _pageScrollable(WidgetTester tester) {
  for (final String body in <String>[
    'settings-page-body',
    'settings-tab-body',
  ]) {
    final Finder list = find.descendant(
      of: find.byKey(Key(body)),
      matching: find.byType(Scrollable),
    );
    if (list.evaluate().isNotEmpty) {
      return tester.state<ScrollableState>(list.first);
    }
  }
  return null;
}

/// Which of [keys] the page on top shows, scrolling it from top to bottom.
Future<Set<String>> _collect(WidgetTester tester, Iterable<String> keys) async {
  final Set<String> seen = <String>{};
  void look() {
    for (final String key in keys) {
      if (find.byKey(Key(key)).evaluate().isNotEmpty) {
        seen.add(key);
      }
    }
  }

  final ScrollableState? list = _pageScrollable(tester);
  if (list == null) {
    look();
    return seen;
  }
  list.position.jumpTo(0);
  await tester.pump();
  while (true) {
    look();
    final ScrollPosition position = list.position;
    if (position.pixels >= position.maxScrollExtent) {
      break;
    }
    position.jumpTo(
      (position.pixels + position.viewportDimension * 0.6).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
    await tester.pump();
  }
  list.position.jumpTo(0);
  await tester.pump();
  return seen;
}

Future<void> _tapRow(WidgetTester tester, String key) async {
  final Finder row = find.byKey(Key(key));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.byWidget(_pageScrollable(tester)!.widget),
  );
  await tester.pump();
  await tester.tap(row);
  await _route(tester);
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('chats-status-chip')));
  await _route(tester);
}

void main() {
  test('every setting of 1.14.0 is on a page of the new map', () {
    final Set<String> now = <String>{
      for (final List<String> keys in _pages.values) ...keys,
      ..._androidOnly.keys,
      ..._iosOnly.keys,
    };
    for (final String key in _before) {
      final String kept = _mergedRows[key] ?? key;
      expect(now, contains(kept), reason: '$key was lost');
    }
    // A merged row is gone from the list, its setting is not.
    for (final String row in _mergedRows.keys) {
      expect(_rows, isNot(contains(row)));
    }
    // The pages of the platform-only rows are on the map.
    for (final String page in <String>[
      ..._androidOnly.values,
      ..._iosOnly.values,
    ]) {
      expect(_pages.keys, contains(page));
    }
  });

  test('the settings search knows every setting of the map and finds each '
      'by its name', () {
    final List<SettingsSearchEntry> index = settingsSearchIndex(
      const SettingsSearchDevice.everything(),
    );
    final Map<String, SettingsSearchEntry> byKey =
        <String, SettingsSearchEntry>{
          for (final SettingsSearchEntry e in index) e.key: e,
        };
    expect(byKey, hasLength(index.length), reason: 'a key twice');
    final Set<String> settings = <String>{
      for (final MapEntry<String, List<String>> page in _pages.entries)
        if (page.key.isNotEmpty) ...page.value,
      for (final MapEntry<String, String> e in <MapEntry<String, String>>[
        ..._androidOnly.entries,
        ..._iosOnly.entries,
      ])
        if (e.value.isNotEmpty) e.key,
    };
    for (final String key in settings) {
      if (_notSearched.containsKey(key)) {
        continue;
      }
      expect(byKey, contains(key), reason: '$key is not in the search');
    }
    for (final SettingsSearchEntry e in index) {
      // On the page of a row of the list.
      expect(
        <String>[..._rows, ..._androidOnly.keys],
        contains(e.row),
        reason: e.key,
      );
      for (final String typed in <String>[
        e.title,
        foldForSearch(e.title),
        e.title.toUpperCase(),
      ]) {
        expect(
          searchSettings(SearchQuery.parse(typed), index),
          contains(e),
          reason: '"$typed" does not find ${e.key}',
        );
      }
    }
  });

  test('the settings search finds the words people use', () {
    final List<SettingsSearchEntry> index = settingsSearchIndex(
      const SettingsSearchDevice.everything(),
    );
    Iterable<String> keys(String typed) => searchSettings(
      SearchQuery.parse(typed),
      index,
    ).map((SettingsSearchEntry e) => e.key);
    expect(keys('motyw'), contains('settings-palette-picker'));
    expect(keys('theme'), contains('settings-palette-picker'));
    expect(keys('ciemny'), contains('settings-theme-mode-segmented'));
    expect(keys('zrzuty'), contains('settings-secure-screens-switch'));
    expect(keys('screenshot'), contains('settings-secure-screens-switch'));
    expect(keys('haslo'), contains('settings-change-password-button'));
    expect(keys('blokada'), contains('settings-lock-mode-dropdown'));
    expect(keys('dzwiek'), contains('settings-notification-sounds'));
    expect(keys('pamiec'), contains('storage-limits'));
    expect(keys('kopie'), contains('storage-limits'));
    expect(keys('wifi direct'), contains('settings-wifi-direct-switch'));
    expect(keys('bluetooth'), contains('settings-bluetooth-links-switch'));
    expect(keys('kamyczki'), contains('settings-serve-pebbles-switch'));
    expect(keys('powiadomienia'), contains('settings-notice-message'));
  });

  testWidgets('every name the search shows is on its page, where the map '
      'says', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    await _openSettings(tester);
    final List<SettingsSearchEntry> index = settingsSearchIndex(
      SettingsSearchDevice(
        android: Platform.isAndroid,
        ios: Platform.isIOS,
        platform: defaultTargetPlatform,
      ),
    );
    final Map<String, List<SettingsSearchEntry>> byRow =
        <String, List<SettingsSearchEntry>>{};
    for (final SettingsSearchEntry e in index) {
      (byRow[e.row] ??= <SettingsSearchEntry>[]).add(e);
    }
    const Set<String> radios = <String>{
      'settings-wifi-direct-switch',
      'settings-bluetooth-links-switch',
      'settings-multipeer-links-switch',
    };
    for (final MapEntry<String, List<SettingsSearchEntry>> row
        in byRow.entries) {
      await _tapRow(tester, row.key);
      for (final SettingsSearchEntry e in row.value) {
        final Set<String> seen = await _collect(tester, <String>[e.key]);
        if (seen.isEmpty && radios.contains(e.key)) {
          // Only where the device has the radio.
          continue;
        }
        expect(seen, contains(e.key), reason: '${e.key} on ${row.key}');
        // Section titles are shown in capitals: compared folded.
        final String title = foldForSearch(e.title);
        expect(
          find
              .byWidgetPredicate(
                (Widget w) =>
                    w is RichText &&
                    foldForSearch(w.text.toPlainText()).contains(title),
              )
              .evaluate(),
          isNotEmpty,
          reason: '"${e.title}" (${e.key}) is not on ${row.key}',
        );
      }
      await tester.pageBack();
      await _route(tester);
    }
    expect(tester.takeException(), isNull);
    await _tearDown(tester);
  });

  for (final (String typed, String key) in const <(String, String)>[
    ('motyw', 'settings-palette-picker'),
    ('zrzuty', 'settings-secure-screens-switch'),
    ('dzwiek powiadomien', 'settings-notification-sounds'),
  ]) {
    testWidgets('"$typed" finds the setting on its page and opens it there '
        '(320 px, text ×2)', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpApp(tester);
      await _openSettings(tester);
      await tester.enterText(
        find.byKey(const Key('settings-search-field')),
        typed,
      );
      await tester.pump();
      final Finder result = find.byKey(Key('settings-search-result-$key'));
      await tester.scrollUntilVisible(
        result,
        200,
        scrollable: find.byWidget(_pageScrollable(tester)!.widget),
      );
      await tester.pump();
      expect(
        find.descendant(of: result, matching: find.textContaining(' › ')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings-search-empty')), findsNothing);
      await tester.tap(result);
      await _route(tester);
      // The page is open, scrolled to the setting, which is marked.
      final Finder setting = find.byKey(Key(key));
      expect(setting, findsOneWidget);
      final Rect shown = tester.getRect(setting);
      expect(shown.top, lessThan(700));
      expect(shown.bottom, greaterThan(0));
      expect(find.byKey(const Key('settings-page-highlight')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pageBack();
      await _route(tester);
      await _tearDown(tester);
    });
  }

  testWidgets('every setting is on exactly one page, where the map says', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    await _openSettings(tester);

    final Set<String> all = <String>{
      for (final List<String> keys in _pages.values) ...keys,
      ..._androidOnly.keys,
      ..._iosOnly.keys,
      ..._mergedRows.keys,
    };
    final Map<String, List<String>> foundOn = <String, List<String>>{};
    for (final MapEntry<String, List<String>> page in _pages.entries) {
      final List<String> path = page.key.isEmpty
          ? const <String>[]
          : page.key.split('/');
      for (final String row in path) {
        await _tapRow(tester, row);
      }
      final Set<String> seen = await _collect(tester, all);
      for (final String key in seen) {
        (foundOn[key] ??= <String>[]).add(page.key);
      }
      for (final String key in page.value) {
        expect(seen, contains(key), reason: '$key on "${page.key}"');
      }
      for (int i = 0; i < path.length; i++) {
        await tester.pageBack();
        await _route(tester);
      }
    }
    for (final MapEntry<String, List<String>> entry in foundOn.entries) {
      expect(
        entry.value,
        hasLength(1),
        reason: '${entry.key} is on ${entry.value}',
      );
    }
    // The rows of one system only: there, on their page; nowhere else.
    for (final MapEntry<String, String> entry in <MapEntry<String, String>>[
      ..._androidOnly.entries,
      ..._iosOnly.entries,
    ]) {
      final bool shown =
          (_androidOnly.containsKey(entry.key) && Platform.isAndroid) ||
          (_iosOnly.containsKey(entry.key) && Platform.isIOS);
      expect(
        foundOn[entry.key],
        shown ? <String>[entry.value] : isNull,
        reason: entry.key,
      );
    }
    for (final String row in _mergedRows.keys) {
      expect(foundOn[row], isNull, reason: row);
    }
    expect(tester.takeException(), isNull);
    await _tearDown(tester);
  });

  testWidgets('everything about notifications is on one page: what they '
      'say, the sounds, the kinds and the muted people', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    AppSettings settings() => container.read(appSettingsControllerProvider);
    await _openSettings(tester);
    // The level of the previews is no longer a row of its own.
    expect(
      find.byKey(const Key('settings-notification-privacy')),
      findsNothing,
    );

    await _tapRow(tester, 'settings-nav-notifications');
    // The level of the previews comes first, above the sounds.
    expect(
      tester
          .getTopLeft(find.byKey(const Key('settings-notification-privacy')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('settings-notification-sounds')))
            .dy,
      ),
    );
    final Finder senderOnly = find.byKey(
      const Key('notification-privacy-senderOnly'),
    );
    await tester.ensureVisible(senderOnly);
    await tester.pump();
    await tester.tap(senderOnly);
    await tester.pump();
    expect(settings().notificationPrivacy, NotificationPrivacy.senderOnly);

    await _tapRow(tester, 'settings-nav-muted-post-authors');
    expect(find.byKey(const Key('muted-post-authors-empty')), findsOneWidget);
    await tester.pageBack();
    await _route(tester);
    await tester.pageBack();
    await _route(tester);
    // The row says the chosen level.
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-nav-notifications')),
        matching: find.textContaining(NotificationPrivacy.senderOnly.label),
      ),
      findsOneWidget,
    );
    await _tearDown(tester);
  });

  testWidgets('who sees you and who may write to you are switched on one '
      'page; media downloads are with the data', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpApp(tester);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    AppSettings settings() => container.read(appSettingsControllerProvider);
    await _openSettings(tester);

    await _tapRow(tester, 'settings-nav-contact');
    expect(settings().showLastOpened, isTrue);
    await tester.tap(find.byKey(const Key('settings-show-last-opened')));
    await tester.pump();
    expect(settings().showLastOpened, isFalse);
    await tester.tap(find.byKey(const Key('group-invite-from-closeFriends')));
    await tester.pump();
    expect(settings().groupInviteFrom, GroupInviteFrom.closeFriends);
    expect(find.byKey(const Key('stranger-messages-from')), findsOneWidget);
    await tester.pageBack();
    await _route(tester);

    await _tapRow(tester, 'settings-nav-data');
    final Finder wifi = find.byKey(const Key('settings-media-wifi-only'));
    await tester.ensureVisible(wifi);
    await tester.pump();
    final bool before = settings().mediaOnlyOnWifi;
    await tester.tap(wifi);
    await tester.pump();
    expect(settings().mediaOnlyOnWifi, !before);
    final Finder auto = find.byKey(const Key('settings-auto-media'));
    await tester.tap(auto);
    await tester.pump();
    expect(settings().autoDownloadMedia, isFalse);
    await tester.pageBack();
    await _route(tester);
    await _tearDown(tester);
  });
}
