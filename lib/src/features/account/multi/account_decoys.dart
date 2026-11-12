import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// How a file of an account's folder is written. A decoy's files go
/// through the very code an account's go through (or, where that code
/// needs the account's keys, through the same steps), so their names,
/// earlier generations, temporary files and times come out as an
/// account's do. Nothing here sets a file's time.
enum _Way {
  /// The data store (`data/`): [FileBinaryStore] as persistent_stores.dart
  /// opens it (sealed, the names under [kZenHiddenNamePrefixes] hashed,
  /// earlier generations kept).
  data,

  /// The settings store (`settings/`), not sealed.
  settings,

  /// Saved in one move ([writeFileAtomically]): the node's pins and peers,
  /// the background kits, the language.
  atomic,

  /// The node config and its copy (`.bak`), each saved in one move
  /// (runtime_native_signal_transport.dart).
  nodeConfig,

  /// Written beside as `.next`, then moved over it (the alarm kit).
  next,

  /// Appended to (the background inbox, sealed_inbox.dart).
  append,

  /// A media vault file: `<name>.tmp`, then renamed (media_vault.dart).
  vault,
}

/// One name an account's folder can hold.
@immutable
final class _Name {
  const _Name(
    this.path, {
    this.way = _Way.data,
    this.first = 0,
    required this.used,
    required this.min,
    required this.max,
    this.large = 0,
    this.many = false,
    this.background = false,
  });

  /// A key of the data or settings store, or a path inside the account's
  /// folder (`/`-separated); a `{…}` part is random ([_expand]).
  final String path;

  final _Way way;

  /// How likely an account has it after its first session (opened once,
  /// its password set, its node started).
  final double first;

  /// How likely an account in use has it.
  final double used;

  /// Sizes of the file on the disk.
  final int min;
  final int max;

  /// When above [max]: how large the file of an account that keeps much
  /// in it gets; one in four of its writes is between [max] and this.
  final int large;

  /// A kind of file an account has several of (one per friend, per
  /// message, per piece).
  final bool many;

  /// Only in an account whose files the background service keeps (on
  /// Android every account opened in front writes these too).
  final bool background;

  /// Where it lies inside the account's folder.
  String get place => switch (way) {
    _Way.data => 'data/$path.zenbin',
    _Way.settings => 'settings/$path.zenbin',
    _ => path,
  };
}

