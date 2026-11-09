import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// One file of an account's folder as the app leaves it: where it is, how
/// likely an account has it and how large it is.
@immutable
final class _Part {
  const _Part(
    this.path,
    this.chance, {
    required this.min,
    required this.max,
    this.backups = true,
  });

  /// `/`-separated, inside the account's folder.
  final String path;

  /// How likely a used account has it (an account opened once has the
  /// first ones only, see [_firstSession]).
  final double chance;

  final int min;
  final int max;

  /// Whether the store keeps earlier generations of it (`.bak`, `.bak2`).
  final bool backups;
}

/// What the app writes into an account's folder, the stores and the node's
/// files (persistent_stores.dart, binary_store.dart, the node's runtime
/// folder, the background folder). Sizes are of sealed files.
const List<_Part> _parts = <_Part>[
  _Part('settings/settings/app.zenbin', 0.97, min: 420, max: 1700),
  _Part('data/user_profile.zenbin', 0.96, min: 140, max: 2600),
  _Part('runtime/yggdrasil.config.json', 0.95, min: 760, max: 1100),
  _Part('data/social/hub.zenbin', 0.9, min: 300, max: 90000),
  _Part('runtime/public_peers.json', 0.75, min: 150, max: 4200, backups: false),
  _Part('data/.swept', 0.65, min: 0, max: 0, backups: false),
  _Part('data/relay/state.zenbin', 0.6, min: 150, max: 3200),
  _Part('data/groups.zenbin', 0.5, min: 110, max: 7000),
  _Part('data/signals/pending.zenbin', 0.5, min: 90, max: 4000),
  _Part('runtime/yggdrasil.pins', 0.4, min: 90, max: 3200, backups: false),
  _Part('data/ui/drafts.zenbin', 0.3, min: 100, max: 2200),
  _Part('background/capability.zenbg', 0.18, min: 300, max: 2600),
  _Part('background/inbox.zbox', 0.1, min: 0, max: 24000, backups: false),
  _Part('background/presence.zbox', 0.1, min: 180, max: 3000, backups: false),
];

/// The parts an account has after its first session (opened once, a
/// password set, its node started).
const int _firstSession = 3;

/// Files of up to this size keep two earlier generations (binary_store.dart).
const int _twoBackupsUpTo = 256 * 1024;

/// The secret-store entries every account with a password has.
const List<String> _baseSecrets = <String>[
  appSecurityPasswordKdfStorageKey,
  appSecuritySaltStorageKey,
  appSecurityPasswordHashStorageKey,
  appSecurityWrappedMasterKeyStorageKey,
  appSecurityMasterKeyFingerprintStorageKey,
  appSecurityGuardedSettingsStorageKey,
];

/// Folders and secret-store entries that look like an additional account's
/// to anyone who lists the folders or the names of the secret store's
/// entries: the same tree, names, extensions and spread of sizes, times
/// that move the way a used account's do (or stay, as an unused one's),
/// and entries of the same kind and number. What is in them is random:
/// nothing ever opens a decoy (no account ID leads to it).
final class ZenAccountDecoys {
  ZenAccountDecoys(Random random)
    : _random = random,
      _bytes = Random(random.nextInt(1 << 32));

  /// Picks what to plant and when it happened.
  final Random _random;

  /// The files' contents (only need to look random).
  final Random _bytes;

  /// What the decoys of an earlier version hold: random `<24 hex>.bin`
  /// files in a `settings` and a `data` folder, nothing else. No account
  /// ever has such a file.
  static bool hasEarlierLook(Directory folder) {
    final RegExp file = RegExp(r'^[0-9a-f]{24}\.bin$');
    int files = 0;
    try {
      for (final FileSystemEntity e in folder.listSync(followLinks: false)) {
        final String name = _nameOf(e);
        if (e is! Directory || (name != 'settings' && name != 'data')) {
          return false;
        }
        for (final FileSystemEntity f in e.listSync(followLinks: false)) {
          if (f is! File || !file.hasMatch(_nameOf(f))) {
            return false;
          }
          files++;
        }
      }
    } on FileSystemException {
      return false;
    }
    return files > 0;
  }

