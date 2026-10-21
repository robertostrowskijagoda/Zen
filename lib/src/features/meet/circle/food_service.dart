import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/circle/food_model.dart';
import 'package:zen/src/features/meet/circle/food_points.dart';
import 'package:zen/src/features/meet/circle/food_seal.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_thread.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Payload types of shared food.
abstract final class FoodTypes {
  /// The current copy of an offer (no place, no requests): cook → the
  /// circle and, by reach, friends; for friends of friends one step further
  /// through each friend (`hops`).
  static const String offer = 'food_offer';

  /// "Biorę" (`s` absent, with the request's public key `ek`), "cancel",
  /// "paid" or "chat" (sealed `box`): asker → cook. A friend of a friend
  /// sends it to the friend the offer came through, who passes it on with
  /// `by` (for free seats only once they vouch, `vch`).
  static const String request = 'food_req';

  /// The cook's answer: "ok" (with the place sealed for the asker: `kc`,
  /// `pl`), "no", "done", "chat" (sealed `box`). With `to`, for the friend
  /// in between to pass on.
  static const String answer = 'food_ans';

  static const Set<String> all = <String>{offer, request, answer};
}

/// "Podziel się jedzeniem" in dinner circles: a member offers portions of
/// a dish to their circle (optionally friends, friends of friends), to eat
/// at their place ("Zjedz u mnie") or to take away ("Weź na wynos"), for
/// free, as "Dziś Ty, jutro ja", for pyramid points, or for an amount the
/// two settle themselves (Zen moves no money). People ask for portions,
/// the cook accepts or declines; accepted people get the place, the cook
/// confirms the hand-over. Past "ready until" an offer closes by itself.
///
/// Every message goes between friends or circle members; a friend of a
/// friend talks to the cook through the friend who passed the offer on.
/// The place and the small chat of an accepted request are sealed for the
/// asker alone (food_seal.dart): the friend in between carries only
/// ciphertext.
///
/// "Gotuję dziś — dosiądź się" is an offer of seats at the cook's table
/// ([FoodOffer.seats], "Zjedz u mnie" only, with or without a circle):
/// friends (or only close friends) see it, friends of friends through a
/// friend who vouches for each of them ([vouch]).
///
/// Private, on this phone only: who fed whom how often ([balanceWith]) and
/// the no-shows the cook marked ([noShowsOf]).
final class FoodService extends ChangeNotifier {
  FoodService({
    required this.host,
    required this.disk,
    required this.circles,
    this.points = const NoFoodPoints(),
    List<String> Function()? closeFriends,
    int Function()? now,
    Random? random,
  }) : _closeFriends = closeFriends ?? (() => const <String>[]),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// This person's close friends ("przyjaciele"), for [FoodReach.close].
  final List<String> Function() _closeFriends;

  /// Who is in which circle (the default audience).
  final CircleService circles;

  /// "Za punkty".
  final FoodPoints points;
  final int Function() _now;
  final Random _random;

  static const String _key = 'meet/food';
  static const int _day = 24 * 3600 * 1000;

  /// Offers are kept this long after their time (pickups still confirmed).
  static const int _keepAfter = 2 * _day;

  /// Flood guards: new offers from one sender a day, offers of others kept.
  static const int maxNewPerSenderPerDay = 20;
  static const int maxForeignOffers = 200;

  /// Private counters kept (people).
  static const int _maxPeople = 500;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
  static final RegExp _addressPattern = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

  final Map<String, FoodOffer> _offers = <String, FoodOffer>{};

  /// Someone else's offer that came through a friend (id → that friend).
  final Map<String, String> _via = <String, String>{};

  /// This person's requests for offers of others (offer id → request).
  final Map<String, FoodRequest> _mine = <String, FoodRequest>{};

  /// Offers this phone passed on to its friends, and for whom it passed
  /// requests on (so only their answers go back).
  final Set<String> _forwarded = <String>{};
  final Map<String, Set<String>> _relayed = <String, Set<String>>{};

  /// Offers this person removed (reported): newer copies stay out.
  final Set<String> _hidden = <String>{};

  final Map<String, int> _gave = <String, int>{};
  final Map<String, int> _got = <String, int>{};
  final Map<String, int> _noShows = <String, int>{};

  final Map<String, List<int>> _newFrom = <String, List<int>>{};
  Future<void> _queue = Future<void>.value();

  /// The small chat of each accepted request (offer id | the other one).
  final MeetThreads _threads = MeetThreads();

  /// As the friend in between of free seats: friends of ours who asked,
  /// waiting for "Ręczę" (offer id → who → their request).
  final Map<String, Map<String, Map<String, dynamic>>> _toVouch =
      <String, Map<String, Map<String, dynamic>>>{};

  int get now => _now();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String get _me => _n(host.ownAddress());

  bool isMine(FoodOffer o) => o.isBy(_me);

  FoodOffer? offer(String id) => _offers[id];

  /// Offers on screen: open ones, and this person's own with people still
  /// to hand over to; soonest to end first. With [circleId], only that
  /// circle's.
  List<FoodOffer> offers({String? circleId}) {
    final int t = _now();
    return _offers.values
        .where(
          (FoodOffer o) =>
              (circleId == null || o.circleId == circleId) &&
              ((!o.closed && !o.expiredAt(t)) ||
                  (isMine(o) && o.waiting.isNotEmpty) ||
                  _mine[o.id]?.state == FoodRequestState.accepted),
        )
        .toList()
      ..sort(
        (FoodOffer a, FoodOffer b) => a.readyUntil.compareTo(b.readyUntil),
      );
  }

  /// Offers still open at [now] (for a badge).
  int openCount({String? circleId}) {
    final int t = _now();
    return _offers.values
        .where(
          (FoodOffer o) =>
              (circleId == null || o.circleId == circleId) && o.openAt(t),
        )
        .length;
  }

