import 'dart:async';
import 'dart:io';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/calls/presentation/call_session_widgets.dart';
import 'package:zen/src/features/calls/presentation/call_surface_screen.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/runtime_lifecycle_bridge.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_biometric_auth.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

void _ignoreDevice(CallMediaDevice device) {}

const String _defaultAdaAddress = 'ada.ygg';
const String _defaultAdaPreview =
    'Jestem online, mogę wejść na rozmowę za 5 minut.';

SocialHubState _defaultAdaSocialState() {
  return SocialHubState.empty().copyWith(
    friends: const <String, FriendProfile>{
      _defaultAdaAddress: FriendProfile(
        address: _defaultAdaAddress,
        displayName: 'Ada',
        status: FriendRelationshipStatus.accepted,
        isOnline: true,
        lastMessagePreview: _defaultAdaPreview,
        lastActivityLabel: 'Teraz',
        unreadCount: 1,
      ),
    },
  );
}

MemoryMessageTimelineStore _defaultAdaTimelineStore() {
  return MemoryMessageTimelineStore(<String, List<ChatMessage>>{
    _defaultAdaAddress: const <ChatMessage>[
      ChatMessage(
        id: 'ada-msg-1',
        sender: _defaultAdaAddress,
        text: _defaultAdaPreview,
        sentAtMillis: 1,
        direction: ChatMessageDirection.incoming,
      ),
    ],
  });
}

/// Locks the app with the button on the left rail.
Future<void> _lockFromRail(WidgetTester tester) async {
  expect(find.byKey(const Key('side-tabs-lock')), findsOneWidget);
  tester
      .widget<IconButton>(find.byKey(const Key('side-tabs-lock')))
      .onPressed!
      .call();
  await tester.pump();
}

Future<void> _openProfileFromShell(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('chats-status-chip')));
  await tester.pumpAndSettle();
}

/// The profile page hosts text fields (which own horizontal Scrollables), so
/// scrolling must target the page ListView itself, never `.last`.
Finder _profileScrollable() {
  return find
      .descendant(
        of: find.byKey(const Key('settings-tab-body')),
        matching: find.byType(Scrollable),
      )
      .first;
}

/// Opens one topic of the settings list (they live on their own pages).
Future<void> _openSettingsPage(WidgetTester tester, String tileKey) async {
  await tester.scrollUntilVisible(
    find.byKey(Key(tileKey)),
    220,
    scrollable: _profileScrollable(),
  );
  await tester.pump();
  await tester.tap(find.byKey(Key(tileKey)));
  await tester.pumpAndSettle();
}

Finder _settingsPageScrollable() {
  return find
      .descendant(
        of: find.byKey(const Key('settings-page-body')),
        matching: find.byType(Scrollable),
      )
      .first;
}

Future<void> _moveAppToBackground(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
}

Future<void> _resumeAppFromBackground(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
}

/// Unmounts the app and disposes [container] inside the test body: the
/// services' timers are cancelled on dispose, and a tear-down runs only
/// after the pending-timer check.
Future<void> _disposeUncontrolled(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
}

