import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/features/account/multi/account_decoys.dart';
import 'package:zen/src/features/account/multi/account_id.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// An account shown in the account list ("Pokazuj na liście kont"): only
/// these are written down anywhere, and only because the person chose so.
@immutable
final class ZenListedAccount {
  const ZenListedAccount({required this.id, required this.name});

  /// The normalized account ID.
  final String id;

  /// The name shown in the list (the account's profile name when it was
  /// put on the list, or last opened).
  final String name;

  Map<String, String> toJson() => <String, String>{'id': id, 'n': name};

  static ZenListedAccount? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? name = json['n'];
    final String? normalized = id is String ? normalizeAccountId(id) : null;
    if (normalized == null) {
      return null;
    }
    return ZenListedAccount(id: normalized, name: name is String ? name : '');
  }
}

/// A decoy folder, as the device's own entry in the secret store keeps it:
/// its name, the secret its entries are named with, and whether it is
/// "used" now and then or stays as it was made.
@immutable
final class _Decoy {
  const _Decoy(this.folder, this.secret, {required this.used});

  final String folder;
  final Uint8List secret;
  final bool used;

  Map<String, Object> toJson() => <String, Object>{
    'f': folder,
    's': _hexOf(secret),
    'u': used ? 1 : 0,
  };

  static _Decoy? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? folder = json['f'];
    final Object? secret = json['s'];
    if (folder is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(folder) ||
        secret is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      return null;
    }
    return _Decoy(
      folder,
      Uint8List.fromList(<int>[
        for (int i = 0; i < 64; i += 2)
          int.parse(secret.substring(i, i + 2), radix: 16),
      ]),
      used: json['u'] == 1,
    );
  }
}

