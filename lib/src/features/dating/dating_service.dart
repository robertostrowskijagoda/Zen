import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/dating/dating_crypto.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart' show kSendOnceKey;
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class DatingTypes {
  /// A dating profile (or a cover one) flooding up to 3 steps.
  static const String package = 'date_pkg';

  /// A sealed message travelling back along the way a package came.
  static const String back = 'date_back';

  /// Between friends: "Co sądzisz o …?" and the answer.
  static const String ask = 'date_ask';
  static const String askAnswer = 'date_ask_re';

  /// Between friends: asking for a few words on one's profile, and them.
  static const String vouchRequest = 'date_vouch_req';
  static const String vouch = 'date_vouch';

  /// Between friends: "Idę na randkę" and "Wszystko OK".
  static const String safe = 'date_safe';
  static const String safeOk = 'date_safe_ok';

  static const Set<String> all = <String>{
    package,
    back,
    ask,
    askAnswer,
    vouchRequest,
    vouch,
    safe,
    safeOk,
  };
}

/// Re-encodes a photo from someone else, so odd bytes never reach the image
/// decoder; `null` for anything that is not a small picture.
String? cleanDatingPhoto(String? photo) {
  if (photo == null) {
    return null;
  }
  try {
    final Uint8List? clean = sanitizeIncomingAvatar(base64Decode(photo));
    return clean == null ? null : base64Encode(clean);
  } on Object {
    return null;
  }
}

/// How often a phone sends its package (a real profile, or a cover one when
/// dating is off, so nobody can tell the difference).
const Duration kDatingPublishEvery = Duration(days: 7);

/// A profile not refreshed for this long disappears.
const Duration kDatingProfileLife = Duration(days: 16);

/// Routes and seen packages are kept this long.
const Duration kDatingRouteLife = Duration(days: 30);

/// Steps a package travels (always the same, real or cover).
const int kDatingHops = 3;

/// Flood guard on the receiving side: new packages taken in from one
/// friend a day (their own and the ones they pass on). Every phone sends
/// one a week (and again when its profile changes), so this covers a
/// friend whose three steps of friends are several hundred phones; a
/// broken or modified app cannot make the whole network pass on more.
const int kDatingPackagesPerFriendPerDay = 100;

/// Largest sealed message travelling back (an introduction carries a whole
/// profile with its photos).
const int _maxBoxChars = 800 * 1024;

/// Steps a message travelling back may still make, at most.
const int _maxBackTtl = 8;