void main() {
  testWidgets('shows the unified shell with the chats tab by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));

    expect(find.byKey(const Key('chats-page')), findsOneWidget);
    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    expect(find.byKey(const Key('chats-status-chip')), findsOneWidget);
    expect(find.byKey(const Key('chats-search-field')), findsOneWidget);
    expect(find.text('Czaty'), findsOneWidget);
    expect(find.byKey(const Key('inbox-tab-body')), findsNothing);
  });

  testWidgets(
    'windows shell shows the status chip and hides empty local-code placeholders',
    (WidgetTester tester) async {
      final TargetPlatform? previousPlatform =
          debugDefaultTargetPlatformOverride;
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;

        await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));

        expect(find.byKey(const Key('chats-status-chip')), findsOneWidget);
        expect(find.text('Połączono'), findsOneWidget);

        await _openProfileFromShell(tester);
        await _openSettingsPage(tester, 'settings-nav-network');

        expect(find.byKey(const Key('settings-network-card')), findsOneWidget);
        expect(find.text('Jeszcze niegotowy'), findsNothing);
        expect(
          find.text(
            'Kod pojawi się od razu po starcie nodea i pobraniu lokalnego adresu.',
          ),
          findsNothing,
        );
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  testWidgets('profile tab opens the blocked users list from a button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                _defaultAdaAddress: FriendProfile(
                  address: _defaultAdaAddress,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.blocked,
                  blockNote: 'Spam',
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await _openProfileFromShell(tester);

    // The lock panel is always pinned to the top; without a password it
    // offers to set one instead of locking.
    expect(find.byKey(const Key('settings-lock-now-button')), findsOneWidget);
    expect(find.text('Ustaw hasło'), findsWidgets);

    await _openSettingsPage(tester, 'settings-nav-security');
    expect(find.byKey(const Key('settings-security-section')), findsOneWidget);
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-blocked-button')),
      220,
      scrollable: _profileScrollable(),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-blocked-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('blocked-friends-screen')), findsOneWidget);
    expect(find.byKey(const Key('settings-unblock-ada.ygg')), findsOneWidget);
  });

  testWidgets(
    'the ten-second reset hold stays ten seconds with animations turned off',
    (WidgetTester tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));

      await _openProfileFromShell(tester);
      await _openSettingsPage(tester, 'settings-nav-reset');

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('desktop-reset-data-button'))),
      );
      // Small steps, like real frames: the hold is timed from its first
      // frame, so one big jump would skip most of it.
      Duration held = Duration.zero;
      const Duration step = Duration(milliseconds: 100);
      while (held < const Duration(milliseconds: 9500)) {
        await tester.pump(step);
        held += step;
      }
      expect(
        find.byKey(const Key('desktop-reset-confirm-dialog')),
        findsNothing,
        reason: 'the hold must not finish early',
      );
      for (int i = 0; i < 15; i++) {
        await tester.pump(step);
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const Key('desktop-reset-confirm-dialog')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('an own GIF key is checked before it replaces the default', (
    WidgetTester tester,
  ) async {
    final List<String> tried = <String>[];
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gifCatalogFactoryProvider.overrideWithValue((String key) {
            tried.add(key);
            return key == 'dobry-klucz'
                ? const _FakeGifCatalog(<GifCatalogEntry>[])
                : const _BrokenGifCatalog();
          }),
        ],
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) {
            container = ProviderScope.containerOf(context);
            return const ZenRewriteApp();
          },
        ),
      ),
    );
    await _openProfileFromShell(tester);
    // The settings list is lazy: the tile is built once scrolled to.
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-nav-gifs')),
      220,
      scrollable: _profileScrollable(),
    );
    await tester.pump();
    expect(find.text('Domyślny klucz aplikacji'), findsOneWidget);
    await _openSettingsPage(tester, 'settings-nav-gifs');

    // Not a key at all: refused without asking Klipy.
    await tester.enterText(
      find.byKey(const Key('settings-gif-key-field')),
      'zly klucz&x=1',
    );
    await tester.tap(find.byKey(const Key('settings-gif-key-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-gif-key-error')), findsOneWidget);
    expect(tried, isEmpty);

    // Looks fine, but Klipy refuses it: the default stays.
    await tester.enterText(
      find.byKey(const Key('settings-gif-key-field')),
      'wygasly-klucz',
    );
    await tester.tap(find.byKey(const Key('settings-gif-key-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-gif-key-error')), findsOneWidget);
    expect(container.read(appSettingsControllerProvider).gifApiKey, isEmpty);

    await tester.enterText(
      find.byKey(const Key('settings-gif-key-field')),
      ' dobry-klucz ',
    );
    await tester.tap(find.byKey(const Key('settings-gif-key-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-gif-key-info')), findsOneWidget);
    expect(
      container.read(appSettingsControllerProvider).gifApiKey,
      'dobry-klucz',
    );
    expect(tried.last, 'dobry-klucz');

    await tester.tap(find.byKey(const Key('settings-gif-key-default')));
    await tester.pumpAndSettle();
    expect(container.read(appSettingsControllerProvider).gifApiKey, isEmpty);
    expect(find.byKey(const Key('settings-gif-key-default')), findsNothing);
  });

  testWidgets(
    'reset data panel waits for a ten-second hold before showing confirmation',
    (WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));

      await _openProfileFromShell(tester);
      await _openSettingsPage(tester, 'settings-nav-reset');

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('desktop-reset-data-button'))),
      );
      await tester.pump(const Duration(seconds: 9));

      expect(
        find.byKey(const Key('desktop-reset-confirm-dialog')),
        findsNothing,
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('desktop-reset-confirm-dialog')),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'service controls are readable and react without rebuilding chaos',
    (WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );

      await _openProfileFromShell(tester);
      await _openSettingsPage(tester, 'settings-nav-network');
      await tester.tap(find.byKey(const Key('settings-tech-info-tile')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('service-toggle-button')),
        220,
        scrollable: _settingsPageScrollable(),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings-network-card')), findsOneWidget);
      expect(find.text('Połączono'), findsOneWidget);
      expect(find.text('Zatrzymaj serwis'), findsOneWidget);
      expect(find.text('Resetuj sieć'), findsOneWidget);

      await container.read(appShellControllerProvider.notifier).toggleService();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Brak sieci'), findsOneWidget);
      expect(find.text('Uruchom serwis'), findsOneWidget);

      final Future<void> resetFuture = container
          .read(appShellControllerProvider.notifier)
          .resetService();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await resetFuture;
      await tester.pump();

      expect(find.text('Synchronizacja'), findsNothing);
      expect(find.text('Połączono'), findsOneWidget);
      expect(find.text('39 ms'), findsOneWidget);
    },
  );

  testWidgets('profile tab edits persisted runtime preferences', (
    WidgetTester tester,
  ) async {
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
      const AppSettings(inboxLimitMb: 80, autoCleanupDays: 6),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsStoreProvider.overrideWithValue(settingsStore)],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    await _openProfileFromShell(tester);

    await _openSettingsPage(tester, 'settings-nav-appearance');
    await tester.ensureVisible(find.text('Ciemny'));
    await tester.pump();
    await tester.tap(find.text('Ciemny'));
    await tester.pumpAndSettle();
    expect((await settingsStore.load())!.themeMode, AppThemeMode.dark);
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    await _openSettingsPage(tester, 'settings-nav-data');

    expect(find.byKey(const Key('settings-preferences-panel')), findsOneWidget);
    expect(find.text('Limit zdarzeń: 80 MB'), findsOneWidget);

    final SwitchListTile unlimitedSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings-inbox-unlimited-switch')),
    );
    unlimitedSwitch.onChanged!(true);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-inbox-limit-editor')), findsNothing);
    expect((await settingsStore.load())!.inboxLimitMb, 0);

    final TextFormField cleanupField = tester.widget<TextFormField>(
      find.byKey(const Key('settings-auto-cleanup-field')),
    );
    cleanupField.onChanged!.call('14');
    await tester.pumpAndSettle();

    final AppSettings persisted = (await settingsStore.load())!;
    expect(persisted.autoCleanupDays, 14);
    expect(persisted.themeMode, AppThemeMode.dark);
  });

  testWidgets(
    'security section can lock the app and unlock with the password',
    (WidgetTester tester) async {
      final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
        const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );
      final LocalAppSecurityService security = LocalAppSecurityService(
        credentialsStore: MemorySecurityCredentialsStore(),
        passwordIterations: 10,
      );
      await security.initialize(
        settings: const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );
      await security.setPassword('sekret12');
      await security.applySettings(
        const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsStoreProvider.overrideWithValue(settingsStore),
            appSecurityServiceProvider.overrideWithValue(security),
            // The real app layout, with the rail and its lock button.
            ledgerNodeEnabledProvider.overrideWithValue(true),
            ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pump();

      // "Zablokuj teraz" sits on the left rail.
      await _lockFromRail(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const Key('app-unlock-password-field')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('app-unlock-password-field')),
        'zle-haslo',
      );
      await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('app-unlock-password-field')),
        'sekret12',
      );
      await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);
      // Locking tears down the whole navigator, so the shell comes back on
      // the chats page regardless of where the lock happened.
      expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    },
  );

  testWidgets('security gate can unlock with biometrics', (
    WidgetTester tester,
  ) async {
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
      const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: MemoryKeyVault(),
    );
    await security.initialize(
      settings: const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    await security.setPassword('sekret12');
    await security.setBiometricUnlockEnabled(true);
    await security.applySettings(
      const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 9,
      ),
    );
    const _FakeBiometricAuthenticator biometric = _FakeBiometricAuthenticator(
      available: true,
      shouldAuthenticate: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(settingsStore),
          appSecurityServiceProvider.overrideWithValue(security),
          // The real app layout, with the rail and its lock button.
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          appBiometricAuthenticatorProvider.overrideWithValue(biometric),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    await _lockFromRail(tester);
    await tester.pumpAndSettle();

    // Set up: the biometric prompt comes by itself, no tap needed.
    expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);
    expect(security.isLocked, isFalse);
  });

  testWidgets('biometric unlock stays off until the person turns it on', (
    WidgetTester tester,
  ) async {
    const AppSettings securitySettings = AppSettings(
      lockMode: AppLockMode.background,
      backgroundLockDelaySeconds: 9,
    );
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
      securitySettings,
    );
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: MemoryKeyVault(),
    );
    await security.initialize(settings: securitySettings);
    await security.setPassword('sekret12');
    await security.applySettings(securitySettings);
    const _FakeBiometricAuthenticator biometric = _FakeBiometricAuthenticator(
      available: true,
      shouldAuthenticate: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(settingsStore),
          appSecurityServiceProvider.overrideWithValue(security),
          // The real app layout, with the rail and its lock button.
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          appBiometricAuthenticatorProvider.overrideWithValue(biometric),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    await _lockFromRail(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-unlock-password-field')), findsOneWidget);
    expect(find.byKey(const Key('app-unlock-biometric-button')), findsNothing);
    expect(security.isLocked, isTrue);
  });

  testWidgets('panic password on the lock screen silently wipes local data', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = Directory(
      '${Directory.systemTemp.path}/zen-panic-wipe-${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    const AppSettings securitySettings = AppSettings(
      lockMode: AppLockMode.background,
      backgroundLockDelaySeconds: 9,
    );
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
      securitySettings,
    );
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
    );
    await security.initialize(settings: securitySettings);
    await security.setPassword('sekret12');
    await security.setPanicPassword('panika123');
    await security.applySettings(securitySettings);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          appSettingsStoreProvider.overrideWithValue(settingsStore),
          appSecurityServiceProvider.overrideWithValue(security),
          supportDirectoryResolverProvider.overrideWithValue(
            () async => tempDir,
          ),
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    security.lock();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-unlock-password-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('app-unlock-password-field')),
      'panika123',
    );
    // The wipe performs real file I/O, so the tap and the settling must
    // happen on the real event loop.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The wipe is silent: no error text, no snackbar, straight back to a
    // fresh-install chats tab with the lock gone.
    expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);
    expect(find.text('Nieprawidłowe hasło.'), findsNothing);
    expect(security.hasPassword, isFalse);
    expect(security.hasPanicPassword, isFalse);
    expect(security.isLocked, isFalse);
    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    expect(find.byKey(const Key('conversation-card-ada.ygg')), findsNothing);
  });

  testWidgets(
    'global call banner stays visible on the classic shell and can open the conversation',
    (WidgetTester tester) async {
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
                activeCall: const CallSession(
                  id: 'call-shell-1',
                  peerAddress: peerAddress,
                  displayName: 'Ada',
                  kind: CallInviteKind.audio,
                  status: CallSessionStatus.active,
                  startedAtMillis: 7,
                ),
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );

      expect(find.text('Ada'), findsWidgets);

      await tester.tap(
        find.byKey(
          const Key('conversation-card-200:1111:2222:3333:4444:5555:6666:7777'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('conversation-menu-button')), findsOneWidget);
      // Address details stay hidden until the reveal button is used.
      expect(
        find.textContaining(PeerShareCodec.shareIdForAddress(peerAddress)),
        findsNothing,
      );
      expect(find.text(peerAddress), findsNothing);

      await tester.tap(find.byKey(const Key('conversation-menu-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conversation-menu-show-address')),
        findsNothing,
      );
      expect(find.text(peerAddress), findsNothing);
      expect(
        find.textContaining(PeerShareCodec.shareIdForAddress(peerAddress)),
        findsNothing,
      );
    },
  );

  testWidgets(
    'incoming call overlay covers a pushed route such as the settings screen',
    (WidgetTester tester) async {
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            callMediaSessionControllerProvider.overrideWithValue(callMedia),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Push a full-screen route on top of the shell.
      await _openProfileFromShell(tester);
      expect(find.byKey(const Key('settings-tab-body')), findsOneWidget);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('settings-tab-body'))),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: peerAddress,
              callId: 'call-over-settings',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 9,
          );
      await tester.pumpAndSettle();

      // The overlay lives above the root Navigator, so the pushed route can no
      // longer bury a ringing call.
      expect(find.byKey(const Key('incoming-call-overlay')), findsOneWidget);

      // Being in the tree is not enough — while the overlay sat inside the
      // home route, the pushed settings screen swallowed every tap meant for
      // it. Declining has to actually reach the button.
      await tester.tap(find.byKey(const Key('incoming-call-decline-button')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(socialHubControllerProvider).activeCall, isNull);
      expect(find.byKey(const Key('incoming-call-overlay')), findsNothing);
      expect(find.byKey(const Key('settings-tab-body')), findsOneWidget);
    },
  );

  testWidgets(
    'global incoming call banner can accept outside the conversation screen',
    (WidgetTester tester) async {
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      await transport.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            callMediaSessionControllerProvider.overrideWithValue(callMedia),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
                activeCall: const CallSession(
                  id: 'call-shell-2',
                  peerAddress: peerAddress,
                  displayName: 'Ada',
                  kind: CallInviteKind.video,
                  status: CallSessionStatus.ringing,
                  startedAtMillis: 8,
                  isIncoming: true,
                ),
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: peerAddress,
              callId: 'call-shell-2',
              content: 'video',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 9,
          );
      await tester.pumpAndSettle();

      final Finder acceptButton = find.byKey(
        const Key('incoming-call-accept-button'),
      );
      expect(acceptButton, findsOneWidget);
      await tester.tap(acceptButton);
      await tester.pumpAndSettle();

      expect(callMedia.acceptedIncomingCallId, 'call-shell-2');
      expect(callMedia.acceptedRemoteAddress, peerAddress);
      expect(find.byKey(const Key('call-surface-screen')), findsOneWidget);
      expect(find.text('Rozmowa wideo trwa'), findsOneWidget);
    },
  );

  testWidgets(
    'the notification accept route answers the ringing call on its own',
    (WidgetTester tester) async {
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      await transport.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            callMediaSessionControllerProvider.overrideWithValue(callMedia),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
                activeCall: const CallSession(
                  id: 'call-notification-accept',
                  peerAddress: peerAddress,
                  displayName: 'Ada',
                  kind: CallInviteKind.audio,
                  status: CallSessionStatus.ringing,
                  startedAtMillis: 8,
                  isIncoming: true,
                ),
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: peerAddress,
              callId: 'call-notification-accept',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 9,
          );
      await tester.pumpAndSettle();

      // Exactly what the background service queues when the user hits
      // "Odbierz" on the Android notification: answering needs the microphone,
      // so the app is launched on the call route with the accept flag set.
      await container
          .read(socialHubControllerProvider.notifier)
          .requestLaunchFromRouteKey(
            buildCallRouteKey(
              peerAddress: peerAddress,
              title: 'Ada',
              autoAccept: true,
            ),
          );
      await tester.pumpAndSettle();

      expect(callMedia.acceptedIncomingCallId, 'call-notification-accept');
      expect(find.byKey(const Key('incoming-call-overlay')), findsNothing);
      expect(find.byKey(const Key('call-surface-screen')), findsOneWidget);
    },
  );

  testWidgets('global active call banner can open the full call surface', (
    WidgetTester tester,
  ) async {
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                peerAddress: FriendProfile(
                  address: peerAddress,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
              activeCall: const CallSession(
                id: 'call-shell-surface',
                peerAddress: peerAddress,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.active,
                startedAtMillis: 10,
              ),
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('floating-call-chip')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call-surface-screen')), findsOneWidget);
    expect(find.text('Rozmowa audio trwa'), findsOneWidget);
    expect(
      find.byKey(const Key('call-surface-top-chat-button')),
      findsOneWidget,
    );
  });

  testWidgets('global active call banner can toggle media controls', (
    WidgetTester tester,
  ) async {
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController()
          ..activeCallIdValue = 'call-shell-controls'
          ..activeKindValue = CallInviteKind.video;
    final ProviderContainer container = ProviderContainer(
      overrides: [
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            friends: const <String, FriendProfile>{
              peerAddress: FriendProfile(
                address: peerAddress,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
            },
            activeCall: const CallSession(
              id: 'call-shell-controls',
              peerAddress: peerAddress,
              displayName: 'Ada',
              kind: CallInviteKind.video,
              status: CallSessionStatus.active,
              startedAtMillis: 9,
              isCameraEnabled: true,
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('global-call-mute-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('global-call-speaker-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('global-call-camera-button')));
    await tester.pumpAndSettle();

    final CallSession session = container
        .read(socialHubControllerProvider)
        .activeCall!;
    expect(session.isMuted, isTrue);
    expect(session.isSpeakerOn, isTrue);
    expect(session.isCameraEnabled, isFalse);
    expect(callMedia.mutedValue, isTrue);
    expect(callMedia.speakerOnValue, isTrue);
    expect(callMedia.cameraEnabledValue, isFalse);
    await _disposeUncontrolled(tester, container);
  });

  testWidgets('conversation call card can open call surface and return', (
    WidgetTester tester,
  ) async {
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                peerAddress: FriendProfile(
                  address: peerAddress,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
              activeCall: const CallSession(
                id: 'call-chat-surface',
                peerAddress: peerAddress,
                displayName: 'Ada',
                kind: CallInviteKind.video,
                status: CallSessionStatus.active,
                startedAtMillis: 11,
                isCameraEnabled: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: CallFloatingOverlay(
            child: ConversationScreen(peerAddress: peerAddress, title: 'Ada'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('floating-call-chip')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('call-surface-screen')), findsOneWidget);

    await tester.tap(find.byKey(const Key('call-surface-top-chat-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-menu-button')), findsOneWidget);
    expect(find.byKey(const Key('call-surface-screen')), findsNothing);
  });

  testWidgets('social tabs react to live signal state instead of mock lists', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          // Invited from here (no name given): only an invitation the user
          // sent can be completed by the other side's accept.
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  status: FriendRelationshipStatus.pendingOutgoing,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    expect(find.text('Ada'), findsNothing);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendAccept,
            sender: 'ada.ygg',
            displayName: 'Ada',
          ),
          receivedAtMillis: 1,
        );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    expect(find.byKey(const Key('conversation-card-ada.ygg')), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets(
    'inbox entries land at the top of the chats tab and can be cleared',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          ],
          child: const ZenRewriteApp(),
        ),
      );

      expect(find.text('Nowe (1)'), findsNothing);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendRequest,
              sender: 'ada.ygg',
              displayName: 'Ada',
              content: 'Mam chwilę na testy.',
            ),
            receivedAtMillis: 2,
          );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
      expect(find.text('Nowe (1)'), findsOneWidget);
      // The live-notification banner mirrors the inbox card title.
      expect(find.textContaining('Nowe zaproszenie od Ada'), findsWidgets);

      await tester.tap(find.byKey(const Key('inbox-clear-all-button')));
      await tester.pumpAndSettle();

      expect(find.text('Nowe (1)'), findsNothing);
      expect(find.byKey(const Key('inbox-clear-all-button')), findsNothing);
    },
  );

  testWidgets('friend request can be accepted directly from inbox', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendRequest,
            sender: 'ada.ygg',
            displayName: 'Ada',
            content: 'Mam chwilę na testy.',
          ),
          receivedAtMillis: 2,
        );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('inbox-accept-ada.ygg')));
    await tester.pumpAndSettle();
    // One tap: they keep the name from their profile.
    await tester.tap(find.byKey(const Key('inbox-accept-ada.ygg')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    expect(find.textContaining('Nowe zaproszenie od Ada'), findsNothing);
    expect(find.byKey(const Key('conversation-card-ada.ygg')), findsOneWidget);
  });

  testWidgets('add friend sheet creates a pending outgoing conversation', (
    WidgetTester tester,
  ) async {
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('open-add-friend-sheet-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('add-friend-target-field')),
      peerAddress,
    );
    await tester.enterText(
      find.byKey(const Key('add-friend-nickname-field')),
      'Ada z pracy',
    );
    await tester.enterText(
      find.byKey(const Key('add-friend-message-field')),
      'Hej Ada',
    );
    await tester.tap(find.byKey(const Key('submit-add-friend-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('Czekasz na akceptację'), findsOneWidget);

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('conversation-card-$peerAddress')), findsOneWidget);
    expect(find.text('Oczekuje'), findsOneWidget);
    // Their name comes with their answer; until then the nickname helps.
    expect(find.text('Kontakt Zen'), findsWidgets);
    expect(find.text('Ada z pracy'), findsOneWidget);
  });

  testWidgets('add friend sheet shows the polished optional note placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));

    await tester.tap(find.byKey(const Key('open-add-friend-sheet-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Opcjonalna wiadomość dołączona do zaproszenia'),
      findsOneWidget,
    );
    final TextField field = tester.widget<TextField>(
      find.byKey(const Key('add-friend-message-field')),
    );
    expect(field.decoration?.hintStyle?.fontStyle, FontStyle.italic);
  });

  testWidgets('add friend sheet can scan a QR target', (
    WidgetTester tester,
  ) async {
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    final PeerShareProfile profile = PeerShareCodec.buildLocalProfile(
      address: peerAddress,
      displayName: 'Ada',
    )!;
    final _FakePeerQrScanner scanner = _FakePeerQrScanner(profile.qrData);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          peerQrScannerProvider.overrideWithValue(scanner),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('open-add-friend-sheet-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-friend-scan-button')));
    await tester.pumpAndSettle();

    final TextField scannedTargetField = tester.widget<TextField>(
      find.byKey(const Key('add-friend-target-field')),
    );
    expect(scannedTargetField.controller?.text, profile.inviteCode);
    // The code carries no name, and there is no field to make one up: the
    // name comes from their profile.
    expect(
      find.byKey(const Key('add-friend-display-name-field')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('submit-add-friend-button')));
    await tester.pumpAndSettle();

    // Scanned in person: the app asks whether you met, and how close you
    // are.
    expect(find.text('Poznaliśmy się osobiście?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('met-level-skip')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Czekasz na akceptację'), findsOneWidget);

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('conversation-card-$peerAddress')), findsOneWidget);
    expect(find.text('Oczekuje'), findsOneWidget);
  });

  testWidgets(
    'external zen deep link opens the add-friend sheet with prefilled input',
    (WidgetTester tester) async {
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final _FakeDeepLinkSource deepLinkSource = _FakeDeepLinkSource();
      final PeerShareProfile profile = PeerShareCodec.buildLocalProfile(
        address: peerAddress,
        displayName: 'Ada',
      )!;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [deepLinkSourceProvider.overrideWithValue(deepLinkSource)],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      deepLinkSource.emit(Uri.parse(profile.qrData));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('add-friend-target-field')), findsOneWidget);
      final TextField targetField = tester.widget<TextField>(
        find.byKey(const Key('add-friend-target-field')),
      );
      final TextField nicknameField = tester.widget<TextField>(
        find.byKey(const Key('add-friend-nickname-field')),
      );
      expect(targetField.controller?.text, profile.inviteCode);
      expect(nicknameField.controller?.text, isEmpty);
    },
  );

  testWidgets(
    'a chat link cannot dress a stranger up with a name of its choosing',
    (WidgetTester tester) async {
      const String stranger = '200:1111:2222:3333:4444:5555:6666:7777';
      final _FakeDeepLinkSource deepLinkSource = _FakeDeepLinkSource();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [deepLinkSourceProvider.overrideWithValue(deepLinkSource)],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Any web page or app can fire this at the app.
      deepLinkSource.emit(Uri.parse('zen://chat/$stranger?title=Mama'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation-open-profile')),
        findsOneWidget,
      );
      expect(find.text('Mama'), findsNothing);
      expect(
        find.text(PeerShareCodec.displayNameForAddress(stranger)),
        findsWidgets,
      );
      expect(find.text('Nieznajomy'), findsOneWidget);
    },
  );

  testWidgets('emoji button inserts an emoji into the composer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            _defaultAdaTimelineStore(),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const Key('conversation-emoji-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('emoji-picker-grid')), findsOneWidget);
    await tester.tap(find.byKey(const Key('emoji-0')));
    await tester.pumpAndSettle();

    final TextField composer = tester.widget<TextField>(
      find.byKey(const Key('conversation-composer-field')),
    );
    expect(composer.controller?.text, contains('😀'));
  });

  testWidgets('conversation screen opens and can send a local message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            _defaultAdaTimelineStore(),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    expect(
      find.byKey(const Key('conversation-unread-ada.ygg')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(const Key('conversation-composer-field')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('conversation-composer-field')),
      'Wchodze za minute.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('conversation-send-button')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Wchodze za minute.'), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-unread-ada.ygg')), findsNothing);
    expect(find.text('Wchodze za minute.'), findsOneWidget);
  });

  testWidgets('conversation shows read receipt state for outgoing messages', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              'ada.ygg': const <ChatMessage>[
                ChatMessage(
                  id: 'read-1',
                  sender: 'self',
                  text: 'Masz to?',
                  sentAtMillis: 1,
                  direction: ChatMessageDirection.outgoing,
                  deliveryState: ChatMessageDeliveryState.delivered,
                  readAtMillis: 2,
                ),
              ],
            }),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    expect(find.text('Masz to?'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  testWidgets('conversation renders inline file attachments', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              'ada.ygg': <ChatMessage>[
                ChatMessage(
                  id: 'file-1',
                  sender: 'ada.ygg',
                  text: '📎 raport.txt',
                  sentAtMillis: 5,
                  direction: ChatMessageDirection.incoming,
                  type: ChatMessageType.file,
                  fileName: 'raport.txt',
                  mimeType: 'text/plain',
                  attachmentSizeBytes: 3,
                  attachmentBytes: Uint8List.fromList(<int>[1, 2, 3]),
                ),
              ],
            }),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    expect(find.text('raport.txt'), findsOneWidget);
    expect(find.text('3 B'), findsOneWidget);
    expect(find.text('Zapisz kopie'), findsOneWidget);
  });

  testWidgets('conversation renders voice and video attachment states', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              'ada.ygg': const <ChatMessage>[
                ChatMessage(
                  id: 'voice-1',
                  sender: 'ada.ygg',
                  text: '🎤 Wiadomość głosowa',
                  sentAtMillis: 6,
                  direction: ChatMessageDirection.incoming,
                  type: ChatMessageType.voice,
                  fileName: 'voice.m4a',
                  mimeType: 'audio/mp4',
                  durationMs: 4200,
                  attachmentSizeBytes: 2048,
                ),
                ChatMessage(
                  id: 'video-1',
                  sender: 'ada.ygg',
                  text: '🎬 Wideo',
                  sentAtMillis: 7,
                  direction: ChatMessageDirection.incoming,
                  type: ChatMessageType.video,
                  fileName: 'clip.mp4',
                  mimeType: 'video/mp4',
                  durationMs: 9500,
                  attachmentSizeBytes: 4096,
                ),
              ],
            }),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const MaterialApp(
          home: ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('voice.m4a'), findsOneWidget);
    expect(find.text('00:04 • 2.0 KB'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('00:09 • 4.0 KB'), findsOneWidget);
    expect(find.text('Transfer w toku'), findsNWidgets(2));
  });

  testWidgets('conversation can pick and send a GIF from the catalog', (
    WidgetTester tester,
  ) async {
    final MemoryMessageTimelineStore timelineStore =
        MemoryMessageTimelineStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gifCatalogProvider.overrideWithValue(
            const _FakeGifCatalog(<GifCatalogEntry>[
              GifCatalogEntry(
                previewUrl: 'https://example.com/cat-preview.gif',
                sendUrl: 'https://example.com/cat.gif',
                label: 'Kot',
              ),
            ]),
          ),
          gifDownloaderProvider.overrideWithValue(_FakeGifDownloader()),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const MaterialApp(
          home: ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-gif-button')));
    // Not pumpAndSettle: the previews' spinners / animations never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Wybierz GIF'), findsOneWidget);
    // GIF search is a third-party connection, and the picker says so.
    expect(
      find.text('Wyszukiwanie GIF-ów łączy się z klipy.com.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('conversation-gif-tile-0')));
    // Bounded pumps: the sent GIF's bubble shows a spinner that never settles
    // (its codec decodes outside fake async).
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
    expect(messages, hasLength(1));
    expect(messages.single.type, ChatMessageType.image);
    // The sender downloaded the GIF and sent its bytes as an attachment.
    expect(messages.single.attachmentBytes, _tinyGif);
    expect(messages.single.mimeType, 'image/gif');
    expect(messages.single.fileName, 'gif.gif');
  });

  testWidgets('conversation toolbar can send an audio call invite', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController();
    await transport.start();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
        callReRingIntervalProvider.overrideWithValue(Duration.zero),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(<String, List<ChatMessage>>{
            '200:1111:2222:3333:4444:5555:6666:7777': const <ChatMessage>[],
          }),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            friends: const <String, FriendProfile>{
              '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                address: '200:1111:2222:3333:4444:5555:6666:7777',
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(
      find.byKey(
        const Key('conversation-card-200:1111:2222:3333:4444:5555:6666:7777'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-audio-button')));
    await tester.pumpAndSettle();

    expect(
      transport.sentSignals
          .lastWhere((signal) => signal.payload['type'] == 'call_invite')
          .payload['kind'],
      'audio',
    );
    expect(
      transport.sentSignals
          .lastWhere((signal) => signal.payload['type'] == 'call_invite')
          .payload['callId'],
      isNotEmpty,
    );
    expect(callMedia.activeKind, CallInviteKind.audio);
    expect(callMedia.startedOutgoingCallId, isNotNull);
    expect(
      container.read(socialHubControllerProvider).activeCall?.status,
      CallSessionStatus.ringing,
    );
    await _disposeUncontrolled(tester, container);
  });

  testWidgets('conversation call buttons keep a gap between audio and video', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                  address: '200:1111:2222:3333:4444:5555:6666:7777',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const MaterialApp(
          home: ConversationScreen(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            title: 'Ada',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect audio = tester.getRect(
      find.byKey(const Key('conversation-audio-button')),
    );
    final Rect video = tester.getRect(
      find.byKey(const Key('conversation-video-button')),
    );
    expect(
      video.left - audio.right,
      greaterThanOrEqualTo(16),
      reason: 'call and video must not sit flush against each other',
    );
  });

  testWidgets('device picker lists every microphone above the system inset', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: 48)),
        child: MaterialApp(
          home: Scaffold(
            body: CallDevicePickerSheet(
              devices: <CallMediaDevice>[
                CallMediaDevice(
                  id: 'mic-a',
                  label: 'Mikrofon 1',
                  kind: CallMediaDeviceKind.microphone,
                ),
                CallMediaDevice(
                  id: 'mic-b',
                  label: 'Mikrofon 2',
                  kind: CallMediaDeviceKind.microphone,
                ),
                CallMediaDevice(
                  id: 'speakerphone',
                  label: 'Głośnik',
                  kind: CallMediaDeviceKind.speaker,
                ),
              ],
              onSelected: _ignoreDevice,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Mikrofon 1'), findsOneWidget);
    expect(find.text('Mikrofon 2'), findsOneWidget);
    expect(find.byType(SafeArea), findsWidgets);
  });

  testWidgets('ringing calls trigger audible waiting feedback', (
    WidgetTester tester,
  ) async {
    int playCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
              activeCall: const CallSession(
                id: 'call-1',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 1,
              ),
            ),
          ),
          systemSoundPlayerProvider.overrideWithValue((
            SystemSoundType type,
          ) async {
            playCount += 1;
          }),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(playCount, greaterThanOrEqualTo(1));
  });

  testWidgets(
    'incoming call controls can accept the current conversation call',
    (WidgetTester tester) async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      await transport.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            callMediaSessionControllerProvider.overrideWithValue(callMedia),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(<String, List<ChatMessage>>{
                '200:1111:2222:3333:4444:5555:6666:7777': const <ChatMessage>[],
              }),
            ),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                    address: '200:1111:2222:3333:4444:5555:6666:7777',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
                activeCall: const CallSession(
                  id: 'call-1',
                  peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
                  displayName: 'Ada',
                  kind: CallInviteKind.video,
                  status: CallSessionStatus.ringing,
                  startedAtMillis: 5,
                  isIncoming: true,
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            home: CallSurfaceScreen(
              peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
              title: 'Ada',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(CallSurfaceScreen)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: '200:1111:2222:3333:4444:5555:6666:7777',
              callId: 'call-1',
              content: 'video',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 6,
          );
      await tester.pumpAndSettle();

      final Finder acceptButton = find.byKey(const Key('call-accept-button'));
      expect(tester.widget<IconButton>(acceptButton).onPressed, isNotNull);
      tester.widget<IconButton>(acceptButton).onPressed!.call();
      await tester.pumpAndSettle();

      expect(callMedia.acceptedIncomingCallId, 'call-1');
      expect(
        container.read(socialHubControllerProvider).activeCall?.status,
        CallSessionStatus.active,
      );
      expect(find.byKey(const Key('call-end-button')), findsOneWidget);
    },
  );

  testWidgets('active call controls update mute, speaker, and camera state', (
    WidgetTester tester,
  ) async {
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController()
          ..activeCallIdValue = 'call-controls'
          ..activeKindValue = CallInviteKind.video;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              '200:1111:2222:3333:4444:5555:6666:7777': const <ChatMessage>[],
            }),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                  address: '200:1111:2222:3333:4444:5555:6666:7777',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
              activeCall: const CallSession(
                id: 'call-controls',
                peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
                displayName: 'Ada',
                kind: CallInviteKind.video,
                status: CallSessionStatus.active,
                startedAtMillis: 6,
                isCameraEnabled: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: CallSurfaceScreen(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            title: 'Ada',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(CallSurfaceScreen)),
    );

    await tester.tap(find.byKey(const Key('call-mute-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-speaker-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('call-camera-button')));
    await tester.pumpAndSettle();

    final CallSession state = container
        .read(socialHubControllerProvider)
        .activeCall!;
    expect(state.isMuted, isTrue);
    expect(state.isSpeakerOn, isTrue);
    expect(state.isCameraEnabled, isFalse);
    expect(callMedia.mutedValue, isTrue);
    expect(callMedia.speakerOnValue, isTrue);
    expect(callMedia.cameraEnabledValue, isFalse);
    expect(find.text('Wyciszony'), findsOneWidget);
    expect(find.text('Głośnik'), findsWidgets);
    expect(find.text('Kamera wył.'), findsWidgets);
  });

  testWidgets('a nickname shows under the name in the chat and the list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            _defaultAdaTimelineStore(),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pseudonim'));
    await tester.pumpAndSettle();
    // Their name is shown, but cannot be changed here.
    expect(
      find.descendant(
        of: find.byKey(const Key('friend-nickname-profile-name')),
        matching: find.text('Ada'),
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('friend-nickname-field')),
      'Ada z chóru',
    );
    await tester.tap(find.byKey(const Key('friend-nickname-save')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Ada z chóru'),
      findsWidgets,
      reason: 'under the name in the header',
    );

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(find.text('Ada'), findsWidgets);
    expect(find.text('Ada z chóru'), findsOneWidget);
  });

  testWidgets('conversation retention dialog saves per-peer cleanup settings', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            _defaultAdaTimelineStore(),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retencja rozmowy'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('retention-cleanup-field')),
      '7',
    );
    await tester.enterText(find.byKey(const Key('retention-limit-field')), '4');
    await tester.tap(find.byKey(const Key('retention-settings-save')));
    await tester.pumpAndSettle();

    final FriendProfile updated = container
        .read(socialHubControllerProvider)
        .friends['ada.ygg']!;
    expect(updated.autoCleanupDays, 7);
    expect(updated.inboxLimitMb, 4);
    await tester.tap(find.byKey(const Key('conversation-menu-button')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Retencja: 7 dni • Limit: 4 MB'),
      findsOneWidget,
    );
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
  });

  testWidgets('conversation menu can clear the current history', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            _defaultAdaTimelineStore(),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    expect(
      find.text('Jestem online, mogę wejść na rozmowę za 5 minut.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('conversation-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wyczyść historię'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-history-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('Brak wiadomości'), findsOneWidget);
    expect(
      find.text('Zacznij rozmowę bez czekania na synchronizację tła.'),
      findsOneWidget,
    );

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(
      find.text('Jestem online, mogę wejść na rozmowę za 5 minut.'),
      findsNothing,
    );
  });

  testWidgets('blocked friends can be unblocked from settings', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(_defaultAdaSocialState()),
          messageTimelineStoreProvider.overrideWithValue(
            _defaultAdaTimelineStore(),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zablokuj'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Relacja zablokowana'), findsOneWidget);

    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-card-ada.ygg')), findsNothing);

    await _openProfileFromShell(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-blocked-button')),
      220,
      scrollable: _profileScrollable(),
    );
    await tester.pump();
    expect(find.byKey(const Key('settings-blocked-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-blocked-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('blocked-friends-screen')), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-unblock-ada.ygg')));
    await tester.pumpAndSettle();

    expect(find.text('Brak zablokowanych użytkowników.'), findsOneWidget);
  });

  testWidgets('background alerts stay visible until the user clears them', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          runtimeLifecycleBindingEnabledProvider.overrideWithValue(false),
          // Ada was invited from here, so her accept completes it.
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.pendingOutgoing,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendAccept,
            sender: 'ada.ygg',
            displayName: 'Ada',
          ),
          receivedAtMillis: 1,
        );
    await container
        .read(socialHubControllerProvider.notifier)
        .setLifecycle(
          const LifecycleSnapshot(
            visibility: AppVisibilityState.foregroundFocused,
            generation: 2,
            capturedAtMillis: 1,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background-alert-banner')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('background-alert-banner')),
        matching: find.text('Ada zaakceptował(a) zaproszenie'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('background-alert-clear-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background-alert-banner')), findsNothing);
  });

  testWidgets('background alert action can open the matching conversation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          runtimeLifecycleBindingEnabledProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.message,
            sender: 'ada.ygg',
            displayName: 'Ada',
            content: 'Wpadnij na czat.',
          ),
          receivedAtMillis: 1,
        );
    await container
        .read(socialHubControllerProvider.notifier)
        .setLifecycle(
          const LifecycleSnapshot(
            visibility: AppVisibilityState.foregroundFocused,
            generation: 2,
            capturedAtMillis: 1,
          ),
        );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('background-alert-open-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('background-alert-open-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-composer-field')),
      findsOneWidget,
    );
    expect(find.text('Ada'), findsWidgets);
  });

  testWidgets('background alerts banner can collapse and clear', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          runtimeLifecycleBindingEnabledProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.message,
            sender: 'ada.ygg',
            displayName: 'Ada',
            content: 'Wiadomość do zwijania.',
          ),
          receivedAtMillis: 1,
        );
    await container
        .read(socialHubControllerProvider.notifier)
        .setLifecycle(
          const LifecycleSnapshot(
            visibility: AppVisibilityState.foregroundFocused,
            generation: 2,
            capturedAtMillis: 1,
          ),
        );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('background-alert-open-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('background-alert-collapse-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('background-alert-open-button')), findsNothing);

    await tester.tap(find.byKey(const Key('background-alert-collapse-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('background-alert-open-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('background-alert-clear-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('background-alert-banner')), findsNothing);
  });

  testWidgets('inbox is the only in-app notification surface', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
              inbox: const <InboxEntry>[
                InboxEntry(
                  id: 'accept-ada',
                  type: InboxEntryType.friendAccepted,
                  title: 'Ada zaakceptował(a) zaproszenie',
                  body: 'Rozmowa jest gotowa od razu.',
                  createdAtMillis: 1,
                  routeKey: 'zen://chat/ada.ygg?title=Ada',
                  peerAddress: 'ada.ygg',
                ),
              ],
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    expect(find.byKey(const Key('runtime-notification-banner')), findsNothing);
    expect(find.text('Ada zaakceptował(a) zaproszenie'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inbox-card-accept-ada')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-composer-field')),
      findsOneWidget,
    );
    expect(find.text('Ada'), findsWidgets);
  });

  testWidgets('runtime lifecycle bridge flushes queued alerts on resume', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );

    await _moveAppToBackground(tester);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.message,
            sender: 'ada.ygg',
            displayName: 'Ada',
            content: 'Wracam za chwilę.',
          ),
          receivedAtMillis: 10,
        );
    await tester.pump();

    expect(
      container.read(socialHubControllerProvider).lifecycle.visibility,
      AppVisibilityState.background,
    );
    expect(
      container.read(socialHubControllerProvider).pendingSignalCount,
      greaterThan(0),
    );

    await _resumeAppFromBackground(tester);
    await tester.pumpAndSettle();

    expect(
      container.read(socialHubControllerProvider).lifecycle.visibility,
      AppVisibilityState.foregroundFocused,
    );
    expect(container.read(socialHubControllerProvider).pendingSignalCount, 0);
    expect(find.byKey(const Key('background-alert-banner')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('background-alert-banner')),
        matching: find.text('Nowa wiadomość od Ada'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'resume stays non-interactive until the security gate is unlocked',
    (WidgetTester tester) async {
      final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
        const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );
      final LocalAppSecurityService security = LocalAppSecurityService(
        credentialsStore: MemorySecurityCredentialsStore(),
        passwordIterations: 10,
      );
      await security.initialize(
        settings: const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );
      await security.setPassword('sekret12');
      await security.applySettings(
        const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            appSettingsStoreProvider.overrideWithValue(settingsStore),
            appSecurityServiceProvider.overrideWithValue(security),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );

      await _moveAppToBackground(tester);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.message,
              sender: 'ada.ygg',
              displayName: 'Ada',
              content: 'Mam cos pilnego.',
            ),
            receivedAtMillis: 10,
          );
      await tester.pump();
      expect(
        container.read(socialHubControllerProvider).lifecycle.visibility,
        AppVisibilityState.background,
      );
      expect(
        container.read(socialHubControllerProvider).pendingSignalCount,
        greaterThan(0),
      );
      security.lock();
      await tester.pumpAndSettle();

      await _resumeAppFromBackground(tester);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('app-unlock-password-field')),
        findsOneWidget,
      );
      expect(
        container.read(socialHubControllerProvider).lifecycle.visibility,
        AppVisibilityState.foreground,
      );
      final lockedQueue = await container.read(signalQueueStoreProvider).load();
      expect(lockedQueue.length, greaterThan(0));

      await tester.enterText(
        find.byKey(const Key('app-unlock-password-field')),
        'sekret12',
      );
      await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);
      expect(
        container.read(socialHubControllerProvider).lifecycle.visibility,
        AppVisibilityState.foregroundFocused,
      );
      expect(container.read(socialHubControllerProvider).pendingSignalCount, 0);
      expect(find.byKey(const Key('background-alert-banner')), findsOneWidget);
    },
  );

  testWidgets('runtime lifecycle bridge tracks window focus changes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    final int viewId = View.of(
      tester.element(find.byType(AppShellScreen)),
    ).viewId;

    expect(
      container.read(socialHubControllerProvider).lifecycle.visibility,
      AppVisibilityState.foregroundFocused,
    );

    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(socialHubControllerProvider).lifecycle.visibility,
      AppVisibilityState.foreground,
    );

    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.forward,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(socialHubControllerProvider).lifecycle.visibility,
      AppVisibilityState.foregroundFocused,
    );
  });

  testWidgets('deep link signal opens inbox after resume', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );

    await _moveAppToBackground(tester);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.deepLink,
            sender: 'ada.ygg',
            routeKey: 'zen://inbox',
          ),
          receivedAtMillis: 8,
        );
    await tester.pump();

    await _resumeAppFromBackground(tester);
    await tester.pumpAndSettle();

    // The inbox tab is gone; zen://inbox lands on the chats tab now.
    expect(find.byKey(const Key('chats-tab-body')), findsOneWidget);
    expect(find.byKey(const Key('inbox-tab-body')), findsNothing);
  });

  testWidgets(
    'conversation card long press opens action sheet with remove and block options',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation-card-ada.ygg')),
        findsOneWidget,
      );

      await tester.longPress(
        find.byKey(const Key('conversation-card-ada.ygg')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Otwórz rozmowę'), findsOneWidget);
      expect(find.text('Pseudonim'), findsOneWidget);
      expect(find.text('Wyczyść historię'), findsOneWidget);
      expect(find.text('Usuń znajomego'), findsOneWidget);
      expect(find.text('Zablokuj użytkownika'), findsOneWidget);

      // Tap Zablokuj użytkownika -> triggers confirmation dialog
      await tester.tap(find.text('Zablokuj użytkownika'));
      await tester.pumpAndSettle();

      expect(find.text('Zablokować użytkownika?'), findsOneWidget);
      await tester.tap(find.text('Zablokuj'));
      await tester.pumpAndSettle();

      // Friend is now blocked and removed from the active chats list
      expect(find.byKey(const Key('conversation-card-ada.ygg')), findsNothing);
    },
  );

  testWidgets('emoji picker sheet has search filter for finding emojis', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-emoji-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('emoji-search-field')), findsOneWidget);
    expect(find.text('😀'), findsOneWidget);

    // Search for 'kot'
    await tester.enterText(find.byKey(const Key('emoji-search-field')), 'kot');
    await tester.pumpAndSettle();

    expect(find.text('🐱'), findsOneWidget);
    expect(find.text('😀'), findsNothing);

    // Select the cat emoji
    await tester.tap(find.text('🐱'));
    await tester.pumpAndSettle();

    // Field should have 🐱
    expect(find.text('🐱'), findsOneWidget);
  });

  testWidgets(
    'typing indicator is visible on conversation card and inside conversation screen',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                    isTyping: true,
                  ),
                },
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      // On conversation card
      expect(find.text('Pisze...'), findsOneWidget);

      // Open conversation screen
      await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
      await tester.pumpAndSettle();

      // In header and typing bubble
      expect(find.text('pisze...'), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-typing-bubble')),
        findsOneWidget,
      );
    },
  );

  testWidgets('camera button opens capture options bottom sheet', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-card-ada.ygg')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-camera-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('conversation-camera-button')));
    await tester.pumpAndSettle();

    expect(find.text('Zrób zdjęcie (Aparat)'), findsOneWidget);
    expect(find.text('Nagraj film (Wideo)'), findsOneWidget);
    expect(find.text('Wybierz z galerii'), findsOneWidget);
  });

  testWidgets('a request arriving while the code is on screen can be '
      'accepted right there', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ZenRewriteApp()));
    await tester.pump();
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );

    await tester.tap(find.byKey(const Key('status-my-code')));
    await tester.pumpAndSettle();
    expect(find.text('OTRZYMANO ZAPROSZENIE'), findsNothing);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendRequest,
            sender: 'kuba.ygg',
            displayName: 'Kuba',
            content: 'To ja z imprezy',
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('OTRZYMANO ZAPROSZENIE'), findsOneWidget);
    expect(find.textContaining('To ja z imprezy'), findsOneWidget);

    final Finder accept = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('qr-accept-'),
    );
    await tester.tap(accept);
    await tester.pumpAndSettle();

    // The side showing the code is asked about the meeting too.
    expect(find.text('Poznaliśmy się osobiście?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('met-level-skip')));
    await tester.pumpAndSettle();

    expect(
      container
          .read(socialHubControllerProvider)
          .friendByAddress('kuba.ygg')
          ?.status,
      FriendRelationshipStatus.accepted,
    );
    // Answered: the card goes, the code screen stays.
    expect(find.text('OTRZYMANO ZAPROSZENIE'), findsNothing);
    expect(find.text('Mój kod'), findsOneWidget);
  });
}

