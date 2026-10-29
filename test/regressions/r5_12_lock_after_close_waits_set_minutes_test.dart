// Owner report R5-#12 (28.10.2026, after 1.14.0): the lock came at once after closing instead of after the set minutes.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed as the owner decided, by a setting off by default ("keep unlocked
// after close", resume_session.dart and app_security_service.dart,
// 5481e807); guarded by the tests below, test/app_resume_session_test.dart
// and test/app_security_gate_lock_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/resume_session.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String password = 'sekret12';
  // Locks five minutes after leaving the screen, also after a close.
  const AppSettings keepAfterClose = AppSettings(
    lockMode: AppLockMode.background,
    backgroundLockDelaySeconds: 300,
    keepUnlockedAfterClose: true,
  );

  late MemorySecurityCredentialsStore credentials;
  late int sinceBoot;
  late DateTime now;
  late Uint8List masterKey;

  LocalAppSecurityService build() => LocalAppSecurityService(
    credentialsStore: credentials,
    passwordIterations: 10,
    resumeVault: ClockResumeSessionVault(
      sinceBootMillis: () => sinceBoot,
      now: () => now,
      screenLock: () async => true,
    ),
  );

  void wait(Duration duration) {
    sinceBoot += duration.inMilliseconds;
    now = now.add(duration);
  }

  /// The app closed: its process is gone, and the next start is a new one.
  Future<LocalAppSecurityService> closeAndStart(
    LocalAppSecurityService running,
    Duration away, {
    AppSettings settings = keepAfterClose,
  }) async {
    await running.keepResumeSession();
    wait(away);
    final LocalAppSecurityService started = build();
    await started.initialize(settings: settings);
    return started;
  }

  setUp(() async {
    credentials = MemorySecurityCredentialsStore();
    sinceBoot = const Duration(hours: 3).inMilliseconds;
    now = DateTime.utc(2026, 10, 28, 12);
    final LocalAppSecurityService first = build();
    await first.initialize(settings: const AppSettings());
    masterKey = (await first.currentEncryptionKey())!;
    await first.setPassword(password);
  });

  Future<LocalAppSecurityService> unlocked(AppSettings settings) async {
    final LocalAppSecurityService service = build();
    await service.initialize(settings: settings);
    expect(await service.unlock(password), isTrue);
    await service.applySettings(settings);
    return service;
  }

  test(
    'R5-#12: after closing, the app locks only after the minutes set',
    () async {
      final LocalAppSecurityService again = await closeAndStart(
        await unlocked(keepAfterClose),
        const Duration(minutes: 4, seconds: 50),
      );
      expect(again.isLocked, isFalse);
      expect(await again.currentEncryptionKey(), masterKey);

      final LocalAppSecurityService afterDelay = await closeAndStart(
        again,
        const Duration(minutes: 5, seconds: 1),
      );
      expect(afterDelay.isLocked, isTrue);
      expect(await afterDelay.currentEncryptionKey(), isNull);
    },
  );

  test('R5-#12: the setting is off by default, and then a close locks at '
      'once', () async {
    const AppSettings byDefault = AppSettings(
      lockMode: AppLockMode.background,
      backgroundLockDelaySeconds: 300,
    );
    expect(byDefault.keepUnlockedAfterClose, isFalse);
    final LocalAppSecurityService again = await closeAndStart(
      await unlocked(byDefault),
      const Duration(seconds: 10),
      settings: byDefault,
    );
    expect(again.isLocked, isTrue);
  });
}
