import 'dart:convert';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

/// The settings file is read before the app is unlocked (the lock mode
/// decides how the app starts), so it cannot be sealed with the data key.
/// This keeps what protects the user out of reach of whoever can write
/// that file:
///
/// * the lock mode and its delay, screenshot blocking, hidden notification
///   content and the "no password" consent are also kept in secure storage
///   (Android Keystore / Windows credential storage) and that copy wins
///   over the file;
/// * the user's own GIF API key lives only in secure storage.
///
/// Secure storage failing never stops the app: the file is used as before.
final class GuardedAppSettingsStore implements AppSettingsStore {
  GuardedAppSettingsStore({
    required this.inner,
    AppSecurityCredentialsStore secrets = const SecureStorageCredentialsStore(),
  }) : _secrets = secrets;

  /// The settings file.
  final AppSettingsStore inner;
  final AppSecurityCredentialsStore _secrets;

  static const int _version = 1;

  static String _encode(AppSettings settings) => jsonEncode(<String, Object>{
    'v': _version,
    'lock': settings.lockMode.name,
    'delay': settings.backgroundLockDelaySeconds,
    'secure': settings.secureScreens,
    'hide': settings.hideNotificationContent,
    'noPassword': settings.allowNoAppPassword,
  });

  /// [settings] with the protected fields of [encoded] (each one only when
  /// it is readable).
  static AppSettings? _apply(AppSettings settings, String? encoded) {
    if (encoded == null) {
      return null;
    }
    final Object? json;
    try {
      json = jsonDecode(encoded);
    } on FormatException {
      return null;
    }
    if (json is! Map || json['v'] != _version) {
      return null;
    }
    AppLockMode? lockMode;
    for (final AppLockMode mode in AppLockMode.values) {
      if (mode.name == json['lock']) {
        lockMode = mode;
      }
    }
    final Object? delay = json['delay'];
    final Object? secure = json['secure'];
    final Object? hide = json['hide'];
    final Object? noPassword = json['noPassword'];
    return settings.copyWith(
      lockMode: lockMode,
      backgroundLockDelaySeconds: delay is int ? delay : null,
      secureScreens: secure is bool ? secure : null,
      hideNotificationContent: hide is bool ? hide : null,
      allowNoAppPassword: noPassword is bool ? noPassword : null,
    );
  }

  @override
  Future<AppSettings?> load() async {
    final AppSettings? fromFile = await inner.load();
    try {
      final String? guarded = await _secrets.read(
        appSecurityGuardedSettingsStorageKey,
      );
      final String? gifKey = await _secrets.read(
        appSecurityGifApiKeyStorageKey,
      );
      if (fromFile == null) {
        // No file (deleted?): what was protected still holds.
        final AppSettings? kept = _apply(const AppSettings(), guarded);
        if (kept == null) {
          return null;
        }
        return gifKey == null ? kept : kept.copyWith(gifApiKey: gifKey);
      }
      AppSettings settings = fromFile;
      final AppSettings? guardedSettings = _apply(fromFile, guarded);
      if (guardedSettings == null) {
        // First start with the guard: remember what the file says.
        await _secrets.write(
          appSecurityGuardedSettingsStorageKey,
          _encode(fromFile),
        );
      } else {
        if (_encode(guardedSettings) != _encode(fromFile)) {
          logZenWarning(
            'The settings file differs from its protected copy; '
            'the protected one is used.',
          );
        }
        settings = guardedSettings;
      }
      return gifKey == null ? settings : settings.copyWith(gifApiKey: gifKey);
    } on Object catch (error, stackTrace) {
      logZenError('Reading the protected settings failed', error, stackTrace);
      return fromFile;
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    bool keyStored = false;
    try {
      await _secrets.write(
        appSecurityGuardedSettingsStorageKey,
        _encode(settings),
      );
      if (settings.gifApiKey.isEmpty) {
        await _secrets.delete(appSecurityGifApiKeyStorageKey);
      } else {
        await _secrets.write(
          appSecurityGifApiKeyStorageKey,
          settings.gifApiKey,
        );
      }
      keyStored = true;
    } on Object catch (error, stackTrace) {
      logZenError('Saving the protected settings failed', error, stackTrace);
      try {
        // A stale protected copy must not win over this save later.
        await _secrets.delete(appSecurityGuardedSettingsStorageKey);
      } on Object catch (deleteError, deleteStack) {
        logZenError(
          'Dropping the protected settings failed',
          deleteError,
          deleteStack,
        );
      }
    }
    await inner.save(keyStored ? settings.copyWith(gifApiKey: '') : settings);
  }
}