final class _FakeCallMediaSessionController extends CallMediaSessionController {
  String? acceptedIncomingCallId;
  String? acceptedRemoteAddress;
  String? startedOutgoingCallId;
  String? startedOutgoingRemoteAddress;
  bool mutedValue = false;
  bool speakerOnValue = false;
  bool cameraEnabledValue = true;
  String? activeCallIdValue;
  CallInviteKind? activeKindValue;
  CallMediaStatusListener? _onStatusChanged;
  CallMediaErrorListener? _onError;

  @override
  String? get activeCallId => activeCallIdValue;

  @override
  CallInviteKind? get activeKind => activeKindValue;

  @override
  bool get hasLocalStream => activeCallIdValue != null;

  @override
  bool get hasLocalVideo => cameraEnabledValue;

  @override
  bool get hasRemoteStream => activeCallIdValue != null;

  @override
  bool get hasRemoteVideo => activeKindValue == CallInviteKind.video;

  @override
  RTCVideoRenderer? get localRenderer => null;

  @override
  RTCVideoRenderer? get remoteRenderer => null;

  @override
  String? get remoteAddress => acceptedRemoteAddress;

  @override
  CallMediaStatusListener? get onStatusChanged => _onStatusChanged;

  @override
  set onStatusChanged(CallMediaStatusListener? value) {
    _onStatusChanged = value;
  }

