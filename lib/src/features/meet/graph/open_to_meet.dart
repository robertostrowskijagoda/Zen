import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What a person said they are open to on the graph: an explicit opt-in
/// from the dating profile ("Pokazać Cię na grafie…?", off by default).
/// Only the intention travels, nothing else from the dating profile.
enum OpenToMeet {
  dates('d'),
  friends('f'),
  both('b');

  const OpenToMeet(this.code);

  final String code;

  static OpenToMeet? byCode(Object? code) =>
      OpenToMeet.values.where((OpenToMeet o) => o.code == code).firstOrNull;

  /// The intention of the dating profile ("Szukam").
  static OpenToMeet forIntent(DatingIntent intent) => switch (intent) {
    DatingIntent.dates => OpenToMeet.dates,
    DatingIntent.friends => OpenToMeet.friends,
    DatingIntent.both => OpenToMeet.both,
  };

  /// The badge on the graph.
  String get label => switch (this) {
    OpenToMeet.dates => t('randki'),
    OpenToMeet.friends => t('znajomości'),
    OpenToMeet.both => t('randki i znajomości'),
  };
}

/// Most hidden people one person's flag carries (as salted hashes; the
/// list is filled up with random ones to a multiple of [kOpenHidePad]).
const int kOpenMaxHidden = 512;

/// The hide list's length is a multiple of this, so it does not tell how
/// many people are hidden.
const int kOpenHidePad = 32;

/// Most friends' flags passed on in one frame.
const int kOpenMaxRelayed = 2000;

/// Steps of friendship a flag reaches at most without gates (as Dating).
const int kOpenMaxHops = kDatingMaxHops;

final RegExp _address = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');
final RegExp _hash = RegExp(r'^[0-9a-f]{32}$');

String _n(String a) => PeerShareCodec.normalizeAddress(a);

/// The salted hash of [address] in a person's "not for them" list: a
/// friend who passes the flag on checks the next person against it. The
/// salt is new for every friend and the list goes no further than them, so
/// a list cannot be checked by anyone else (only by that friend, for
/// people they could pass the flag to).
String openHideHash(String salt, String address) => crypto.sha256
    .convert(utf8.encode('zen-graph-open-hide|$salt|${_n(address)}'))
    .toString()
    .substring(0, 32);

Set<String> _hashes(Object? ex, int max) => ex is! List
    ? const <String>{}
    : ex.whereType<String>().where(_hash.hasMatch).take(max).toSet();

/// A flag a friend passed on: whose ([OpenToMeet]), their name as the friend
/// knows it, how many steps from the friend ([hops]: 1 = the friend's own
/// friend, 2 = a friend of theirs) and who knows them ([via], for 2). It
/// carries no list of the people it must not reach: that list goes only to
/// the person's own friends, keyed for each of them ([FriendOpenness]), so
/// nobody further can probe it. A friend's friend passes such a flag one
/// step further unless it is marked [noRelay].
@immutable
final class RelayedOpen {
  const RelayedOpen({
    required this.open,
    this.name = '',
    this.hops = 1,
    this.via = '',
    this.noRelay = false,
  });

  final OpenToMeet open;
  final String name;
  final int hops;
  final String via;
  final bool noRelay;

  /// Whether this flag may be passed on one step further.
  bool get relayable => hops == 1 && !noRelay;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'o': open.code,
    if (name.isNotEmpty) 'n': name,
    'h': hops,
    if (via.isNotEmpty) 'v': via,
    if (noRelay) 'nr': true,
  };

  static RelayedOpen? fromJson(Object? json) {
    if (json is String) {
      final OpenToMeet? o = OpenToMeet.byCode(json);
      return o == null ? null : RelayedOpen(open: o, noRelay: true);
    }
    if (json is! Map) {
      return null;
    }
    final OpenToMeet? o = OpenToMeet.byCode(json['o']);
    if (o == null) {
      return null;
    }
    final Object? name = json['n'];
    final Object? via = json['v'];
    final int hops = json['h'] == 2 ? 2 : 1;
    return RelayedOpen(
      open: o,
      name: name is String
          ? (name.length > 60 ? name.substring(0, 60) : name)
          : '',
      hops: hops,
      via: hops == 2 && via is String && _address.hasMatch(via) ? _n(via) : '',
      noRelay: hops != 1 || json['nr'] == true,
    );
  }
}

/// What one friend told this phone: their own flag (with the salted
/// hashes of the people it must not reach) and the flags they passed on.
@immutable
final class FriendOpenness {
  const FriendOpenness({
    this.own,
    this.salt = '',
    this.hide = const <String>{},
    this.relayed = const <String, RelayedOpen>{},
    this.noRelay = false,
  });

