import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Who is a friend of this account: the one place that decides it.
///
/// Per address a small state machine:
///
/// ```text
///   none ──invite──────────▶ requested (out) ──they accept──▶ friend
///   none ──their invitation▶ requested (in) ───I accept─────▶ friend
///   requested (out) ──their invitation (both asked)─────────▶ friend
///   friend ──remove──▶ removed ──a new invitation──▶ requested …
///   any ──block──▶ blocked ──unblock──▶ none
/// ```
///
/// Only [admit] makes a friend, and only on [FriendshipEvidence]: an
/// invitation answered (here or on another device of the account). A frame
/// of theirs, a replay of what was kept for the app's return, a preview, a
/// presence, a profile, a group never does — they can only edit what an
/// existing entry shows ([edit]), never its standing.
///
/// What is settled (friend, blocked, removed, none) is kept as a
/// [FriendshipRecord] stamped with a hybrid logical clock and this device,
/// shared with the account's other devices (the contacts copy) and merged
/// there by the same rule: per address, the later record wins. So a removal
/// and a friendship made again on two devices end the same on both, and a
/// device (or a backup) that still lists a removed friend brings nobody
/// back: its record is older than the removal.
///
/// Immutable: every change returns a new book, the same instance when
/// nothing changed.
@immutable
final class FriendshipBook {
  const FriendshipBook._(this._profiles, this._records, this.clock);

  /// The book as it was kept: [profiles] (each person's entry, a friend's or
  /// an invitation's), [records] (what is settled, see [records]) and the
  /// [clock] its stamps came from. Anything that disagrees is put right,
  /// the record winning: a friend or a block without a record was settled
  /// before records were kept (a stamp older than anything).
  ///
  /// Only for what was stored (and tests): every change goes through the
  /// book's own transitions.
  factory FriendshipBook.restore({
    Map<String, FriendProfile> profiles = const <String, FriendProfile>{},
    Map<String, FriendshipRecord> records = const <String, FriendshipRecord>{},
    Hlc clock = Hlc.zero,
  }) {
    final Map<String, FriendProfile> byAddress = <String, FriendProfile>{};
    for (final FriendProfile profile in profiles.values) {
      final String key = PeerShareCodec.normalizeAddress(profile.address);
      if (key.isEmpty) {
        continue;
      }
      byAddress[key] = _merged(byAddress[key], profile, nicknameChanged: true);
    }
    final Map<String, FriendshipRecord> settled = <String, FriendshipRecord>{};
    Hlc last = clock;
    records.forEach((String address, FriendshipRecord record) {
      final String key = PeerShareCodec.normalizeAddress(address);
      if (key.isEmpty) {
        return;
      }
      final FriendshipRecord? have = settled[key];
      if (have == null || record.beats(have)) {
        settled[key] = record;
      }
      if (record.stamp.hlc > last) {
        last = record.stamp.hlc;
      }
    });
    byAddress.forEach((String key, FriendProfile profile) {
      if (settled.containsKey(key)) {
        return;
      }
      switch (profile.status) {
        case FriendRelationshipStatus.accepted:
          settled[key] = const FriendshipRecord(
            FriendshipMark.friend,
            FriendshipStamp.zero,
          );
        case FriendRelationshipStatus.blocked:
          settled[key] = const FriendshipRecord(
            FriendshipMark.blocked,
            FriendshipStamp.zero,
          );
        case FriendRelationshipStatus.none ||
            FriendRelationshipStatus.pendingIncoming ||
            FriendRelationshipStatus.pendingOutgoing:
          break;
      }
    });
    for (final MapEntry<String, FriendshipRecord> e in settled.entries) {
      final FriendProfile? settledProfile = _settled(
        e.key,
        byAddress[e.key],
        e.value.mark,
      );
      if (settledProfile == null) {
        byAddress.remove(e.key);
      } else {
        byAddress[e.key] = settledProfile;
      }
    }
    return FriendshipBook._(
      UnmodifiableMapView<String, FriendProfile>(byAddress),
      UnmodifiableMapView<String, FriendshipRecord>(_pruned(settled)),
      last,
    );
  }

  static const FriendshipBook empty = FriendshipBook._(
    <String, FriendProfile>{},
    <String, FriendshipRecord>{},
    Hlc.zero,
  );

