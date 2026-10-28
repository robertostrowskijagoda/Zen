import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/launcher_disguise.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

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

  Future<void> setFeedLimitMb(int value) async {
    await _save(state.copyWith(feedLimitMb: value));
  }

  Future<void> setAutoCleanupDays(int value) async {
    await _save(state.copyWith(autoCleanupDays: value));
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

  Future<void> setAnimations(AppAnimations value) async {
    await _save(state.copyWith(animations: value));
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

  /// How much notifications tell, where a conversation has no level of
  /// its own.
  Future<void> setNotificationPrivacy(NotificationPrivacy value) async {
    await _save(state.copyWith(notificationPrivacy: value));
  }

  /// "Powiadomienia o nowych postach" on or off.
  Future<void> setPostNotifications(bool value) async {
    await _save(state.copyWith(postNotifications: value));
  }

  /// "Wycisz posty tej osoby": new posts of the friend at [address] are
  /// not announced while [muted].
  Future<void> setPostAuthorMuted(String address, {required bool muted}) async {
    final String normal = PeerShareCodec.normalizeAddress(address);
    if (normal.isEmpty || state.mutedPostAuthors.contains(normal) == muted) {
      return;
    }
    await _save(
      state.copyWith(
        mutedPostAuthors: muted
            ? <String>{...state.mutedPostAuthors, normal}
            : (Set<String>.of(state.mutedPostAuthors)..remove(normal)),
      ),
    );
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

  /// "Odbieraj w tle cały czas" (iPhone).
  Future<void> setKeepReceivingInBackground(bool value) async {
    await _save(state.copyWith(keepReceivingInBackground: value));
  }

  /// "Pokazuj, kiedy ostatnio otwierałem aplikację".
  Future<void> setShowLastOpened(bool value) async {
    await _save(state.copyWith(showLastOpened: value));
  }

  /// The setup (as of [kSetupRevision]) was gone through or skipped.
  ///
  /// Set only once it is on the disk: the gate leaves the setup as soon as
  /// the state says so, so a write that fails must leave the state as it
  /// was, for the setup to stay and say that it could not save.
  Future<void> setSetupDone() async {
    final AppSettings before = state;
    final AppSettings next = before.copyWith(setupRevision: kSetupRevision);
    await ref.read(appSettingsStoreProvider).save(next);
    if (!ref.mounted) {
      return;
    }
    if (!identical(state, before)) {
      // Something else was set meanwhile: saved again, with it.
      await _save(state.copyWith(setupRevision: kSetupRevision));
      return;
    }
    state = next;
    await ref.read(appSecurityServiceProvider).applySettings(next);
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

  /// The one-time card or reminder [id] was shown or dismissed.
  Future<void> markTipSeen(String id) async {
    if (state.seenTips.contains(id)) {
      return;
    }
    await _save(state.copyWith(seenTips: <String>{...state.seenTips, id}));
  }

  /// The notification list was opened with [millis] as its newest entry.
  Future<void> markNotificationsSeen(int millis) async {
    if (millis <= state.notificationsSeenMillis) {
      return;
    }
    await _save(state.copyWith(notificationsSeenMillis: millis));
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

  /// All the settings at once (the account's own devices keeping them the
  /// same).
  Future<void> restoreAll(AppSettings settings) => _save(settings);

  /// The settings of a copy of the account without the app's lock (the
  /// recovery circle, another device): the account's choices from it, this
  /// device's own as they are ([AppSettings.takingCopy]) — a setup gone
  /// through here is not asked again because of the copy.
  Future<void> restoreFromCopy(AppSettings copy) =>
      _save(state.takingCopy(copy));

  /// The settings of a backup of the whole app, as they were
  /// ([AppSettings.restoringWhole]). The disguised icon is switched on the
  /// launcher too; where the phone does not take it, it stays as it is here.
  Future<void> restoreWhole(AppSettings copy) async {
    AppSettings next = state.restoringWhole(copy);
    if (next.disguiseIcon != state.disguiseIcon &&
        !await ref
            .read(launcherDisguiseProvider)
            .set(enabled: next.disguiseIcon)) {
      next = next.copyWith(disguiseIcon: state.disguiseIcon);
    }
    await _save(next);
  }

  Future<void> _save(AppSettings next) async {
    state = next;
    await ref.read(appSettingsStoreProvider).save(next);
    await ref.read(appSecurityServiceProvider).applySettings(next);
  }
}