  /// This person's request for someone else's offer [id].
  FoodRequest? myRequest(String id) => _mine[id];

  /// The friend someone else's offer came through (`null`: from the cook).
  String? viaOf(String id) => _via[id];

  /// Private: how often this person and [address] fed each other.
  FoodBalance balanceWith(String address) {
    final String a = _n(address);
    return FoodBalance(gave: _gave[a] ?? 0, got: _got[a] ?? 0);
  }

  /// Private: how often [address] did not come for accepted food.
  int noShowsOf(String address) => _noShows[_n(address)] ?? 0;

  /// Requests waiting for this person's answer, in all their offers.
  int get pendingForMe => _offers.values
      .where(isMine)
      .expand((FoodOffer o) => o.requests.values)
      .where((FoodRequest r) => r.state == FoodRequestState.pending)
      .length;

  // ---- storage ----

  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final Uint8List? raw = await disk.read(_key);
      _diskUnreadable = false;
      if (raw == null) {
        return;
      }
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return;
      }
      _offers.clear();
      for (final Object? o in (json['offers'] as List?) ?? const <Object?>[]) {
        final FoodOffer? offer = FoodOffer.fromJson(o, private: true);
        if (offer != null) {
          _offers[offer.id] = offer;
        }
      }
      _via.clear();
      (json['via'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is String) {
          _via[k] = v;
        }
      });
      _mine.clear();
      (json['mine'] as Map?)?.forEach((Object? k, Object? v) {
        final FoodRequest? r = FoodRequest.fromJson(v);
        if (k is String && r != null) {
          _mine[k] = r;
        }
      });
      _forwarded
        ..clear()
        ..addAll(
          ((json['fwd'] as List?) ?? const <Object?>[]).whereType<String>(),
        );
      _relayed.clear();
      (json['rel'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _relayed[k] = v.whereType<String>().toSet();
        }
      });
      _hidden
        ..clear()
        ..addAll(
          ((json['hid'] as List?) ?? const <Object?>[]).whereType<String>(),
        );
      void counts(Map<String, int> into, Object? raw) {
        into.clear();
        if (raw is Map) {
          raw.forEach((Object? k, Object? v) {
            if (k is String && v is int && v > 0) {
              into[k] = v;
            }
          });
        }
      }

      counts(_gave, json['gave']);
      counts(_got, json['got']);
      counts(_noShows, json['ns']);
      _threads.readJson(json['chat']);
      _toVouch.clear();
      (json['tv'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          _toVouch[k] = <String, Map<String, dynamic>>{
            for (final MapEntry<dynamic, dynamic> e in v.entries)
              if (e.key is String && e.value is Map<String, dynamic>)
                e.key as String: e.value as Map<String, dynamic>,
          };
        }
      });
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt jedzenia', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    final int cutoff = _now() - _keepAfter;
    _offers.removeWhere((String _, FoodOffer o) => o.readyUntil < cutoff);
    bool gone(String id) => !_offers.containsKey(id);
    _via.removeWhere((String id, String _) => gone(id));
    _mine.removeWhere((String id, FoodRequest _) => gone(id));
    _forwarded.removeWhere(gone);
    _relayed.removeWhere((String id, Set<String> _) => gone(id));
    _toVouch.removeWhere(
      (String id, Map<String, Map<String, dynamic>> _) => gone(id),
    );
    _threads.removeWhere((String key) => gone(key.split('|').first));
    while (_hidden.length > maxForeignOffers) {
      _hidden.remove(_hidden.first);
    }
    for (final Map<String, int> m in <Map<String, int>>[
      _gave,
      _got,
      _noShows,
    ]) {
      while (m.length > _maxPeople) {
        m.remove(m.keys.first);
      }
    }
    await disk.write(
      _key,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'offers': <Map<String, dynamic>>[
              for (final FoodOffer o in _offers.values) o.toJson(private: true),
            ],
            'via': _via,
            'mine': <String, dynamic>{
              for (final MapEntry<String, FoodRequest> e in _mine.entries)
                e.key: e.value.toJson(),
            },
            'fwd': _forwarded.toList(),
            'rel': <String, List<String>>{
              for (final MapEntry<String, Set<String>> e in _relayed.entries)
                e.key: e.value.toList(),
            },
            'hid': _hidden.toList(),
            'gave': _gave,
            'got': _got,
            'ns': _noShows,
            'chat': _threads.toJson(),
            'tv': _toVouch,
          }),
        ),
      ),
    );
    notifyListeners();
  }

  /// Waits for queued incoming work (tests).
  Future<void> get idle => _queue;

  String _newId() => List<String>.generate(
    16,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  int _stamp(FoodOffer o) => max(_now(), o.updatedAt + 1);

  // ---- audience ----

  DinnerCircle? _circleOf(FoodOffer o) => circles.circle(o.circleId);

  bool _inCircle(FoodOffer o, String who) =>
      _circleOf(o)?.hasMember(who) ?? false;

  Set<String> get _close => <String>{
    for (final String f in _closeFriends())
      if (host.isFriend(f)) _n(f),
  };

  /// Whether [who] may see this person's offer [o] directly.
  bool _inAudience(FoodOffer o, String who) =>
      _inCircle(o, who) ||
      switch (o.reach) {
        FoodReach.circle => false,
        FoodReach.close => _close.contains(_n(who)),
        FoodReach.friends || FoodReach.friendsOfFriends => host.isFriend(who),
      };

  /// Everyone who gets this person's offer [o] directly.
  Set<String> _audience(FoodOffer o) {
    final String me = _me;
    return <String>{
      for (final CircleMember m
          in _circleOf(o)?.members ?? const <CircleMember>[])
        if (_n(m.address) != me) _n(m.address),
      if (o.reach == FoodReach.close) ..._close,
      if (o.reach == FoodReach.friends || o.reach == FoodReach.friendsOfFriends)
        for (final String f in host.friends()) _n(f),
      // Those already asking, should the circle have changed under them.
      for (final FoodRequest r in o.requests.values)
        if (r.via == null) r.address,
    };
  }

  /// A name for [who]: from the circle (members need not be friends).
  String _nameOf(FoodOffer o, String who) {
    if (host.isFriend(who)) {
      return host.nameOf(who);
    }
    for (final CircleMember m
        in _circleOf(o)?.members ?? const <CircleMember>[]) {
      if (PeerShareCodec.addressesEqual(m.address, who) && m.name.isNotEmpty) {
        return m.name;
      }
    }
    return host.nameOf(who);
  }

  /// The cook of [o] as this person knows them: a friend or circle member
  /// by the name they have here, anyone else by the name they gave.
  String cookNameOf(FoodOffer o) {
    if (isMine(o)) {
      return t('Ty');
    }
    if (host.isFriend(o.cook) || _inCircle(o, o.cook)) {
      return _nameOf(o, o.cook);
    }
    return o.cookName.isEmpty ? t('Ktoś') : o.cookName;
  }

  /// Friends of ours waiting for "Ręczę" before their request for free
  /// seats goes on: (offer, who, their name).
  List<(FoodOffer, String, String)> get toVouch =>
      <(FoodOffer, String, String)>[
        for (final MapEntry<String, Map<String, Map<String, dynamic>>> o
            in _toVouch.entries)
          if (_offers[o.key] case final FoodOffer offer)
            for (final String who in o.value.keys)
              (offer, who, host.nameOf(who)),
      ];

  // ---- the cook ----

  /// Puts out a dish in circle [circleId]. `null` when something is
  /// missing: a title, a way to take it, an exchange, the allergen
  /// information ("Brak informacji" counts), a sensible time, or, for "Za
  /// punkty", a price and a place in the pyramid.
  ///
  /// With [seats] ("Gotuję dziś — dosiądź się") the portions are seats at
  /// this person's table, eaten there only; [circleId] may then be empty
  /// (no circle: friends, close friends or friends of friends see it).
  Future<FoodOffer?> share({
    required String circleId,
    required String title,
    required int portions,
    required int readyFrom,
    required int readyUntil,
    required Set<FoodMode> modes,
    required Set<FoodExchange> exchanges,
    required FoodAllergenInfo? allergenInfo,
    Set<FoodAllergen> allergens = const <FoodAllergen>{},
    Set<FoodDiet> diet = const <FoodDiet>{},
    String note = '',
    String? photo,
    int pointsPerPortion = 0,
    String moneyLabel = '',
    FoodReach reach = FoodReach.circle,
    String place = '',
    bool seats = false,
  }) async {
    final DinnerCircle? c = circleId.isEmpty ? null : circles.circle(circleId);
    final String name = title.trim();
    final int t = _now();
    final String? myKey = points.myKey;
    final bool withPoints = exchanges.contains(FoodExchange.points);
    if ((c == null && (!seats || circleId.isNotEmpty)) ||
        (c != null && !c.hasMember(_me)) ||
        (c == null && reach == FoodReach.circle) ||
        (seats && (modes.length != 1 || !modes.contains(FoodMode.dineIn))) ||
        name.isEmpty ||
        modes.isEmpty ||
        exchanges.isEmpty ||
        !FoodOffer.allergensConsidered(allergenInfo, allergens) ||
        portions < 1 ||
        portions > kFoodMaxPortions ||
        readyUntil <= t ||
        readyUntil <= readyFrom ||
        readyUntil - readyFrom > kFoodMaxWindow.inMilliseconds ||
        readyFrom > t + kFoodMaxAhead.inMilliseconds ||
        (withPoints && (pointsPerPortion <= 0 || myKey == null)) ||
        (photo != null && photo.length > kFoodMaxPhotoChars)) {
      return null;
    }
    String clip(String s, int n) {
      final String v = s.trim();
      return v.length > n ? v.substring(0, n) : v;
    }

    final FoodOffer o = FoodOffer(
      id: _newId(),
      cook: _me,
      cookName: host.ownName(),
      circleId: c?.id ?? '',
      circleName: c?.name ?? '',
      title: clip(name, kFoodMaxTitle),
      note: clip(note, kFoodMaxNote),
      photo: photo,
      portions: portions,
      readyFrom: readyFrom,
      readyUntil: readyUntil,
      modes: Set<FoodMode>.of(modes),
      exchanges: Set<FoodExchange>.of(exchanges),
      diet: Set<FoodDiet>.of(diet),
      allergens: allergenInfo == FoodAllergenInfo.listed
          ? Set<FoodAllergen>.of(allergens)
          : const <FoodAllergen>{},
      allergenInfo: allergenInfo!,
      points: withPoints ? pointsPerPortion : 0,
      moneyLabel: exchanges.contains(FoodExchange.money)
          ? clip(moneyLabel, kFoodMaxMoneyLabel)
          : '',
      pyramidKey: withPoints ? myKey : null,
      pyramid: withPoints ? points.pyramid : null,
      reach: reach,
      updatedAt: t,
      place: clip(place, kFoodMaxPlace),
      seats: seats,
    );
    _offers[o.id] = o;
    await _save();
    await _broadcast(o);
    return o;
  }

  /// Ends this person's offer [id] now; requests not yet answered are
  /// declined.
  Future<void> close(String id) async {
    final FoodOffer? o = _offers[id];
    if (o == null || !isMine(o) || o.closed) {
      return;
    }
    final List<FoodRequest> pending = <FoodRequest>[
      for (final FoodRequest r in o.requests.values)
        if (r.state == FoodRequestState.pending) r,
    ];
    final FoodOffer closed = o.copyWith(
      closed: true,
      updatedAt: _stamp(o),
      requests: <String, FoodRequest>{
        ...o.requests,
        for (final FoodRequest r in pending)
          r.address: r.copyWith(state: FoodRequestState.declined),
      },
    );
    _offers[id] = closed;
    await _save();
    for (final FoodRequest r in pending) {
      await _answer(closed, r, 'no');
    }
    await _broadcast(closed);
  }

  /// Accepts [who]'s request for this person's offer [id], when the
  /// portions are still there. They get the place.
  Future<bool> accept(String id, String who) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? r = o?.requests[_n(who)];
    if (o == null ||
        r == null ||
        !isMine(o) ||
        r.state != FoodRequestState.pending ||
        o.closed ||
        o.expiredAt(_now()) ||
        r.portions > o.left) {
      return false;
    }
    final Uint8List? key = decodeHybridPublicKey(r.key);
    if (key == null) {
      return false;
    }
    // The place (and the chat) only for the one who asked: sealed to the
    // key of their request, never readable by the friend in between.
    final FoodPlaceSeal seal = await sealFoodPlace(
      offerId: o.id,
      place: o.place,
      publicKey: key,
    );
    final FoodOffer updated = _recount(
      o,
      r.copyWith(state: FoodRequestState.accepted, chat: foodB64(seal.chatKey)),
    );
    _offers[id] = updated;
    await _save();
    await _answer(
      updated,
      r,
      'ok',
      extra: <String, dynamic>{
        'kc': foodB64(seal.kemCiphertext),
        'pl': foodB64(seal.box),
      },
    );
    await _broadcast(updated);
    return true;
  }

  Future<void> decline(String id, String who) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? r = o?.requests[_n(who)];
    if (o == null ||
        r == null ||
        !isMine(o) ||
        r.state != FoodRequestState.pending) {
      return;
    }
    final FoodOffer updated = _recount(
      o,
      r.copyWith(state: FoodRequestState.declined),
    );
    _offers[id] = updated;
    await _save();
    await _answer(updated, r, 'no');
  }

  /// "Odebrane": the food reached [who]. Free and "Dziś Ty, jutro ja"
  /// count in the private balance. Once everything is handed over, the
  /// offer closes.
  Future<void> handedOver(String id, String who) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? r = o?.requests[_n(who)];
    if (o == null ||
        r == null ||
        !isMine(o) ||
        r.state != FoodRequestState.accepted) {
      return;
    }
    FoodOffer updated = _recount(o, r.copyWith(state: FoodRequestState.done));
    if (updated.left == 0 && updated.waiting.isEmpty) {
      updated = updated.copyWith(closed: true);
    }
    if (r.exchange.reciprocal) {
      _gave[r.address] = (_gave[r.address] ?? 0) + 1;
    }
    _offers[id] = updated;
    await _save();
    await _answer(updated, r, 'done');
    await _broadcast(updated);
  }

  /// "Nie przyszło": [who] was accepted but never came. Their portions
  /// are free again; only this phone remembers it (nobody is told).
  Future<void> markNoShow(String id, String who) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? r = o?.requests[_n(who)];
    if (o == null ||
        r == null ||
        !isMine(o) ||
        r.state != FoodRequestState.accepted) {
      return;
    }
    final FoodOffer updated = _recount(
      o,
      r.copyWith(state: FoodRequestState.noShow),
    );
    _noShows[r.address] = (_noShows[r.address] ?? 0) + 1;
    _offers[id] = updated;
    await _save();
    if (!updated.expiredAt(_now())) {
      await _broadcast(updated);
    }
  }

  /// [o] with [r] stored, its portions counted again and a new stamp.
  FoodOffer _recount(FoodOffer o, FoodRequest r) {
    final FoodOffer withReq = o.copyWith(
      requests: <String, FoodRequest>{...o.requests, r.address: r},
    );
    return withReq.copyWith(
      left: (o.portions - withReq.held).clamp(0, o.portions),
      updatedAt: _stamp(o),
    );
  }

  /// Sends the current copy of this person's offer [o] to its audience.
  Future<void> _broadcast(FoodOffer o) async {
    final Map<String, dynamic> json = o.toJson();
    for (final String to in _audience(o)) {
      await _send(to, <String, dynamic>{
        'type': FoodTypes.offer,
        'o': json,
        if (o.reach == FoodReach.friendsOfFriends) 'hops': 1,
      });
    }
  }

  /// The cook's answer to [r], through the friend it came through.
  Future<void> _answer(
    FoodOffer o,
    FoodRequest r,
    String s, {
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{
      ...extra,
      'type': FoodTypes.answer,
      'id': o.id,
      's': s,
    };
    final String? via = r.via;
    if (via == null) {
      await _send(r.address, payload);
    } else {
      await _send(via, <String, dynamic>{...payload, 'to': r.address});
    }
  }

  // ---- the one who takes ----

  /// "Biorę": asks for [portions] of someone else's offer [id], to take in
  /// [mode], given back by [exchange]. "Za punkty" only when this person
  /// can pay the cook in the same pyramid.
  Future<bool> ask(
    String id, {
    required FoodMode mode,
    required FoodExchange exchange,
    int portions = 1,
  }) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? had = _mine[id];
    if (o == null ||
        isMine(o) ||
        !o.openAt(_now()) ||
        !o.modes.contains(mode) ||
        !o.exchanges.contains(exchange) ||
        portions < 1 ||
        portions > min(kFoodMaxPerRequest, o.left) ||
        (had != null && had.state != FoodRequestState.cancelled) ||
        (exchange == FoodExchange.points && !canPayPoints(o))) {
      return false;
    }
    final String? pk = exchange == FoodExchange.points ? points.myKey : null;
    // A key pair of this request: the cook seals the place to it.
    final HybridKeyPair keys = await newFoodRequestKeys();
    _mine[id] = FoodRequest(
      address: o.cook,
      name: o.cookName,
      portions: portions,
      mode: mode,
      exchange: exchange,
      at: _now(),
      via: _via[id],
      pyramidKey: pk,
      seed: foodB64(keys.seed),
    );
    await _save();
    await _send(_via[id] ?? o.cook, <String, dynamic>{
      'type': FoodTypes.request,
      'id': id,
      'n': portions,
      'm': mode.code,
      'x': exchange.code,
      'pk': ?pk,
      'ek': foodB64(keys.publicKey),
    });
    return true;
  }

  /// Whether "Za punkty" works between this person and the cook of [o].
  bool canPayPoints(FoodOffer o) {
    final String? key = o.pyramidKey;
    return o.exchanges.contains(FoodExchange.points) &&
        key != null &&
        points.myKey != null &&
        points.canPay(key, pyramid: o.pyramid);
  }

  /// Takes this person's request for [id] back.
  Future<void> cancelAsk(String id) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? r = _mine[id];
    if (o == null ||
        r == null ||
        (r.state != FoodRequestState.pending &&
            r.state != FoodRequestState.accepted)) {
      return;
    }
    _mine[id] = r.copyWith(state: FoodRequestState.cancelled);
    await _save();
    await _send(_via[id] ?? o.cook, <String, dynamic>{
      'type': FoodTypes.request,
      'id': id,
      's': 'cancel',
    });
  }

  /// "Za punkty", once accepted: sends the cook the points for the
  /// portions (the pyramid's treasurers settle the order). Whether the
  /// order went out.
  Future<bool> payPoints(String id) async {
    final FoodOffer? o = _offers[id];
    final FoodRequest? r = _mine[id];
    final String? key = o?.pyramidKey;
    if (o == null ||
        r == null ||
        key == null ||
        r.exchange != FoodExchange.points ||
        r.state != FoodRequestState.accepted ||
        r.paid ||
        !canPayPoints(o)) {
      return false;
    }
    final String? order = await points.pay(
      key,
      o.pointsFor(r.portions),
      memo: t('Jedzenie: {title}', {'title': o.title}),
      pyramid: o.pyramid,
    );
    if (order == null) {
      return false;
    }
    _mine[id] = r.copyWith(paid: true, payment: order);
    await _save();
    await _send(_via[id] ?? o.cook, <String, dynamic>{
      'type': FoodTypes.request,
      'id': id,
      's': 'paid',
      'x': order,
    });
    return true;
  }

  /// "Za punkty", on the cook's phone: whether [r]'s payment for [o] is in
  /// the pyramid — the order the taker named, from their key, to the cook,
  /// for the portions. The taker's "paid" alone is only their word.
  bool pointsIn(FoodOffer o, FoodRequest r) {
    final String? order = r.payment;
    final String? from = r.pyramidKey;
    return r.exchange == FoodExchange.points &&
        order != null &&
        from != null &&
        points.received(order, from: from, amount: o.pointsFor(r.portions));
  }

  /// Removes someone else's offer [id] from this phone (after a report);
  /// newer copies stay out. A request still open is taken back.
  Future<void> hide(String id) async {
    final FoodOffer? o = _offers[id];
    if (o == null || isMine(o)) {
      return;
    }
    await cancelAsk(id);
    _offers.remove(id);
    _hidden.add(id);
    await _save();
  }

  // ---- incoming ----

  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !FoodTypes.all.contains(type)) {
      return false;
    }
    final Completer<void> done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        final String from = _n(frame.from);
        switch (type) {
          case FoodTypes.offer:
            await _onOffer(from, frame.payload);
          case FoodTypes.request:
            await _onRequest(from, frame.payload);
          default:
            await _onAnswer(from, frame.payload);
        }
      } on Object catch (error, stack) {
        logZenError('Jedzenie', error, stack);
      } finally {
        done.complete();
      }
    });
    await done.future;
    return true;
  }

  /// Whether a new offer from [from] may be taken in (counts it).
  bool _takeNew(String from) {
    final int t = _now();
    final List<int> recent = (_newFrom[from] ??= <int>[])
      ..removeWhere((int at) => t - at > _day);
    final int foreign = _offers.values
        .where((FoodOffer o) => !isMine(o))
        .length;
    if (recent.length >= maxNewPerSenderPerDay || foreign >= maxForeignOffers) {
      return false;
    }
    recent.add(t);
    return true;
  }

  Future<void> _onOffer(String from, Map<String, dynamic> payload) async {
    final FoodOffer? got = FoodOffer.fromJson(payload['o']);
    if (got == null || got.isBy(_me) || _hidden.contains(got.id)) {
      return;
    }
    final FoodOffer? had = _offers[got.id];
    if (had != null && isMine(had)) {
      return;
    }
    final int nowMs = _now();
    if (got.readyFrom > nowMs + kFoodMaxAhead.inMilliseconds + _day ||
        got.readyUntil < nowMs - _keepAfter) {
      return;
    }
    final String cook = got.cook;
    final bool direct = from == cook;
    final bool cookInCircle = _inCircle(got, cook);
    final Object? hops = payload['hops'];
    if (direct) {
      // From the cook: a circle member here, or a friend for a wider reach.
      if (!cookInCircle &&
          !(got.reach != FoodReach.circle && host.isFriend(cook))) {
        return;
      }
    } else if (got.reach != FoodReach.friendsOfFriends ||
        hops != 0 ||
        !host.isFriend(from) ||
        host.isFriend(cook) ||
        cookInCircle ||
        (had != null && _via[got.id] != from)) {
      // A friend's friend's offer passed on by a friend: only for that
      // reach, one step, and not when the cook reaches this phone anyway.
      return;
    }
    if (had != null && (!had.isBy(cook) || had.updatedAt >= got.updatedAt)) {
      return;
    }
    if (had == null && (!_idPattern.hasMatch(got.id) || !_takeNew(from))) {
      return;
    }
    _offers[got.id] = got;
    if (direct) {
      _via.remove(got.id);
    } else {
      _via[got.id] = from;
    }
    final bool forward =
        direct &&
        got.reach == FoodReach.friendsOfFriends &&
        hops is int &&
        hops > 0;
    if (forward) {
      _forwarded.add(got.id);
    }
    await _save();
    if (had == null && got.openAt(nowMs)) {
      final String portions = got.seats
          ? tn(
              got.left,
              one: '{n} wolne miejsce',
              few: '{n} wolne miejsca',
              many: '{n} wolnych miejsc',
            )
          : tn(
              got.left,
              one: '{n} porcja',
              few: '{n} porcje',
              many: '{n} porcji',
            );
      final String until = ZenFormat.dayMonthTime(
        DateTime.fromMillisecondsSinceEpoch(got.readyUntil),
      );
      final Map<String, Object?> who = <String, Object?>{
        'name': cookNameOf(got),
        'title': got.title,
      };
      // Ids start with "circle-": the shade hides such titles when content
      // is hidden (they name people and dishes).
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-food-${got.id}',
          title: got.seats
              ? t('{name} gotuje dziś — dosiądź się: {title}', who)
              : t('{name} dzieli się jedzeniem: {title}', who),
          body: direct
              ? t('{portions} · do {until}', {
                  'portions': portions,
                  'until': until,
                })
              : t('{portions} · do {until} · przez {via}', {
                  'portions': portions,
                  'until': until,
                  'via': host.nameOf(from),
                }),
          createdAtMillis: nowMs,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'food:${got.id}',
        ),
      );
    }
    if (forward) {
      for (final String f in host.friends()) {
        if (_n(f) != cook) {
          await _send(_n(f), <String, dynamic>{
            'type': FoodTypes.offer,
            'o': got.toJson(),
            'hops': 0,
          });
        }
      }
    }
  }

  Future<void> _onRequest(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final FoodOffer? o = id is String ? _offers[id] : null;
    if (o == null) {
      return;
    }
    final Object? by = payload['by'];
    final Object? s = payload['s'];
    if (!isMine(o)) {
      await _relayRequest(o, from, payload);
      return;
    }
    final String who;
    final String name;
    String? via;
    if (by == null) {
      if (!_inAudience(o, from)) {
        return;
      }
      who = from;
      name = _nameOf(o, from);
    } else {
      if (by is! String ||
          o.reach != FoodReach.friendsOfFriends ||
          !_addressPattern.hasMatch(by) ||
          !host.isFriend(from)) {
        return;
      }
      final String b = _n(by);
      final FoodRequest? prior = o.requests[b];
      if (b == _me ||
          b == from ||
          host.isFriend(b) ||
          _inCircle(o, b) ||
          (prior != null && prior.via != from)) {
        return;
      }
      final Object? bn = payload['bn'];
      who = b;
      name = bn is String && bn.trim().isNotEmpty
          ? (bn.trim().length > 60 ? bn.trim().substring(0, 60) : bn.trim())
          : t('Ktoś');
      via = from;
    }
    final FoodRequest? had = o.requests[who];
    if (s == 'cancel') {
      if (had == null ||
          (had.state != FoodRequestState.pending &&
              had.state != FoodRequestState.accepted)) {
        return;
      }
      final bool wasHeld = had.state.holds;
      final FoodOffer updated = _recount(
        o,
        had.copyWith(state: FoodRequestState.cancelled),
      );
      _offers[o.id] = updated;
      await _save();
      if (wasHeld && !updated.expiredAt(_now())) {
        await _broadcast(updated);
      }
      return;
    }
    if (s == 'chat') {
      final Uint8List? key = foodBytes(had?.chat, maxChars: 100);
      final Uint8List? box = foodBytes(payload['box']);
      if (had == null || key == null || box == null) {
        return;
      }
      await _takeChat(o, who, name, key, box, fromCook: false);
      return;
    }
    if (s == 'paid') {
      final Object? x = payload['x'];
      if (had == null ||
          had.exchange != FoodExchange.points ||
          !had.state.holds ||
          had.payment != null ||
          x is! String ||
          x.isEmpty ||
          x.length > 200) {
        return;
      }
      // The order's id only: paid once it is in the pyramid ([pointsIn]).
      _offers[o.id] = o.copyWith(
        requests: <String, FoodRequest>{
          ...o.requests,
          who: had.copyWith(payment: x),
        },
      );
      await _save();
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-food-paid-${o.id}-$who',
          title: t('Punkty za jedzenie: {title}', {'title': o.title}),
          body: t('{name} wysyła {amount} pkt.', {
            'name': name,
            'amount': points.format(o.pointsFor(had.portions)),
          }),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'food:${o.id}',
        ),
      );
      return;
    }
    if (s != null) {
      return;
    }
    // "Biorę" (for free seats through a friend: only once they vouch).
    final Object? n = payload['n'];
    final FoodMode? mode = FoodMode.byCode(payload['m']);
    final FoodExchange? exchange = FoodExchange.byCode(payload['x']);
    final Object? pk = payload['pk'];
    final Object? ek = payload['ek'];
    if (n is! int ||
        n < 1 ||
        n > kFoodMaxPerRequest ||
        mode == null ||
        exchange == null ||
        !o.modes.contains(mode) ||
        !o.exchanges.contains(exchange) ||
        decodeHybridPublicKey(ek) == null ||
        (o.seats && via != null && payload['vch'] != true) ||
        (exchange == FoodExchange.points &&
            (pk is! String || pk.isEmpty || pk.length > 200)) ||
        (had != null && had.state != FoodRequestState.cancelled) ||
        (had == null && o.requests.length >= kFoodMaxRequests)) {
      return;
    }
    final FoodRequest r = FoodRequest(
      address: who,
      name: name,
      portions: n,
      mode: mode,
      exchange: exchange,
      at: _now(),
      via: via,
      pyramidKey: exchange == FoodExchange.points ? pk as String : null,
      key: ek as String,
      vouched: via != null && payload['vch'] == true,
    );
    if (!o.openAt(_now()) || n > o.left) {
      // Nothing (or not enough) left: no, at once.
      await _answer(o, r, 'no');
      return;
    }
    _offers[o.id] = o.copyWith(
      requests: <String, FoodRequest>{...o.requests, who: r},
    );
    await _save();
    final String portions = o.seats
        ? tn(n, one: '{n} miejsce', few: '{n} miejsca', many: '{n} miejsc')
        : tn(n, one: '{n} porcja', few: '{n} porcje', many: '{n} porcji');
    await host.notify(
      RuntimeSystemNotification(
        id: 'circle-food-req-${o.id}-$who',
        title: o.seats
            ? t('{name} chce się dosiąść: {title}', {
                'name': name,
                'title': o.title,
              })
            : t('{name} prosi o jedzenie: {title}', {
                'name': name,
                'title': o.title,
              }),
        body: via == null
            ? '$portions · ${mode.label} · ${exchange.label}'
            : '$portions · ${t('ręczy {name}', {'name': host.nameOf(via)})}',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'food:${o.id}',
      ),
    );
  }

  /// As the friend who passed the offer on: a friend of ours asks through
  /// us. Requests for free seats wait for "Ręczę" ([vouch]); the rest go
  /// on to the cook at once, sealed parts untouched.
  Future<void> _relayRequest(
    FoodOffer o,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final Object? s = payload['s'];
    final Set<String> relayed = _relayed[o.id] ?? <String>{};
    final Map<String, Map<String, dynamic>> waiting =
        _toVouch[o.id] ?? <String, Map<String, dynamic>>{};
    if (payload['by'] != null ||
        !_forwarded.contains(o.id) ||
        _via.containsKey(o.id) ||
        from == o.cook ||
        !host.isFriend(from) ||
        (!relayed.contains(from) &&
            relayed.length + waiting.length >= kFoodMaxRequests)) {
      return;
    }
    if (o.seats && !relayed.contains(from)) {
      if (s == null && !waiting.containsKey(from)) {
        waiting[from] = <String, dynamic>{
          if (payload['n'] is int) 'n': payload['n'],
          if (payload['m'] is String) 'm': payload['m'],
          if (payload['x'] is String) 'x': payload['x'],
          if (payload['pk'] is String) 'pk': payload['pk'],
          if (payload['ek'] is String) 'ek': payload['ek'],
        };
        _toVouch[o.id] = waiting;
        await _save();
        await host.notify(
          RuntimeSystemNotification(
            id: 'circle-food-vouch-${o.id}-$from',
            title: t('{name} chce się dosiąść u {cook}', {
              'name': host.nameOf(from),
              'cook': cookNameOf(o),
            }),
            body: t('„{title}” — ręczysz za tę osobę?', {'title': o.title}),
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'food:${o.id}',
          ),
        );
      } else if (s == 'cancel' && waiting.remove(from) != null) {
        await _save();
      }
      return;
    }
    _relayed[o.id] = relayed..add(from);
    await _save();
    await _send(o.cook, <String, dynamic>{
      'type': FoodTypes.request,
      'id': o.id,
      if (s is String) 's': s,
      if (payload['n'] is int) 'n': payload['n'],
      if (payload['m'] is String) 'm': payload['m'],
      if (payload['x'] is String) 'x': payload['x'],
      if (payload['pk'] is String) 'pk': payload['pk'],
      if (payload['ek'] is String) 'ek': payload['ek'],
      if (payload['box'] is String) 'box': payload['box'],
      'by': from,
      'bn': host.nameOf(from),
    });
  }

  /// "Ręczę" ([yes]) for [who], a friend of ours who wants a seat at the
  /// table of offer [id]: their request goes on to the cook, saying we
  /// vouch. Otherwise they hear "Tym razem nie".
  Future<void> vouch(String id, String who, bool yes) async {
    final FoodOffer? o = _offers[id];
    final String w = _n(who);
    final Map<String, dynamic>? ask = _toVouch[id]?.remove(w);
    if (o == null || ask == null) {
      return;
    }
    if (_toVouch[id]?.isEmpty ?? false) {
      _toVouch.remove(id);
    }
    if (!yes) {
      await _save();
      await _send(w, <String, dynamic>{
        'type': FoodTypes.answer,
        'id': id,
        's': 'no',
      });
      return;
    }
    _relayed[id] = (_relayed[id] ?? <String>{})..add(w);
    await _save();
    await _send(o.cook, <String, dynamic>{
      ...ask,
      'type': FoodTypes.request,
      'id': id,
      'by': w,
      'bn': host.nameOf(w),
      'vch': true,
    });
  }

  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final FoodOffer? o = id is String ? _offers[id] : null;
    final Object? s = payload['s'];
    if (o == null || isMine(o) || s is! String) {
      return;
    }
    final Object? to = payload['to'];
    if (to != null) {
      // As the friend in between: the cook answers a friend of ours. The
      // place and the chat are sealed for them; we only carry them.
      if (to is! String ||
          from != o.cook ||
          !_forwarded.contains(o.id) ||
          !(_relayed[o.id]?.contains(_n(to)) ?? false) ||
          !host.isFriend(to)) {
        return;
      }
      await _send(_n(to), <String, dynamic>{
        'type': FoodTypes.answer,
        'id': o.id,
        's': s,
        for (final String k in <String>['kc', 'pl', 'box'])
          if (payload[k] is String) k: payload[k],
      });
      return;
    }
    final FoodRequest? r = _mine[o.id];
    if (r == null || from != (_via[o.id] ?? o.cook)) {
      return;
    }
    final String cookName = cookNameOf(o);
    switch (s) {
      case 'ok' when r.state == FoodRequestState.pending:
        final Uint8List? seed = foodBytes(r.seed, maxChars: 100);
        final Uint8List? kc = foodBytes(payload['kc']);
        final Uint8List? box = foodBytes(payload['pl']);
        final (String, Uint8List)? opened =
            seed == null || kc == null || box == null
            ? null
            : await openFoodPlace(
                offerId: o.id,
                seed: seed,
                kemCiphertext: kc,
                box: box,
              );
        if (opened == null) {
          logZenWarning('Jedzenie: the place did not open.');
        }
        String place = opened?.$1.trim() ?? '';
        if (place.length > kFoodMaxPlace) {
          place = place.substring(0, kFoodMaxPlace);
        }
        _mine[o.id] = r.copyWith(
          state: FoodRequestState.accepted,
          place: place,
          chat: opened == null ? null : foodB64(opened.$2),
        );
        await _save();
        await host.notify(
          RuntimeSystemNotification(
            id: 'circle-food-ok-${o.id}',
            title: t('Przyjęte: {title}', {'title': o.title}),
            body: t('{name} czeka na Ciebie. Szczegóły w aplikacji.', {
              'name': cookName,
            }),
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'food:${o.id}',
          ),
        );
      case 'no' when r.state == FoodRequestState.pending:
        _mine[o.id] = r.copyWith(state: FoodRequestState.declined);
        await _save();
        await host.notify(
          RuntimeSystemNotification(
            id: 'circle-food-no-${o.id}',
            title: t('Tym razem nie: {title}', {'title': o.title}),
            body: t('{name} nie może tym razem.', {'name': cookName}),
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'food:${o.id}',
          ),
        );
      case 'done' when r.state == FoodRequestState.accepted:
        _mine[o.id] = r.copyWith(state: FoodRequestState.done);
        if (r.exchange.reciprocal) {
          _got[o.cook] = (_got[o.cook] ?? 0) + 1;
        }
        await _save();
      case 'chat':
        final Uint8List? key = foodBytes(r.chat, maxChars: 100);
        final Uint8List? box = foodBytes(payload['box']);
        if (key != null && box != null) {
          await _takeChat(o, o.cook, cookName, key, box, fromCook: true);
        }
    }
  }

  // ---- the small chat of an accepted request ----

  /// The thread of offer [id] with [who] (the cook's side) or with the cook
  /// (the asker's side).
  String _threadKey(FoodOffer o, String? who) =>
      '${o.id}|${isMine(o) ? _n(who ?? '') : o.cook}';

  List<MeetThreadMessage> thread(String id, {String? who}) {
    final FoodOffer? o = _offers[id];
    return o == null
        ? const <MeetThreadMessage>[]
        : _threads.thread(_threadKey(o, who));
  }

  int unread(String id, {String? who}) {
    final FoodOffer? o = _offers[id];
    return o == null ? 0 : _threads.unread(_threadKey(o, who));
  }

  Future<void> markRead(String id, {String? who}) async {
    final FoodOffer? o = _offers[id];
    if (o == null || _threads.unread(_threadKey(o, who)) == 0) {
      return;
    }
    _threads.markRead(_threadKey(o, who), _now());
    await _save();
  }

  /// Whether this person can write about offer [id] (with [who], for the
  /// cook): the request was accepted and its chat key is here.
  bool canChat(String id, {String? who}) {
    final FoodOffer? o = _offers[id];
    if (o == null) {
      return false;
    }
    final FoodRequest? r = isMine(o) ? o.requests[_n(who ?? '')] : _mine[id];
    return r != null && r.state.holds && r.chat != null;
  }

  /// Writes [text] about offer [id] ("Dzwoń domofonem 12", "Spóźnię się
  /// 10 min"): to the cook, or, for the cook, to [who]. Sealed for the two
  /// of them; through the friend in between when there is one.
  Future<bool> sendChat(String id, String text, {String? who}) async {
    final FoodOffer? o = _offers[id];
    final String? clean = cleanThreadText(text);
    if (o == null || clean == null || !canChat(id, who: who)) {
      return false;
    }
    final bool cook = isMine(o);
    final FoodRequest r = cook ? o.requests[_n(who!)]! : _mine[id]!;
    final Uint8List? key = foodBytes(r.chat, maxChars: 100);
    if (key == null) {
      return false;
    }
    final MeetThreadMessage m = MeetThreadMessage(
      id: newThreadMessageId(_random),
      from: _me,
      text: clean,
      at: _now(),
      mine: true,
    );
    final String box = foodB64(
      await sealFoodChat(
        key,
        o.id,
        fromCook: cook,
        json: <String, dynamic>{'m': m.id, 'x': m.text, 't': m.at},
      ),
    );
    _threads
      ..add(_threadKey(o, who), m)
      ..markRead(_threadKey(o, who), m.at);
    await _save();
    if (cook) {
      await _answer(o, r, 'chat', extra: <String, dynamic>{'box': box});
    } else {
      await _send(_via[id] ?? o.cook, <String, dynamic>{
        'type': FoodTypes.request,
        'id': id,
        's': 'chat',
        'box': box,
      });
    }
    return true;
  }

  Future<void> _takeChat(
    FoodOffer o,
    String other,
    String name,
    Uint8List key,
    Uint8List box, {
    required bool fromCook,
  }) async {
    final Map<String, dynamic>? json = await openFoodChat(
      key,
      o.id,
      fromCook: fromCook,
      box: box,
    );
    final Object? mid = json?['m'];
    final Object? text = json?['x'];
    final Object? at = json?['t'];
    if (!isThreadMessageId(mid) || text is! String || at is! int) {
      return;
    }
    final String? clean = cleanThreadText(text);
    final String key2 = '${o.id}|$other';
    if (clean == null ||
        !_threads.add(
          key2,
          MeetThreadMessage(
            id: mid as String,
            from: other,
            text: clean,
            at: min(at, _now() + 10 * 60 * 1000),
          ),
        )) {
      return;
    }
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'circle-food-chat-${o.id}-$mid',
        title: t('{name} · {title}', {'name': name, 'title': o.title}),
        body: clean,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'food-chat:$key2',
      ),
    );
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Jedzenie: do $to: $error');
    }
  }
}
