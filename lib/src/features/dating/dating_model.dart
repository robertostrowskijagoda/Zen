import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';

/// Gender on a dating profile.
enum DatingGender {
  woman('k'),
  man('m'),
  other('i');

  const DatingGender(this.code);

  final String code;

  String get label => switch (this) {
    DatingGender.woman => t('kobieta'),
    DatingGender.man => t('mężczyzna'),
    DatingGender.other => t('inna osoba'),
  };

  static DatingGender? byCode(Object? code) {
    for (final DatingGender g in values) {
      if (g.code == code) {
        return g;
      }
    }
    return null;
  }
}

/// Steps of friendship a lantern travels, and the farthest a person can ask
/// for.
const int kDatingMaxHops = 2;

/// Every gender (the default wish, and "any gender" for new friends).
const Set<DatingGender> kDatingAllGenders = <DatingGender>{
  DatingGender.woman,
  DatingGender.man,
  DatingGender.other,
};

/// What a person is in Dating for: dates, new friends with no romantic
/// intention, or either. A plain status on the dating profile; it is one
/// more private wish in the match test, so a person looking only for
/// friends fits only people open to friends.
enum DatingIntent {
  dates('d'),
  friends('f'),
  both('b');

  const DatingIntent(this.code);

  final String code;

  String get label => switch (this) {
    DatingIntent.dates => t('Randki'),
    DatingIntent.friends => t('Nowi znajomi'),
    DatingIntent.both => t('Randki i znajomi'),
  };

  /// A line under [label].
  String get hint => switch (this) {
    DatingIntent.dates => t('Szukam kogoś na randkę'),
    DatingIntent.friends => t('Bez intencji związkowej'),
    DatingIntent.both => t('Otwarta(-y) na jedno i drugie'),
  };

  /// The ways of meeting this covers: [dates], [friends], or both.
  Set<DatingIntent> get modes => this == DatingIntent.both
      ? const <DatingIntent>{DatingIntent.dates, DatingIntent.friends}
      : <DatingIntent>{this};

  static DatingIntent? byCode(Object? code) {
    for (final DatingIntent i in values) {
      if (i.code == code) {
        return i;
      }
    }
    return null;
  }
}

/// Whom one is looking for.
@immutable
final class DatingWants {
  const DatingWants({
    this.genders = kDatingAllGenders,
    this.hops = kDatingMaxHops,
    this.intent = DatingIntent.dates,
    this.friendGenders = kDatingAllGenders,
  });

  /// Wanted genders for dates.
  final Set<DatingGender> genders;

  /// How far in the friendship graph (1–[kDatingMaxHops] steps).
  final int hops;

  /// Dates, new friends, or both.
  final DatingIntent intent;

  /// Wanted genders for new friends (any, unless the person narrows it).
  final Set<DatingGender> friendGenders;

  /// The wanted genders for one way of meeting ([DatingIntent.dates] or
  /// [DatingIntent.friends]).
  Set<DatingGender> gendersFor(DatingIntent mode) =>
      mode == DatingIntent.friends ? friendGenders : genders;

  /// Whether this person looks for someone of [gender] in [mode].
  bool acceptsIn(DatingIntent mode, DatingGender gender) =>
      intent.modes.contains(mode) && gendersFor(mode).contains(gender);

  /// Whether this person looks for someone of [gender] at [distance] in any
  /// way.
  bool accepts({required DatingGender gender, required int distance}) =>
      distance <= hops &&
      intent.modes.any((DatingIntent m) => acceptsIn(m, gender));

  /// The ways ([DatingIntent.dates], [DatingIntent.friends]) in which this
  /// person (of gender [own]) and someone of gender [other] who wants
  /// [theirs] fit each other: both look for it and each is someone the other
  /// wants for it. Empty: they do not fit. [distance] (when given) must be
  /// within both people's reach.
  Set<DatingIntent> sharedWith({
    required DatingGender own,
    required DatingGender other,
    required DatingWants theirs,
    int? distance,
  }) {
    if (distance != null && (distance > hops || distance > theirs.hops)) {
      return const <DatingIntent>{};
    }
    return <DatingIntent>{
      for (final DatingIntent m in intent.modes)
        if (acceptsIn(m, other) && theirs.acceptsIn(m, own)) m,
    };
  }