  final OpenToMeet? own;
  final String salt;
  final Set<String> hide;
  final Map<String, RelayedOpen> relayed;

  /// The friend hides from more people than a flag carries
  /// ([kOpenMaxHidden]): their flag is passed on to nobody (those past the
  /// list could not be kept from it).
  final bool noRelay;

  bool get isEmpty => own == null && relayed.isEmpty;

  /// Whether [address] may get [own] passed on (not hidden from them).
  bool reaches(String address) =>
      !noRelay && !hide.contains(openHideHash(salt, address));

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (own != null) 'o': own!.code,
    if (salt.isNotEmpty) 'xs': salt,
    if (hide.isNotEmpty) 'ex': hide.toList()..sort(),
    if (noRelay) 'nr': true,
    if (relayed.isNotEmpty)
      'r': <String, dynamic>{
        for (final MapEntry<String, RelayedOpen> e in relayed.entries)
          e.key: e.value.toJson(),
      },
  };

  /// Reads a stored entry or a friend's frame (with limits). [self] tells
  /// this phone's own addresses (never kept as someone else's flag).
  static FriendOpenness fromJson(
    Object? json, {
    String? from,
    bool Function(String address)? self,
  }) {
    if (json is! Map) {
      return const FriendOpenness();
    }
    final OpenToMeet? own = OpenToMeet.byCode(json['o']);
    final Object? xs = json['xs'];
    final Object? ex = json['ex'];
    final Object? r = json['r'];
    final Map<String, RelayedOpen> relayed = <String, RelayedOpen>{};
    if (r is Map) {
      for (final MapEntry<dynamic, dynamic> e in r.entries) {
        if (relayed.length >= kOpenMaxRelayed) {
          break;
        }
        final Object? k = e.key;
        final RelayedOpen? o = RelayedOpen.fromJson(e.value);
        if (k is! String || o == null || !_address.hasMatch(k)) {
          continue;
        }
        final String a = _n(k);
        if (a == from || (self?.call(a) ?? false)) {
          continue;
        }
        relayed[a] = o;
      }
    }
    return FriendOpenness(
      own: own,
      salt: own != null && xs is String && xs.length <= 40 ? xs : '',
      hide: own == null ? const <String>{} : _hashes(ex, kOpenMaxHidden),
      relayed: relayed,
      noRelay:
          own != null &&
          (json['nr'] == true || (ex is List && ex.length > kOpenMaxHidden)),
    );
  }
}

/// What this phone keeps about "open to meet" (key [OpenToMeetService.storeKey]).
final class OpenToMeetBook {
  OpenToMeet? mine;

  /// The salt of this person's hidden list, one for each friend it goes to.
  final Map<String, String> salts = <String, String>{};

  /// People the flag must not reach (the dating profile's "Ukryj przed"
  /// as it was when the flag was saved; the live list is added on top).
  final Set<String> hiddenFrom = <String>{};

  /// What each friend (or person across an opened gate) said.
  final Map<String, FriendOpenness> friends = <String, FriendOpenness>{};

  /// What each friend was last sent (short digest, when): unchanged is not
  /// sent again before [OpenToMeetService.resendAfter].
  final Map<String, (String, int)> sent = <String, (String, int)>{};

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 3,
    if (mine != null) 'my': mine!.code,
    if (salts.isNotEmpty) 'xs': salts,
    if (hiddenFrom.isNotEmpty) 'hf': hiddenFrom.toList()..sort(),
    'fr': <String, dynamic>{
      for (final MapEntry<String, FriendOpenness> e in friends.entries)
        e.key: e.value.toJson(),
    },
    'sent': <String, dynamic>{
      for (final MapEntry<String, (String, int)> e in sent.entries)
        e.key: <Object>[e.value.$1, e.value.$2],
    },
  };

  static OpenToMeetBook fromJson(Object? json) {
    final OpenToMeetBook book = OpenToMeetBook();
    if (json is! Map || !isReadableFormat(json, current: 3, oldest: 3)) {
      return book;
    }
    book.mine = OpenToMeet.byCode(json['my']);
    final Object? xs = json['xs'];
    if (xs is Map) {
      for (final MapEntry<dynamic, dynamic> e in xs.entries) {
        if (e.key is String && e.value is String) {
          book.salts[e.key as String] = e.value as String;
        }
      }
    }
    final Object? hf = json['hf'];
    if (hf is List) {
      book.hiddenFrom.addAll(
        hf.whereType<String>().where(_address.hasMatch).map(_n).take(5000),
      );
    }
    final Object? fr = json['fr'];
    if (fr is Map) {
      for (final MapEntry<dynamic, dynamic> e in fr.entries) {
        if (e.key is String && _address.hasMatch(e.key as String)) {
          final String a = _n(e.key as String);
          final FriendOpenness f = FriendOpenness.fromJson(e.value, from: a);
          if (!f.isEmpty) {
            book.friends[a] = f;
          }
        }
      }
    }
    final Object? sent = json['sent'];
    if (sent is Map) {
      for (final MapEntry<dynamic, dynamic> e in sent.entries) {
        final Object? v = e.value;
        if (e.key is String &&
            v is List &&
            v.length == 2 &&
            v[0] is String &&
            v[1] is int) {
          book.sent[e.key as String] = (v[0] as String, v[1] as int);
        }
      }
    }
    return book;
  }
}

