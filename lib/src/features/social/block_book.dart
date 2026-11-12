import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Who this account blocked, by person: the one list every feature reads
/// (the messenger, the wall and films, Dating, "W pobliżu", pebbles,
/// introductions, mentions, followers).
///
/// A person is known by what this account knows of them: their account
/// (the ledger key behind all their devices), their addresses and their
/// dating keys. A block made in any feature is one [BlockRecord] that
/// covers all of it, and what is learnt later (another device of theirs,
/// a dating key their phone tells) is added to it. A record of a dating
/// key whose owner is unknown stays a key block until the owner's address
/// or account turns up; from then on it is a block of the account.
///
/// Each record is a decision (blocked or lifted, at a stamp) and what is
/// known of the person. The account's devices share the records in the
/// contacts copy and merge them one by one: the later decision wins, what
/// is known is put together. A lifted block stays as a lifted record (up to
/// [kMaxLiftedBlocks]), so a device that was away, or an older copy, never
/// brings it back.
///
/// Honest limits: an account costs nothing. Somebody blocked can make a new
/// account and a new dating key; the phone refuses the device keys,
/// addresses and dating keys it knows to be theirs, never the person.
///
/// Immutable: every change returns a new book, the same instance when
/// nothing changed.
@immutable
final class BlockBook {
  const BlockBook._(this._records, this.clock);

  /// The book as it was kept.
  factory BlockBook.restore(Map<String, BlockRecord> records) {
    Hlc last = Hlc.zero;
    final Map<String, BlockRecord> kept = <String, BlockRecord>{};
    records.forEach((String id, BlockRecord r) {
      if (id.isEmpty) {
        return;
      }
      kept[id] = r;
      if (r.stamp.hlc > last) {
        last = r.stamp.hlc;
      }
    });
    return BlockBook._(
      UnmodifiableMapView<String, BlockRecord>(_pruned(kept)),
      last,
    );
  }

  static const BlockBook empty = BlockBook._(<String, BlockRecord>{}, Hlc.zero);

  final Map<String, BlockRecord> _records;

  /// The latest stamp this book made or saw.
  final Hlc clock;

  /// Every record by id (`a:<account>`, `@:<address>`, `d:<dating key>`).
  Map<String, BlockRecord> get records => _records;

  bool get isEmpty => _records.isEmpty;

  /// The blocks in force.
  Iterable<BlockRecord> get active =>
      _records.values.where((BlockRecord r) => r.on);

  /// The blocked accounts.
  Set<String> get accounts => <String>{
    for (final BlockRecord r in active)
      if (r.account.isNotEmpty) r.account,
  };

  /// Every address known to be a blocked person's.
  Set<String> get addresses => <String>{
    for (final BlockRecord r in active) ...r.addresses,
  };

  /// Every dating key known to be a blocked person's.
  Set<String> get datingKeys => <String>{
    for (final BlockRecord r in active) ...r.datingKeys,
  };

  bool blocksAccount(String account) =>
      account.isNotEmpty && active.any((BlockRecord r) => r.account == account);

  bool blocksAddress(String address) {
    final String a = PeerShareCodec.normalizeAddress(address);
    return a.isNotEmpty &&
        active.any((BlockRecord r) => r.addresses.contains(a));
  }

  /// Whether the dating key [key] is blocked here (true), was blocked and
  /// the block lifted (false), or is unknown to the book (null).
  bool? datingKeyState(String key) {
    bool lifted = false;
    for (final BlockRecord r in _records.values) {
      if (r.datingKeys.contains(key)) {
        if (r.on) {
          return true;
        }
        lifted = true;
      }
    }
    return lifted ? false : null;
  }

  /// The id of the record of a person known by [account], [addresses] and
  /// [datingKeys]: the account when known, else the first address, else the
  /// first key; '' for nobody.
  static String idFor({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
  }) {
    if (account.isNotEmpty) {
      return 'a:$account';
    }
    for (final String a in addresses) {
      final String n = PeerShareCodec.normalizeAddress(a);
      if (n.isNotEmpty) {
        return '@:$n';
      }
    }
    for (final String k in datingKeys) {
      if (k.isNotEmpty) {
        return 'd:$k';
      }
    }
    return '';
  }