/// Every name the app writes into an account's folder outside the hidden
/// names ([kZenHiddenNamePrefixes], [_hiddenKey]): the data store's keys,
/// the settings, the node's files, the background folder, the language,
/// the media vault. A key added to the app needs its line here (the test
/// of the decoys reads the keys out of the code and holds them to this
/// list). Sizes are of the sealed files.
const List<_Name> _names = <_Name>[
  _Name(
    'settings/app',
    way: _Way.settings,
    first: 0.97,
    used: 0.99,
    min: 420,
    max: 1700,
  ),
  _Name(
    'runtime/yggdrasil.config.json',
    way: _Way.nodeConfig,
    first: 0.95,
    used: 0.98,
    min: 800,
    max: 1150,
  ),
  _Name(
    'runtime/yggdrasil.pins',
    way: _Way.atomic,
    first: 0.15,
    used: 0.6,
    min: 90,
    max: 9000,
  ),
  _Name(
    'runtime/public_peers.json',
    way: _Way.atomic,
    used: 0.05,
    min: 150,
    max: 4200,
  ),
  _Name('language.txt', way: _Way.atomic, used: 0.04, min: 2, max: 7),
  _Name('user_profile', first: 0.9, used: 0.97, min: 140, max: 2600),
  _Name('social/hub', first: 0.85, used: 0.96, min: 300, max: 90000),
  _Name('relay/state', first: 0.5, used: 0.8, min: 150, max: 3200),
  _Name('signals/pending', first: 0.3, used: 0.6, min: 90, max: 4000),
  _Name('groups', used: 0.5, min: 110, max: 7000),
  _Name('ui/last_place', first: 0.6, used: 0.92, min: 90, max: 300),
  _Name('ui/drafts', used: 0.3, min: 100, max: 2200),
  _Name('ui/feed_filter', used: 0.25, min: 90, max: 200),
  _Name('ui/rail_hidden', used: 0.05, min: 90, max: 120),
  _Name('update/book', first: 0.5, used: 0.85, min: 200, max: 6000),
  _Name('census/state', first: 0.3, used: 0.7, min: 100, max: 3000),
  _Name('feed/notified_posts', used: 0.5, min: 90, max: 4000),
  _Name('feed/notified_mentions', used: 0.2, min: 90, max: 2000),
  _Name('feed/mention_budget', used: 0.15, min: 90, max: 600),
  _Name('feed/reach', used: 0.4, min: 90, max: 6000),
  _Name('feed/seen_reactions', used: 0.4, min: 90, max: 4000),
  _Name('feed/notified_reactions', used: 0.35, min: 90, max: 3000),
  _Name('chat/location_shares', used: 0.05, min: 90, max: 1500),
  _Name('chat/scheduled', used: 0.08, min: 90, max: 3000),
  _Name('chat/strangers', used: 0.15, min: 90, max: 6000),
  _Name('notes/self', used: 0.2, min: 90, max: 9000),
  _Name('dating/state', used: 0.05, min: 120, max: 5000),
  _Name('films/state', used: 0.1, min: 90, max: 2000),
  _Name('recordings/index', used: 0.05, min: 90, max: 2000),
  _Name('qr/stickers', used: 0.05, min: 90, max: 3000),
  _Name('neighbors/state', used: 0.1, min: 150, max: 8000),
  _Name('meet/state', used: 0.4, min: 120, max: 6000),
  _Name('meet/table', used: 0.1, min: 90, max: 3000),
  _Name('meet/intros', used: 0.1, min: 90, max: 3000),
  _Name('meet/plans', used: 0.1, min: 90, max: 3000),
  _Name('meet/encounters', used: 0.2, min: 90, max: 4000),
  _Name('meet/questions', used: 0.1, min: 90, max: 3000),
  _Name('meet/events', used: 0.15, min: 90, max: 5000),
  _Name('meet/food', used: 0.05, min: 90, max: 3000),
  _Name('meet/circles', used: 0.15, min: 90, max: 4000),
  _Name('meet/vouched', used: 0.3, min: 90, max: 6000),
  _Name('pebbles/index', used: 0.1, min: 90, max: 2000),
  _Name('pebbles/door', used: 0.1, min: 90, max: 200),
  _Name('pebbles/profile_hash', used: 0.1, min: 90, max: 200),
  _Name('pebbles/design/{b32}', used: 0.08, min: 120, max: 3000, many: true),
  _Name('pyramid/ledger', used: 0.05, min: 120, max: 9000),
  _Name('pyramid/me', used: 0.08, min: 90, max: 2000),
  _Name('pyramid/records', used: 0.03, min: 90, max: 4000),
  _Name('pyramid/records/idx', used: 0.05, min: 90, max: 300),
  _Name('pyramid/records/{n}', used: 0.05, min: 90, max: 9000, many: true),
  _Name('pyramid/reports', used: 0.03, min: 90, max: 3000),
  _Name('pyramid/verdicts', used: 0.03, min: 90, max: 3000),
  _Name('pyramid/national', used: 0.05, min: 90, max: 4000),
  _Name('pyramid/recovered', used: 0.01, min: 90, max: 600),
  _Name('recovery/circle', used: 0.25, min: 90, max: 2000),
  _Name('recovery/held', used: 0.2, min: 120, max: 9000),
  _Name('recovery/acks', used: 0.1, min: 90, max: 1500),
  _Name('recovery/pending', used: 0.05, min: 90, max: 3000),
  _Name('recovery/received', used: 0.05, min: 90, max: 6000),
  _Name('recovery/collecting', used: 0.03, min: 90, max: 3000),
  _Name('recovery/requests', used: 0.05, min: 90, max: 2000),
  _Name('account/contacts', used: 0.1, min: 90, max: 3000),
  _Name('account/history', used: 0.03, min: 90, max: 6000),
  _Name('account/sync/state', used: 0.1, min: 90, max: 2000),
  _Name('account/sync/photos', used: 0.05, min: 90, max: 2000),
  _Name('account/sync/media_pending', used: 0.03, min: 90, max: 1500),
  _Name('account/sync/{sync}', used: 0.08, min: 90, max: 4000, many: true),
  _Name('account/import/manifest', used: 0.01, min: 90, max: 4000),
  _Name('account/import/summary', used: 0.02, min: 90, max: 1500),
  _Name(
    'account/import/b/{h64}/{n}',
    used: 0.01,
    min: 120,
    max: 300000,
    many: true,
  ),
  _Name('group_board/{h32}', used: 0.1, min: 120, max: 9000, many: true),
  _Name('relay/out/{rid}', used: 0.15, min: 300, max: 200000, many: true),
  _Name(
    'relay/blob/{blob}/{h32}/{n}',
    used: 0.1,
    min: 300,
    max: 70000,
    many: true,
  ),
  _Name(
    'transfers/{io}/{h32}/{h32}',
    used: 0.1,
    min: 300,
    max: 300000,
    many: true,
  ),
  _Name(
    'vault/{h32}.zmedia',
    way: _Way.vault,
    used: 0.85,
    min: 2000,
    max: 400000,
    many: true,
  ),
  _Name(
    'background/capability.zenbg',
    way: _Way.atomic,
    first: 0.6,
    used: 0.95,
    min: 300,
    max: 2600,
    background: true,
  ),
  _Name(
    'background/outbox-kit.zenbg',
    way: _Way.atomic,
    first: 0.3,
    used: 0.7,
    min: 120,
    max: 30000,
    background: true,
  ),
  _Name(
    'background/mailbox-kit.zenbg',
    way: _Way.atomic,
    used: 0.5,
    min: 120,
    max: 3000,
    background: true,
  ),
  _Name(
    'background/mailbox-held.zenbg',
    way: _Way.atomic,
    used: 0.2,
    min: 120,
    max: 20000,
    background: true,
  ),
  // Names, levels and a tag for each member of each joined group (about 35
  // bytes a member): a few groups make it tens of kilobytes.
  _Name(
    'background/notice-kit.zenbg',
    way: _Way.atomic,
    first: 0.3,
    used: 0.6,
    min: 120,
    max: 40000,
    background: true,
  ),
  _Name(
    'background/presence-kit.zenbg',
    way: _Way.atomic,
    first: 0.3,
    used: 0.6,
    min: 120,
    max: 1500,
    background: true,
  ),
  _Name(
    'background/nearby-kit.zenbg',
    way: _Way.atomic,
    used: 0.3,
    min: 120,
    max: 2000,
    background: true,
  ),
  _Name(
    'background/door-kit.zenbg',
    way: _Way.atomic,
    used: 0.1,
    min: 120,
    max: 1500,
    background: true,
  ),
  _Name(
    'background/alarm-kit.zenbg',
    way: _Way.next,
    used: 0.1,
    min: 200,
    max: 4000,
    background: true,
  ),
  _Name(
    'background/presence.zbox',
    way: _Way.atomic,
    used: 0.3,
    min: 100,
    max: 6000,
    background: true,
  ),
  _Name(
    'background/inbox.zbox',
    way: _Way.append,
    used: 0.4,
    min: 0,
    max: 24000,
    background: true,
  ),
  // The passwords (from 1.16.5): a few hand-made entries to an imported
  // export of hundreds (random passwords do not compress), and now and
  // then as large as the vault can be (`kMaxPasswordVaultBytes`, 4 MiB of
  // JSON before the store compresses it: 2000 logins with their history),
  // so no size a real vault reaches is one no decoy has.
  _Name(
    'passwords/vault',
    used: 0.15,
    min: 160,
    max: 60000,
    large: 4 * 1024 * 1024,
  ),
  // The copy with friends (from 1.16.5 every account with a friend makes
  // one, circle or not, and keeps its friends'): its state, the index of
  // the copies kept here and their chunks (named by 32 hex digits).
  _Name('circle-backup/status', used: 0.6, min: 90, max: 200),
  _Name('circle-backup/held', used: 0.4, min: 120, max: 12000),
  _Name('circle-backup/restore', used: 0.01, min: 90, max: 400),
  _Name(
    'circle-backup/k/{h32}/{h32}',
    used: 0.4,
    min: 120,
    max: 200000,
    many: true,
  ),
  // The recovery pieces (from 1.16.5 every close friend holds one by
  // itself): those kept for friends by account, this account's password
  // seal, its generation and what it hands out.
  _Name('recovery/pieces', used: 0.35, min: 120, max: 60000),
  _Name('recovery/sealed', used: 0.25, min: 150, max: 300),
  _Name('recovery/gen', used: 0.25, min: 120, max: 3000),
  _Name('recovery/out', used: 0.25, min: 200, max: 30000),
];

