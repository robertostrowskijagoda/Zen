import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Following: anyone may follow anyone, without asking; a follower
// sees only public posts.
//
// A follow is a signed `follow` entry in the follower's own `acts` space
// (so every device of the follower follows the same people, and friends
// of the follower can see it). The followed person learns about it from
// the hello the follower's device sends anyway (to fetch the public
// posts): it carries the newest signed `follow` entry for that address.
// The followed device checks the signature and keeps a list of followers
// (who stopped greeting for [kFollowerTtl] drops off).

/// Entry kind of a follow (or, with `on: 0`, of stopping it).
const String kFollowKind = 'follow';

/// A follower whose device has not greeted for this long is dropped.
const Duration kFollowerTtl = Duration(days: 60);

const int _maxFollowName = 60;
const int _maxFollowers = 5000;
const String _followersKey = 'ledger/followers';

/// Body of following [address] ([account] when known, [name]: the
/// follower's own name, so the followed person sees who it is).
Map<String, dynamic> followBody(
  String address, {
  String account = '',
  String name = '',
  bool on = true,
}) => <String, dynamic>{
  'addr': PeerShareCodec.normalizeAddress(address),
  if (account.isNotEmpty) 'a': account,
  if (name.trim().isNotEmpty)
    'n': name.trim().length > _maxFollowName
        ? name.trim().substring(0, _maxFollowName)
        : name.trim(),
  'on': on ? 1 : 0,
};

/// The newest follow entry per followed (normalised) address in [acts].
Map<String, LogEntry> latestFollows(Iterable<LogEntry> acts) {
  final Map<String, LogEntry> latest = <String, LogEntry>{};
  for (final LogEntry e in acts) {
    final Object? addr = e.body['addr'];
    if (e.kind != kFollowKind || addr is! String || addr.isEmpty) {
      continue;
    }
    final LogEntry? had = latest[addr];
    if (had == null || e.hlc > had.hlc) {
      latest[addr] = e;
    }
  }
  return latest;
}

/// Someone following this account (who is not necessarily a friend).
@immutable
final class Follower {
  const Follower({
    required this.account,
    required this.address,
    required this.name,
    required this.since,
    required this.seen,
  });

  final String account;

  /// Mesh address their notice came from.
  final String address;

  /// The name they gave in their follow ('' if none).
  final String name;

  /// HLC (as int) of their follow entry.
  final int since;

  /// When their device last greeted (wall millis).
  final int seen;

  Follower seenAt(int millis) => Follower(
    account: account,
    address: address,
    name: name,
    since: since,
    seen: millis,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'addr': address,
    'n': name,
    'h': since,
    's': seen,
  };

  static Follower? fromJson(String account, Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? addr = json['addr'];
    final Object? n = json['n'];
    final Object? h = json['h'];
    final Object? s = json['s'];
    if (addr is! String || h is! int || s is! int) {
      return null;
    }
    return Follower(
      account: account,
      address: addr,
      name: n is String ? n : '',
      since: h,
      seen: s,
    );
  }
}

/// Follows, followers and blocked followers of one [LedgerNode].
final class FollowLedger {
  FollowLedger._(this.node, this._now);

  static final Expando<FollowLedger> _byNode = Expando<FollowLedger>();

  /// The follow ledger of [node] (attached the first time it is asked
  /// for: from then on hellos carry follow notices). [now] is for tests.
  static FollowLedger of(LedgerNode node, {int Function()? now}) {
    final FollowLedger? known = _byNode[node];
    if (known != null) {
      return known;
    }
    final FollowLedger created = FollowLedger._(
      node,
      now ?? () => DateTime.now().millisecondsSinceEpoch,
    );
    _byNode[node] = created;
    created._attach();
    return created;
  }

  final LedgerNode node;
  final int Function() _now;

  /// Latest own follow entry per followed address.
  final Map<String, LogEntry> _latest = <String, LogEntry>{};
  final Map<String, Follower> _followers = <String, Follower>{};
  final Map<String, String> _blocked = <String, String>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<LogEntry>? _added;
  Future<void>? _ready;

  /// Fires when followers (or blocked followers) change.
  Stream<void> get changes => _changes.stream;

  /// Done once the saved followers and follow entries are read.
  Future<void> get ready => _ready ?? Future<void>.value();

  void _attach() {
    node.helloExtras = _helloExtras;
    node.onStrangerHello = _onStrangerHello;
    final Future<void> ready = _start();
    _ready = ready;
    // Nobody has to wait for it: a ledger that cannot start (its identity
    // damaged) is logged here, not left as an error nobody handles; who
    // awaits [ready] still learns of it.
    unawaitedLogged(ready, context: 'Starting the follows failed');
  }

