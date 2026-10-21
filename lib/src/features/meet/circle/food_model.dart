import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Most portions one offer has.
const int kFoodMaxPortions = 20;

/// Most portions one person asks for at once.
const int kFoodMaxPerRequest = 4;

/// Longest a dish waits to be taken, from "ready from" to "until".
const Duration kFoodMaxWindow = Duration(hours: 48);

/// How far ahead an offer may start.
const Duration kFoodMaxAhead = Duration(days: 7);

const int kFoodMaxTitle = 80;
const int kFoodMaxNote = 300;
const int kFoodMaxPlace = 160;
const int kFoodMaxMoneyLabel = 40;

/// A base64 photo travelling with the offer (a small JPEG, see
/// `compressFlatPhoto`): anything longer is dropped.
const int kFoodMaxPhotoChars = 90 * 1000;

/// Most requests the cook keeps for one offer.
const int kFoodMaxRequests = 50;

/// "Zjedz u mnie" or "Weź na wynos".
enum FoodMode {
  dineIn('in'),
  takeaway('out');

  const FoodMode(this.code);

  final String code;

  String get label => switch (this) {
    FoodMode.dineIn => t('Zjedz u mnie'),
    FoodMode.takeaway => t('Weź na wynos'),
  };

  static FoodMode? byCode(Object? c) =>
      FoodMode.values.where((FoodMode m) => m.code == c).firstOrNull;
}

/// What the one who takes gives back.
enum FoodExchange {
  /// "Za darmo".
  free('free'),

  /// "Dziś Ty, jutro ja": nothing now; both phones count who fed whom.
  swap('swap'),

  /// The pyramid's points, when both are members.
  points('pts'),

  /// An amount agreed between the two; Zen only shows the label and moves
  /// no money.
  money('cash');

  const FoodExchange(this.code);

  final String code;

  String get label => switch (this) {
    FoodExchange.free => t('Za darmo'),
    FoodExchange.swap => t('Dziś Ty, jutro ja'),
    FoodExchange.points => t('Za punkty'),
    FoodExchange.money => t('Za pieniądze'),
  };

  /// Counted in the private give/take balance of a pair.
  bool get reciprocal => this == FoodExchange.free || this == FoodExchange.swap;

  static FoodExchange? byCode(Object? c) =>
      FoodExchange.values.where((FoodExchange x) => x.code == c).firstOrNull;
}

enum FoodDiet {
  vegetarian('veg'),
  vegan('vegan');

  const FoodDiet(this.code);

  final String code;

  String get label => switch (this) {
    FoodDiet.vegetarian => t('Wegetariańskie'),
    FoodDiet.vegan => t('Wegańskie'),
  };

  static FoodDiet? byCode(Object? c) =>
      FoodDiet.values.where((FoodDiet d) => d.code == c).firstOrNull;
}

/// Common allergens the cook marks as present.
enum FoodAllergen {
  gluten('gluten'),
  nuts('nuts'),
  lactose('lactose'),
  eggs('eggs'),
  fish('fish'),
  soy('soy'),
  sesame('sesame');

  const FoodAllergen(this.code);

  final String code;

  String get label => switch (this) {
    FoodAllergen.gluten => t('Gluten'),
    FoodAllergen.nuts => t('Orzechy'),
    FoodAllergen.lactose => t('Laktoza'),
    FoodAllergen.eggs => t('Jajka'),
    FoodAllergen.fish => t('Ryby i owoce morza'),
    FoodAllergen.soy => t('Soja'),
    FoodAllergen.sesame => t('Sezam'),
  };

  static FoodAllergen? byCode(Object? c) =>
      FoodAllergen.values.where((FoodAllergen a) => a.code == c).firstOrNull;
}

/// What the cook said about allergens: an offer always says something,
/// even "Brak informacji".
enum FoodAllergenInfo {
  /// [FoodOffer.allergens] lists what is in it.
  listed('listed'),

  /// None of the common allergens.
  none('none'),

  /// "Brak informacji".
  unknown('unknown');

  const FoodAllergenInfo(this.code);

  final String code;

  static FoodAllergenInfo? byCode(Object? c) => FoodAllergenInfo.values
      .where((FoodAllergenInfo a) => a.code == c)
      .firstOrNull;
}

/// Who sees an offer.
enum FoodReach {
  /// The members of the circle it was made in.
  circle('circle'),

  /// The circle and the cook's friends.
  friends('friends'),

  /// Also the friends of the cook's friends, passed on by them.
  friendsOfFriends('fof');

  const FoodReach(this.code);

  final String code;

  String get label => switch (this) {
    FoodReach.circle => t('Kółko'),
    FoodReach.friends => t('Kółko i znajomi'),
    FoodReach.friendsOfFriends => t('Też znajomi znajomych'),
  };