  final Map<String, FriendProfile> _profiles;
  final Map<String, FriendshipRecord> _records;

  /// The latest stamp this book made or saw: the next one is later.
  final Hlc clock;

  /// Every entry by normalized address: friends, invitations both ways,
  /// blocked people. Read only.
  Map<String, FriendProfile> get profiles => _profiles;

  /// What is settled per normalized address, as shared with the account's
  /// other devices. Read only.
  Map<String, FriendshipRecord> get records => _records;

  FriendProfile? profileOf(String address) {
    final FriendProfile? direct =
        _profiles[PeerShareCodec.normalizeAddress(address)] ??
        _profiles[address];
    if (direct != null) {
      return direct;
    }
    for (final FriendProfile friend in _profiles.values) {
      if (PeerShareCodec.addressesEqual(friend.address, address)) {
        return friend;
      }
    }
    return null;
  }

  FriendshipRecord? recordOf(String address) =>
      _records[PeerShareCodec.normalizeAddress(address)];

  /// Where [address] stands.
  FriendshipStanding standingOf(String address) {
    switch (profileOf(address)?.status) {
      case FriendRelationshipStatus.accepted:
        return FriendshipStanding.friend;
      case FriendRelationshipStatus.blocked:
        return FriendshipStanding.blocked;
      case FriendRelationshipStatus.pendingOutgoing:
        return FriendshipStanding.requestedOut;
      case FriendRelationshipStatus.pendingIncoming:
        return FriendshipStanding.requestedIn;
      case FriendRelationshipStatus.none || null:
        return recordOf(address)?.mark == FriendshipMark.removed
            ? FriendshipStanding.removed
            : FriendshipStanding.none;
    }
  }

  /// When [address] was removed as a friend (wall time of the removal),
  /// `null` when they were not or a friendship was made since.
  int? removedAt(String address) {
    final FriendshipRecord? record = recordOf(address);
    return record?.mark == FriendshipMark.removed
        ? record!.stamp.hlc.millis
        : null;
  }

  /// What a `friend_accept` from [address] means here: it makes a friend
  /// only of someone invited from here (and still waiting); from a friend
  /// it is a repeated one; from someone removed it answers nothing (an old
  /// acceptance sent again, or kept for the app's return); from anyone else
  /// it is the invitation it amounts to, which the user still has to
  /// confirm.
  AcceptMeaning meaningOfAccept(String address) =>
      switch (standingOf(address)) {
        FriendshipStanding.requestedOut => AcceptMeaning.admits,
        FriendshipStanding.friend => AcceptMeaning.repeated,
        FriendshipStanding.none => AcceptMeaning.invitation,
        FriendshipStanding.requestedIn ||
        FriendshipStanding.blocked ||
        FriendshipStanding.removed => AcceptMeaning.nothing,
      };

  /// The removed friends (normalized addresses).
  Set<String> get removedAddresses => <String>{
    for (final MapEntry<String, FriendshipRecord> e in _records.entries)
      if (e.value.mark == FriendshipMark.removed) e.key,
  };

  // ---- transitions ----

  /// [address] becomes a friend on [evidence]; [shape] gives what their
  /// entry shows (their name, the first line of the chat), the standing
  /// being the book's. Refused (the same book back) when the evidence does
  /// not hold here: an acceptance of an invitation nobody here sent (or one
  /// sent before a removal), a copy older than what is known.
  FriendshipBook admit(
    String address,
    FriendshipEvidence evidence,
    FriendshipTick tick, {
    FriendProfile Function(FriendProfile base)? shape,
  }) {
    final String key = PeerShareCodec.normalizeAddress(address);
    if (key.isEmpty) {
      return this;
    }
    final FriendRelationshipStatus? status = profileOf(key)?.status;
    final FriendshipStamp stamp;
    switch (evidence) {
      case TheyAcceptedMine() || BothInvited():
        if (status != FriendRelationshipStatus.pendingOutgoing) {
          return this;
        }
        stamp = _nextStamp(tick);
      case IAcceptedTheirs():
        if (status != FriendRelationshipStatus.pendingIncoming) {
          return this;
        }
        stamp = _nextStamp(tick);
      case OwnCopy(stamp: final FriendshipStamp copied):
        stamp = copied;
    }
    return _apply(
      key,
      FriendshipRecord(FriendshipMark.friend, stamp),
      tick,
      shape: shape,
    );
  }

