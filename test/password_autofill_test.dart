import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_autofill_host.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_screen.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

// Filling another app's login form (Android's autofill): the request waits
// for the app password, the picker lists only the entries saved for that
// app or page, every other entry only past a warning, and the Android side
// gets exactly the entry tapped - or nothing, when the picker is closed,
// the password is wrong, or Zen locks.

const MethodChannel _channel = MethodChannel(
  PasswordAutofillBridge.channelName,
);

const PasswordFields _bankApp = PasswordFields(
  name: 'Bank',
  login: 'ania',
  password: 'bank-haslo',
  address: 'android-app://com.bank.app',
);

const PasswordFields _shop = PasswordFields(
  name: 'Sklep',
  login: 'ola',
  password: 'sklep-haslo',
  address: 'https://login.example.com/',
);

const PasswordFields _other = PasswordFields(
  name: 'Inna strona',
  login: 'ktos',
  password: 'inne-haslo',
  address: 'https://other.org',
);

/// The Android side of `zen/autofill`: the open request, and every call.
final class _Android {
  _Android(this.pending);

  Map<String, Object?>? pending;
  final List<MethodCall> calls = <MethodCall>[];
  PasswordAutofillState state = PasswordAutofillState.off;

  /// The open request ends (its time ran out) once it was asked for this
  /// many more times.
  int? endsAfterAsked;

  List<MethodCall> named(String method) =>
      calls.where((MethodCall c) => c.method == method).toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'pending':
        final Map<String, Object?>? open = pending;
        final int? left = endsAfterAsked;
        if (left != null) {
          endsAfterAsked = left - 1;
          if (left <= 1) {
            pending = null;
            endsAfterAsked = null;
          }
        }
        return open;
      case 'fill':
      case 'cancel':
        final bool open =
            pending != null &&
            (call.arguments as Map<Object?, Object?>)['id'] == pending!['id'];
        pending = null;
        return open;
      case 'status':
        return <String, bool>{
          'supported': state != PasswordAutofillState.unsupported,
          'enabled': state == PasswordAutofillState.on,
        };
      case 'guard':
      case 'openSettings':
        return true;
    }
    return null;
  }
}

Map<String, Object?> _appRequest() => <String, Object?>{
  'id': 'r1',
  'package': 'com.bank.app',
  'label': 'Mój Bank',
  'username': true,
};

Map<String, Object?> _webRequest() => <String, Object?>{
  'id': 'r2',
  'package': 'com.android.chrome',
  'label': 'Chrome',
  'webDomain': 'example.com',
  'webScheme': 'https',
  'username': true,
};

PasswordVaultService _vault(AppSecurityService security) {
  int t = 1760000000000;
  return PasswordVaultService(
    disk: MemoryLedgerDisk(),
    now: () => t += 60000,
    random: Random(3),
    isLocked: () => security.isLocked,
    copy: (String _) async => true,
  );
}

Future<MemoryAppSecurityService> _withPassword() async {
  final MemoryAppSecurityService security = MemoryAppSecurityService(
    passwordIterations: 10,
  );
  await security.setPassword('sekret12');
  return security;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

_Android _android(Map<String, Object?>? pending) {
  final _Android android = _Android(pending);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, android.handle);
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
  return android;
}

/// The Android side says a request opened or ended.
Future<void> _changed(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    PasswordAutofillBridge.channelName,
    const StandardMethodCodec().encodeMethodCall(const MethodCall('changed')),
    (ByteData? _) {},
  );
  await _frames(tester);
}