  /// Unknown codes fall back to the narrowest reach.
  static FoodReach byCode(Object? c) =>
      FoodReach.values.where((FoodReach r) => r.code == c).firstOrNull ??
      FoodReach.circle;
}

enum FoodRequestState {
  pending,
  accepted,
  declined,

  /// Handed over (the cook confirmed).
  done,

  /// Accepted, but never came (only the cook knows).
  noShow,

  /// Taken back by the one who asked.
  cancelled;

  static FoodRequestState byName(Object? n) =>
      FoodRequestState.values
          .where((FoodRequestState s) => s.name == n)
          .firstOrNull ??
      FoodRequestState.pending;

  /// Holds portions of the offer.
  bool get holds =>
      this == FoodRequestState.accepted || this == FoodRequestState.done;
}

String _clip(Object? v, int max) {
  if (v is! String) {
    return '';
  }
  final String s = v.trim();
  return s.length > max ? s.substring(0, max) : s;
}

Set<T> _codes<T>(Object? raw, T? Function(Object?) by) => <T>{
  if (raw is List)
    for (final Object? c in raw.take(16))
      if (by(c) case final T v) v,
};

/// "Biorę": one person's request for portions of an offer. The cook keeps
/// one per person; the one who asked keeps their own (with the place once
/// accepted).
@immutable
final class FoodRequest {
  const FoodRequest({
    required this.address,
    required this.name,
    required this.portions,
    required this.mode,
    required this.exchange,
    required this.at,
    this.state = FoodRequestState.pending,
    this.via,
    this.pyramidKey,
    this.paid = false,
    this.payment,
    this.place = '',
  });

  /// Who asks (on the cook's phone) or the cook (on the asker's phone).
  final String address;
  final String name;
  final int portions;
  final FoodMode mode;
  final FoodExchange exchange;
  final int at;
  final FoodRequestState state;

  /// The friend the request came through (a friend of a friend).
  final String? via;

  /// The asker's pyramid key, for "Za punkty".
  final String? pyramidKey;

  /// "Za punkty", on the asker's phone: the payment order went out.
  final bool paid;

  /// "Za punkty": the payment order's id (on the cook's phone as the asker
  /// named it; paid only once it is in the pyramid, `FoodService.pointsIn`).
  final String? payment;

  /// On the asker's phone, once accepted: where to come.
  final String place;

  FoodRequest copyWith({
    FoodRequestState? state,
    bool? paid,
    String? payment,
    String? place,
  }) => FoodRequest(
    address: address,
    name: name,
    portions: portions,
    mode: mode,
    exchange: exchange,
    at: at,
    state: state ?? this.state,
    via: via,
    pyramidKey: pyramidKey,
    paid: paid ?? this.paid,
    payment: payment ?? this.payment,
    place: place ?? this.place,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    'n': name,
    'p': portions,
    'm': mode.code,
    'x': exchange.code,
    't': at,
    's': state.name,
    'v': ?via,
    'pk': ?pyramidKey,
    if (paid) 'paid': true,
    'pay': ?payment,
    if (place.isNotEmpty) 'pl': place,
  };

  static FoodRequest? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String || json['t'] is! int) {
      return null;
    }
    final FoodMode? mode = FoodMode.byCode(json['m']);
    final FoodExchange? exchange = FoodExchange.byCode(json['x']);
    final Object? p = json['p'];
    if (mode == null || exchange == null || p is! int) {
      return null;
    }
    final Object? via = json['v'];
    final Object? pk = json['pk'];
    final Object? pay = json['pay'];
    return FoodRequest(
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      name: _clip(json['n'], 60),
      portions: p.clamp(1, kFoodMaxPerRequest),
      mode: mode,
      exchange: exchange,
      at: json['t'] as int,
      state: FoodRequestState.byName(json['s']),
      via: via is String ? PeerShareCodec.normalizeAddress(via) : null,
      pyramidKey: pk is String && pk.isNotEmpty && pk.length <= 200 ? pk : null,
      paid: json['paid'] == true,
      payment: pay is String && pay.isNotEmpty && pay.length <= 200
          ? pay
          : null,
      place: _clip(json['pl'], kFoodMaxPlace),
    );
  }
}

