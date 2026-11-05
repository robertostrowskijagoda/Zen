import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/launcher_disguise.dart';
import 'package:zen/src/features/settings/notice_kind.dart';

/// A launcher that takes the icon switch, or not.
final class _Disguise extends LauncherDisguise {
  const _Disguise({required this.takes});

  final bool takes;

  @override
  Future<bool> set({required bool enabled}) async => takes;
}

void main() {
  test(
    'controller hydrates persisted settings and saves normalized edits',
    () async {
      final MemoryAppSettingsStore store = MemoryAppSettingsStore(
        const AppSettings(
          inboxLimitMb: 80,
          autoCleanupDays: 9,
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
      expect(state.backgroundLockDelaySeconds, 3600);
      expect(state.lockMode, AppLockMode.appClose);
      expect(state.themeMode, AppThemeMode.light);

      final AppSettings? persisted = await store.load();
      expect(persisted, isNotNull);
      expect(persisted!.inboxLimitMb, 0);
      expect(persisted.autoCleanupDays, 0);
      expect(persisted.backgroundLockDelaySeconds, 3600);
      expect(persisted.lockMode, AppLockMode.appClose);
      expect(persisted.themeMode, AppThemeMode.light);
    },
  );

  test('the offline link choices are saved', () async {
    final MemoryAppSettingsStore store = MemoryAppSettingsStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [appSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    container.read(appSettingsControllerProvider);
    await Future<void>.delayed(Duration.zero);

    final AppSettingsController controller = container.read(
      appSettingsControllerProvider.notifier,
    );
    await controller.setLanDiscovery(false);
    await controller.setWifiDirect(true);
    await controller.setBluetoothLinks(true);
    await controller.setMultipeerLinks(true);

    expect(container.read(appSettingsControllerProvider).lanDiscovery, false);
    expect((await store.load())!.lanDiscoveryOn, isFalse);
    expect((await store.load())!.wifiDirect, isTrue);
    expect((await store.load())!.bluetoothLinks, isTrue);
    expect((await store.load())!.multipeerLinks, isTrue);

    await controller.setBluetoothLinks(false);
    expect((await store.load())!.bluetoothLinks, isFalse);
  });
  group('pinned by mutation testing', () {
    const String ola = '200:1111:2222:3333:4444:5555:6666:7777';

    Future<(ProviderContainer, AppSettingsController)> controller({
      bool disguiseTakes = true,
    }) async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(MemoryAppSettingsStore()),
          launcherDisguiseProvider.overrideWithValue(
            _Disguise(takes: disguiseTakes),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(appSettingsControllerProvider);
      await Future<void>.delayed(Duration.zero);
      return (
        container,
        container.read(appSettingsControllerProvider.notifier),
      );
    }

    test("a friend's posts muted and unmuted, by the address in any "
        'spelling; no empty one', () async {
      final (ProviderContainer c, AppSettingsController settings) =
          await controller();
      await settings.setPostAuthorMuted(ola.toUpperCase(), muted: true);
      expect(c.read(appSettingsControllerProvider).mutedPostAuthors, <String>{
        ola.toUpperCase(),
      });
      await settings.setPostAuthorMuted('', muted: true);
      expect(
        c.read(appSettingsControllerProvider).mutedPostAuthors,
        hasLength(1),
      );
      await settings.setPostAuthorMuted(ola, muted: false);
      expect(c.read(appSettingsControllerProvider).mutedPostAuthors, isEmpty);
    });

    test("friends' posts are muted by their own switch, other kinds in the "
        'list', () async {
      final (ProviderContainer c, AppSettingsController settings) =
          await controller();
      await settings.setNoticeMuted(NoticeKind.friendPost, muted: true);
      expect(c.read(appSettingsControllerProvider).postNotifications, isFalse);
      expect(c.read(appSettingsControllerProvider).mutedNotices, isEmpty);
      await settings.setNoticeMuted(NoticeKind.reaction, muted: true);
      expect(c.read(appSettingsControllerProvider).mutedNotices, <NoticeKind>{
        NoticeKind.reaction,
      });
      await settings.setNoticeMuted(NoticeKind.friendPost, muted: false);
      expect(c.read(appSettingsControllerProvider).postNotifications, isTrue);
    });

    test("a kind's own level is set and given back; a kind without one "
        'takes none', () async {
      final (ProviderContainer c, AppSettingsController settings) =
          await controller();
      await settings.setNoticePrivacy(
        NoticeKind.message,
        NotificationPrivacy.generic,
      );
      expect(
        c.read(appSettingsControllerProvider).noticePrivacy[NoticeKind.message],
        NotificationPrivacy.generic,
      );
      await settings.setNoticePrivacy(
        NoticeKind.update,
        NotificationPrivacy.generic,
      );
      expect(
        c.read(appSettingsControllerProvider).noticePrivacy,
        isNot(contains(NoticeKind.update)),
      );
      await settings.setNoticePrivacy(NoticeKind.message, null);
      expect(c.read(appSettingsControllerProvider).noticePrivacy, isEmpty);
    });

    test(
      'the icon disguise is remembered only once the launcher took it',
      () async {
        final (ProviderContainer refused, AppSettingsController no) =
            await controller(disguiseTakes: false);
        expect(await no.setDisguiseIcon(true), isFalse);
        expect(
          refused.read(appSettingsControllerProvider).disguiseIcon,
          isFalse,
        );
        final (ProviderContainer took, AppSettingsController yes) =
            await controller();
        expect(await yes.setDisguiseIcon(true), isTrue);
        expect(took.read(appSettingsControllerProvider).disguiseIcon, isTrue);
      },
    );

    test(
      'the notification list is seen up to its newest entry, never back',
      () async {
        final (ProviderContainer c, AppSettingsController settings) =
            await controller();
        await settings.markNotificationsSeen(500);
        await settings.markNotificationsSeen(300);
        expect(
          c.read(appSettingsControllerProvider).notificationsSeenMillis,
          500,
        );
        await settings.markNotificationsSeen(800);
        expect(
          c.read(appSettingsControllerProvider).notificationsSeenMillis,
          800,
        );
      },
    );
  });
}