/// "Otwarty(-a) na poznanie" on the graph: this person's opt-in goes to
/// friends (never to those the dating profile is hidden from, nor to weak
/// acquaintances) and to the people across this person's opened gates.
/// Each friend passes it on to their own friends who see their friend list,
/// and those once more to theirs — so it reaches people up to three steps
/// away (as Dating does, no gate needed). The hide list goes only to this
/// person's own friends, salted anew for each: they keep the flag from the
/// hidden people they would pass it to, and nobody further gets a list to
/// probe. (Further away, a hidden friend's own app shows only what that
/// friend says themselves, so it shows nothing.)
/// Only the intention travels (and the name the friend knows); nothing of
/// the dating profile itself.
final class OpenToMeetService extends ChangeNotifier {
  OpenToMeetService({
    required this.host,
    required this.disk,
    this.listVisibleTo,
    this.isWeak,
    this.hiddenFrom,
    this.gateContacts,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  /// The frame: `o` own flag, `xs`/`ex` salt and hashes of who it must
  /// not reach, `r` flags passed on (address → [RelayedOpen]).
  static const String frameType = 'graph_open';
  static const String storeKey = 'meet/graph-open';

  /// An unchanged frame goes to a friend again after this long (a lost
  /// one is not lost for good).
  static const Duration resendAfter = Duration(days: 1);

  final MeetHost host;
  final LedgerDisk disk;

  /// Whether [friend] sees this person's friend list: friends' flags are
  /// passed on only with it (without it they do not see those people).
  final bool Function(String friend)? listVisibleTo;

  /// Weak acquaintances get no flag (like statuses).
  final bool Function(String friend)? isWeak;

  /// Everyone the dating profile is hidden from now.
  final Set<String> Function()? hiddenFrom;

  /// People this person reached through an opened gate, or who reached this
  /// person through one: they get this person's flag and their own flags
  /// (and the ones they pass on) are taken, but never passed further.
  final Set<String> Function()? gateContacts;

  final int Function() _now;
  final Random _random;

  OpenToMeetBook _book = OpenToMeetBook();
  Map<String, (OpenToMeet, int)> _relayed = const <String, (OpenToMeet, int)>{};
  Future<void> _queue = Future<void>.value();
  Future<void>? _loading;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// [length] random hex digits.
  String _hex(int length) => List<String>.generate(
    length,
    (_) => _random.nextInt(16).toRadixString(16),
  ).join();

  /// This person's own flag (`null`: not shown on the graph).
  OpenToMeet? get mine => _book.mine;

  @visibleForTesting
  OpenToMeetBook get book => _book;

  Set<String> _gates() => gateContacts?.call().map(_n).toSet() ?? <String>{};

  bool _isGate(String address) => _gates().contains(_n(address));

  Future<T> _inTurn<T>(Future<T> Function() work) {
    final Completer<T> done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await work());
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<void> load() => _loading ??= _inTurn<void>(() async {
    try {
      final Uint8List? raw = await disk.read(storeKey);
      if (raw != null) {
        final Object? json = jsonDecode(utf8.decode(raw));
        // A newer build's file stays as it is (saves are skipped).
        heldAsNewerOn(disk, storeKey, json, current: 3);
        _book = OpenToMeetBook.fromJson(json);
      }
    } on Object catch (error, stack) {
      logZenError('Graph: reading open to meet', error, stack);
    }
    _reindex();
    _changed();
  });

  Future<void> _save() async {
    try {
      await disk.write(
        storeKey,
        Uint8List.fromList(utf8.encode(jsonEncode(_book.toJson()))),
      );
    } on Object catch (error, stack) {
      logZenError('Graph: saving open to meet', error, stack);
    }
  }

  /// Steps from this person of a flag [o] passed on by [from]: one more than
  /// from the friend, and past three when [from] is across a gate.
  int _stepsOf(String from, RelayedOpen o) =>
      _isGate(from) ? kOpenMaxHops + o.hops : o.hops + 1;

  void _reindex() {
    final Map<String, (OpenToMeet, int)> index = <String, (OpenToMeet, int)>{};
    // Gone friends are dropped in [shareAll], once the friends are known.
    final List<String> order = _book.friends.keys.toList()..sort();
    for (final String f in order) {
      _book.friends[f]!.relayed.forEach((String a, RelayedOpen o) {
        final int steps = _stepsOf(f, o);
        final (OpenToMeet, int)? had = index[a];
        if (had == null || steps < had.$2) {
          index[a] = (o.open, steps);
        }
      });
    }
    _relayed = index;
  }

  /// What [address] is open to, as this phone knows it: a friend's own
  /// word (or that of someone across an opened gate), or for anyone further
  /// what friends passed on. A friend who did not tell this phone shows
  /// nothing (they may hide it from this person, or keep them a weak
  /// acquaintance).
  OpenToMeet? openOf(String address) {
    final String a = _n(address);
    if (host.isFriend(a) || _isGate(a)) {
      return _book.friends[a]?.own;
    }
    return _relayed[a]?.$1;
  }

  /// The people open to meet beyond friends of friends: three steps away, or
  /// across an opened gate (address → the name the friend knows them by, ''
  /// if none, and who knows them — a friend of a friend, or the friend or
  /// person across a gate who passed it on). For the graph's far ring.
  Map<String, ({String name, Set<String> via})> farOpen() {
    final Map<String, ({String name, Set<String> via})> out =
        <String, ({String name, Set<String> via})>{};
    final List<String> order = _book.friends.keys.toList()..sort();
    for (final String f in order) {
      final bool gate = _isGate(f);
      if (gate && !host.isFriend(f) && _book.friends[f]?.own != null) {
        final ({String name, Set<String> via})? had = out[f];
        out[f] = (name: had?.name ?? '', via: <String>{...?had?.via});
      }
      _book.friends[f]!.relayed.forEach((String a, RelayedOpen o) {
        if (host.isFriend(a) || host.isSelf(a) || (!gate && o.hops < 2)) {
          return;
        }
        final ({String name, Set<String> via})? had = out[a];
        out[a] = (
          name: had != null && had.name.isNotEmpty ? had.name : o.name,
          via: <String>{...?had?.via, if (o.via.isNotEmpty) o.via else f},
        );
      });
    }
    return out;
  }

  /// Sets (or with `null` takes back) this person's flag and tells
  /// friends. [hiddenFrom]: the dating profile's "Ukryj przed" now.
  Future<void> setMine(
    OpenToMeet? to, {
    Iterable<String> hiddenFrom = const <String>[],
  }) async {
    await load();
    await _inTurn<void>(() async {
      _book.mine = to;
      _book.hiddenFrom.clear();
      if (to != null) {
        _book.hiddenFrom.addAll(hiddenFrom.map(_n));
      }
      await _save();
    });
    _changed();
    await shareAll();
  }

  /// What goes to [friend] (or a person across an opened gate) now.
  Map<String, dynamic> payloadFor(String friend) {
    final String f = _n(friend);
    final OpenToMeet? mine = _book.mine;
    final Map<String, dynamic> out = <String, dynamic>{'type': frameType};
    if (mine != null) {
      final Set<String> hidden = <String>{
        ..._book.hiddenFrom,
        ...?hiddenFrom?.call().map(_n),
      };
      if (!hidden.contains(f) && !(isWeak?.call(f) ?? false)) {
        // Weak acquaintances are hidden from too: a friend who passes the
        // flag on cannot tell them apart otherwise (they may see that
        // friend's list), so it would reach them one step round.
        final Set<String> notFor = <String>{
          ...hidden,
          for (final String w in host.friends().map(_n))
            if (isWeak?.call(w) ?? false) w,
        };
        // A salt of its own for this friend: the list is good for checking
        // only with it, and the friend passes no list on.
        final String salt = _book.salts[f] ??= _hex(16);
        final List<String> hashes = <String>[
          for (final String a in notFor.take(kOpenMaxHidden))
            openHideHash(salt, a),
        ];
        // Filled up (the same way every time, so an unchanged frame stays
        // unchanged) with hashes of nobody.
        for (
          int i = 0;
          hashes.isEmpty || hashes.length % kOpenHidePad != 0;
          i++
        ) {
          hashes.add(openHideHash(salt, 'pad|$i'));
        }
        hashes.sort();
        out
          ..['o'] = mine.code
          ..['xs'] = salt
          ..['ex'] = hashes;
        if (notFor.length > kOpenMaxHidden) {
          // The list does not fit: the flag goes no further than this
          // friend.
          out['nr'] = true;
        }
      }
    }
    if (host.isFriend(f) && (listVisibleTo?.call(f) ?? false)) {
      final List<String> order = _book.friends.keys.toList()..sort();
      final Map<String, dynamic> relay = <String, dynamic>{};
      // Friends' own flags first (friends of friends for [f]), then the
      // flags friends passed on (three steps for [f]).
      for (final String w in order) {
        final FriendOpenness o = _book.friends[w]!;
        if (relay.length >= kOpenMaxRelayed) {
          break;
        }
        if (w == f || o.own == null || !host.isFriend(w) || !o.reaches(f)) {
          continue;
        }
        relay[w] = RelayedOpen(
          open: o.own!,
          name: host.nameOf(w),
          noRelay: o.noRelay,
        ).toJson();
      }
      for (final String w in order) {
        if (!host.isFriend(w)) {
          continue;
        }
        _book.friends[w]!.relayed.forEach((String a, RelayedOpen o) {
          if (relay.length >= kOpenMaxRelayed ||
              relay.containsKey(a) ||
              a == f ||
              host.isFriend(a) ||
              !o.relayable) {
            return;
          }
          relay[a] = RelayedOpen(
            open: o.open,
            name: o.name,
            hops: 2,
            via: w,
          ).toJson();
        });
      }
      if (relay.isNotEmpty) {
        out['r'] = relay;
      }
    }
    return out;
  }

  /// Sends each friend (and person across an opened gate) what changed for
  /// them (unchanged: once a day at most; someone told before who now gets
  /// nothing gets an empty frame, so they forget).
  Future<void> shareAll() async {
    await load();
    await _inTurn<void>(() async {
      final Set<String> gates = _gates();
      final List<String> friends = <String>{
        ...host.friends().map(_n),
        ...gates,
      }.toList()..sort();
      bool changed = false;
      if (friends.isNotEmpty) {
        // Gone friends: what they said and what they were sent is dropped
        // (only once the friends are known: an empty list may be unread).
        final Set<String> known = friends.toSet();
        final int before = _book.friends.length + _book.sent.length;
        _book.friends.removeWhere((String a, _) => !known.contains(a));
        _book.sent.removeWhere((String a, _) => !known.contains(a));
        _book.salts.removeWhere((String a, _) => !known.contains(a));
        changed = before != _book.friends.length + _book.sent.length;
        if (changed) {
          _reindex();
        }
      }
      final int now = _now();
      for (final String f in friends) {
        final Map<String, dynamic> payload = payloadFor(f);
        final bool empty = payload.length == 1;
        final (String, int)? last = _book.sent[f];
        final String digest = crypto.sha256
            .convert(utf8.encode(jsonEncode(payload)))
            .toString()
            .substring(0, 16);
        if (empty
            ? last == null
            : last != null &&
                  last.$1 == digest &&
                  now - last.$2 < resendAfter.inMilliseconds) {
          continue;
        }
        try {
          await host.send(f, payload);
        } on Object catch (error) {
          logZenWarning('Graph: sending open to meet to $f: $error');
          continue;
        }
        if (empty) {
          _book.sent.remove(f);
        } else {
          _book.sent[f] = (digest, now);
        }
        changed = true;
      }
      if (changed) {
        await _save();
      }
    });
  }

  /// A friend's frame (or one from across an opened gate). Returns whether
  /// it was one of these.
  Future<bool> handle(SignalTransportFrame frame) async {
    if (frame.payload['type'] != frameType) {
      return false;
    }
    final String from = _n(frame.from);
    if (!(host.isFriend(from) || _isGate(from)) || host.isSelf(from)) {
      return true;
    }
    await load();
    final FriendOpenness got = FriendOpenness.fromJson(
      frame.payload,
      from: from,
      self: host.isSelf,
    );
    final bool changed = await _inTurn<bool>(() async {
      final FriendOpenness? before = _book.friends[from];
      if (got.isEmpty) {
        _book.friends.remove(from);
      } else {
        _book.friends[from] = got;
      }
      _reindex();
      await _save();
      // Their friends who see this person's list hear it from here: their
      // own flag, and the flags they pass on (one step further).
      return jsonEncode(before?.toJson() ?? const <String, dynamic>{}) !=
          jsonEncode(got.toJson());
    });
    _changed();
    if (changed && host.isFriend(from)) {
      await shareAll();
    }
    return true;
  }
}