/// "Podziel się jedzeniem": a dish a member of a dinner circle shares.
///
/// The copy that travels has no place and no requests: the place goes only
/// to the people the cook accepts, and the requests stay on the cook's
/// phone ([toJson] with `private`).
@immutable
final class FoodOffer {
  const FoodOffer({
    required this.id,
    required this.cook,
    required this.cookName,
    required this.circleId,
    required this.circleName,
    required this.title,
    required this.portions,
    required this.readyFrom,
    required this.readyUntil,
    required this.modes,
    required this.exchanges,
    required this.allergenInfo,
    this.note = '',
    this.photo,
    int? left,
    this.diet = const <FoodDiet>{},
    this.allergens = const <FoodAllergen>{},
    this.points = 0,
    this.moneyLabel = '',
    this.pyramidKey,
    this.pyramid,
    this.reach = FoodReach.circle,
    this.closed = false,
    this.updatedAt = 0,
    this.place = '',
    this.requests = const <String, FoodRequest>{},
  }) : left = left ?? portions;

  final String id;

  /// The cook's address.
  final String cook;
  final String cookName;
  final String circleId;
  final String circleName;
  final String title;
  final String note;

  /// A small JPEG, base64.
  final String? photo;
  final int portions;

  /// Portions not yet given to anyone (the cook counts them).
  final int left;
  final int readyFrom;

  /// After this the offer closes by itself.
  final int readyUntil;
  final Set<FoodMode> modes;
  final Set<FoodExchange> exchanges;
  final Set<FoodDiet> diet;
  final Set<FoodAllergen> allergens;
  final FoodAllergenInfo allergenInfo;

  /// "Za punkty": points per portion, in hundredths.
  final int points;

  /// "Za pieniądze": what was agreed, e.g. "10 zł za porcję".
  final String moneyLabel;

  /// The cook's pyramid key and pyramid, for "Za punkty".
  final String? pyramidKey;
  final String? pyramid;
  final FoodReach reach;

  /// Closed by the cook, or everything handed over.
  final bool closed;
  final int updatedAt;

  /// On the cook's phone only: where to come.
  final String place;

  /// On the cook's phone only: requests by the asker's address.
  final Map<String, FoodRequest> requests;

  /// Whether the cook said what they had to say about allergens.
  static bool allergensConsidered(
    FoodAllergenInfo? info,
    Set<FoodAllergen> allergens,
  ) =>
      info != null && (info != FoodAllergenInfo.listed || allergens.isNotEmpty);

  /// Whether one can still ask for a portion at [now].
  bool openAt(int now) => !closed && now < readyUntil && left > 0;

  /// Past its time ("expiry closes it").
  bool expiredAt(int now) => now >= readyUntil;

  /// Points for [n] portions.
  int pointsFor(int n) => points * n;

  /// Portions that accepted or handed-over requests hold.
  int get held => requests.values
      .where((FoodRequest r) => r.state.holds)
      .fold(0, (int s, FoodRequest r) => s + r.portions);

  /// Accepted requests not yet handed over.
  Iterable<FoodRequest> get waiting => requests.values.where(
    (FoodRequest r) => r.state == FoodRequestState.accepted,
  );

  bool isBy(String address) => PeerShareCodec.addressesEqual(cook, address);

  FoodOffer copyWith({
    int? left,
    bool? closed,
    int? updatedAt,
    Map<String, FoodRequest>? requests,
    String? cook,
  }) => FoodOffer(
    id: id,
    cook: cook ?? this.cook,
    cookName: cookName,
    circleId: circleId,
    circleName: circleName,
    title: title,
    note: note,
    photo: photo,
    portions: portions,
    left: left ?? this.left,
    readyFrom: readyFrom,
    readyUntil: readyUntil,
    modes: modes,
    exchanges: exchanges,
    diet: diet,
    allergens: allergens,
    allergenInfo: allergenInfo,
    points: points,
    moneyLabel: moneyLabel,
    pyramidKey: pyramidKey,
    pyramid: pyramid,
    reach: reach,
    closed: closed ?? this.closed,
    updatedAt: updatedAt ?? this.updatedAt,
    place: place,
    requests: requests ?? this.requests,
  );

  Map<String, dynamic> toJson({bool private = false}) => <String, dynamic>{
    'id': id,
    'cook': cook,
    'cn': cookName,
    'ci': circleId,
    'cin': circleName,
    'title': title,
    if (note.isNotEmpty) 'note': note,
    'ph': ?photo,
    'por': portions,
    'left': left,
    'from': readyFrom,
    'until': readyUntil,
    'modes': <String>[for (final FoodMode m in modes) m.code],
    'ex': <String>[for (final FoodExchange x in exchanges) x.code],
    if (diet.isNotEmpty)
      'diet': <String>[for (final FoodDiet d in diet) d.code],
    if (allergens.isNotEmpty)
      'alg': <String>[for (final FoodAllergen a in allergens) a.code],
    'ai': allergenInfo.code,
    if (points > 0) 'pts': points,
    if (moneyLabel.isNotEmpty) 'cash': moneyLabel,
    'pk': ?pyramidKey,
    'py': ?pyramid,
    'reach': reach.code,
    if (closed) 'closed': true,
    'upd': updatedAt,
    if (private && place.isNotEmpty) 'place': place,
    if (private && requests.isNotEmpty)
      'req': <Map<String, dynamic>>[
        for (final FoodRequest r in requests.values) r.toJson(),
      ],
  };