  Future<void> _start() async {
    await node.start();
    await _load();
    _latest.addAll(latestFollows(node.entriesOf(spaceKind: 'acts')));
    _added = node.store.added.listen(_onAdded);
    await _applyFollowEntries();
  }

  Future<void> dispose() async {
    await _added?.cancel();
    if (identical(_byNode[node], this)) {
      _byNode[node] = null;
    }
    if (node.helloExtras == _helloExtras) {
      node.helloExtras = null;
    }
    if (node.onStrangerHello == _onStrangerHello) {
      node.onStrangerHello = null;
    }
    await _changes.close();
  }

  // ---- following ----

  String get _myName => latestProfile(node, node.account)?.name ?? '';

  /// Follows [address]: the local follow (public posts start coming) and a
  /// signed entry (other own devices follow too; the person learns it).
  Future<void> follow(String address) async {
    await ready;
    final String normalized = PeerShareCodec.normalizeAddress(address);
    if (normalized.isEmpty) {
      return;
    }
    await _write(normalized, on: true);
    await node.follow(normalized);
  }

  /// Stops following [address] and tells them (one more hello).
  Future<void> unfollow(String address) async {
    await ready;
    final String normalized = PeerShareCodec.normalizeAddress(address);
    if (normalized.isEmpty) {
      return;
    }
    final String account = node.knownAccountOf(normalized) ?? '';
    await node.unfollow(normalized);
    await _write(normalized, on: false, account: account);
    node.greet(normalized);
  }

  Future<void> _write(
    String address, {
    required bool on,
    String? account,
  }) async {
    final LogEntry? had = _latest[address];
    if (had != null && (had.body['on'] == 1) == on) {
      return;
    }
    final LogEntry e = await node.publish(
      kFollowKind,
      followBody(
        address,
        account: account ?? node.knownAccountOf(address) ?? '',
        name: _myName,
        on: on,
      ),
      spaceKind: 'acts',
    );
    _latest[address] = e;
  }

  /// Follows another own device made are taken over.
  Future<void> _applyFollowEntries() async {
    for (final MapEntry<String, LogEntry> f in _latest.entries.toList()) {
      if (f.value.body['on'] == 1 &&
          !node.isFollowing(f.key) &&
          !node.isFriendAddress(f.key)) {
        await node.follow(f.key);
      }
    }
  }

  void _onAdded(LogEntry e) {
    if (e.kind != kFollowKind || e.account != node.account) {
      return;
    }
    final Object? addr = e.body['addr'];
    if (addr is! String || addr.isEmpty) {
      return;
    }
    final LogEntry? had = _latest[addr];
    if (had != null && had.hlc > e.hlc) {
      return;
    }
    _latest[addr] = e;
    if (e.device == node.identity.deviceKey.id) {
      return; // written here: already applied
    }
    // Another device of this account followed or stopped following.
    final bool on = e.body['on'] == 1;
    unawaitedLogged(
      on ? node.follow(addr) : node.unfollow(addr),
      context: 'Following from another device failed',
    );
  }

  /// Addresses this account follows explicitly (with a signed entry).
  Set<String> get followed => <String>{
    for (final MapEntry<String, LogEntry> f in _latest.entries)
      if (f.value.body['on'] == 1) f.key,
  };

  Map<String, dynamic>? _helloExtras(String address) {
    final LogEntry? e = _latest[address];
    if (e == null) {
      return null;
    }
    // The hello carries this device's certificate; a notice another
    // device of the account wrote goes with its own.
    return <String, dynamic>{
      'fw': e.device == node.identity.deviceKey.id
          ? e.toJson()
          : e.toCertifiedJson(),
    };
  }

  // ---- followers ----

  void _onStrangerHello(
    String address,
    String account,
    Map<String, dynamic> payload,
  ) {
    final Object? notice = payload['fw'];
    if (notice == null) {
      return;
    }
    unawaitedLogged(
      takeNotice(
        address,
        account,
        notice,
        certificate: DeviceCertificate.fromJson(payload['cert']),
      ),
      context: 'Reading follows failed',
    );
  }

