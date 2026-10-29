import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/guarded_settings_store.dart';
import 'package:zen/src/features/security/resume_session.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/lock_mode_choice.dart';

/// The device's clocks as the vault reads them: the time since boot and the
/// wall clock, and its screen lock.
final class _Device {
  int sinceBoot = 3 * 60 * 60 * 1000;
  DateTime now = DateTime.utc(2026, 10, 28, 12);
  bool? screenLock = true;

  void wait(Duration duration) {
    sinceBoot += duration.inMilliseconds;
    now = now.add(duration);
  }

  /// Off for [off], then started again: the clock since boot starts over.
  void restart(Duration off) {
    now = now.add(off);
    sinceBoot = const Duration(seconds: 40).inMilliseconds;
  }

  ClockResumeSessionVault vault() => ClockResumeSessionVault(
    sinceBootMillis: () => sinceBoot,
    now: () => now,
    screenLock: () async => screenLock,
  );
}

/// A vault that counts how often its key was destroyed.
final class _CountingVault implements ResumeSessionVault {
  _CountingVault(this._inner);

  final ResumeSessionVault _inner;
  int wipes = 0;

  @override
  bool get isAvailable => _inner.isAvailable;

  @override
  Future<Uint8List?> seal(Uint8List secret, Duration lifetime) =>
      _inner.seal(secret, lifetime);

  @override
  Future<Uint8List?> open(Uint8List sealed) => _inner.open(sealed);

  @override
  Future<void> wipe() async => wipes++;
}