  /// The earliest time a file in [folder] was written (when it was made),
  /// or `null` when it holds none.
  static DateTime? madeAt(Directory folder) {
    DateTime? first;
    try {
      for (final FileSystemEntity e in folder.listSync(recursive: true)) {
        if (e is File) {
          final DateTime at = e.lastModifiedSync();
          if (first == null || at.isBefore(first)) {
            first = at;
          }
        }
      }
    } on FileSystemException {
      return first;
    }
    return first;
  }

  /// Fills [folder] (empty, or holding an earlier decoy, which goes) with
  /// an account's files: an account [used] for a while between [since] and
  /// [until], or one opened once at [since] and never since.
  Future<void> plant(
    Directory folder, {
    required bool used,
    required DateTime since,
    required DateTime until,
  }) async {
    if (await folder.exists()) {
      await for (final FileSystemEntity e in folder.list(followLinks: false)) {
        await e.delete(recursive: true);
      }
    }
    await folder.create(recursive: true);
    final DateTime last = until.isBefore(since) ? since : until;
    DateTime when() {
      if (!used) {
        // One session: a few minutes after it was made.
        return since.add(Duration(seconds: _random.nextInt(600)));
      }
      final int span = last.difference(since).inSeconds;
      return since.add(
        Duration(seconds: span <= 0 ? 0 : _random.nextInt(span)),
      );
    }

    for (int i = 0; i < _parts.length; i++) {
      final _Part part = _parts[i];
      final double chance = used || i < _firstSession
          ? part.chance
          : part.chance * 0.15;
      if (_random.nextDouble() >= chance) {
        continue;
      }
      await _write(
        folder,
        part.path,
        _size(part.min, part.max),
        when(),
        part,
        used: used,
        since: since,
      );
    }
    // Files whose names hide what they hold (binary_store.dart, `hidden`).
    final int hidden = used ? 2 + _random.nextInt(46) : _random.nextInt(4);
    for (int i = 0; i < hidden; i++) {
      await _write(
        folder,
        _hiddenPath(),
        _size(80, _random.nextInt(4) == 0 ? 60000 : 4000),
        when(),
        const _Part('', 1, min: 0, max: 0),
        used: used,
        since: since,
      );
    }
  }

  /// Something like a session of the account: a few of its files saved
  /// again (with their earlier generations moved down, as the store does),
  /// now and then a new one.
  Future<void> use(Directory folder) async {
    final List<File> files = <File>[
      for (final FileSystemEntity e in folder.listSync(recursive: true))
        if (e is File &&
            !_nameOf(e).endsWith('.bak') &&
            !_nameOf(e).endsWith('.bak2') &&
            !_nameOf(e).endsWith('.tmp') &&
            !_nameOf(e).startsWith('.'))
          e,
    ];
    if (files.isEmpty) {
      return;
    }
    final int saves = 1 + _random.nextInt(4);
    for (int i = 0; i < saves; i++) {
      final File file = files[_random.nextInt(files.length)];
      final int size = file.lengthSync();
      final int next = max(
        0,
        size + (size * (_random.nextDouble() - 0.4) * 0.3).round(),
      );
      await _save(file, next, keepsBackups: !file.path.endsWith('.zbox'));
    }
    if (_random.nextInt(3) == 0) {
      final File file = File(_platformPath(folder, _hiddenPath()));
      await file.parent.create(recursive: true);
      await _save(file, _size(80, 4000), keepsBackups: true);
    }
  }

