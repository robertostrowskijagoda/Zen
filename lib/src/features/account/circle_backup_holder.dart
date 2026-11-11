import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/circle_backup.dart';

/// Most bytes all the copies this device keeps for others take.
const int kCircleBackupHolderTotalBytes = 100 * 1024 * 1024;

/// Of those, most bytes the copies of friends whose recovery key this
/// device does not keep take together (the circles' copies always find
/// room).
const int kCircleBackupFriendsBytes = 60 * 1024 * 1024;

/// What a holder said to a copy offered to it.
enum CircleBackupOfferResult {
  /// Taken: [CircleBackupHolder.missing] lists what to send.
  accepted,

  /// This device keeps no recovery key of that account, and it is not an
  /// accepted friend here (the name is the one 1.16.4 sends, which knows
  /// only the circle).
  notInCircle,

  /// Not signed by a device of the account.
  badSignature,

  /// Bigger than one copy may be, or no room left here.
  tooBig,

  /// Older than the copy kept already.
  stale,
}

/// The copies of other people's data this device keeps for them: sealed
/// chunks it cannot open, under the account they belong to, at most
/// [kCircleBackupMaxBytes] (and a little) each and [totalBytes] in all.
///
/// Whose: the accounts whose recovery key this device keeps
/// ([isInCircle]), and the accounts of its accepted friends ([isFriend]),
/// these within [friendsBytes] together. A copy goes when neither is true
/// any more ([prune]: the key went, the friendship ended) or when the
/// person here drops it ([drop]). Its chunks are named by their id's first
/// 32 hex digits (copies kept by earlier versions under the whole id are
/// renamed at [load]), as the decoy accounts' files are.
final class CircleBackupHolder {
  CircleBackupHolder({
    required this.disk,
    required this.isInCircle,
    bool Function(String account)? isFriend,
    this.totalBytes = kCircleBackupHolderTotalBytes,
    this.friendsBytes = kCircleBackupFriendsBytes,
    this.perAccountBytes = kCircleBackupMaxBytes + kCircleBackupMaxBytes ~/ 10,
  }) : isFriend = isFriend ?? _nobody;

  final LedgerDisk disk;

  /// Whether this device keeps a recovery key of [account].
  final bool Function(String account) isInCircle;

  /// Whether [account] is an accepted friend here.
  final bool Function(String account) isFriend;
  final int totalBytes;
  final int friendsBytes;
  final int perAccountBytes;

  static bool _nobody(String _) => false;

  /// Whether a copy of [account] may be kept here.
  bool mayKeep(String account) => isInCircle(account) || isFriend(account);

  static const String _indexKey = 'circle-backup/held';

  /// Account → the kept copy's manifest.
  final Map<String, CircleBackupManifest> _kept =
      <String, CircleBackupManifest>{};

  /// Account → a copy being received (its chunks arrive one by one).
  final Map<String, CircleBackupManifest> _incoming =
      <String, CircleBackupManifest>{};

  bool _loaded = false;

  static String _folder(String account) =>
      'circle-backup/k/${sha256Hex(utf8.encode(account)).substring(0, 32)}';

  static String _chunkKey(String account, String id) =>
      '${_folder(account)}/${id.substring(0, 32)}';