  /// The records that cover the person known by [account], [addresses] or
  /// [datingKeys] (any of them), in force or lifted.
  Map<String, BlockRecord> covering({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
  }) {
    final List<String> norm = _addresses(addresses);
    return <String, BlockRecord>{
      for (final MapEntry<String, BlockRecord> e in _records.entries)
        if (e.value.covers(
          account: account,
          addresses: norm,
          datingKeys: datingKeys,
        ))
          e.key: e.value,
    };
  }

  /// The person known by [account], [addresses] and [datingKeys] is blocked
  /// (made in [origin], shown as [name]). Already blocked: what is new about
  /// them is added ([learn]). [at]: the stamp of the decision (the one the
  /// messenger's record got, so both say the same); a new one otherwise.
  BlockBook block({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
    String name = '',
    BlockOrigin origin = BlockOrigin.messenger,
    required FriendshipTick tick,
    FriendshipStamp? at,
  }) {
    final List<String> addrs = _addresses(addresses);
    final List<String> keys = _keys(datingKeys);
    final Map<String, BlockRecord> known = covering(
      account: account,
      addresses: addrs,
      datingKeys: keys,
    );
    if (known.values.any((BlockRecord r) => r.on)) {
      return learn(
        account: account,
        addresses: addrs,
        datingKeys: keys,
        name: name,
      );
    }
    String who = account;
    for (final BlockRecord r in known.values) {
      if (who.isEmpty && r.account.isNotEmpty) {
        who = r.account;
      }
    }
    final String id = idFor(account: who, addresses: addrs, datingKeys: keys);
    if (id.isEmpty) {
      return this;
    }
    BlockRecord record = BlockRecord(
      on: true,
      stamp: at ?? _nextStamp(tick),
      account: who,
      name: _clipName(name),
      origin: origin,
    ).withKnown(addresses: addrs, datingKeys: keys);
    for (final BlockRecord r in known.values) {
      record = record.withKnown(
        addresses: r.addresses,
        datingKeys: r.datingKeys,
        name: r.name,
      );
    }
    return _put(<String, BlockRecord>{id: record});
  }

  /// What became known about a person blocked here: another address or
  /// dating key of theirs, or their account. A block known only by a key or
  /// an address becomes a block of the account once the account is known
  /// (a record of its own, the same decision). Nothing changes for someone
  /// not blocked.
  BlockBook learn({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
    String name = '',
  }) {
    final List<String> addrs = _addresses(addresses);
    final List<String> keys = _keys(datingKeys);
    final Map<String, BlockRecord> changed = <String, BlockRecord>{};
    covering(account: account, addresses: addrs, datingKeys: keys).forEach((
      String id,
      BlockRecord r,
    ) {
      if (!r.on) {
        return;
      }
      BlockRecord next = r.withKnown(
        account: account,
        addresses: addrs,
        datingKeys: keys,
        name: name,
      );
      final String accountId = next.account.isEmpty ? '' : 'a:${next.account}';
      if (accountId.isNotEmpty && accountId != id) {
        // The owner is known now: the account is blocked by the same
        // decision, unless a later one lifted the account's block.
        final BlockRecord? had = changed[accountId] ?? _records[accountId];
        if (had != null && !had.on && had.decidesOver(next)) {
          next = next.lifted(had.stamp);
        } else {
          final BlockRecord merged = had == null ? next : _merge(had, next);
          if (had == null || merged != had) {
            changed[accountId] = merged;
          }
        }
      }
      if (next != r) {
        changed[id] = next;
      }
    });
    return changed.isEmpty ? this : _put(changed);
  }

