import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
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

/// Most hidden people one person's flag carries (as salted hashes).
const int kOpenMaxHidden = 500;

/// Most friends' flags passed on in one frame.
const int kOpenMaxRelayed = 2000;

final RegExp _address = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');
final RegExp _hash = RegExp(r'^[0-9a-f]{32}$');

String _n(String a) => PeerShareCodec.normalizeAddress(a);

/// The salted hash of [address] in a person's "not for them" list: a
/// friend who passes the flag on checks the next person against it
/// without learning the list (the dating profile hides the same way).
String openHideHash(String salt, String address) => crypto.sha256
    .convert(utf8.encode('zen-graph-open-hide|$salt|${_n(address)}'))
    .toString()
    .substring(0, 32);

/// What one friend told this phone: their own flag (with the salted
/// hashes of the people it must not reach) and their friends' flags
/// they passed on.
@immutable
final class FriendOpenness {
  const FriendOpenness({
    this.own,
    this.salt = '',
    this.hide = const <String>{},
    this.relayed = const <String, OpenToMeet>{},
    this.noRelay = false,
  });

  final OpenToMeet? own;
  final String salt;
  final Set<String> hide;
  final Map<String, OpenToMeet> relayed;

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
      'r': <String, String>{
        for (final MapEntry<String, OpenToMeet> e in relayed.entries)
          e.key: e.value.code,
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
    final Map<String, OpenToMeet> relayed = <String, OpenToMeet>{};
    if (r is Map) {
      for (final MapEntry<dynamic, dynamic> e in r.entries) {
        if (relayed.length >= kOpenMaxRelayed) {
          break;
        }
        final Object? k = e.key;
        final OpenToMeet? o = OpenToMeet.byCode(e.value);
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
      hide: own == null || ex is! List
          ? const <String>{}
          : ex
                .whereType<String>()
                .where(_hash.hasMatch)
                .take(kOpenMaxHidden)
                .toSet(),
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

  /// Salt of this person's hidden list (new when the flag is first set).
  String salt = '';

  /// People the flag must not reach (the dating profile's "Ukryj przed"
  /// as it was when the flag was saved; the live list is added on top).
  final Set<String> hiddenFrom = <String>{};
  final Map<String, FriendOpenness> friends = <String, FriendOpenness>{};

  /// What each friend was last sent (short digest, when): unchanged is not
  /// sent again before [OpenToMeetService.resendAfter].
  final Map<String, (String, int)> sent = <String, (String, int)>{};

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    if (mine != null) 'my': mine!.code,
    if (salt.isNotEmpty) 'xs': salt,
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
    if (json is! Map || json['v'] != 1) {
      return book;
    }
    book
      ..mine = OpenToMeet.byCode(json['my'])
      ..salt = json['xs'] is String ? json['xs'] as String : '';
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
/// acquaintances), and each friend passes it on to their own friends who
/// see their friend list — so it reaches exactly the friends and friends
/// of friends who already see this person on their graph. Only the
/// intention travels; nothing of the dating profile itself.
final class OpenToMeetService extends ChangeNotifier {
  OpenToMeetService({
    required this.host,
    required this.disk,
    this.listVisibleTo,
    this.isWeak,
    this.hiddenFrom,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  /// The frame: `o` own flag, `xs`/`ex` salt and hashes of who it must
  /// not reach, `r` friends' flags passed on (address → code).
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

  final int Function() _now;
  final Random _random;

  OpenToMeetBook _book = OpenToMeetBook();
  Map<String, OpenToMeet> _relayed = const <String, OpenToMeet>{};
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

  /// This person's own flag (`null`: not shown on the graph).
  OpenToMeet? get mine => _book.mine;

  @visibleForTesting
  OpenToMeetBook get book => _book;

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
        _book = OpenToMeetBook.fromJson(jsonDecode(utf8.decode(raw)));
      }
    } on Object catch (error, stack) {
      logZenError('Graf: odczyt otwartych na poznanie', error, stack);
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
      logZenError('Graf: zapis otwartych na poznanie', error, stack);
    }
  }

  void _reindex() {
    final Map<String, OpenToMeet> index = <String, OpenToMeet>{};
    // Gone friends are dropped in [shareAll], once the friends are known.
    final List<String> order = _book.friends.keys.toList()..sort();
    for (final String f in order) {
      _book.friends[f]!.relayed.forEach((String a, OpenToMeet o) {
        index.putIfAbsent(a, () => o);
      });
    }
    _relayed = index;
  }

  /// What [address] is open to, as this phone knows it: a friend's own
  /// word, or for a friend of a friend what friends passed on. A friend
  /// who did not tell this phone shows nothing (they may hide it from this
  /// person, or keep them a weak acquaintance).
  OpenToMeet? openOf(String address) {
    final String a = _n(address);
    if (host.isFriend(a)) {
      return _book.friends[a]?.own;
    }
    return _relayed[a];
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
        if (_book.salt.isEmpty) {
          _book.salt = List<String>.generate(
            16,
            (_) => _random.nextInt(16).toRadixString(16),
          ).join();
        }
        _book.hiddenFrom.addAll(hiddenFrom.map(_n));
      }
      await _save();
    });
    _changed();
    await shareAll();
  }