  /// What the owner of a lantern puts into the private match test: "a
  /// person of gender [own] looking, in mode m, for gender g", for every
  /// mode of [intent] and every gender wanted in it (at most 2 × 3 tags, the
  /// match test's slots).
  Set<String> offerTags(DatingGender own) => <String>{
    for (final DatingIntent m in intent.modes)
      for (final DatingGender g in gendersFor(m))
        '${m.code}:${own.code}>${g.code}',
  };

  /// What a person of gender [own] asks the match test with: "a person of
  /// gender g looking, in mode m, for [own]", for every mode and wanted g.
  /// A tag is common to [offerTags] of the other side exactly when both look
  /// for the same mode and fit each other in it.
  Set<String> seekTags(DatingGender own) => <String>{
    for (final DatingIntent m in intent.modes)
      for (final DatingGender g in gendersFor(m))
        '${m.code}:${g.code}>${own.code}',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'g': <String>[for (final DatingGender g in genders) g.code],
    'hops': hops,
    'i': intent.code,
    'fg': <String>[for (final DatingGender g in friendGenders) g.code],
  };

  static Set<DatingGender> _gendersFromJson(Object? g) => <DatingGender>{
    if (g is List)
      for (final Object? c in g)
        if (DatingGender.byCode(c) != null) DatingGender.byCode(c)!,
  };

  static DatingWants fromJson(Object? json) {
    if (json is! Map) {
      return const DatingWants();
    }
    final Set<DatingGender> genders = _gendersFromJson(json['g']);
    final Set<DatingGender> friendGenders = _gendersFromJson(json['fg']);
    return DatingWants(
      genders: genders.isEmpty ? kDatingAllGenders : genders,
      hops: json['hops'] is int
          ? (json['hops'] as int).clamp(1, kDatingMaxHops)
          : kDatingMaxHops,
      intent: DatingIntent.byCode(json['i']) ?? DatingIntent.dates,
      friendGenders: friendGenders.isEmpty ? kDatingAllGenders : friendGenders,
    );
  }
}

/// Interests a person can mark on the dating profile (codes; the labels
/// are [datingInterestLabel]).
const List<String> kDatingInterests = <String>[
  'mountains',
  'sea',
  'bike',
  'running',
  'gym',
  'dance',
  'music',
  'concerts',
  'films',
  'series',
  'books',
  'boardgames',
  'videogames',
  'cooking',
  'travel',
  'photo',
  'art',
  'animals',
  'volunteering',
  'tech',
];

/// Interests on one profile, at most.
const int kDatingMaxInterests = 8;

String datingInterestLabel(String code) => switch (code) {
  'mountains' => t('góry'),
  'sea' => t('morze'),
  'bike' => t('rower'),
  'running' => t('bieganie'),
  'gym' => t('siłownia'),
  'dance' => t('taniec'),
  'music' => t('muzyka'),
  'concerts' => t('koncerty'),
  'films' => t('kino'),
  'series' => t('seriale'),
  'books' => t('książki'),
  'boardgames' => t('planszówki'),
  'videogames' => t('gry wideo'),
  'cooking' => t('gotowanie'),
  'travel' => t('podróże'),
  'photo' => t('fotografia'),
  'art' => t('sztuka'),
  'animals' => t('zwierzęta'),
  'volunteering' => t('wolontariat'),
  'tech' => t('technologia'),
  _ => code,
};

/// Known interest codes out of [json], in the order of [kDatingInterests],
/// at most [kDatingMaxInterests].
List<String> datingInterestsFromJson(Object? json) {
  final Set<Object?> got = json is List ? json.toSet() : const <Object?>{};
  return <String>[
    for (final String c in kDatingInterests)
      if (got.contains(c)) c,
  ].take(kDatingMaxInterests).toList();
}

/// What this person wants to see among the new profiles. Kept on this
/// phone only and never sent: the distance is applied in the match test by
/// asking with fillers only (which looks exactly like not fitting), the rest
/// to the profiles this phone receives. Narrowing the asked wishes instead
/// would tell the owner of a fitting lantern the filter, since the proof of
/// fit reveals the question's blinding secret.
@immutable
final class DatingFilter {
  const DatingFilter({
    this.intent,
    this.hops = kDatingMaxHops,
    this.genders = kDatingAllGenders,
    this.interests = const <String>{},
    this.withPhoto = false,
    this.minMutual = 0,
  });

