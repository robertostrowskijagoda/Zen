import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
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
import 'package:zen/src/features/security/hybrid_kem.dart';
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

  /// Between friends (and the people of one's chat groups): this phone's
  /// dating key, sent by every phone with dating on or off, so a friend
  /// this person hides from is known before they ever ask anything.
  static const String key = 'date_key';

  /// A matchmaker to a friend: "make a lantern for an introduction"; and
  /// the friend's answer with that lantern (every phone answers alike).
  static const String intro = 'date_intro';
  static const String introLantern = 'date_intro_re';

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
    key,
    intro,
    introLantern,
  };

  /// What a person this one reached through an opened gate (or who reached
  /// this one) may send: lanterns and what travels back along them.
  static const Set<String> viaGate = <String>{lantern, back};
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
/// friend a day (their own and the ones they pass on, up to three steps).
/// Every phone sends one a week; a broken or modified app cannot make the
/// whole network pass on more.
const int kDatingLanternsPerFriendPerDay = 300;

/// Requests for a profile answered per dating key a day.
const int kDatingFetchesPerKeyPerDay = 10;

/// Match tests answered per lantern for a friend asking from one step away
/// (the friend itself), whatever key it asks with: an honest phone asks once.
const int kDatingMatchNearPerFriend = 1;

/// Match tests answered per lantern that come through one friend from
/// further away (that friend's friends and theirs). A dating key costs
/// nothing, so this, not the key, is what limits how often anyone can run
/// the test.
const int kDatingMatchFarPerFriend = 40;

/// Match tests answered for a lantern made for an introduction (only the
/// one introduced asks).
const int _introAnswers = 2;

/// The share of lanterns that did not fit whose profile a phone asks for
/// anyway (and drops the answer) — with dating on or off alike, so that
/// asking does not tell who dates.
const double kDatingDecoyFetchShare = 0.25;

/// Parts (photos, pages of vouches) of one profile answered for one answer,
/// at most.
const int kDatingPartsPerAnswer =
    kDatingMaxPhotos +
    (kDatingMaxVouches + kDatingVouchesPerPart - 1) ~/ kDatingVouchesPerPart;

/// Introductions a phone makes lanterns for, per friend (or dating key) who
/// asks, a day.
const int kDatingIntroOffersPerDay = 10;

/// Largest sealed message travelling back.
const int _maxBoxChars = 800 * 1024;

/// Steps a message travelling back may still make, at most.
const int _maxBackTtl = 8;

/// One side of an introduction: a friend (by address), or someone this
/// phone knows from Dating (by dating key).
@immutable
final class DatingEnd {
  const DatingEnd.friend(String this.address) : key = null;
  const DatingEnd.profile(String this.key) : address = null;

  final String? address;
  final String? key;

  Map<String, dynamic> toJson() => address != null
      ? <String, dynamic>{'f': address}
      : <String, dynamic>{'k': key};

  static DatingEnd? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? f = json['f'];
    final Object? k = json['k'];
    if (f is String && f.isNotEmpty) {
      return DatingEnd.friend(f);
    }
    if (k is String && k.isNotEmpty) {
      return DatingEnd.profile(k);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DatingEnd && other.address == address && other.key == key;

  @override
  int get hashCode => Object.hash(address, key);
}

/// "Randki przez znajomych".
///
/// * Every phone has a dating key (X25519 with a hybrid ML-KEM-768 half)
///   and tells it to its friends (with dating on or off). Every phone sends
///   a small lantern every week on a fixed schedule and passes on its
///   friends' lanterns up to [kDatingMaxHops] steps (and across gates this
///   person opened). A lantern carries only a one-off key, so everybody
///   looks the same, every week anew.
/// * Every phone runs a private match test ([DatingMatch]) with every
///   lantern it sees. The lantern's owner does not take the asker's word for
///   the distance: every phone a question passes counts one more step, and
///   the owner's own friend (who handed it over) cannot be skipped.
/// * Only when they fit does the phone ask for the profile, with a proof of
///   fit; the answer is the profile (signed by its owner) only when the
///   proof holds, otherwise a cover — both of exactly one size. Photos and
///   vouches come after it, one part at a time, each of one size too.
/// * Likes, messages and introductions go back the way lanterns came, in
///   hybrid boxes: the phones in between cannot read them or tell who wrote
///   them, now or with a quantum computer later.
/// * "Tak" sends a signed like that starts the pair's own secret; "Nie"
///   sends nothing — so a "Nie" looks exactly like no decision at all.
/// * A matchmaker asks two of their friends for a lantern each and hands
///   each the other's: the two run the match test with each other, so the
///   matchmaker learns nothing and their own wishes do not matter.
final class DatingService extends ChangeNotifier {
  DatingService({
    required this.host,
    required this.disk,
    this.groupMembers,
    this.groupPeers,
    this.gateContacts,
    this.trustedFriends,
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

  /// Everyone in this person's chat groups who is not a friend: they get
  /// this phone's dating key too (so hiding from a group holds for them).
  final Set<String> Function()? groupPeers;

  /// People this person reached through an opened gate, or who reached this
  /// person through one: lanterns go to them as to friends, marked as
  /// having crossed a gate ("dalej przez otwarte bramy").
  final Set<String> Function()? gateContacts;

  /// Friends whose friendship may be shown to a match who agreed to it
  /// ("Wspólni znajomi"); all friends when not given.
  final List<String> Function()? trustedFriends;

  /// Raises this person's alarm when they do not confirm after a date.
  final Future<void> Function(String note)? raiseAlarm;

  /// Dating keys switched off by the pyramid (e.g. a minor).
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

  /// The key this phone signs its dating profile and likes with (hybrid
  /// Ed25519 + ML-DSA-65; named in the profile).
  LedgerKeyPair? _profileSigner;

  /// The key this phone signs vouches with (separate from the dating key,
  /// so a vouch does not tell anyone the voucher's dating key).
  LedgerKeyPair? _signer;
  MyDating me = MyDating();
  int _publishedAt = 0;

  /// What this person wants to see among new profiles ([DatingFilter]):
  /// kept on this phone, never sent.
  DatingFilter filter = const DatingFilter();

  final Map<String, int> _seen = <String, int>{};

  /// Lanterns seen (id → the shortest reach so far and the lantern's key):
  /// a copy that comes a shorter way is taken again.
  final Map<String, (int, String)> _shortest = <String, (int, String)>{};

  /// id → (next hop, id to use there, when).
  final Map<String, (String, String, int)> _routes =
      <String, (String, String, int)>{};

  /// Ids that end here: own lantern ids and marks.
  final Map<String, int> _own = <String, int>{};

  /// This phone's own lanterns (id → its keys): only their ids are answered
  /// with a match test and a profile.
  final Map<String, _OwnLantern> _lanterns = <String, _OwnLantern>{};

  /// Match tests asked (lantern id → the lantern's key, the blinding
  /// secret, who passed it on, the way, the answer mark, when, whether the
  /// way crossed a gate, the introduction).
  final Map<String, Map<String, dynamic>> _asked =
      <String, Map<String, dynamic>>{};

  /// The mark others use to answer us, per dating key.
  final Map<String, String> _marks = <String, String>{};
  final Map<String, SeenProfile> _profiles = <String, SeenProfile>{};
  final Map<String, bool> _decisions = <String, bool>{};

  /// "Tak" from others (dating key → its KEM ciphertext and signature),
  /// checked once their profile is here.
  final Map<String, Map<String, String>> _likesIn =
      <String, Map<String, String>>{};

  /// This phone's own "Tak" (dating key → the secret it started `s`, and
  /// the ciphertext `c` and signature `sig` it sent): a "Tak" said again
  /// sends the same, so the pair's key stays one.
  final Map<String, Map<String, String>> _likeOut =
      <String, Map<String, String>>{};

  /// The pair's own key, once both said "Tak" (dating key → base64url).
  final Map<String, String> _pairKeys = <String, String>{};
  final Map<String, int> _matches = <String, int>{};
  final Map<String, List<DatingLine>> _chats = <String, List<DatingLine>>{};
  final Set<String> _blocked = <String>{};
  final Map<String, OpinionAsk> _asks = <String, OpinionAsk>{};

  /// "Wspólni znajomi" in a pair: whether this person agreed (dating key →
  /// when) and what the other side sent when they agreed.
  final Map<String, int> _mutualMine = <String, int>{};
  final Map<String, List<String>> _mutualTheirs = <String, List<String>>{};

  /// Friends asking for a few words (id → friend address).
  final Map<String, String> vouchRequests = <String, String>{};

  /// The dating key of the profile a request is for (id → key), so the
  /// words can be signed for that profile.
  final Map<String, String> _vouchFor = <String, String>{};

  /// Profiles asked for (lantern id → who sent the lantern, which friend
  /// passed it on, the way, when): an answer is taken only for these.
  final Map<String, Map<String, dynamic>> _wanted =
      <String, Map<String, dynamic>>{};

  /// Parts asked for (answer token → the lantern, whose profile, the
  /// lantern's hybrid key, when).
  final Map<String, Map<String, dynamic>> _parts =
      <String, Map<String, dynamic>>{};

  /// Friends' (and group members') dating keys (address → key), from what
  /// their own phones said ([DatingTypes.key]) or, before that, from the
  /// match tests they ask from one step away. A friend this person hides
  /// from never fits and gets no profile from this phone, also when they ask
  /// through a mutual friend.
  final Map<String, String> _friendKeys = <String, String>{};

  /// Other keys a friend asked with from one step away (address → keys): for
  /// a friend this person hides from they count as hidden too.
  final Map<String, List<String>> _friendOtherKeys = <String, List<String>>{};

  /// When this phone's key last went to each friend or group member.
  final Map<String, int> _keySent = <String, int>{};

  /// Match tests answered (answer id → the lantern id, the asker's key, its
  /// points, whether the test was open, its hybrid key, when): a profile
  /// goes out only for one of these, with a proof of fit.
  final Map<String, Map<String, dynamic>> _answers =
      <String, Map<String, dynamic>>{};

  /// Answers to profile requests (token → the lantern id, the asker's key,
  /// whether the profile was real, parts served, the asker's hybrid key,
  /// when): the parts go out only for these.
  final Map<String, Map<String, dynamic>> _tokens =
      <String, Map<String, dynamic>>{};

  /// Introductions this person makes (id → the two sides, the note, the
  /// lanterns they gave, when).
  final Map<String, Map<String, dynamic>> _intros =
      <String, Map<String, dynamic>>{};

  /// Friends who passed a lantern on to this phone straight from its sender
  /// (lantern id → their addresses): friends of its sender too, so the
  /// mutual friends on the profile it brings ([SeenProfile.mutual]).
  final Map<String, List<String>> _via = <String, List<String>>{};

  /// New lanterns taken in per friend (when), for the flood guard.
  final Map<String, List<int>> _lanternsFrom = <String, List<int>>{};

  /// Profile requests answered per dating key (when), for the flood guard.
  final Map<String, List<int>> _fetchesFrom = <String, List<int>>{};

  /// Introductions made lanterns for, per friend or key (when).
  final Map<String, List<int>> _introsFrom = <String, List<int>>{};

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

  /// This person's profile as last signed, and what it was signed from.
  DatingProfile? _signed;
  String _signedFrom = '';
  Future<void> _queue = Future<void>.value();

  int get now => _now();
  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String _newId([int length = 14]) => List<String>.generate(
    length,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  String? get myKey =>
      _identity == null ? null : base64Url.encode(_identity!.publicKey);

  /// The hybrid half of the dating key (base64url).
  String? get myPq {
    final Uint8List? pq = _identity?.pqPublicKey;
    return pq == null ? null : base64Url.encode(pq);
  }

  /// The key vouches written here are signed with.
  String? get vouchKey => _signer?.id;

  /// The key this phone signs its dating profile with.
  String? get profileKey => _profileSigner?.id;

  bool get active => me.enabled && me.complete;

  bool _isGate(String address) =>
      gateContacts?.call().map(_n).contains(_n(address)) ?? false;

  bool _isPeer(String address) =>
      groupPeers?.call().map(_n).contains(_n(address)) ?? false;

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

  /// The dating key a friend's (or group member's) phone told this one.
  @visibleForTesting
  String? knownKeyOf(String address) => _friendKeys[_n(address)];

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
        final Uint8List? profileSeed = decodeRelayKey(json['ps']);
        if (profileSeed != null && _profileSigner == null) {
          _profileSigner = await LedgerKeyPair.fromSeed(profileSeed);
        }
      }
      final bool fresh =
          _identity == null || _signer == null || _profileSigner == null;
      _identity ??= await RelayIdentity.generateHybrid();
      _signer ??= await LedgerKeyPair.generate();
      _profileSigner ??= await LedgerKeyPair.generate();
      if (raw == null || fresh) {
        await _save();
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt randek', error, stack);
    }
  }

  static Map<String, Map<String, dynamic>> _maps(Object? json) =>
      <String, Map<String, dynamic>>{
        if (json is Map)
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String && e.value is Map)
              e.key as String: Map<String, dynamic>.from(e.value as Map),
      };