/// What `account/sync/<id>` is kept for (account_state_sync_app.dart).
const List<String> _syncIds = <String>[
  'settings',
  'relay',
  'dating',
  'profile',
  'meet/questions',
  'meet/plans',
  'meet/events',
  'meet/intros',
  'meet/table',
  'meet/food',
  'meet/circles',
  'held/household',
  'held/chat/strangers',
];

/// Data store keys that come and go (an outbox entry until it is sent,
/// the pieces of a transfer or an import).
const List<String> _passing = <String>[
  'relay/out/',
  'relay/blob/',
  'transfers/',
  'account/import/',
];

/// The secret-store entries every account with a password has.
const List<String> _baseSecrets = <String>[
  appSecurityPasswordKdfStorageKey,
  appSecuritySaltStorageKey,
  appSecurityPasswordHashStorageKey,
  appSecurityWrappedMasterKeyStorageKey,
  appSecurityMasterKeyFingerprintStorageKey,
  appSecurityGuardedSettingsStorageKey,
  appSecurityPanicStandInSaltStorageKey,
];

/// Folders and secret-store entries that look like an additional account's
/// to anyone who lists the folders or the names of the secret store's
/// entries.
///
/// A decoy is written as an account is used, never planted with a history:
/// its folder is made, then a first session saves what an account's first
/// session does ([open]), and a decoy "in use" later gets sessions now and
/// then while Zen runs ([session]): files saved again (their earlier
/// generations moving down), new ones of the names an account in use
/// gets. Every file goes through the stores and steps the app's own files
/// go through, at the moment it is written, a moment apart from the next
/// one; no time is set or moved back. What is in the files is random:
/// nothing ever opens a decoy (no account ID leads to it).
final class ZenAccountDecoys {
  ZenAccountDecoys(
    Random random, {
    Future<void> Function(Duration)? pause,
    bool Function()? keepGoing,
  }) : _random = random,
       _bytes = Random(random.nextInt(1 << 32)),
       _pause = pause ?? _wait,
       _keepGoing = keepGoing ?? _always;