  /// Only people one fits in this way ([DatingIntent.dates] or
  /// [DatingIntent.friends]); `null`: any.
  final DatingIntent? intent;

  /// Only people this many steps away at most (1–[kDatingMaxHops]).
  final int hops;

  /// Only people of these genders.
  final Set<DatingGender> genders;

  /// Only people with at least one of these interests (empty: any).
  final Set<String> interests;

  /// Only profiles with a photo.
  final bool withPhoto;

  /// Only people with at least this many mutual friends.
  final int minMutual;

  /// How many of the criteria narrow anything.
  int get active =>
      (intent == null ? 0 : 1) +
      (hops < kDatingMaxHops ? 1 : 0) +
      (genders.length < kDatingAllGenders.length ? 1 : 0) +
      (interests.isEmpty ? 0 : 1) +
      (withPhoto ? 1 : 0) +
      (minMutual > 0 ? 1 : 0);

  /// Whether a profile passes. [modes] are the ways the two fit each other
  /// ([DatingWants.sharedWith]), [mutual] the number of mutual friends.
  bool passes(SeenProfile s, {required Set<DatingIntent> modes}) {
    final DatingProfile p = s.profile;
    return (intent == null || modes.contains(intent)) &&
        // An introduced person (distance unknown) came through a friend.
        (s.distance == 0 || s.distance <= hops) &&
        genders.contains(p.gender) &&
        (interests.isEmpty || p.interests.any(interests.contains)) &&
        (!withPhoto || p.photos.isNotEmpty) &&
        s.mutual.length >= minMutual;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (intent != null) 'i': intent!.code,
    'hops': hops,
    'g': <String>[for (final DatingGender g in genders) g.code],
    'it': interests.toList(),
    if (withPhoto) 'ph': true,
    if (minMutual > 0) 'mm': minMutual,
  };

  static DatingFilter fromJson(Object? json) {
    if (json is! Map) {
      return const DatingFilter();
    }
    final DatingIntent? intent = DatingIntent.byCode(json['i']);
    final Set<DatingGender> genders = DatingWants._gendersFromJson(json['g']);
    final Object? mm = json['mm'];
    return DatingFilter(
      intent: intent == DatingIntent.both ? null : intent,
      hops: json['hops'] is int
          ? (json['hops'] as int).clamp(1, kDatingMaxHops)
          : kDatingMaxHops,
      genders: genders.isEmpty ? kDatingAllGenders : genders,
      interests: datingInterestsFromJson(json['it']).toSet(),
      withPhoto: json['ph'] == true,
      minMutual: mm is int ? mm.clamp(0, 50) : 0,
    );
  }
}

/// A lantern: the small thing every phone sends its friends every
/// week, with dating on or off, passed on up to [kDatingMaxHops] steps. It
/// carries only a one-off key (X25519), new with every lantern: no dating
/// key, nothing about the person, nothing that links it to the lantern of
/// the week before. Whether two people fit is found out in a private match
/// test sealed to this key (`DatingMatch`), so every lantern looks alike,
/// real or not, to everyone who sees or passes it on.
@immutable
final class DatingLantern {
  const DatingLantern(this.key);

  /// The lantern's one-off key (X25519, base64url).
  final String key;

  Map<String, dynamic> toJson() => <String, dynamic>{'v': 4, 'k': key};

  /// `null` for anything that is not a lantern this app makes.
  static DatingLantern? fromJson(Object? json) {
    if (json is! Map || json['v'] != 4) {
      return null;
    }
    final Object? k = json['k'];
    final Uint8List? key = k is String && k.length <= 44
        ? decodeRelayKey(k)
        : null;
    return key == null ? null : DatingLantern(base64Url.encode(key));
  }
}

/// A word from a friend on someone's dating profile.
///
/// A vouch is **signed** by the friend's vouch key (hybrid Ed25519 +
/// ML-DSA-65, kept by their dating service): the signature covers the profile's dating key, the
/// friend's name, the text and the time. So the owner of the profile cannot
/// change the words, and cannot copy them onto another profile. What a
/// signature cannot prove to a stranger three steps away is that the key
/// really belongs to the person named — for that there is "Zapytaj
/// o opinię".
@immutable
final class DatingVouch {
  const DatingVouch({
    required this.id,
    required this.by,
    required this.text,
    required this.signer,
    required this.sig,
    required this.at,
    this.approved = false,
  });