  void _fromJson(Map<dynamic, dynamic> json) {
    final RelayIdentity? id = RelayIdentity.fromJson(json['id']);
    // Only a hybrid dating key is kept (an older one is made anew).
    _identity = id != null && id.isHybrid ? id : _identity;
    me = MyDating.fromJson(json['me']);
    filter = DatingFilter.fromJson(json['flt']);
    _publishedAt = json['pub'] is int ? json['pub'] as int : 0;
    _seen
      ..clear()
      ..addAll(_ints(json['seen']));
    _shortest.clear();
    final Object? shortest = json['sl'];
    if (shortest is Map) {
      shortest.forEach((Object? k, Object? v) {
        if (k is String &&
            v is List &&
            v.length == 2 &&
            v[0] is int &&
            v[1] is String) {
          _shortest[k] = (v[0] as int, v[1] as String);
        }
      });
    }
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
    _likesIn.clear();
    final Object? likes = json['likes'];
    if (likes is Map) {
      likes.forEach((Object? k, Object? v) {
        if (k is String && v is Map && v['c'] is String && v['sig'] is String) {
          _likesIn[k] = <String, String>{
            'c': v['c'] as String,
            'sig': v['sig'] as String,
          };
        }
      });
    }
    _likeOut.clear();
    final Object? lout = json['lout'];
    if (lout is Map) {
      lout.forEach((Object? k, Object? v) {
        if (k is String &&
            v is Map &&
            v['s'] is String &&
            v['c'] is String &&
            v['sig'] is String) {
          _likeOut[k] = <String, String>{
            's': v['s'] as String,
            'c': v['c'] as String,
            'sig': v['sig'] as String,
          };
        }
      });
    }
    _pairKeys
      ..clear()
      ..addAll(_strings(json['pair']));
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
    _mutualMine
      ..clear()
      ..addAll(_ints(json['mum']));
    _mutualTheirs.clear();
    final Object? mut = json['mut'];
    if (mut is Map) {
      mut.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _mutualTheirs[k] = v.whereType<String>().take(2000).toList();
        }
      });
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
    _asked
      ..clear()
      ..addAll(_maps(json['asked']));
    _friendKeys
      ..clear()
      ..addAll(_strings(json['fkeys']));
    _friendOtherKeys.clear();
    final Object? other = json['fkx'];
    if (other is Map) {
      other.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _friendOtherKeys[k] = v.whereType<String>().take(20).toList();
        }
      });
    }
    _keySent
      ..clear()
      ..addAll(_ints(json['ksent']));
    _via.clear();
    final Object? via = json['via'];
    if (via is Map) {
      via.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _via[k] = v.whereType<String>().take(_viaMax).toList();
        }
      });
    }
    _answers
      ..clear()
      ..addAll(_maps(json['ans']));
    _tokens
      ..clear()
      ..addAll(_maps(json['tok']));
    _wanted
      ..clear()
      ..addAll(_maps(json['want']));
    _parts
      ..clear()
      ..addAll(_maps(json['parts']));
    _intros
      ..clear()
      ..addAll(_maps(json['intro']));
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

  static bool _older(Map<String, dynamic> m, int t, Duration life) =>
      m['at'] is! int || t - (m['at'] as int) > life.inMilliseconds;

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    final int t = _now();
    final int life = kDatingRouteLife.inMilliseconds;
    _seen.removeWhere((String _, int at) => t - at > life);
    _shortest.removeWhere(
      (String id, (int, String) _) => !_seen.containsKey(id),
    );
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
          _older(a, t, _wantedLife) || !_lanterns.containsKey(a['l']),
    );
    _tokens.removeWhere(
      (String _, Map<String, dynamic> a) =>
          _older(a, t, _wantedLife) || !_lanterns.containsKey(a['l']),
    );
    _asked.removeWhere((String _, Map<String, dynamic> a) {
      final bool old = _older(a, t, _wantedLife);
      if (old && a['m'] is String) {
        _own.remove(a['m']);
      }
      return old;
    });
    _pruneMinorReports(t);
    _wanted.removeWhere(
      (String _, Map<String, dynamic> p) => _older(p, t, _wantedLife),
    );
    _parts.removeWhere(
      (String _, Map<String, dynamic> p) => _older(p, t, _wantedLife),
    );
    _intros.removeWhere(
      (String _, Map<String, dynamic> p) => _older(p, t, _wantedLife),
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
          if (_profileSigner != null)
            'ps': base64Url.encode(_profileSigner!.seed),
          'me': me.toJson(),
          if (filter.active > 0) 'flt': filter.toJson(),
          'pub': _publishedAt,
          'seen': _seen,
          'sl': <String, dynamic>{
            for (final MapEntry<String, (int, String)> e in _shortest.entries)
              e.key: <Object>[e.value.$1, e.value.$2],
          },
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
          'lout': _likeOut,
          'pair': _pairKeys,
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
          if (_mutualMine.isNotEmpty) 'mum': _mutualMine,
          if (_mutualTheirs.isNotEmpty) 'mut': _mutualTheirs,
          'vreq': vouchRequests,
          'vfor': _vouchFor,
          'lan': <String, dynamic>{
            for (final MapEntry<String, _OwnLantern> e in _lanterns.entries)
              e.key: e.value.toJson(),
          },
          'asked': _asked,
          if (_via.isNotEmpty) 'via': _via,
          if (_friendKeys.isNotEmpty) 'fkeys': _friendKeys,
          if (_friendOtherKeys.isNotEmpty) 'fkx': _friendOtherKeys,
          if (_keySent.isNotEmpty) 'ksent': _keySent,
          'ans': _answers,
          'tok': _tokens,
          'want': _wanted,
          'parts': _parts,
          if (_intros.isNotEmpty) 'intro': _intros,
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
  /// they ask for. Newly hidden friends whose dating key is not known yet
  /// are asked for it at once.
  Future<void> saveMine(void Function(MyDating me) change) async {
    change(me);
    await _save();
    for (final String a in hiddenAddresses()) {
      if (!_friendKeys.containsKey(a) && (host.isFriend(a) || _isPeer(a))) {
        await _sendKey(a, want: true);
      }
    }
  }

  /// This person's profile, signed (again only when something in it
  /// changed): the photos and the approved vouches it names are the ones
  /// sent as its parts.
  Future<DatingProfile?> _myProfile() async {
    final String? key = myKey;
    final String? pq = myPq;
    final LedgerKeyPair? signer = _profileSigner;
    if (key == null || pq == null || signer == null || !active) {
      return null;
    }
    final List<String> photos = List<String>.of(
      me.photos.take(kDatingMaxPhotos),
    );
    final List<DatingVouch> vouches = me.vouches
        .where((DatingVouch v) => v.approved)
        .take(kDatingMaxVouches)
        .toList();
    final String from = b64(
      crypto.sha256
          .convert(
            utf8.encode(
              jsonEncode(<Object?>[
                key,
                pq,
                me.name.trim(),
                me.gender.code,
                me.about.trim(),
                me.lookingFor.trim(),
                me.wants.toJson(),
                datingTagsFrom(me.interests),
                photos,
                <Object?>[for (final DatingVouch v in vouches) v.wireJson()],
              ]),
            ),
          )
          .bytes,
    );
    final DatingProfile? had = _signed;
    if (had != null && _signedFrom == from) {
      return had;
    }
    final DatingProfile signed = await DatingProfile.sign(
      signerKey: signer,
      key: key,
      pq: pq,
      name: me.name.trim(),
      gender: me.gender,
      at: _now(),
      about: me.about.trim(),
      lookingFor: me.lookingFor.trim(),
      wants: me.wants,
      interests: datingTagsFrom(me.interests),
      photos: photos,
      vouches: vouches,
    );
    _signed = signed;
    _signedFrom = from;
    return signed;
  }

  /// Sends a new lantern when it is time: only every
  /// [kDatingPublishEvery], whatever this person does in Dating, and the same
  /// lantern to every friend (also the ones this person hides from — the
  /// lantern says nothing; the match test keeps them out) and to the people
  /// across this person's open gates. Also tells friends and group members
  /// who have not heard it lately this phone's dating key.
  Future<void> maybePublish({bool force = false}) async {
    final int t = _now();
    if (_identity == null) {
      return;
    }
    await _shareKeys();
    final bool due = t - _publishedAt >= kDatingPublishEvery.inMilliseconds;
    if (!force && !due) {
      return;
    }
    final _OwnLantern own = _OwnLantern(
      at: t,
      box: await RelayIdentity.generateHybrid(),
    );
    final DatingLantern lantern = DatingLantern(own.box.publicKeyBase64);
    final String id = _newId(16);
    _own[id] = t;
    _lanterns[id] = own;
    _seen[id] = t;
    _publishedAt = t;
    await _save();
    final Set<String> friends = host.friends().map(_n).toSet();
    for (final String f in friends) {
      await _send(f, <String, dynamic>{
        'type': DatingTypes.lantern,
        'id': id,
        'hops': kDatingMaxHops - 1,
        'path': const <String>[],
        'l': lantern.toJson(),
      });
    }
    for (final String g in gateContacts?.call().map(_n) ?? const <String>[]) {
      if (!friends.contains(g)) {
        await _send(g, <String, dynamic>{
          'type': DatingTypes.lantern,
          'id': id,
          'hops': kDatingMaxHops - 1,
          'path': const <String>[],
          'l': lantern.toJson(),
          'g': true,
        });
      }
    }
  }

  // ---- dating keys of friends ----

  Future<void> _sendKey(String to, {required bool want}) async {
    final String? key = myKey;
    if (key == null) {
      return;
    }
    _keySent[to] = _now();
    await _send(to, <String, dynamic>{
      'type': DatingTypes.key,
      'k': key,
      if (want) 'w': true,
    });
  }

  /// This phone's dating key to every friend and group member who has not
  /// had it for [kDatingPublishEvery] (asking for theirs when it is not
  /// known), with dating on or off alike.
  Future<void> _shareKeys() async {
    final int t = _now();
    final Set<String> to = <String>{
      ...host.friends().map(_n),
      ...?groupPeers?.call().map(_n),
    };
    final int before = _keySent.length;
    _keySent.removeWhere((String a, int _) => !to.contains(a));
    bool changed = before != _keySent.length;
    for (final String a in to) {
      final int? last = _keySent[a];
      if (last != null && t - last < kDatingPublishEvery.inMilliseconds) {
        continue;
      }
      await _sendKey(a, want: !_friendKeys.containsKey(a));
      changed = true;
    }
    if (changed) {
      await _save();
    }
  }

  Future<void> _onKey(String from, Map<String, dynamic> p) async {
    final Object? k = p['k'];
    if (k is! String || k.length > 64 || decodeRelayKey(k) == null) {
      return;
    }
    final String? known = _friendKeys[from];
    if (known != null && known != k) {
      _noteOtherKey(from, known);
    }
    _friendKeys
      ..remove(from)
      ..[from] = k;
    while (_friendKeys.length > 4000) {
      final String gone = _friendKeys.keys.first;
      _friendKeys.remove(gone);
      _friendOtherKeys.remove(gone);
    }
    final int? last = _keySent[from];
    if (p['w'] == true &&
        (last == null ||
            _now() - last > const Duration(hours: 1).inMilliseconds)) {
      await _sendKey(from, want: false);
    }
    await _save();
  }

  void _noteOtherKey(String address, String key) {
    final List<String> other = _friendOtherKeys[address] ??= <String>[];
    if (!other.contains(key)) {
      other.add(key);
      if (other.length > 20) {
        other.removeAt(0);
      }
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

  /// Sends [payload] sealed to [key]'s dating key (hybrid), back along the
  /// way.
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
      recipientPq: decodeHybridPublicKey(s.profile.pq),
      payload: payload,
    );
    final String mark = _markFor(key);
    await _save();
    return _route(s.replyTo, mark, box, from: null);
  }

  /// Passes a back message one step on (or sends it from here): [n] is how
  /// many phones it passed before this one, [g] whether its way crossed a
  /// gate.
  Future<bool> _route(
    String to,
    String? mark,
    Map<String, dynamic> box, {
    required String? from,
    int ttl = _maxBackTtl,
    int n = 0,
    bool g = false,
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
      'n': n,
      if (g) 'g': true,
    });
    return true;
  }

  /// "Tak" or "Nie". Only "Tak" sends anything: a like signed with this
  /// person's profile key, with a hybrid secret for the pair.
  Future<void> decide(String key, bool yes) async {
    final SeenProfile? s = _profiles[key];
    final LedgerKeyPair? signer = _profileSigner;
    final String? mine = myKey;
    if (s == null || _identity == null || signer == null || mine == null) {
      return;
    }
    _decisions[key] = yes;
    await _save();
    if (!yes) {
      return;
    }
    Map<String, String>? like = _likeOut[key];
    if (like == null) {
      final Uint8List? theirPq = decodeHybridPublicKey(s.profile.pq);
      if (theirPq == null) {
        return;
      }
      final (String, Uint8List) pair = await datingPairEncapsulate(theirPq);
      final Uint8List sig = await signer.signWithKey(
        datingLikeBytes(from: mine, to: key, ciphertext: pair.$1),
      );
      like = _likeOut[key] = <String, String>{
        's': base64Url.encode(pair.$2),
        'c': pair.$1,
        'sig': base64Url.encode(sig),
      };
      await _save();
    }
    await _sendBack(key, <String, dynamic>{
      'k': 'like',
      'c': like['c'],
      'sig': like['sig'],
    });
    await _checkMatch(key);
  }

  Future<void> _checkMatch(String key) async {
    final Map<String, String>? got = _likesIn[key];
    final SeenProfile? s = _profiles[key];
    final RelayIdentity? identity = _identity;
    final String? mine = myKey;
    final Uint8List? out = unb64(_likeOut[key]?['s']);
    if (got == null ||
        s == null ||
        identity == null ||
        mine == null ||
        out == null ||
        _decisions[key] != true ||
        _matches.containsKey(key)) {
      return;
    }
    final bool signed = await verifyLedgerSignature(
      publicKey: s.profile.signer,
      message: datingLikeBytes(from: key, to: mine, ciphertext: got['c']!),
      signature: got['sig']!,
    );
    final Uint8List? theirs = signed
        ? await datingPairDecapsulate(identity, got['c'])
        : null;
    if (theirs == null) {
      _likesIn.remove(key);
      await _save();
      return;
    }
    _pairKeys[key] = base64Url.encode(
      datingPairKey(myKey: mine, theirKey: key, mine: out, theirs: theirs),
    );
    _matches[key] = _now();
    await _save();
    final String name = s.profile.name;
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
    final Uint8List? pair = unb64(_pairKeys[key]);
    if (!_matches.containsKey(key) || pair == null || text.trim().isEmpty) {
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
    return _sendBack(key, <String, dynamic>{
      'k': 'msg',
      'id': line.id,
      't': t,
      'mac': datingMessageMac(pair, line.id, t),
    });
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

  /// The `mr` entry of an answer this phone sends: the newest reports of a
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

  /// Reports of a minor found in the answer sent by [sender] (a dating
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
    _pairKeys.remove(key);
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
    _likeOut.remove(key);
    _pairKeys.remove(key);
    _matches.remove(key);
    _chats.remove(key);
    _mutualMine.remove(key);
    _mutualTheirs.remove(key);
    await _save();
  }

  // ---- introductions ("Swatuj" / "Przedstaw") ----

  /// Whether [end] can be one side of an introduction made here.
  bool canIntroduce(DatingEnd end) {
    final String? a = end.address;
    if (a != null) {
      return host.isFriend(_n(a)) && _n(a) != _n(host.ownAddress());
    }
    final SeenProfile? s = _profiles[end.key];
    return s != null &&
        s.profile.key != myKey &&
        decodeHybridPublicKey(s.profile.pq) != null &&
        _routes.containsKey(s.replyTo);
  }

  /// Introduces [a] and [b] to each other ("Swatuj" / "Przedstaw"), with
  /// [note]. Each side's phone (dating on or off, it answers alike) makes a
  /// lantern for it; this phone hands each side the other's, and the two
  /// run the private match test with each other. So this person learns
  /// nothing — not even whether either dates — and their own wishes, or
  /// whether they date at all, do not matter; the two people's wishes do,
  /// their distance does not. Returns whether the requests went out.
  Future<bool> introduce(DatingEnd a, DatingEnd b, String note) async {
    if (a == b ||
        _identity == null ||
        !canIntroduce(a) ||
        !canIntroduce(b) ||
        (a.key != null && a.key == b.key) ||
        (a.address != null &&
            b.address != null &&
            _n(a.address!) == _n(b.address!))) {
      return false;
    }
    final String id = _newId(16);
    final String n = note.trim().length > 300
        ? note.trim().substring(0, 300)
        : note.trim();
    _intros[id] = <String, dynamic>{
      'a': a.address != null
          ? <String, dynamic>{'f': _n(a.address!)}
          : a.toJson(),
      'b': b.address != null
          ? <String, dynamic>{'f': _n(b.address!)}
          : b.toJson(),
      'note': n,
      'at': _now(),
    };
    await _save();
    bool ok = true;
    for (final DatingEnd end in <DatingEnd>[a, b]) {
      final String? address = end.address;
      if (address != null) {
        await _send(_n(address), <String, dynamic>{
          'type': DatingTypes.intro,
          'id': id,
        });
      } else {
        ok =
            await _sendBack(end.key!, <String, dynamic>{
              'k': 'intro_ask',
              'id': id,
              'pq': myPq,
            }) &&
            ok;
      }
    }
    return ok;
  }

  /// Someone asks this phone for a lantern for an introduction (with
  /// dating on or off alike, so the asker learns nothing). Returns the new
  /// lantern's id and the lantern, or `null` past the daily limit.
  Future<(String, DatingLantern)?> _introLanternFor(String who) async {
    if (!_take(_introsFrom, who, kDatingIntroOffersPerDay)) {
      return null;
    }
    final int t = _now();
    final _OwnLantern own = _OwnLantern(
      at: t,
      box: await RelayIdentity.generateHybrid(),
      intro: true,
    );
    final String id = _newId(16);
    _own[id] = t;
    _lanterns[id] = own;
    _seen[id] = t;
    await _save();
    return (id, DatingLantern(own.box.publicKeyBase64));
  }

  Future<void> _onIntroOffer(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    if (id is! String || id.isEmpty || id.length > 40) {
      return;
    }
    final (String, DatingLantern)? made = await _introLanternFor(from);
    if (made == null) {
      return;
    }
    await _send(from, <String, dynamic>{
      'type': DatingTypes.introLantern,
      'id': id,
      'lid': made.$1,
      'l': made.$2.toJson(),
    });
  }

  /// A lantern for an introduction came back from one side ([end]).
  Future<void> _onIntroLanternBack(
    DatingEnd end,
    String id,
    Object? lid,
    Object? l,
  ) async {
    final Map<String, dynamic>? intro = _intros[id];
    final DatingLantern? lantern = DatingLantern.fromJson(l);
    if (intro == null ||
        lantern == null ||
        lid is! String ||
        lid.isEmpty ||
        lid.length > 40) {
      return;
    }
    final String? side = end == DatingEnd.fromJson(intro['a'])
        ? 'la'
        : end == DatingEnd.fromJson(intro['b'])
        ? 'lb'
        : null;
    if (side == null || intro[side] != null) {
      return;
    }
    intro[side] = <String, dynamic>{'id': lid, 'l': lantern.toJson()};
    if (end.address != null) {
      _routes[lid] = (end.address!, lid, _now());
    }
    await _save();
    if (intro['la'] != null && intro['lb'] != null) {
      await _handOver(intro);
      _intros.remove(id);
      await _save();
    }
  }

  /// Gives each side of an introduction the other side's lantern, with a
  /// new route id leading through this phone.
  Future<void> _handOver(Map<String, dynamic> intro) async {
    final DatingEnd? a = DatingEnd.fromJson(intro['a']);
    final DatingEnd? b = DatingEnd.fromJson(intro['b']);
    final Object? la = intro['la'];
    final Object? lb = intro['lb'];
    if (a == null || b == null || la is! Map || lb is! Map) {
      return;
    }
    final String by = host.ownName();
    final String? pyr = pyramidKey?.call();
    final Object? note = intro['note'];
    for (final (DatingEnd, Map<dynamic, dynamic>) side
        in <(DatingEnd, Map<dynamic, dynamic>)>[(a, lb), (b, la)]) {
      final Object? lid = side.$2['id'];
      final (String, String, int)? toOther = lid is String
          ? _routes[lid]
          : null;
      if (toOther == null) {
        continue;
      }
      // A route id of its own, so the two ways never mix on a phone that
      // is on both.
      final String route = _newId(16);
      _routes[route] = (toOther.$1, toOther.$2, _now());
      final Map<String, dynamic> meta = <String, dynamic>{
        'by': by.length > 40 ? by.substring(0, 40) : by,
        if (note is String && note.isNotEmpty) 'nt': note,
        'pk': ?pyr,
      };
      final String? address = side.$1.address;
      if (address != null) {
        await _send(address, <String, dynamic>{
          'type': DatingTypes.lantern,
          'id': route,
          'hops': 0,
          'path': const <String>[],
          'l': side.$2['l'],
          'x': meta,
        });
      } else {
        await _sealAndRoute(side.$1.key!, route, <String, dynamic>{
          'k': 'intro_l',
          'id': route,
          'l': side.$2['l'],
          ...meta,
        });
      }
    }
  }

  /// Sends [payload] sealed to [key] along its way, with [mark] as the id
  /// the hops record back to this phone (an introduction's route id).
  Future<bool> _sealAndRoute(
    String key,
    String mark,
    Map<String, dynamic> payload,
  ) async {
    final SeenProfile? s = _profiles[key];
    final Uint8List? them = decodeRelayKey(key);
    if (s == null || them == null || _identity == null) {
      return false;
    }
    final Map<String, String> box = await DatingBox.seal(
      me: _identity!,
      recipient: them,
      recipientPq: decodeHybridPublicKey(s.profile.pq),
      payload: payload,
    );
    await _save();
    return _route(s.replyTo, mark, box, from: null);
  }

  /// The other side's lantern of an introduction reached this phone: the
  /// match test is asked like with any lantern (with dating off: fillers),
  /// only the distance does not count.
  Future<void> _onIntroLantern(
    String from,
    String id,
    DatingLantern lantern,
    Map<dynamic, dynamic> meta, {
    String? via,
  }) async {
    if (_seen.containsKey(id) || id.isEmpty || id.length > 40) {
      return;
    }
    final int t = _now();
    _seen[id] = t;
    _routes[id] = (from, id, t);
    final Object? by = meta['by'];
    final Object? note = meta['nt'];
    final Object? pk = meta['pk'];
    await _onLanternSeen(
      from,
      id,
      const <String>[],
      lantern,
      t,
      intro: <String, dynamic>{
        'by': by is String ? (by.length > 40 ? by.substring(0, 40) : by) : '',
        if (note is String)
          'nt': note.length > 300 ? note.substring(0, 300) : note,
        if (pk is String && pk.length <= 64) 'pk': pk,
        'v': ?via,
      },
    );
  }

  // ---- friends: opinions and vouches ----

  /// The friends this person can ask about [key] ("Zapytaj o opinię"):
  /// mutual friends (who passed the person's lantern on straight from
  /// them, or whom both agreed to show), the friend the profile came
  /// through when the person is further than a friend, and the friend who
  /// introduced them — never the person themselves.
  List<String> opinionFriends(String key) {
    final SeenProfile? s = _profiles[key];
    if (s == null) {
      return const <String>[];
    }
    final String? self = s.distance == 1 ? s.friend : null;
    final Set<String> out = <String>{
      if (s.introVia != null) s.introVia!,
      ...s.mutual,
      if (s.distance >= 2 && s.friend != null) s.friend!,
      ...?mutualFriendsWith(key),
    };
    return <String>[
      for (final String a in out)
        if (a != self && host.isFriend(a)) a,
    ];
  }

  /// "Co sądzisz o …?" to [friend] (one of [opinionFriends]; the first of
  /// them when not given).
  Future<bool> askOpinion(String key, String question, {String? friend}) async {
    final SeenProfile? s = _profiles[key];
    final List<String> can = opinionFriends(key);
    final String? to = friend != null
        ? (can.contains(friend) ? friend : null)
        : (can.isEmpty ? null : can.first);
    if (s == null || to == null || question.trim().isEmpty) {
      return false;
    }
    final OpinionAsk a = OpinionAsk(
      id: _newId(),
      friend: to,
      name: s.profile.name,
      question: question.trim(),
      at: _now(),
      mine: true,
      photo: s.profile.photo,
    );
    _asks[a.id] = a;
    await _save();
    await _send(to, <String, dynamic>{
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
          if (m.vouches.where((DatingVouch v) => v.approved).length <
              kDatingMaxVouches) {
            m.vouches[i] = m.vouches[i].approve();
          }
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

  /// Friends hidden from together with their circle: nothing that reaches
  /// this person through them is answered.
  Set<String> hiddenCircles() {
    final Set<String> hidden = me.hiddenFriends.map(_n).toSet();
    return <String>{
      for (final String a in me.hiddenCircles.map(_n))
        if (hidden.contains(a)) a,
    };
  }

  /// Whether [datingKey] is the (known) dating key of someone this person
  /// hides from.
  bool _hiddenKey(String datingKey) => hiddenAddresses().any(
    (String a) =>
        _friendKeys[a] == datingKey ||
        (_friendOtherKeys[a]?.contains(datingKey) ?? false),
  );

  // ---- "Bezpieczna randka": mutual friends with a match ----

  /// Agrees to show a match [key] which of this person's friends they know
  /// too (and to see theirs): only when both agree, each phone shows the
  /// friends they have in common. What goes out is a mark per friend made
  /// with the pair's own key, never an address.
  Future<bool> shareMutualFriends(String key) async {
    final Uint8List? pair = unb64(_pairKeys[key]);
    if (!_matches.containsKey(key) || pair == null) {
      return false;
    }
    _mutualMine[key] = _now();
    await _save();
    final List<String> friends = (trustedFriends?.call() ?? host.friends())
        .map(_n)
        .toSet()
        .take(2000)
        .toList();
    return _sendBack(key, <String, dynamic>{
      'k': 'mutual',
      'h': <String>[for (final String f in friends) datingFriendMark(pair, f)],
    });
  }

  /// Whether this person and the match [key] agreed to see their mutual
  /// friends.
  (bool, bool) mutualConsent(String key) =>
      (_mutualMine.containsKey(key), _mutualTheirs.containsKey(key));

  /// The friends this person and the match [key] have in common, once both
  /// agreed ([shareMutualFriends]); `null` before.
  List<String>? mutualFriendsWith(String key) {
    final Uint8List? pair = unb64(_pairKeys[key]);
    final List<String>? theirs = _mutualTheirs[key];
    if (pair == null || theirs == null || !_mutualMine.containsKey(key)) {
      return null;
    }
    final Set<String> marks = theirs.toSet();
    return <String>[
      for (final String f
          in (trustedFriends?.call() ?? host.friends()).map(_n).toSet())
        if (marks.contains(datingFriendMark(pair, f))) f,
    ];
  }

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
        // Friends send anything; people across an opened gate only lanterns
        // and what travels back; the people of one's groups only their key.
        final bool allowed =
            host.isFriend(from) ||
            (DatingTypes.viaGate.contains(type) && _isGate(from)) ||
            (type == DatingTypes.key && _isPeer(from));
        if (allowed) {
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
      case DatingTypes.key:
        await _onKey(from, p);
      case DatingTypes.intro:
        await _onIntroOffer(from, p);
      case DatingTypes.introLantern:
        final Object? id = p['id'];
        if (id is String) {
          await _onIntroLanternBack(
            DatingEnd.friend(from),
            id,
            p['lid'],
            p['l'],
          );
        }
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
            vouchRequests.length < 100) {
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
        if (id is String &&
            text is String &&
            me.vouches.length < kDatingMaxVouchesKept) {
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
  bool _takeLantern(String from) =>
      _take(_lanternsFrom, from, kDatingLanternsPerFriendPerDay);

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

  /// A question from the friend [from] itself (one step away, as the phones
  /// on the way counted) with [key]: whether [key] is that friend's dating
  /// key — the one their phone told this one ([DatingTypes.key]), or, when
  /// none came yet, the first they ask with. Any other is kept as one of
  /// their other keys (hidden with them, see [_hiddenKey]) and answered with
  /// fillers only.
  bool _friendKey(String from, String key) {
    final String? known = _friendKeys[from];
    if (known == key) {
      return true;
    }
    if (known != null) {
      _noteOtherKey(from, key);
      return false;
    }
    _friendKeys[from] = key;
    return true;
  }

  /// A friend [from] passed the lantern [id] on straight from its sender: a
  /// friend of its sender too, so a mutual friend of the profile it brings.
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
    final Object? intro = p['x'];
    if (intro is Map) {
      // A matchmaker's friend hands over a lantern made for an
      // introduction: from a friend only, never passed on.
      if (host.isFriend(from)) {
        await _onIntroLantern(from, id, lantern, intro, via: from);
      }
      return;
    }
    // Whether the way crossed an opened gate (on the way here or now).
    final bool gate = p['g'] == true || _isGate(from);
    final List<String> names = <String>[
      for (final String n in path.whereType<String>().take(kDatingMaxHops - 1))
        n.length > 40 ? n.substring(0, 40) : n,
    ];
    final int reach = datingReachOf(names.length + 1, gate: gate);
    if (path.length == 1 && !gate) {
      _noteVia(id, from);
    }
    final (int, String)? best = _shortest[id];
    if (_seen.containsKey(id) &&
        (best == null || best.$1 <= reach || best.$2 != lantern.key)) {
      // Kept in memory and written with the next save: copies come often,
      // and the whole state is not rewritten for each.
      return;
    }
    // New, or the same lantern a shorter way: taken (again).
    if (!_takeLantern(from)) {
      return;
    }
    final int t = _now();
    _seen[id] = t;
    _shortest[id] = (reach, lantern.key);
    _routes[id] = (from, id, t);
    // Everyone passes lanterns on, with dating on or off — once, not kept
    // waiting for friends who are away (the lantern comes again next week),
    // so a flood cannot fill every phone's outbox.
    final int left = min(hops, kDatingMaxHops - 1 - names.length);
    if (left > 0) {
      final List<String> next = <String>[...names, host.ownName()];
      final Set<String> friends = host.friends().map(_n).toSet();
      final Set<String> gates =
          gateContacts?.call().map(_n).toSet() ?? <String>{};
      for (final String f in <String>{...friends, ...gates}) {
        if (f == from) {
          continue;
        }
        final bool acrossGate = gate || !friends.contains(f);
        await _send(f, <String, dynamic>{
          'type': DatingTypes.lantern,
          'id': id,
          'hops': left - 1,
          'path': next,
          'l': lantern.toJson(),
          if (acrossGate) 'g': true,
          kSendOnceKey: true,
        });
      }
    }
    await _onLanternSeen(from, id, names, lantern, t, gate: gate);
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
    int t, {
    bool gate = false,
    Map<String, dynamic>? intro,
  }) async {
    final RelayIdentity? identity = _identity;
    final Uint8List? lanternKey = decodeRelayKey(lantern.key);
    if (lanternKey == null || identity == null || _lanterns.containsKey(id)) {
      await _save();
      return;
    }
    final int reach = datingReachOf(names.length + 1, gate: gate);
    // The filter's distance works here, as fillers only (which looks just
    // like not fitting); the asked wishes are never narrowed by the filter,
    // since a proof of fit shows the owner every tag that was asked. An
    // introduction does not depend on the distance.
    final bool looking =
        active && (intro != null || reach <= min(me.wants.hops, filter.hops));
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
      if (gate) 'g': true,
      'x': ?intro,
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
        'q': question.$2,
        'pq': myPq,
      },
    );
    await _save();
    await _route(id, mark, box, from: null);
  }

  /// Someone runs the match test with this phone's lantern [lantern]. The
  /// distance is not the asker's word: [d] is one more than the phones the
  /// question passed (each counts itself, the friend who handed it over
  /// last), [gate] whether its way crossed a gate. A key costs nothing, so
  /// the limits do not count keys: per lantern, a friend asking from one
  /// step away is answered [kDatingMatchNearPerFriend] times and only with
  /// the key their phone told this one ([_friendKey]); questions coming
  /// through one friend from further [kDatingMatchFarPerFriend] times.
  /// Questions through a friend hidden with their circle, and from keys of
  /// hidden, blocked, banned or reported people, get fillers only. Every
  /// question is answered alike, with dating on or off, with a new secret
  /// each time; only a person who may see the profile can fit.
  Future<void> _onMatchAsk(
    String from,
    Uint8List sender,
    String? mark,
    String id,
    _OwnLantern lantern,
    Map<String, dynamic> msg, {
    required int d,
    required bool gate,
  }) async {
    final String senderKey = base64Url.encode(sender);
    if (mark == null || (!lantern.intro && d > kDatingMaxHops)) {
      return;
    }
    final String slot = lantern.intro ? 'x' : '${d == 1 ? 'n' : 'f'}|$from';
    final int used = lantern.asks[slot] ?? 0;
    final int limit = lantern.intro
        ? _introAnswers
        : d == 1
        ? kDatingMatchNearPerFriend
        : kDatingMatchFarPerFriend;
    if (used >= limit) {
      return;
    }
    lantern.asks[slot] = used + 1;
    final bool theirKey =
        lantern.intro || d != 1 || _friendKey(from, senderKey);
    final int reach = datingReachOf(d, gate: gate);
    final bool open =
        active &&
        theirKey &&
        (lantern.intro || reach <= me.wants.hops) &&
        !(d == 1 && !lantern.intro && hiddenAddresses().contains(from)) &&
        !hiddenCircles().contains(from) &&
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
    final Object? pq = msg['pq'];
    final Uint8List? askerPq = decodeHybridPublicKey(pq);
    // The id the asker knows the lantern by: the same one, except for an
    // introduction, where it is the matchmaker's route id.
    final Object? theirs = msg['id'];
    final String reply =
        theirs is String && theirs.isNotEmpty && theirs.length <= 40
        ? theirs
        : id;
    final String answerId = _newId(16);
    _answers[answerId] = <String, dynamic>{
      'l': id,
      'r': reply,
      'k': senderKey,
      'q': List<String>.from(q as List),
      'd': d,
      'open': open,
      if (askerPq != null) 'pq': pq,
      'at': _now(),
    };
    while (_answers.length > _answersMax) {
      _answers.remove(_answers.keys.first);
    }
    final Map<String, String> box = await DatingBox.seal(
      me: lantern.box,
      recipient: sender,
      recipientPq: askerPq,
      payload: <String, dynamic>{
        'k': 'match_re',
        'id': reply,
        'a': answerId,
        'r': answer.$1,
        'o': answer.$2,
        'lq': base64Url.encode(lantern.box.pqPublicKey ?? Uint8List(0)),
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
    final Object? lq = msg['lq'];
    final Uint8List? lanternPq = decodeHybridPublicKey(lq);
    final int t = _now();
    _wanted[id] = <String, dynamic>{
      'k': asked['k'],
      'f': asked['f'],
      'path': asked['path'],
      'at': asked['at'],
      if (asked['g'] == true) 'g': true,
      if (asked['x'] != null) 'x': asked['x'],
      if (lanternPq != null) 'lq': lq,
      if (!fits) 'dc': true,
    };
    while (_wanted.length > _wantedMax) {
      _wanted.remove(_wanted.keys.first);
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
      recipientPq: lanternPq,
      payload: <String, dynamic>{'k': 'fetch', 'id': id, 'a': msg['a'], 'b': b},
    );
    await _save();
    await _route(id, fetchMark, box, from: null);
  }

  /// A profile out of an answer: kept when it fits both ways (and within
  /// reach, unless introduced).
  Future<bool> _acceptProfile(
    String from,
    String id,
    List<String> names,
    DatingProfile profile,
    int now, {
    required bool gate,
    Map<dynamic, dynamic>? intro,
  }) async {
    if (profile.key == myKey ||
        _blocked.contains(profile.key) ||
        isMinorOff(profile.key)) {
      return false;
    }
    final int distance = intro != null ? 0 : names.length + 1;
    final bool fits = me.wants
        .sharedWith(
          own: me.gender,
          other: profile.gender,
          theirs: profile.wants,
          distance: intro != null ? null : datingReachOf(distance, gate: gate),
        )
        .isNotEmpty;
    if (!fits) {
      return false;
    }
    final SeenProfile? had = _profiles[profile.key];
    if (had != null && had.profile.at > profile.at) {
      return false;
    }
    final Object? by = intro?['by'];
    final Object? note = intro?['nt'];
    final Object? pk = intro?['pk'];
    final Object? via = intro?['v'];
    // An introduction keeps the way this phone knew the person by, if any.
    final SeenProfile? way = intro != null ? had : null;
    final SeenProfile seen = SeenProfile(
      profile: profile.withPartsOf(had?.profile),
      replyTo: id,
      at: now,
      friend: way != null ? way.friend : (intro != null ? null : from),
      path: way != null
          ? way.path
          : (intro != null ? const <String>[] : names.reversed.toList()),
      distance: way != null ? way.distance : distance,
      gate: way != null ? way.gate : gate,
      introBy: intro != null
          ? (by is String && by.isNotEmpty ? by : t('Ktoś'))
          : had?.introBy,
      introVia: intro != null ? (via is String ? via : null) : had?.introVia,
      introNote: intro != null
          ? (note is String && note.isNotEmpty ? note : null)
          : had?.introNote,
      introPyr: intro != null ? (pk is String ? pk : null) : had?.introPyr,
      thankedAt: had?.thankedAt,
      lantern: intro != null ? had?.lantern : id,
      mutual: intro != null
          ? had?.mutual
          : List<String>.of(_via[id] ?? const <String>[]),
    );
    _profiles[profile.key] = seen;
    await _save();
    // Nothing about a profile the filter keeps out of view.
    if (had == null && _passes(seen)) {
      final String name = profile.name;
      await host.notify(
        RuntimeSystemNotification(
          id: 'date-new-${profile.key.hashCode}',
          title: intro != null
              ? t('{name} chce Cię komuś przedstawić', {'name': seen.introBy})
              : friendsOnly(profile.key)
              ? t('Nowa osoba do poznania')
              : t('Nowe dopasowanie'),
          body: intro != null
              ? (seen.introNote != null
                    ? t('{name} — „{note}”', {
                        'name': name,
                        'note': seen.introNote,
                      })
                    : name)
              : distance == 1
              ? t('{name} — ktoś z Twoich znajomych', {'name': name})
              : t('{name} — znacie się przez {friend}', {
                  'name': name,
                  'friend': host.nameOf(from),
                }),
          createdAtMillis: now,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'date-new',
        ),
      );
    }
    return true;
  }

  /// The core of a profile asked for came (from [sender], a dating key):
  /// kept when it is what was asked for and its owner's signature holds;
  /// then its photos and vouches are asked for, one part at a time. A cover
  /// (or a decoy request's answer) gets a few part requests too, dropped
  /// alike, so the number of parts does not tell a real profile either.
  Future<void> _onProfile(String sender, Map<String, dynamic> msg) async {
    final Object? id = msg['id'];
    final Object? content = msg['p'];
    final Object? token = msg['t'];
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
    final DatingProfile? parsed = DatingProfile.fromJson(content);
    bool kept = false;
    if (parsed != null &&
        parsed.key == sender &&
        decodeHybridPublicKey(parsed.pq) != null &&
        waiting['dc'] != true &&
        from is String &&
        path is List &&
        at is int &&
        active &&
        await parsed.verify()) {
      kept = await _acceptProfile(
        from,
        id,
        path.whereType<String>().toList(),
        parsed,
        at,
        gate: waiting['g'] == true,
        intro: waiting['x'] is Map ? waiting['x'] as Map : null,
      );
    }
    if (!kept) {
      await _save();
    }
    if (token is! String || token.isEmpty || token.length > 40) {
      return;
    }
    // A cover, or a profile not kept: a few part requests all the same
    // (when this phone makes decoy requests at all).
    final int decoys = decoyFetchShare > 0 ? _random.nextInt(3) : 0;
    final List<String> specs = kept
        ? _missingParts(_profiles[sender]!.profile)
        : <String>[for (int i = 0; i < decoys; i++) 'p$i'];
    if (specs.isEmpty) {
      return;
    }
    _parts[token] = <String, dynamic>{
      'id': id,
      'k': kept ? sender : '',
      'lk': waiting['k'],
      if (waiting['lq'] != null) 'lq': waiting['lq'],
      'at': _now(),
    };
    for (final String spec in specs) {
      await _askPart(token, spec);
    }
  }

  /// The parts of [p] this phone does not have yet: `p<i>` for a photo,
  /// `v<j>` for a page of vouches.
  List<String> _missingParts(DatingProfile p) {
    bool missingVouch(int i) =>
        i >= p.vouchSlots.length || p.vouchSlots[i] == null;
    final List<String> out = <String>[
      for (int i = 0; i < p.photoDigests.length; i++)
        if (i >= p.photoSlots.length || p.photoSlots[i].isEmpty) 'p$i',
    ];
    for (int j = 0; j * kDatingVouchesPerPart < p.vouchDigests.length; j++) {
      final int end = min(
        (j + 1) * kDatingVouchesPerPart,
        p.vouchDigests.length,
      );
      for (int i = j * kDatingVouchesPerPart; i < end; i++) {
        if (missingVouch(i)) {
          out.add('v$j');
          break;
        }
      }
    }
    return out;
  }

  Future<void> _askPart(String token, String spec) async {
    final Map<String, dynamic>? part = _parts[token];
    final Object? id = part?['id'];
    final RelayIdentity? identity = _identity;
    final Uint8List? lanternKey = decodeRelayKey(part?['lk']);
    if (part == null ||
        id is! String ||
        identity == null ||
        lanternKey == null) {
      return;
    }
    final String mark = _newId(16);
    _own[mark] = _now();
    final Map<String, String> box = await DatingBox.seal(
      me: identity,
      recipient: lanternKey,
      recipientPq: decodeHybridPublicKey(part['lq']),
      payload: <String, dynamic>{'k': 'part', 'id': id, 't': token, 'i': spec},
    );
    await _save();
    await _route(id, mark, box, from: null);
  }

  /// Someone asks for the profile behind this phone's lantern [lantern],
  /// after a match test this phone answered ([_answers], once each). The
  /// real profile goes out only with a proof of fit: the question's blinding
  /// secret shows that it asked a tag this person offers, and the test was
  /// open for that key. Anything else gets a cover, with dating on or off
  /// alike — both exactly [kDatingCoreBytes] long — so an answer says
  /// nothing to the phones in between. Photos and vouches are not in it:
  /// they are asked for as parts with the token it carries.
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
    final DatingProfile? mine = proven ? await _myProfile() : null;
    final Map<String, dynamic> content = datingPadded(<String, dynamic>{
      ...(mine?.wireJson() ?? const <String, dynamic>{'cover': true}),
      // Reports of a minor travel with every answer, real or cover, so
      // they do not tell whether dating is on.
      ...?_carriedMinorReports(t),
    });
    final Object? r = answered['r'];
    final String reply = r is String ? r : id;
    final String token = _newId(16);
    _tokens[token] = <String, dynamic>{
      'l': id,
      'r': reply,
      'k': senderKey,
      if (mine != null) 'real': true,
      'n': 0,
      if (answered['pq'] != null) 'pq': answered['pq'],
      'at': t,
    };
    final Map<String, String> box = await DatingBox.seal(
      me: identity,
      recipient: sender,
      recipientPq: decodeHybridPublicKey(answered['pq']),
      payload: <String, dynamic>{
        'k': 'prof',
        'id': reply,
        'p': content,
        't': token,
        'lp': await datingLanternProof(lantern.box, sender, reply, key),
      },
    );
    await _route(mark, null, box, from: null);
  }

  /// One part of this person's profile (a photo, or a page of vouches) for
  /// an answered profile request, or a cover — exactly [kDatingPartBytes]
  /// either way.
  Future<void> _onPart(
    Uint8List sender,
    String? mark,
    String id,
    Map<String, dynamic> msg,
  ) async {
    final RelayIdentity? identity = _identity;
    final String senderKey = base64Url.encode(sender);
    final Object? token = msg['t'];
    final Object? spec = msg['i'];
    final Map<String, dynamic>? given = token is String ? _tokens[token] : null;
    if (mark == null ||
        identity == null ||
        given == null ||
        given['l'] != id ||
        given['k'] != senderKey ||
        spec is! String ||
        spec.length < 2 ||
        spec.length > 4) {
      return;
    }
    final int served = given['n'] is int ? given['n'] as int : 0;
    if (served >= kDatingPartsPerAnswer) {
      return;
    }
    given['n'] = served + 1;
    final DatingProfile? mine = given['real'] == true && active
        ? (_signed ?? await _myProfile())
        : null;
    final int? index = int.tryParse(spec.substring(1));
    Map<String, dynamic> part = const <String, dynamic>{'cover': true};
    if (mine != null && index != null && index >= 0) {
      if (spec.startsWith('p') && index < mine.photoSlots.length) {
        part = <String, dynamic>{'ph': mine.photoSlots[index]};
      } else if (spec.startsWith('v')) {
        final int from = index * kDatingVouchesPerPart;
        if (from < mine.vouchSlots.length) {
          part = <String, dynamic>{
            'vo': <Map<String, dynamic>>[
              for (final DatingVouch? v
                  in mine.vouchSlots.skip(from).take(kDatingVouchesPerPart))
                if (v != null) v.wireJson(),
            ],
          };
        }
      }
    }
    final Map<String, String> box = await DatingBox.seal(
      me: identity,
      recipient: sender,
      recipientPq: decodeHybridPublicKey(given['pq']),
      payload: <String, dynamic>{
        'k': 'part_re',
        'id': given['r'] is String ? given['r'] : id,
        't': token,
        'i': spec,
        'p': datingPadded(part, size: kDatingPartBytes),
      },
    );
    await _save();
    await _route(mark, null, box, from: null);
  }

  /// A part of a profile came: kept when it is one the profile's signature
  /// names (by digest) and, for vouches, their own signatures hold.
  Future<void> _onPartAnswer(String sender, Map<String, dynamic> msg) async {
    final Object? token = msg['t'];
    final Object? spec = msg['i'];
    final Object? content = msg['p'];
    final Map<String, dynamic>? part = token is String ? _parts[token] : null;
    if (part == null || spec is! String || content is! Map) {
      return;
    }
    final Object? key = part['k'];
    final SeenProfile? s = key is String && key == sender
        ? _profiles[sender]
        : null;
    final int? index = spec.length > 1 ? int.tryParse(spec.substring(1)) : null;
    if (s == null || index == null || index < 0) {
      return;
    }
    final DatingProfile p = s.profile;
    if (spec.startsWith('p')) {
      final Object? photo = content['ph'];
      if (photo is! String ||
          index >= p.photoDigests.length ||
          photo.length > kDatingMaxPhotoChars ||
          datingPhotoDigest(photo) != p.photoDigests[index]) {
        return;
      }
      final String? clean = cleanDatingPhoto(photo);
      if (clean == null) {
        return;
      }
      final List<String> slots = <String>[
        for (int i = 0; i < p.photoDigests.length; i++)
          i == index ? clean : (i < p.photoSlots.length ? p.photoSlots[i] : ''),
      ];
      s.profile = p.copyWith(photoSlots: slots);
    } else if (spec.startsWith('v')) {
      final Object? list = content['vo'];
      if (list is! List) {
        return;
      }
      final List<DatingVouch?> slots = <DatingVouch?>[
        for (int i = 0; i < p.vouchDigests.length; i++)
          i < p.vouchSlots.length ? p.vouchSlots[i] : null,
      ];
      final int start = index * kDatingVouchesPerPart;
      for (final Object? raw in list.take(kDatingVouchesPerPart)) {
        final DatingVouch? v = DatingVouch.fromJson(raw);
        if (v == null) {
          continue;
        }
        final int at = p.vouchDigests.indexOf(v.digest);
        if (at < start ||
            at >= start + kDatingVouchesPerPart ||
            !await v.verify(p.key)) {
          continue;
        }
        slots[at] = v;
      }
      s.profile = p.copyWith(vouchSlots: slots);
    } else {
      return;
    }
    if (s.profile.complete) {
      _parts.remove(token);
    }
    await _save();
  }

  Future<void> _onBack(String from, Map<String, dynamic> p) async {
    final Object? to = p['to'];
    final Object? mark = p['m'];
    final Object? box = p['box'];
    final Object? ttl = p['ttl'];
    final Object? steps = p['n'];
    if (to is! String ||
        to.length > 40 ||
        box is! Map ||
        (mark != null && (mark is! String || mark.length > 40)) ||
        (box['x'] is String && (box['x'] as String).length > _maxBoxChars)) {
      return;
    }
    // Phones the message passed before the one that handed it here.
    final int n = steps is int ? steps.clamp(0, _maxBackTtl) : 0;
    final bool gate = p['g'] == true || _isGate(from);
    if (!_own.containsKey(to)) {
      await _route(
        to,
        mark as String?,
        Map<String, dynamic>.from(box),
        from: from,
        // Never more steps than this app gives a message.
        ttl: ttl is int ? min(ttl, _maxBackTtl) : 0,
        n: n + 1,
        g: gate,
      );
      await _save();
      return;
    }
    final RelayIdentity? id = _identity;
    if (id == null) {
      return;
    }
    // Sealed to one of this phone's lanterns: a match test, a request for
    // the profile or for a part of it, nothing else.
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
            await _onMatchAsk(
              from,
              asked.$1,
              m,
              to,
              lantern,
              asked.$2,
              d: n + 1,
              gate: gate,
            );
          case 'fetch':
            await _onFetch(asked.$1, m, to, lantern, asked.$2);
          case 'part':
            await _onPart(asked.$1, m, to, asked.$2);
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
    // route id leads to the other person, not to the matchmaker; a
    // lantern's answer mark is a one-off.)
    if (mark is String) {
      _routes[mark] = (from, mark, _now());
      final SeenProfile? s = _profiles[sender];
      if (s != null && msg['k'] != 'intro_l' && msg['k'] != 'intro_re') {
        s.replyTo = mark;
      }
    }
    switch (msg['k']) {
      case 'match_re':
        await _onMatchAnswer(opened.$1, msg);
      case 'prof':
        await _onProfile(sender, msg);
      case 'part_re':
        await _onPartAnswer(sender, msg);
      case 'like':
        final Object? c = msg['c'];
        final Object? sig = msg['sig'];
        if (c is String &&
            c.length <= 2000 &&
            sig is String &&
            sig.length <= 8000) {
          _likesIn[sender] = <String, String>{'c': c, 'sig': sig};
          await _save();
          await _checkMatch(sender);
        }
      case 'msg':
        await _onMessage(sender, msg);
      case 'mutual':
        final Object? marks = msg['h'];
        if (_matches.containsKey(sender) && marks is List) {
          _mutualTheirs[sender] = marks
              .whereType<String>()
              .where((String h) => h.length <= 32)
              .take(2000)
              .toList();
          await _save();
        }
      case 'intro_ask':
        // A matchmaker who knows this person from Dating asks for a lantern
        // for an introduction; the answer goes back the way it came.
        final Object? introId = msg['id'];
        if (mark is String && introId is String && introId.length <= 40) {
          final (String, DatingLantern)? made = await _introLanternFor(sender);
          if (made != null) {
            final Map<String, String> reply = await DatingBox.seal(
              me: id,
              recipient: opened.$1,
              recipientPq: decodeHybridPublicKey(msg['pq']),
              payload: <String, dynamic>{
                'k': 'intro_re',
                'id': introId,
                'lid': made.$1,
                'l': made.$2.toJson(),
              },
            );
            await _route(mark, made.$1, reply, from: null);
          }
        }
      case 'intro_re':
        final Object? introId = msg['id'];
        if (introId is String) {
          await _onIntroLanternBack(
            DatingEnd.profile(sender),
            introId,
            msg['lid'],
            msg['l'],
          );
        }
      case 'intro_l':
        final Object? routeId = msg['id'];
        final DatingLantern? lantern = DatingLantern.fromJson(msg['l']);
        if (routeId is String && routeId == mark && lantern != null) {
          await _onIntroLantern(from, routeId, lantern, msg);
        }
      default:
        await _save();
    }
  }

  Future<void> _onMessage(String sender, Map<String, dynamic> msg) async {
    final Object? text = msg['t'];
    final Object? lineId = msg['id'];
    final Uint8List? pair = unb64(_pairKeys[sender]);
    if (!_matches.containsKey(sender) ||
        pair == null ||
        text is! String ||
        lineId is! String ||
        lineId.length > 40 ||
        msg['mac'] != datingMessageMac(pair, lineId, text)) {
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
/// key (hybrid: its X25519 half is the lantern, its ML-KEM half goes out in
/// match test answers), whether it was made for an introduction, and how
/// many match tests it answered per friend the questions came through
/// (`n|address` from the friend itself, `f|address` through them, `x` for
/// an introduction).
final class _OwnLantern {
  _OwnLantern({
    required this.at,
    required this.box,
    this.intro = false,
    Map<String, int>? asks,
  }) : asks = asks ?? <String, int>{};

  final int at;
  final RelayIdentity box;
  final bool intro;
  final Map<String, int> asks;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': at,
    'k': box.toJson(),
    if (intro) 'x': true,
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
      intro: json['x'] == true,
      asks: <String, int>{
        if (n is Map)
          for (final MapEntry<dynamic, dynamic> e in n.entries)
            if (e.key is String && e.value is int)
              e.key as String: e.value as int,
      },
    );
  }
}
