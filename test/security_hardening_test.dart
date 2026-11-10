import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/device_integrity.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  test('one confirmation opens sensitive places for a minute', () {
    DateTime now = DateTime(2026, 1, 1, 12);
    final SensitiveAccessClock clock = SensitiveAccessClock(now: () => now);
    expect(clock.isFresh, isFalse);
    clock.confirmed();
    expect(clock.isFresh, isTrue);
    now = now.add(const Duration(seconds: 59));
    expect(clock.isFresh, isTrue);
    now = now.add(const Duration(seconds: 2));
    expect(clock.isFresh, isFalse);
    clock
      ..confirmed()
      ..forget();
    expect(clock.isFresh, isFalse);
  });

  test('locking the app forgets the confirmation', () async {
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      passwordIterations: 10,
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('sekret123');
    final ProviderContainer container = ProviderContainer(
      overrides: [appSecurityServiceProvider.overrideWithValue(security)],
    );
    addTearDown(container.dispose);
    final SensitiveAccessClock clock = container.read(
      sensitiveAccessClockProvider,
    )..confirmed();
    expect(clock.isFresh, isTrue);
    security.lock();
    expect(clock.isFresh, isFalse);
  });

  testWidgets('sensitive places ask for the app password', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      passwordIterations: 10,
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('sekret123');
    final List<bool> results = <bool>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSecurityServiceProvider.overrideWithValue(security)],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async => results.add(
                await confirmSensitiveAccess(context, reason: 'Sprawdzam'),
              ),
              child: const Text('otwórz'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('otwórz'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sensitive-access-dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('sensitive-access-password')),
      'zle-haslo',
    );
    await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('sensitive-access-password')),
      'sekret123',
    );
    await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
    await tester.pumpAndSettle();
    expect(results, <bool>[true]);

    // Within the grace period: no second question.
    await tester.tap(find.text('otwórz'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
    expect(results, <bool>[true, true]);
  });

  testWidgets('wrong passwords at a sensitive place count with the lock '
      'screen, and during the wait even the right one is not tried', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      passwordIterations: 10,
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('sekret123');
    Duration steady = Duration.zero;
    final UnlockThrottle throttle = UnlockThrottle(
      security.credentialsStore,
      monotonic: () => steady,
    );
    final List<bool> results = <bool>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSecurityServiceProvider.overrideWithValue(security),
          unlockThrottleProvider.overrideWithValue(throttle),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async => results.add(
                await confirmSensitiveAccess(context, reason: 'Sprawdzam'),
              ),
              child: const Text('otwórz'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('otwórz'));
    await tester.pumpAndSettle();
    Future<void> attempt(String password) async {
      await tester.enterText(
        find.byKey(const Key('sensitive-access-password')),
        password,
      );
      await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
      await tester.pumpAndSettle();
    }

    for (int i = 0; i < UnlockThrottle.freeFailures; i++) {
      await attempt('zle-haslo-$i');
    }
    // The fifth wrong one started the lock screen's wait, in its words.
    expect(
      await security.credentialsStore.read(appSecurityUnlockFailuresStorageKey),
      startsWith('5;'),
    );
    expect(
      find.text('Za dużo błędnych prób. Spróbuj ponownie za 0:30.'),
      findsOneWidget,
    );
    await attempt('sekret123');
    expect(results, isEmpty);
    expect(find.textContaining('Za dużo błędnych prób.'), findsOneWidget);
    expect(
      await security.credentialsStore.read(appSecurityUnlockFailuresStorageKey),
      startsWith('5;'),
    );

    // After the wait the right one opens and clears the count.
    steady += const Duration(seconds: 31);
    await attempt('sekret123');
    expect(results, <bool>[true]);
    expect(
      await security.credentialsStore.read(appSecurityUnlockFailuresStorageKey),
      isNull,
    );
  });

  testWidgets('wrong account passwords count with the lock screen too; a '
      'right one clears nothing', (WidgetTester tester) async {
    final MemorySecurityCredentialsStore store =
        MemorySecurityCredentialsStore();
    final UnlockThrottle throttle = UnlockThrottle(
      store,
      monotonic: () => Duration.zero,
    );
    late BuildContext context;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [unlockThrottleProvider.overrideWithValue(throttle)],
        child: Builder(
          builder: (BuildContext c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    int tried = 0;
    Future<bool> wrong() async {
      tried++;
      return false;
    }

    expect(await tryAccountPassword(context, wrong), 'Złe hasło konta.');
    expect(await tryAccountPassword(context, () async => true), isNull);
    expect(await store.read(appSecurityUnlockFailuresStorageKey), '1;0');
    for (int i = 1; i < UnlockThrottle.freeFailures; i++) {
      await tryAccountPassword(context, wrong);
    }
    expect(tried, UnlockThrottle.freeFailures);
    final String? waiting = await tryAccountPassword(context, () async => true);
    expect(waiting, 'Za dużo błędnych prób. Spróbuj ponownie za 0:30.');
  });

  testWidgets('biometrics confirm when the key is sealed in hardware', (
    WidgetTester tester,
  ) async {
    final MemoryKeyVault vault = MemoryKeyVault();
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      keyVault: vault,
      passwordIterations: 10,
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('sekret123');
    // Biometric unlock is off until the person turns it on.
    await security.setBiometricUnlockEnabled(true);
    final List<bool> results = <bool>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSecurityServiceProvider.overrideWithValue(security)],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async => results.add(
                await confirmSensitiveAccess(context, reason: 'Sprawdzam'),
              ),
              child: const Text('otwórz'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('otwórz'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
    expect(results, <bool>[true]);
    expect(vault.prompts, 1);
  });

  test('integrity answers are read and described', () {
    final DeviceIntegrity rooted = DeviceIntegrity.fromMap(<Object?, Object?>{
      'rooted': true,
      'reasons': <Object?>['su', 'app:com.topjohnwu.magisk', 'frida', 7],
      'debuggable': false,
    });
    expect(rooted.hasWarning, isTrue);
    expect(rooted.reasons, hasLength(3));
    expect(rooted.describe().first, contains('su'));
    expect(rooted.describe()[1], contains('com.topjohnwu.magisk'));
    expect(
      DeviceIntegrity.fromMap(const <Object?, Object?>{}).hasWarning,
      isFalse,
    );
    expect(DeviceIntegrity.clean.hasWarning, isFalse);
  });

  test('a missing native side means a clean device', () async {
    expect((await checkDeviceIntegrity()).hasWarning, isFalse);
  });

  test('the channel vault is quiet without its native side', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final ChannelKeyVault vault = ChannelKeyVault(
      channel: const MethodChannel('zen/keyvault-test'),
    );
    expect(await vault.isAvailable(), isFalse);
    expect(await vault.describe(), 'brak');
    expect(await vault.seal(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  testWidgets('a screen with private content never blocks captures', (
    WidgetTester tester,
  ) async {
    SecureWindow.lastApplied = false;
    await tester.pumpWidget(
      const MaterialApp(
        home: SecureScreen(child: SecureScreen(child: Text('tajne'))),
      ),
    );
    await tester.pump();
    expect(SecureWindow.lastApplied, isFalse);
    expect(find.text('tajne'), findsOneWidget);
  });

  testWidgets('while a screen with private content protects nothing, no '
      'document says it does', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SecureScreen(child: Text('tajne'))),
    );
    expect(SecureWindow.lastApplied, isFalse);

    String normal(String text) =>
        text.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    final List<File> documents = <File>[
      File('README.md'),
      File('docs/SECURITY_MODEL.md'),
      File('docs/PRIVACY.md'),
      File('docs/TERMS.md'),
      ...Directory(
        'docs/guide',
      ).listSync().whereType<File>().where((File f) => f.path.endsWith('.md')),
    ];
    const List<String> claims = <String>[
      'protected from screenshots',
      'protected from screen recording',
      'blocking screenshots',
      'blocks screenshots',
      'out of screenshots',
      'out of the recent apps',
      'no screenshots',
      'chronione przed zrzutami',
      'blokuje zrzuty',
      'blokowanie zrzutów',
    ];
    for (final File document in documents) {
      final String text = normal(document.readAsStringSync());
      for (final String claim in claims) {
        expect(text, isNot(contains(claim)), reason: document.path);
      }
    }
    // What is true is said where the device's protection is described.
    final String model = normal(
      File('docs/SECURITY_MODEL.md').readAsStringSync(),
    );
    expect(model, contains('does not block screenshots'));
    expect(model, contains('recent-apps preview'));
  });
}