  /// [address] is removed as a friend: here by the user, or by them ([at]
  /// absent: now), or on another device of the account at [at]. Nothing
  /// brings them back but a friendship made after it ([admit]). A removal
  /// older than what is known changes nothing. [dropPending]: their
  /// invitation (either way) goes too — the user removed them.
  FriendshipBook remove(
    String address,
    FriendshipTick tick, {
    FriendshipStamp? at,
    bool dropPending = false,
  }) {
    final String key = PeerShareCodec.normalizeAddress(address);
    if (key.isEmpty) {
      return this;
    }
    final FriendshipBook next = _apply(
      key,
      FriendshipRecord(FriendshipMark.removed, at ?? _nextStamp(tick)),
      tick,
    );
    return dropPending ? next.withdraw(key) : next;
  }

  /// [address] is blocked, from any standing.
  FriendshipBook block(
    String address,
    FriendshipTick tick, {
    FriendProfile Function(FriendProfile base)? shape,
  }) => _apply(
    PeerShareCodec.normalizeAddress(address),
    FriendshipRecord(FriendshipMark.blocked, _nextStamp(tick)),
    tick,
    shape: shape,
  );

  /// [address] is no longer blocked: neither a friend nor blocked.
  FriendshipBook unblock(
    String address,
    FriendshipTick tick, {
    FriendProfile Function(FriendProfile base)? shape,
  }) {
    final String key = PeerShareCodec.normalizeAddress(address);
    if (profileOf(key)?.status != FriendRelationshipStatus.blocked) {
      return this;
    }
    return _apply(
      key,
      FriendshipRecord(FriendshipMark.none, _nextStamp(tick)),
      tick,
      shape: shape,
    );
  }

  /// A record from another device of the account (or a copy of the
  /// account): taken when it is later than what is known here. [shape]
  /// gives what a new entry shows.
  FriendshipBook merge(
    String address,
    FriendshipRecord record,
    FriendshipTick tick, {
    FriendProfile Function(FriendProfile base)? shape,
  }) => record.mark == FriendshipMark.friend
      ? admit(address, OwnCopy(record.stamp), tick, shape: shape)
      : _apply(
          PeerShareCodec.normalizeAddress(address),
          record,
          tick,
          shape: shape,
        );

  /// Every record of [other] merged in ([merge]); a friend new here gets
  /// [other]'s entry.
  FriendshipBook mergeAll(FriendshipBook other, FriendshipTick tick) {
    FriendshipBook next = this;
    other._records.forEach((String address, FriendshipRecord record) {
      final FriendProfile? theirs = other._profiles[address];
      final bool known = next.profileOf(address) != null;
      next = next.merge(
        address,
        record,
        tick,
        shape: theirs == null || known
            ? null
            : (FriendProfile base) => theirs.copyWith(status: base.status),
      );
    });
    return next;
  }

  /// An invitation sent from here to [address]: requested (out). Not to a
  /// friend or someone blocked.
  FriendshipBook invite(
    String address,
    FriendProfile Function(FriendProfile base) shape, {
    bool nicknameChanged = false,
  }) => _request(
    address,
    FriendRelationshipStatus.pendingOutgoing,
    shape,
    nicknameChanged: nicknameChanged,
  );

  /// Their invitation came: requested (in). Not from a friend, someone
  /// blocked, or someone invited from here (both asked: [admit]).
  FriendshipBook invitedBy(
    String address,
    FriendProfile Function(FriendProfile base) shape,
  ) {
    final FriendRelationshipStatus? status = profileOf(address)?.status;
    if (status == FriendRelationshipStatus.pendingOutgoing) {
      return this;
    }
    return _request(address, FriendRelationshipStatus.pendingIncoming, shape);
  }