Future<void> _pump(
  WidgetTester tester, {
  required PasswordVaultService vault,
  required AppSecurityService security,
  PasswordAutofillBridge? bridge,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        passwordVaultServiceProvider.overrideWithValue(vault),
        appSecurityServiceProvider.overrideWithValue(security),
        passwordAutofillBridgeProvider.overrideWithValue(
          bridge ?? PasswordAutofillBridge(supported: true),
        ),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        home: PasswordAutofillHost(
          child: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: TextButton(
                  key: const Key('open-vault'),
                  onPressed: () => unawaited(PasswordVaultScreen.open(context)),
                  child: const Text('home'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
}

Future<void> _confirm(WidgetTester tester, String password) async {
  await tester.enterText(
    find.byKey(const Key('sensitive-access-password')),
    password,
  );
  await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
  await _frames(tester);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _frames(tester);
}

final Finder _picker = find.byKey(const Key('autofill-screen'));
final Finder _question = find.byKey(const Key('sensitive-access-dialog'));

/// The app as it runs: the lock screen ([AppSecurityGate]) over the host.
/// [wipe] stands in for erasing the device (the emergency wipe password).
Future<void> _pumpGated(
  WidgetTester tester, {
  required PasswordVaultService vault,
  required AppSecurityService security,
  Future<void> Function(WidgetRef ref)? wipe,
}) async {
  tester.view.physicalSize = const Size(700, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsStoreProvider.overrideWithValue(
          MemoryAppSettingsStore(const AppSettings()),
        ),
        appSecurityServiceProvider.overrideWithValue(security),
        otherAccountThrottleProvider.overrideWithValue(
          UnlockThrottle.otherAccounts(store: MemorySecurityCredentialsStore()),
        ),
        passwordVaultServiceProvider.overrideWithValue(vault),
        passwordAutofillBridgeProvider.overrideWithValue(
          PasswordAutofillBridge(supported: true),
        ),
        if (wipe != null) zenLocalDataResetProvider.overrideWithValue(wipe),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        builder: (BuildContext context, Widget? child) =>
            AppSecurityGate(child: child!),
        home: PasswordAutofillHost(
          child: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: TextButton(
                  key: const Key('open-vault'),
                  onPressed: () => unawaited(PasswordVaultScreen.open(context)),
                  child: const Text('home'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
}

/// A password typed on the lock screen.
Future<void> _unlockWith(WidgetTester tester, String password) async {
  await tester.enterText(
    find.byKey(const Key('app-unlock-password-field')),
    password,
  );
  await tester.tap(find.byKey(const Key('app-unlock-submit-button')));
  await _frames(tester);
}

AutofillUnlockPass _passOf(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(MaterialApp)),
).read(autofillUnlockPassProvider);

final Finder _lockScreen = find.byKey(const Key('app-unlock-password-field'));

void main() {
  testWidgets('an app\'s request: the app password first, then only the '
      'entry saved for that app; the one tapped goes over, exactly', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    final PasswordEntry bank = await vault.add(_bankApp);
    final PasswordEntry shop = await vault.add(_shop);
    final PasswordEntry other = await vault.add(_other);
    final _Android android = _android(_appRequest());
    await _pump(tester, vault: vault, security: security);

    // Asked who it is before anything of the vault shows.
    expect(find.byKey(const Key('sensitive-access-dialog')), findsOneWidget);
    expect(_picker, findsNothing);
    await _confirm(tester, 'sekret12');

    expect(_picker, findsOneWidget);
    expect(find.byKey(const Key('autofill-requester-name')), findsOneWidget);
    expect(find.text('Mój Bank'), findsOneWidget);
    // The package is always there: the name is the app's own say.
    expect(find.text('com.bank.app'), findsOneWidget);
    expect(find.byKey(Key('autofill-row-${bank.id}')), findsOneWidget);
    expect(find.byKey(Key('autofill-row-${shop.id}')), findsNothing);
    expect(find.byKey(Key('autofill-row-${other.id}')), findsNothing);
    // No password on the screen.
    expect(find.textContaining('haslo'), findsNothing);
    // Touches through other apps' windows are dropped while it is up.
    expect(android.named('guard').map((MethodCall c) => c.arguments), <Object?>[
      <Object?, Object?>{'on': true},
    ]);
    expect(android.named('fill'), isEmpty);

    await _tap(tester, 'autofill-row-${bank.id}');
    expect(_picker, findsNothing);
    final List<MethodCall> fills = android.named('fill');
    expect(fills, hasLength(1));
    expect(fills.single.arguments, <Object?, Object?>{
      'id': 'r1',
      'login': 'ania',
      'password': 'bank-haslo',
    });
    expect(android.named('cancel'), isEmpty);
    expect(android.named('guard').last.arguments, <Object?, Object?>{
      'on': false,
    });
  });

  testWidgets('a page in a browser: entries of that site only; the rest '
      'only past a warning, which can be turned back', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    final PasswordEntry bank = await vault.add(_bankApp);
    final PasswordEntry shop = await vault.add(_shop);
    final PasswordEntry other = await vault.add(_other);
    final _Android android = _android(_webRequest());
    await _pump(tester, vault: vault, security: security);
    await _confirm(tester, 'sekret12');

    // The host of the page, then the browser it is in.
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('Chrome · com.android.chrome'), findsOneWidget);
    expect(find.byKey(Key('autofill-row-${shop.id}')), findsOneWidget);
    // Another host of the same site says which one.
    expect(find.text('ola · login.example.com'), findsOneWidget);
    expect(find.byKey(Key('autofill-row-${bank.id}')), findsNothing);
    expect(find.byKey(Key('autofill-row-${other.id}')), findsNothing);

    await _tap(tester, 'autofill-search-all');
    expect(find.byKey(const Key('autofill-warning')), findsOneWidget);
    await _tap(tester, 'autofill-warning-cancel');
    expect(find.byKey(const Key('autofill-all-notice')), findsNothing);
    expect(find.byKey(Key('autofill-any-row-${other.id}')), findsNothing);

    await _tap(tester, 'autofill-search-all');
    await _tap(tester, 'autofill-warning-continue');
    expect(find.byKey(const Key('autofill-all-notice')), findsOneWidget);
    expect(find.byKey(Key('autofill-any-row-${other.id}')), findsOneWidget);
    expect(find.byKey(Key('autofill-any-row-${bank.id}')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('autofill-search')), 'inna');
    await tester.pump();
    expect(find.byKey(Key('autofill-any-row-${bank.id}')), findsNothing);
    expect(android.named('fill'), isEmpty);

    await _tap(tester, 'autofill-any-row-${other.id}');
    expect(android.named('fill').single.arguments, <Object?, Object?>{
      'id': 'r2',
      'login': 'ktos',
      'password': 'inne-haslo',
    });
  });

  testWidgets('closed without a pick, nothing goes over and the person is '
      'taken back to the app', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    await vault.add(_bankApp);
    final _Android android = _android(_appRequest());
    await _pump(tester, vault: vault, security: security);
    await _confirm(tester, 'sekret12');
    expect(_picker, findsOneWidget);

    await tester.pageBack();
    await _frames(tester);
    expect(_picker, findsNothing);
    expect(android.named('fill'), isEmpty);
    expect(android.named('cancel').single.arguments, <Object?, Object?>{
      'id': 'r1',
      'back': true,
    });
  });

  testWidgets('a wrong app password, or none given: no picker, nothing goes '
      'over', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    await vault.add(_bankApp);
    final _Android android = _android(_appRequest());
    await _pump(tester, vault: vault, security: security);

    await _confirm(tester, 'zle-haslo');
    expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await _frames(tester);
    expect(_picker, findsNothing);
    expect(android.named('fill'), isEmpty);
    expect(android.named('cancel'), hasLength(1));
    // Not taken up again.
    await _changed(tester);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
  });

  testWidgets('Zen locking closes the picker; nothing goes over, and Zen '
      'stays where it is', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    final PasswordEntry bank = await vault.add(_bankApp);
    final _Android android = _android(_appRequest());
    await _pump(tester, vault: vault, security: security);
    await _confirm(tester, 'sekret12');
    expect(find.byKey(Key('autofill-row-${bank.id}')), findsOneWidget);

    security.lock();
    vault.forget();
    await _frames(tester);
    expect(_picker, findsNothing);
    expect(android.named('fill'), isEmpty);
    expect(android.named('cancel').single.arguments, <Object?, Object?>{
      'id': 'r1',
      'back': false,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('a request the Android side ended (time ran out, the person '
      'went back to the app) closes the picker; nothing goes over', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    await vault.add(_bankApp);
    final _Android android = _android(_appRequest());
    await _pump(tester, vault: vault, security: security);
    await _confirm(tester, 'sekret12');
    expect(_picker, findsOneWidget);

    android.pending = null;
    await _changed(tester);
    expect(_picker, findsNothing);
    expect(android.named('fill'), isEmpty);
    expect(android.named('cancel'), isEmpty);
  });

  testWidgets('an entry deleted meanwhile leaves the list at once; nothing '
      'goes over', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    final PasswordEntry bank = await vault.add(_bankApp);
    final _Android android = _android(_appRequest());
    await _pump(tester, vault: vault, security: security);
    await _confirm(tester, 'sekret12');
    final Finder row = find.byKey(Key('autofill-row-${bank.id}'));
    expect(row, findsOneWidget);
    await vault.delete(bank.id);
    await tester.pump();
    expect(row, findsNothing);
    expect(android.named('fill'), isEmpty);
  });

  test('a request from the Android side is taken only when it looks right; '
      'an app\'s own name is one plain short line', () {
    expect(PasswordAutofillRequest.fromMap(null), isNull);
    expect(
      PasswordAutofillRequest.fromMap(<String, Object?>{'id': 'x'}),
      isNull,
    );
    expect(
      PasswordAutofillRequest.fromMap(<String, Object?>{
        'id': 'x',
        'package': 'not a package',
      }),
      isNull,
    );
    final PasswordAutofillRequest? r =
        PasswordAutofillRequest.fromMap(<String, Object?>{
          'id': 'x',
          'package': 'com.example.app',
          'label': 'Bank\u202e\n${'x' * 100}',
          'webScheme': 'javascript',
        });
    expect(r, isNotNull);
    expect(r!.isWeb, isFalse);
    expect(r.webScheme, isNull);
    expect(r.appLabel, startsWith('Bank x'));
    expect(r.appLabel!.length, lessThanOrEqualTo(61));
    expect(r.appLabel, isNot(contains('\u202e')));
    // Nothing of who asked in its text (it may reach a log).
    expect(r.toString(), isNot(contains('example')));
  });

  testWidgets('without Android nothing is asked of the channel', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await _withPassword();
    final _Android android = _android(_appRequest());
    await _pump(
      tester,
      vault: _vault(security),
      security: security,
      bridge: PasswordAutofillBridge(supported: false),
    );
    expect(android.calls, isEmpty);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
  });

  testWidgets('"Wypełnianie w innych aplikacjach" in the menu of Hasła says '
      'what it does and opens Android\'s setting', (WidgetTester tester) async {
    final MemoryAppSecurityService security = MemoryAppSecurityService();
    final _Android android = _android(null);
    await _pump(tester, vault: _vault(security), security: security);
    await _tap(tester, 'open-vault');
    await _tap(tester, 'passwords-menu');
    await _tap(tester, 'passwords-menu-autofill');
    expect(find.byKey(const Key('autofill-info')), findsOneWidget);
    expect(find.textContaining('najpierw odblokowujesz Zen'), findsOneWidget);
    expect(find.byKey(const Key('autofill-status-off')), findsOneWidget);
    await _tap(tester, 'autofill-open-settings');
    expect(android.named('openSettings'), hasLength(1));
    expect(find.byKey(const Key('autofill-info')), findsNothing);
  });

  group('one question per request', () {
    /// Zen with an app password and the bank's login, locked.
    Future<(MemoryAppSecurityService, PasswordVaultService, String)>
    lockedWithBank({PlatformKeyVault? keys, String? panic}) async {
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        passwordIterations: 10,
        keyVault: keys,
      );
      await security.setPassword('sekret12');
      if (panic != null) {
        await security.setPanicPassword(panic);
      }
      if (keys != null) {
        expect(await security.setBiometricUnlockEnabled(true), isTrue);
      }
      final PasswordVaultService vault = _vault(security);
      final PasswordEntry bank = await vault.add(_bankApp);
      security.lock();
      vault.forget();
      return (security, vault, bank.id);
    }

    testWidgets('Zen locked when the request came: the lock screen is the '
        'one question, the picker follows, and "Hasła" still asks', (
      WidgetTester tester,
    ) async {
      final (
        MemoryAppSecurityService security,
        PasswordVaultService vault,
        String bank,
      ) = await lockedWithBank();
      final _Android android = _android(_appRequest());
      await _pumpGated(tester, vault: vault, security: security);
      expect(_lockScreen, findsOneWidget);
      expect(_picker, findsNothing);

      await _unlockWith(tester, 'sekret12');
      expect(_question, findsNothing);
      expect(_picker, findsOneWidget);
      await _tap(tester, 'autofill-row-$bank');
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r1',
        'login': 'ania',
        'password': 'bank-haslo',
      });

      // The unlock went to that picker alone: the passwords ask.
      await _tap(tester, 'open-vault');
      expect(_question, findsOneWidget);
    });

    testWidgets('a fingerprint at the lock screen counts the same: one '
        'prompt in all', (WidgetTester tester) async {
      final MemoryKeyVault keys = MemoryKeyVault();
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank(keys: keys);
      _android(_appRequest());
      // The lock screen asks for the fingerprint at once.
      await _pumpGated(tester, vault: vault, security: security);
      expect(security.isLocked, isFalse);
      expect(_question, findsNothing);
      expect(_picker, findsOneWidget);
      expect(keys.prompts, 1);
    });

    testWidgets('Zen already unlocked when the request came: asked exactly '
        'once', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      await vault.add(_bankApp);
      final _Android android = _android(null);
      await _pumpGated(tester, vault: vault, security: security);
      expect(_lockScreen, findsNothing);

      android.pending = _appRequest();
      await _changed(tester);
      expect(_question, findsOneWidget);
      await _confirm(tester, 'sekret12');
      expect(_question, findsNothing);
      expect(_picker, findsOneWidget);
    });

    testWidgets('an unlock older than the request does not count', (
      WidgetTester tester,
    ) async {
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank();
      final _Android android = _android(null);
      await _pumpGated(tester, vault: vault, security: security);
      await _unlockWith(tester, 'sekret12');
      expect(_lockScreen, findsNothing);

      android.pending = _appRequest();
      await _changed(tester);
      expect(_question, findsOneWidget);
      expect(_picker, findsNothing);
    });

    testWidgets('the unlock counts once: the next request asks', (
      WidgetTester tester,
    ) async {
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank();
      final _Android android = _android(_appRequest());
      await _pumpGated(tester, vault: vault, security: security);
      await _unlockWith(tester, 'sekret12');
      expect(_picker, findsOneWidget);
      await tester.pageBack();
      await _frames(tester);
      expect(_picker, findsNothing);
      expect(android.named('cancel').single.arguments, <Object?, Object?>{
        'id': 'r1',
        'back': true,
      });

      android.pending = _webRequest();
      await _changed(tester);
      expect(_question, findsOneWidget);
      expect(_picker, findsNothing);
    });

    testWidgets('Zen locking while the picker is up still ends the request', (
      WidgetTester tester,
    ) async {
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank();
      final _Android android = _android(_appRequest());
      await _pumpGated(tester, vault: vault, security: security);
      await _unlockWith(tester, 'sekret12');
      expect(_picker, findsOneWidget);

      security.lock();
      vault.forget();
      await _frames(tester);
      expect(_picker, findsNothing);
      expect(_lockScreen, findsOneWidget);
      expect(android.named('fill'), isEmpty);
      expect(android.named('cancel').single.arguments, <Object?, Object?>{
        'id': 'r1',
        'back': false,
      });
      // Unlocked again: the request is gone, nothing waits for it.
      await _unlockWith(tester, 'sekret12');
      expect(_picker, findsNothing);
      expect(_question, findsNothing);
    });

    testWidgets('wrong passwords count as before and pass nothing; the right '
        'one then opens the picker', (WidgetTester tester) async {
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank();
      _android(_appRequest());
      await _pumpGated(tester, vault: vault, security: security);
      await _unlockWith(tester, 'zle-haslo');
      expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
      expect(
        await security.credentialsStore.read(
          appSecurityUnlockFailuresStorageKey,
        ),
        startsWith('1;'),
      );
      expect(_passOf(tester).take('r1'), isFalse);

      await _unlockWith(tester, 'sekret12');
      expect(_question, findsNothing);
      expect(_picker, findsOneWidget);
      expect(
        await security.credentialsStore.read(
          appSecurityUnlockFailuresStorageKey,
        ),
        isNull,
      );
    });

    testWidgets('the emergency wipe password passes nothing', (
      WidgetTester tester,
    ) async {
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank(panic: 'panika99');
      final Completer<void> wiping = Completer<void>();
      _android(_appRequest());
      await _pumpGated(
        tester,
        vault: vault,
        security: security,
        wipe: (WidgetRef ref) async {
          await security.reset();
          await wiping.future;
        },
      );
      await _unlockWith(tester, 'panika99');
      expect(security.hasPassword, isFalse);
      expect(_passOf(tester).take('r1'), isFalse);
      wiping.complete();
      await _frames(tester);
    });

    testWidgets('a request whose time ran out before the picker leaves no '
        'unlock behind', (WidgetTester tester) async {
      final (MemoryAppSecurityService security, PasswordVaultService vault, _) =
          await lockedWithBank();
      // Open when the lock screen checks the password, gone right after.
      final _Android android = _android(_appRequest())..endsAfterAsked = 1;
      await _pumpGated(tester, vault: vault, security: security);
      await _unlockWith(tester, 'sekret12');
      expect(_picker, findsNothing);
      expect(_question, findsNothing);
      expect(android.named('pending'), hasLength(2));
      expect(_passOf(tester).take('r1'), isFalse);
    });

    test('the pass: only for the request seen before a check that opened '
        'Zen, once, and within the request\'s minute', () {
      DateTime now = DateTime.utc(2026, 11, 12, 12);
      final AutofillUnlockPass pass = AutofillUnlockPass(now: () => now);

      // Nothing was waiting, or the check did not open Zen.
      pass.unlocked();
      expect(pass.take('r1'), isFalse);
      pass
        ..waiting(null)
        ..unlocked();
      expect(pass.take('r1'), isFalse);
      pass
        ..waiting('r1')
        ..forget()
        ..unlocked();
      expect(pass.take('r1'), isFalse);
      pass.waiting('r1');
      expect(pass.take('r1'), isFalse);

      // Another request gets nothing, and the pass is gone after it.
      pass
        ..waiting('r1')
        ..unlocked();
      expect(pass.take('r2'), isFalse);
      expect(pass.take('r1'), isFalse);

      pass
        ..waiting('r1')
        ..unlocked();
      expect(pass.take('r1'), isTrue);
      expect(pass.take('r1'), isFalse);

      // The minute counts from when the request was seen open.
      pass.waiting('r1');
      now = now.add(const Duration(seconds: 50));
      pass.unlocked();
      now = now.add(const Duration(seconds: 9));
      expect(pass.take('r1'), isTrue);
      pass.waiting('r1');
      now = now.add(const Duration(seconds: 59));
      pass.unlocked();
      now = now.add(const Duration(seconds: 1));
      expect(pass.take('r1'), isFalse);
    });

    test(
      'locking (as opening another account does) forgets the pass',
      () async {
        final MemoryAppSecurityService security = await _withPassword();
        final ProviderContainer container = ProviderContainer(
          overrides: [appSecurityServiceProvider.overrideWithValue(security)],
        );
        addTearDown(container.dispose);
        final AutofillUnlockPass pass = container.read(
          autofillUnlockPassProvider,
        );
        pass
          ..waiting('r1')
          ..unlocked();
        security.lock();
        expect(pass.take('r1'), isFalse);
      },
    );
  });
}
