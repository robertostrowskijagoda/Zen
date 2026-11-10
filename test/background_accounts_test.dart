import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// "Odbieraj w tle" per account: on for the default account, off for the
/// others until turned on; the list the background service reads names no
/// account and always has the same length; another account's
/// notifications say nothing about it.
void main() {
  late Directory base;
  late _MemoryKeychain keychain;
  late SecureStorageCredentialsStore secrets;
  late ZenAccountRegistry registry;
  late ZenBackgroundAccounts background;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zen-background-');
    keychain = _MemoryKeychain();
    secrets = SecureStorageCredentialsStore.device(keychain, keychain);
    registry = ZenAccountRegistry(
      instanceDirectory: () async => base,
      secrets: secrets,
      random: Random(3),
    );
    background = ZenBackgroundAccounts(
      registry: registry,
      secrets: secrets,
      random: Random(4),
    );
  });

  tearDown(() => base.delete(recursive: true));

  /// What the app writes for an opened account: its background key.
  Future<void> opened(ZenAccountScope scope) => secrets
      .forAccount(scope.secret)
      .write(appSecurityBackgroundKeyStorageKey, 'ab' * 32);

  Map<String, dynamic> stored() =>
      jsonDecode(keychain.items[ZenBackgroundAccounts.storageKey]!)
          as Map<String, dynamic>;

  test(
    'only the default account receives in the background at first',
    () async {
      final ZenAccountScope a = await registry.create();
      expect(await background.isOn(ZenAccountScope.defaultAccount), isTrue);
      expect(await background.isOn(a), isFalse);
      final ZenBackgroundAccountList list = await background.load();
      expect(list.defaultOn, isTrue);
      expect(list.additional, isEmpty);
    },
  );

  test('an account turned on is in a list of fixed length that names no '
      'account', () async {
    await registry.prepare();
    final ZenAccountScope a = await registry.create();
    final ZenAccountScope b = await registry.create();
    await opened(a);
    await opened(b);

    expect(await background.setOn(a, true), isTrue);
    expect(await background.isOn(a), isTrue);
    expect(await background.isOn(b), isFalse);
    expect(await background.setOn(b, true), isTrue);
    expect(await background.isOn(a), isTrue);
    expect(await background.isOn(b), isTrue);

    final List<dynamic> entries = stored()['a'] as List<dynamic>;
    expect(entries, hasLength(ZenBackgroundAccounts.slots));
    for (final Object? e in entries) {
      final Map<dynamic, dynamic> m = e! as Map<dynamic, dynamic>;
      expect(m.keys.toSet(), <String>{'f', 's', 'n'});
      expect(m['f'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(m['s'], matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    final String raw = keychain.items[ZenBackgroundAccounts.storageKey]!;
    for (final ZenAccountScope s in <ZenAccountScope>[a, b]) {
      expect(raw.contains(s.id!), isFalse);
    }
    // The service reads every entry; padding opens nothing.
    expect(
      (await background.load()).additional,
      hasLength(ZenBackgroundAccounts.slots),
    );

    expect(await background.setOn(a, false), isTrue);
    expect(await background.isOn(a), isFalse);
    expect(await background.isOn(b), isTrue);
    expect(
      stored()['a'] as List<dynamic>,
      hasLength(ZenBackgroundAccounts.slots),
    );

    // A wiped account drops out by itself (its key is gone).
    await registry.wipeAccount(b);
    final ZenAccountScope c = await registry.create();
    await opened(c);
    await background.setOn(c, true);
    expect(await background.isOn(c), isTrue);
    expect(await background.isOn(b), isFalse);
  });

  test('the emergency wipe password of an account that receives in the '
      'background takes it off the list and stops its node at once', () async {
    await registry.prepare();
    final ZenAccountScope a = await registry.create();
    final AppSecurityService security = LocalAppSecurityService(
      credentialsStore: secrets.forAccount(a.secret),
      passwordIterations: 10,
      keyVault: const SharedKeyVault(NoKeyVault()),
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('haslo-konta-a');
    await security.setPanicPassword('alarm-alarm');
    await opened(a);
    expect(await background.setOn(a, true), isTrue);
    final Directory accounts = await registry.accountsDirectory();
    final int folders = accounts.listSync().whereType<Directory>().length;
    int stopped = 0;
    BackgroundAccountRuns.add(a.folder!, () async => stopped++);

    final ZenAccountUnlockResult result = await unlockZenAccount(
      a,
      'alarm-alarm',
      registry: registry,
      security: (ZenAccountScope s) => LocalAppSecurityService(
        credentialsStore: secrets.forAccount(s.secret),
        passwordIterations: 10,
        keyVault: const SharedKeyVault(NoKeyVault()),
      ),
    );

    expect(result.outcome, ZenAccountUnlock.wiped);
    expect(stopped, 1);
    expect(await background.isOn(a), isFalse);
    expect(
      (stored()['a'] as List<dynamic>).where(
        (Object? e) => (e! as Map<dynamic, dynamic>)['f'] == a.folder,
      ),
      isEmpty,
    );
    expect(await Directory('${accounts.path}/${a.folder}').exists(), isFalse);
    expect(accounts.listSync().whereType<Directory>(), hasLength(folders));
  });

  test('a node whose account is gone stops by itself and takes away what '
      'it wrote again; an account turned off keeps its folder', () async {
    final ZenAccountScope a = await registry.create();
    await opened(a);
    final Directory folder = Directory(
      '${(await registry.accountsDirectory()).path}/${a.folder}',
    );
    int stopped = 0;
    final BackgroundAccountWatch watch = BackgroundAccountWatch(
      folder: folder,
      credentials: secrets.forAccount(a.secret),
      onGone: () async => stopped++,
      every: const Duration(hours: 1),
    )..start();
    expect(await watch.check(), isFalse);
    expect(stopped, 0);

    // Wiped (keys first, then the folder), and the node wrote into its
    // inbox once more before it noticed.
    await secrets.forAccount(a.secret).deleteAccountEntries();
    await File('${folder.path}/background/inbox.zbox').create(recursive: true);
    expect(await watch.check(), isTrue);
    expect(stopped, 1);
    expect(await folder.exists(), isFalse);

    // "Odbieraj w tle" turned off: the node stops, the account stays.
    final ZenAccountScope b = await registry.create();
    await opened(b);
    final Directory home = Directory(
      '${(await registry.accountsDirectory()).path}/${b.folder}',
    );
    await File('${home.path}/data/user_profile.zenbin').create(recursive: true);
    final BackgroundAccountWatch other = BackgroundAccountWatch(
      folder: home,
      credentials: secrets.forAccount(b.secret),
      onGone: () async => stopped++,
    )..start();
    await secrets
        .forAccount(b.secret)
        .delete(appSecurityBackgroundKeyStorageKey);
    expect(await other.check(), isTrue);
    expect(stopped, 2);
    expect(await home.exists(), isTrue);
  });

  test('the default account can be turned off, and on again', () async {
    expect(
      await background.setOn(ZenAccountScope.defaultAccount, false),
      isTrue,
    );
    expect(await background.isOn(ZenAccountScope.defaultAccount), isFalse);
    expect((await background.load()).defaultOn, isFalse);
    await background.setOn(ZenAccountScope.defaultAccount, true);
    expect((await background.load()).defaultOn, isTrue);
  });

  test('at most a few additional accounts receive in the background', () async {
    final List<ZenAccountScope> accounts = <ZenAccountScope>[
      for (int i = 0; i <= ZenBackgroundAccounts.slots; i++)
        await registry.create(),
    ];
    for (final ZenAccountScope s in accounts) {
      await opened(s);
    }
    for (int i = 0; i < ZenBackgroundAccounts.slots; i++) {
      expect(await background.setOn(accounts[i], true), isTrue);
    }
    expect(await background.setOn(accounts.last, true), isFalse);
    expect(await background.isOn(accounts.last), isFalse);
  });

  test('a padding entry, or an account with nothing published, opens no '
      'node', () async {
    final ZenAccountScope a = await registry.create();
    await opened(a);
    await background.setOn(a, true);
    final RuntimeSystemNotificationService notices =
        MemoryRuntimeSystemNotificationService();
    // Nothing published under the secret (no capability): no node.
    final List<BackgroundAccountNode> nodes =
        await BackgroundAccountNode.openAll(
          await background.load(),
          accounts: await registry.accountsDirectory(),
          notices: notices,
          secrets: secrets,
        );
    expect(nodes, isEmpty);
  });

  test("an account's notifications can be turned off, and its notices "
      'open that account', () async {
    await registry.prepare();
    final ZenAccountScope a = await registry.create();
    final ZenAccountScope b = await registry.create();
    await opened(a);
    await opened(b);
    await background.setOn(a, true);
    await background.setOn(b, true);
    expect(await background.notifies(a), isTrue, reason: 'on by default');
    await background.setNotify(a, false);
    expect(await background.notifies(a), isFalse);
    expect(await background.notifies(b), isTrue);
    expect(await background.isOn(a), isTrue, reason: 'still receives');
    // The list keeps its length whatever the bits say.
    expect(
      (await background.load()).additional,
      hasLength(ZenBackgroundAccounts.slots),
    );

    final MemoryRuntimeSystemNotificationService shade =
        MemoryRuntimeSystemNotificationService();
    await shade.initialize(onOpenRoute: (String _) async {});
    const RuntimeSystemNotification message = RuntimeSystemNotification(
      id: 'msg-ada',
      title: 'Ada',
      body: 'Hej',
      createdAtMillis: 1,
      category: RuntimeSystemNotificationCategory.message,
    );
    await GenericAccountNotices(
      shade,
      slot: 1,
      folder: a.folder,
      notify: false,
    ).show(message);
    expect(shade.activeNotifications, isEmpty);
    await GenericAccountNotices(shade, slot: 2, folder: b.folder).show(message);
    expect(
      shade.activeNotifications.single.routeKey,
      buildAccountRouteKey(b.folder!),
    );
    final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
      id: 'n',
      routeKey: buildAccountRouteKey(b.folder!),
    );
    expect(intent?.target, RuntimeRouteTarget.account);
    expect(intent?.rawInput, b.folder);
  });

  test("another account's notifications are generic", () async {
    final MemoryRuntimeSystemNotificationService shade =
        MemoryRuntimeSystemNotificationService();
    await shade.initialize(onOpenRoute: (String _) async {});
    final GenericAccountNotices notices = GenericAccountNotices(shade, slot: 2);
    await notices.show(
      const RuntimeSystemNotification(
        id: 'msg-ada',
        title: 'Ada',
        body: 'Spotkajmy się o 18',
        createdAtMillis: 1,
        category: RuntimeSystemNotificationCategory.message,
        routeKey: 'zen://chat/ada',
        slotKey: 'chat-ada',
      ),
    );
    final RuntimeSystemNotification shown = shade.activeNotifications.single;
    expect(shown.title, PrivacyRedactingNotificationService.genericTitle);
    expect(
      shown.body,
      PrivacyRedactingNotificationService.genericBodyFor(
        RuntimeSystemNotificationCategory.message,
      ),
    );
    // Without the account's folder it leads nowhere in particular.
    expect(shown.routeKey, isNull);
    expect(shown.id, isNot(contains('msg-ada')));
    expect(shown.slotKey, isNot(contains('chat-ada')));
    await notices.dismissSlot('chat-ada');
    expect(shade.activeNotifications, isEmpty);
  });
}

final class _MemoryKeychain implements SecureKeyValueBackend {
  final Map<String, String> items = <String, String>{};

  @override
  Future<String?> read(String key) async => items[key];

  @override
  Future<void> write(String key, String value) async {
    items[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    items.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.of(items);
}