  /// Lifts every block in force of the person known by [account],
  /// [addresses] or [datingKeys] ([only]: only those made in that feature).
  BlockBook lift({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
    BlockOrigin? only,
    required FriendshipTick tick,
    FriendshipStamp? at,
  }) {
    final Map<String, BlockRecord> found = covering(
      account: account,
      addresses: addresses,
      datingKeys: datingKeys,
    )..removeWhere((String _, BlockRecord r) => !r.on);
    // The account's own record goes with any record that names it, and
    // every record that names the account goes with it.
    final Set<String> accounts = <String>{
      for (final BlockRecord r in found.values)
        if (r.account.isNotEmpty) r.account,
    };
    for (final MapEntry<String, BlockRecord> e in _records.entries) {
      if (e.value.on && accounts.contains(e.value.account)) {
        found[e.key] = e.value;
      }
    }
    if (only != null) {
      found.removeWhere((String _, BlockRecord r) => r.origin != only);
    }
    if (found.isEmpty) {
      return this;
    }
    final FriendshipStamp stamp = at ?? _nextStamp(tick);
    return _put(<String, BlockRecord>{
      for (final MapEntry<String, BlockRecord> e in found.entries)
        e.key: e.value.lifted(stamp),
    });
  }

  /// Lifts the record [id] and every record of the same person.
  BlockBook liftId(String id, FriendshipTick tick) {
    final BlockRecord? r = _records[id];
    if (r == null || !r.on) {
      return this;
    }
    return lift(
      account: r.account,
      addresses: r.addresses,
      datingKeys: r.datingKeys,
      tick: tick,
    );
  }

  /// A record from another device of the account, or from a copy: the
  /// later decision wins, what is known is put together. One dated too far
  /// ahead of [wallMillis] is not taken (it would win for good).
  BlockBook merge(String id, BlockRecord record, {required int wallMillis}) {
    if (id.isEmpty ||
        record.stamp.hlc.millis > wallMillis + kMaxClockSkew.inMilliseconds) {
      return this;
    }
    final BlockRecord? have = _records[id];
    final BlockRecord next = have == null ? record : _merge(have, record);
    if (have == next) {
      return this;
    }
    return _put(<String, BlockRecord>{id: next});
  }

  /// Every record of [other] merged in ([merge]).
  BlockBook mergeAll(BlockBook other, {required int wallMillis}) {
    BlockBook next = this;
    other._records.forEach((String id, BlockRecord r) {
      next = next.merge(id, r, wallMillis: wallMillis);
    });
    return next;
  }

  /// Whether this book knows something [other] lacks or has older: then
  /// this device's copy should go out.
  bool aheadOf(BlockBook other) {
    for (final MapEntry<String, BlockRecord> e in _records.entries) {
      final BlockRecord? theirs = other._records[e.key];
      if (theirs == null || _merge(theirs, e.value) != theirs) {
        return true;
      }
    }
    return false;
  }

  /// Brings the book in line with the messenger's [friends] book, which
  /// devices of Zen 1.16.5 (and older copies) still change on their own: a
  /// block there that no record covers becomes one (at the messenger's
  /// stamp, with the account [accountOf] tells), and a record whose
  /// address the messenger unblocked or befriended later is lifted at that
  /// stamp. Every device comes to the same records.
  BlockBook reconcile(
    FriendshipBook friends, {
    String? Function(String address)? accountOf,
  }) {
    final Map<String, BlockRecord> changed = <String, BlockRecord>{};
    for (final FriendProfile p in friends.profiles.values) {
      if (p.status != FriendRelationshipStatus.blocked) {
        continue;
      }
      final String address = PeerShareCodec.normalizeAddress(p.address);
      final FriendshipStamp stamp =
          friends.recordOf(address)?.stamp ?? FriendshipStamp.zero;
      final Map<String, BlockRecord> known = covering(
        addresses: <String>[address],
      );
      if (known.values.any((BlockRecord r) => r.on) ||
          known.values.any((BlockRecord r) => r.stamp.compareTo(stamp) >= 0)) {
        continue;
      }
      final String account = accountOf?.call(address) ?? '';
      final String id = idFor(account: account, addresses: <String>[address]);
      final BlockRecord? had = _records[id];
      if (had != null && had.stamp.compareTo(stamp) >= 0) {
        continue;
      }
      changed[id] = BlockRecord(
        on: true,
        stamp: stamp,
        account: account,
        name: _clipName(p.displayLabel),
      ).withKnown(addresses: <String>[address]);
    }
    for (final MapEntry<String, BlockRecord> e in _records.entries) {
      final BlockRecord r = e.value;
      if (!r.on || changed.containsKey(e.key)) {
        continue;
      }
      for (final String a in r.addresses) {
        final FriendshipRecord? m = friends.recordOf(a);
        if (m != null &&
            m.mark != FriendshipMark.blocked &&
            m.stamp.compareTo(r.stamp) > 0) {
          changed[e.key] = r.lifted(m.stamp);
          break;
        }
      }
    }
    return changed.isEmpty ? this : _put(changed);
  }

