import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_match.dart';
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
      case 'hold':
        return pending != null &&
            (call.arguments as Map<Object?, Object?>)['id'] == pending!['id'];
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

Map<String, Object?> _webRequest({bool username = true, bool? password}) =>
    <String, Object?>{
      'id': 'r2',
      'package': 'com.android.chrome',
      'label': 'Chrome',
      'webDomain': 'example.com',
      'webScheme': 'https',
      'username': username,
      'password': ?password,
    };

/// A login entry for example.com without a login: it can fill a password
/// field only.
const PasswordFields _passwordOnly = PasswordFields(
  name: 'Bez loginu',
  password: 'tylko-haslo',
  address: 'https://example.com',
);

/// A login entry for example.com without a password (a note instead): it
/// can fill a login field only.
const PasswordFields _loginOnly = PasswordFields(
  name: 'Sam login',
  login: 'jan',
  note: 'hasło na kartce',
  address: 'https://example.com',
);

/// A store that takes nothing: every write fails.
final class _FailingDisk implements LedgerDisk {
  final MemoryLedgerDisk _disk = MemoryLedgerDisk();
  bool failing = false;

  @override
  Future<Uint8List?> read(String key) => _disk.read(key);

  @override
  Future<void> write(String key, Uint8List data) async {
    if (failing) {
      throw const FileSystemException('disk full');
    }
    await _disk.write(key, data);
  }

  @override
  Future<void> delete(String key) => _disk.delete(key);
}