  /// Picks what to write and when.
  final Random _random;

  /// The files' contents (only need to look random).
  final Random _bytes;

  /// Waits between two saves (tests make it short).
  final Future<void> Function(Duration) _pause;

  /// Whether to go on: false once the device's data was wiped meanwhile.
  final bool Function() _keepGoing;

  static Future<void> _wait(Duration d) => Future<void>.delayed(d);
  static bool _always() => true;

  /// The names [open] and [session] may write, as places inside an
  /// account's folder (`{…}` parts random).
  @visibleForTesting
  static List<String> get debugPlaces => <String>[
    for (final _Name name in _names) name.place,
  ];

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

  /// The first session of the account in [folder] (named by [secret]):
  /// what an account has once it was opened, its password set and its
  /// node started, saved a moment apart. With [clear], what [folder] held
  /// goes first (a decoy of an earlier version, whose files were planted
  /// with set times).
  Future<void> open(
    Directory folder,
    Uint8List secret, {
    bool clear = false,
  }) async {
    if (clear && await folder.exists()) {
      await for (final FileSystemEntity e in folder.list(followLinks: false)) {
        await e.delete(recursive: true);
      }
    }
    await folder.create(recursive: true);
    final _Place place = _Place(folder, secret, _bytes);
    final List<Future<void> Function()> saves = <Future<void> Function()>[
      () => _sweep(place),
      for (final _Name name in _names)
        if (name.first > 0 &&
            (!name.background || place.background) &&
            _random.nextDouble() < name.first)
          () => _write(place, name),
      for (int i = 0, n = 1 + _random.nextInt(5); i < n; i++)
        () => _writeHidden(place, i),
    ];
    await _run(
      place,
      saves,
      shortest: const Duration(milliseconds: 300),
      longest: const Duration(seconds: 6),
    );
  }

