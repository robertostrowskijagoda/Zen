import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';

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
      expect(m.keys.toSet(), <String>{'f', 's'});
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