/// Deletes wait for [gate] while it is set.
final class _HeldDeletes implements AppSecurityCredentialsStore {
  final MemorySecurityCredentialsStore _inner =
      MemorySecurityCredentialsStore();
  Completer<void>? gate;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) async {
    await gate?.future;
    await _inner.delete(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String password = 'sekret12';
  const AppSettings on = AppSettings(
    lockMode: AppLockMode.background,
    backgroundLockDelaySeconds: 300,
    keepUnlockedAfterClose: true,
  );
  const AppSettings off = AppSettings(
    lockMode: AppLockMode.background,
    backgroundLockDelaySeconds: 300,
  );

  late AppSecurityCredentialsStore credentials;
  late _Device device;
  late _CountingVault vault;
  late LocalAppSecurityService service;
  late Uint8List masterKey;

  LocalAppSecurityService build() => LocalAppSecurityService(
    credentialsStore: credentials,
    passwordIterations: 10,
    resumeVault: vault,
  );

  /// A start from scratch (the process was gone) with [settings].
  Future<LocalAppSecurityService> start([AppSettings settings = on]) async {
    final LocalAppSecurityService started = build();
    await started.initialize(settings: settings);
    return started;
  }

  Future<String?> kept() =>
      credentials.read(appSecurityResumeSessionStorageKey);

  setUp(() async {
    credentials = MemorySecurityCredentialsStore();
    device = _Device();
    vault = _CountingVault(device.vault());
    service = build();
    await service.initialize(settings: const AppSettings());
    masterKey = (await service.currentEncryptionKey())!;
    await service.setPassword(password);
    await service.applySettings(on);
  });

  test('off by default, and the protected settings copy keeps it', () async {
    expect(const AppSettings().keepUnlockedAfterClose, isFalse);
    expect(
      AppSettings.fromJson(const <String, dynamic>{}).keepUnlockedAfterClose,
      isFalse,
    );
    expect(AppSettings.fromJson(on.toJson()).keepUnlockedAfterClose, isTrue);
    expect(kDeviceSettingKeys, contains('keepUnlockedAfterClose'));

    final MemorySecurityCredentialsStore secrets =
        MemorySecurityCredentialsStore();
    final MemoryAppSettingsStore file = MemoryAppSettingsStore(off);
    final GuardedAppSettingsStore guarded = GuardedAppSettingsStore(
      inner: file,
      secrets: secrets,
    );
    await guarded.save(on);
    // Whoever writes the settings file cannot turn it on or off.
    await file.save(off);
    expect((await guarded.load())!.keepUnlockedAfterClose, isTrue);
    await guarded.save(off);
    await file.save(on);
    expect((await guarded.load())!.keepUnlockedAfterClose, isFalse);
  });

  test('nothing is kept while the setting is off, and a start asks for '
      'the password', () async {
    await service.applySettings(off);
    await service.keepResumeSession();
    expect(await kept(), isNull);
    final LocalAppSecurityService restarted = await start(off);
    expect(restarted.isLocked, isTrue);
    expect(await restarted.currentEncryptionKey(), isNull);
  });

  test('nothing is kept under another lock mode', () async {
    for (final AppLockMode mode in <AppLockMode>[
      AppLockMode.appClose,
      AppLockMode.systemRestart,
    ]) {
      await service.applySettings(on.copyWith(lockMode: mode));
      await service.keepResumeSession();
      expect(await kept(), isNull, reason: mode.name);
    }
  });

  test('closed and started again within the delay, Zen opens without the '
      'password, once', () async {
    await service.keepResumeSession();
    expect(await kept(), isNotNull);
    device.wait(const Duration(minutes: 4, seconds: 50));

    final LocalAppSecurityService restarted = await start();
    expect(restarted.isLocked, isFalse);
    expect(await restarted.currentEncryptionKey(), masterKey);
    // It served this start: the next one needs a new one.
    expect(await kept(), isNull);
    expect((await start()).isLocked, isTrue);
  });

  test(
    'after the delay the password is needed, and what was kept goes',
    () async {
      await service.keepResumeSession();
      device.wait(const Duration(minutes: 5, seconds: 1));
      final LocalAppSecurityService restarted = await start();
      expect(restarted.isLocked, isTrue);
      expect(await restarted.currentEncryptionKey(), isNull);
      expect(await kept(), isNull);
    },
  );

  test('the delay counts from leaving the screen, as the setting is', () async {
    await service.applySettings(on.copyWith(backgroundLockDelaySeconds: 30));
    await service.keepResumeSession();
    device.wait(const Duration(seconds: 31));
    expect(
      (await start(on.copyWith(backgroundLockDelaySeconds: 30))).isLocked,
      isTrue,
    );
  });

  test('setting the date back does not stretch it', () async {
    await service.keepResumeSession();
    device.wait(const Duration(minutes: 6));
    device.now = device.now.subtract(const Duration(minutes: 10));
    expect((await start()).isLocked, isTrue);
  });

  test('after a restart of the device the password is needed', () async {
    await service.keepResumeSession();
    device.restart(const Duration(seconds: 20));
    expect((await start()).isLocked, isTrue);
    expect(await kept(), isNull);
  });

  test('after the screen lock of the device changed the password is '
      'needed', () async {
    for (final bool? lock in <bool?>[false, null]) {
      device.screenLock = true;
      await service.keepResumeSession();
      device.screenLock = lock;
      expect((await start()).isLocked, isTrue, reason: '$lock');
    }
    // Kept without a screen lock, one turned on since: the password too.
    device.screenLock = false;
    await service.keepResumeSession();
    device.screenLock = true;
    expect((await start()).isLocked, isTrue);
  });

  test(
    'turned off since it was kept: the start asks for the password',
    () async {
      await service.keepResumeSession();
      expect((await start(off)).isLocked, isTrue);
      expect(await kept(), isNull);
      await service.keepResumeSession();
      expect(
        (await start(on.copyWith(lockMode: AppLockMode.appClose))).isLocked,
        isTrue,
      );
    },
  );

  test('"Zablokuj teraz" deletes it before the lock screen shows', () async {
    final _HeldDeletes held = _HeldDeletes();
    credentials = held;
    final LocalAppSecurityService locking = build();
    await locking.initialize(settings: const AppSettings());
    await locking.setPassword(password);
    await locking.applySettings(on);
    await locking.keepResumeSession();
    expect(await kept(), isNotNull);
    int told = 0;
    locking.addListener(() => told++);
    final Completer<void> gate = Completer<void>();
    held.gate = gate;

    locking.lock();
    expect(locking.isLocked, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(told, 0, reason: 'what was kept is still there');

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(told, 1);
    expect(await kept(), isNull);
    expect((await start()).isLocked, isTrue);
  });

  test('a lock while it is being kept still deletes it', () async {
    final Future<void> keeping = service.keepResumeSession();
    service.lock();
    await keeping;
    await Future<void>.delayed(Duration.zero);
    expect(await kept(), isNull);
    expect((await start()).isLocked, isTrue);
  });

  test('coming back to the screen deletes it', () async {
    await service.keepResumeSession();
    await service.dropResumeSession();
    expect(await kept(), isNull);
    expect((await start()).isLocked, isTrue);
  });

  test('a new password deletes it', () async {
    await service.keepResumeSession();
    await service.setPassword('nowe-haslo-9');
    expect(await kept(), isNull);
    expect((await start()).isLocked, isTrue);
  });

  test('turning it off deletes it and destroys the vault key; another lock '
      'mode or delay deletes it', () async {
    await service.keepResumeSession();
    await service.applySettings(off);
    expect(await kept(), isNull);
    expect(vault.wipes, 1);

    await service.applySettings(on);
    await service.keepResumeSession();
    await service.applySettings(on.copyWith(lockMode: AppLockMode.appClose));
    expect(await kept(), isNull);

    await service.applySettings(on);
    await service.keepResumeSession();
    await service.applySettings(on.copyWith(backgroundLockDelaySeconds: 60));
    expect(await kept(), isNull);

    // Any other setting leaves it alone.
    await service.keepResumeSession();
    await service.applySettings(
      on.copyWith(backgroundLockDelaySeconds: 60, secureScreens: false),
    );
    expect(await kept(), isNotNull);
  });

  test('a reset (the wipe) deletes it and destroys the vault key', () async {
    await service.keepResumeSession();
    await service.reset();
    expect(await kept(), isNull);
    expect(vault.wipes, greaterThanOrEqualTo(1));
  });

  test('it never holds the password, only the key', () async {
    await service.keepResumeSession();
    final String stored = (await kept())!;
    final String opened = utf8.decode(base64Decode(stored));
    for (final String text in <String>[stored, opened]) {
      expect(text, isNot(contains(password)));
      expect(text, isNot(contains(base64Encode(utf8.encode(password)))));
      expect(
        text,
        isNot(contains(securityHexFromBytes(utf8.encode(password)))),
      );
    }
    expect(opened, contains(securityHexFromBytes(masterKey)));
  });

  test('anything else in its place asks for the password, without a '
      'crash', () async {
    final List<String> broken = <String>[
      '',
      'nie-base64-%%%',
      base64Encode(<int>[1, 2, 3]),
      base64Encode(utf8.encode('{"v":1}')),
      base64Encode(utf8.encode('[1,2,3]')),
      base64Encode(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'v': 1,
            'k': 'zz',
            'b': 0,
            's': 0,
            'd': 1 << 40,
            'l': true,
          }),
        ),
      ),
    ];
    for (final String value in broken) {
      await credentials.write(appSecurityResumeSessionStorageKey, value);
      final LocalAppSecurityService restarted = await start();
      expect(restarted.isLocked, isTrue, reason: value);
      expect(await kept(), isNull, reason: value);
    }
  });

  test('a key that is not this app\'s master key opens nothing', () async {
    final Uint8List other = Uint8List.fromList(
      List<int>.generate(32, (int i) => 255 - i),
    );
    final Uint8List sealed = (await vault.seal(
      other,
      const Duration(minutes: 5),
    ))!;
    await credentials.write(
      appSecurityResumeSessionStorageKey,
      base64Encode(sealed),
    );
    expect((await start()).isLocked, isTrue);
  });

  test('a vault that does not answer leaves the password', () async {
    final _CountingVault failing = _CountingVault(
      ClockResumeSessionVault(sinceBootMillis: () => null),
    );
    final LocalAppSecurityService withoutClock = LocalAppSecurityService(
      credentialsStore: credentials,
      passwordIterations: 10,
      resumeVault: failing,
    );
    await withoutClock.initialize(settings: on);
    expect(await withoutClock.unlock(password), isTrue);
    await withoutClock.keepResumeSession();
    expect(await kept(), isNull);
  });

  test('without a vault (an additional account) it is not offered', () async {
    final MemoryAppSecurityService none = MemoryAppSecurityService(
      settings: on,
      hasPassword: true,
    );
    expect(none.canStayUnlockedAfterClose, isFalse);
    expect(service.canStayUnlockedAfterClose, isTrue);
  });

  test('the background service, without the app\'s channel, opens '
      'nothing', () async {
    // The service's engine has no `zen/resume_session`: every call there
    // misses its plugin.
    final ChannelResumeSessionVault background = ChannelResumeSessionVault();
    expect(
      await background.seal(masterKey, const Duration(minutes: 5)),
      isNull,
    );
    expect(await background.open(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    // Nor are lifetimes beyond the longest delay ever asked for.
    const MethodChannel channel = MethodChannel('zen/resume_session');
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    expect(
      await ChannelResumeSessionVault().seal(
        masterKey,
        kResumeSessionLongest + const Duration(seconds: 1),
      ),
      isNull,
    );
    expect(calls, isEmpty);
    await ChannelResumeSessionVault().seal(
      masterKey,
      const Duration(minutes: 5),
    );
    expect(calls.single.method, 'seal');
    expect((calls.single.arguments as Map)['ttlMs'], 300000);
  });

  group('the switch next to the lock delay', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      AppSettings settings = off,
      bool vault = true,
    }) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        settings: settings,
        hasPassword: true,
        passwordIterations: 10,
        resumeVault: vault ? device.vault() : null,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...buildAppSettingsProviderOverrides(
              store: MemoryAppSettingsStore(),
              initialState: settings,
              hydrationEnabled: false,
            ),
            appSecurityServiceProvider.overrideWithValue(security),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: LockModeSettingChoice()),
            ),
          ),
        ),
      );
      await tester.pump();
      return ProviderScope.containerOf(
        tester.element(find.byType(LockModeSettingChoice)),
      );
    }

    const Key toggle = Key('settings-lock-keep-after-close');

    testWidgets('is off, says it is a risk, and turns the setting on', (
      WidgetTester tester,
    ) async {
      final ProviderContainer container = await pump(tester);
      expect(find.byKey(toggle), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isFalse);
      expect(find.textContaining('To ryzyko'), findsOneWidget);
      await tester.tap(find.byKey(toggle));
      await tester.pump();
      expect(
        container.read(appSettingsControllerProvider).keepUnlockedAfterClose,
        isTrue,
      );
    });

    testWidgets('is not there under another mode, or where nothing can '
        'keep the key', (WidgetTester tester) async {
      await pump(
        tester,
        settings: off.copyWith(lockMode: AppLockMode.appClose),
      );
      expect(find.byKey(toggle), findsNothing);
      await pump(tester, vault: false);
      expect(find.byKey(toggle), findsNothing);
    });
  });

  test('the clock since boot of this computer is read', () {
    final int? first = systemSinceBootMillis();
    expect(first, isNotNull);
    expect(first, greaterThan(0));
    expect(systemSinceBootMillis()!, greaterThanOrEqualTo(first!));
  });
}