  /// An invitation either way (or an entry left with no standing) is gone:
  /// declined, cancelled, made room for. A friend or a block stays.
  FriendshipBook withdraw(String address) {
    final String key = PeerShareCodec.normalizeAddress(address);
    final FriendProfile? have = profileOf(key);
    if (have == null ||
        have.status == FriendRelationshipStatus.accepted ||
        have.status == FriendRelationshipStatus.blocked) {
      return this;
    }
    return _with(_put(key, null), _records, clock);
  }

  /// The oldest invitations received go until at most [keep] wait; returns
  /// the book and the addresses that went.
  (FriendshipBook, List<String>) withoutOldestInvitations({required int keep}) {
    final List<String> waiting = <String>[
      for (final MapEntry<String, FriendProfile> e in _profiles.entries)
        if (e.value.status == FriendRelationshipStatus.pendingIncoming) e.key,
    ];
    final int excess = waiting.length - keep;
    if (excess <= 0) {
      return (this, const <String>[]);
    }
    final List<String> evicted = waiting.sublist(0, excess);
    final Map<String, FriendProfile> rest = Map<String, FriendProfile>.of(
      _profiles,
    )..removeWhere((String key, _) => evicted.contains(key));
    return (_with(rest, _records, clock), evicted);
  }

  /// [address]'s entry as [change] makes it: what it shows (names, the chat
  /// line, unread, presence, retention), never its standing or address —
  /// those are the book's. Nothing when there is no entry. A change
  /// without a real name keeps the name told before; the nickname stays
  /// unless [nicknameChanged].
  FriendshipBook edit(
    String address,
    FriendProfile Function(FriendProfile profile) change, {
    bool nicknameChanged = false,
  }) {
    final String key = PeerShareCodec.normalizeAddress(address);
    final FriendProfile? have = profileOf(key);
    if (have == null) {
      return this;
    }
    final FriendProfile changed = change(have);
    if (identical(changed, have)) {
      return this;
    }
    final FriendProfile stored = _merged(
      have,
      changed.copyWith(address: key, status: have.status),
      nicknameChanged: nicknameChanged,
    );
    return _with(_put(key, stored), _records, clock);
  }

  /// Every entry as [change] makes it ([edit]); the same book when it
  /// changes none.
  FriendshipBook editAll(FriendProfile Function(FriendProfile profile) change) {
    Map<String, FriendProfile>? next;
    _profiles.forEach((String key, FriendProfile have) {
      final FriendProfile changed = change(have);
      if (identical(changed, have)) {
        return;
      }
      (next ??= Map<String, FriendProfile>.of(_profiles))[key] = changed
          .copyWith(address: key, status: have.status);
    });
    return next == null ? this : _with(next!, _records, clock);
  }

  // ---- inside ----

  FriendshipBook _request(
    String address,
    FriendRelationshipStatus status,
    FriendProfile Function(FriendProfile base) shape, {
    bool nicknameChanged = false,
  }) {
    final String key = PeerShareCodec.normalizeAddress(address);
    if (key.isEmpty) {
      return this;
    }
    final FriendProfile? have = profileOf(key);
    if (have?.status == FriendRelationshipStatus.accepted ||
        have?.status == FriendRelationshipStatus.blocked) {
      return this;
    }
    final FriendProfile base = have ?? FriendProfile(address: key);
    final FriendProfile stored = _merged(
      have,
      shape(base).copyWith(address: key, status: status),
      nicknameChanged: nicknameChanged || have == null,
    );
    return _with(_put(key, stored), _records, clock);
  }

  /// [record] for [key] when it is later than the one known, and the entry
  /// as it then stands.
  FriendshipBook _apply(
    String key,
    FriendshipRecord record,
    FriendshipTick tick, {
    FriendProfile Function(FriendProfile base)? shape,
  }) {
    if (key.isEmpty) {
      return this;
    }
    if (record.stamp.hlc.millis >
        tick.wallMillis + kMaxClockSkew.inMilliseconds) {
      // Dated too far ahead: it would win over everything for good.
      return this;
    }
    final FriendshipRecord? have = _records[key];
    if (have != null && !record.beats(have)) {
      return this;
    }
    final FriendProfile? current = profileOf(key);
    FriendProfile? profile = _settled(key, current, record.mark);
    if (profile != null && shape != null) {
      final FriendProfile shaped = shape(profile);
      profile = _merged(
        current,
        shaped.copyWith(address: key, status: profile.status),
      );
    }
    return _with(
      _put(key, profile),
      _pruned(<String, FriendshipRecord>{..._records, key: record}),
      record.stamp.hlc > clock ? record.stamp.hlc : clock,
    );
  }

