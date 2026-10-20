import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

final Provider<AppSettings> appSettingsInitialStateProvider =
    Provider<AppSettings>((Ref ref) {
      return const AppSettings();
    });

final Provider<bool> appSettingsHydrationEnabledProvider = Provider<bool>((
  Ref ref,
) {
  return true;
});

final Provider<AppSettingsStore> appSettingsStoreProvider =
    Provider<AppSettingsStore>((Ref ref) {
      return MemoryAppSettingsStore();
    });

final NotifierProvider<AppSettingsController, AppSettings>
appSettingsControllerProvider =
    NotifierProvider<AppSettingsController, AppSettings>(
      AppSettingsController.new,
    );

List buildAppSettingsProviderOverrides({
  required AppSettingsStore store,
  AppSettings initialState = const AppSettings(),
  bool hydrationEnabled = true,
}) {
  return [
    appSettingsStoreProvider.overrideWithValue(store),
    appSettingsInitialStateProvider.overrideWithValue(initialState),
    appSettingsHydrationEnabledProvider.overrideWithValue(hydrationEnabled),
  ];
}

final class AppSettingsController extends Notifier<AppSettings> {
  bool _hydrationScheduled = false;

  @override
  AppSettings build() {
    if (!_hydrationScheduled && ref.read(appSettingsHydrationEnabledProvider)) {
      _hydrationScheduled = true;
      // Nothing awaits this, so an error would escape as an unhandled async
      // error instead of a log line.
      unawaitedLogged(
        Future<void>.microtask(_hydrate),
        context: 'Hydrating the app settings failed',
      );
    }
    return ref.read(appSettingsInitialStateProvider);
  }

  Future<void> _hydrate() async {
    // The microtask can be picked up after the container was torn down.
    if (!ref.mounted) {
      return;
    }
    final AppSettings? persisted = await ref
        .read(appSettingsStoreProvider)
        .load();
    if (!ref.mounted) {
      return;
    }
    final AppSettings next = persisted ?? const AppSettings();
    await ref.read(appSecurityServiceProvider).applySettings(next);
    if (persisted != null) {
      state = persisted;
    }
  }

  Future<void> setInboxUnlimited(bool value) async {
    final int limit = value
        ? 0
        : (state.inboxLimitMb > 0
              ? state.inboxLimitMb
              : AppSettings.defaultInboxLimitMb);
    await _save(state.copyWith(inboxLimitMb: limit));
  }

  Future<void> setInboxLimitMb(int value) async {
    await _save(state.copyWith(inboxLimitMb: value));
  }

  Future<void> setAutoCleanupDays(int value) async {
    await _save(state.copyWith(autoCleanupDays: value));
  }

  Future<void> setNotificationDelaySeconds(int value) async {
    await _save(state.copyWith(notificationDelaySeconds: value));
  }

  Future<void> setThemeMode(AppThemeMode value) async {
    await _save(state.copyWith(themeMode: value));
  }

  Future<void> setAccentTheme(AppAccentTheme value) async {
    await _save(state.copyWith(accentTheme: value));
  }

  Future<void> setLockMode(AppLockMode value) async {
    await _save(state.copyWith(lockMode: value));
  }

  Future<void> setBackgroundLockDelaySeconds(int value) async {
    await _save(state.copyWith(backgroundLockDelaySeconds: value));
  }

  /// Uses [key] for GIFs from now on; an empty key goes back to the shared
  /// app key.
  Future<void> setGifApiKey(String key) async {
    await _save(state.copyWith(gifApiKey: key));
  }

  Future<void> setHideNotificationContent(bool value) async {
    await _save(state.copyWith(hideNotificationContent: value));
  }

  Future<void> setSecureScreens(bool value) async {
    await _save(state.copyWith(secureScreens: value));
  }

  Future<void> setAllowNoAppPassword(bool value) async {
    await _save(state.copyWith(allowNoAppPassword: value));
  }

  Future<void> setBridgeEnabled(bool value) async {
    await _save(state.copyWith(bridgeEnabled: value));
  }

  /// The first-start permissions step is done (§25.2).
  Future<void> setPermissionsSetupDone(bool value) async {
    await _save(state.copyWith(permissionsSetupDone: value));
  }

  /// The first-start "Zabezpiecz konto" card was answered (§6.3).
  Future<void> setAccountSecureOffered(bool value) async {
    await _save(state.copyWith(accountSecureOffered: value));
  }

  /// The paper copy of the account key was written down (§6.1).
  Future<void> setPaperBackupDone(bool value) async {
    await _save(state.copyWith(paperBackupDone: value));
  }

  /// Who may invite this person to a new group (§8).
  Future<void> setGroupInviteFrom(GroupInviteFrom value) async {
    await _save(state.copyWith(groupInviteFrom: value));
  }

  /// The age gate's answer (§26.1, §27): a date of birth, or only the
  /// 18+ confirmation ([birth] `null`). Kept on this device only.
  Future<void> setAgeGate({DateTime? birth, bool adult = false}) async {
    await _save(
      state.copyWith(
        birthDateMillis: birth == null
            ? 0
            : DateTime(
                birth.year,
                birth.month,
                birth.day,
              ).millisecondsSinceEpoch,
        adultConfirmed: birth == null && adult,
      ),
    );
  }

  Future<void> setAutoDownloadMedia(bool value) async {
    await _save(state.copyWith(autoDownloadMedia: value));
  }

  Future<void> setMediaOnlyOnWifi(bool value) async {
    await _save(state.copyWith(mediaOnlyOnWifi: value));
  }

  Future<void> reset() async {
    await _save(const AppSettings());
  }

  Future<void> _save(AppSettings next) async {
    state = next;
    await ref.read(appSettingsStoreProvider).save(next);
    await ref.read(appSecurityServiceProvider).applySettings(next);
  }
}
