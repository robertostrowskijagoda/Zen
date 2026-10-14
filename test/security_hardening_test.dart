import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/device_integrity.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
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

  testWidgets('secure screens hold capture protection while shown', (
    WidgetTester tester,
  ) async {
    SecureWindow.lastApplied = false;
    final ValueNotifier<bool> show = ValueNotifier<bool>(true);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (BuildContext context, bool on, Widget? _) => on
                ? const SecureScreen(child: SecureScreen(child: Text('tajne')))
                : const Text('jawne'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(SecureWindow.lastApplied, isTrue);
    show.value = false;
    await tester.pump();
    expect(SecureWindow.lastApplied, isFalse);
  });
}