  // ---- inside ----

  BlockBook _put(Map<String, BlockRecord> changed) {
    final Map<String, BlockRecord> next = <String, BlockRecord>{
      ..._records,
      ...changed,
    };
    Hlc last = clock;
    for (final BlockRecord r in changed.values) {
      if (r.stamp.hlc > last) {
        last = r.stamp.hlc;
      }
    }
    return BlockBook._(
      UnmodifiableMapView<String, BlockRecord>(_pruned(next)),
      last,
    );
  }

  FriendshipStamp _nextStamp(FriendshipTick tick) {
    final Hlc next;
    if (tick.wallMillis > clock.millis) {
      next = Hlc(tick.wallMillis, 0);
    } else if (clock.counter < 0xFFFF) {
      next = Hlc(clock.millis, clock.counter + 1);
    } else {
      next = Hlc(clock.millis + 1, 0);
    }
    return FriendshipStamp(next, tick.device);
  }

  static List<String> _addresses(Iterable<String> addresses) => <String>[
    for (final String a in addresses)
      if (PeerShareCodec.normalizeAddress(a).isNotEmpty)
        PeerShareCodec.normalizeAddress(a),
  ];

  static List<String> _keys(Iterable<String> keys) => <String>[
    for (final String k in keys)
      if (k.isNotEmpty && k.length <= _maxKeyLength) k,
  ];
}

/// The later decision of [a] and [b], with what both know of the person.
BlockRecord _merge(BlockRecord a, BlockRecord b) {
  final bool bWins = b.decidesOver(a);
  final BlockRecord winner = bWins ? b : a;
  final BlockRecord loser = bWins ? a : b;
  return winner.withKnown(
    account: loser.account,
    addresses: loser.addresses,
    datingKeys: loser.datingKeys,
    name: loser.name,
  );
}

/// Lifted blocks remembered at most; past it the oldest go.
const int kMaxLiftedBlocks = 2000;

/// Blocks in force read from a copy at most.
const int kMaxBlocks = 5000;

/// Addresses and dating keys kept per person at most (the newest).
const int _maxAddresses = 16;
const int _maxKeys = 32;
const int _maxKeyLength = 100;
const int _maxName = 80;

String _clipName(String name) {
  final String n = name.trim();
  return n.length > _maxName ? n.substring(0, _maxName) : n;
}

Map<String, BlockRecord> _pruned(Map<String, BlockRecord> records) {
  final List<MapEntry<String, BlockRecord>> lifted =
      records.entries
          .where((MapEntry<String, BlockRecord> e) => !e.value.on)
          .toList()
        ..sort(
          (MapEntry<String, BlockRecord> a, MapEntry<String, BlockRecord> b) =>
              a.value.stamp.compareTo(b.value.stamp),
        );
  if (lifted.length <= kMaxLiftedBlocks) {
    return records;
  }
  final Map<String, BlockRecord> rest = Map<String, BlockRecord>.of(records);
  for (final MapEntry<String, BlockRecord> e in lifted.take(
    lifted.length - kMaxLiftedBlocks,
  )) {
    rest.remove(e.key);
  }
  return rest;
}

/// Where a block was made: the list says so, and "W pobliżu" can lift its
/// own at once.
enum BlockOrigin {
  messenger('m'),
  dating('d'),
  nearby('n'),
  follower('f');

  const BlockOrigin(this.code);

  final String code;

  static BlockOrigin fromCode(Object? code) {
    for (final BlockOrigin o in values) {
      if (o.code == code) {
        return o;
      }
    }
    return BlockOrigin.messenger;
  }
}