  /// Takes a follow notice [notice] that came from [address] in a proven
  /// hello of [account] (whose device [certificate] checks a notice that
  /// comes without its own). Returns true when the followers changed.
  @visibleForTesting
  Future<bool> takeNotice(
    String address,
    String account,
    Object? notice, {
    DeviceCertificate? certificate,
  }) async {
    await ready;
    if (_blocked.containsKey(account) || account == node.account) {
      return false;
    }
    final LogEntry? e = await verifiedEntry(notice, certificate: certificate);
    if (e == null ||
        e.kind != kFollowKind ||
        e.account != account ||
        e.space != accountSpace('acts', account)) {
      return false;
    }
    final Object? addr = e.body['addr'];
    final Object? target = e.body['a'];
    final String own = node.ownAddress;
    final bool forUs =
        target == node.account ||
        (addr is String &&
            (own.isEmpty || PeerShareCodec.normalizeAddress(addr) == own));
    if (!forUs) {
      return false;
    }
    final int now = _now();
    final Follower? had = _followers[account];
    final int at = e.hlc.toInt();
    if (had != null && had.since > at) {
      return false; // an older notice
    }
    if (e.body['on'] != 1) {
      if (_followers.remove(account) != null) {
        await _save();
        _emit();
        return true;
      }
      return false;
    }
    if (had != null && had.since == at) {
      // The same follow greeting again: only remember it is alive (on
      // disk at most once a day).
      _followers[account] = had.seenAt(now);
      if (now - had.seen > const Duration(days: 1).inMilliseconds) {
        await _save();
      }
      return false;
    }
    if (had == null && _followers.length >= _maxFollowers) {
      _dropStale(now);
      if (_followers.length >= _maxFollowers) {
        return false;
      }
    }
    final Object? n = e.body['n'];
    _followers[account] = Follower(
      account: account,
      address: PeerShareCodec.normalizeAddress(address),
      name: n is String
          ? (n.length > _maxFollowName ? n.substring(0, _maxFollowName) : n)
          : '',
      since: at,
      seen: now,
    );
    await _save();
    _emit();
    return true;
  }

  void _dropStale(int now) {
    _followers.removeWhere(
      (String _, Follower f) => now - f.seen > kFollowerTtl.inMilliseconds,
    );
  }

  /// People following this account who are not friends (friends follow
  /// automatically), newest first. Blocked followers are left out.
  List<Follower> get followers {
    final int now = _now();
    final Set<String> friends = node.friendAccounts.values.toSet();
    return <Follower>[
      for (final Follower f in _followers.values)
        if (now - f.seen <= kFollowerTtl.inMilliseconds &&
            !friends.contains(f.account) &&
            !_blocked.containsKey(f.account))
          f,
    ]..sort((Follower a, Follower b) => b.since.compareTo(a.since));
  }

  /// Friends follow automatically: everyone on the friend list, also
  /// one whose account is not known yet (their device has not greeted).
  int get friendCount => node
      .friendAddresses()
      .map(PeerShareCodec.normalizeAddress)
      .toSet()
      .length;

  /// Everyone following: friends (automatically) and the others. It
  /// matches the friend count and the list of followers.
  int get followerCount => friendCount + followers.length;

  /// Blocked followers: account → name.
  Map<String, String> get blocked => Map<String, String>.unmodifiable(_blocked);

  bool isBlocked(String account) => _blocked.containsKey(account);

  /// Blocks a follower: they leave the list, their notices are
  /// ignored and their reactions disappear from this account's threads (a
  /// signed `thread_block`). They can still read public posts.
  Future<void> block(String account, {String name = ''}) async {
    await ready;
    if (account.isEmpty || account == node.account) {
      return;
    }
    _blocked[account] = name;
    _followers.remove(account);
    await node.publish(
      kThreadBlockKind,
      threadBlockBody(account, name: name),
      spaceKind: 'acts',
    );
    await _save();
    _emit();
  }

  Future<void> unblock(String account) async {
    await ready;
    if (_blocked.remove(account) == null) {
      return;
    }
    await node.publish(
      kThreadBlockKind,
      threadBlockBody(account, on: false),
      spaceKind: 'acts',
    );
    await _save();
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  Future<void> _load() async {
    final Uint8List? raw = await node.disk.read(_followersKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return;
      }
      final Object? f = json['f'];
      if (f is Map) {
        for (final MapEntry<dynamic, dynamic> e in f.entries) {
          final Follower? follower = e.key is String
              ? Follower.fromJson(e.key as String, e.value)
              : null;
          if (follower != null) {
            _followers[follower.account] = follower;
          }
        }
      }
      final Object? b = json['b'];
      if (b is Map) {
        for (final MapEntry<dynamic, dynamic> e in b.entries) {
          if (e.key is String) {
            _blocked[e.key as String] = e.value is String
                ? e.value as String
                : '';
          }
        }
      }
    } on FormatException {
      logZenWarning('The list of followers is damaged.');
    }
  }

  Future<void> _save() {
    _dropStale(_now());
    return node.disk.write(
      _followersKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'f': <String, dynamic>{
              for (final Follower f in _followers.values) f.account: f.toJson(),
            },
            'b': _blocked,
          }),
        ),
      ),
    );
  }
}
