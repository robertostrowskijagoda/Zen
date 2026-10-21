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
  /// A lantern: a one-off key, the same for everyone with dating on
  /// or off, flooding up to [kDatingMaxHops] steps.
  static const String lantern = 'date_lantern';

  /// A sealed message travelling back along the way a lantern came.
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

  /// Between friends: the watching friend asks once for the current
  /// location of the person on a date (the answer is a plain [safe] update).
  static const String locationRequest = 'date_loc_req';

  static const Set<String> all = <String>{
    lantern,
    back,
    ask,
    askAnswer,
    vouchRequest,
    vouch,
    safe,
    safeOk,
    locationRequest,
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

/// How often a phone sends a new lantern — only on this schedule, with
/// dating on or off, so nobody can tell the difference.
const Duration kDatingPublishEvery = Duration(days: 7);

/// A profile not refreshed for this long disappears.
const Duration kDatingProfileLife = Duration(days: 16);

/// Routes and seen lanterns are kept this long.
const Duration kDatingRouteLife = Duration(days: 30);

/// Independent reports of a minor (from different dating keys) that hide a
/// dating profile on a phone which never reported it itself.
const int kDatingMinorQuorum = 2;

/// Reports of a minor a phone carries in the profiles it sends, at most (the
/// newest), and for how long.
const int _minorCarried = 16;
const Duration _minorCarriedLife = Duration(days: 60);

/// Reporters kept per reported dating key, and reported keys kept.
const int _minorReportersMax = 50;
const int _minorKeysMax = 300;

/// A request for the location of a date is answered at most this often.
const Duration kDatingLocationAskEvery = Duration(minutes: 2);

/// Flood guard on the receiving side: new lanterns taken in from one
/// friend a day (their own and the ones they pass on). Every phone sends
/// one a week, so this covers a friend whose friends are several hundred
/// phones; a broken or modified app cannot make the whole network pass on
/// more.
const int kDatingLanternsPerFriendPerDay = 100;

/// Requests for a profile answered per dating key a day: an answer is up to
/// a few hundred kilobytes, so one key cannot make a phone send many.
const int kDatingFetchesPerKeyPerDay = 10;

/// Match tests answered per lantern for a friend asking from one step away
/// (the friend itself), whatever key it asks with: an honest phone asks once.
const int kDatingMatchNearPerFriend = 1;

/// Match tests answered per lantern that come through one friend from two
/// steps away (that friend's friends). A dating key costs nothing, so this,
/// not the key, is what limits how often anyone can run the test.
const int kDatingMatchFarPerFriend = 12;

/// The share of lanterns that did not fit whose profile a phone asks for
/// anyway (and drops the answer) — with dating on or off alike, so that
/// asking does not tell who dates.
const double kDatingDecoyFetchShare = 0.25;

/// Largest sealed message travelling back (an introduction carries a whole
/// profile with its photos).
const int _maxBoxChars = 800 * 1024;

/// Steps a message travelling back may still make, at most.
const int _maxBackTtl = 8;

/// "Randki przez znajomych".
///
/// * Every phone has a dating key and sends a small lantern every week on a
///   fixed schedule, with dating on or off, and passes on its friends'
///   lanterns up to [kDatingMaxHops] steps. A lantern carries only a
///   one-off key, so from the outside, and to the friends passing them on,
///   everybody looks the same, every week anew.
/// * Every phone runs a private match test ([DatingMatch]) with every
///   lantern it sees, sealed to the lantern's key: it tells the asker
///   whether the two fit (intention — dates or new friends — and wanted
///   genders both ways, distance).
///   Answers are limited per lantern and per friend the question comes
///   through, not per key (keys cost nothing).
///   A phone with dating off, or one this person is hidden from, never
///   fits — just like someone who does not fit.
/// * Only when they fit does the phone ask for the profile, back along the
///   way the lantern came, with a proof of fit; the answer is the profile
///   only when the proof holds, otherwise a cover of the same size range. Every phone asks for a share of the lanterns that did not
///   fit too and drops the answers.
/// * Likes, messages and introductions go back the way lanterns came,
///   sealed with dating keys: the phones in between cannot read
///   them or tell who wrote them.
/// * "Tak" sends a token both sides can compute only with their keys; "Nie"
///   sends nothing — so a "Nie" looks exactly like no decision at all.
/// * A profile travels only sealed to the one who asked (see [DatingBox]):
///   the phones in between cannot read it.
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
    this.currentPosition,
    this.decoyFetchShare = kDatingDecoyFetchShare,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// Members of a chat group (for hiding from whole groups).
  final List<String> Function(String groupId)? groupMembers;

  /// Raises this person's alarm when they do not confirm after a date.
  final Future<void> Function(String note)? raiseAlarm;

  /// Dating keys switched off by the pyramid (e.g. a minor.1).
  final bool Function(String datingKey)? isBanned;

  /// Dating keys this person hid after reporting them: left out of
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

  /// The current position of this phone (latitude, longitude), when it can
  /// be read: answers a friend's request for the location of a date at once
  /// when the person agreed to that beforehand ([SafeDate.autoShare]).
  final Future<(double, double)?> Function()? currentPosition;

  /// The share of lanterns that did not fit whose profile a phone asks for
  /// anyway ([kDatingDecoyFetchShare]; tests set 0 or 1).
  final double decoyFetchShare;
  final int Function() _now;
  final Random _random;
  static const String _key = 'dating/state';

  /// A profile asked for is waited for this long.
  static const Duration _wantedLife = Duration(days: 3);

  /// Profiles waited for, at most.
  static const int _wantedMax = 200;

  /// Match tests waited for, at most.
  static const int _askedMax = 1000;

  /// Answered match tests kept for a profile request, at most.
  static const int _answersMax = 2000;

  /// Lanterns whose passing friends are kept, and friends kept per lantern.
  static const int _viaLanterns = 2000;
  static const int _viaMax = 200;

  RelayIdentity? _identity;

  /// The key this phone signs vouches with (Ed25519; separate from the
  /// dating key, so a vouch does not tell anyone the voucher's dating key).
  LedgerKeyPair? _signer;
  MyDating me = MyDating();
  int _publishedAt = 0;

  /// What this person wants to see among new profiles ([DatingFilter]):
  /// kept on this phone, never sent.
  DatingFilter filter = const DatingFilter();

  final Map<String, int> _seen = <String, int>{};

  /// id → (next hop, id to use there, when).
  final Map<String, (String, String, int)> _routes =
      <String, (String, String, int)>{};

  /// Ids that end here: own lantern ids and marks.
  final Map<String, int> _own = <String, int>{};

  /// This phone's own lanterns (id → its keys): only their ids are answered
  /// with a match test and a profile.
  final Map<String, _OwnLantern> _lanterns = <String, _OwnLantern>{};

  /// Match tests asked (lantern id → the lantern's key, the blinding
  /// secret, who passed it on, the way, the answer mark, when).
  final Map<String, Map<String, dynamic>> _asked =
      <String, Map<String, dynamic>>{};

  /// Lanterns seen so far only through someone else (id → the lantern's
  /// key): when the sender's own copy comes later, the match test is asked
  /// again from one step away, so the sender learns this phone's dating key
  /// (see [_friendKeys]).
  final Map<String, String> _far = <String, String>{};

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

  /// Profiles asked for (lantern id → who sent the lantern, which friend
  /// passed it on, the way, when): an answer is taken only for these.
  final Map<String, Map<String, dynamic>> _wanted =
      <String, Map<String, dynamic>>{};

  /// Friends' own dating keys (address → key), learnt from the match tests
  /// they ask of this phone's lanterns from one step away: a friend this
  /// person hides from never fits and gets no profile from this phone, also
  /// when they ask through a mutual friend (see [_onMatchAsk], [_onFetch]).
  /// The first key stays; another one from the same friend is answered with
  /// fillers only, unless the known one has not been used for
  /// [kDatingProfileLife] (a reinstalled app).
  final Map<String, String> _friendKeys = <String, String>{};

  /// When each friend's key in [_friendKeys] was last used.
  final Map<String, int> _friendKeyAt = <String, int>{};

  /// Other keys a friend asked with from one step away (address → keys): for
  /// a friend this person hides from they count as hidden too.
  final Map<String, List<String>> _friendOtherKeys = <String, List<String>>{};

  /// Match tests answered (answer id → the lantern id, the asker's key, its
  /// points, whether the test was open, when): a profile goes out only for
  /// one of these, with a proof of fit ([DatingMatch.proves]).
  final Map<String, Map<String, dynamic>> _answers =
      <String, Map<String, dynamic>>{};

  /// Friends who passed a lantern on to this phone (lantern id → their
  /// addresses): they are friends of its sender too, so they count as the
  /// mutual friends on the profile it brings ([SeenProfile.mutual]).
  final Map<String, List<String>> _via = <String, List<String>>{};

  /// New lanterns taken in per friend (when), for the flood guard.
  final Map<String, List<int>> _lanternsFrom = <String, List<int>>{};

  /// Profile requests answered per dating key (when), for the flood guard.
  final Map<String, List<int>> _fetchesFrom = <String, List<int>>{};

  /// Sends made while a frame is handled; they go out once the handling is
  /// over, so two phones answering each other never wait on each other.
  List<(String, Map<String, dynamic>)>? _outbox;
  final Map<String, SafeDate> _safe = <String, SafeDate>{};

  /// Dating keys this person reported as a minor (key → when): switched off
  /// on this phone at once and carried in the profiles this phone sends.
  final Map<String, int> _minorSelf = <String, int>{};

  /// Reports of a minor seen in other people's profiles: reported dating
  /// key → (reporting dating key → when).
  final Map<String, Map<String, int>> _minorSeen = <String, Map<String, int>>{};
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

  /// Profiles to decide on (no decision yet) that still fit this person's
  /// wishes and pass the [filter], newest first.
  List<SeenProfile> get toDecide => _undecided().where(_passes).toList();

  /// Profiles to decide on that only the [filter] keeps out.
  int get filteredOut =>
      _undecided().where((SeenProfile s) => !_passes(s)).length;

  Iterable<SeenProfile> _undecided() => _visible().where(
    (SeenProfile s) =>
        !_decisions.containsKey(s.profile.key) && modesWith(s).isNotEmpty,
  );

  bool _passes(SeenProfile s) => filter.passes(s, modes: modesWith(s));

  /// The ways ([DatingIntent.dates], [DatingIntent.friends]) this person and
  /// [s] fit each other in, by both profiles as they are now.
  Set<DatingIntent> modesWith(SeenProfile s) => me.wants.sharedWith(
    own: me.gender,
    other: s.profile.gender,
    theirs: s.profile.wants,
  );

  /// Whether the two meet only as new friends (no dates): the screens and
  /// notifications then do not speak of dating.
  bool friendsOnly(String key) {
    final SeenProfile? s = _profiles[key];
    if (s == null) {
      return false;
    }
    final Set<DatingIntent> modes = modesWith(s);
    return modes.length == 1 && modes.first == DatingIntent.friends;
  }

  /// Changes the [filter] (kept on this phone only).
  Future<void> setFilter(DatingFilter value) async {
    filter = value;
    await _save();
  }

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
          if (_profiles[k] != null && !_hiddenByMe(k) && !isMinorOff(k))
            _profiles[k]!,
      ]..sort(
        (SeenProfile a, SeenProfile b) => (_matches[b.profile.key] ?? 0)
            .compareTo(_matches[a.profile.key] ?? 0),
      );

  bool _hiddenByMe(String key) => isHiddenByMe?.call(key) ?? false;

  /// Whether the dating profile [key] is switched off on this phone because
  /// of a report of a minor: this person reported it, or at least
  /// [kDatingMinorQuorum] other dating keys did (independent reports, from
  /// the profiles of the people around). A pyramid decision comes through
  /// [isBanned]. It cannot be shown again.
  bool isMinorOff(String key) {
    if (_minorSelf.containsKey(key)) {
      return true;
    }
    final Map<String, int>? by = _minorSeen[key];
    return by != null && by.length >= kDatingMinorQuorum;
  }

  /// Whether this person reported the profile [key] as a minor.
  bool reportedMinor(String key) => _minorSelf.containsKey(key);

  Iterable<SeenProfile> _visible() {
    final int t = _now();
    return (_profiles.values
        .where(
          (SeenProfile s) =>
              !_blocked.contains(s.profile.key) &&
              !(isBanned?.call(s.profile.key) ?? false) &&
              !isMinorOff(s.profile.key) &&
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
          !isMinorOff(s.profile.key) &&
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
    filter = DatingFilter.fromJson(json['flt']);
    _publishedAt = json['pub'] is int ? json['pub'] as int : 0;
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
    _lanterns.clear();
    final Object? lanterns = json['lan'];
    if (lanterns is Map) {
      lanterns.forEach((Object? k, Object? v) {
        final _OwnLantern? l = _OwnLantern.fromJson(v);
        if (k is String && l != null) {
          _lanterns[k] = l;
        }
      });
    }
    _asked.clear();
    final Object? asked = json['asked'];
    if (asked is Map) {
      asked.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          _asked[k] = Map<String, dynamic>.from(v);
        }
      });
    }
    _friendKeys
      ..clear()
      ..addAll(_strings(json['fkeys']));
    _friendKeyAt
      ..clear()
      ..addAll(_ints(json['fkat']));
    _friendOtherKeys.clear();
    final Object? other = json['fkx'];
    if (other is Map) {
      other.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _friendOtherKeys[k] = v.whereType<String>().take(20).toList();
        }
      });
    }
    _via.clear();
    final Object? via = json['via'];
    if (via is Map) {
      via.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _via[k] = v.whereType<String>().take(_viaMax).toList();
        }
      });
    }
    _answers.clear();
    final Object? answers = json['ans'];
    if (answers is Map) {
      answers.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          _answers[k] = Map<String, dynamic>.from(v);
        }
      });
    }
    _wanted.clear();
    final Object? wanted = json['want'];
    if (wanted is Map) {
      wanted.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          _wanted[k] = Map<String, dynamic>.from(v);
        }
      });
    }
    _minorSelf
      ..clear()
      ..addAll(_ints(json['mrs']));
    _minorSeen.clear();
    final Object? seen = json['mrn'];
    if (seen is Map) {
      seen.forEach((Object? k, Object? v) {
        final Map<String, int> by = _ints(v);
        if (k is String && by.isNotEmpty) {
          _minorSeen[k] = by;
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
    _via.removeWhere((String id, List<String> _) => !_seen.containsKey(id));
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
    _lanterns.removeWhere((String id, _OwnLantern _) => !_own.containsKey(id));
    _answers.removeWhere(
      (String _, Map<String, dynamic> a) =>
          a['at'] is! int ||
          t - (a['at'] as int) > _wantedLife.inMilliseconds ||
          !_lanterns.containsKey(a['l']),
    );
    _asked.removeWhere((String _, Map<String, dynamic> a) {
      final bool old =
          a['at'] is! int || t - (a['at'] as int) > _wantedLife.inMilliseconds;
      if (old && a['m'] is String) {
        _own.remove(a['m']);
      }
      return old;
    });
    _pruneMinorReports(t);
    _wanted.removeWhere(
      (String _, Map<String, dynamic> p) =>
          p['at'] is! int || t - (p['at'] as int) > _wantedLife.inMilliseconds,
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
          if (filter.active > 0) 'flt': filter.toJson(),
          'pub': _publishedAt,
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
          'lan': <String, dynamic>{
            for (final MapEntry<String, _OwnLantern> e in _lanterns.entries)
              e.key: e.value.toJson(),
          },
          'asked': _asked,
          if (_via.isNotEmpty) 'via': _via,
          if (_friendKeys.isNotEmpty) 'fkeys': _friendKeys,
          if (_friendKeyAt.isNotEmpty) 'fkat': _friendKeyAt,
          if (_friendOtherKeys.isNotEmpty) 'fkx': _friendOtherKeys,
          'ans': _answers,
          'want': _wanted,
          'safe': <Map<String, dynamic>>[
            for (final SafeDate s in _safe.values) s.toJson(),
          ],
          if (_minorSelf.isNotEmpty) 'mrs': _minorSelf,
          if (_minorSeen.isNotEmpty) 'mrn': _minorSeen,
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

  /// Saves the profile and settings. Nothing is sent because of it (that
  /// would tell who dates): people get the change with the next profile
  /// they ask for.
  Future<void> saveMine(void Function(MyDating me) change) async {
    change(me);
    await _save();
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
    // [kDatingMaxHidden] of them (and the profile stays a sane size).
    final Set<String> hidden = <String>{
      ...me.hiddenFriends.map(_n),
      for (final String g in me.hiddenGroups) ...?groupMembers?.call(g).map(_n),
    };
    return DatingProfile(
      key: key,
      name: me.name.trim(),
      gender: me.gender,
      about: me.about.trim(),
      lookingFor: me.lookingFor.trim(),
      wants: me.wants,
      photos: List<String>.of(me.photos.take(kDatingMaxPhotos)),
      interests: datingInterestsFromJson(me.interests),
      salt: salt,
      hidden: <String>[
        for (final String a in hidden.take(kDatingMaxHidden))
          _hiddenHash(salt, a),
      ],
      vouches: me.vouches.where((DatingVouch v) => v.approved).toList(),
      at: _now(),
    );
  }

  /// Sends a new lantern when it is time: only every
  /// [kDatingPublishEvery], whatever this person does in Dating, and the same
  /// lantern to every friend (also the ones this person hides from — the
  /// lantern says nothing; the match test keeps them out).
  Future<void> maybePublish({bool force = false}) async {
    final int t = _now();
    if (_identity == null) {
      return;
    }
    final bool due = t - _publishedAt >= kDatingPublishEvery.inMilliseconds;
    if (!force && !due) {
      return;
    }
    final _OwnLantern own = _OwnLantern(
      at: t,
      box: await RelayIdentity.generate(),
    );
    final DatingLantern lantern = DatingLantern(own.box.publicKeyBase64);
    final String id = _newId(16);
    _own[id] = t;
    _lanterns[id] = own;
    _seen[id] = t;
    _publishedAt = t;
    await _save();
    for (final String f in host.friends()) {
      await _send(f, <String, dynamic>{
        'type': DatingTypes.lantern,
        'id': id,
        'hops': kDatingMaxHops - 1,
        'path': const <String>[],
        'l': lantern.toJson(),
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

  /// "Tak" or "Nie". Only "Tak" sends anything.
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
    final String name = s?.profile.name ?? t('Ktoś');
    final bool friends = friendsOnly(key);
    await host.notify(
      RuntimeSystemNotification(
        id: 'date-match-${key.hashCode}',
        title: friends ? t('Nowa znajomość! 👋') : t('Para! ❤️'),
        body: friends
            ? t('{name} też chce się poznać. Napiszcie do siebie.', {
                'name': name,
              })
            : t('{name} też powiedział(a) „Tak”. Napiszcie do siebie.', {
                'name': name,
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

  /// Reports the dating profile [key] as a minor: it is switched
  /// off on this phone at once (gone from the lists and the matches, never
  /// shown again), and the report travels in the profiles this phone sends. A
  /// phone that gets reports from [kDatingMinorQuorum] different dating keys
  /// switches the profile off too. The chat is kept (as evidence), unreadable
  /// in the lists.
  Future<void> reportMinor(String key) async {
    if (key.isEmpty || key.length > 100 || key == myKey) {
      return;
    }
    _minorSelf[key] = _now();
    _matches.remove(key);
    await _save();
  }

  /// The `mr` entry of a profile this phone sends: the newest reports of a
  /// minor.
  Map<String, dynamic>? _carriedMinorReports(int t) {
    final List<String> keys = <String>[
      for (final MapEntry<String, int> e in _minorSelf.entries)
        if (t - e.value < _minorCarriedLife.inMilliseconds) e.key,
    ];
    if (keys.isEmpty) {
      return null;
    }
    final List<String> newest = keys.length > _minorCarried
        ? keys.sublist(keys.length - _minorCarried)
        : keys;
    return <String, dynamic>{'mr': newest};
  }

  /// Reports of a minor found in the profile sent by [sender] (a dating
  /// key): counted once per reporting key. Returns whether anything new was
  /// learnt.
  bool _noteMinorReports(String sender, Object? reported) {
    if (reported is! List || sender == myKey || _blocked.contains(sender)) {
      return false;
    }
    bool changed = false;
    final int t = _now();
    for (final Object? k in reported.take(_minorCarried)) {
      if (k is! String ||
          k.isEmpty ||
          k.length > 100 ||
          k == sender ||
          k == myKey ||
          decodeRelayKey(k) == null) {
        continue;
      }
      final Map<String, int>? known = _minorSeen[k];
      if (known == null && _minorSeen.length >= _minorKeysMax) {
        continue;
      }
      final Map<String, int> by = known ?? (_minorSeen[k] = <String, int>{});
      if (by.containsKey(sender)) {
        by[sender] = t;
        continue;
      }
      if (by.length >= _minorReportersMax) {
        continue;
      }
      by[sender] = t;
      changed = true;
    }
    return changed;
  }

  void _pruneMinorReports(int t) {
    final int life = kDatingProfileLife.inMilliseconds * 4;
    for (final Map<String, int> by in _minorSeen.values) {
      by.removeWhere((String _, int at) => t - at > life);
    }
    _minorSeen.removeWhere((String _, Map<String, int> by) => by.isEmpty);
  }

  Future<void> block(String key) async {
    _blocked.add(key);
    _matches.remove(key);
    _chats.remove(key);
    await _save();
  }

  /// Removes the profile [key] from this phone ("Usuń z mojego urządzenia"
  /// after a report): its photos and text, the chat, the match and
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

  /// Introduces [a] and [b] to each other ("swatanie").
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
    // So the pair can thank the matchmaker with currency.
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
  /// status does not reach them either.
  Set<String> hiddenAddresses() => <String>{
    ...me.hiddenFriends.map(_n),
    for (final String g in me.hiddenGroups) ...?groupMembers?.call(g).map(_n),
  };

  /// Whether [datingKey] is the (known) dating key of someone this person
  /// hides from.
  bool _hiddenKey(String datingKey) => hiddenAddresses().any(
    (String a) =>
        _friendKeys[a] == datingKey ||
        (_friendOtherKeys[a]?.contains(datingKey) ?? false),
  );

  // ---- thanking the matchmaker ----

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
    bool autoShareLocation = false,
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
      autoShare: autoShareLocation,
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

  /// The watching friend asks once for the current location of the person
  /// on date [id]. The other phone asks that person for consent, or
  /// answers by itself when they agreed beforehand. At most one question
  /// every [kDatingLocationAskEvery] until it is answered. Returns whether
  /// the question went out.
  Future<bool> requestSafeLocation(String id) async {
    final SafeDate? d = _safe[id];
    if (d == null || d.mine || d.isOver) {
      return false;
    }
    final int t = _now();
    final int? asked = d.requestedAt;
    final bool answered = asked != null && (d.locatedAt ?? 0) >= asked;
    if (asked != null &&
        !answered &&
        t - asked < kDatingLocationAskEvery.inMilliseconds) {
      return false;
    }
    d.requestedAt = t;
    await _save();
    await _send(d.friend, <String, dynamic>{
      'type': DatingTypes.locationRequest,
      'id': d.id,
    });
    return true;
  }

  /// The person on the date answers a friend's request for the location:
  /// [allow] with the current position ([lat], [lon]) sends it; without it
  /// the question is dropped and nothing is sent.
  Future<void> answerLocationRequest({
    required bool allow,
    double? lat,
    double? lon,
  }) async {
    final SafeDate? d = mySafeDate;
    if (d == null) {
      return;
    }
    d.askedAt = null;
    if (allow && lat != null && lon != null) {
      await updateSafeLocation(lat, lon);
      return;
    }
    await _save();
  }

  Future<void> _onLocationRequest(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final SafeDate? d = id is String ? _safe[id] : null;
    if (d == null || !d.mine || d.friend != from || d.isOver) {
      return;
    }
    final int stamp = _now();
    final int? asked = d.askedAt;
    if (asked != null &&
        stamp - asked < kDatingLocationAskEvery.inMilliseconds) {
      return;
    }
    if (d.autoShare) {
      (double, double)? at;
      try {
        at = await currentPosition?.call();
      } on Object catch (error, stack) {
        logZenError('Randki: położenie na żądanie', error, stack);
      }
      if (at != null) {
        d
          ..lat = at.$1
          ..lon = at.$2
          ..locatedAt = _now();
        await _save();
        await _sendSafe(d);
        return;
      }
    }
    d.askedAt = stamp;
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'date-loc-ask-${d.id}',
        title: t('{name} prosi o Twoje położenie', {'name': host.nameOf(from)}),
        body: t('Otwórz Randki i wybierz, czy je wysłać.'),
        createdAtMillis: stamp,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'date-loc-ask:${d.id}',
      ),
    );
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

  /// For the Android background service: reads the state the app
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
      case DatingTypes.lantern:
        await _onLantern(from, p);
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
      case DatingTypes.locationRequest:
        await _onLocationRequest(from, p);
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

  /// Whether a new lantern from the friend [from] may be taken in (the
  /// flood guard). Counts it when it may.
  bool _takeLantern(String from) {
    final int t = _now();
    final List<int> recent = (_lanternsFrom[from] ??= <int>[])
      ..removeWhere((int at) => t - at > 24 * 3600 * 1000);
    if (recent.length >= kDatingLanternsPerFriendPerDay) {
      return false;
    }
    recent.add(t);
    return true;
  }

  /// Whether the dating key [requester] may be answered with a profile now
  /// (the flood guard). Counts it when it may.
  bool _takeFetch(String requester) =>
      _take(_fetchesFrom, requester, kDatingFetchesPerKeyPerDay);

  /// Whether [key] may be answered now, at most [limit] times a day per key
  /// in [log]. Counts it when it may.
  bool _take(Map<String, List<int>> log, String key, int limit) {
    final int t = _now();
    final List<int> recent = (log[key] ??= <int>[])
      ..removeWhere((int at) => t - at > 24 * 3600 * 1000);
    if (recent.length >= limit) {
      return false;
    }
    recent.add(t);
    while (log.length > 500) {
      log.remove(log.keys.first);
    }
    return true;
  }

  /// A question from the friend [from] itself (one step away) with [key]:
  /// whether [key] is that friend's dating key. The first key a friend asks
  /// with stays theirs; any other is kept as one of their other keys (hidden
  /// with them, see [_hiddenKey]) and answered with fillers only — unless
  /// the known key has not been used for [kDatingProfileLife].
  bool _friendKey(String from, String key) {
    final int t = _now();
    final String? known = _friendKeys[from];
    if (known == key) {
      _friendKeyAt[from] = t;
      return true;
    }
    final List<String> other = _friendOtherKeys[from] ??= <String>[];
    if (known != null &&
        t - (_friendKeyAt[from] ?? 0) <= kDatingProfileLife.inMilliseconds) {
      if (!other.contains(key)) {
        other.add(key);
        if (other.length > 20) {
          other.removeAt(0);
        }
      }
      return false;
    }
    if (known != null) {
      other.add(known);
      if (other.length > 20) {
        other.removeAt(0);
      }
    }
    _friendKeys
      ..remove(from)
      ..[from] = key;
    _friendKeyAt[from] = t;
    while (_friendKeys.length > 2000) {
      final String gone = _friendKeys.keys.first;
      _friendKeys.remove(gone);
      _friendKeyAt.remove(gone);
      _friendOtherKeys.remove(gone);
    }
    return true;
  }

  /// A friend [from] passed the lantern [id] on: a friend of its sender
  /// too, so a mutual friend of the profile it brings.
  void _noteVia(String id, String from) {
    final List<String> by = _via[id] ?? <String>[];
    if (by.contains(from) || by.length >= _viaMax) {
      return;
    }
    _via
      ..remove(id)
      ..[id] = (by..add(from));
    while (_via.length > _viaLanterns) {
      _via.remove(_via.keys.first);
    }
    for (final SeenProfile s in _profiles.values) {
      if (s.lantern == id && !s.mutual.contains(from)) {
        s.mutual.add(from);
      }
    }
  }

  Future<void> _onLantern(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final Object? hops = p['hops'];
    final Object? path = p['path'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 40 ||
        hops is! int ||
        path is! List) {
      return;
    }
    // Checked before anything is kept or passed on: a lantern of a shape
    // this app never makes, or one too many from this friend today, goes no
    // further (and may still come through another friend later). It is
    // rebuilt from its own fields, so nothing else rides along.
    final DatingLantern? lantern = DatingLantern.fromJson(p['l']);
    if (lantern == null) {
      return;
    }
    // The sender's own copy after one passed on by someone else: asked
    // again from one step away (see [_far]).
    final bool again =
        path.isEmpty && _far[id] == lantern.key && _far.remove(id) != null;
    if (_seen.containsKey(id) && !again) {
      // Kept in memory and written with the next save: copies come often,
      // and the whole state is not rewritten for each.
      if (path.isNotEmpty) {
        _noteVia(id, from);
      }
      return;
    }
    if (!again && !_takeLantern(from)) {
      return;
    }
    if (path.isNotEmpty) {
      _noteVia(id, from);
    }
    final int t = _now();
    _seen[id] = t;
    _routes[id] = (from, id, t);
    if (path.isNotEmpty) {
      _far[id] = lantern.key;
      while (_far.length > 2000) {
        _far.remove(_far.keys.first);
      }
    }
    final List<String> names = <String>[
      for (final String n in path.whereType<String>().take(kDatingMaxHops))
        n.length > 40 ? n.substring(0, 40) : n,
    ];
    // Everyone passes lanterns on, with dating on or off — once, not kept
    // waiting for friends who are away (the lantern comes again next week),
    // so a flood cannot fill every phone's outbox.
    if (hops > 0) {
      final List<String> next = <String>[...names, host.ownName()];
      for (final String f in host.friends()) {
        if (_n(f) != from) {
          await _send(f, <String, dynamic>{
            'type': DatingTypes.lantern,
            'id': id,
            'hops': min(hops, kDatingMaxHops - 1) - 1,
            'path': next,
            'l': lantern.toJson(),
            kSendOnceKey: true,
          });
        }
      }
    }
    await _onLanternSeen(from, id, names, lantern, t);
  }

  /// A lantern reached this phone: it asks the match test, with dating on
  /// or off alike (with dating off, or farther than this person looks, it
  /// asks with fillers only, so it never fits). The question is sealed to
  /// the lantern's key and goes back the way the lantern came.
  Future<void> _onLanternSeen(
    String from,
    String id,
    List<String> names,
    DatingLantern lantern,
    int t,
  ) async {
    final RelayIdentity? identity = _identity;
    final Uint8List? lanternKey = decodeRelayKey(lantern.key);
    if (lanternKey == null || identity == null || _lanterns.containsKey(id)) {
      await _save();
      return;
    }
    final int distance = names.length + 1;
    // The filter's distance works here, as fillers only (which looks just
    // like not fitting); the asked wishes are never narrowed by the filter,
    // since a proof of fit shows the owner every tag that was asked.
    final bool looking = active && distance <= min(me.wants.hops, filter.hops);
    final (RelayIdentity, List<String>) question = await DatingMatch.ask(
      looking ? me.wants.seekTags(me.gender) : const <String>{},
      _random,
    );
    // A one-off mark the answer comes back to.
    final String mark = _newId(16);
    _own[mark] = t;
    final Object? oldMark = _asked[id]?['m'];
    if (oldMark is String) {
      _own.remove(oldMark);
    }
    _asked[id] = <String, dynamic>{
      'k': lantern.key,
      'b': question.$1.toJson(),
      'f': from,
      'path': names,
      'm': mark,
      'at': t,
    };
    while (_asked.length > _askedMax) {
      final Object? m = _asked.remove(_asked.keys.first)?['m'];
      if (m is String) {
        _own.remove(m);
      }
    }
    final Map<String, String> box = await DatingBox.seal(
      me: identity,
      recipient: lanternKey,
      payload: <String, dynamic>{
        'k': 'match',
        'id': id,
        'd': distance,
        'q': question.$2,
      },
    );
    await _save();
    await _route(id, mark, box, from: null);
  }

  /// Someone runs the match test with this phone's lantern [lantern]. A key
  /// costs nothing, so the limits do not count keys: per lantern, a friend
  /// asking from one step away is answered [kDatingMatchNearPerFriend] times
  /// and only with the key learnt for them ([_friendKey]); questions coming
  /// through one friend from two steps away [kDatingMatchFarPerFriend]
  /// times. Questions through a friend this person hides from, and from
  /// keys of hidden, blocked, banned or reported people, get fillers only.
  /// Every question is answered alike, with dating on or off, with a new
  /// secret each time; only a person who may see the profile can fit.
  Future<void> _onMatchAsk(
    String from,
    Uint8List sender,
    String? mark,
    String id,
    _OwnLantern lantern,
    Map<String, dynamic> msg,
  ) async {
    final Object? d = msg['d'];
    final String senderKey = base64Url.encode(sender);
    if (d is! int || d < 1 || d > kDatingMaxHops || mark == null) {
      return;
    }
    final String slot = '${d == 1 ? 'n' : 'f'}|$from';
    final int used = lantern.asks[slot] ?? 0;
    if (used >=
        (d == 1 ? kDatingMatchNearPerFriend : kDatingMatchFarPerFriend)) {
      return;
    }
    lantern.asks[slot] = used + 1;
    final bool theirKey = d != 1 || _friendKey(from, senderKey);
    final bool open =
        active &&
        theirKey &&
        d <= me.wants.hops &&
        !hiddenAddresses().contains(from) &&
        !_blocked.contains(senderKey) &&
        !(isBanned?.call(senderKey) ?? false) &&
        !isMinorOff(senderKey) &&
        !_hiddenKey(senderKey);
    final Object? q = msg['q'];
    final (List<String>, List<String>)? answer = await DatingMatch.answer(
      q,
      open ? me.wants.offerTags(me.gender) : const <String>{},
      _random,
    );
    if (answer == null) {
      return;
    }
    final String answerId = _newId(16);
    _answers[answerId] = <String, dynamic>{
      'l': id,
      'k': senderKey,
      'q': List<String>.from(q as List),
      'd': d,
      'open': open,
      'at': _now(),
    };
    while (_answers.length > _answersMax) {
      _answers.remove(_answers.keys.first);
    }
    final Map<String, String> box = await DatingBox.seal(
      me: lantern.box,
      recipient: sender,
      payload: <String, dynamic>{
        'k': 'match_re',
        'id': id,
        'a': answerId,
        'r': answer.$1,
        'o': answer.$2,
      },
    );
    await _route(mark, null, box, from: null);
  }

  /// The answer to a match test (from [sender], the lantern's key). When the
  /// two fit, this phone asks for the profile; otherwise it asks anyway for
  /// a share of them ([decoyFetchShare]) and drops the answer, with dating on
  /// or off alike, so asking tells nobody anything.
  Future<void> _onMatchAnswer(
    Uint8List sender,
    Map<String, dynamic> msg,
  ) async {
    final Object? id = msg['id'];
    final Map<String, dynamic>? asked = id is String ? _asked[id] : null;
    final RelayIdentity? identity = _identity;
    if (id is! String ||
        asked == null ||
        identity == null ||
        asked['k'] != base64Url.encode(sender)) {
      return;
    }
    _asked.remove(id);
    final Object? mark = asked['m'];
    if (mark is String) {
      _own.remove(mark);
    }
    final RelayIdentity? blind = RelayIdentity.fromJson(asked['b']);
    final bool fits =
        active &&
        blind != null &&
        await DatingMatch.fits(blind, msg['r'], msg['o']);
    if (!fits && _random.nextDouble() >= decoyFetchShare) {
      await _save();
      return;
    }
    final int t = _now();
    if (fits) {
      _wanted[id] = <String, dynamic>{
        'k': asked['k'],
        'f': asked['f'],
        'path': asked['path'],
        'at': asked['at'],
      };
      while (_wanted.length > _wantedMax) {
        _wanted.remove(_wanted.keys.first);
      }
    }
    final String fetchMark = _newId(16);
    _own[fetchMark] = t;
    // The proof of fit is the blinding secret of the question: with it the
    // owner sees that a common tag was asked. It goes out only on a fit (a
    // request that did not fit carries a new random secret instead, and
    // gets a cover), so the owner learns this person's wishes only when the
    // two fit anyway.
    final Object? b = fits
        ? asked['b']
        : (await RelayIdentity.generate()).toJson();
    final Map<String, String> box = await DatingBox.seal(
      me: identity,
      recipient: sender,
      payload: <String, dynamic>{'k': 'fetch', 'id': id, 'a': msg['a'], 'b': b},
    );
    await _save();
    await _route(id, fetchMark, box, from: null);
  }

  /// A profile out of an answer: kept when it fits both ways and is
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
        _blocked.contains(profile.key) ||
        isMinorOff(profile.key)) {
      await _save();
      return;
    }
    final int distance = names.length + 1;
    final String own = host.ownAddress();
    final bool hiddenFromMe =
        own.isNotEmpty &&
        profile.hidden.contains(_hiddenHash(profile.salt, own));
    final bool fits = me.wants
        .sharedWith(
          own: me.gender,
          other: profile.gender,
          theirs: profile.wants,
          distance: distance,
        )
        .isNotEmpty;
    if (hiddenFromMe || !fits) {
      await _save();
      return;
    }
    final SeenProfile? had = _profiles[profile.key];
    if (had != null && had.profile.at > profile.at) {
      await _save();
      return;
    }
    final SeenProfile seen = SeenProfile(
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
      lantern: id,
      mutual: List<String>.of(_via[id] ?? const <String>[]),
    );
    _profiles[profile.key] = seen;
    await _save();
    // Nothing about a profile the filter keeps out of view.
    if (had == null && _passes(seen)) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'date-new-${profile.key.hashCode}',
          title: friendsOnly(profile.key)
              ? t('Nowa osoba do poznania')
              : t('Nowe dopasowanie'),
          body: distance == 1
              ? t('{name} — ktoś z Twoich znajomych', {'name': profile.name})
              : t('{name} — znacie się przez {friend}', {
                  'name': profile.name,
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

  /// The profile asked for came (from [sender], a dating key): kept when it
  /// is what was asked for.
  Future<void> _onProfile(String sender, Map<String, dynamic> msg) async {
    final Object? id = msg['id'];
    final Object? content = msg['p'];
    final Map<String, dynamic>? waiting = id is String ? _wanted[id] : null;
    final Uint8List? lanternKey = decodeRelayKey(waiting?['k']);
    final RelayIdentity? identity = _identity;
    if (id is! String ||
        content is! Map ||
        waiting == null ||
        lanternKey == null ||
        identity == null) {
      return;
    }
    // Only the sender of the lantern can answer for it.
    if (msg['lp'] !=
        await datingLanternProof(identity, lanternKey, id, sender)) {
      return;
    }
    _wanted.remove(id);
    final Object? from = waiting['f'];
    final Object? path = waiting['path'];
    final Object? at = waiting['at'];
    // Covers carry reports of a minor too.
    if (active) {
      _noteMinorReports(sender, content['mr']);
    }
    // A cover, or a profile wrapped by someone else's key: nothing to show.
    if (content['k'] != sender ||
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

  /// Someone asks for the profile behind this phone's lantern [lantern],
  /// after a match test this phone answered ([_answers], once each). The
  /// real profile goes out only with a proof of fit: the question's blinding
  /// secret shows that it asked a tag this person offers, and the test was
  /// open for that key. Anything else gets a cover, with dating on or off
  /// alike (padded to whole [kDatingBucket]s), so an answer says nothing to
  /// the phones in between. Hiding and blocking hold for every key the test
  /// was closed for; someone who invents fitting wishes under a new key from
  /// two steps away gets the profile, like anyone who fits.
  Future<void> _onFetch(
    Uint8List sender,
    String? mark,
    String id,
    _OwnLantern lantern,
    Map<String, dynamic> msg,
  ) async {
    final RelayIdentity? identity = _identity;
    final String? key = myKey;
    final String senderKey = base64Url.encode(sender);
    final Object? answerId = msg['a'];
    final Map<String, dynamic>? answered = answerId is String
        ? _answers[answerId]
        : null;
    if (mark == null ||
        key == null ||
        identity == null ||
        answered == null ||
        answered['l'] != id ||
        answered['k'] != senderKey ||
        !_takeFetch(senderKey)) {
      return;
    }
    _answers.remove(answerId);
    final RelayIdentity? blind = RelayIdentity.fromJson(msg['b']);
    final bool proven =
        answered['open'] == true &&
        active &&
        !_blocked.contains(senderKey) &&
        !(isBanned?.call(senderKey) ?? false) &&
        !isMinorOff(senderKey) &&
        !_hiddenKey(senderKey) &&
        blind != null &&
        await DatingMatch.proves(
          blind,
          answered['q'],
          me.wants.offerTags(me.gender),
        );
    final int t = _now();
    final DatingProfile? mine = proven ? _myProfile(_newId(12)) : null;
    final Map<String, dynamic> content = datingPadded(<String, dynamic>{
      ...(mine?.toJson() ?? const <String, dynamic>{'v': 1, 'cover': true}),
      // Reports of a minor travel with every answer, real or cover, so
      // they do not tell whether dating is on.
      ...?_carriedMinorReports(t),
    }, minBuckets: mine == null ? 2 + _random.nextInt(11) : 2);
    final Map<String, String> box = await DatingBox.seal(
      me: identity,
      recipient: sender,
      payload: <String, dynamic>{
        'k': 'prof',
        'id': id,
        'p': content,
        'lp': await datingLanternProof(lantern.box, sender, id, key),
      },
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
    // Sealed to one of this phone's lanterns: a match test or a request for
    // the profile, nothing else.
    final _OwnLantern? lantern = _lanterns[to];
    if (lantern != null) {
      final (Uint8List, Map<String, dynamic>)? asked = await DatingBox.open(
        me: lantern.box,
        box: box,
      );
      if (asked != null) {
        if (mark is String) {
          _routes[mark] = (from, mark, _now());
        }
        final String? m = mark is String ? mark : null;
        switch (asked.$2['k']) {
          case 'match':
            await _onMatchAsk(from, asked.$1, m, to, lantern, asked.$2);
          case 'fetch':
            await _onFetch(asked.$1, m, to, lantern, asked.$2);
        }
        await _save();
        return;
      }
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
      if (s != null && msg['k'] != 'intro') {
        s.replyTo = mark;
      }
    }
    switch (msg['k']) {
      case 'match_re':
        await _onMatchAnswer(opened.$1, msg);
      case 'prof':
        await _onProfile(sender, msg);
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
    if (me.wants
        .sharedWith(own: me.gender, other: other.gender, theirs: other.wants)
        .isEmpty) {
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
      lantern: had?.lantern,
      mutual: had?.mutual,
    );
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'date-intro-${other.key.hashCode}',
        title: t('{name} chce Cię komuś przedstawić', {
          'name': by is String ? by : t('Znajomy'),
        }),
        body: note is String && note.isNotEmpty
            ? t('{name} — „{note}”', {'name': other.name, 'note': note})
            : other.name,
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

/// One of this phone's own lanterns: when it went out, its one-off
/// key (questions are sealed to it) and how many match tests it answered per
/// friend the questions came through (`n|address` from the friend itself,
/// `f|address` through them).
final class _OwnLantern {
  _OwnLantern({required this.at, required this.box, Map<String, int>? asks})
    : asks = asks ?? <String, int>{};

  final int at;
  final RelayIdentity box;
  final Map<String, int> asks;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': at,
    'k': box.toJson(),
    'n': asks,
  };

  static _OwnLantern? fromJson(Object? json) {
    if (json is! Map || json['at'] is! int) {
      return null;
    }
    final RelayIdentity? box = RelayIdentity.fromJson(json['k']);
    if (box == null) {
      return null;
    }
    final Object? n = json['n'];
    return _OwnLantern(
      at: json['at'] as int,
      box: box,
      asks: <String, int>{
        if (n is Map)
          for (final MapEntry<dynamic, dynamic> e in n.entries)
            if (e.key is String && e.value is int)
              e.key as String: e.value as int,
      },
    );
  }
}