/// One person's block: the decision ([on] at [stamp]) and what is known of
/// them.
@immutable
final class BlockRecord {
  const BlockRecord({
    required this.on,
    required this.stamp,
    this.account = '',
    this.addresses = const <String>[],
    this.datingKeys = const <String>[],
    this.name = '',
    this.origin = BlockOrigin.messenger,
  });

  /// Blocked (or lifted).
  final bool on;
  final FriendshipStamp stamp;

  /// Their account ('' while unknown).
  final String account;

  /// Their addresses (normalized), the newest last.
  final List<String> addresses;

  /// Their dating keys, the newest last.
  final List<String> datingKeys;

  /// What the list shows.
  final String name;
  final BlockOrigin origin;

  /// Whether this record is of the person known by any of these.
  bool covers({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
  }) =>
      (account.isNotEmpty && this.account == account) ||
      addresses.any(this.addresses.contains) ||
      datingKeys.any(this.datingKeys.contains);

  /// Whether this decision wins over [other]'s: the later stamp; on the very
  /// same stamp a lift (so every device picks the same one).
  bool decidesOver(BlockRecord other) {
    final int byStamp = stamp.compareTo(other.stamp);
    if (byStamp != 0) {
      return byStamp > 0;
    }
    return !on && other.on;
  }

  BlockRecord lifted(FriendshipStamp at) => BlockRecord(
    on: false,
    stamp: at,
    account: account,
    addresses: addresses,
    datingKeys: datingKeys,
    name: name,
    origin: origin,
  );

  /// The same decision with more known of the person: the account when
  /// this one has none, addresses and keys added (the newest kept), the
  /// name when this one has none.
  BlockRecord withKnown({
    String account = '',
    Iterable<String> addresses = const <String>[],
    Iterable<String> datingKeys = const <String>[],
    String name = '',
  }) {
    List<String> add(List<String> have, Iterable<String> more, int max) {
      final List<String> out = List<String>.of(have);
      for (final String m in more) {
        if (m.isNotEmpty && !out.contains(m)) {
          out.add(m);
        }
      }
      return out.length > max ? out.sublist(out.length - max) : out;
    }

    final List<String> addrs = add(this.addresses, <String>[
      for (final String a in addresses)
        if (PeerShareCodec.normalizeAddress(a).isNotEmpty)
          PeerShareCodec.normalizeAddress(a),
    ], _maxAddresses);
    final List<String> keys = add(this.datingKeys, <String>[
      for (final String k in datingKeys)
        if (k.length <= _maxKeyLength) k,
    ], _maxKeys);
    final String who = this.account.isNotEmpty ? this.account : account;
    final String shown = this.name.isNotEmpty ? this.name : _clipName(name);
    if (who == this.account &&
        shown == this.name &&
        listEquals(addrs, this.addresses) &&
        listEquals(keys, this.datingKeys)) {
      return this;
    }
    return BlockRecord(
      on: on,
      stamp: stamp,
      account: who,
      addresses: addrs,
      datingKeys: keys,
      name: shown,
      origin: origin,
    );
  }

  /// `{o, t, v, a, ad, k, n, f}`.
  Map<String, Object> toJson() => <String, Object>{
    'o': on ? 1 : 0,
    't': stamp.hlc.toInt(),
    'v': stamp.device,
    if (account.isNotEmpty) 'a': account,
    if (addresses.isNotEmpty) 'ad': addresses,
    if (datingKeys.isNotEmpty) 'k': datingKeys,
    if (name.isNotEmpty) 'n': name,
    'f': origin.code,
  };