  /// A stamp later than any this book made or saw.
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

  /// The entries with [key]'s set to [profile] (gone when `null`), other
  /// spellings of the address dropped; an entry kept stays where it was
  /// (the oldest invitations come first).
  Map<String, FriendProfile> _put(String key, FriendProfile? profile) {
    final Map<String, FriendProfile> next =
        Map<String, FriendProfile>.of(_profiles)..removeWhere(
          (String k, FriendProfile p) =>
              k != key &&
              (PeerShareCodec.addressesEqual(k, key) ||
                  PeerShareCodec.addressesEqual(p.address, key)),
        );
    if (profile == null) {
      next.remove(key);
    } else {
      next[key] = profile;
    }
    return next;
  }

  FriendshipBook _with(
    Map<String, FriendProfile> profiles,
    Map<String, FriendshipRecord> records,
    Hlc clock,
  ) => FriendshipBook._(
    UnmodifiableMapView<String, FriendProfile>(profiles),
    records is UnmodifiableMapView<String, FriendshipRecord>
        ? records
        : UnmodifiableMapView<String, FriendshipRecord>(records),
    clock,
  );
}

/// The entry of [key] once [mark] is settled for it: a friend's or a
/// blocked person's standing set; for a removal or "none" a friend's or a
/// block's entry goes (an invitation waiting either way stays: the user
/// answers it).
FriendProfile? _settled(String key, FriendProfile? have, FriendshipMark mark) {
  switch (mark) {
    case FriendshipMark.friend:
      return (have ?? FriendProfile(address: key)).copyWith(
        address: key,
        status: FriendRelationshipStatus.accepted,
        requestMessage: null,
        blockNote: null,
      );
    case FriendshipMark.blocked:
      return (have ?? FriendProfile(address: key)).copyWith(
        address: key,
        status: FriendRelationshipStatus.blocked,
        requestMessage: null,
      );
    case FriendshipMark.removed || FriendshipMark.none:
      if (have == null ||
          have.status == FriendRelationshipStatus.accepted ||
          have.status == FriendRelationshipStatus.blocked) {
        return have != null && mark == FriendshipMark.none
            ? have.copyWith(
                address: key,
                status: FriendRelationshipStatus.none,
                requestMessage: null,
                blockNote: null,
              )
            : null;
      }
      return have;
  }
}

/// [next] stored over [have]: a profile without a real name never wipes
/// the name the peer already told, and the nickname stays what this user
/// set unless [nicknameChanged].
FriendProfile _merged(
  FriendProfile? have,
  FriendProfile next, {
  bool nicknameChanged = false,
}) {
  if (have == null) {
    return next;
  }
  FriendProfile stored = next;
  if (have.hasProfileName && !stored.hasProfileName) {
    stored = stored.copyWith(displayName: have.displayName);
  }
  if (!nicknameChanged) {
    stored = stored.copyWith(nickname: have.nickname);
  }
  return stored;
}

/// The most removals (and unblocks) remembered; past it the oldest go.
const int kMaxRemovedFriends = 2000;

Map<String, FriendshipRecord> _pruned(Map<String, FriendshipRecord> records) {
  final List<MapEntry<String, FriendshipRecord>> gone =
      records.entries
          .where(
            (MapEntry<String, FriendshipRecord> e) =>
                e.value.mark == FriendshipMark.removed ||
                e.value.mark == FriendshipMark.none,
          )
          .toList()
        ..sort(
          (
            MapEntry<String, FriendshipRecord> a,
            MapEntry<String, FriendshipRecord> b,
          ) => a.value.stamp.compareTo(b.value.stamp),
        );
  if (gone.length <= kMaxRemovedFriends) {
    return records;
  }
  final Map<String, FriendshipRecord> rest = Map<String, FriendshipRecord>.of(
    records,
  );
  for (final MapEntry<String, FriendshipRecord> e in gone.take(
    gone.length - kMaxRemovedFriends,
  )) {
    rest.remove(e.key);
  }
  return rest;
}