  @override
  CallMediaErrorListener? get onError => _onError;

  @override
  set onError(CallMediaErrorListener? value) {
    _onError = value;
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    acceptedIncomingCallId = callId;
    acceptedRemoteAddress = remoteAddress;
    activeCallIdValue = callId;
    activeKindValue = kind;
    cameraEnabledValue = false;
    _onStatusChanged?.call(callId, CallMediaSessionLifecycle.active);
    notifyListeners();
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}

  @override
  Future<bool> resendLocalOffer(String callId) async {
    return false;
  }

  @override
  Future<bool> resendLocalAnswer(String callId) async {
    return false;
  }

  @override
  Future<void> close() async {
    activeCallIdValue = null;
    activeKindValue = null;
    notifyListeners();
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    activeKindValue = kind;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraEnabledValue = enabled;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    mutedValue = muted;
    notifyListeners();
  }

  @override
  Future<void> setSpeakerOn(bool enabled) async {
    speakerOnValue = enabled;
    notifyListeners();
  }

  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    startedOutgoingCallId = callId;
    startedOutgoingRemoteAddress = remoteAddress;
    activeCallIdValue = callId;
    acceptedRemoteAddress = remoteAddress;
    activeKindValue = kind;
    cameraEnabledValue = kind == CallInviteKind.video;
    notifyListeners();
  }
}