  /// Something like a later session of the account in [folder]: some of
  /// its files saved again, now and then new ones of the names an account
  /// in use gets, messages and posts (hidden names), media; a piece that
  /// was passing through gone. Saves a while apart, as a person uses it.
  Future<void> session(Directory folder, Uint8List secret) async {
    if (!await folder.exists()) {
      return;
    }
    final _Place place = _Place(folder, secret, _bytes);
    final Set<String> present = _placesIn(folder);
    final List<String> keys = <String>[
      for (final String p in present)
        if (p.startsWith('data/') &&
            p.endsWith('.zenbin') &&
            !p.startsWith('data/$kHiddenNamesFolder/'))
          p.substring('data/'.length, p.length - '.zenbin'.length),
    ];
    final int hidden = await _hiddenCount(place);
    final List<Future<void> Function()> saves = <Future<void> Function()>[
      for (int i = 0, n = 1 + _random.nextInt(4); i < n && keys.isNotEmpty; i++)
        _again(place, keys[_random.nextInt(keys.length)]),
      if (_random.nextInt(4) == 0)
        () => _write(place, _names.first, again: true),
      for (int i = 0, n = _random.nextInt(4); i < n; i++)
        hidden > 0 && _random.nextBool()
            ? () => _writeHidden(place, _random.nextInt(hidden))
            : () => _writeHidden(place, hidden + i),
      for (int i = 0, n = _random.nextInt(3); i < n; i++)
        ?_newName(place, present),
      if (place.media && _random.nextInt(3) == 0)
        for (int i = 0, n = 1 + _random.nextInt(3); i < n; i++)
          () => _write(place, _vault),
      for (final _Name name in _names)
        if (name.way != _Way.data &&
            name.way != _Way.settings &&
            !name.many &&
            name.way != _Way.nodeConfig &&
            present.contains(_folded(name.place)) &&
            _random.nextInt(4) == 0)
          () => _write(place, name, again: true),
      if (_random.nextInt(5) == 0) ?_passed(place, keys),
    ];
    if (saves.isEmpty) {
      return;
    }
    saves.shuffle(_random);
    await _run(
      place,
      <Future<void> Function()>[() => _sweep(place), ...saves],
      shortest: const Duration(seconds: 2),
      longest: const Duration(minutes: 4),
    );
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

  static final _Name _vault = _names.firstWhere(
    (_Name n) => n.way == _Way.vault,
  );

  /// Runs [saves] in order, a random while apart (between [shortest] and
  /// [longest]); stops when the folder went or [_keepGoing] says so.
  Future<void> _run(
    _Place place,
    List<Future<void> Function()> saves, {
    required Duration shortest,
    required Duration longest,
  }) async {
    for (int i = 0; i < saves.length; i++) {
      if (!_keepGoing() || !await place.folder.exists()) {
        return;
      }
      await saves[i]();
      if (i + 1 < saves.length) {
        final int span = longest.inMilliseconds - shortest.inMilliseconds;
        await _pause(
          shortest + Duration(milliseconds: _random.nextInt(span + 1)),
        );
      }
    }
  }

  /// The sweep of leftover temporary files every start of an account runs
  /// on its data store (it leaves the `.swept` marker).
  Future<void> _sweep(_Place place) =>
      place.data.sweepOrphanTemporaries(every: const Duration(days: 1));

  /// The key [key] of the data store saved again, a little smaller or
  /// bigger than it was.
  Future<void> Function() _again(_Place place, String key) => () async {
    final File file = File(_platformPath(place.folder, 'data/$key.zenbin'));
    final int size = await file.exists() ? await file.length() : 0;
    final int next = max(
      0,
      size + (size * (_random.nextDouble() - 0.4) * 0.3).round(),
    );
    await place.data.write(key, _payload(next - _sealedOverhead));
  };

  /// A name the account did not have yet, picked by how likely an account
  /// in use has it; `null` when nothing is left.
  Future<void> Function()? _newName(_Place place, Set<String> present) {
    final List<_Name> open = <_Name>[
      for (final _Name name in _names)
        if ((name.many || !present.contains(_folded(name.place))) &&
            (!name.background || place.background) &&
            name.way != _Way.vault)
          name,
    ];
    final double total = open.fold(0, (double a, _Name n) => a + n.used);
    if (open.isEmpty || total <= 0) {
      return null;
    }
    double at = _random.nextDouble() * total;
    for (final _Name name in open) {
      at -= name.used;
      if (at <= 0) {
        return () => _write(place, name);
      }
    }
    return () => _write(place, open.last);
  }

  /// One of the keys that come and go, gone (sent, assembled, imported).
  Future<void> Function()? _passed(_Place place, List<String> keys) {
    final List<String> passing = <String>[
      for (final String key in keys)
        if (_passing.any(key.startsWith)) key,
    ];
    if (passing.isEmpty) {
      return null;
    }
    final String key = passing[_random.nextInt(passing.length)];
    return () => place.data.delete(key);
  }

  Future<void> _write(_Place place, _Name name, {bool again = false}) async {
    final String path = _expand(name.path);
    final int size = _sizeOf(name);
    switch (name.way) {
      case _Way.data:
        await place.data.write(path, _payload(size - _sealedOverhead));
      case _Way.settings:
        await place.settings.write(path, _payload(size - _envelopeOverhead));
      case _Way.atomic:
        await writeFileAtomically(
          File(_platformPath(place.folder, path)),
          _payload(size),
        );
      case _Way.nodeConfig:
        if (again) {
          return;
        }
        final File file = File(_platformPath(place.folder, path));
        final Uint8List bytes = _payload(size);
        await writeFileAtomically(file, bytes);
        await writeFileAtomically(File('${file.path}.bak'), bytes);
      case _Way.next:
        final File file = File(_platformPath(place.folder, path));
        await file.parent.create(recursive: true);
        final File next = File('${file.path}.next');
        await next.writeAsBytes(_payload(size), flush: true);
        await next.rename(file.path);
      case _Way.append:
        final File file = File(_platformPath(place.folder, path));
        await file.parent.create(recursive: true);
        final RandomAccessFile out = await file.open(mode: FileMode.append);
        try {
          await out.writeFrom(_payload(80 + _random.nextInt(900)));
          await out.flush();
        } finally {
          await out.close();
        }
      case _Way.vault:
        final File file = File(_platformPath(place.folder, path));
        await file.parent.create(recursive: true);
        final File temporary = File('${file.path}.tmp');
        await temporary.writeAsBytes(
          _payload(_random.nextInt(10) == 0 ? _size(size, 2500000) : size),
          flush: true,
        );
        await temporary.rename(file.path);
    }
  }

  /// A file of the data store whose name is hidden (a thread, a post's
  /// entry, mail held for a friend): the key itself is never seen, only
  /// its keyed hash ([FileBinaryStore]), so the [index]-th of the account
  /// will do.
  Future<void> _writeHidden(_Place place, int index) => place.data.write(
    _hiddenKey(index),
    _payload(
      _size(80, _random.nextInt(4) == 0 ? 60000 : 4000) - _sealedOverhead,
    ),
  );

  static String _hiddenKey(int index) => 'threads/decoy-$index';

  /// How many hidden files [_writeHidden] wrote so far.
  Future<int> _hiddenCount(_Place place) async {
    int count = 0;
    while (count < 4000 && await place.data.exists(_hiddenKey(count))) {
      count++;
    }
    return count;
  }

  String _expand(String template) =>
      template.replaceAllMapped(RegExp(r'\{(\w+)\}'), (Match m) {
        switch (m.group(1)) {
          case 'h32':
            return _hex(16);
          case 'h64':
            return _hex(32);
          case 'n':
            return '${_random.nextInt(40)}';
          case 'io':
            return _random.nextBool() ? 'in' : 'out';
          case 'blob':
            return const <String>['o', 'p', 'h', 'i'][_random.nextInt(4)];
          case 'sync':
            return _syncIds[_random.nextInt(_syncIds.length)];
          case 'b32':
            const String alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
            return <String>[
              for (int i = 0; i < 26; i++) alphabet[_random.nextInt(32)],
            ].join();
          case 'rid':
            // relay_engine.dart: `r`, the time and two random numbers in
            // base 36, kept under its base64url form.
            final String rid =
                'r${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
                '${_random.nextInt(1 << 32).toRadixString(36)}'
                '${_random.nextInt(1 << 32).toRadixString(36)}';
            return base64Url.encode(utf8.encode(rid)).replaceAll('=', '');
        }
        return m.group(0)!;
      });

  /// `ZENENC2`, the nonce and the tag of a sealed file, and the store's
  /// envelope inside it.
  static const int _envelopeOverhead = 48;
  static const int _sealedOverhead = 7 + 12 + 16 + _envelopeOverhead;

  String _secretValue(String key) => switch (key) {
    appSecurityPasswordKdfStorageKey ||
    appSecurityPanicKdfStorageKey => '{"a":"argon2id","m":19456,"t":2,"p":1}',
    appSecurityWrappedMasterKeyStorageKey => _hex(60),
    appSecurityGuardedSettingsStorageKey => base64Encode(
      _payload(120 + _random.nextInt(80)),
    ),
    _ => _hex(32),
  };

  /// How large [name] is written this time ([_Name.large]).
  int _sizeOf(_Name name) =>
      name.large > name.max && _random.nextInt(_largeOdds) == 0
      ? _size(name.max, name.large)
      : _size(name.min, name.max);

  /// One file of a name with [_Name.large] in this many is a large one.
  static const int _largeOdds = 4;

  /// The sizes [place] (one of [debugPlaces]) is written with: the
  /// smallest and the largest.
  @visibleForTesting
  static (int, int) debugSizesOf(String place) {
    final _Name name = _names.firstWhere((_Name n) => n.place == place);
    return (name.min, name.large > name.max ? name.large : name.max);
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

  Uint8List _payload(int n) {
    final Uint8List out = Uint8List(max(0, n));
    for (int i = 0; i < out.length; i++) {
      out[i] = _bytes.nextInt(256);
    }
    return out;
  }

  String _hex(int bytes) => <String>[
    for (int i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// Every file in [folder], as `/`-separated places inside it ([_folded]).
  static Set<String> _placesIn(Directory folder) {
    final Set<String> places = <String>{};
    try {
      for (final FileSystemEntity e in folder.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (e is File) {
          places.add(
            _folded(
              e.path
                  .substring(folder.path.length + 1)
                  .replaceAll(Platform.pathSeparator, '/'),
            ),
          );
        }
      }
    } on FileSystemException {
      // Changed while listed: what was seen will do.
    }
    return places;
  }

  /// [place] as the data store names it on this system (lower case on
  /// Windows).
  static String _folded(String place) =>
      Platform.isWindows ? place.toLowerCase() : place;

  static String _platformPath(Directory folder, String path) =>
      '${folder.path}${Platform.pathSeparator}'
      '${path.replaceAll('/', Platform.pathSeparator)}';

  static String _nameOf(FileSystemEntity e) =>
      e.path.split(RegExp(r'[/\\]')).where((String s) => s.isNotEmpty).last;
}

/// A decoy's own stores, as an account's are opened on its folder.
final class _Place {
  _Place(this.folder, Uint8List secret, Random bytes)
    : background = secret[1] < (Platform.isAndroid ? 150 : 50),
      media = secret[2] < 215 {
    final _StandInSeal seal = _StandInSeal(
      Uint8List.fromList(
        Hmac(sha256, secret).convert(utf8.encode('store.names')).bytes,
      ),
      bytes,
    );
    final BinaryCodec codec = BinaryCodec(compressor: const _Stored());
    final String sep = Platform.pathSeparator;
    data = FileBinaryStore(
      Directory('${folder.path}${sep}data'),
      codec: codec,
      protector: seal,
    );
    settings = FileBinaryStore(
      Directory('${folder.path}${sep}settings'),
      codec: codec,
    );
  }

  final Directory folder;

  /// Whether it has the background folder's files (on Android every
  /// account opened in front writes some; on a computer only one that
  /// receives in the background).
  final bool background;

  /// Whether it gets media (friends' photos, attachments).
  final bool media;

  late final FileBinaryStore data;
  late final FileBinaryStore settings;
}

/// The data store's seal for a decoy: the envelope of a sealed file
/// (`ZENENC2`, security_payload_protector.dart) around random bytes of the
/// sealed length, and a name key of the decoy's own. Nothing it writes
/// ever opens.
final class _StandInSeal
    implements KeyedBinaryPayloadProtector, BinaryStoreNameKeySource {
  _StandInSeal(this._nameKey, this._bytes);

  static final List<int> _magic = ascii.encode('ZENENC2');

  /// Nonce and tag of AES-GCM.
  static const int _overhead = 12 + 16;

  final Uint8List _nameKey;
  final Random _bytes;

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async {
    final Uint8List out = Uint8List(_magic.length + payload.length + _overhead);
    out.setRange(0, _magic.length, _magic);
    for (int i = _magic.length; i < out.length; i++) {
      out[i] = _bytes.nextInt(256);
    }
    return out;
  }

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) =>
      Future<Uint8List>.error(
        const UnsupportedStoredPayloadException('A decoy never opens.'),
      );

  @override
  Future<Uint8List> seal(Uint8List payload) => sealFor('', payload);

  @override
  Future<Uint8List> unseal(Uint8List payload) => unsealFor('', payload);

  @override
  bool isSealed(Uint8List payload) {
    if (payload.length < _magic.length) {
      return false;
    }
    for (int i = 0; i < _magic.length; i++) {
      if (payload[i] != _magic[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<Uint8List?> fileNameKey() async => _nameKey;
}

/// Leaves a payload as it is (random bytes do not compress anyway).
final class _Stored implements BinaryCompressor {
  const _Stored();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => null;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