  /// Reads an offer; with [private] (this phone's own copy from disk) also
  /// the place and the requests. `null` for anything that is not a valid
  /// offer: no allergen information, no way to take it, no exchange.
  static FoodOffer? fromJson(Object? json, {bool private = false}) {
    if (json is! Map ||
        json['id'] is! String ||
        json['cook'] is! String ||
        json['ci'] is! String ||
        json['por'] is! int ||
        json['from'] is! int ||
        json['until'] is! int) {
      return null;
    }
    final String id = json['id'] as String;
    final String title = _clip(json['title'], kFoodMaxTitle);
    final Set<FoodMode> modes = _codes(json['modes'], FoodMode.byCode);
    final Set<FoodExchange> exchanges = _codes(json['ex'], FoodExchange.byCode);
    final Set<FoodAllergen> allergens = _codes(
      json['alg'],
      FoodAllergen.byCode,
    );
    final FoodAllergenInfo? info = FoodAllergenInfo.byCode(json['ai']);
    final int from = json['from'] as int;
    final int until = json['until'] as int;
    if (id.isEmpty ||
        id.length > 40 ||
        title.isEmpty ||
        modes.isEmpty ||
        exchanges.isEmpty ||
        !allergensConsidered(info, allergens) ||
        until <= from ||
        until - from > kFoodMaxWindow.inMilliseconds) {
      return null;
    }
    final int portions = (json['por'] as int).clamp(1, kFoodMaxPortions);
    final Object? left = json['left'];
    final Object? pts = json['pts'];
    final Object? pk = json['pk'];
    final Object? py = json['py'];
    final Object? photo = json['ph'];
    final int points = pts is int ? pts.clamp(0, 100000000) : 0;
    final String? pyramidKey = pk is String && pk.isNotEmpty && pk.length <= 200
        ? pk
        : null;
    // "Za punkty" only with a price and the cook's key.
    if (points <= 0 || pyramidKey == null) {
      exchanges.remove(FoodExchange.points);
      if (exchanges.isEmpty) {
        return null;
      }
    }
    final Map<String, FoodRequest> requests = <String, FoodRequest>{
      if (private && json['req'] is List)
        for (final Object? r in (json['req'] as List).take(kFoodMaxRequests))
          if (FoodRequest.fromJson(r) case final FoodRequest q) q.address: q,
    };
    return FoodOffer(
      id: id,
      cook: PeerShareCodec.normalizeAddress(json['cook'] as String),
      cookName: _clip(json['cn'], 60),
      circleId: _clip(json['ci'], 40),
      circleName: _clip(json['cin'], 60),
      title: title,
      note: _clip(json['note'], kFoodMaxNote),
      photo:
          photo is String &&
              photo.isNotEmpty &&
              photo.length <= kFoodMaxPhotoChars
          ? photo
          : null,
      portions: portions,
      left: left is int ? left.clamp(0, portions) : portions,
      readyFrom: from,
      readyUntil: until,
      modes: modes,
      exchanges: exchanges,
      diet: _codes(json['diet'], FoodDiet.byCode),
      allergens: info == FoodAllergenInfo.listed
          ? allergens
          : const <FoodAllergen>{},
      allergenInfo: info!,
      points: exchanges.contains(FoodExchange.points) ? points : 0,
      moneyLabel: exchanges.contains(FoodExchange.money)
          ? _clip(json['cash'], kFoodMaxMoneyLabel)
          : '',
      pyramidKey: exchanges.contains(FoodExchange.points) ? pyramidKey : null,
      pyramid: exchanges.contains(FoodExchange.points) && py is String
          ? _clip(py, 200)
          : null,
      reach: FoodReach.byCode(json['reach']),
      closed: json['closed'] == true,
      updatedAt: json['upd'] is int ? json['upd'] as int : 0,
      place: private ? _clip(json['place'], kFoodMaxPlace) : '',
      requests: requests,
    );
  }
}

/// How often two people fed each other through shared food (free and
/// "Dziś Ty, jutro ja"), as this phone counted it. Private: never sent.
@immutable
final class FoodBalance {
  const FoodBalance({this.gave = 0, this.got = 0});

  /// Times this person gave the other one food.
  final int gave;

  /// Times the other one gave this person food.
  final int got;

  bool get isEmpty => gave == 0 && got == 0;
}
