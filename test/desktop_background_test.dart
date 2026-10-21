import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/account/multi/desktop_background.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';

/// A computer's tray: the node config under the background key while
/// "Odbieraj w tle" is on (and back under the master key when off), the
/// tray's nodes, and the files an account exported going with it.
void main() {
  late Directory base;
  late _MemoryKeychain keychain;
  late SecureStorageCredentialsStore secrets;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zen-tray-');
    keychain = _MemoryKeychain();
    secrets = SecureStorageCredentialsStore.device(keychain, keychain);
  });

  tearDown(() => base.delete(recursive: true));

  Future<File> nodeConfig(Directory support, Uint8List sealed) async {
    final File file = File('${support.path}/runtime/yggdrasil.config.json');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(sealed);
    return file;
  }

  test('the node config is sealed again when the switch flips, and opens '
      'either way meanwhile', () async {
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      passwordIterations: 10,
    );
    final KeyedBinaryPayloadProtector master = EncryptedBinaryPayloadProtector(
      security,
    );
    final KeyedBinaryPayloadProtector background = BackgroundKeyProtector(
      security.credentialsStore,
      createKey: true,
    );
    final Uint8List plain = Uint8List.fromList(utf8.encode('{"key":"x"}'));
    final File file = await nodeConfig(
      base,
      await master.sealFor(kNodeConfigStorageKey, plain),
    );

    await applyDesktopBackgroundSetting(
      account: ZenAccountScope.defaultAccount,
      on: true,
      security: security,
      support: base,
    );
    Uint8List stored = await file.readAsBytes();
    expect(background.isSealed(stored), isTrue);
    expect(master.isSealed(stored), isFalse);
    // What the tray opens without the password.
    expect(
      await BackgroundKeyProtector(
        security.credentialsStore,
      ).unsealFor(kNodeConfigStorageKey, stored),
      plain,
    );
    expect(await File('${file.path}.bak').readAsBytes(), stored);
    // The app opens it whichever way it was sealed.
    expect(
      await FallbackKeyedProtector(
        master,
        background,
      ).unsealFor(kNodeConfigStorageKey, stored),
      plain,
    );

    // Something the background node kept, then the switch goes off.
    final Directory kept = Directory('${base.path}/background');
    await kept.create(recursive: true);
    await File('${kept.path}/capability.zenbg').writeAsBytes(<int>[1]);
    await applyDesktopBackgroundSetting(
      account: ZenAccountScope.defaultAccount,
      on: false,
      security: security,
      support: base,
    );
    stored = await file.readAsBytes();
    expect(master.isSealed(stored), isTrue);
    expect(await master.unsealFor(kNodeConfigStorageKey, stored), plain);
    expect(await kept.exists(), isFalse);
    expect(
      await security.credentialsStore.read(appSecurityBackgroundKeyStorageKey),
      isNull,
    );
  });

  test('the tray runs no node for an account with nothing published', () async {
    final ZenAccountRegistry registry = ZenAccountRegistry(
      instanceDirectory: () async => base,
      secrets: secrets,
    );
    final ZenBackgroundAccounts settings = ZenBackgroundAccounts(
      registry: registry,
      secrets: secrets,
    );
    final ZenAccountScope a = await registry.create();
    await secrets
        .forAccount(a.secret)
        .write(appSecurityBackgroundKeyStorageKey, 'ab' * 32);
    await settings.setOn(a, true);
    final DesktopBackgroundAccounts tray = DesktopBackgroundAccounts();
    await tray.update(
      open: ZenAccountScope.defaultAccount,
      openUnlocked: false,
      notices: MemoryRuntimeSystemNotificationService(),
      settings: settings,
      instanceDirectory: () async => base,
      secrets: secrets,
    );
    expect(tray.running, 0);
    await tray.stop();
  });

  group('exported files', () {
    test("wiping an account deletes its exports, hidden ones too, and "
        "leaves the others'", () async {
      final ZenAccountRegistry registry = ZenAccountRegistry(
        instanceDirectory: () async => base,
        secrets: secrets,
      );
      final ZenAccountScope hidden = await registry.create();
      final ZenAccountScope other = await registry.create();
      final File fromHidden = File('${base.path}/eksport-a.pdf')
        ..writeAsBytesSync(<int>[1]);
      final File fromOther = File('${base.path}/eksport-b.pdf')
        ..writeAsBytesSync(<int>[2]);
      await ExportedFilesIndex(
        secrets.forAccount(hidden.secret),
        secrets.forDevice(),
      ).remember(fromHidden.path);
      await ExportedFilesIndex(
        secrets.forAccount(other.secret),
        secrets.forDevice(),
      ).remember(fromOther.path);
      // The device's list names no account.
      final String device = keychain.items[kExportedFilesDeviceStorageKey]!;
      expect(device.contains(hidden.id!), isFalse);

      await registry.wipeAccount(hidden);

      expect(fromHidden.existsSync(), isFalse);
      expect(fromOther.existsSync(), isTrue);
      expect(
        keychain.items[kExportedFilesDeviceStorageKey],
        isNot(contains('eksport-a')),
      );
    });

    test('the device wipe deletes every account\'s exports without knowing '
        'the accounts', () async {
      final File a = File('${base.path}/a.webm')..writeAsBytesSync(<int>[1]);
      final File b = File('${base.path}/b.webm')..writeAsBytesSync(<int>[2]);
      await ExportedFilesIndex(
        secrets.forAccount(Uint8List(32)..[0] = 1),
        secrets.forDevice(),
      ).remember(a.path);
      await ExportedFilesIndex(
        secrets.forAccount(null),
        secrets.forDevice(),
      ).remember(b.path);

      expect(await ExportedFilesIndex.deleteEveryAccount(secrets), 2);

      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isFalse);
      expect(
        keychain.items.containsKey(kExportedFilesDeviceStorageKey),
        isFalse,
      );
    });

    test('an index without the device list still works', () async {
      final File a = File('${base.path}/c.txt')..writeAsBytesSync(<int>[1]);
      final ExportedFilesIndex index = ExportedFilesIndex(
        MemorySecurityCredentialsStore(),
        null,
      );
      await index.remember(a.path);
      expect(await index.paths(), <String>[a.path]);
      expect(await index.deleteAll(), 1);
      expect(a.existsSync(), isFalse);
    });
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