  /// What goes to [friend] now.
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
        final List<String> hashes = <String>[
          for (final String a in notFor.take(kOpenMaxHidden))
            openHideHash(_book.salt, a),
        ]..sort();
        out
          ..['o'] = mine.code
          ..['xs'] = _book.salt
          ..['ex'] = hashes;
        if (notFor.length > kOpenMaxHidden) {
          // The list does not fit: the flag goes no further than this
          // friend.
          out['nr'] = true;
        }
      }
    }
    if (listVisibleTo?.call(f) ?? false) {
      final List<String> order = _book.friends.keys.toList()..sort();
      final Map<String, String> relay = <String, String>{};
      for (final String w in order) {
        final FriendOpenness o = _book.friends[w]!;
        if (relay.length >= kOpenMaxRelayed) {
          break;
        }
        if (w == f || o.own == null || !host.isFriend(w) || !o.reaches(f)) {
          continue;
        }
        relay[w] = o.own!.code;
      }
      if (relay.isNotEmpty) {
        out['r'] = relay;
      }
    }
    return out;
  }

  /// Sends each friend what changed for them (unchanged: once a day at
  /// most; someone told before who now gets nothing gets an empty frame,
  /// so they forget).
  Future<void> shareAll() async {
    await load();
    await _inTurn<void>(() async {
      final List<String> friends = host.friends().map(_n).toSet().toList()
        ..sort();
      bool changed = false;
      if (friends.isNotEmpty) {
        // Gone friends: what they said and what they were sent is dropped
        // (only once the friends are known: an empty list may be unread).
        final Set<String> known = friends.toSet();
        final int before = _book.friends.length + _book.sent.length;
        _book.friends.removeWhere((String a, _) => !known.contains(a));
        _book.sent.removeWhere((String a, _) => !known.contains(a));
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
          logZenWarning('Graf: wysłanie otwartych na poznanie do $f: $error');
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

  /// A friend's frame. Returns whether it was one of these.
  Future<bool> handle(SignalTransportFrame frame) async {
    if (frame.payload['type'] != frameType) {
      return false;
    }
    final String from = _n(frame.from);
    if (!host.isFriend(from) || host.isSelf(from)) {
      return true;
    }
    await load();
    final FriendOpenness got = FriendOpenness.fromJson(
      frame.payload,
      from: from,
      self: host.isSelf,
    );
    final bool ownChanged = await _inTurn<bool>(() async {
      final FriendOpenness? before = _book.friends[from];
      if (got.isEmpty) {
        _book.friends.remove(from);
      } else {
        _book.friends[from] = got;
      }
      _reindex();
      await _save();
      return before?.own != got.own ||
          (before?.salt ?? '') != got.salt ||
          (before?.noRelay ?? false) != got.noRelay ||
          !setEquals(before?.hide ?? const <String>{}, got.hide);
    });
    _changed();
    if (ownChanged) {
      // Their friends who see this person's list hear it from here.
      await shareAll();
    }
    return true;
  }
}