  final String id;
  final String by;
  final String text;

  /// Shown on the profile (the owner accepted it).
  final bool approved;

  /// The friend's vouch key (its Ed25519 id, base64url) and hybrid
  /// signature.
  final String signer;
  final String sig;

  /// When it was written (part of what is signed).
  final int at;

  DatingVouch approve() => DatingVouch(
    id: id,
    by: by,
    text: text,
    approved: true,
    signer: signer,
    sig: sig,
    at: at,
  );

  /// What the friend signs: the words bound to one profile (its dating key).
  static Uint8List signedBytes({
    required String forKey,
    required String by,
    required String text,
    required int at,
  }) => canonicalJsonBytes(<String, dynamic>{
    't': 'zen_date_vouch',
    'for': forKey,
    'by': by,
    'txt': text,
    'at': at,
  });

  /// Signs [text] about the profile with dating key [forKey].
  static Future<DatingVouch> sign({
    required LedgerKeyPair signer,
    required String id,
    required String forKey,
    required String by,
    required String text,
    required int at,
  }) async {
    // Keyed: whoever reads the profile may never have met the signer.
    final Uint8List sig = await signer.signWithKey(
      signedBytes(forKey: forKey, by: by, text: text, at: at),
    );
    return DatingVouch(
      id: id,
      by: by,
      text: text,
      signer: signer.id,
      sig: base64Url.encode(sig),
      at: at,
    );
  }

  /// Whether the signature is good for the profile with dating key
  /// [forKey].
  Future<bool> verify(String forKey) => verifyLedgerSignature(
    publicKey: signer,
    message: signedBytes(forKey: forKey, by: by, text: text, at: at),
    signature: sig,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'by': by,
    't': text,
    if (approved) 'ok': true,
    'vk': signer,
    'sig': sig,
    'at': at,
  };

  /// `null` for anything but a signed vouch of sane size (the name and
  /// text are never cut: that would break the signature).
  static DatingVouch? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? by = json['by'];
    final Object? t = json['t'];
    final Object? vk = json['vk'];
    final Object? sig = json['sig'];
    final Object? at = json['at'];
    if (by is! String ||
        by.length > 60 ||
        t is! String ||
        t.length > 300 ||
        vk is! String ||
        vk.length > 64 ||
        sig is! String ||
        !isHybridSignatureText(sig) ||
        at is! int) {
      return null;
    }
    return DatingVouch(
      id: json['id'] is String ? json['id'] as String : '',
      by: by,
      text: t,
      approved: json['ok'] == true,
      signer: vk,
      sig: sig,
      at: at,
    );
  }
}

/// Photos on a dating profile, at most.
const int kDatingMaxPhotos = 4;

/// Hidden people a profile carries (and a phone reads), at most.
const int kDatingMaxHidden = 500;

List<String> _photosFromJson(Object? photos) => <String>[
  if (photos is List)
    for (final Object? p in photos.take(kDatingMaxPhotos))
      if (p is String && p.length <= 48 * 1024) p,
].take(kDatingMaxPhotos).toList();

/// A dating profile as it travels. It names the dating key, not
/// the account.
@immutable
final class DatingProfile {
  const DatingProfile({
    required this.key,
    required this.name,
    required this.gender,
    required this.at,
    this.about = '',
    this.lookingFor = '',
    this.wants = const DatingWants(),
    this.photos = const <String>[],
    this.interests = const <String>[],
    this.salt = '',
    this.hidden = const <String>[],
    this.vouches = const <DatingVouch>[],
  });

  /// The dating key (X25519, base64url).
  final String key;
  final String name;
  final DatingGender gender;
  final String about;

  /// "Czego szukam".
  final String lookingFor;
  final DatingWants wants;

  /// Small JPEGs, base64 (up to [kDatingMaxPhotos]); the first is the main
  /// one.
  final List<String> photos;

  String? get photo => photos.isEmpty ? null : photos.first;

  /// Interest codes ([kDatingInterests]).
  final List<String> interests;

  /// Salt and hashes of the people it must not be shown to.
  final String salt;
  final List<String> hidden;
  final List<DatingVouch> vouches;
  final int at;

