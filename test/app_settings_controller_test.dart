import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

void main() {
  test(
    'controller hydrates persisted settings and saves normalized edits',
    () async {
      final MemoryAppSettingsStore store = MemoryAppSettingsStore(
        const AppSettings(
          inboxLimitMb: 80,
          autoCleanupDays: 9,
          notificationDelaySeconds: 6,
          encryptionEnabled: true,
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 9,
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [appSettingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      container.read(appSettingsControllerProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(appSettingsControllerProvider).inboxLimitMb, 80);
      expect(container.read(appSettingsControllerProvider).autoCleanupDays, 9);
      expect(
        container.read(appSettingsControllerProvider).notificationDelaySeconds,
        6,
      );
      expect(
        container.read(appSettingsControllerProvider).encryptionEnabled,
        isTrue,
      );
      expect(
        container.read(appSettingsControllerProvider).lockMode,
        AppLockMode.background,
      );
      expect(
        container
            .read(appSettingsControllerProvider)
            .backgroundLockDelaySeconds,
        9,
      );
      expect(
        container.read(appSettingsControllerProvider).themeMode,
        AppSettings.defaultThemeMode,
      );

      await container
          .read(appSettingsControllerProvider.notifier)
          .setInboxUnlimited(true);
      await container
          .read(appSettingsControllerProvider.notifier)
          .setAutoCleanupDays(-20);
      await container
          .read(appSettingsControllerProvider.notifier)
          .setNotificationDelaySeconds(99);
      await container
          .read(appSettingsControllerProvider.notifier)
          .setBackgroundLockDelaySeconds(99999);
      await container
          .read(appSettingsControllerProvider.notifier)
          .setLockMode(AppLockMode.appClose);
      await container
          .read(appSettingsControllerProvider.notifier)
          .setThemeMode(AppThemeMode.light);

      final AppSettings state = container.read(appSettingsControllerProvider);
      expect(state.inboxLimitMb, 0);
      expect(state.autoCleanupDays, 0);
      expect(state.notificationDelaySeconds, 10);
      expect(state.backgroundLockDelaySeconds, 3600);
      expect(state.lockMode, AppLockMode.appClose);
      expect(state.themeMode, AppThemeMode.light);

      final AppSettings? persisted = await store.load();
      expect(persisted, isNotNull);
      expect(persisted!.inboxLimitMb, 0);
      expect(persisted.autoCleanupDays, 0);
      expect(persisted.notificationDelaySeconds, 10);
      expect(persisted.backgroundLockDelaySeconds, 3600);
      expect(persisted.lockMode, AppLockMode.appClose);
      expect(persisted.themeMode, AppThemeMode.light);
    },
  );

  test('the LAN discovery choice is saved', () async {
    final MemoryAppSettingsStore store = MemoryAppSettingsStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [appSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    container.read(appSettingsControllerProvider);
    await Future<void>.delayed(Duration.zero);

    // The preview runtime (no node) is not restarted.
    await container
        .read(appSettingsControllerProvider.notifier)
        .setLanDiscovery(false);

    expect(container.read(appSettingsControllerProvider).lanDiscovery, false);
    expect((await store.load())!.lanDiscoveryOn(phone: false), isFalse);
  });
}
