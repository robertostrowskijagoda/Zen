import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/multi/account_id.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// Several accounts on one device: separate folders and secrets, hidden
/// ones in no list and not to be found without their ID, opened by ID and
/// password, wiped one by one or all together.
void main() {
  late Directory base;
  late _MemoryKeychain keychain;
  late SecureStorageCredentialsStore secrets;
  late ZenAccountRegistry registry;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zen-accounts-');
    keychain = _MemoryKeychain();
    secrets = SecureStorageCredentialsStore(keychain, keychain);
    registry = ZenAccountRegistry(
      instanceDirectory: () async => base,
      secrets: secrets,
      random: Random(42),
    );
    ZenInstance.debugSetBaseDirectory(base);
    ZenAccounts.activate(ZenAccountScope.defaultAccount);
  });

  tearDown(() async {
    ZenAccounts.activate(ZenAccountScope.defaultAccount);
    ZenInstance.debugSetBaseDirectory(null);
    // Windows may still hold a file for a moment: try again, then leave
    // the temporary folder to the system.
    for (int i = 0; i < 10 && await base.exists(); i++) {
      try {
        await base.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  AppSecurityService securityFor(ZenAccountScope scope) =>
      LocalAppSecurityService(
        credentialsStore: secrets.forAccount(scope.secret),
        passwordIterations: 10,
        keyVault: scope.isDefault
            ? const NoKeyVault()
            : const SharedKeyVault(NoKeyVault()),
      );

  Future<List<String>> accountFolders() async {
    final Directory dir = await registry.accountsDirectory();
    return <String>[
      for (final FileSystemEntity e in dir.listSync())
        if (e is Directory)
          e.uri.pathSegments.where((String s) => s.isNotEmpty).last,
    ];
  }

  /// Every byte of every file under [dir], as Latin-1 text.
  String everything(Directory dir) {
    final StringBuffer out = StringBuffer();
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      out.writeln(e.path);
      if (e is File) {
        out.writeln(latin1.decode(e.readAsBytesSync()));
      }
    }
    return out.toString();
  }

  group('account IDs', () {
    test('80 random bits, read back however they are typed', () {
      final String id = newAccountId(Random(1));
      expect(id, hasLength(kAccountIdLength));
      expect(normalizeAccountId(id), id);
      expect(formatAccountId(id), matches(RegExp(r'^(\w{4}-){3}\w{4}$')));
      expect(normalizeAccountId(formatAccountId(id).toLowerCase()), id);
      expect(normalizeAccountId(' ${formatAccountId(id)} '), id);
      // Look-alikes read as what they look like.
      expect(normalizeAccountId('OIL0-0000-0000-000U'), '011000000000000V');
      expect(normalizeAccountId('ABCD'), isNull);
      expect(normalizeAccountId('ABCD-EFGH-JKMN-PQR!'), isNull);
      expect(maskAccountId(id), endsWith(id.substring(12)));
      expect(maskAccountId(id), isNot(contains(id.substring(0, 4))));
    });
  });

  group('a hidden account', () {
    test('is in no list, and nothing on the disk or in the secret store '
        'shows its ID', () async {
      await registry.prepare();
      final int decoys = (await accountFolders()).length;
      expect(decoys, greaterThanOrEqualTo(ZenAccountRegistry.minDecoys));

      final ZenAccountScope hidden = await registry.create();
      final String id = hidden.id!;
      expect(await registry.listed(), isEmpty);
      expect(await registry.isListed(hidden), isFalse);

      // Its data, as the app writes it there.
      ZenAccounts.activate(hidden);
      final Directory home = await ZenInstance.supportDirectory();
      await secrets.write(appSecurityPasswordHashStorageKey, 'x');
      await Directory('${home.path}/settings').create(recursive: true);

      final List<String> folders = await accountFolders();
      expect(folders, hasLength(decoys + 1));
      // Every folder looks the same: 32 hex digits, none the ID's.
      for (final String name in folders) {
        expect(name, matches(RegExp(r'^[0-9a-f]{32}$')));
      }
      final String disk = everything(base);
      for (final String form in <String>[
        id,
        id.toLowerCase(),
        formatAccountId(id),
      ]) {
        expect(disk.contains(form), isFalse);
        expect(
          keychain.items.keys.any((String k) => k.contains(form)),
          isFalse,
        );
        expect(
          keychain.items.values.any((String v) => v.contains(form)),
          isFalse,
        );
      }
      // Its secret-store entries carry no name a reader could tell apart.
      expect(
        keychain.items.keys.where((String k) => k.startsWith('zen_x_')),
        isNotEmpty,
      );
      expect(
        keychain.items.containsKey(appSecurityPasswordHashStorageKey),
        isFalse,
      );
    });

    test('opens by its ID only, on this device only', () async {
      final ZenAccountScope hidden = await registry.create();
      final String id = hidden.id!;
      expect(await registry.find(id), hidden);
      expect(await registry.find(formatAccountId(id).toLowerCase()), hidden);
      expect(await registry.find(newAccountId(Random(7))), isNull);
      expect(await registry.find('nie-id'), isNull);

      // Another device (another salt) does not know it.
      final Directory other = await Directory.systemTemp.createTemp('zen-o-');
      addTearDown(() => other.delete(recursive: true));
      final ZenAccountRegistry elsewhere = ZenAccountRegistry(
        instanceDirectory: () async => other,
        secrets: secrets,
      );
      expect(await elsewhere.find(id), isNull);
    });
  });

  test(
    'the list setting shows an account by name, without typing its ID',
    () async {
      final ZenAccountScope a = await registry.create();
      final ZenAccountScope b = await registry.create(
        listed: true,
        name: 'Ola',
      );
      expect(
        (await registry.listed()).map((ZenListedAccount x) => x.id),
        <String>[b.id!],
      );
      expect((await registry.listed()).single.name, 'Ola');
      expect(await registry.scopeOf((await registry.listed()).single), b);

      await registry.setListed(a, listed: true, name: 'Praca');
      expect(await registry.isListed(a), isTrue);
      await registry.rename(a, 'Praca 2');
      expect(
        (await registry.listed())
            .firstWhere((ZenListedAccount x) => x.id == a.id)
            .name,
        'Praca 2',
      );
      await registry.setListed(b, listed: false);
      expect(await registry.isListed(b), isFalse);
      expect(
        (await registry.listed()).map((ZenListedAccount x) => x.id),
        <String>[a.id!],
      );
      // The default account is always there, never on the list.
      expect(await registry.isListed(ZenAccountScope.defaultAccount), isTrue);
    },
  );

  test('accounts are separate people: own folders, own secrets', () async {
    final ZenAccountScope a = await registry.create();
    final ZenAccountScope b = await registry.create();

    final Directory defaultHome = await ZenInstance.supportDirectory();
    expect(defaultHome.path, base.path);
    await secrets.write('zen_rewrite_test', 'default');

    ZenAccounts.activate(a);
    final Directory aHome = await ZenInstance.supportDirectory();
    expect(aHome.path, isNot(defaultHome.path));
    expect(aHome.path, startsWith(base.path));
    expect(await secrets.read('zen_rewrite_test'), isNull);
    await secrets.write('zen_rewrite_test', 'a');

    ZenAccounts.activate(b);
    final Directory bHome = await ZenInstance.supportDirectory();
    expect(bHome.path, isNot(aHome.path));
    expect(await secrets.read('zen_rewrite_test'), isNull);
    await secrets.write('zen_rewrite_test', 'b');

    ZenAccounts.activate(ZenAccountScope.defaultAccount);
    expect(await secrets.read('zen_rewrite_test'), 'default');
    expect(await secrets.forAccount(a.secret).read('zen_rewrite_test'), 'a');
    expect(await secrets.forAccount(b.secret).read('zen_rewrite_test'), 'b');
    // The device's own entries are never an account's.
    ZenAccounts.activate(a);
    expect(await secrets.forDevice().read('zen_rewrite_test'), 'default');
  });

  test("switching back and forth keeps each account's data", () async {
    final ZenAccountScope a = await registry.create();
    final ZenAccountScope b = await registry.create();
    final BinaryCodec codec = BinaryCodec(compressor: const _PassThrough());

    Future<ZenPersistentStores> open(ZenAccountScope scope) async {
      ZenAccounts.activate(scope);
      return buildZenPersistentStoresForDirectory(
        await ZenInstance.supportDirectory(),
        codec: codec,
      );
    }

    await (await open(
      ZenAccountScope.defaultAccount,
    )).userProfileStore.save(const UserProfile(displayName: 'Domyślna'));
    await (await open(
      a,
    )).userProfileStore.save(const UserProfile(displayName: 'Ania'));
    await (await open(
      b,
    )).userProfileStore.save(const UserProfile(displayName: 'Basia'));

    expect(
      (await (await open(a)).userProfileStore.load())!.displayName,
      'Ania',
    );
    expect(
      (await (await open(
        ZenAccountScope.defaultAccount,
      )).userProfileStore.load())!.displayName,
      'Domyślna',
    );
    expect(
      (await (await open(b)).userProfileStore.load())!.displayName,
      'Basia',
    );
  });

  group('opening another account', () {
    test(
      'its own password opens it; the same password may serve two',
      () async {
        final ZenAccountScope a = await registry.create();
        final ZenAccountScope b = await registry.create();
        for (final ZenAccountScope scope in <ZenAccountScope>[a, b]) {
          final AppSecurityService s = securityFor(scope);
          await s.initialize(settings: const AppSettings());
          await s.setPassword('wspolne-haslo');
        }
        final AppSecurityService ownA = securityFor(a);
        await ownA.initialize(settings: const AppSettings());
        await ownA.setPanicPassword('alarm-alarm');

        ZenAccountUnlockResult result = await unlockZenAccount(
          a,
          'zle-haslo-123',
          registry: registry,
          security: securityFor,
        );
        expect(result.outcome, ZenAccountUnlock.refused);
        expect(result.security, isNull);

        result = await unlockZenAccount(
          b,
          'wspolne-haslo',
          registry: registry,
          security: securityFor,
        );
        expect(result.outcome, ZenAccountUnlock.opened);
        expect(result.security!.isUnlocked, isTrue);
        expect(await result.security!.currentEncryptionKey(), isNotNull);

        // The panic password of an account wipes that account only.
        result = await unlockZenAccount(
          a,
          'alarm-alarm',
          registry: registry,
          security: securityFor,
        );
        expect(result.outcome, ZenAccountUnlock.wiped);
        expect(await registry.find(a.id!), isNull);
        expect(await registry.find(b.id!), b);
      },
    );

    test('an ID that is not on this device costs the same work as a wrong '
        'password and gets the same answer', () async {
      final ZenAccountScope a = await registry.create();
      final AppSecurityService own = securityFor(a);
      await own.initialize(settings: const AppSettings());
      await own.setPassword('haslo-konta-a');
      await own.setPanicPassword('alarm-alarm');
      final List<PasswordCost> costs = <PasswordCost>[];
      debugOnPasswordDerivation = costs.add;
      addTearDown(() => debugOnPasswordDerivation = null);

      Future<List<PasswordCost>> attempt(
        String typed, {
        ZenAccountScope current = ZenAccountScope.defaultAccount,
      }) async {
        costs.clear();
        final ZenAccountUnlockResult result = await unlockOtherZenAccount(
          typed: typed,
          password: 'zle-haslo-123',
          current: current,
          registry: registry,
          security: securityFor,
        );
        expect(result.outcome, ZenAccountUnlock.refused);
        expect(result.security, isNull);
        return List<PasswordCost>.of(costs);
      }

      final List<PasswordCost> wrongPassword = await attempt(a.id!);
      expect(wrongPassword, hasLength(2));
      expect(await attempt(newAccountId(Random(99))), wrongPassword);
      expect(await attempt('nie-id'), wrongPassword);
      // The account open now is not opened again, at the same cost.
      expect(await attempt(a.id!, current: a), wrongPassword);
      expect(await registry.find(a.id!), a);

      costs.clear();
      final ZenAccountUnlockResult right = await unlockOtherZenAccount(
        typed: formatAccountId(a.id!),
        password: 'haslo-konta-a',
        current: ZenAccountScope.defaultAccount,
        registry: registry,
        security: securityFor,
      );
      expect(right.outcome, ZenAccountUnlock.opened);
      expect(right.scope, a);
      expect(costs, hasLength(2));
    });

    test('a wrong ID makes the same calls to the secret store, of the same '
        'kinds and in the same order, with the derivations in the same '
        'places, as a wrong password for an account that is there', () async {
      // Each call to the system's secret store costs time of its own (on a
      // computer it reads and decrypts the whole store): a count that
      // differs tells whether an ID exists.
      final List<String> calls = <String>[];
      final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
        _MemoryKeychain(calls, 'keychain'),
        _MemoryKeychain(calls, 'earlier keychain'),
      );
      final ZenAccountRegistry accounts = ZenAccountRegistry(
        instanceDirectory: () async => base,
        secrets: store,
        random: Random(7),
      );
      AppSecurityService securityOf(ZenAccountScope scope) =>
          LocalAppSecurityService(
            credentialsStore: store.forAccount(scope.secret),
            passwordIterations: 10,
            keyVault: const SharedKeyVault(NoKeyVault()),
          );
      final ZenAccountScope plain = await accounts.create();
      final ZenAccountScope withPanic = await accounts.create();
      for (final ZenAccountScope scope in <ZenAccountScope>[plain, withPanic]) {
        final AppSecurityService own = securityOf(scope);
        await own.initialize(settings: const AppSettings());
        await own.setPassword('haslo-konta');
        if (scope == withPanic) {
          await own.setPanicPassword('alarm-alarm');
        }
      }
      final UnlockThrottle guesses = UnlockThrottle.otherAccounts(
        store: store.forDevice(),
        monotonic: () => Duration.zero,
      );
      debugOnPasswordDerivation = (PasswordCost cost) =>
          calls.add('derivation ${cost.memoryKiB}');
      addTearDown(() {
        debugOnPasswordDerivation = null;
        debugDefaultTargetPlatformOverride = null;
        SecureStorageCredentialsStore.debugForgetKeychainMove();
      });

      Future<List<String>> attempt(
        String typed, {
        ZenAccountScope current = ZenAccountScope.defaultAccount,
      }) async {
        // Each attempt from a count of none.
        await guesses.clear();
        calls.clear();
        final ZenAccountUnlockResult result = await unlockOtherZenAccount(
          typed: typed,
          password: 'zle-haslo-123',
          current: current,
          registry: accounts,
          security: securityOf,
          throttle: guesses,
        );
        expect(result.outcome, ZenAccountUnlock.refused);
        return List<String>.of(calls);
      }

      for (final TargetPlatform? platform in <TargetPlatform?>[
        null,
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        SecureStorageCredentialsStore.debugForgetKeychainMove();
        // iOS moves its items once per start, before anything else.
        await store.read('zen_rewrite_warm_up');
        final List<String> there = await attempt(plain.id!);
        expect(
          there.where((String c) => c.startsWith('derivation')),
          hasLength(2),
        );
        expect(there.where((String c) => c.contains('read')), isNotEmpty);
        final Map<String, List<String>> others = <String, List<String>>{
          'with an emergency wipe password': await attempt(withPanic.id!),
          'a wrong ID': await attempt(newAccountId(Random(99))),
          'not an ID': await attempt('nie-id'),
          'the account open now': await attempt(plain.id!, current: plain),
        };
        others.forEach((String what, List<String> seen) {
          expect(seen, there, reason: '$what ($platform)');
        });
      }
    });

    test('a guess at another account is counted before its password is '
        'checked: Zen closed during the check leaves it counted', () async {
      final ZenAccountScope a = await registry.create();
      final AppSecurityService own = securityFor(a);
      await own.initialize(settings: const AppSettings());
      await own.setPassword('haslo-konta-a');
      UnlockThrottle started() => UnlockThrottle.otherAccounts(
        store: secrets.forDevice(),
        monotonic: () => Duration.zero,
      );
      String? count() => keychain.items[UnlockThrottle.otherAccountsStorageKey];
      addTearDown(() => debugOnPasswordDerivation = null);

      // Zen closed as the first derivation starts.
      debugOnPasswordDerivation = (PasswordCost _) =>
          throw StateError('Zen was closed');
      for (final String typed in <String>[a.id!, newAccountId(Random(3))]) {
        await expectLater(
          unlockOtherZenAccount(
            typed: typed,
            password: 'zgadywane',
            current: ZenAccountScope.defaultAccount,
            registry: registry,
            security: securityFor,
            throttle: started(),
          ),
          throwsStateError,
        );
      }
      expect(count(), startsWith('2;'));

      // The right password: counted during its check, then taken back, the
      // entry as it was.
      final List<String?> duringCheck = <String?>[];
      debugOnPasswordDerivation = (PasswordCost _) => duringCheck.add(count());
      final String? before = count();
      final ZenAccountUnlockResult right = await unlockOtherZenAccount(
        typed: a.id!,
        password: 'haslo-konta-a',
        current: ZenAccountScope.defaultAccount,
        registry: registry,
        security: securityFor,
        throttle: started(),
      );
      expect(right.outcome, ZenAccountUnlock.opened);
      expect(duringCheck, hasLength(2));
      expect(duringCheck, everyElement(startsWith('3;')));
      expect(count(), before);
    });

    test('guesses at another account are counted for the device, apart '
        'from the lock screen, and no unlock clears the count', () async {
      final ZenAccountScope a = await registry.create();
      final AppSecurityService own = securityFor(a);
      await own.initialize(settings: const AppSettings());
      await own.setPassword('haslo-konta-a');
      Duration steady = Duration.zero;
      final UnlockThrottle guesses = UnlockThrottle.otherAccounts(
        store: secrets.forDevice(),
        monotonic: () => steady,
      );
      final UnlockThrottle lockScreen = UnlockThrottle(
        secrets.forAccount(null),
        monotonic: () => steady,
      );

      Future<ZenAccountUnlock> attempt(String typed, String password) async =>
          (await unlockOtherZenAccount(
            typed: typed,
            password: password,
            current: ZenAccountScope.defaultAccount,
            registry: registry,
            security: securityFor,
            throttle: guesses,
          )).outcome;

      for (int i = 0; i < UnlockThrottle.freeFailures; i++) {
        expect(
          await attempt(newAccountId(Random(i)), 'zgadywane'),
          ZenAccountUnlock.refused,
        );
      }
      // The right password waits too, and the lock screen's own count
      // (cleared by unlocking the default account) is another one.
      expect(await attempt(a.id!, 'haslo-konta-a'), ZenAccountUnlock.throttled);
      await lockScreen.recordFailure();
      await lockScreen.clear();
      expect(await guesses.remaining(), UnlockThrottle.baseDelay);
      // The device's entry names no account.
      expect(
        keychain.items.keys,
        contains(UnlockThrottle.otherAccountsStorageKey),
      );

      steady += UnlockThrottle.baseDelay;
      expect(await attempt(a.id!, 'haslo-konta-a'), ZenAccountUnlock.opened);
      // Opening an account cleared nothing: the next wrong guess waits
      // longer at once.
      expect(
        await attempt(newAccountId(Random(50)), 'zgadywane'),
        ZenAccountUnlock.refused,
      );
      expect(await guesses.remaining(), UnlockThrottle.baseDelay * 2);
    });

    test('an account whose first start was cut short opens to set a '
        'password', () async {
      final ZenAccountScope a = await registry.create();
      final ZenAccountUnlockResult result = await unlockZenAccount(
        a,
        'cokolwiek',
        registry: registry,
        security: securityFor,
      );
      expect(result.outcome, ZenAccountUnlock.opened);
      expect(result.security!.hasPassword, isFalse);
    });
  });

  test('"Nigdy" keeps each account\'s own key, and an additional account '
      'never opens by itself', () async {
    const AppSettings never = AppSettings(lockMode: AppLockMode.never);
    final ZenAccountScope a = await registry.create();
    final AppSecurityService main = securityFor(ZenAccountScope.defaultAccount);
    await main.initialize(settings: const AppSettings());
    await main.setPassword('haslo-glowne');
    await main.applySettings(never);
    expect(await main.keepMasterKeyForNeverLock('haslo-glowne'), isTrue);
    final AppSecurityService other = securityFor(a);
    await other.initialize(settings: const AppSettings());
    await other.setPassword('haslo-konta-a');
    await other.applySettings(never);
    expect(await other.keepMasterKeyForNeverLock('haslo-konta-a'), isTrue);

    // One account's copy is not the other's, and neither is the other key.
    final String? mainCopy = await secrets
        .forAccount(null)
        .read(appSecurityNeverLockMasterKeyStorageKey);
    final String? otherCopy = await secrets
        .forAccount(a.secret)
        .read(appSecurityNeverLockMasterKeyStorageKey);
    expect(mainCopy, isNotNull);
    expect(otherCopy, isNotNull);
    expect(otherCopy, isNot(mainCopy));
    expect(
      keychain.items.containsKey(appSecurityNeverLockMasterKeyStorageKey),
      isTrue,
    );
    expect(
      keychain.items.keys.where(
        (String name) =>
            name.contains('never_lock') &&
            name != appSecurityNeverLockMasterKeyStorageKey,
      ),
      isEmpty,
      reason: 'an additional account\'s entry names say nothing',
    );

    // Leaving "Nigdy" on the default account leaves the other one alone.
    await main.applySettings(const AppSettings());
    expect(
      await secrets
          .forAccount(null)
          .read(appSecurityNeverLockMasterKeyStorageKey),
      isNull,
    );
    expect(
      await secrets
          .forAccount(a.secret)
          .read(appSecurityNeverLockMasterKeyStorageKey),
      otherCopy,
    );

    // Another account is only ever opened by its ID and password: the copy
    // opens nothing there (and goes).
    ZenAccountUnlockResult result = await unlockZenAccount(
      a,
      'zle-haslo-123',
      registry: registry,
      security: securityFor,
    );
    expect(result.outcome, ZenAccountUnlock.refused);
    expect(
      await secrets
          .forAccount(a.secret)
          .read(appSecurityNeverLockMasterKeyStorageKey),
      isNull,
    );
    result = await unlockZenAccount(
      a,
      'haslo-konta-a',
      registry: registry,
      security: securityFor,
    );
    expect(result.outcome, ZenAccountUnlock.opened);
  });

  test(
    'the app root opens the asked account with its checked password',
    () async {
      final ZenAccountScope a = await registry.create();
      final AppSecurityService checked = securityFor(a);
      await checked.initialize(settings: const AppSettings());
      await checked.setPassword('haslo-konta-a');
      final ZenAccountHost host = ZenAccountHost();
      int heard = 0;
      host.addListener(() => heard++);
      host.begin();
      expect(host.switching, isTrue);
      host.request(ZenAccountOpening(scope: a, security: checked));
      expect(heard, 1);
      final ZenAccountOpening opening = host.take()!;
      expect(host.take(), isNull);

      final ZenBootstrapper bootstrapper = ZenBootstrapper(
        supportDirectoryLoader: () async => base,
        opening: opening,
      );
      final AppSecurityService security = await bootstrapper.initSecurity(
        settings: const AppSettings(),
      );
      expect(security, same(checked));
      expect(security.isUnlocked, isTrue);
      host.settled();
      expect(host.switching, isFalse);
    },
  );

  group('wiping', () {
    test(
      'one account goes whole; the others and the decoy count stay',
      () async {
        await registry.prepare();
        final ZenAccountScope a = await registry.create(
          listed: true,
          name: 'A',
        );
        final ZenAccountScope b = await registry.create();
        await secrets.forAccount(a.secret).write('zen_rewrite_one', '1');
        await secrets.forAccount(a.secret).write('zen_rewrite_two', '2');
        await secrets.forAccount(b.secret).write('zen_rewrite_one', 'b');
        await secrets.forAccount(null).write('zen_rewrite_one', 'default');
        ZenAccounts.activate(a);
        final Directory aHome = await ZenInstance.supportDirectory();
        await File('${aHome.path}/x.bin').writeAsBytes(<int>[1, 2, 3]);
        ZenAccounts.activate(ZenAccountScope.defaultAccount);
        final int folders = (await accountFolders()).length;
        final Set<String> entries = keychain.items.keys.toSet();
        final Set<String> ofA = <String>{
          for (final String key in <String>[
            'zen_rewrite_one',
            'zen_rewrite_two',
            '\u0000keys',
          ])
            SecureStorageCredentialsStore.scopedSecretName(a.secret, key),
        };

        await registry.wipeAccount(a);

        expect(await aHome.exists(), isFalse);
        expect(await registry.find(a.id!), isNull);
        expect(await registry.listed(), isEmpty);
        expect(
          await secrets.forAccount(a.secret).read('zen_rewrite_one'),
          isNull,
        );
        expect(
          await secrets.forAccount(a.secret).read('zen_rewrite_two'),
          isNull,
        );
        expect(await secrets.forAccount(b.secret).read('zen_rewrite_one'), 'b');
        expect(
          await secrets.forAccount(null).read('zen_rewrite_one'),
          'default',
        );
        expect(await registry.find(b.id!), b);
        // A's two entries, its key list and the (now empty) list of listed
        // accounts are gone; a decoy took its folder's place, with entries
        // of its own like an account's.
        expect(keychain.items.keys.toSet().intersection(ofA), isEmpty);
        expect(
          keychain.items.containsKey(ZenAccountRegistry.listedStorageKey),
          isFalse,
        );
        final Set<String> added = keychain.items.keys.toSet().difference(
          entries,
        );
        expect(added, isNotEmpty);
        expect(added, everyElement(matches(RegExp(r'^zen_x_[0-9a-f]{40}$'))));
        expect((await accountFolders()).length, folders);
      },
    );

    test('the device wipe deletes every account\'s secrets', () async {
      final ZenAccountScope a = await registry.create(listed: true, name: 'A');
      final ZenAccountScope b = await registry.create();
      await secrets.forAccount(a.secret).write('zen_rewrite_one', '1');
      await secrets.forAccount(b.secret).write('zen_rewrite_one', '2');
      await secrets
          .forAccount(null)
          .write(appSecurityPasswordHashStorageKey, 'h');
      keychain.items['someone_else'] = 'keep';

      await secrets.deleteEverything();

      expect(keychain.items, <String, String>{'someone_else': 'keep'});
    });
  });
}

final class _MemoryKeychain implements SecureKeyValueBackend {
  /// With [calls]: every call is noted there as `<name> <kind>`.
  _MemoryKeychain([this.calls, this.name = 'keychain']);

  final Map<String, String> items = <String, String>{};
  final List<String>? calls;
  final String name;

  @override
  Future<String?> read(String key) async {
    calls?.add('$name read');
    return items[key];
  }

  @override
  Future<void> write(String key, String value) async {
    calls?.add('$name write');
    items[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    calls?.add('$name delete');
    items.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    calls?.add('$name read all');
    return Map<String, String>.of(items);
  }
}

final class _PassThrough implements BinaryCompressor {
  const _PassThrough();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