/// Where someone stands with this account.
enum FriendshipStanding {
  none,
  requestedOut,
  requestedIn,
  friend,
  blocked,
  removed,
}

/// See [FriendshipBook.meaningOfAccept].
enum AcceptMeaning {
  /// Their answer to an invitation from here: a friend now.
  admits,

  /// From a friend: nothing new (their name may be).
  repeated,

  /// Nobody here invited them: as their invitation.
  invitation,

  /// Nothing at all.
  nothing,
}

/// What is settled for an address (see [FriendshipBook.records]).
enum FriendshipMark {
  /// A friend.
  friend('f'),

  /// Blocked.
  blocked('b'),

  /// Removed as a friend (by this account, or they removed it).
  removed('x'),

  /// Neither a friend nor blocked any more (unblocked).
  none('n');

  const FriendshipMark(this.code);

  /// How it is written.
  final String code;

  static FriendshipMark? fromCode(Object? code) {
    for (final FriendshipMark mark in values) {
      if (mark.code == code) {
        return mark;
      }
    }
    return null;
  }
}

/// When a record was made: a hybrid logical clock (wall time, then a
/// counter), then the device that made it — so two devices order every pair
/// of records the same way.
@immutable
final class FriendshipStamp implements Comparable<FriendshipStamp> {
  const FriendshipStamp(this.hlc, this.device);

  /// Older than anything: what was settled before stamps were kept.
  static const FriendshipStamp zero = FriendshipStamp(Hlc.zero, '');

  final Hlc hlc;
  final String device;

  @override
  int compareTo(FriendshipStamp other) {
    final int byClock = hlc.compareTo(other.hlc);
    return byClock != 0 ? byClock : device.compareTo(other.device);
  }

  @override
  bool operator ==(Object other) =>
      other is FriendshipStamp && other.hlc == hlc && other.device == device;

  @override
  int get hashCode => Object.hash(hlc, device);

  @override
  String toString() => 'FriendshipStamp(${hlc.millis}:${hlc.counter}@$device)';
}

/// A settled [mark] for an address, made at [stamp].
@immutable
final class FriendshipRecord {
  const FriendshipRecord(this.mark, this.stamp);

  final FriendshipMark mark;
  final FriendshipStamp stamp;

  /// Whether this record wins over [other]: the later stamp; on the very
  /// same stamp the stronger mark (a removal over a block over "none" over
  /// a friendship), so every device picks the same one.
  bool beats(FriendshipRecord other) {
    final int byStamp = stamp.compareTo(other.stamp);
    if (byStamp != 0) {
      return byStamp > 0;
    }
    return _strength(mark) > _strength(other.mark);
  }

  static int _strength(FriendshipMark mark) => switch (mark) {
    FriendshipMark.friend => 0,
    FriendshipMark.none => 1,
    FriendshipMark.blocked => 2,
    FriendshipMark.removed => 3,
  };

  /// `[mark, clock, device]`.
  List<Object> toJson() => <Object>[mark.code, stamp.hlc.toInt(), stamp.device];

  static FriendshipRecord? fromJson(Object? json) {
    if (json is! List || json.length < 2) {
      return null;
    }
    final FriendshipMark? mark = FriendshipMark.fromCode(json[0]);
    final Object? clock = json[1];
    final Object? device = json.length > 2 ? json[2] : '';
    if (mark == null || clock is! int || clock < 0 || device is! String) {
      return null;
    }
    return FriendshipRecord(mark, FriendshipStamp(Hlc.fromInt(clock), device));
  }

  @override
  bool operator ==(Object other) =>
      other is FriendshipRecord && other.mark == mark && other.stamp == stamp;

  @override
  int get hashCode => Object.hash(mark, stamp);

  @override
  String toString() => 'FriendshipRecord(${mark.name} $stamp)';
}

/// Records as written: normalized address → `[mark, clock, device]`.
Map<String, List<Object>> friendshipRecordsToJson(
  Map<String, FriendshipRecord> records,
) => <String, List<Object>>{
  for (final String address in records.keys.toList()..sort())
    address: records[address]!.toJson(),
};