  DatingProfile copyWith({List<String>? photos, List<DatingVouch>? vouches}) =>
      DatingProfile(
        key: key,
        name: name,
        gender: gender,
        at: at,
        about: about,
        lookingFor: lookingFor,
        wants: wants,
        photos: photos ?? this.photos,
        interests: interests,
        salt: salt,
        hidden: hidden,
        vouches: vouches ?? this.vouches,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'k': key,
    'n': name,
    'g': gender.code,
    'ab': about,
    'look': lookingFor,
    'want': wants.toJson(),
    if (photos.isNotEmpty) 'ph': photos,
    if (interests.isNotEmpty) 'it': interests,
    'xs': salt,
    'ex': hidden,
    'vo': <Map<String, dynamic>>[
      for (final DatingVouch v in vouches) v.toJson(),
    ],
    'at': at,
  };

  static String _clip(Object? s, int max) {
    if (s is! String) {
      return '';
    }
    return s.length > max ? s.substring(0, max) : s;
  }

  static DatingProfile? fromJson(Object? json) {
    if (json is! Map ||
        json['v'] != 1 ||
        json['cover'] == true ||
        json['k'] is! String ||
        json['n'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final DatingGender? gender = DatingGender.byCode(json['g']);
    if (gender == null) {
      return null;
    }
    final Object? ex = json['ex'];
    final Object? vo = json['vo'];
    return DatingProfile(
      key: json['k'] as String,
      name: _clip(json['n'], 40),
      gender: gender,
      about: _clip(json['ab'], 1000),
      lookingFor: _clip(json['look'], 300),
      wants: DatingWants.fromJson(json['want']),
      photos: _photosFromJson(json['ph']),
      interests: datingInterestsFromJson(json['it']),
      salt: _clip(json['xs'], 40),
      hidden: ex is List
          ? ex.whereType<String>().take(kDatingMaxHidden).toList()
          : const <String>[],
      vouches: <DatingVouch>[
        if (vo is List)
          for (final Object? v in vo.take(10))
            if (DatingVouch.fromJson(v) != null) DatingVouch.fromJson(v)!,
      ],
      at: json['at'] as int,
    );
  }
}

/// Someone's profile as this phone knows it, with the way to reach them.
final class SeenProfile {
  SeenProfile({
    required this.profile,
    required this.replyTo,
    required this.at,
    this.friend,
    this.path = const <String>[],
    this.distance = 0,
    this.introBy,
    this.introNote,
    this.introPyr,
    this.thankedAt,
    this.lantern,
    List<String>? mutual,
  }) : mutual = mutual ?? <String>[];

  DatingProfile profile;

  /// Where to send to reach them (their package id, or a route mark).
  String replyTo;
  int at;

  /// The friend who passed the profile on (for "Zapytaj o opinię").
  String? friend;

  /// Who passed it on, from their side towards us.
  List<String> path;

  /// Steps of friendship between us (0 = unknown, e.g. introduced).
  int distance;

  /// Introduced by a friend.
  String? introBy;
  String? introNote;

  /// The matchmaker's pyramid key, when they are in a pyramid (for "Podziękuj
  /// swatowi").
  String? introPyr;

  /// When this person thanked the matchmaker with currency.
  int? thankedAt;

  /// The lantern the profile last came with (copies of it passed on by
  /// friends count as [mutual]).
  String? lantern;

  /// Mutual friends (addresses): friends who passed this person's lantern
  /// on to this phone. Counted here only.
  final List<String> mutual;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': profile.toJson(),
    'to': replyTo,
    'at': at,
    if (friend != null) 'f': friend,
    'path': path,
    'd': distance,
    if (introBy != null) 'ib': introBy,
    if (introNote != null) 'in': introNote,
    if (introPyr != null) 'ip': introPyr,
    if (thankedAt != null) 'ty': thankedAt,
    if (lantern != null) 'l': lantern,
    if (mutual.isNotEmpty) 'mu': mutual,
  };

  static SeenProfile? fromJson(Object? json) {
    if (json is! Map || json['to'] is! String || json['at'] is! int) {
      return null;
    }
    final DatingProfile? p = DatingProfile.fromJson(json['p']);
    if (p == null) {
      return null;
    }
    final Object? path = json['path'];
    final Object? mutual = json['mu'];
    return SeenProfile(
      profile: p,
      replyTo: json['to'] as String,
      at: json['at'] as int,
      friend: json['f'] is String ? json['f'] as String : null,
      path: path is List ? path.whereType<String>().toList() : const <String>[],
      distance: json['d'] is int ? json['d'] as int : 0,
      introBy: json['ib'] is String ? json['ib'] as String : null,
      introNote: json['in'] is String ? json['in'] as String : null,
      introPyr: json['ip'] is String ? json['ip'] as String : null,
      thankedAt: json['ty'] is int ? json['ty'] as int : null,
      lantern: json['l'] is String ? json['l'] as String : null,
      mutual: mutual is List ? mutual.whereType<String>().toList() : null,
    );
  }
}

/// One line of a conversation with a match.
@immutable
final class DatingLine {
  const DatingLine({
    required this.id,
    required this.mine,
    required this.text,
    required this.at,
  });