  /// Where an earlier version kept a chunk (the whole id).
  static String _oldChunkKey(String account, String id) =>
      '${_folder(account)}/$id';

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    final Uint8List? raw = await disk.read(_indexKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is List) {
        for (final Object? m in json) {
          final CircleBackupManifest? manifest = CircleBackupManifest.parse(m);
          if (manifest != null) {
            _kept[manifest.account] = manifest;
          }
        }
      }
    } on FormatException {
      logZenWarning('The circle copies index is damaged.');
    }
    // Chunks an earlier version kept under the whole id: renamed once.
    for (final CircleBackupManifest m in _kept.values) {
      for (final String id in m.chunks.keys) {
        final Uint8List? old = await disk.read(_oldChunkKey(m.account, id));
        if (old != null) {
          await disk.write(_chunkKey(m.account, id), old);
          await disk.delete(_oldChunkKey(m.account, id));
        }
      }
    }
  }

  Future<void> _saveIndex() => disk.write(
    _indexKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Object?>[
          for (final CircleBackupManifest m in _kept.values) m.json,
        ]),
      ),
    ),
  );

  /// Accounts whose copy is kept here, and the size of each.
  Map<String, int> get kept => <String, int>{
    for (final CircleBackupManifest m in _kept.values) m.account: m.totalBytes,
  };

  /// The kept copy of [account] (to give back after a recovery).
  CircleBackupManifest? manifestOf(String account) => _kept[account];

  int get _used => _kept.values.fold(
    0,
    (int sum, CircleBackupManifest m) => sum + m.totalBytes,
  );

  /// Bytes of the copies kept only as a friend's (no key of theirs here).
  int get _usedByFriends => _kept.values
      .where((CircleBackupManifest m) => !isInCircle(m.account))
      .fold(0, (int sum, CircleBackupManifest m) => sum + m.totalBytes);

  /// Takes [manifest] as the copy being received for its account.
  Future<CircleBackupOfferResult> offer(CircleBackupManifest manifest) async {
    await load();
    final String account = manifest.account;
    final bool circle = isInCircle(account);
    if (!circle && !isFriend(account)) {
      return CircleBackupOfferResult.notInCircle;
    }
    final CircleBackupManifest? coming = _incoming[account];
    if (coming != null && manifest.createdAt < coming.createdAt) {
      return CircleBackupOfferResult.stale;
    }
    final CircleBackupManifest? had = _kept[account];
    if (had != null && manifest.createdAt <= had.createdAt) {
      return had.id == manifest.id
          ? CircleBackupOfferResult.accepted
          : CircleBackupOfferResult.stale;
    }
    final int size = manifest.totalBytes;
    if (size > perAccountBytes ||
        _used - (had?.totalBytes ?? 0) + size > totalBytes ||
        (!circle &&
            _usedByFriends - (had?.totalBytes ?? 0) + size > friendsBytes)) {
      return CircleBackupOfferResult.tooBig;
    }
    if (!await manifest.verify()) {
      return CircleBackupOfferResult.badSignature;
    }
    _incoming[account] = manifest;
    return CircleBackupOfferResult.accepted;
  }

  /// The chunks of the copy being received for [account] not here yet.
  Future<List<String>> missing(String account) async {
    final CircleBackupManifest? m = _incoming[account] ?? _kept[account];
    if (m == null) {
      return const <String>[];
    }
    return <String>[
      for (final String id in m.chunks.keys)
        if (await disk.read(_chunkKey(account, id)) == null) id,
    ];
  }

  /// One chunk of the copy being received for [account]: kept when it is
  /// what its id says. Returns true once the whole copy is here (it then
  /// replaces the one kept before).
  Future<bool> putChunk(String account, String id, Uint8List chunk) async {
    final CircleBackupManifest? m = _incoming[account];
    final int? size = m?.chunks[id];
    if (m == null ||
        size == null ||
        chunk.length != size ||
        circleBackupChunkId(chunk) != id) {
      return false;
    }
    await disk.write(_chunkKey(account, id), chunk);
    return _commitIfComplete(account);
  }

  /// Makes the copy being received for [account] the kept one when all
  /// its chunks are here (true), deleting chunks no longer used.
  Future<bool> settle(String account) => _commitIfComplete(account);

  Future<bool> _commitIfComplete(String account) async {
    final CircleBackupManifest? m = _incoming[account];
    if (m == null || (await missing(account)).isNotEmpty) {
      return false;
    }
    final CircleBackupManifest? old = _kept[account];
    _kept[account] = m;
    _incoming.remove(account);
    await _saveIndex();
    if (old != null) {
      final Set<String> now = m.chunks.keys.toSet();
      for (final String id in old.chunks.keys) {
        if (!now.contains(id)) {
          await disk.delete(_chunkKey(account, id));
        }
      }
    }
    return true;
  }

  /// A chunk of the kept copy of [account].
  Future<Uint8List?> chunk(String account, String id) async {
    final CircleBackupManifest? m = _kept[account];
    if (m == null || !m.chunks.containsKey(id)) {
      return null;
    }
    return disk.read(_chunkKey(account, id));
  }

  /// Drops the copy of [account] (the person here left that circle).
  Future<void> drop(String account) async {
    await load();
    final CircleBackupManifest? m = _kept.remove(account);
    final CircleBackupManifest? incoming = _incoming.remove(account);
    for (final CircleBackupManifest x in <CircleBackupManifest>[
      ?m,
      ?incoming,
    ]) {
      for (final String id in x.chunks.keys) {
        await disk.delete(_chunkKey(account, id));
      }
    }
    await _saveIndex();
  }

  /// Drops the copies of accounts whose recovery key is no longer here
  /// and that are no longer friends here.
  Future<int> prune() async {
    await load();
    final List<String> gone = <String>[
      for (final String account in _kept.keys)
        if (!mayKeep(account)) account,
    ];
    for (final String account in gone) {
      await drop(account);
    }
    return gone.length;
  }
}