PasswordVaultService _vault(AppSecurityService security, {LedgerDisk? disk}) {
  int t = 1760000000000;
  return PasswordVaultService(
    disk: disk ?? MemoryLedgerDisk(),
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
    // One question in all: the unlock, or the confirmation when Zen is open.
    expect(
      find.textContaining('najpierw odblokowujesz Zen albo potwierdzasz'),
      findsOneWidget,
    );
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

  group('forms with one field', () {
    test('the Android side says which fields the form has; an answer '
        'without the password\'s had one', () {
      PasswordAutofillRequest r(Map<String, Object?> fields) =>
          PasswordAutofillRequest.fromMap(<String, Object?>{
            'id': 'x',
            'package': 'com.example.app',
            ...fields,
          })!;
      expect(r(const <String, Object?>{}).hasPasswordField, isTrue);
      expect(
        r(const <String, Object?>{'password': true}).hasPasswordField,
        isTrue,
      );
      expect(
        r(const <String, Object?>{'password': 'no'}).hasPasswordField,
        isTrue,
      );

      final PasswordAutofillRequest loginOnly = r(const <String, Object?>{
        'username': true,
        'password': false,
      });
      expect(loginOnly.hasPasswordField, isFalse);
      expect(loginOnly.canFillWith(login: 'jan', password: ''), isTrue);
      expect(loginOnly.canFillWith(login: '', password: 'haslo'), isFalse);

      final PasswordAutofillRequest passwordOnly = r(const <String, Object?>{
        'username': false,
        'password': true,
      });
      expect(passwordOnly.canFillWith(login: 'jan', password: ''), isFalse);
      expect(passwordOnly.canFillWith(login: '', password: 'haslo'), isTrue);
    });

    testWidgets('the first page of a login in two steps: only entries with a '
        'login, a line that says only the login goes in; the one tapped goes '
        'over', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final PasswordEntry shop = await vault.add(_shop);
      final PasswordEntry noLogin = await vault.add(_passwordOnly);
      final PasswordEntry noPassword = await vault.add(_loginOnly);
      final _Android android = _android(_webRequest(password: false));
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');

      expect(find.byKey(const Key('autofill-login-only')), findsOneWidget);
      expect(find.byKey(Key('autofill-row-${shop.id}')), findsOneWidget);
      expect(find.byKey(Key('autofill-row-${noPassword.id}')), findsOneWidget);
      // It would fill nothing here.
      expect(find.byKey(Key('autofill-row-${noLogin.id}')), findsNothing);

      await _tap(tester, 'autofill-row-${shop.id}');
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r2',
        'login': 'ola',
        'password': 'sklep-haslo',
      });
    });

    testWidgets('a page with the password field alone: only entries with a '
        'password', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final PasswordEntry shop = await vault.add(_shop);
      final PasswordEntry noLogin = await vault.add(_passwordOnly);
      final PasswordEntry noPassword = await vault.add(_loginOnly);
      final _Android android = _android(_webRequest(username: false));
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');

      expect(find.byKey(const Key('autofill-login-only')), findsNothing);
      expect(find.byKey(Key('autofill-row-${shop.id}')), findsOneWidget);
      expect(find.byKey(Key('autofill-row-${noLogin.id}')), findsOneWidget);
      expect(find.byKey(Key('autofill-row-${noPassword.id}')), findsNothing);
      // Not past the warning either.
      await _tap(tester, 'autofill-search-all');
      await _tap(tester, 'autofill-warning-continue');
      expect(find.byKey(Key('autofill-any-row-${noLogin.id}')), findsOneWidget);
      expect(
        find.byKey(Key('autofill-any-row-${noPassword.id}')),
        findsNothing,
      );

      await _tap(tester, 'autofill-any-row-${noLogin.id}');
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r2',
        'login': '',
        'password': 'tylko-haslo',
      });
    });
  });

  testWidgets('past the warning, a search that finds nothing says so', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(security);
    final PasswordEntry other = await vault.add(_other);
    _android(_webRequest());
    await _pump(tester, vault: vault, security: security);
    await _confirm(tester, 'sekret12');
    await _tap(tester, 'autofill-search-all');
    await _tap(tester, 'autofill-warning-continue');
    expect(find.byKey(Key('autofill-any-row-${other.id}')), findsOneWidget);
    expect(find.byKey(const Key('autofill-search-empty')), findsNothing);

    await tester.enterText(find.byKey(const Key('autofill-search')), 'zzz');
    await tester.pump();
    expect(find.byKey(Key('autofill-any-row-${other.id}')), findsNothing);
    expect(find.text('Nic nie pasuje do „zzz”.'), findsOneWidget);
  });

  group('a new login right in the picker', () {
    final Finder form = find.byKey(const Key('password-form-screen'));

    TextField field(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(Key(key)));

    Future<void> type(
      WidgetTester tester, {
      String login = 'nowy@example.com',
      String password = 'Nowe-haslo-1',
    }) async {
      await tester.enterText(
        find.byKey(const Key('password-field-login')),
        login,
      );
      await tester.enterText(
        find.byKey(const Key('password-field-password')),
        password,
      );
      await tester.pump();
    }

    PasswordEntry? saved(PasswordVaultService vault, String login) {
      for (final PasswordEntry e in vault.entries) {
        if (e.login == login) {
          return e;
        }
      }
      return null;
    }

    test('it is saved under the address the matching finds the same request '
        'by, exactly: a page by its scheme, host and port, an app by its '
        'package', () {
      PasswordAutofillRequest r(Map<String, Object?> fields) =>
          PasswordAutofillRequest.fromMap(<String, Object?>{
            'id': 'x',
            'package': 'com.android.chrome',
            'label': 'Chrome',
            ...fields,
          })!;
      final List<(PasswordAutofillRequest, String, String)> cases =
          <(PasswordAutofillRequest, String, String)>[
            (
              r(const <String, Object?>{
                'webDomain': 'example.com',
                'webScheme': 'https',
              }),
              'https://example.com',
              'example.com',
            ),
            (
              r(const <String, Object?>{
                'webDomain': 'example.com',
                'webScheme': 'http',
              }),
              'http://example.com',
              'example.com',
            ),
            // No scheme reported: the matching takes the page as http.
            (
              r(const <String, Object?>{'webDomain': 'example.com'}),
              'http://example.com',
              'example.com',
            ),
            (
              r(const <String, Object?>{
                'webDomain': 'Login.Example.COM.:8443',
                'webScheme': 'https',
              }),
              'https://login.example.com:8443',
              'login.example.com',
            ),
            (
              PasswordAutofillRequest.fromMap(_appRequest())!,
              'android-app://com.bank.app',
              'Mój Bank',
            ),
            (
              r(const <String, Object?>{'label': null}),
              'android-app://com.android.chrome',
              'com.android.chrome',
            ),
          ];
      for (final (PasswordAutofillRequest request, String address, String name)
          in cases) {
        expect(request.newEntryAddress, address);
        expect(request.newEntryName, name);
        final PasswordEntry entry = PasswordEntry(
          id: 'e0000001',
          versionKey: 'v0000001',
          fields: PasswordFields(
            name: request.newEntryName,
            login: 'a',
            password: 'b',
            address: request.newEntryAddress!,
          ),
          createdAtMillis: 1,
          changedAtMillis: 1,
        );
        final List<PasswordMatch> found = matchPasswordEntries(
          <PasswordEntry>[entry],
          packageName: request.packageName,
          webDomain: request.webDomain,
          webScheme: request.webScheme,
        );
        expect(found, hasLength(1), reason: address);
        expect(found.single.kind, PasswordMatchKind.exact, reason: address);
      }
      // A page that is no host gets no address (and no new login).
      expect(
        r(const <String, Object?>{'webDomain': 'not a host'}).newEntryAddress,
        isNull,
      );
    });

    testWidgets('nothing saved for the page: the new login is the main '
        'action; it opens prefilled, and saved it is in the vault and fills '
        'the form at once', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      await vault.add(_bankApp);
      await vault.add(_other);
      int edits = 0;
      vault.edits.addListener(() => edits++);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');

      expect(find.byKey(const Key('autofill-none')), findsOneWidget);
      expect(
        tester.widget(find.byKey(const Key('autofill-add'))),
        isA<FilledButton>(),
      );
      expect(find.text('Nowy login dla tej strony'), findsOneWidget);

      await _tap(tester, 'autofill-add');
      expect(form, findsOneWidget);
      expect(
        field(tester, 'password-field-name').controller!.text,
        'example.com',
      );
      final TextField address = field(tester, 'password-field-address');
      expect(address.controller!.text, 'https://example.com');
      expect(address.readOnly, isTrue);
      expect(find.text('Zapisz i użyj'), findsOneWidget);
      // The request waits longer while the login is typed.
      expect(
        android.named('hold').map((MethodCall c) => c.arguments),
        <Object?>[
          <Object?, Object?>{'id': 'r2', 'on': true},
        ],
      );

      await type(tester);
      await _tap(tester, 'password-save');
      expect(form, findsNothing);
      expect(_picker, findsNothing);
      final PasswordEntry entry = saved(vault, 'nowy@example.com')!;
      expect(entry.name, 'example.com');
      expect(entry.password, 'Nowe-haslo-1');
      expect(entry.address, 'https://example.com');
      // Saved as any other entry is: the sync and the copies look then.
      expect(edits, 1);
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r2',
        'login': 'nowy@example.com',
        'password': 'Nowe-haslo-1',
      });
      expect(android.named('cancel'), isEmpty);
      // The next request from the page finds it as its own.
      final List<PasswordMatch> next = vault.matchesFor(
        webDomain: 'example.com',
        webScheme: 'https',
      );
      expect(next.single.entry.id, entry.id);
      expect(next.single.kind, PasswordMatchKind.exact);
    });

    testWidgets('with a login saved for the page it is there as a plain '
        'button; back from the untouched form asks nothing and the request '
        'gets its usual time again', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      await vault.add(_shop);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      expect(
        tester.widget(find.byKey(const Key('autofill-add'))),
        isA<OutlinedButton>(),
      );

      await _tap(tester, 'autofill-add');
      expect(form, findsOneWidget);
      await tester.pageBack();
      await _frames(tester);
      expect(find.byKey(const Key('password-discard-dialog')), findsNothing);
      expect(form, findsNothing);
      expect(_picker, findsOneWidget);
      expect(
        android.named('hold').map((MethodCall c) => c.arguments),
        <Object?>[
          <Object?, Object?>{'id': 'r2', 'on': true},
          <Object?, Object?>{'id': 'r2', 'on': false},
        ],
      );
      expect(android.named('fill'), isEmpty);
      expect(vault.entries, hasLength(1));
    });

    testWidgets('an app: named as the app calls itself, saved for its '
        'package', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      await vault.add(_shop);
      final _Android android = _android(_appRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      expect(find.text('Nowy login dla tej aplikacji'), findsOneWidget);

      await _tap(tester, 'autofill-add');
      expect(field(tester, 'password-field-name').controller!.text, 'Mój Bank');
      expect(
        field(tester, 'password-field-address').controller!.text,
        'android-app://com.bank.app',
      );
      await type(tester, login: 'ania2', password: 'bank-2');
      await _tap(tester, 'password-save');
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r1',
        'login': 'ania2',
        'password': 'bank-2',
      });
      final PasswordEntry entry = saved(vault, 'ania2')!;
      expect(
        vault.matchesFor(packageName: 'com.bank.app').single.entry.id,
        entry.id,
      );
    });

    testWidgets('the first page of a login in two steps: the login is saved '
        'whole and handed over', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final _Android android = _android(_webRequest(password: false));
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      expect(find.byKey(const Key('autofill-login-only')), findsOneWidget);

      await _tap(tester, 'autofill-add');
      await type(tester);
      await _tap(tester, 'password-save');
      expect(saved(vault, 'nowy@example.com')!.password, 'Nowe-haslo-1');
      // The Android side puts in only the login: the form has no other field.
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r2',
        'login': 'nowy@example.com',
        'password': 'Nowe-haslo-1',
      });
    });

    testWidgets('a new login with nothing the form takes is saved, said so, '
        'and the picker stays', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final _Android android = _android(_webRequest(username: false));
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');

      await _tap(tester, 'autofill-add');
      await tester.enterText(
        find.byKey(const Key('password-field-login')),
        'jan',
      );
      await tester.enterText(
        find.byKey(const Key('password-field-note')),
        'hasło na kartce',
      );
      await tester.pump();
      await _tap(tester, 'password-save');
      expect(saved(vault, 'jan'), isNotNull);
      expect(
        find.text(
          'Login zapisany w Hasłach, ale nie ma w nim nic do wpisania w tym '
          'formularzu.',
        ),
        findsOneWidget,
      );
      expect(form, findsNothing);
      expect(_picker, findsOneWidget);
      expect(android.named('fill'), isEmpty);
      expect(android.named('hold').last.arguments, <Object?, Object?>{
        'id': 'r2',
        'on': false,
      });
    });

    testWidgets('a full vault is said plainly; the form stays as typed and '
        'nothing goes over', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final Map<String, Object?> versions = <String, Object?>{
        for (int i = 0; i < kMaxPasswordEntries; i++)
          'v${i.toString().padLeft(9, '0')}': <String, Object?>{
            'i': 'e${i.toString().padLeft(9, '0')}',
            'a': 1000 + i,
            'n': 'Strona $i',
            'p': 'haslo-$i',
          },
      };
      final MemoryLedgerDisk disk = MemoryLedgerDisk()
        ..files[kPasswordVaultKey] = Uint8List.fromList(
          utf8.encode(jsonEncode(<String, Object?>{'v': 1, 'e': versions})),
        );
      final PasswordVaultService vault = _vault(security, disk: disk);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');

      await _tap(tester, 'autofill-add');
      await type(tester);
      await _tap(tester, 'password-save');
      expect(
        find.text(
          'Brak miejsca na nowe hasła. Usuń te, których nie potrzebujesz.',
        ),
        findsOneWidget,
      );
      expect(form, findsOneWidget);
      expect(
        field(tester, 'password-field-login').controller!.text,
        'nowy@example.com',
      );
      expect(android.named('fill'), isEmpty);
    });

    testWidgets('a write that fails is said; saved again, it fills', (
      WidgetTester tester,
    ) async {
      final MemoryAppSecurityService security = await _withPassword();
      final _FailingDisk disk = _FailingDisk();
      final PasswordVaultService vault = _vault(security, disk: disk);
      await vault.load();
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');

      await _tap(tester, 'autofill-add');
      await type(tester);
      disk.failing = true;
      await _tap(tester, 'password-save');
      expect(find.text('Nie udało się. Spróbuj jeszcze raz.'), findsOneWidget);
      expect(form, findsOneWidget);
      expect(android.named('fill'), isEmpty);
      expect(saved(vault, 'nowy@example.com'), isNull);

      disk.failing = false;
      await _tap(tester, 'password-save');
      expect(form, findsNothing);
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r2',
        'login': 'nowy@example.com',
        'password': 'Nowe-haslo-1',
      });
    });

    testWidgets('a vault of a newer Zen takes nothing: no new login is '
        'offered, and the picker says why', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final MemoryLedgerDisk disk = MemoryLedgerDisk()
        ..files[kPasswordVaultKey] = Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object?>{'v': 99, 'e': <String, Object?>{}}),
          ),
        );
      _android(_webRequest());
      await _pump(
        tester,
        vault: _vault(security, disk: disk),
        security: security,
      );
      await _confirm(tester, 'sekret12');
      expect(find.byKey(const Key('autofill-newer')), findsOneWidget);
      expect(find.byKey(const Key('autofill-add')), findsNothing);
    });

    testWidgets('the request ends while the login is typed: the form stays; '
        'saved, the login is kept and the person is told the form was not '
        'filled', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      await _tap(tester, 'autofill-add');
      await type(tester);

      android.pending = null;
      await _changed(tester);
      expect(form, findsOneWidget);
      expect(
        field(tester, 'password-field-login').controller!.text,
        'nowy@example.com',
      );

      await _tap(tester, 'password-save');
      expect(form, findsNothing);
      expect(_picker, findsNothing);
      expect(saved(vault, 'nowy@example.com'), isNotNull);
      expect(
        find.text(
          'Login zapisany w Hasłach, ale czas na wypełnienie minął. Spróbuj '
          'jeszcze raz w tamtej aplikacji.',
        ),
        findsOneWidget,
      );
      expect(android.named('fill'), isEmpty);
      expect(android.named('cancel'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the request ends while the login is typed and the form is '
        'left: the picker goes with it, nothing is saved', (
      WidgetTester tester,
    ) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      await _tap(tester, 'autofill-add');
      await type(tester);
      android.pending = null;
      await _changed(tester);

      await tester.pageBack();
      await _frames(tester);
      await _tap(tester, 'password-discard');
      expect(form, findsNothing);
      expect(_picker, findsNothing);
      expect(vault.entries, isEmpty);
      expect(android.named('fill'), isEmpty);
      expect(android.named('guard').last.arguments, <Object?, Object?>{
        'on': false,
      });
    });

    testWidgets('a newer request while the form is kept is answered over it; '
        'the form and its picker stay until left, and touches through other '
        'windows stay dropped while any picker is up', (
      WidgetTester tester,
    ) async {
      final MemoryAppSecurityService security = await _withPassword();
      final PasswordVaultService vault = _vault(security);
      final PasswordEntry bank = await vault.add(_bankApp);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      await _tap(tester, 'autofill-add');
      await type(tester);
      android.pending = null;
      await _changed(tester);

      android.pending = _appRequest();
      await _changed(tester);
      await _confirm(tester, 'sekret12');
      await _tap(tester, 'autofill-row-${bank.id}');
      expect(android.named('fill').single.arguments, <Object?, Object?>{
        'id': 'r1',
        'login': 'ania',
        'password': 'bank-haslo',
      });
      expect(
        android.named('guard').map((MethodCall c) => c.arguments),
        <Object?>[
          <Object?, Object?>{'on': true},
        ],
      );
      // Back in Zen: what was typed is still there.
      expect(form, findsOneWidget);
      expect(
        field(tester, 'password-field-login').controller!.text,
        'nowy@example.com',
      );

      await _tap(tester, 'password-save');
      expect(form, findsNothing);
      expect(_picker, findsNothing);
      expect(saved(vault, 'nowy@example.com'), isNotNull);
      expect(android.named('fill'), hasLength(1));
      expect(android.named('guard').last.arguments, <Object?, Object?>{
        'on': false,
      });
      expect(tester.takeException(), isNull);
    });

    testWidgets('Zen locking while the login is typed closes it all; nothing '
        'is saved and nothing goes over', (WidgetTester tester) async {
      final MemoryAppSecurityService security = await _withPassword();
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final PasswordVaultService vault = _vault(security, disk: disk);
      final _Android android = _android(_webRequest());
      await _pump(tester, vault: vault, security: security);
      await _confirm(tester, 'sekret12');
      await _tap(tester, 'autofill-add');
      await type(tester);

      security.lock();
      vault.forget();
      await _frames(tester);
      expect(form, findsNothing);
      expect(_picker, findsNothing);
      expect(android.named('fill'), isEmpty);
      expect(android.named('cancel').single.arguments, <Object?, Object?>{
        'id': 'r2',
        'back': false,
      });
      final Uint8List? stored = disk.files[kPasswordVaultKey];
      expect(
        stored == null ? '' : utf8.decode(stored),
        isNot(contains('nowy@example.com')),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