  /// The secret-store entries of an account with a password, under
  /// [account] (the store of a random secret): the same names an account
  /// writes, so the same number of hashed names, with values of their
  /// shape.
  Future<void> plantSecrets(SecureStorageCredentialsStore account) async {
    final Map<String, String> values = <String, String>{
      for (final String key in _baseSecrets) key: _secretValue(key),
      if (_random.nextInt(6) == 0) ...<String, String>{
        appSecurityPanicKdfStorageKey: _secretValue(
          appSecurityPanicKdfStorageKey,
        ),
        appSecurityPanicSaltStorageKey: _hex(32),
        appSecurityPanicPasswordHashStorageKey: _hex(32),
      },
      if (_random.nextInt(4) == 0)
        appSecurityBiometricUnlockChoiceStorageKey: _random.nextBool()
            ? '1'
            : '0',
      if (_random.nextInt(6) == 0) appSecurityBackgroundKeyStorageKey: _hex(32),
    };
    for (final MapEntry<String, String> entry in values.entries) {
      await account.write(entry.key, entry.value);
    }
  }

  String _secretValue(String key) => switch (key) {
    appSecurityPasswordKdfStorageKey ||
    appSecurityPanicKdfStorageKey => '{"a":"argon2id","m":19456,"t":2,"p":1}',
    appSecurityWrappedMasterKeyStorageKey => _hex(60),
    appSecurityGuardedSettingsStorageKey => base64Encode(
      _randomBytes(120 + _random.nextInt(80)),
    ),
    _ => _hex(32),
  };

  String _hiddenPath() {
    final String name = _hex(20);
    return 'data/hidden/${name.substring(0, 2)}/$name.zenbin';
  }

  Future<void> _write(
    Directory folder,
    String path,
    int size,
    DateTime at,
    _Part part, {
    required bool used,
    required DateTime since,
  }) async {
    final File file = File(_platformPath(folder, path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_randomBytes(size));
    await file.setLastModified(at);
    if (!part.backups ||
        (!path.endsWith('.zenbin') && !path.endsWith('.json'))) {
      return;
    }
    // Saved more than once: the generations before it, a little older (in
    // the same session for an account opened once).
    DateTime earlier = at;
    for (final String suffix in const <String>['.bak', '.bak2']) {
      if (_random.nextInt(used ? 3 : 8) != 0 ||
          (suffix == '.bak2' && size > _twoBackupsUpTo)) {
        return;
      }
      earlier = earlier.subtract(
        Duration(seconds: 5 + _random.nextInt(used ? 86400 : 120)),
      );
      if (earlier.isBefore(since)) {
        earlier = since;
      }
      final File backup = File('${file.path}$suffix');
      final int drift = (size * 0.1).round();
      await backup.writeAsBytes(
        _randomBytes(max(0, size - drift + _random.nextInt(drift + 1))),
      );
      await backup.setLastModified(earlier);
    }
  }

  /// Writes [file] the way the store saves: the new content beside it,
  /// then the file and its first backup moved down a generation, then the
  /// new one moved into place.
  Future<void> _save(File file, int size, {required bool keepsBackups}) async {
    final File temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp',
    );
    await temporary.writeAsBytes(_randomBytes(size));
    final File backup = File('${file.path}.bak');
    if (keepsBackups && await file.exists()) {
      if (size <= _twoBackupsUpTo && await backup.exists()) {
        await backup.rename('${file.path}.bak2');
      }
      await file.rename(backup.path);
    }
    await temporary.rename(file.path);
  }

  int _size(int min, int max) {
    if (max <= min) {
      return min;
    }
    // Most files are small, a few large: even on a logarithmic scale.
    final double low = log(min + 1);
    final double high = log(max + 1);
    return (exp(low + (high - low) * _random.nextDouble()) - 1).round();
  }

  Uint8List _randomBytes(int n) {
    final Uint8List out = Uint8List(n);
    for (int i = 0; i < n; i++) {
      out[i] = _bytes.nextInt(256);
    }
    return out;
  }

  String _hex(int bytes) => <String>[
    for (int i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  static String _platformPath(Directory folder, String path) =>
      '${folder.path}${Platform.pathSeparator}'
      '${path.replaceAll('/', Platform.pathSeparator)}';

  static String _nameOf(FileSystemEntity e) =>
      e.path.split(RegExp(r'[/\\]')).where((String s) => s.isNotEmpty).last;
}