String _hexOf(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The additional accounts on this device.
///
/// What is on the disk: `accounts/salt` (32 random bytes, made once) and
/// one folder per additional account, named by a keyed hash of its ID
/// ([ZenAccountScope.derive]), next to a few decoy folders of random
/// names that hold what an account's folder holds (random files of the
/// same names and sizes, [ZenAccountDecoys]), each with secret-store
/// entries of its own. There is no list of the accounts: an account is
/// found only from its ID. The list of the accounts the person chose to
/// show ([listed]) is kept in the system's secret store, never in a file;
/// the hidden ones are in no list at all. The decoys are listed in the
/// device's own entry ([decoysStorageKey]), so they can be kept up.
final class ZenAccountRegistry {
  ZenAccountRegistry({
    Future<Directory> Function()? instanceDirectory,
    SecureStorageCredentialsStore secrets =
        const SecureStorageCredentialsStore.device(),
    Random? random,
  }) : _instanceDirectory = instanceDirectory ?? ZenInstance.instanceDirectory,
       _secrets = secrets.forDevice(),
       _random = random ?? Random.secure();

  final Future<Directory> Function() _instanceDirectory;
  final SecureStorageCredentialsStore _secrets;
  final Random _random;

  /// The secret-store entry with the listed accounts (JSON).
  static const String listedStorageKey = 'zen_rewrite_accounts_listed';

  /// The secret-store entry with the decoys (JSON), on every device.
  static const String decoysStorageKey = 'zen_rewrite_accounts_decoys';

  /// The device's salt, in the accounts folder.
  static const String saltFileName = 'salt';

  static const int _saltBytes = 32;

  /// How many decoy folders a device gets at first, at least and at most.
  static const int minDecoys = 2;
  static const int maxDecoys = 5;

  /// How likely a "used" decoy gets something like a session at a start.
  static const double decoyUseChance = 0.3;

  /// The accounts folders whose decoys were looked after in this process
  /// ([prepare]).
  static final Set<String> _tended = <String>{};

  /// For tests: the next [prepare] looks after the decoys again, as a new
  /// process would.
  @visibleForTesting
  static void debugStartAgain() => _tended.clear();

  Uint8List? _salt;

  Future<Directory> accountsDirectory() async {
    final Directory instance = await _instanceDirectory();
    return Directory(
      '${instance.path}${Platform.pathSeparator}${ZenInstance.accountsFolder}',
    );
  }

  /// Makes the salt and the first decoys on a new device (cheap when they
  /// are there already). Every device gets them, with or without
  /// additional accounts, so the folder itself says nothing. Once per
  /// process the decoys are looked after too: those an earlier version
  /// made get the look of today's, and some get something like a session,
  /// as an account in use would.
  Future<void> prepare() async {
    await deviceSalt();
    final Directory dir = await accountsDirectory();
    if (_tended.add(dir.path)) {
      await _tendDecoys(dir);
    }
  }

  /// The device's salt (made with the decoys the first time).
  Future<Uint8List> deviceSalt() async {
    final Uint8List? cached = _salt;
    if (cached != null) {
      return cached;
    }
    final Directory dir = await accountsDirectory();
    final File file = File('${dir.path}${Platform.pathSeparator}$saltFileName');
    try {
      if (await file.exists()) {
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.length == _saltBytes) {
          return _salt = bytes;
        }
      }
    } on FileSystemException catch (error) {
      logZenWarning('Reading the accounts salt failed: $error');
    }
    await dir.create(recursive: true);
    final Uint8List salt = _randomBytes(_saltBytes);
    await writeFileAtomically(file, salt);
    final int decoys = minDecoys + _random.nextInt(maxDecoys - minDecoys + 1);
    final List<_Decoy> planted = <_Decoy>[];
    for (int i = 0; i < decoys; i++) {
      final _Decoy? decoy = await _plantDecoy(dir);
      if (decoy != null) {
        planted.add(decoy);
      }
    }
    // A salt made again (the folder was emptied by hand) starts a new list.
    await _writeDecoys(planted);
    _tended.add(dir.path);
    return _salt = salt;
  }

  /// A new additional account: a random ID, its folder made. Shown in the
  /// list only when [listed] (with [name]).
  Future<ZenAccountScope> create({
    bool listed = false,
    String name = '',
  }) async {
    final Uint8List salt = await deviceSalt();
    final Directory dir = await accountsDirectory();
    ZenAccountScope scope;
    do {
      scope = ZenAccountScope.derive(newAccountId(_random), salt);
    } while (await _folderOf(dir, scope).exists());
    await _folderOf(dir, scope).create(recursive: true);
    if (listed) {
      await setListed(scope, listed: true, name: name);
    }
    return scope;
  }

  /// The account with the ID [typed], if there is one on this device.
  Future<ZenAccountScope?> find(String typed) async {
    final String? id = normalizeAccountId(typed);
    if (id == null) {
      return null;
    }
    final ZenAccountScope scope = ZenAccountScope.derive(
      id,
      await deviceSalt(),
    );
    return await _folderOf(await accountsDirectory(), scope).exists()
        ? scope
        : null;
  }

  /// The scope of the listed account [account].
  Future<ZenAccountScope> scopeOf(ZenListedAccount account) async =>
      ZenAccountScope.derive(account.id, await deviceSalt());

  /// The accounts shown in the list, as they were put there.
  Future<List<ZenListedAccount>> listed() async {
    final String? raw = await _secrets.read(listedStorageKey);
    if (raw == null) {
      return const <ZenListedAccount>[];
    }
    try {
      final Object? json = jsonDecode(raw);
      if (json is! List) {
        return const <ZenListedAccount>[];
      }
      return <ZenListedAccount>[
        for (final Object? item in json) ?ZenListedAccount.fromJson(item),
      ];
    } on FormatException {
      return const <ZenListedAccount>[];
    }
  }

  Future<bool> isListed(ZenAccountScope scope) async =>
      scope.isDefault ||
      (await listed()).any((ZenListedAccount a) => a.id == scope.id);

  /// Shows [scope] in the list (with [name]) or takes it off.
  Future<void> setListed(
    ZenAccountScope scope, {
    required bool listed,
    String name = '',
  }) async {
    final String? id = scope.id;
    if (id == null) {
      return;
    }
    final List<ZenListedAccount> all = <ZenListedAccount>[
      for (final ZenListedAccount a in await this.listed())
        if (a.id != id) a,
      if (listed) ZenListedAccount(id: id, name: name.trim()),
    ];
    if (all.isEmpty) {
      await _secrets.delete(listedStorageKey);
      return;
    }
    await _secrets.write(
      listedStorageKey,
      jsonEncode(<Map<String, String>>[
        for (final ZenListedAccount a in all) a.toJson(),
      ]),
    );
  }

  /// The name of a listed account, when it changed (nothing for a hidden
  /// one: it never gets on the list this way).
  Future<void> rename(ZenAccountScope scope, String name) async {
    final List<ZenListedAccount> all = await listed();
    final int i = all.indexWhere((ZenListedAccount a) => a.id == scope.id);
    if (i < 0 || all[i].name == name.trim()) {
      return;
    }
    await setListed(scope, listed: true, name: name);
  }

  /// Wipes the additional account [scope] from this device: its place in
  /// the background list and the node it runs there in this isolate (a
  /// computer's tray; the Android service's stops by itself once the keys
  /// are gone, [BackgroundAccountWatch]), every entry it has in the secret
  /// store (the keys first), its folder, its place in the list. A decoy
  /// takes the folder's place, so the count of folders does not change.
  Future<void> wipeAccount(ZenAccountScope scope) async {
    if (scope.isDefault) {
      throw ArgumentError.value(scope, 'scope', 'Not an additional account');
    }
    try {
      await ZenBackgroundAccounts(
        registry: this,
        secrets: _secrets,
      ).forget(scope);
    } on Object catch (error, stackTrace) {
      logZenError('Leaving the background list failed', error, stackTrace);
    }
    // Before its folder goes: a running node would write it back.
    await BackgroundAccountRuns.stop(scope.folder!);
    try {
      // The files it exported first, while its own list still names them.
      await ExportedFilesIndex(
        _secrets.forAccount(scope.secret),
        _secrets.forDevice(),
      ).deleteAll();
    } on Object catch (error, stackTrace) {
      logZenError('Deleting the account exports failed', error, stackTrace);
    }
    try {
      await _secrets.forAccount(scope.secret).deleteAccountEntries();
    } on Object catch (error, stackTrace) {
      logZenError('Deleting the account secrets failed', error, stackTrace);
    }
    final Directory dir = await accountsDirectory();
    final Directory folder = _folderOf(dir, scope);
    try {
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
    } on FileSystemException catch (error) {
      logZenWarning('Deleting an account folder failed: $error');
    }
    await setListed(scope, listed: false);
    final _Decoy? decoy = await _plantDecoy(dir);
    if (decoy != null) {
      await _writeDecoys(<_Decoy>[...await _readDecoys(), decoy]);
    }
  }

  /// Forgets the salt held in memory (after the device wipe deleted it).
  void forget() {
    _salt = null;
  }

  Directory _folderOf(Directory accounts, ZenAccountScope scope) =>
      Directory('${accounts.path}${Platform.pathSeparator}${scope.folder}');

  /// A folder of a random name that holds what an account's folder holds
  /// ([ZenAccountDecoys]), with entries of its own in the secret store;
  /// `null` when it could not be made.
  Future<_Decoy?> _plantDecoy(Directory accounts) async {
    final _Decoy decoy = _Decoy(
      _hex(16),
      _randomBytes(32),
      used: _random.nextBool(),
    );
    final DateTime now = DateTime.now();
    try {
      await _fill(
        Directory('${accounts.path}${Platform.pathSeparator}${decoy.folder}'),
        decoy,
        since: now,
        until: now,
      );
      return decoy;
    } on Object catch (error) {
      logZenWarning('Planting a decoy failed: ${error.runtimeType}');
      return null;
    }
  }

  Future<void> _fill(
    Directory folder,
    _Decoy decoy, {
    required DateTime since,
    required DateTime until,
  }) async {
    final ZenAccountDecoys decoys = ZenAccountDecoys(_random);
    await decoys.plant(folder, used: decoy.used, since: since, until: until);
    await decoys.plantSecrets(_secrets.forAccount(decoy.secret));
  }

  /// Once per process: decoys of an earlier version get today's look (in
  /// place: the same folders, times between when they were made and now),
  /// the "used" ones now and then something like a session. Nothing about
  /// a single folder is logged.
  Future<void> _tendDecoys(Directory accounts) async {
    try {
      if (!await accounts.exists()) {
        return;
      }
      final List<_Decoy> known = await _readDecoys();
      final List<_Decoy> kept = <_Decoy>[];
      bool changed = false;
      final Set<String> folders = <String>{
        await for (final FileSystemEntity e in accounts.list(
          followLinks: false,
        ))
          if (e is Directory)
            e.uri.pathSegments.where((String s) => s.isNotEmpty).last,
      };
      for (final _Decoy decoy in known) {
        if (!folders.contains(decoy.folder)) {
          // Gone (by hand): its entries go too.
          await _secrets.forAccount(decoy.secret).deleteAccountEntries();
          changed = true;
          continue;
        }
        kept.add(decoy);
        if (decoy.used && _random.nextDouble() < decoyUseChance) {
          await ZenAccountDecoys(_random).use(
            Directory(
              '${accounts.path}${Platform.pathSeparator}${decoy.folder}',
            ),
          );
        }
      }
      final DateTime now = DateTime.now();
      for (final String name in folders) {
        final Directory folder = Directory(
          '${accounts.path}${Platform.pathSeparator}$name',
        );
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(name) ||
            known.any((_Decoy d) => d.folder == name) ||
            !ZenAccountDecoys.hasEarlierLook(folder)) {
          continue;
        }
        final DateTime made = ZenAccountDecoys.madeAt(folder) ?? now;
        final _Decoy decoy = _Decoy(
          name,
          _randomBytes(32),
          used: _random.nextBool(),
        );
        await _fill(folder, decoy, since: made, until: now);
        kept.add(decoy);
        changed = true;
      }
      if (changed) {
        await _writeDecoys(kept);
      }
    } on Object catch (error) {
      logZenWarning('Looking after the decoys failed: ${error.runtimeType}');
    }
  }

  Future<List<_Decoy>> _readDecoys() async {
    final String? raw = await _secrets.read(decoysStorageKey);
    if (raw == null) {
      return <_Decoy>[];
    }
    try {
      final Object? json = jsonDecode(raw);
      return <_Decoy>[
        if (json is Map && json['d'] is List)
          for (final Object? item in json['d'] as List) ?_Decoy.fromJson(item),
      ];
    } on FormatException {
      return <_Decoy>[];
    }
  }

  Future<void> _writeDecoys(List<_Decoy> decoys) => _secrets.write(
    decoysStorageKey,
    jsonEncode(<String, Object>{
      'v': 1,
      'd': <Map<String, Object>>[for (final _Decoy d in decoys) d.toJson()],
    }),
  );

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

  String _hex(int bytes) => _randomBytes(
    bytes,
  ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}
