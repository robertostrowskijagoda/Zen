import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/launcher_disguise.dart';

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

  Future<void> setPalette(AppPalette value) async {
    await _save(state.copyWith(palette: value));
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

  /// GIF search (klipy.com) on or off.
  Future<void> setGifSearch(bool value) async {
    await _save(state.copyWith(gifSearch: value));
  }

  Future<void> setHideNotificationContent(bool value) async {
    await _save(state.copyWith(hideNotificationContent: value));
  }

  Future<void> setInAppSounds(bool value) async {
    await _save(state.copyWith(inAppSounds: value));
  }

  Future<void> setSecureScreens(bool value) async {
    await _save(state.copyWith(secureScreens: value));
  }

  /// Android: switches the launcher icon and name and remembers the
  /// choice. Returns `false`, changing nothing, when the phone did not take
  /// the switch.
  Future<bool> setDisguiseIcon(bool value) async {
    if (!await ref.read(launcherDisguiseProvider).set(enabled: value)) {
      return false;
    }
    await _save(state.copyWith(disguiseIcon: value));
    return true;
  }

  Future<void> setAllowNoAppPassword(bool value) async {
    await _save(state.copyWith(allowNoAppPassword: value));
  }

  Future<void> setBridgeEnabled(bool value) async {
    await _save(state.copyWith(bridgeEnabled: value));
  }

  /// "Znajomi w tej samej sieci Wi-Fi"; the local links
  /// controller applies it to the running node.
  Future<void> setLanDiscovery(bool value) async {
    await _save(state.copyWith(lanDiscovery: value));
  }

  /// "Wi-Fi Direct (Android)".
  Future<void> setWifiDirect(bool value) async {
    await _save(state.copyWith(wifiDirect: value));
  }

  /// "Bluetooth".
  Future<void> setBluetoothLinks(bool value) async {
    await _save(state.copyWith(bluetoothLinks: value));
  }

  /// "Apple Wi-Fi/Bluetooth" (item 6, iPhone, iPad and Mac).
  Future<void> setMultipeerLinks(bool value) async {
    await _save(state.copyWith(multipeerLinks: value));
  }

  /// The first-start permissions step is done.
  Future<void> setPermissionsSetupDone(bool value) async {
    await _save(state.copyWith(permissionsSetupDone: value));
  }

  /// The first-start "Zabezpiecz konto" card was answered.
  Future<void> setAccountSecureOffered(bool value) async {
    await _save(state.copyWith(accountSecureOffered: value));
  }

  /// The paper copy of the account key was written down.
  Future<void> setPaperBackupDone(bool value) async {
    await _save(state.copyWith(paperBackupDone: value));
  }

  /// The terms, the privacy policy and the licence notice of [version]
  /// were accepted (on the first start, or again after they changed).
  Future<void> acceptLegalDocuments(String version, {DateTime? at}) async {
    await _save(
      state.copyWith(
        legalAcceptedVersion: version,
        legalAcceptedAtMillis: (at ?? DateTime.now()).millisecondsSinceEpoch,
      ),
    );
  }

  /// Who may invite this person to a new group.
  Future<void> setGroupInviteFrom(GroupInviteFrom value) async {
    await _save(state.copyWith(groupInviteFrom: value));
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
