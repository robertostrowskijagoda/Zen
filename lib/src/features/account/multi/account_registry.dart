import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/multi/account_id.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
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

/// The additional accounts on this device.
///
/// What is on the disk: `accounts/salt` (32 random bytes, made once) and
/// one folder per additional account, named by a keyed hash of its ID
/// ([ZenAccountScope.derive]), next to a few decoy folders of random
/// names with random sealed-looking files in them. There is no list of
/// the accounts: an account is found only from its ID. The list of the
/// accounts the person chose to show ([listed]) is kept in the system's
/// secret store, never in a file; the hidden ones are in no list at all.
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

  /// The device's salt, in the accounts folder.
  static const String saltFileName = 'salt';

  static const int _saltBytes = 32;

  /// How many decoy folders a device gets at first, at least and at most.
  static const int minDecoys = 2;
  static const int maxDecoys = 5;

  Uint8List? _salt;

  Future<Directory> accountsDirectory() async {
    final Directory instance = await _instanceDirectory();
    return Directory(
      '${instance.path}${Platform.pathSeparator}${ZenInstance.accountsFolder}',
    );
  }

  /// Makes the salt and the first decoys on a new device (cheap when they
  /// are there already). Every device gets them, with or without
  /// additional accounts, so the folder itself says nothing.
  Future<void> prepare() async {
    await deviceSalt();
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
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(salt, flush: true);
    await tmp.rename(file.path);
    final int decoys = minDecoys + _random.nextInt(maxDecoys - minDecoys + 1);
    for (int i = 0; i < decoys; i++) {
      await _plantDecoy(dir);
    }
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

  /// Wipes the additional account [scope] from this device: every entry
  /// it has in the secret store (the keys first), its folder, its place in
  /// the list. A decoy takes the folder's place, so the count of folders
  /// does not change.
  Future<void> wipeAccount(ZenAccountScope scope) async {
    if (scope.isDefault) {
      throw ArgumentError.value(scope, 'scope', 'Not an additional account');
    }
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
    await _plantDecoy(dir);
  }

  /// Forgets the salt held in memory (after the device wipe deleted it).
  void forget() {
    _salt = null;
  }

  Directory _folderOf(Directory accounts, ZenAccountScope scope) =>
      Directory('${accounts.path}${Platform.pathSeparator}${scope.folder}');

  /// A folder of a random name shaped like an account's (a `settings`
  /// and a `data` folder, a few random files of plausible sizes).
  Future<void> _plantDecoy(Directory accounts) async {
    try {
      final Directory decoy = Directory(
        '${accounts.path}${Platform.pathSeparator}${_hex(16)}',
      );
      for (final String part in <String>['settings', 'data']) {
        final Directory sub = Directory(
          '${decoy.path}${Platform.pathSeparator}$part',
        );
        await sub.create(recursive: true);
        final int files = 1 + _random.nextInt(3);
        for (int i = 0; i < files; i++) {
          await File(
            '${sub.path}${Platform.pathSeparator}${_hex(12)}.bin',
          ).writeAsBytes(_randomBytes(600 + _random.nextInt(24 * 1024)));
        }
      }
    } on FileSystemException catch (error) {
      logZenWarning('Planting a decoy failed: $error');
    }
  }

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

  String _hex(int bytes) => _randomBytes(
    bytes,
  ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}