/// "Randki przez znajomych" (§19).
///
/// * Every phone has a dating key and sends a package every week, also with
///   dating off (then a cover package), and passes on its friends'
///   packages up to 3 steps. From the outside, and to the friends passing
///   them on, everybody looks the same.
/// * A phone with dating off never opens or keeps the packages it passes
///   on.
/// * Likes, messages and introductions go back the way packages came,
///   sealed with dating keys (§19.2–19.3): the phones in between cannot read
///   them or tell who wrote them.
/// * "Tak" sends a token both sides can compute only with their keys; "Nie"
///   sends nothing — so a "Nie" looks exactly like no decision at all.
/// * Packages are sealed (see [DatingPackageSeal]): the phones passing them
///   on cannot read them; the key is handed out on request.
/// * Vouches are signed by the friend who wrote them ([DatingVouch]).
final class DatingService extends ChangeNotifier {
  DatingService({
    required this.host,
    required this.disk,
    this.groupMembers,
    this.raiseAlarm,
    this.isBanned,
    this.isHiddenByMe,
    this.pyramidKey,
    this.canPay,
    this.pay,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// Members of a chat group (for hiding from whole groups).
  final List<String> Function(String groupId)? groupMembers;

  /// Raises this person's alarm (§16.3) when they do not confirm after a date.
  final Future<void> Function(String note)? raiseAlarm;

  /// Dating keys switched off by the pyramid (e.g. a minor, §19.1, §21.4).
  final bool Function(String datingKey)? isBanned;

  /// Dating keys this person hid after reporting them (§21.4): left out of
  /// the lists until they choose to see them anyway ([hiddenProfiles]).
  final bool Function(String datingKey)? isHiddenByMe;

  /// This person's pyramid key, when they are a member (sent along with an
  /// introduction, so the pair can thank the matchmaker).
  final String? Function()? pyramidKey;

  /// Whether this person can pay pyramid member [pyramidKey] (both are
  /// members of the same pyramid).
  final bool Function(String pyramidKey)? canPay;

  /// Pays [amount] to pyramid member [pyramidKey]; true when the order went
  /// out.
  final Future<bool> Function(String pyramidKey, int amount, String memo)? pay;
  final int Function() _now;
  final Random _random;
  static const String _key = 'dating/state';

  /// A sealed package waits this long for its key.
  static const Duration _pendingLife = Duration(days: 3);

  /// Sealed packages kept waiting for a key, at most.
  static const int _pendingMax = 200;

  RelayIdentity? _identity;

  /// The key this phone signs vouches with (Ed25519; separate from the
  /// dating key, so a vouch does not tell anyone the voucher's dating key).
  LedgerKeyPair? _signer;
  MyDating me = MyDating();
  int _publishedAt = 0;
  bool _dirty = true;

  final Map<String, int> _seen = <String, int>{};

  /// id → (next hop, id to use there, when).
  final Map<String, (String, String, int)> _routes =
      <String, (String, String, int)>{};

  /// Ids that end here: own package ids and marks.
  final Map<String, int> _own = <String, int>{};

  /// The mark others use to answer us, per dating key.
  final Map<String, String> _marks = <String, String>{};
  final Map<String, SeenProfile> _profiles = <String, SeenProfile>{};
  final Map<String, bool> _decisions = <String, bool>{};
  final Map<String, String> _likesIn = <String, String>{};
  final Map<String, int> _matches = <String, int>{};
  final Map<String, List<DatingLine>> _chats = <String, List<DatingLine>>{};
  final Set<String> _blocked = <String>{};
  final Map<String, OpinionAsk> _asks = <String, OpinionAsk>{};

  /// Friends asking for a few words (id → friend address).
  final Map<String, String> vouchRequests = <String, String>{};

  /// The dating key of the profile a request is for (id → key), so the
  /// words can be signed for that profile.
  final Map<String, String> _vouchFor = <String, String>{};

  /// Keys of this phone's own packages (package id → key, base64url).
  final Map<String, String> _pkgKeys = <String, String>{};

  /// Sealed packages waiting for their key (only with dating on).
  final Map<String, Map<String, dynamic>> _pending =
      <String, Map<String, dynamic>>{};

  /// Friends' own dating keys (address → key), learnt from the packages
  /// they send themselves: a friend this person hides from gets no key for
  /// this phone's packages (see [_onKeyRequest]).
  final Map<String, String> _friendKeys = <String, String>{};

  /// New packages taken in per friend (when), for the flood guard.
  final Map<String, List<int>> _packagesFrom = <String, List<int>>{};

  /// Sends made while a frame is handled; they go out once the handling is
  /// over, so two phones answering each other never wait on each other.
  List<(String, Map<String, dynamic>)>? _outbox;
  final Map<String, SafeDate> _safe = <String, SafeDate>{};
  Future<void> _queue = Future<void>.value();

  int get now => _now();
  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String _newId([int length = 14]) => List<String>.generate(
    length,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  String? get myKey =>
      _identity == null ? null : base64Url.encode(_identity!.publicKey);

  /// The key vouches written here are signed with.
  String? get vouchKey => _signer?.id;

  bool get active => me.enabled && me.complete;

  // ---- reading ----

  /// Profiles to decide on (no decision yet), newest first.
  List<SeenProfile> get toDecide => _visible()
      .where((SeenProfile s) => !_decisions.containsKey(s.profile.key))
      .toList();

  /// Profiles already liked, waiting for the other side.
  List<SeenProfile> get liked => _visible()
      .where(
        (SeenProfile s) =>
            _decisions[s.profile.key] == true && !isMatch(s.profile.key),
      )
      .toList();

  List<SeenProfile> get matches =>
      <SeenProfile>[
        for (final String k in _matches.keys)
          if (_profiles[k] != null && !_hiddenByMe(k)) _profiles[k]!,
      ]..sort(
        (SeenProfile a, SeenProfile b) => (_matches[b.profile.key] ?? 0)
            .compareTo(_matches[a.profile.key] ?? 0),
      );

  bool _hiddenByMe(String key) => isHiddenByMe?.call(key) ?? false;

  Iterable<SeenProfile> _visible() {
    final int t = _now();
    return (_profiles.values
        .where(
          (SeenProfile s) =>
              !_blocked.contains(s.profile.key) &&
              !(isBanned?.call(s.profile.key) ?? false) &&
              !_hiddenByMe(s.profile.key) &&
              t - s.at < kDatingProfileLife.inMilliseconds,
        )
        .toList()
      ..sort((SeenProfile a, SeenProfile b) => b.at.compareTo(a.at)));
  }

  /// Profiles this person hid after reporting them and has not blocked:
  /// each can be shown anyway.
  List<SeenProfile> get hiddenProfiles => <SeenProfile>[
    for (final SeenProfile s in _profiles.values)
      if (_hiddenByMe(s.profile.key) &&
          !_blocked.contains(s.profile.key) &&
          !(isBanned?.call(s.profile.key) ?? false))
        s,
  ]..sort((SeenProfile a, SeenProfile b) => b.at.compareTo(a.at));

  SeenProfile? profile(String key) => _profiles[key];
  bool isMatch(String key) => _matches.containsKey(key);
  bool? decision(String key) => _decisions[key];

  List<DatingLine> chat(String key) =>
      List<DatingLine>.unmodifiable(_chats[key] ?? const <DatingLine>[]);

  List<OpinionAsk> get asksToMe =>
      _asks.values.where((OpinionAsk a) => !a.mine).toList()
        ..sort((OpinionAsk a, OpinionAsk b) => b.at.compareTo(a.at));

  List<OpinionAsk> get myAsks =>
      _asks.values.where((OpinionAsk a) => a.mine).toList()
        ..sort((OpinionAsk a, OpinionAsk b) => b.at.compareTo(a.at));

  /// Dates I watch for friends, and my own.
  List<SafeDate> get safeDates =>
      _safe.values.where((SafeDate s) => !s.isOver).toList()
        ..sort((SafeDate a, SafeDate b) => a.until.compareTo(b.until));

  SafeDate? get mySafeDate {
    for (final SafeDate s in _safe.values) {
      if (s.mine && !s.isOver) {
        return s;
      }
    }
    return null;
  }

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      _diskUnreadable = false;
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        _fromJson(json);
        final Uint8List? seed = decodeRelayKey(json['vs']);
        if (seed != null && _signer == null) {
          _signer = await LedgerKeyPair.fromSeed(seed);
        }
      }
      final bool fresh = _identity == null || _signer == null;
      _identity ??= await RelayIdentity.generate();
      _signer ??= await LedgerKeyPair.generate();
      if (raw == null || fresh) {
        await _save();
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt randek', error, stack);
    }
  }

  void _fromJson(Map<dynamic, dynamic> json) {
    _identity = RelayIdentity.fromJson(json['id']) ?? _identity;
    me = MyDating.fromJson(json['me']);
    _publishedAt = json['pub'] is int ? json['pub'] as int : 0;
    _dirty = json['dirty'] != false;
    _seen
      ..clear()
      ..addAll(_ints(json['seen']));
    _own
      ..clear()
      ..addAll(_ints(json['own']));
    _routes.clear();
    final Object? routes = json['routes'];
    if (routes is Map) {
      routes.forEach((Object? k, Object? v) {
        if (k is String &&
            v is List &&
            v.length == 3 &&
            v[0] is String &&
            v[1] is String &&
            v[2] is int) {
          _routes[k] = (v[0] as String, v[1] as String, v[2] as int);
        }
      });
    }
    _marks
      ..clear()
      ..addAll(_strings(json['marks']));
    _profiles.clear();
    final Object? profiles = json['profiles'];
    if (profiles is List) {
      for (final Object? p in profiles) {
        final SeenProfile? s = SeenProfile.fromJson(p);
        if (s != null) {
          _profiles[s.profile.key] = s;
        }
      }
    }
    _decisions.clear();
    final Object? dec = json['dec'];
    if (dec is Map) {
      dec.forEach((Object? k, Object? v) {
        if (k is String && v is bool) {
          _decisions[k] = v;
        }
      });
    }
    _likesIn
      ..clear()
      ..addAll(_strings(json['likes']));
    _matches
      ..clear()
      ..addAll(_ints(json['matches']));
    _chats.clear();
    final Object? chats = json['chats'];
    if (chats is Map) {
      chats.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _chats[k] = <DatingLine>[
            for (final Object? l in v)
              if (DatingLine.fromJson(l) != null) DatingLine.fromJson(l)!,
          ];
        }
      });
    }
    _blocked
      ..clear()
      ..addAll(
        json['blocked'] is List
            ? (json['blocked'] as List).whereType<String>()
            : const <String>[],
      );
    _asks.clear();
    final Object? asks = json['asks'];
    if (asks is List) {
      for (final Object? a in asks) {
        final OpinionAsk? ask = OpinionAsk.fromJson(a);
        if (ask != null) {
          _asks[ask.id] = ask;
        }
      }
    }
    vouchRequests
      ..clear()
      ..addAll(_strings(json['vreq']));
    _vouchFor
      ..clear()
      ..addAll(_strings(json['vfor']));
    _pkgKeys
      ..clear()
      ..addAll(_strings(json['pkeys']));
    _friendKeys
      ..clear()
      ..addAll(_strings(json['fkeys']));
    _pending.clear();
    final Object? pending = json['pend'];
    if (pending is Map) {
      pending.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          _pending[k] = Map<String, dynamic>.from(v);
        }
      });
    }
    _safe.clear();
    final Object? safe = json['safe'];
    if (safe is List) {
      for (final Object? s in safe) {
        final SafeDate? d = SafeDate.fromJson(s);
        if (d != null) {
          _safe[d.id] = d;
        }
      }
    }
  }

  static Map<String, int> _ints(Object? json) => <String, int>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
  };

  static Map<String, String> _strings(Object? json) => <String, String>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
  };

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    final int t = _now();
    final int life = kDatingRouteLife.inMilliseconds;
    _seen.removeWhere((String _, int at) => t - at > life);
    _routes.removeWhere((String _, (String, String, int) r) => t - r.$3 > life);
    _own.removeWhere(
      (String id, int at) => t - at > life && !_marks.containsValue(id),
    );
    _profiles.removeWhere(
      (String k, SeenProfile s) =>
          t - s.at > kDatingProfileLife.inMilliseconds * 2 &&
          !_matches.containsKey(k),
    );
    _safe.removeWhere(
      (String _, SafeDate s) => s.isOver && t - s.okAt! > 2 * 24 * 3600 * 1000,
    );
    _pkgKeys.removeWhere((String id, String _) => !_own.containsKey(id));
    _pending.removeWhere(
      (String _, Map<String, dynamic> p) =>
          p['at'] is! int || t - (p['at'] as int) > _pendingLife.inMilliseconds,
    );
    _vouchFor.removeWhere(
      (String id, String _) => !vouchRequests.containsKey(id),
    );
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          if (_identity != null) 'id': _identity!.toJson(),
          if (_signer != null) 'vs': base64Url.encode(_signer!.seed),
          'me': me.toJson(),
          'pub': _publishedAt,
          'dirty': _dirty,
          'seen': _seen,
          'own': _own,
          'routes': <String, dynamic>{
            for (final MapEntry<String, (String, String, int)> e
                in _routes.entries)
              e.key: <Object>[e.value.$1, e.value.$2, e.value.$3],
          },
          'marks': _marks,
          'profiles': <Map<String, dynamic>>[
            for (final SeenProfile s in _profiles.values) s.toJson(),
          ],
          'dec': _decisions,
          'likes': _likesIn,
          'matches': _matches,
          'chats': <String, dynamic>{
            for (final MapEntry<String, List<DatingLine>> e in _chats.entries)
              e.key: <Map<String, dynamic>>[
                for (final DatingLine l
                    in e.value.length > 500
                        ? e.value.sublist(e.value.length - 500)
                        : e.value)
                  l.toJson(),
              ],
          },
          'blocked': _blocked.toList(),
          'asks': <Map<String, dynamic>>[
            for (final OpinionAsk a in _asks.values) a.toJson(),
          ],
          'vreq': vouchRequests,
          'vfor': _vouchFor,
          'pkeys': _pkgKeys,
          if (_friendKeys.isNotEmpty) 'fkeys': _friendKeys,
          'pend': _pending,
          'safe': <Map<String, dynamic>>[
            for (final SafeDate s in _safe.values) s.toJson(),
          ],
        }),
      ),
    );
    notifyListeners();
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    final List<(String, Map<String, dynamic>)>? outbox = _outbox;
    if (outbox != null) {
      outbox.add((to, payload));
      return;
    }
    await _deliver(to, payload);
  }

  Future<void> _deliver(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Randki: ${payload['type']} do $to: $error');
    }
  }

  // ---- own profile ----

  /// Saves the profile and settings; the next package carries them.
  Future<void> saveMine(void Function(MyDating me) change) async {
    change(me);
    _dirty = true;
    await _save();
    await maybePublish();
  }

  String _hiddenHash(String salt, String address) => crypto.sha256
      .convert(utf8.encode('zen-date-hide|$salt|${_n(address)}'))
      .toString()
      .substring(0, 32);

  DatingProfile? _myProfile(String salt) {
    final String? key = myKey;
    if (key == null || !active) {
      return null;
    }
    // Hidden friends first, then members of hidden groups: phones read
    // [kDatingMaxHidden] of them (and the package stays a sane size).
    final Set<String> hidden = <String>{
      ...me.hiddenFriends.map(_n),
      for (final String g in me.hiddenGroups) ...?groupMembers?.call(g).map(_n),
    };
    return DatingProfile(
      key: key,
      name: me.name.trim(),
      age: me.age,
      gender: me.gender,
      about: me.about.trim(),
      lookingFor: me.lookingFor.trim(),
      wants: me.wants,
      photos: List<String>.of(me.photos.take(kDatingMaxPhotos)),
      salt: salt,
      hidden: <String>[
        for (final String a in hidden.take(kDatingMaxHidden))
          _hiddenHash(salt, a),
      ],
      vouches: me.vouches.where((DatingVouch v) => v.approved).toList(),
      at: _now(),
    );
  }

  /// Sends this phone's package when it is time (or the profile changed).
  Future<void> maybePublish({bool force = false}) async {
    final int t = _now();
    if (_identity == null) {
      return;
    }
    final bool due = t - _publishedAt >= kDatingPublishEvery.inMilliseconds;
    if (!force && !due && !(_dirty && active)) {
      return;
    }
    final String salt = _newId(12);
    final DatingProfile? mine = _myProfile(salt);
    final String id = _newId(16);
    // Sealed for the phones on the way; a cover is padded to the size of a
    // profile with one to four photos (see DatingPackageSeal).
    final (Uint8List, Map<String, dynamic>) sealed =
        await DatingPackageSeal.seal(
          sender: myKey!,
          packageId: id,
          content:
              mine?.toJson() ?? const <String, dynamic>{'v': 1, 'cover': true},
          minBuckets: mine == null ? 2 + _random.nextInt(11) : 2,
        );
    final Map<String, dynamic> p = sealed.$2;
    _pkgKeys[id] = base64Url.encode(sealed.$1);
    _own[id] = t;
    _seen[id] = t;
    _publishedAt = t;
    _dirty = false;
    await _save();
    final Set<String> hiddenFriends = <String>{
      ...me.hiddenFriends.map(_n),
      for (final String g in me.hiddenGroups) ...?groupMembers?.call(g).map(_n),
    };
    for (final String f in host.friends()) {
      // Hidden people do not even get it directly.
      if (mine != null && hiddenFriends.contains(_n(f))) {
        continue;
      }
      await _send(f, <String, dynamic>{
        'type': DatingTypes.package,
        'id': id,
        'hops': kDatingHops - 1,
        'path': const <String>[],
        'p': p,
      });
    }
  }

  // ---- deciding ----

  String _markFor(String key) {
    final String? m = _marks[key];
    if (m != null) {
      return m;
    }
    final String id = _newId(16);
    _marks[key] = id;
    _own[id] = _now();
    return id;
  }

  /// Sends [payload] sealed to [key]'s dating key, back along the way.
  Future<bool> _sendBack(String key, Map<String, dynamic> payload) async {
    final SeenProfile? s = _profiles[key];
    final RelayIdentity? id = _identity;
    final Uint8List? them = decodeRelayKey(key);
    if (s == null || id == null || them == null) {
      return false;
    }
    final Map<String, String> box = await DatingBox.seal(
      me: id,
      recipient: them,
      payload: payload,
    );
    final String mark = _markFor(key);
    await _save();
    return _route(s.replyTo, mark, box, from: null);
  }

  /// Passes a back message one step on (or delivers it here).
  Future<bool> _route(
    String to,
    String? mark,
    Map<String, dynamic> box, {
    required String? from,
    int ttl = 8,
  }) async {
    final (String, String, int)? r = _routes[to];
    if (r == null || ttl <= 0) {
      return false;
    }
    if (mark != null && from != null) {
      _routes[mark] = (from, mark, _now());
    }
    await _send(r.$1, <String, dynamic>{
      'type': DatingTypes.back,
      'to': r.$2,
      'm': ?mark,
      'box': box,
      'ttl': ttl - 1,
    });
    return true;
  }

  /// "Tak" or "Nie" (§19.2). Only "Tak" sends anything.
  Future<void> decide(String key, bool yes) async {
    if (!_profiles.containsKey(key) || _identity == null) {
      return;
    }
    _decisions[key] = yes;
    await _save();
    if (!yes) {
      return;
    }
    final Uint8List? them = decodeRelayKey(key);
    if (them == null) {
      return;
    }
    final String token = await datingLikeToken(_identity!, them);
    await _sendBack(key, <String, dynamic>{'k': 'like', 'tok': token});
    await _checkMatch(key);
  }

  Future<void> _checkMatch(String key) async {
    final String? got = _likesIn[key];
    final Uint8List? them = decodeRelayKey(key);
    if (got == null ||
        them == null ||
        _decisions[key] != true ||
        _matches.containsKey(key)) {
      return;
    }
    if (got != await datingLikeToken(_identity!, them)) {
      return;
    }
    _matches[key] = _now();
    await _save();
    final SeenProfile? s = _profiles[key];
    await host.notify(
      RuntimeSystemNotification(
        id: 'date-match-${key.hashCode}',
        title: t('Para! ❤️'),
        body: t('{name} też powiedział(a) „Tak”. Napiszcie do siebie.', {
          'name': s?.profile.name ?? t('Ktoś'),
        }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'date-match',
      ),
    );
  }

  Future<bool> sendMessage(String key, String text) async {
    if (!_matches.containsKey(key) || text.trim().isEmpty) {
      return false;
    }
    final String t = text.trim().length > 2000
        ? text.trim().substring(0, 2000)
        : text.trim();
    final DatingLine line = DatingLine(
      id: _newId(),
      mine: true,
      text: t,
      at: _now(),
    );
    (_chats[key] ??= <DatingLine>[]).add(line);
    await _save();
    return _sendBack(key, <String, dynamic>{'k': 'msg', 'id': line.id, 't': t});
  }

  Future<void> block(String key) async {
    _blocked.add(key);
    _matches.remove(key);
    _chats.remove(key);
    await _save();
  }

  /// Removes the profile [key] from this phone ("Usuń z mojego urządzenia"
  /// after a report, §21.4): its photos and text, the chat, the match and
  /// what was decided about it. It is blocked as well, so a copy that
  /// reaches this phone later is dropped.
  Future<void> forget(String key) async {
    _blocked.add(key);
    _profiles.remove(key);
    _decisions.remove(key);
    _likesIn.remove(key);
    _matches.remove(key);
    _chats.remove(key);
    await _save();
  }

  /// Introduces [a] and [b] to each other (§19.3, "swatanie").
  Future<bool> introduce(String a, String b, String note) async {
    final SeenProfile? sa = _profiles[a];
    final SeenProfile? sb = _profiles[b];
    if (sa == null || sb == null || a == b || !active) {
      return false;
    }
    final (String, String, int)? ra = _routes[sa.replyTo];
    final (String, String, int)? rb = _routes[sb.replyTo];
    if (ra == null || rb == null) {
      return false;
    }
    // Marks that lead through this phone to the other one.
    final String toB = _newId(16);
    final String toA = _newId(16);
    _routes[toB] = (rb.$1, rb.$2, _now());
    _routes[toA] = (ra.$1, ra.$2, _now());
    await _save();
    final String by = host.ownName();
    final String n = note.trim().length > 300
        ? note.trim().substring(0, 300)
        : note.trim();
    // So the pair can thank the matchmaker with currency (§19.3).
    final String? pyr = pyramidKey?.call();
    final bool okA = await _sealAndRoute(a, sa.replyTo, toB, <String, dynamic>{
      'k': 'intro',
      'by': by,
      'note': n,
      'p': sb.profile.toJson(),
      'via': toB,
      'pk': ?pyr,
    });
    final bool okB = await _sealAndRoute(b, sb.replyTo, toA, <String, dynamic>{
      'k': 'intro',
      'by': by,
      'note': n,
      'p': sa.profile.toJson(),
      'via': toA,
      'pk': ?pyr,
    });
    return okA && okB;
  }

  Future<bool> _sealAndRoute(
    String key,
    String to,
    String mark,
    Map<String, dynamic> payload,
  ) async {
    final Uint8List? them = decodeRelayKey(key);
    if (them == null || _identity == null) {
      return false;
    }
    final Map<String, String> box = await DatingBox.seal(
      me: _identity!,
      recipient: them,
      payload: payload,
    );
    // The mark is set up here already; the hops record it on the way.
    final (String, String, int)? r = _routes[to];
    if (r == null) {
      return false;
    }
    await _send(r.$1, <String, dynamic>{
      'type': DatingTypes.back,
      'to': r.$2,
      'm': mark,
      'box': box,
      'ttl': 7,
    });
    return true;
  }

  // ---- friends: opinions and vouches ----

  /// "Co sądzisz o …?" to the friend who passed the profile on.
  Future<bool> askOpinion(String key, String question) async {
    final SeenProfile? s = _profiles[key];
    final String? friend = s?.friend;
    if (s == null || friend == null || question.trim().isEmpty) {
      return false;
    }
    final OpinionAsk a = OpinionAsk(
      id: _newId(),
      friend: friend,
      name: s.profile.name,
      question: question.trim(),
      at: _now(),
      mine: true,
      photo: s.profile.photo,
    );
    _asks[a.id] = a;
    await _save();
    await _send(friend, <String, dynamic>{
      'type': DatingTypes.ask,
      'id': a.id,
      'n': a.name,
      'q': a.question,
      if (a.photo != null && a.photo!.length < 40 * 1024) 'ph': a.photo,
    });
    return true;
  }

  Future<void> answerOpinion(String id, String text) async {
    final OpinionAsk? a = _asks[id];
    if (a == null || a.mine || text.trim().isEmpty) {
      return;
    }
    a.answer = text.trim();
    await _save();
    await _send(a.friend, <String, dynamic>{
      'type': DatingTypes.askAnswer,
      'id': id,
      't': a.answer,
    });
  }

  /// Asks a friend for a few words on the dating profile. The request
  /// names the profile's dating key, so the friend signs the words for it.
  Future<void> requestVouch(String friend) async {
    final String? key = myKey;
    if (key == null) {
      return;
    }
    await _send(friend, <String, dynamic>{
      'type': DatingTypes.vouchRequest,
      'id': _newId(),
      'k': key,
    });
  }

  Future<void> writeVouch(String requestId, String text) async {
    final String? friend = vouchRequests.remove(requestId);
    final String? forKey = _vouchFor.remove(requestId);
    if (friend == null || text.trim().isEmpty) {
      return;
    }
    await _save();
    final String t = text.trim().length > 300
        ? text.trim().substring(0, 300)
        : text.trim();
    final LedgerKeyPair? signer = _signer;
    if (signer == null || forKey == null) {
      return;
    }
    // Signed for the profile it is about.
    final String by = host.ownName();
    final DatingVouch signed = await DatingVouch.sign(
      signer: signer,
      id: requestId,
      forKey: forKey,
      by: by.length > 60 ? by.substring(0, 60) : by,
      text: t,
      at: _now(),
    );
    await _send(friend, <String, dynamic>{
      'type': DatingTypes.vouch,
      'id': requestId,
      't': t,
      'by': signed.by,
      'vk': signed.signer,
      'sig': signed.sig,
      'at': signed.at,
    });
  }

  Future<void> dismissVouchRequest(String requestId) async {
    vouchRequests.remove(requestId);
    _vouchFor.remove(requestId);
    await _save();
  }

  Future<void> setVouch(String id, {required bool keep}) =>
      saveMine((MyDating m) {
        final int i = m.vouches.indexWhere((DatingVouch v) => v.id == id);
        if (i < 0) {
          return;
        }
        if (keep) {
          m.vouches[i] = m.vouches[i].approve();
        } else {
          m.vouches.removeAt(i);
        }
      });

  /// Everyone the dating profile is hidden from (friends and members of
  /// hidden groups), as normalized addresses — e.g. so the „Randkuję”
  /// status (§16.2) does not reach them either.
  Set<String> hiddenAddresses() => <String>{
    ...me.hiddenFriends.map(_n),
    for (final String g in me.hiddenGroups) ...?groupMembers?.call(g).map(_n),
  };

  /// Whether [datingKey] is the (known) dating key of someone this person
  /// hides from.
  bool _hiddenKey(String datingKey) {
    if (!_friendKeys.containsValue(datingKey)) {
      return false;
    }
    final Set<String> hidden = hiddenAddresses();
    return hidden.any((String a) => _friendKeys[a] == datingKey);
  }

  // ---- thanking the matchmaker (§19.3) ----

  /// Whether "Podziękuj swatowi" makes sense for the match [key]: it came
  /// from an introduction by a pyramid member this person can pay.
  bool canThank(String key) {
    final SeenProfile? s = _profiles[key];
    final String? pyr = s?.introPyr;
    return s != null &&
        isMatch(key) &&
        s.introBy != null &&
        pyr != null &&
        pay != null &&
        (canPay?.call(pyr) ?? false);
  }

  /// Already thanked the matchmaker of [key].
  bool thanked(String key) => _profiles[key]?.thankedAt != null;

  /// Pays the matchmaker of the match [key] [amount] in the pyramid's
  /// currency.
  Future<bool> thankMatchmaker(String key, int amount) async {
    final SeenProfile? s = _profiles[key];
    final Future<bool> Function(String, int, String)? payNow = pay;
    if (s == null || amount <= 0 || payNow == null || !canThank(key)) {
      return false;
    }
    // The memo stays neutral: the pyramid's treasurers see transfers, and
    // must not learn that anyone dates.
    final bool ok = await payNow(s.introPyr!, amount, t('Podziękowanie'));
    if (ok) {
      s.thankedAt = _now();
      await _save();
    }
    return ok;
  }

  // ---- "Idę na randkę" ----

  Future<SafeDate?> startSafeDate({
    required String friend,
    required Duration length,
    String note = '',
    double? lat,
    double? lon,
  }) async {
    if (mySafeDate != null) {
      return mySafeDate;
    }
    final SafeDate d = SafeDate(
      id: _newId(),
      friend: _n(friend),
      until: _now() + length.inMilliseconds,
      mine: true,
      note: note.trim(),
      lat: lat,
      lon: lon,
      locatedAt: lat == null ? null : _now(),
    );
    _safe[d.id] = d;
    await _save();
    await _sendSafe(d);
    return d;
  }

  Future<void> _sendSafe(SafeDate d) => _send(d.friend, <String, dynamic>{
    'type': DatingTypes.safe,
    'id': d.id,
    'until': d.until,
    'note': d.note,
    if (d.lat != null) 'lat': d.lat,
    if (d.lon != null) 'lon': d.lon,
  });

  Future<void> updateSafeLocation(double lat, double lon) async {
    final SafeDate? d = mySafeDate;
    if (d == null) {
      return;
    }
    d
      ..lat = lat
      ..lon = lon
      ..locatedAt = _now();
    await _save();
    await _sendSafe(d);
  }

  Future<void> extendSafeDate(Duration more) async {
    final SafeDate? d = mySafeDate;
    if (d == null) {
      return;
    }
    d
      ..until = max(d.until, _now()) + more.inMilliseconds
      ..remindedAt = null;
    await _save();
    await _sendSafe(d);
  }

  /// "Wszystko OK".
  Future<void> safeOk() async {
    final SafeDate? d = mySafeDate;
    if (d == null) {
      return;
    }
    d.okAt = _now();
    await _save();
    await _send(d.friend, <String, dynamic>{
      'type': DatingTypes.safeOk,
      'id': d.id,
    });
  }

  bool _due(int t) => _safe.values.any(
    (SafeDate d) =>
        !d.isOver &&
        t >= d.until &&
        (d.remindedAt == null ||
            (d.alarmedAt == null &&
                t >= d.until + SafeDate.grace.inMilliseconds)),
  );

  /// Checks the deadlines (call every minute and on start). Runs in turn
  /// with incoming frames.
  Future<void> tick() {
    final Completer<void> done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _tick();
      } on Object catch (error, stack) {
        logZenError('Randki: terminy', error, stack);
      }
      done.complete();
    });
    return done.future;
  }

  /// For the Android background service (§19.4): reads the state the app
  /// left and checks the deadlines, so the reminder and the alarm come on
  /// time while the app is closed.
  Future<void> backgroundTick() async {
    await load();
    await tick();
  }

  Future<void> _tick() async {
    if (_due(_now()) && !_diskUnreadable) {
      // The app and the background service both check the deadlines: read
      // what the other one may have done already, so nothing fires twice.
      try {
        final List<int>? raw = await disk.read(_key);
        final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
        if (json is Map) {
          _fromJson(json);
        }
      } on Object catch (error, stack) {
        logZenError('Randki: odczyt terminów', error, stack);
      }
    }
    final int now = _now();
    final List<SafeDate> remind = <SafeDate>[];
    final List<SafeDate> alarm = <SafeDate>[];
    for (final SafeDate d in _safe.values) {
      if (d.isOver || now < d.until) {
        continue;
      }
      if (d.remindedAt == null) {
        d.remindedAt = now;
        remind.add(d);
      }
      // Only a phone that can raise this person's alarm marks it raised.
      if (d.alarmedAt == null &&
          now >= d.until + SafeDate.grace.inMilliseconds &&
          (!d.mine || raiseAlarm != null)) {
        d.alarmedAt = now;
        alarm.add(d);
      }
    }
    if (remind.isEmpty && alarm.isEmpty) {
      return;
    }
    // Written down first, so the other side (app or background service)
    // sees it done before the slow part (the alarm takes a position fix).
    await _save();
    for (final SafeDate d in remind) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'date-safe-rem-${d.id}',
          title: d.mine
              ? t('Wszystko OK?')
              : t('{name} miał(a) dać znać', {'name': host.nameOf(d.friend)}),
          body: d.mine
              ? t(
                  'Potwierdź w aplikacji, że wszystko w porządku — inaczej '
                  'za 15 minut przyjaciel dostanie alarm.',
                )
              : t(
                  'Jeszcze nie potwierdził(a), że wszystko OK. Jeśli to się '
                  'nie zmieni, za 15 minut dostaniesz alarm.',
                ),
          createdAtMillis: now,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'date-safe:${d.id}',
        ),
      );
    }
    for (final SafeDate d in alarm) {
      if (d.mine) {
        await raiseAlarm?.call(
          t('Nie potwierdziłem(-am), że po randce wszystko OK.'),
        );
      } else {
        await host.notify(
          RuntimeSystemNotification(
            id: 'date-safe-alarm-${d.id}',
            title: t('⚠️ {name} nie potwierdził(a), że wszystko OK', {
              'name': host.nameOf(d.friend),
            }),
            body: d.note.isEmpty
                ? t('Zadzwoń albo sprawdź, co się dzieje.')
                : t('Randka: {note}. Zadzwoń albo sprawdź.', {'note': d.note}),
            createdAtMillis: now,
            category: RuntimeSystemNotificationCategory.alarm,
            slotKey: 'date-safe:${d.id}',
            isRingingCall: true,
          ),
        );
      }
    }
  }

  // ---- receiving ----

  Future<bool> handle(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (type is! String || !DatingTypes.all.contains(type)) {
      return Future<bool>.value(false);
    }
    final Completer<List<(String, Map<String, dynamic>)>> handled =
        Completer<List<(String, Map<String, dynamic>)>>();
    _queue = _queue.then((_) async {
      final List<(String, Map<String, dynamic>)> outbox =
          <(String, Map<String, dynamic>)>[];
      _outbox = outbox;
      try {
        final String from = _n(frame.from);
        if (host.isFriend(from)) {
          await _handle(type, from, frame.payload);
        }
      } on Object catch (error, stack) {
        logZenError('Randki', error, stack);
      } finally {
        _outbox = null;
      }
      handled.complete(outbox);
    });
    return handled.future.then((
      List<(String, Map<String, dynamic>)> outbox,
    ) async {
      // Sent after the handling, outside the queue.
      for (final (String, Map<String, dynamic>) m in outbox) {
        await _deliver(m.$1, m.$2);
      }
      return true;
    });
  }

  Future<void> _handle(String type, String from, Map<String, dynamic> p) async {
    switch (type) {
      case DatingTypes.package:
        await _onPackage(from, p);
      case DatingTypes.back:
        await _onBack(from, p);
      case DatingTypes.ask:
        await _onAsk(from, p);
      case DatingTypes.askAnswer:
        final Object? id = p['id'];
        final Object? text = p['t'];
        final OpinionAsk? a = id is String ? _asks[id] : null;
        if (a != null && a.mine && a.friend == from && text is String) {
          a.answer = text.length > 2000 ? text.substring(0, 2000) : text;
          await _save();
          await host.notify(
            RuntimeSystemNotification(
              id: 'date-opinion-$id',
              title: t('{name} o {about}', {
                'name': host.nameOf(from),
                'about': a.name,
              }),
              body: a.answer!,
              createdAtMillis: _now(),
              category: RuntimeSystemNotificationCategory.social,
              slotKey: 'date-opinion',
            ),
          );
        }
      case DatingTypes.vouchRequest:
        final Object? id = p['id'];
        final Object? forKey = p['k'];
        // The request names the profile the words are signed for.
        if (id is String &&
            id.length <= 40 &&
            forKey is String &&
            decodeRelayKey(forKey) != null &&
            vouchRequests.length < 50) {
          vouchRequests[id] = from;
          _vouchFor[id] = forKey;
          await _save();
          await host.notify(
            RuntimeSystemNotification(
              id: 'date-vreq-$id',
              title: t('{name} prosi o kilka słów', {
                'name': host.nameOf(from),
              }),
              body: t(
                'Napisz, co o niej / o nim myślisz — trafi na jej / jego '
                'profil randkowy.',
              ),
              createdAtMillis: _now(),
              category: RuntimeSystemNotificationCategory.social,
              slotKey: 'date-vreq',
            ),
          );
        }
      case DatingTypes.vouch:
        final Object? id = p['id'];
        final Object? text = p['t'];
        if (id is String && text is String && me.vouches.length < 20) {
          if (me.vouches.any((DatingVouch v) => v.id == id)) {
            return;
          }
          final DatingVouch? vouch = DatingVouch.fromJson(<String, dynamic>{
            'id': id,
            'by': p['by'],
            't': text,
            'vk': p['vk'],
            'sig': p['sig'],
            'at': p['at'],
          });
          final String? key = myKey;
          // Kept only when the signature is good for this profile.
          if (vouch == null || key == null || !await vouch.verify(key)) {
            return;
          }
          me.vouches.add(vouch);
          await _save();
          await host.notify(
            RuntimeSystemNotification(
              id: 'date-vouch-$id',
              title: t('{name} napisał(a) o Tobie', {
                'name': host.nameOf(from),
              }),
              body: text,
              createdAtMillis: _now(),
              category: RuntimeSystemNotificationCategory.social,
              slotKey: 'date-vouch',
            ),
          );
        }
      case DatingTypes.safe:
        await _onSafe(from, p);
      case DatingTypes.safeOk:
        final Object? id = p['id'];
        final SafeDate? d = id is String ? _safe[id] : null;
        if (d != null && !d.mine && d.friend == from && !d.isOver) {
          d.okAt = _now();
          await _save();
          await host.notify(
            RuntimeSystemNotification(
              id: 'date-safe-ok-$id',
              title: t('{name}: wszystko OK', {'name': host.nameOf(from)}),
              body: t('Randka skończona bezpiecznie.'),
              createdAtMillis: _now(),
              category: RuntimeSystemNotificationCategory.social,
              slotKey: 'date-safe:$id',
            ),
          );
        }
    }
  }

  /// Whether a new package from the friend [from] may be taken in (the
  /// flood guard). Counts it when it may.
  bool _takePackage(String from) {
    final int t = _now();
    final List<int> recent = (_packagesFrom[from] ??= <int>[])
      ..removeWhere((int at) => t - at > 24 * 3600 * 1000);
    if (recent.length >= kDatingPackagesPerFriendPerDay) {
      return false;
    }
    recent.add(t);
    return true;
  }

  /// Notes [key] (the sender's key of a sealed package) as the dating key of
  /// the friend [from]. Returns whether it changed anything.
  bool _learnFriendKey(String from, Object? key) {
    if (key is! String ||
        decodeRelayKey(key) == null ||
        _friendKeys[from] == key) {
      return false;
    }
    _friendKeys
      ..remove(from)
      ..[from] = key;
    while (_friendKeys.length > 2000) {
      _friendKeys.remove(_friendKeys.keys.first);
    }
    return true;
  }

  Future<void> _onPackage(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? hops = p['hops'];
    final Object? path = p['path'];
    final Object? raw = p['p'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 40 ||
        hops is! int ||
        path is! List ||
        raw is! Map) {
      return;
    }
    // A friend's own package (nobody passed it on yet) names their dating
    // key — also when the same package already came through someone else.
    final bool learnt = path.isEmpty && _learnFriendKey(from, raw['k']);
    if (_seen.containsKey(id)) {
      if (learnt) {
        await _save();
      }
      return;
    }
    // Checked before anything is kept or passed on: a package of a shape
    // this app never makes, or one too many from this friend today, goes no
    // further (and may still come through another friend later).
    // Only sealed packages, rebuilt from their own fields.
    final Map<String, dynamic>? body = DatingPackageSeal.wellFormed(raw);
    if (body == null || !_takePackage(from)) {
      return;
    }
    final int t = _now();
    _seen[id] = t;
    _routes[id] = (from, id, t);
    final List<String> names = <String>[
      for (final String n in path.whereType<String>().take(kDatingHops))
        n.length > 40 ? n.substring(0, 40) : n,
    ];
    // Everyone passes packages on, with dating on or off — once, not kept
    // waiting for friends who are away (the package comes again next week),
    // so a flood cannot fill every phone's outbox.
    if (hops > 0) {
      final List<String> next = <String>[...names, host.ownName()];
      for (final String f in host.friends()) {
        if (_n(f) != from) {
          await _send(f, <String, dynamic>{
            'type': DatingTypes.package,
            'id': id,
            'hops': min(hops, kDatingHops) - 1,
            'path': next,
            'p': body,
            kSendOnceKey: true,
          });
        }
      }
    }
    await _onSealedPackage(from, id, names, body, t);
  }

  /// A sealed package: every phone asks for its key, with dating on or off
  /// (so asking tells nobody anything); only with dating on is it kept until
  /// the key comes.
  Future<void> _onSealedPackage(
    String from,
    String id,
    List<String> names,
    Map<String, dynamic> body,
    int t,
  ) async {
    final String? sender = DatingPackageSeal.senderOf(body);
    final RelayIdentity? me = _identity;
    final Uint8List? senderKey = decodeRelayKey(sender);
    if (sender == null || senderKey == null || me == null || sender == myKey) {
      await _save();
      return;
    }
    if (active && !_blocked.contains(sender)) {
      _pending[id] = <String, dynamic>{
        'b': body,
        'f': from,
        'path': names,
        'at': t,
      };
      while (_pending.length > _pendingMax) {
        _pending.remove(_pending.keys.first);
      }
    }
    // A one-off mark the answer comes back to (not the per-person mark: a
    // phone asks every sender in range for keys).
    final String mark = _newId(16);
    _own[mark] = t;
    final Map<String, String> box = await DatingBox.seal(
      me: me,
      recipient: senderKey,
      payload: <String, dynamic>{'k': 'key?', 'id': id},
    );
    await _save();
    await _route(id, mark, box, from: null);
  }

  /// A profile out of an opened package: kept when it fits both ways and is
  /// not hidden from this person.
  Future<void> _acceptProfile(
    String from,
    String id,
    List<String> names,
    Map<dynamic, dynamic> body,
    int now,
  ) async {
    final DatingProfile? parsed = DatingProfile.fromJson(body);
    final DatingProfile? profile = parsed == null
        ? null
        : await _cleanProfile(parsed);
    if (profile == null ||
        profile.key == myKey ||
        _blocked.contains(profile.key)) {
      await _save();
      return;
    }
    final int distance = names.length + 1;
    final String own = host.ownAddress();
    final bool hiddenFromMe =
        own.isNotEmpty &&
        profile.hidden.contains(_hiddenHash(profile.salt, own));
    final bool fits =
        me.wants.accepts(
          age: profile.age,
          gender: profile.gender,
          distance: distance,
        ) &&
        profile.wants.accepts(
          age: me.age,
          gender: me.gender,
          distance: distance,
        );
    if (hiddenFromMe || !fits) {
      await _save();
      return;
    }
    final SeenProfile? had = _profiles[profile.key];
    if (had != null && had.profile.at > profile.at) {
      await _save();
      return;
    }
    _profiles[profile.key] = SeenProfile(
      profile: profile,
      replyTo: id,
      at: now,
      friend: from,
      path: names.reversed.toList(),
      distance: distance,
      introBy: had?.introBy,
      introNote: had?.introNote,
      introPyr: had?.introPyr,
      thankedAt: had?.thankedAt,
    );
    await _save();
    if (had == null) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'date-new-${profile.key.hashCode}',
          title: t('Randki: ktoś nowy'),
          body: distance == 1
              ? t('{name}, {age} — ktoś z Twoich znajomych', {
                  'name': profile.name,
                  'age': profile.age,
                })
              : t('{name}, {age} — znacie się przez {friend}', {
                  'name': profile.name,
                  'age': profile.age,
                  'friend': host.nameOf(from),
                }),
          createdAtMillis: now,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'date-new',
        ),
      );
    }
  }

  /// Re-encodes the photos and checks the vouches' signatures: a vouch whose
  /// signature does not check out was changed after it was written, so it
  /// is dropped.
  Future<DatingProfile> _cleanProfile(DatingProfile p) async {
    final List<String> photos = <String>[];
    for (final String photo in p.photos) {
      final String? clean = cleanDatingPhoto(photo);
      if (clean != null) {
        photos.add(clean);
      }
    }
    final List<DatingVouch> vouches = <DatingVouch>[];
    for (final DatingVouch v in p.vouches) {
      if (await v.verify(p.key)) {
        vouches.add(v);
      }
    }
    return p.copyWith(photos: photos, vouches: vouches);
  }

  /// The key of a sealed package came: open it.
  Future<void> _onPackageKey(String sender, Map<String, dynamic> msg) async {
    final Object? id = msg['id'];
    final Uint8List? key = decodeRelayKey(msg['key']);
    final Map<String, dynamic>? waiting = id is String ? _pending[id] : null;
    if (id is! String || key == null || waiting == null) {
      return;
    }
    final Object? body = waiting['b'];
    // Only the package's own sender can hand out its key.
    if (DatingPackageSeal.senderOf(body) != sender) {
      return;
    }
    _pending.remove(id);
    final Map<String, dynamic>? content = await DatingPackageSeal.open(
      body: body,
      packageId: id,
      key: key,
    );
    final Object? from = waiting['f'];
    final Object? path = waiting['path'];
    final Object? at = waiting['at'];
    // A cover, or a profile wrapped by someone else's key: nothing to show.
    if (content == null ||
        content['k'] != sender ||
        from is! String ||
        path is! List ||
        at is! int ||
        !active) {
      await _save();
      return;
    }
    await _acceptProfile(
      from,
      id,
      path.whereType<String>().toList(),
      content,
      at,
    );
  }

  /// Someone asks for the key of this phone's package (real or cover —
  /// every phone answers alike). Blocked and banned dating keys get none,
  /// and neither do the dating keys of the people this person hides from,
  /// when this phone knows them (friends' own keys, from their packages) —
  /// with dating on or off alike, so a missing answer says nothing about
  /// dating.
  /// A modified app can still ask with a key nobody knows: hiding works
  /// against the ordinary app, not against a determined one (§19.1).
  Future<void> _onKeyRequest(
    Uint8List sender,
    String? mark,
    Map<String, dynamic> msg,
  ) async {
    final Object? id = msg['id'];
    final String? key = id is String ? _pkgKeys[id] : null;
    final RelayIdentity? me = _identity;
    final String senderKey = base64Url.encode(sender);
    if (key == null ||
        mark == null ||
        me == null ||
        (isBanned?.call(senderKey) ?? false) ||
        _hiddenKey(senderKey)) {
      return;
    }
    final Map<String, String> box = await DatingBox.seal(
      me: me,
      recipient: sender,
      payload: <String, dynamic>{'k': 'key', 'id': id, 'key': key},
    );
    await _route(mark, null, box, from: null);
  }

  Future<void> _onBack(String from, Map<String, dynamic> p) async {
    final Object? to = p['to'];
    final Object? mark = p['m'];
    final Object? box = p['box'];
    final Object? ttl = p['ttl'];
    if (to is! String ||
        to.length > 40 ||
        box is! Map ||
        (mark != null && (mark is! String || mark.length > 40)) ||
        (box['c'] is String && (box['c'] as String).length > _maxBoxChars)) {
      return;
    }
    if (!_own.containsKey(to)) {
      await _route(
        to,
        mark as String?,
        Map<String, dynamic>.from(box),
        from: from,
        // Never more steps than this app gives a message.
        ttl: ttl is int ? min(ttl, _maxBackTtl) : 0,
      );
      await _save();
      return;
    }
    final RelayIdentity? id = _identity;
    if (id == null) {
      return;
    }
    final (Uint8List, Map<String, dynamic>)? opened = await DatingBox.open(
      me: id,
      box: box,
    );
    if (opened == null) {
      return;
    }
    final String sender = base64Url.encode(opened.$1);
    final Map<String, dynamic> msg = opened.$2;
    if (_blocked.contains(sender)) {
      return;
    }
    // Answers to the sender go back the way this came. (An introduction's
    // mark leads to the other person, not to the matchmaker; a key request's
    // mark is a one-off.)
    if (mark is String) {
      _routes[mark] = (from, mark, _now());
      final SeenProfile? s = _profiles[sender];
      if (s != null && msg['k'] != 'intro' && msg['k'] != 'key?') {
        s.replyTo = mark;
      }
    }
    switch (msg['k']) {
      case 'key?':
        await _onKeyRequest(opened.$1, mark is String ? mark : null, msg);
        await _save();
      case 'key':
        await _onPackageKey(sender, msg);
      case 'like':
        final Object? tok = msg['tok'];
        if (tok is String && tok.length <= 100) {
          _likesIn[sender] = tok;
          await _save();
          await _checkMatch(sender);
        }
      case 'msg':
        final Object? text = msg['t'];
        final Object? lineId = msg['id'];
        if (!_matches.containsKey(sender) ||
            text is! String ||
            lineId is! String) {
          return;
        }
        final List<DatingLine> lines = _chats[sender] ??= <DatingLine>[];
        if (lines.any((DatingLine l) => l.id == lineId)) {
          return;
        }
        lines.add(
          DatingLine(
            id: lineId,
            mine: false,
            text: text.length > 2000 ? text.substring(0, 2000) : text,
            at: _now(),
          ),
        );
        await _save();
        await host.notify(
          RuntimeSystemNotification(
            id: 'date-msg-$lineId',
            title: _profiles[sender]?.profile.name ?? t('Randki'),
            body: text,
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.message,
            slotKey: 'date-msg:${sender.hashCode}',
          ),
        );
      case 'intro':
        await _onIntro(from, sender, msg);
      default:
        await _save();
    }
  }

  Future<void> _onIntro(
    String from,
    String sender,
    Map<String, dynamic> msg,
  ) async {
    final DatingProfile? parsed = DatingProfile.fromJson(msg['p']);
    final DatingProfile? other = parsed == null
        ? null
        : await _cleanProfile(parsed);
    final Object? via = msg['via'];
    final Object? by = msg['by'];
    final Object? note = msg['note'];
    final Object? pyr = msg['pk'];
    if (!active ||
        other == null ||
        via is! String ||
        other.key == myKey ||
        _blocked.contains(other.key)) {
      return;
    }
    final String own = host.ownAddress();
    if (own.isNotEmpty && other.hidden.contains(_hiddenHash(other.salt, own))) {
      return;
    }
    // Preferences still count; the distance does not (a friend vouches).
    if (!me.wants.accepts(age: other.age, gender: other.gender, distance: 1) ||
        !other.wants.accepts(age: me.age, gender: me.gender, distance: 1)) {
      return;
    }
    // The way to the other person goes through the matchmaker's mark.
    _routes[via] = (from, via, _now());
    final SeenProfile? had = _profiles[other.key];
    _profiles[other.key] = SeenProfile(
      profile: other,
      replyTo: via,
      at: _now(),
      friend: had?.friend,
      path: had?.path ?? const <String>[],
      distance: had?.distance ?? 0,
      introBy: by is String
          ? (by.length > 40 ? by.substring(0, 40) : by)
          : t('Ktoś'),
      introNote: note is String
          ? (note.length > 300 ? note.substring(0, 300) : note)
          : null,
      introPyr: pyr is String && pyr.length <= 64 ? pyr : null,
      thankedAt: had?.thankedAt,
    );
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'date-intro-${other.key.hashCode}',
        title: t('{name} chce Cię komuś przedstawić', {
          'name': by is String ? by : t('Znajomy'),
        }),
        body: note is String && note.isNotEmpty
            ? t('{name}, {age} — „{note}”', {
                'name': other.name,
                'age': other.age,
                'note': note,
              })
            : '${other.name}, ${other.age}',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'date-intro',
      ),
    );
  }

  Future<void> _onAsk(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? name = p['n'];
    final Object? q = p['q'];
    final Object? ph = p['ph'];
    if (id is! String ||
        id.length > 40 ||
        name is! String ||
        q is! String ||
        _asks.containsKey(id)) {
      return;
    }
    final OpinionAsk a = OpinionAsk(
      id: id,
      friend: from,
      name: name.length > 40 ? name.substring(0, 40) : name,
      question: q.length > 500 ? q.substring(0, 500) : q,
      at: _now(),
      photo: ph is String && ph.length < 48 * 1024 ? ph : null,
    );
    _asks[id] = a;
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'date-ask-$id',
        title: t('{name} pyta o opinię', {'name': host.nameOf(from)}),
        body: a.question,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'date-ask',
      ),
    );
  }

  Future<void> _onSafe(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? until = p['until'];
    if (id is! String || id.length > 40 || until is! int) {
      return;
    }
    final Object? lat = p['lat'];
    final Object? lon = p['lon'];
    final SafeDate? had = _safe[id];
    if (had != null && (had.mine || had.friend != from)) {
      return;
    }
    final Object? note = p['note'];
    final SafeDate d =
        had ??
        SafeDate(
          id: id,
          friend: from,
          until: until,
          mine: false,
          note: note is String
              ? (note.length > 200 ? note.substring(0, 200) : note)
              : '',
        );
    if (had != null && until > had.until) {
      d
        ..until = until
        ..remindedAt = null
        ..alarmedAt = null;
    }
    if (lat is num && lon is num) {
      d
        ..lat = lat.toDouble()
        ..lon = lon.toDouble()
        ..locatedAt = _now();
    }
    _safe[id] = d;
    await _save();
    if (had == null) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'date-safe-$id',
          title: t('{name} idzie na randkę', {'name': host.nameOf(from)}),
          body: t('Prosi, żebyś czuwał(a). Ma dać znać, że wszystko OK.'),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'date-safe:$id',
        ),
      );
    }
  }
}