  final String id;
  final bool mine;
  final String text;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (mine) 'mine': true,
    't': text,
    'at': at,
  };

  static DatingLine? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['t'] is! String ||
        json['at'] is! int) {
      return null;
    }
    return DatingLine(
      id: json['id'] as String,
      mine: json['mine'] == true,
      text: json['t'] as String,
      at: json['at'] as int,
    );
  }
}

/// "Co sądzisz o …?" between friends.
final class OpinionAsk {
  OpinionAsk({
    required this.id,
    required this.friend,
    required this.name,
    required this.question,
    required this.at,
    this.mine = false,
    this.photo,
    this.answer,
  });

  final String id;

  /// The friend asked (when [mine]) or asking.
  final String friend;

  /// Whom it is about.
  final String name;
  final String question;
  final int at;
  final bool mine;
  final String? photo;
  String? answer;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'f': friend,
    'n': name,
    'q': question,
    'at': at,
    if (mine) 'mine': true,
    if (photo != null) 'ph': photo,
    if (answer != null) 'a': answer,
  };

  static OpinionAsk? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['f'] is! String ||
        json['n'] is! String ||
        json['q'] is! String ||
        json['at'] is! int) {
      return null;
    }
    return OpinionAsk(
      id: json['id'] as String,
      friend: json['f'] as String,
      name: json['n'] as String,
      question: json['q'] as String,
      at: json['at'] as int,
      mine: json['mine'] == true,
      photo: json['ph'] is String ? json['ph'] as String : null,
      answer: json['a'] is String ? json['a'] as String : null,
    );
  }
}

/// "Idę na randkę": one side shares, the other watches.
final class SafeDate {
  SafeDate({
    required this.id,
    required this.friend,
    required this.until,
    required this.mine,
    this.note = '',
    this.lat,
    this.lon,
    this.locatedAt,
    this.okAt,
    this.remindedAt,
    this.alarmedAt,
    this.autoShare = false,
    this.askedAt,
    this.requestedAt,
  });

  final String id;

  /// The watching friend (when [mine]) or the one on a date.
  final String friend;

  /// "Daj znać do": after it a reminder, 15 minutes later an alarm.
  int until;
  final bool mine;
  final String note;
  double? lat;
  double? lon;
  int? locatedAt;
  int? okAt;
  int? remindedAt;
  int? alarmedAt;

  /// The person on the date agreed beforehand that their phone answers a
  /// friend's request for the location by itself (own dates only).
  final bool autoShare;

  /// Own date: the watching friend asked for the location and the person
  /// has not answered yet.
  int? askedAt;

  /// Watched date: when this person asked for the location.
  int? requestedAt;

  /// Own date: a request for the location waits for an answer.
  bool get locationAsked => mine && askedAt != null && !isOver;

  /// Watched date: the location was asked for and has not come yet.
  bool get locationPending =>
      !mine &&
      requestedAt != null &&
      (locatedAt ?? 0) < requestedAt! &&
      !isOver;

  bool get isOver => okAt != null;

