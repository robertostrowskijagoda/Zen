import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The decoy folders beside the additional accounts: whoever lists the
/// folders (names, sizes) and the names of the secret store's entries
/// cannot tell a hidden account from them.
void main() {
  final List<Directory> made = <Directory>[];

  tearDown(() async {
    ZenAccounts.activate(ZenAccountScope.defaultAccount);
    ZenInstance.debugSetBaseDirectory(null);
    for (final Directory dir in made) {
      for (int i = 0; i < 10 && await dir.exists(); i++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
    made.clear();
  });

  Future<_Device> device(int seed) async {
    final Directory base = await Directory.systemTemp.createTemp('zen-d-');
    made.add(base);
    final _Keychain keychain = _Keychain();
    final SecureStorageCredentialsStore secrets = SecureStorageCredentialsStore(
      keychain,
      keychain,
    );
    final ZenAccountRegistry registry = ZenAccountRegistry(
      instanceDirectory: () async => base,
      secrets: secrets,
      random: Random(seed),
    );
    ZenInstance.debugSetBaseDirectory(base);
    await registry.prepare();
    return _Device(base, keychain, secrets, registry);
  }

  /// A hidden account used as the app uses one: a password, the settings
  /// (with their guarded copy), a sealed profile, its ledger identity
  /// (hidden name), the node's own files.
  Future<ZenAccountScope> useHiddenAccount(_Device d) async {
    final ZenAccountScope hidden = await d.registry.create();
    ZenAccounts.activate(hidden);
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: d.secrets.forAccount(hidden.secret),
      passwordIterations: 10,
      keyVault: const SharedKeyVault(NoKeyVault()),
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('hidden-password-1');
    final Directory home = await ZenInstance.supportDirectory();
    final BinaryCodec codec = BinaryCodec(compressor: const _PassThrough());
    final ZenPersistentStores stores = buildZenPersistentStoresForDirectory(
      home,
      codec: codec,
      dataProtector: EncryptedBinaryPayloadProtector(security),
      appSettingsStore: buildZenAppSettingsStoreForDirectory(
        home,
        codec: codec,
        secrets: d.secrets.forAccount(hidden.secret),
      ),
    );
    await stores.userProfileStore.save(const UserProfile(displayName: 'x'));
    await stores.ledgerDisk.write(
      'ledger/identity',
      Uint8List.fromList(List<int>.filled(400, 7)),
    );
    await stores.appSettingsStore.save(
      const AppSettings(themeMode: AppThemeMode.dark),
    );
    // What the node writes there (there is no Go bridge in tests).
    final Random random = Random(7);
    for (final (String name, int size) in <(String, int)>[
      ('yggdrasil.config.json', 912),
      ('public_peers.json', 1480),
    ]) {
      final File file = File('${home.path}/runtime/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(<int>[
        for (int i = 0; i < size; i++) random.nextInt(256),
      ]);
    }
    ZenAccounts.activate(ZenAccountScope.defaultAccount);
    return hidden;
  }

  test('a hidden account is not told from the decoys by the folders and '
      'the secret store', () async {
    final List<Map<String, int>> decoys = <Map<String, int>>[];
    final List<Map<String, int>> real = <Map<String, int>>[];
    final List<int> entriesOfDecoys = <int>[];
    final List<int> entriesOfReal = <int>[];
    for (int seed = 1; seed <= 10; seed++) {
      final _Device d = await device(seed);
      // A device with no other account has entries of the same kind.
      final int before = d.scopedEntries;
      final int decoyCount = (await d.folders()).length;
      expect(decoyCount, greaterThanOrEqualTo(ZenAccountRegistry.minDecoys));
      expect(before, greaterThan(0));
      entriesOfDecoys.add(before ~/ decoyCount);

      final ZenAccountScope hidden = await useHiddenAccount(d);
      entriesOfReal.add(d.scopedEntries - before);
      for (final String folder in await d.folders()) {
        (folder == hidden.folder ? real : decoys).add(await d.listing(folder));
      }
      // The names of the entries are all of one kind.
      expect(
        d.keychain.items.keys.where((String k) => k.startsWith('zen_x_')),
        everyElement(matches(RegExp(r'^zen_x_[0-9a-f]{40}$'))),
      );
      // The earlier tell: only the account had readable store names.
      final List<Map<String, int>> withStores = <Map<String, int>>[
        for (final String folder in await d.folders())
          if ((await d.listing(
            folder,
          )).keys.any((String n) => n.endsWith('.zenbin')))
            await d.listing(folder),
      ];
      expect(withStores.length, greaterThan(1));
    }

    for (final Map<String, int> account in real) {
      final Set<String> tells = _tellsOf(account);
      // Nothing the account has is rare among the decoys...
      for (final String tell in tells) {
        final int share = decoys
            .where((Map<String, int> d) => _tellsOf(d).contains(tell))
            .length;
        expect(share, greaterThan(decoys.length ~/ 10), reason: tell);
      }
      // ...and nothing most decoys have is missing from it.
      final Set<String> all = <String>{
        for (final Map<String, int> d in decoys) ..._tellsOf(d),
      };
      for (final String tell in all.difference(tells)) {
        final int share = decoys
            .where((Map<String, int> d) => _tellsOf(d).contains(tell))
            .length;
        expect(share, lessThan(decoys.length * 9 ~/ 10), reason: tell);
      }
      // Its number of files and its size are ones decoys have too.
      for (final int Function(Map<String, int>) measure
          in <int Function(Map<String, int>)>[
            (Map<String, int> l) => l.length,
            (Map<String, int> l) => l.values.fold(0, (int a, int b) => a + b),
          ]) {
        final int value = measure(account);
        expect(
          decoys.where((Map<String, int> d) => measure(d) <= value).length,
          greaterThan(decoys.length ~/ 20),
        );
        expect(
          decoys.where((Map<String, int> d) => measure(d) >= value).length,
          greaterThan(decoys.length ~/ 20),
        );
      }
    }
    // As many secret-store entries as an account has.
    for (final int count in entriesOfReal) {
      expect(count, inInclusiveRange(entriesOfDecoys.reduce(min) - 1, 99));
      expect(count, lessThanOrEqualTo(entriesOfDecoys.reduce(max) + 1));
    }
  });

  test('decoys an earlier version made get the look of today\'s at the '
      'next start, in place; an account stays exactly as it was', () async {
    final Directory base = await Directory.systemTemp.createTemp('zen-d-');
    made.add(base);
    final Directory accounts = Directory('${base.path}/accounts');
    await accounts.create(recursive: true);
    await File('${accounts.path}/salt').writeAsBytes(List<int>.filled(32, 3));
    final DateTime then = DateTime.now().subtract(const Duration(days: 40));
    final Random random = Random(11);
    String hex(int n) => <String>[
      for (int i = 0; i < n; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    // As 1.16.2 planted them: a few random `<24 hex>.bin` files.
    final List<String> earlier = <String>[hex(16), hex(16), hex(16)];
    for (final String name in earlier) {
      for (final String part in <String>['settings', 'data']) {
        final File file = File('${accounts.path}/$name/$part/${hex(12)}.bin');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(<int>[
          for (int i = 0; i < 900; i++) random.nextInt(256),
        ]);
        await file.setLastModified(then);
      }
    }
    // An account (of 1.16.2) next to them, and one whose start was cut
    // short (an empty folder).
    final String account = hex(16);
    final File profile = File('${accounts.path}/$account/data/x.zenbin');
    await profile.parent.create(recursive: true);
    await profile.writeAsBytes(<int>[1, 2, 3]);
    await profile.setLastModified(then);
    final String empty = hex(16);
    await Directory('${accounts.path}/$empty').create();

    final _Keychain keychain = _Keychain();
    final ZenAccountRegistry registry = ZenAccountRegistry(
      instanceDirectory: () async => base,
      secrets: SecureStorageCredentialsStore(keychain, keychain),
      random: Random(5),
    );
    await registry.prepare();

    final _Device d = _Device(
      base,
      keychain,
      SecureStorageCredentialsStore(keychain, keychain),
      registry,
    );
    expect(await d.folders(), hasLength(5));
    final DateTime now = DateTime.now().add(const Duration(seconds: 1));
    for (final String name in earlier) {
      final Map<String, int> listing = await d.listing(name);
      expect(listing.keys, isNot(contains(matches(RegExp(r'\.bin$')))));
      expect(listing.keys, contains(endsWith('.zenbin')));
      for (final FileSystemEntity e in Directory(
        '${accounts.path}/$name',
      ).listSync(recursive: true)) {
        if (e is File) {
          final DateTime at = e.lastModifiedSync();
          expect(at.isBefore(then.subtract(const Duration(seconds: 1))), false);
          expect(at.isAfter(now), isFalse);
        }
      }
    }
    expect(await d.listing(account), <String, int>{'data/x.zenbin': 3});
    expect(profile.lastModifiedSync(), then);
    expect(await d.listing(empty), isEmpty);
    // Their entries in the secret store, of the account kind.
    expect(d.scopedEntries, greaterThanOrEqualTo(3 * 7));

    // The next start plants nothing anew.
    final int entries = keychain.items.length;
    ZenAccountRegistry.debugStartAgain();
    await ZenAccountRegistry(
      instanceDirectory: () async => base,
      secrets: SecureStorageCredentialsStore(keychain, keychain),
      random: Random(6),
    ).prepare();
    expect(keychain.items.length, entries);
    for (final String name in earlier) {
      expect(
        (await d.listing(name)).keys.where((String n) => n.endsWith('.bin')),
        isEmpty,
      );
      expect((await d.listing(name)).length, greaterThanOrEqualTo(1));
    }
    expect(await d.listing(account), <String, int>{'data/x.zenbin': 3});
    expect(await d.folders(), hasLength(5));
  });

  test('decoys "used" now and then change as an account in use does; the '
      'others stay as they were made', () async {
    final _Device d = await device(21);
    final Map<String, DateTime> first = <String, DateTime>{
      for (final String folder in await d.folders())
        folder: await d.newest(folder),
    };
    final Set<String> used = d.usedDecoys();
    expect(used, isNotEmpty);
    expect(first.keys.toSet().containsAll(used), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    for (int start = 0; start < 12; start++) {
      ZenAccountRegistry.debugStartAgain();
      await ZenAccountRegistry(
        instanceDirectory: () async => d.base,
        secrets: d.secrets,
        random: Random(100 + start),
      ).prepare();
    }
    for (final String folder in first.keys) {
      final DateTime newest = await d.newest(folder);
      if (used.contains(folder)) {
        expect(newest.isAfter(first[folder]!), isTrue, reason: folder);
      } else {
        expect(newest, first[folder], reason: folder);
      }
    }
    expect(await d.folders(), hasLength(first.length));
  });
}

/// What a listing says of a folder: the paths with their random parts
/// (hex names) taken out, the extensions, the depth.
Set<String> _tellsOf(Map<String, int> listing) => <String>{
  for (final String path in listing.keys) ...<String>{
    path
        .replaceAll(RegExp('[0-9a-f]{12,}'), '#')
        .replaceAll(RegExp(r'/[0-9a-f]{2}/'), '/##/'),
    'ext:${path.contains('.') ? path.substring(path.indexOf('.')) : ''}'
        .replaceAll(RegExp('[0-9a-f]{12,}'), '#'),
  },
};

final class _Device {
  _Device(this.base, this.keychain, this.secrets, this.registry);

  final Directory base;
  final _Keychain keychain;
  final SecureStorageCredentialsStore secrets;
  final ZenAccountRegistry registry;

  int get scopedEntries =>
      keychain.items.keys.where((String k) => k.startsWith('zen_x_')).length;

  /// The decoys that get "used", as the device's own entry lists them.
  Set<String> usedDecoys() {
    final Object? json = jsonDecode(
      keychain.items[ZenAccountRegistry.decoysStorageKey]!,
    );
    return <String>{
      for (final Object? d in (json! as Map<String, Object?>)['d']! as List)
        if (d case {'u': 1, 'f': final String folder}) folder,
    };
  }

  /// When a file of [folder] was last written.
  Future<DateTime> newest(String folder) async {
    DateTime last = DateTime.fromMillisecondsSinceEpoch(0);
    for (final FileSystemEntity e in Directory(
      '${(await registry.accountsDirectory()).path}/$folder',
    ).listSync(recursive: true)) {
      if (e is File && e.lastModifiedSync().isAfter(last)) {
        last = e.lastModifiedSync();
      }
    }
    return last;
  }

  Future<List<String>> folders() async {
    final Directory dir = await registry.accountsDirectory();
    return <String>[
      for (final FileSystemEntity e in dir.listSync())
        if (e is Directory)
          e.uri.pathSegments.where((String s) => s.isNotEmpty).last,
    ];
  }

  /// Every file of [folder]: its path inside (with `/`) and its size.
  Future<Map<String, int>> listing(String folder) async {
    final Directory dir = Directory(
      '${(await registry.accountsDirectory()).path}/$folder',
    );
    return <String, int>{
      for (final FileSystemEntity e in dir.listSync(recursive: true))
        if (e is File)
          e.path.substring(dir.path.length + 1).replaceAll('\\', '/'): e
              .lengthSync(),
    };
  }
}

final class _Keychain implements SecureKeyValueBackend {
  final Map<String, String> items = <String, String>{};

  @override
  Future<String?> read(String key) async => items[key];

  @override
  Future<void> write(String key, String value) async => items[key] = value;

  @override
  Future<void> delete(String key) async => items.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.of(items);
}

final class _PassThrough implements BinaryCompressor {
  const _PassThrough();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
