import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/animations_choice.dart';
import 'package:zen/src/features/settings/presentation/lock_mode_choice.dart';
import 'package:zen/src/features/settings/presentation/notification_privacy_choice.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// What the review of the screens asked for, kept: the wording of the choices
// and that their chips are a comfortable target and not told apart by colour
// alone. (The top bar, the notification list, the setup, presence, the
// backup card, mentions and the feed have their own tests.)

Widget _app(Widget child, {List overrides = const []}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: ZenTheme.dark(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// Every chip of [choice] is at least 44 px tall (a hit box, not the look),
/// and the chips of a wrapped row do not overlap. A chip that shrink-wraps
/// is 32 px; the padded target is 48 less the compact density the app theme
/// uses on phones (40), and the settings chips add the rest around it.
void _expectComfortableChips(WidgetTester tester, String choice) {
  final Finder chips = find.descendant(
    of: find.byKey(Key(choice)),
    matching: find.byType(ChoiceChip),
  );
  expect(chips, findsWidgets, reason: choice);
  final List<Rect> boxes = <Rect>[
    for (int i = 0; i < chips.evaluate().length; i++)
      tester.getRect(chips.at(i)),
  ];
  for (final Rect r in boxes) {
    expect(r.height, greaterThanOrEqualTo(44), reason: choice);
  }
  for (int i = 0; i < boxes.length; i++) {
    for (int j = i + 1; j < boxes.length; j++) {
      expect(
        boxes[i].deflate(0.5).overlaps(boxes[j].deflate(0.5)),
        isFalse,
        reason: '$choice: chips $i and $j',
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Real file reads and writes run on, one wait and one frame at a time.
Future<void> _real(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

/// A pushed route has finished coming in (or going away).
Future<void> _route(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
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

void main() {
  group('plain words for the choices', () {
    test('the lock that never asks says there is no password', () {
      expect(AppLockMode.never.label, 'Nigdy (bez hasła)');
    });

    test('the notification levels name what they leave out', () {
      expect(NotificationPrivacy.senderAndContent.label, 'Nadawca i treść');
      expect(NotificationPrivacy.senderOnly.label, 'Tylko nadawca');
      expect(NotificationPrivacy.generic.label, 'Bez nadawcy i treści');
    });

    test('the animations note does not name an Android setting', () {
      final String system = AppAnimations.system.description;
      expect(system, isNot(contains('Usuń animacje')));
      expect(system, contains('system'));
    });
  });

  group('chips of the settings choices', () {
    testWidgets('animations: padded target and not touching', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(AnimationsChoice(value: AppAnimations.always, onChanged: (_) {})),
      );
      _expectComfortableChips(tester, 'settings-animations-choice');
    });

    testWidgets('notification level: padded target, "Jak w ustawieniach" for '
        'a chat', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          NotificationPrivacyChoice(
            value: null,
            global: NotificationPrivacy.senderOnly,
            onChanged: (_) {},
          ),
        ),
      );
      _expectComfortableChips(tester, 'notification-privacy-choice');
      expect(find.text('Jak w ustawieniach'), findsOneWidget);
      expect(find.text('Jak globalnie'), findsNothing);
    });

    testWidgets('lock mode and delay: padded target, "Nigdy (bez hasła)"', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          const LockModeSettingChoice(),
          overrides: buildAppSettingsProviderOverrides(
            store: MemoryAppSettingsStore(),
            initialState: const AppSettings(lockMode: AppLockMode.background),
            hydrationEnabled: false,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Nigdy (bez hasła)'), findsOneWidget);
      _expectComfortableChips(tester, 'settings-lock-mode-dropdown');
      _expectComfortableChips(tester, 'settings-lock-delay-choices');
    });
  });

  testWidgets('the diagnostics screen: the warning first, one place to copy '
      'and save, a question before clearing, no raw error', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory folder = Directory.systemTemp.createTempSync('zen-diag-');
    addTearDown(() {
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        // Still held open by the log on Windows: the system cleans it up.
      }
    });
    await tester.runAsync(() async {
      await ZenDiagnosticsLog.attach(folder, source: 'ui');
      ZenDiagnosticsLog.write('INFO  something happened in the background');
      await ZenDiagnosticsLog.settled;
    });
    await _pumpApp(tester);
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    await _route(tester);
    final Finder entry = find.byKey(const Key('settings-nav-diagnostics'));
    await tester.scrollUntilVisible(
      entry,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(entry);
    await _route(tester);
    await _real(tester);

    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      contains('something happened'),
    );
    // Said before the buttons, and the buttons are there once.
    final Finder warning = find.textContaining('zapisuje się bez szyfrowania');
    expect(warning, findsOneWidget);
    expect(find.byKey(const Key('diagnostics-copy')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-save')), findsOneWidget);
    expect(
      tester.getTopLeft(warning).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('diagnostics-copy'))).dy),
    );

    // Saving fails here (no system dialog in a test): the person is told
    // plainly, the exception stays in the log.
    await tester.tap(find.byKey(const Key('diagnostics-save')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.text('Nie udało się zapisać pliku.'), findsOneWidget);
    final String snack = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .map((Text t) => t.data ?? '')
        .join(' ');
    expect(snack, isNot(contains('Error')));
    expect(snack, isNot(contains('Exception')));

    // Clearing asks first; "Anuluj" keeps everything.
    await tester.tap(find.byKey(const Key('diagnostics-clear')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('diagnostics-clear-dialog')), findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('diagnostics-clear-dialog')), findsNothing);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      contains('something happened'),
    );
    expect(await tester.runAsync(ZenDiagnosticsLog.read), isNotEmpty);

    await tester.tap(find.byKey(const Key('diagnostics-clear')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('diagnostics-clear-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _real(tester);
    // What was in it is gone (the app may have written a line since).
    expect(
      await tester.runAsync(ZenDiagnosticsLog.read),
      isNot(contains('something happened')),
    );
    expect(find.byType(SelectableText), findsNothing);

    await tester.pageBack();
    await _route(tester);
    await tester.pageBack();
    await _route(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });

  group('the conversation menu', () {
    final String ada = PeerShareCodec.normalizeAddress('200::ada');

    Future<ProviderContainer> pumpConversation(
      WidgetTester tester, {
      required bool postNotifications,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...buildAppSettingsProviderOverrides(
              store: MemoryAppSettingsStore(),
              initialState: AppSettings(postNotifications: postNotifications),
              hydrationEnabled: false,
            ),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(),
            ),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                book: FriendshipBook.restore(
                  profiles: <String, FriendProfile>{
                    ada: FriendProfile(
                      address: ada,
                      displayName: 'Ada',
                      status: FriendRelationshipStatus.accepted,
                    ),
                  },
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: ConversationScreen(peerAddress: ada, title: 'Ada'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(ConversationScreen)),
      );
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('conversation-menu-button')));
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('names what each entry does', (WidgetTester tester) async {
      await pumpConversation(tester, postNotifications: true);
      await openMenu(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('conversation-notification-privacy-menu')),
          matching: find.text('Treść powiadomień'),
        ),
        findsOneWidget,
      );
      expect(find.text('Wycisz posty tej osoby'), findsOneWidget);
    });

    testWidgets('muting says so, and unmuting too, and the entry follows', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = await pumpConversation(
        tester,
        postNotifications: true,
      );
      await openMenu(tester);
      await choose(tester, 'conversation-post-notifications-menu');
      expect(
        container.read(appSettingsControllerProvider).mutedPostAuthors,
        <String>{ada},
      );
      expect(
        find.text(
          'Bez powiadomień o nowych postach: Ada. Posty nadal są na Tablicy.',
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await openMenu(tester);
      expect(
        find.text('Włącz powiadomienia o postach tej osoby'),
        findsOneWidget,
      );
      await choose(tester, 'conversation-post-notifications-menu');
      expect(
        container.read(appSettingsControllerProvider).mutedPostAuthors,
        isEmpty,
      );
      expect(
        find.text('Znów powiadomimy o nowych postach: Ada.'),
        findsOneWidget,
      );
    });

    testWidgets('with the switch for posts off it explains instead of '
        'turning it on', (WidgetTester tester) async {
      final ProviderContainer container = await pumpConversation(
        tester,
        postNotifications: false,
      );
      await openMenu(tester);
      await choose(tester, 'conversation-post-notifications-menu');
      expect(
        find.text(
          'Powiadomienia o nowych postach znajomych są wyłączone w '
          'Ustawieniach.',
        ),
        findsOneWidget,
      );
      final AppSettings settings = container.read(
        appSettingsControllerProvider,
      );
      expect(settings.postNotifications, isFalse);
      expect(settings.mutedPostAuthors, isEmpty);
    });
  });
}