/// Records read back from [json] ([friendshipRecordsToJson]); what does
/// not read is left out.
Map<String, FriendshipRecord> friendshipRecordsFromJson(Object? json) {
  final Map<String, FriendshipRecord> out = <String, FriendshipRecord>{};
  if (json is! Map) {
    return out;
  }
  for (final MapEntry<dynamic, dynamic> e in json.entries.take(
    kMaxRemovedFriends + 5000,
  )) {
    final Object? address = e.key;
    final FriendshipRecord? record = FriendshipRecord.fromJson(e.value);
    if (address is String && record != null) {
      out[PeerShareCodec.normalizeAddress(address)] = record;
    }
  }
  return out;
}

/// The moment a change is made at: the wall clock and the device.
@immutable
final class FriendshipTick {
  const FriendshipTick(this.wallMillis, this.device);

  /// Now, on [device].
  FriendshipTick.now(this.device)
    : wallMillis = DateTime.now().millisecondsSinceEpoch;

  final int wallMillis;
  final String device;
}

/// Why someone becomes a friend: the only ways in.
sealed class FriendshipEvidence {
  const FriendshipEvidence();

  /// They accepted the invitation sent from here (it must still wait:
  /// requested (out)).
  static const FriendshipEvidence theyAcceptedMine = TheyAcceptedMine();

  /// The user accepted their invitation here (requested (in)).
  static const FriendshipEvidence iAcceptedTheirs = IAcceptedTheirs();

  /// Their invitation came while one from here waited: both asked.
  static const FriendshipEvidence bothInvited = BothInvited();
}

/// See [FriendshipEvidence.theyAcceptedMine].
final class TheyAcceptedMine extends FriendshipEvidence {
  const TheyAcceptedMine();
}

/// See [FriendshipEvidence.iAcceptedTheirs].
final class IAcceptedTheirs extends FriendshipEvidence {
  const IAcceptedTheirs();
}

/// See [FriendshipEvidence.bothInvited].
final class BothInvited extends FriendshipEvidence {
  const BothInvited();
}

/// A friendship made on another device of this account, or kept in a copy
/// of the account, at [stamp]: it counts when it is later than what is
/// known here.
final class OwnCopy extends FriendshipEvidence {
  const OwnCopy(this.stamp);

  final FriendshipStamp stamp;
}

/// Records for what test builds of 1.15 kept before records: [removed]
/// (normalized address → when a friend was removed) and [since] (→ when a
/// friendship was made), beside [profiles]. A friendship becomes a friend
/// record at its time; a removal a removal record — unless the person is
/// still a friend or blocked in [profiles] (a friendship of unknown time
/// that was kept over it). Addresses [known] already has are left alone.
Map<String, FriendshipRecord> legacyFriendshipRecords({
  required Object? removed,
  required Object? since,
  required Map<String, FriendProfile> profiles,
  Map<String, FriendshipRecord> known = const <String, FriendshipRecord>{},
}) {
  Map<String, int> times(Object? json) => <String, int>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries.take(
        kMaxRemovedFriends + 5000,
      ))
        if (e.key is String && e.value is int && (e.value as int) > 0)
          PeerShareCodec.normalizeAddress(e.key as String): e.value as int,
  };
  FriendRelationshipStatus? statusOf(String key) {
    for (final FriendProfile p in profiles.values) {
      if (PeerShareCodec.addressesEqual(p.address, key)) {
        return p.status;
      }
    }
    return null;
  }

  final Map<String, FriendshipRecord> out = <String, FriendshipRecord>{};
  times(since).forEach((String key, int at) {
    if (!known.containsKey(key) &&
        statusOf(key) == FriendRelationshipStatus.accepted) {
      out[key] = FriendshipRecord(
        FriendshipMark.friend,
        FriendshipStamp(Hlc(at, 0), ''),
      );
    }
  });
  times(removed).forEach((String key, int at) {
    final FriendRelationshipStatus? status = statusOf(key);
    if (known.containsKey(key) ||
        status == FriendRelationshipStatus.accepted ||
        status == FriendRelationshipStatus.blocked) {
      return;
    }
    out[key] = FriendshipRecord(
      FriendshipMark.removed,
      FriendshipStamp(Hlc(at, 0), ''),
    );
  });
  return out;
}