  static BlockRecord? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? o = json['o'];
    final Object? t = json['t'];
    final Object? v = json['v'] ?? '';
    final Object? a = json['a'] ?? '';
    final Object? n = json['n'] ?? '';
    if ((o != 0 && o != 1) ||
        t is! int ||
        t < 0 ||
        v is! String ||
        a is! String ||
        n is! String ||
        a.length > 200) {
      return null;
    }
    List<String> strings(Object? list, int max) => <String>[
      if (list is List)
        for (final Object? s in list.take(max))
          if (s is String && s.isNotEmpty && s.length <= _maxKeyLength) s,
    ];
    return BlockRecord(
      on: o == 1,
      stamp: FriendshipStamp(Hlc.fromInt(t), v),
      account: a,
      addresses: <String>[
        for (final String s in strings(json['ad'], _maxAddresses))
          if (PeerShareCodec.normalizeAddress(s).isNotEmpty)
            PeerShareCodec.normalizeAddress(s),
      ],
      datingKeys: strings(json['k'], _maxKeys),
      name: _clipName(n),
      origin: BlockOrigin.fromCode(json['f']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BlockRecord &&
      other.on == on &&
      other.stamp == stamp &&
      other.account == account &&
      listEquals(other.addresses, addresses) &&
      listEquals(other.datingKeys, datingKeys) &&
      other.name == name &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(
    on,
    stamp,
    account,
    Object.hashAll(addresses),
    Object.hashAll(datingKeys),
    name,
    origin,
  );

  @override
  String toString() =>
      'BlockRecord(${on ? 'on' : 'lifted'} $stamp $account $addresses '
      '$datingKeys)';
}

/// Records as written: id → [BlockRecord.toJson].
Map<String, Map<String, Object>> blockRecordsToJson(
  Map<String, BlockRecord> records,
) => <String, Map<String, Object>>{
  for (final String id in records.keys.toList()..sort())
    id: records[id]!.toJson(),
};

/// Records read back from [json] ([blockRecordsToJson]); what does not read
/// is left out.
Map<String, BlockRecord> blockRecordsFromJson(Object? json) {
  final Map<String, BlockRecord> out = <String, BlockRecord>{};
  if (json is! Map) {
    return out;
  }
  for (final MapEntry<dynamic, dynamic> e in json.entries.take(
    kMaxBlocks + kMaxLiftedBlocks,
  )) {
    final Object? id = e.key;
    final BlockRecord? r = BlockRecord.fromJson(e.value);
    if (id is String && id.isNotEmpty && id.length <= 220 && r != null) {
      out[id] = r;
    }
  }
  return out;
}

/// Who is blocked here, as every feature asks it: the records of the
/// [book], the addresses blocked in the messenger, and what the ledger
/// tells of accounts ([accountOf] an address, [addressesOf] an account), so
/// another device of a blocked person counts as them as soon as it is known.
final class BlockedPeople {
  BlockedPeople({
    this.book = BlockBook.empty,
    Iterable<String> blockedAddresses = const <String>[],
    String? Function(String address)? accountOf,
    Iterable<String> Function(String account)? addressesOf,
    this.ownAccount = '',
  }) : _accountOf = accountOf,
       _addressesOf = addressesOf,
       _messenger = <String>{
         for (final String a in blockedAddresses)
           if (PeerShareCodec.normalizeAddress(a).isNotEmpty)
             PeerShareCodec.normalizeAddress(a),
       };

  /// Nobody blocked.
  static final BlockedPeople nobody = BlockedPeople();

  final BlockBook book;
  final String ownAccount;
  final String? Function(String address)? _accountOf;
  final Iterable<String> Function(String account)? _addressesOf;
  final Set<String> _messenger;

  /// The blocked accounts (never this account).
  late final Set<String> accounts = <String>{
    ...book.accounts,
    for (final String a in _messenger) ?_accountOf?.call(a),
  }..removeWhere((String a) => a.isEmpty || a == ownAccount);

  /// Every address known to be a blocked person's.
  late final Set<String> addresses = <String>{
    ..._messenger,
    ...book.addresses,
    for (final String acc in accounts)
      ...?_addressesOf?.call(acc).map(PeerShareCodec.normalizeAddress),
  };

  bool get isEmpty => _messenger.isEmpty && book.active.isEmpty;

  /// Whether [address] is a blocked person's: blocked itself, or a device of
  /// a blocked account.
  bool address(String address) {
    final String a = PeerShareCodec.normalizeAddress(address);
    if (a.isEmpty) {
      return false;
    }
    if (addresses.contains(a)) {
      return true;
    }
    final String? acc = _accountOf?.call(a);
    return acc != null && accounts.contains(acc);
  }

  bool account(String account) => accounts.contains(account);

  /// See [BlockBook.datingKeyState].
  bool? datingKey(String key) => book.datingKeyState(key);
}