  static const Duration grace = Duration(minutes: 15);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'f': friend,
    'until': until,
    if (mine) 'mine': true,
    'note': note,
    if (lat != null) 'lat': lat,
    if (lon != null) 'lon': lon,
    if (locatedAt != null) 'la': locatedAt,
    if (okAt != null) 'ok': okAt,
    if (remindedAt != null) 'rem': remindedAt,
    if (alarmedAt != null) 'al': alarmedAt,
    if (autoShare) 'as': true,
    if (askedAt != null) 'ask': askedAt,
    if (requestedAt != null) 'req': requestedAt,
  };

  static SafeDate? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['f'] is! String ||
        json['until'] is! int) {
      return null;
    }
    double? d(Object? v) => v is num ? v.toDouble() : null;
    int? i(Object? v) => v is int ? v : null;
    return SafeDate(
      id: json['id'] as String,
      friend: json['f'] as String,
      until: json['until'] as int,
      mine: json['mine'] == true,
      note: json['note'] is String ? json['note'] as String : '',
      lat: d(json['lat']),
      lon: d(json['lon']),
      locatedAt: i(json['la']),
      okAt: i(json['ok']),
      remindedAt: i(json['rem']),
      alarmedAt: i(json['al']),
      autoShare: json['as'] == true,
      askedAt: i(json['ask']),
      requestedAt: i(json['req']),
    );
  }
}

/// This person's own dating settings and profile draft.
final class MyDating {
  MyDating({
    this.enabled = false,
    this.name = '',
    this.gender = DatingGender.other,
    this.about = '',
    this.lookingFor = '',
    this.wants = const DatingWants(),
    List<String>? photos,
    List<String>? interests,
    List<String>? hiddenFriends,
    List<String>? hiddenGroups,
    List<DatingVouch>? vouches,
  }) : photos = photos ?? <String>[],
       interests = interests ?? <String>[],
       hiddenFriends = hiddenFriends ?? <String>[],
       hiddenGroups = hiddenGroups ?? <String>[],
       vouches = vouches ?? <DatingVouch>[];

  bool enabled;
  String name;
  DatingGender gender;
  String about;
  String lookingFor;
  DatingWants wants;

  /// Up to [kDatingMaxPhotos] small JPEGs (base64); the first is the main one.
  final List<String> photos;

  String? get photo => photos.isEmpty ? null : photos.first;

  /// Sets the main photo (`null` removes all).
  set photo(String? value) {
    if (value == null) {
      photos.clear();
    } else if (photos.isEmpty) {
      photos.add(value);
    } else {
      photos[0] = value;
    }
  }

  /// Interest codes ([kDatingInterests], up to [kDatingMaxInterests]).
  final List<String> interests;

  /// Friends (addresses) and chat groups (ids) it is hidden from.
  final List<String> hiddenFriends;
  final List<String> hiddenGroups;
  final List<DatingVouch> vouches;

  bool get complete => name.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (enabled) 'on': true,
    'n': name,
    'g': gender.code,
    'ab': about,
    'look': lookingFor,
    'want': wants.toJson(),
    if (photos.isNotEmpty) 'ph': photos,
    if (interests.isNotEmpty) 'it': interests,
    'hf': hiddenFriends,
    'hg': hiddenGroups,
    'vo': <Map<String, dynamic>>[
      for (final DatingVouch v in vouches) v.toJson(),
    ],
  };

  static MyDating fromJson(Object? json) {
    if (json is! Map) {
      return MyDating();
    }
    final Object? hf = json['hf'];
    final Object? hg = json['hg'];
    final Object? vo = json['vo'];
    return MyDating(
      enabled: json['on'] == true,
      name: json['n'] is String ? json['n'] as String : '',
      gender: DatingGender.byCode(json['g']) ?? DatingGender.other,
      about: json['ab'] is String ? json['ab'] as String : '',
      lookingFor: json['look'] is String ? json['look'] as String : '',
      wants: DatingWants.fromJson(json['want']),
      photos: <String>[
        if (json['ph'] is List) ...(json['ph'] as List).whereType<String>(),
      ].take(kDatingMaxPhotos).toList(),
      interests: datingInterestsFromJson(json['it']),
      hiddenFriends: hf is List ? hf.whereType<String>().toList() : null,
      hiddenGroups: hg is List ? hg.whereType<String>().toList() : null,
      vouches: <DatingVouch>[
        if (vo is List)
          for (final Object? v in vo)
            if (DatingVouch.fromJson(v) != null) DatingVouch.fromJson(v)!,
      ],
    );
  }
}
