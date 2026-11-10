import 'dart:async';
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
/// its name, the secret its entries (and its files' hidden names) are
/// named with, whether it is "used" now and then or stays as it was made,
/// and how far it got ([look]).
@immutable
final class _Decoy {
  const _Decoy(
    this.folder,
    this.secret, {
    required this.used,
    this.look = earlier,
  });

  /// Planted by an earlier version (files of set times, or random `.bin`
  /// files): written anew by a first session at a later start.
  static const int earlier = 0;

  /// Made; its first session is still to come (or was cut short).
  static const int made = 1;

  /// Written the way an account's files are.
  static const int current = 2;

  final String folder;
  final Uint8List secret;
  final bool used;
  final int look;

  _Decoy withLook(int look) => _Decoy(folder, secret, used: used, look: look);

  Map<String, Object> toJson() => <String, Object>{
    'f': folder,
    's': _hexOf(secret),
    'u': used ? 1 : 0,
    if (look != earlier) 'l': look,
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
    final Object? look = json['l'];
    return _Decoy(
      folder,
      Uint8List.fromList(<int>[
        for (int i = 0; i < 64; i += 2)
          int.parse(secret.substring(i, i + 2), radix: 16),
      ]),
      used: json['u'] == 1,
      look: look == made || look == current ? look! as int : earlier,
    );
  }
}

/// The device's entry: how many decoys it is to have ([want]) and the
/// decoys; [version] 1 is an earlier version's (decoys of set times).
final class _Entry {
  _Entry(this.want, this.decoys, {this.version = 2});

  final int want;
  final List<_Decoy> decoys;
  final int version;
}

