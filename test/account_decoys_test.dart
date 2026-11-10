import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/multi/account_decoys.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The decoy folders beside the additional accounts: whoever lists the
/// folders (names, sizes, times) and the names of the secret store's
/// entries cannot tell a hidden account from them.
void main() {
  final List<Directory> made = <Directory>[];

  tearDown(() async {
    await ZenAccountRegistry.debugSettled();
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

  /// A new device, after its first run (the decoys' first sessions done).
  Future<_Device> device(
    int seed, {
    Future<void> Function(Duration)? pause,
  }) async {
    final Directory base = await Directory.systemTemp.createTemp('zen-d-');
    made.add(base);
    final _Keychain keychain = _Keychain();
    final _Device d = _Device(
      base,
      keychain,
      SecureStorageCredentialsStore(keychain, keychain),
      seed,
      pause ?? _noPause,
    );
    ZenInstance.debugSetBaseDirectory(base);
    ZenAccountRegistry.debugStartAgain();
    await d.registry.prepare();
    await ZenAccountRegistry.debugSettled();
    return d;
  }

  /// A hidden account used as the app uses one, through the app's own
  /// stores and files: a password, the settings saved a few times, a sealed
  /// profile, its ledger identity (hidden name), the places it was on, the
  /// update book, the census, its recovery circle, the node's config with
  /// its copy, a friend's photo in the media vault.
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
    await loadOrCreateNodeConfigJson(
      file: File('${home.path}/runtime/yggdrasil.config.json'),
      generateConfig: () => jsonEncode(<String, Object>{'PrivateKey': 'x'}),
    );
    await stores.userProfileStore.save(const UserProfile(displayName: 'x'));
    await stores.ledgerDisk.write(
      'ledger/identity',
      Uint8List.fromList(List<int>.filled(400, 7)),
    );
    for (int i = 0; i < 3; i++) {
      await stores.appSettingsStore.save(
        AppSettings(
          themeMode: i.isEven ? AppThemeMode.dark : AppThemeMode.light,
        ),
      );
      await stores.ledgerDisk.write(
        'ui/last_place',
        Uint8List.fromList(List<int>.filled(60 + i, 1)),
      );
    }
    for (final String key in <String>[
      'update/book',
      'census/state',
      'recovery/circle',
    ]) {
      await stores.ledgerDisk.write(
        key,
        Uint8List.fromList(List<int>.filled(300, 2)),
      );
    }
    final Uint8List master = (await security.currentEncryptionKey())!;
    await MediaVault(
      masterKey: () async => master,
      supportDirectory: () async => home,
    ).put(Uint8List.fromList(List<int>.filled(5000, 3)));
    ZenAccounts.activate(ZenAccountScope.defaultAccount);
    return hidden;
  }

  test('every name a used account has is one decoys have too', () async {
    final Set<String> decoyNames = <String>{};
    int decoyFolders = 0;
    for (int seed = 1; seed <= 12; seed++) {
      final _Device d = await device(seed);
      await d.runs(20);
      for (final String folder in await d.folders()) {
        decoyFolders++;
        decoyNames.addAll(_shapes(await d.folder(folder)));
      }
    }
    final _Device d = await device(99);
    await d.runs(3);
    final ZenAccountScope hidden = await useHiddenAccount(d);
    final Set<String> own = _shapes(await d.folder(hidden.folder!));
    // The names a session writes first of all (the shell's last place on a
    // tab change, the update book) and their earlier generations.
    expect(
      own,
      containsAll(<String>[
        'data/ui/last_place.zenbin',
        'data/ui/last_place.zenbin.bak',
        'data/update/book.zenbin',
        'data/census/state.zenbin',
        'vault/#.zmedia',
        'runtime/yggdrasil.config.json.bak',
      ]),
    );
    expect(
      own.difference(decoyNames),
      isEmpty,
      reason: 'over $decoyFolders decoys',
    );
    // Told by a name no other device's decoys have: never the account (a
    // decoy may be, by a name only a few accounts get).
    final List<String> flagged = <String>[
      for (final String folder in await d.folders())
        if (_shapes(await d.folder(folder)).difference(decoyNames).isNotEmpty)
          folder,
    ];
    expect(flagged, isNot(contains(hidden.folder)));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('every store key and background file the app writes has its name '
      'among the decoys\'', () {
    final List<RegExp> places = <RegExp>[
      for (final String place in ZenAccountDecoys.debugPlaces)
        RegExp(
          '^${RegExp.escape(place).replaceAll(RegExp(r'\\\{\w+\\\}'), '[^/]+')}'
          r'$',
        ),
    ];
    bool covered(String place) => places.any((RegExp p) => p.hasMatch(place));
    bool coveredPrefix(String prefix) => ZenAccountDecoys.debugPlaces.any(
      (String p) => p.startsWith(prefix) && p.length > prefix.length,
    );
    // Literals that are not keys of the data store: method channels and
    // media types, assets; the names the node's and the background's files
    // are sealed for (their files are checked below); the ids of the
    // account sync kept under `account/sync/`; the pieces of a relay blob
    // key, kept under `relay/blob/`.
    const Set<String> notKeys = <String>{
      'zen',
      'flutter',
      'image',
      'audio',
      'video',
      'application',
      'text',
      'assets',
      'packages',
      'install',
      'runtime',
      'background',
      'held',
      'o',
      'p',
      'h',
      'i',
    };
    final RegExp key = RegExp(r"'([a-z][a-z0-9_]*(?:/[a-z0-9_]+)+)'");
    final RegExp keyPrefix = RegExp(r"'([a-z][a-z0-9_]*/(?:[a-z0-9_]+/)*)\$");
    final RegExp backgroundFile = RegExp(
      r"'([a-z][a-z0-9_-]*\.(?:zenbg|zbox))'",
    );
    final List<String> missing = <String>[];
    int hidden = 0;
    int keys = 0;
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File ||
          !e.path.endsWith('.dart') ||
          // The list itself.
          e.path.endsWith('account_decoys.dart')) {
        continue;
      }
      final String text = e.readAsStringSync();
      for (final (RegExp pattern, bool whole) in <(RegExp, bool)>[
        (key, true),
        (keyPrefix, false),
      ]) {
        for (final Match m in pattern.allMatches(text)) {
          final String k = m.group(1)!;
          if (notKeys.contains(k.split('/').first)) {
            continue;
          }
          if (kZenHiddenNamePrefixes.any(
            (String p) => k.startsWith(p) || '$k/'.startsWith(p),
          )) {
            hidden++;
            continue;
          }
          keys++;
          final String place = k == 'settings/app'
              ? 'settings/settings/app.zenbin'
              : 'data/$k${whole ? '.zenbin' : ''}';
          if (whole ? !covered(place) : !coveredPrefix(place)) {
            missing.add('$k (${e.path})');
          }
        }
      }
      for (final Match m in backgroundFile.allMatches(text)) {
        if (!covered('${FileBackgroundVault.folderName}/${m.group(1)}')) {
          missing.add('${m.group(1)} (${e.path})');
        }
      }
    }
    expect(missing, isEmpty);
    expect(keys, greaterThan(60));
    expect(hidden, greaterThan(5));
    for (final String place in <String>[
      'runtime/yggdrasil.config.json',
      'runtime/yggdrasil.pins',
      'runtime/public_peers.json',
      kZenLanguagePreferenceFileName,
      '$kMediaVaultFolder/${'0' * 32}$kMediaVaultExtension',
      '${FileBackgroundVault.folderName}/$kKeptPresenceFileName',
    ]) {
      expect(covered(place), isTrue, reason: place);
    }
  });

  test('no decoy file carries a set time: each is written when it is, '
      'through the steps an account\'s file is', () async {
    int decoys = 0;
    for (int seed = 1; seed <= 6; seed++) {
      final DateTime start = DateTime.now().subtract(
        const Duration(seconds: 2),
      );
      final _Device d = await device(seed, pause: _shortPause);
      await d.runs(4);
      final ZenAccountScope hidden = await useHiddenAccount(d);
      for (final String name in await d.folders()) {
        final Directory folder = await d.folder(name);
        final List<FileStat> stats = <FileStat>[
          for (final FileSystemEntity f in folder.listSync(recursive: true))
            if (f is File) f.statSync(),
        ];
        Duration spread(Iterable<DateTime> times) {
          final List<DateTime> sorted = times.toList()..sort();
          return sorted.isEmpty
              ? Duration.zero
              : sorted.last.difference(sorted.first);
        }

        final int distinct = <DateTime>{
          for (final FileStat st in stats) st.modified,
        }.length;
        // A "used" decoy of before: every file of one modification time.
        expect(stats.length >= 5 && distinct == 1, isFalse, reason: name);
        // An "unused" one: made in one burst, dated over minutes after.
        expect(
          spread(<DateTime>[for (final FileStat st in stats) st.changed]) <
                  const Duration(seconds: 3) &&
              spread(<DateTime>[for (final FileStat st in stats) st.modified]) >
                  const Duration(seconds: 30),
          isFalse,
          reason: name,
        );
        for (final FileStat st in stats) {
          // Never dated back, never made (Windows) or changed (POSIX)
          // after it was last written.
          expect(st.modified.isBefore(start), isFalse, reason: name);
          expect(
            st.changed.difference(st.modified) > const Duration(minutes: 1),
            isFalse,
            reason: name,
          );
        }
        if (name != hidden.folder) {
          decoys++;
        }
      }
    }
    expect(decoys, greaterThanOrEqualTo(6 * ZenAccountRegistry.minDecoys));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a decoy is written while Zen runs, not while it starts', () async {
    final _Device d = await device(31);
    int changedLater = 0;
    for (int run = 0; run < 20 && changedLater == 0; run++) {
      final Map<String, String> before = await d.snapshot();
      final Completer<void> gate = Completer<void>();
      ZenAccountRegistry.debugStartAgain();
      await ZenAccountRegistry(
        instanceDirectory: () async => d.base,
        secrets: d.secrets,
        random: Random(500 + run),
        pause: (Duration _) => gate.future,
      ).prepare();
      // The start itself changed no file of any decoy.
      expect(await d.snapshot(), before);
      gate.complete();
      await ZenAccountRegistry.debugSettled();
      if (!_sameMap(await d.snapshot(), before)) {
        changedLater++;
      }
    }
    expect(changedLater, 1);
  });

  test('a hidden account is not told from the decoys by the secret '
      'store\'s entries', () async {
    final List<int> entriesOfDecoys = <int>[];
    final List<int> entriesOfReal = <int>[];
    for (int seed = 1; seed <= 6; seed++) {
      final _Device d = await device(seed);
      final int before = d.scopedEntries;
      final int decoyCount = (await d.folders()).length;
      expect(decoyCount, ZenAccountRegistry.minDecoys);
      expect(before, greaterThan(0));
      entriesOfDecoys.add(before ~/ decoyCount);
      await useHiddenAccount(d);
      entriesOfReal.add(d.scopedEntries - before);
      expect(
        d.keychain.items.keys.where((String k) => k.startsWith('zen_x_')),
        everyElement(matches(RegExp(r'^zen_x_[0-9a-f]{40}$'))),
      );
    }
    for (final int count in entriesOfReal) {
      expect(count, greaterThanOrEqualTo(entriesOfDecoys.reduce(min) - 1));
      expect(count, lessThanOrEqualTo(entriesOfDecoys.reduce(max) + 1));
    }
  });

  test('decoys of earlier versions: the update changes no file; later '
      'starts write them anew, with no time of before; an account stays '
      'as it was', () async {
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
    // As 1.16.3 planted them: a few random `<24 hex>.bin` files.
    final List<String> oldest = <String>[hex(16), hex(16)];
    for (final String name in oldest) {
      for (final String part in <String>['settings', 'data']) {
        final File file = File('${accounts.path}/$name/$part/${hex(12)}.bin');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List<int>.filled(900, 1));
        await file.setLastModified(then);
      }
    }
    // As 1.16.4 planted them: an account's names, every time set.
    final List<String> older = <String>[hex(16), hex(16)];
    for (final String name in older) {
      for (final String part in <String>[
        'settings/settings/app.zenbin',
        'data/user_profile.zenbin',
        'data/user_profile.zenbin.bak',
        'runtime/yggdrasil.config.json',
      ]) {
        final File file = File('${accounts.path}/$name/$part');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List<int>.filled(500, 2));
        await file.setLastModified(then);
      }
    }
    final _Keychain keychain = _Keychain();
    keychain.items[ZenAccountRegistry.decoysStorageKey] = jsonEncode(
      <String, Object>{
        'v': 1,
        'd': <Object>[
          for (final String name in older)
            <String, Object>{'f': name, 's': hex(32), 'u': 1},
        ],
      },
    );
    // An account (of 1.16.2) next to them, and one whose start was cut
    // short (an empty folder).
    final String account = hex(16);
    final File profile = File('${accounts.path}/$account/data/x.zenbin');
    await profile.parent.create(recursive: true);
    await profile.writeAsBytes(<int>[1, 2, 3]);
    await profile.setLastModified(then);
    final String empty = hex(16);
    await Directory('${accounts.path}/$empty').create();

    final _Device d = _Device(
      base,
      keychain,
      SecureStorageCredentialsStore(keychain, keychain),
      5,
      _noPause,
    );
    final Map<String, String> before = await d.snapshot();
    ZenAccountRegistry.debugStartAgain();
    await d.registry.prepare();
    await ZenAccountRegistry.debugSettled();
    // The first start of the new version only takes the decoys over.
    expect(await d.snapshot(), before);
    expect(await d.folders(), hasLength(6));
    expect(d.scopedEntries, greaterThanOrEqualTo(2 * 7));

    final DateTime start = DateTime.now().subtract(const Duration(seconds: 2));
    await d.runs(30);
    // As many folders as before (one may have been replaced since).
    expect(await d.folders(), hasLength(6));
    for (final String name in await d.folders()) {
      if (name == account || name == empty) {
        continue;
      }
      final Directory folder = await d.folder(name);
      final Map<String, int> listing = await d.listing(name);
      expect(listing.keys, isNot(contains(endsWith('.bin'))), reason: name);
      expect(listing.keys, contains(endsWith('.zenbin')), reason: name);
      for (final FileSystemEntity e in folder.listSync(recursive: true)) {
        if (e is File) {
          final FileStat st = e.statSync();
          expect(st.modified.isBefore(start), isFalse, reason: e.path);
          expect(
            st.changed.difference(st.modified) > const Duration(minutes: 1),
            isFalse,
            reason: e.path,
          );
        }
      }
    }
    expect(await d.listing(account), <String, int>{'data/x.zenbin': 3});
    expect(profile.lastModifiedSync(), then);
    expect(await d.listing(empty), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('decoys "used" change now and then as an account in use does; the '
      'others stay as their first session left them', () async {
    final _Device d = await device(21);
    final Map<String, DateTime> first = <String, DateTime>{
      for (final String folder in await d.folders())
        folder: await d.newest(folder),
    };
    final Set<String> used = d.usedDecoys();
    expect(first.keys.toSet().containsAll(used), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await d.runs(15);
    final List<String> now = await d.folders();
    int changed = 0;
    for (final String folder in first.keys) {
      if (!now.contains(folder)) {
        continue;
      }
      final DateTime newest = await d.newest(folder);
      if (used.contains(folder)) {
        if (newest.isAfter(first[folder]!)) {
          changed++;
        }
      } else {
        expect(newest, first[folder], reason: folder);
      }
    }
    expect(changed, used.where(now.contains).length);
  });

  test('a device gets decoys up to its own number over its starts, and '
      'now and then one is replaced', () async {
    final _Device d = await device(41);
    expect(await d.folders(), hasLength(ZenAccountRegistry.minDecoys));
    final Set<String> seen = (await d.folders()).toSet();
    await d.runs(80);
    final int want =
        (jsonDecode(d.keychain.items[ZenAccountRegistry.decoysStorageKey]!)
                as Map<String, Object?>)['w']!
            as int;
    expect(want, inInclusiveRange(2, ZenAccountRegistry.maxDecoys));
    expect(await d.folders(), hasLength(want));
    seen.addAll(await d.folders());
    // Every folder ever made has its entries while it is there.
    expect(d.usedDecoys().every((await d.folders()).contains), isTrue);
    expect(seen.length, greaterThanOrEqualTo(want));
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<void> _noPause(Duration _) async {}

Future<void> _shortPause(Duration _) =>
    Future<void>.delayed(const Duration(milliseconds: 3));

bool _sameMap(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length &&
    a.entries.every((MapEntry<String, String> e) => b[e.key] == e.value);

/// What a listing says of a folder: the paths with their random parts
/// (hex names, the pieces of a temporary name) taken out.
Set<String> _shapes(Directory folder) => <String>{
  for (final FileSystemEntity e in folder.listSync(recursive: true))
    if (e is File)
      e.path
          .substring(folder.path.length + 1)
          .replaceAll('\\', '/')
          .toLowerCase()
          .replaceAll(RegExp('[0-9a-f]{12,}'), '#')
          .replaceAll(RegExp(r'/[0-9a-f]{2}/'), '/##/')
          .replaceAll(RegExp(r'(\.\d+)+\.tmp$'), '.tmp'),
};

final class _Device {
  _Device(this.base, this.keychain, this.secrets, this.seed, this.pause);

  final Directory base;
  final _Keychain keychain;
  final SecureStorageCredentialsStore secrets;
  final int seed;
  final Future<void> Function(Duration) pause;
  int _run = 0;

  ZenAccountRegistry get registry => ZenAccountRegistry(
    instanceDirectory: () async => base,
    secrets: secrets,
    random: Random(seed * 1000 + _run),
    pause: pause,
  );

  /// [n] more runs of Zen, each to its end.
  Future<void> runs(int n) async {
    for (int i = 0; i < n; i++) {
      _run++;
      ZenAccountRegistry.debugStartAgain();
      await registry.prepare();
      await ZenAccountRegistry.debugSettled();
    }
  }

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

  Future<Directory> folder(String name) async =>
      Directory('${(await registry.accountsDirectory()).path}/$name');

  /// When a file of [name] was last written.
  Future<DateTime> newest(String name) async {
    DateTime last = DateTime.fromMillisecondsSinceEpoch(0);
    for (final FileSystemEntity e in (await folder(
      name,
    )).listSync(recursive: true)) {
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

  /// Every file under the accounts folder with its size and time.
  Future<Map<String, String>> snapshot() async {
    final Directory dir = await registry.accountsDirectory();
    return <String, String>{
      for (final FileSystemEntity e in dir.listSync(recursive: true))
        e.path.substring(dir.path.length): e is File
            ? '${e.lengthSync()} ${e.lastModifiedSync().microsecondsSinceEpoch}'
            : 'folder',
    };
  }

  /// Every file of [name]: its path inside (with `/`) and its size.
  Future<Map<String, int>> listing(String name) async {
    final Directory dir = await folder(name);
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