final class _FakeDeepLinkSource implements DeepLinkSource {
  final StreamController<Uri> _links = StreamController<Uri>.broadcast();
  Uri? initialLink;

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get linkStream => _links.stream;

  void emit(Uri uri) {
    _links.add(uri);
  }
}

/// A valid 1x1 GIF.
final Uint8List _tinyGif = Uint8List.fromList(const <int>[
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
  0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
  0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
]);

final class _FakeGifDownloader implements GifDownloader {
  @override
  Future<Uint8List> download(String url) async => _tinyGif;
}

final class _FakeGifCatalog implements GifCatalog {
  const _FakeGifCatalog(this.entries);

  final List<GifCatalogEntry> entries;

  @override
  Future<List<GifCatalogEntry>> loadFeatured() async => entries;

  @override
  Future<List<GifCatalogEntry>> search(String query) async => entries;
}

final class _BrokenGifCatalog implements GifCatalog {
  const _BrokenGifCatalog();

  @override
  Future<List<GifCatalogEntry>> loadFeatured() async =>
      throw const HttpException('401');

  @override
  Future<List<GifCatalogEntry>> search(String query) async =>
      throw const HttpException('401');
}

final class _FakeBiometricAuthenticator implements AppBiometricAuthenticator {
  const _FakeBiometricAuthenticator({
    required this.available,
    required this.shouldAuthenticate,
  });

  final bool available;
  final bool shouldAuthenticate;

  @override
  Future<bool> authenticate() async => shouldAuthenticate;

  @override
  Future<bool> isAvailable() async => available;
}

final class _FakePeerQrScanner implements PeerQrScanner {
  const _FakePeerQrScanner(this.result);

  final String? result;

  @override
  bool get isSupported => true;

  @override
  Future<String?> scan(BuildContext context) async => result;
}