String _hexOf(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The additional accounts on this device.
///
/// What is on the disk: `accounts/salt` (32 random bytes, made once) and
/// one folder per additional account, named by a keyed hash of its ID
/// ([ZenAccountScope.derive]), next to a few decoy folders of random
/// names that are written as an account's folder is (random files of the
/// same names and sizes, through the same stores, at the time they are
/// written, [ZenAccountDecoys]), each with secret-store entries of its
/// own. There is no list of the accounts: an account is found only from
/// its ID. The list of the accounts the person chose to show ([listed]) is
/// kept in the system's secret store, never in a file; the hidden ones are
/// in no list at all. The decoys are listed in the device's own entry
/// ([decoysStorageKey]), so they can be kept up.
///
/// A decoy lives as an account does, while Zen runs: made at the first
/// start or at a later one (as an account is made when the person makes
/// it), a first session right after, and for one "in use" a session now
/// and then, at some moment of a run rather than at its start. Now and
/// then one goes and a new one is made, as when an account is deleted.
final class ZenAccountRegistry {
  ZenAccountRegistry({
    Future<Directory> Function()? instanceDirectory,
    SecureStorageCredentialsStore secrets =
        const SecureStorageCredentialsStore.device(),
    Random? random,
    Future<void> Function(Duration)? pause,
  }) : _instanceDirectory = instanceDirectory ?? ZenInstance.instanceDirectory,
       _secrets = secrets.forDevice(),
       _random = random ?? Random.secure(),
       _pause = pause ?? _wait;

  final Future<Directory> Function() _instanceDirectory;
  final SecureStorageCredentialsStore _secrets;
  final Random _random;

  /// Waits until a decoy's turn comes, and between its saves (tests make
  /// it short).
  final Future<void> Function(Duration) _pause;

  static Future<void> _wait(Duration d) => Future<void>.delayed(d);

  /// The secret-store entry with the listed accounts (JSON).
  static const String listedStorageKey = 'zen_rewrite_accounts_listed';

  /// The secret-store entry with the decoys (JSON), on every device.
  static const String decoysStorageKey = 'zen_rewrite_accounts_decoys';

  /// The device's salt, in the accounts folder.
  static const String saltFileName = 'salt';

  static const int _saltBytes = 32;

  /// How many decoy folders a device has: [minDecoys] from the first
  /// start, then more at later starts up to a number of its own between
  /// [minDecoys] and [maxDecoys].
  static const int minDecoys = 2;
  static const int maxDecoys = 5;

  /// How likely a "used" decoy gets something like a session in a run.
  static const double decoyUseChance = 0.3;

  /// How likely a decoy is made in a run while the device has fewer than
  /// its number.
  static const double decoyBirthChance = 0.15;

  /// How likely, in a run, a decoy goes and a new one is made in its place.
  static const double decoyReplaceChance = 0.02;

  /// How likely, in a run after the first one of this version, a decoy of
  /// an earlier version is written anew.
  static const double earlierDecoyChance = 0.3;

  /// The latest moment of a run, after its start, a decoy's turn comes.
  static const Duration decoyTurnWithin = Duration(minutes: 20);

  /// The accounts folders whose decoys were looked after in this process
  /// ([prepare]).
  static final Set<String> _tended = <String>{};

  /// What the decoys do in this process now, until it is done.
  static final Set<Future<void>> _running = <Future<void>>{};

  /// Changes when the device's data is wiped ([forget]): what was still
  /// to be written into the decoys of before stops.
  static int _epoch = 0;

  /// Changes of the device's entry, one at a time.
  static Future<void> _entryChanges = Future<void>.value();

  /// For tests: the next [prepare] looks after the decoys again, as a new
  /// process would.
  @visibleForTesting
  static void debugStartAgain() => _tended.clear();

  /// For tests: waits until the decoys did all they were to do in this
  /// process.
  @visibleForTesting
  static Future<void> debugSettled() async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.toList());
    }
  }

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
  /// process the decoys are looked after too ([_tendDecoys]): what they
  /// write comes later in the run, not before this returns.
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
    final int want = minDecoys + _random.nextInt(maxDecoys - minDecoys + 1);
    final List<_Decoy> planted = <_Decoy>[];
    for (int i = 0; i < minDecoys; i++) {
      final _Decoy? decoy = await _makeDecoy(dir);
      if (decoy != null) {
        planted.add(decoy);
      }
    }
    // A salt made again (the folder was emptied by hand) starts a new list.
    await _changeEntry((_Entry _) => _Entry(want, planted));
    _tended.add(dir.path);
    for (final _Decoy decoy in planted) {
      _later(() => _firstSession(dir, decoy));
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
    final _Decoy? decoy = await _makeDecoy(dir);
    if (decoy != null) {
      await _changeEntry(
        (_Entry entry) => _Entry(entry.want, <_Decoy>[
          ...entry.decoys,
          decoy,
        ], version: entry.version),
      );
      _later(() => _firstSession(dir, decoy));
    }
  }

  /// Forgets the salt held in memory (after the device wipe deleted it);
  /// whatever the decoys of before were still to write is dropped.
  void forget() {
    _salt = null;
    _epoch++;
  }

  Directory _folderOf(Directory accounts, ZenAccountScope scope) =>
      Directory('${accounts.path}${Platform.pathSeparator}${scope.folder}');

  Directory _decoyFolder(Directory accounts, _Decoy decoy) =>
      Directory('${accounts.path}${Platform.pathSeparator}${decoy.folder}');

  /// A folder of a random name, made now, with entries of its own in the
  /// secret store; what an account's folder holds comes with its first
  /// session ([_firstSession]). `null` when it could not be made.
  Future<_Decoy?> _makeDecoy(Directory accounts) async {
    final _Decoy decoy = _Decoy(
      _hex(16),
      _randomBytes(32),
      used: _random.nextBool(),
      look: _Decoy.made,
    );
    try {
      await _decoyFolder(accounts, decoy).create(recursive: true);
      await ZenAccountDecoys(
        _random,
      ).plantSecrets(_secrets.forAccount(decoy.secret));
      return decoy;
    } on Object catch (error) {
      logZenWarning('Making a decoy failed: ${error.runtimeType}');
      return null;
    }
  }

  ZenAccountDecoys _decoys() {
    final int epoch = _epoch;
    return ZenAccountDecoys(
      _random,
      pause: _pause,
      keepGoing: () => epoch == _epoch,
    );
  }

  /// The first session of [decoy] (for one of an earlier version: what it
  /// held goes first); from then on it is of the current look.
  Future<void> _firstSession(Directory accounts, _Decoy decoy) async {
    final bool earlier = decoy.look == _Decoy.earlier;
    final int epoch = _epoch;
    await _decoys().open(
      _decoyFolder(accounts, decoy),
      decoy.secret,
      clear: earlier,
    );
    if (epoch != _epoch) {
      return;
    }
    await _changeEntry(
      (_Entry entry) => _Entry(entry.want, <_Decoy>[
        for (final _Decoy d in entry.decoys)
          d.folder == decoy.folder ? d.withLook(_Decoy.current) : d,
      ], version: entry.version),
    );
  }

  /// A decoy made now, as an account is, its first session right after.
  Future<void> _birth(Directory accounts) async {
    final _Decoy? decoy = await _makeDecoy(accounts);
    if (decoy == null) {
      return;
    }
    await _changeEntry(
      (_Entry entry) => _Entry(entry.want, <_Decoy>[
        ...entry.decoys,
        decoy,
      ], version: entry.version),
    );
    await _firstSession(accounts, decoy);
  }

  /// [decoy] goes (its folder and entries) and a new one takes its place,
  /// as when an account is deleted ([wipeAccount]).
  Future<void> _replace(Directory accounts, _Decoy decoy) async {
    try {
      await _decoyFolder(accounts, decoy).delete(recursive: true);
    } on FileSystemException {
      return;
    }
    await _secrets.forAccount(decoy.secret).deleteAccountEntries();
    await _changeEntry(
      (_Entry entry) => _Entry(entry.want, <_Decoy>[
        for (final _Decoy d in entry.decoys)
          if (d.folder != decoy.folder) d,
      ], version: entry.version),
    );
    await _birth(accounts);
  }

  /// Runs [work] at a random moment of this run (within
  /// [decoyTurnWithin]); dropped when the device's data is wiped before.
  /// Nothing about a single folder is logged.
  void _later(Future<void> Function() work) {
    final int epoch = _epoch;
    final Duration wait = Duration(
      milliseconds:
          2000 + _random.nextInt(decoyTurnWithin.inMilliseconds - 2000),
    );
    final Completer<void> done = Completer<void>();
    _running.add(done.future);
    unawaited(() async {
      try {
        await _pause(wait);
        if (epoch == _epoch) {
          await work();
        }
      } on Object catch (error) {
        logZenWarning('Looking after the decoys failed: ${error.runtimeType}');
      } finally {
        _running.remove(done.future);
        done.complete();
      }
    }());
  }

  /// Once per process: the decoys of the device get their turns for this
  /// run ([_later]): a "used" one now and then a session, one whose first
  /// session was cut short that session, one of an earlier version (from
  /// the second run of this version on, so the update itself changes no
  /// file) a first session that replaces what it held; a new decoy while
  /// the device has fewer than its number, and now and then one replaced.
  Future<void> _tendDecoys(Directory accounts) async {
    try {
      if (!await accounts.exists()) {
        return;
      }
      final _Entry entry = await _readEntry();
      final List<_Decoy> kept = <_Decoy>[];
      bool changed = entry.version < 2;
      final Set<String> folders = <String>{
        await for (final FileSystemEntity e in accounts.list(
          followLinks: false,
        ))
          if (e is Directory)
            e.uri.pathSegments.where((String s) => s.isNotEmpty).last,
      };
      for (final _Decoy decoy in entry.decoys) {
        if (!folders.contains(decoy.folder)) {
          // Gone (by hand): its entries go too.
          await _secrets.forAccount(decoy.secret).deleteAccountEntries();
          changed = true;
          continue;
        }
        kept.add(decoy);
      }
      bool found = false;
      for (final String name in folders) {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(name) ||
            kept.any((_Decoy d) => d.folder == name) ||
            !ZenAccountDecoys.hasEarlierLook(
              Directory('${accounts.path}${Platform.pathSeparator}$name'),
            )) {
          continue;
        }
        // A decoy of 1.16.3 and before (in no list): its entries now, its
        // files at a later start, as any decoy of an earlier version.
        final _Decoy decoy = _Decoy(
          name,
          _randomBytes(32),
          used: _random.nextBool(),
        );
        await ZenAccountDecoys(
          _random,
        ).plantSecrets(_secrets.forAccount(decoy.secret));
        kept.add(decoy);
        changed = found = true;
      }
      // A device of an earlier version keeps the number it has.
      final int want = entry.version < 2 || found
          ? max(kept.length, minDecoys)
          : entry.want;
      if (changed) {
        await _changeEntry((_Entry _) => _Entry(want, kept));
      }
      if (entry.version < 2 || found) {
        // The first run of this version on a device of an earlier one:
        // the decoys are only taken over; their files change later.
        return;
      }
      for (final _Decoy decoy in kept) {
        switch (decoy.look) {
          case _Decoy.earlier:
            if (_random.nextDouble() < earlierDecoyChance) {
              _later(() => _firstSession(accounts, decoy));
            }
          case _Decoy.made:
            _later(() => _firstSession(accounts, decoy));
          default:
            if (decoy.used && _random.nextDouble() < decoyUseChance) {
              _later(
                () => _decoys().session(
                  _decoyFolder(accounts, decoy),
                  decoy.secret,
                ),
              );
            }
        }
      }
      if (kept.length < want) {
        if (_random.nextDouble() < decoyBirthChance) {
          _later(() => _birth(accounts));
        }
      } else if (kept.isNotEmpty &&
          kept.every((_Decoy d) => d.look == _Decoy.current) &&
          _random.nextDouble() < decoyReplaceChance) {
        final _Decoy gone = kept[_random.nextInt(kept.length)];
        _later(() => _replace(accounts, gone));
      }
    } on Object catch (error) {
      logZenWarning('Looking after the decoys failed: ${error.runtimeType}');
    }
  }

  Future<_Entry> _readEntry() async {
    final String? raw = await _secrets.read(decoysStorageKey);
    if (raw == null) {
      return _Entry(minDecoys, <_Decoy>[]);
    }
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) {
        return _Entry(minDecoys, <_Decoy>[]);
      }
      final List<_Decoy> decoys = <_Decoy>[
        if (json['d'] is List)
          for (final Object? item in json['d'] as List) ?_Decoy.fromJson(item),
      ];
      final Object? want = json['w'];
      final Object? version = json['v'];
      return _Entry(
        want is int ? want.clamp(minDecoys, maxDecoys) : decoys.length,
        decoys,
        version: version is int ? version : 1,
      );
    } on FormatException {
      return _Entry(minDecoys, <_Decoy>[]);
    }
  }

  /// Reads the device's entry, changes it with [change] and writes it, one
  /// change at a time in this process.
  Future<void> _changeEntry(_Entry Function(_Entry entry) change) {
    final Future<void> next = _entryChanges.then((_) async {
      final _Entry entry = change(await _readEntry());
      await _secrets.write(
        decoysStorageKey,
        jsonEncode(<String, Object>{
          'v': entry.version,
          'w': entry.want,
          'd': <Map<String, Object>>[
            for (final _Decoy d in entry.decoys) d.toJson(),
          ],
        }),
      );
    });
    _entryChanges = next.catchError((Object _) {});
    return next;
  }

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

  String _hex(int bytes) => _randomBytes(
    bytes,
  ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}
