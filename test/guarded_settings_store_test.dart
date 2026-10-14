import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/guarded_settings_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

void main() {
  test('the protected settings win over an edited settings file', () async {
    final MemoryAppSettingsStore file = MemoryAppSettingsStore();
    final MemorySecurityCredentialsStore secrets =
        MemorySecurityCredentialsStore();
    final GuardedAppSettingsStore store = GuardedAppSettingsStore(
      inner: file,
      secrets: secrets,
    );
    await store.save(
      const AppSettings(
        lockMode: AppLockMode.background,
        backgroundLockDelaySeconds: 30,
        gifApiKey: 'mojKlucz123',
      ),
    );
    // The GIF key is not in the file.
    expect((await file.load())!.gifApiKey, isEmpty);

    // Someone who can write the file switches the protection off.
    await file.save(
      const AppSettings(
        lockMode: AppLockMode.never,
        secureScreens: false,
        hideNotificationContent: false,
        allowNoAppPassword: true,
        themeMode: AppThemeMode.dark,
      ),
    );

    final AppSettings loaded = (await store.load())!;
    expect(loaded.lockMode, AppLockMode.background);
    expect(loaded.backgroundLockDelaySeconds, 30);
    expect(loaded.secureScreens, isTrue);
    expect(loaded.hideNotificationContent, isTrue);
    expect(loaded.allowNoAppPassword, isFalse);
    expect(loaded.gifApiKey, 'mojKlucz123');
    // Everything else still comes from the file.
    expect(loaded.themeMode, AppThemeMode.dark);
  });

  test('a settings file put back to defaults keeps the protection', () async {
    final MemoryAppSettingsStore file = MemoryAppSettingsStore();
    final GuardedAppSettingsStore store = GuardedAppSettingsStore(
      inner: file,
      secrets: MemorySecurityCredentialsStore(),
    );
    expect(await store.load(), isNull, reason: 'a fresh install');
    await store.save(const AppSettings(lockMode: AppLockMode.appClose));
    await file.save(const AppSettings());
    final AppSettings loaded = (await store.load())!;
    expect(loaded.lockMode, AppLockMode.appClose);
  });

  test('an older settings file is adopted and its GIF key leaves the '
      'file', () async {
    final MemoryAppSettingsStore file = MemoryAppSettingsStore(
      const AppSettings(
        lockMode: AppLockMode.appClose,
        secureScreens: false,
        gifApiKey: 'staryKlucz',
      ),
    );
    final MemorySecurityCredentialsStore secrets =
        MemorySecurityCredentialsStore();
    final GuardedAppSettingsStore store = GuardedAppSettingsStore(
      inner: file,
      secrets: secrets,
    );

    final AppSettings loaded = (await store.load())!;
    // The user's own choices are kept as they were.
    expect(loaded.lockMode, AppLockMode.appClose);
    expect(loaded.secureScreens, isFalse);
    expect(loaded.gifApiKey, 'staryKlucz');
    expect(await secrets.read(appSecurityGifApiKeyStorageKey), 'staryKlucz');
    expect(await secrets.read(appSecurityGuardedSettingsStorageKey), isNotNull);

    // The next save takes the key out of the file.
    await store.save(loaded);
    expect((await file.load())!.gifApiKey, isEmpty);
    expect((await store.load())!.gifApiKey, 'staryKlucz');
  });

  test('secure storage failing never stops the settings', () async {
    final MemoryAppSettingsStore file = MemoryAppSettingsStore(
      const AppSettings(lockMode: AppLockMode.background),
    );
    final GuardedAppSettingsStore store = GuardedAppSettingsStore(
      inner: file,
      secrets: _BrokenSecrets(),
    );
    expect((await store.load())!.lockMode, AppLockMode.background);
    await store.save(const AppSettings(gifApiKey: 'klucz123'));
    expect((await file.load())!.gifApiKey, 'klucz123');
  });

  test('resetting the app forgets the protected settings', () async {
    final MemorySecurityCredentialsStore secrets =
        MemorySecurityCredentialsStore();
    final GuardedAppSettingsStore store = GuardedAppSettingsStore(
      inner: MemoryAppSettingsStore(),
      secrets: secrets,
    );
    await store.save(const AppSettings(gifApiKey: 'klucz123'));
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: secrets,
      passwordIterations: 10,
    );
    await security.initialize(settings: const AppSettings());
    await security.reset();
    expect(await secrets.read(appSecurityGifApiKeyStorageKey), isNull);
    expect(await secrets.read(appSecurityGuardedSettingsStorageKey), isNull);
  });
}

final class _BrokenSecrets implements AppSecurityCredentialsStore {
  @override
  Future<String?> read(String key) async => throw StateError('no storage');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no storage');

  @override
  Future<void> delete(String key) async => throw StateError('no storage');
}
