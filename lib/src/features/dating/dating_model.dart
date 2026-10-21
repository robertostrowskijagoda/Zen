import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

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

/// Steps of friendship a lantern travels: friends, their friends and their
/// friends' friends — no gate needed within them.
const int kDatingMaxHops = 3;

/// The reach past [kDatingMaxHops] plain steps: "dalej przez otwarte bramy",
/// people a lantern reached across a gate this person or someone on the way
/// opened (still at most [kDatingMaxHops] steps).
const int kDatingRangeGates = 4;

/// How far a person is, as one number to compare with a reach: the steps of
/// friendship, or [kDatingRangeGates] when the way crossed an opened gate.
int datingReachOf(int distance, {bool gate = false}) =>
    gate ? kDatingRangeGates : distance;

/// The name of a reach (1–3 steps, or through open gates).
String datingReachLabel(int reach) => switch (reach) {
  1 => t('Moi znajomi'),
  2 => t('Znajomi znajomych'),
  3 => t('3 kroki znajomości'),
  _ => t('Dalej przez otwarte bramy'),
};

int _reachFromJson(Object? json) =>
    json is int ? json.clamp(1, kDatingRangeGates) : kDatingMaxHops;

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

  /// "Jak daleko chcesz widzieć": 1–[kDatingMaxHops] steps of friendship,
  /// or [kDatingRangeGates] (also through open gates). It works both ways:
  /// this person meets only people within it.
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

  /// Whether this person looks for someone of [gender] at reach [distance]
  /// ([datingReachOf]) in any way.
  bool accepts({required DatingGender gender, required int distance}) =>
      distance <= hops &&
      intent.modes.any((DatingIntent m) => acceptsIn(m, gender));

  /// The ways ([DatingIntent.dates], [DatingIntent.friends]) in which this
  /// person (of gender [own]) and someone of gender [other] who wants
  /// [theirs] fit each other: both look for it and each is someone the other
  /// wants for it. Empty: they do not fit. [distance] (a reach, see
  /// [datingReachOf]; when given) must be within both people's reach.
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
    'g': <String>[
      for (final DatingGender g in DatingGender.values)
        if (genders.contains(g)) g.code,
    ],
    'hops': hops,
    'i': intent.code,
    'fg': <String>[
      for (final DatingGender g in DatingGender.values)
        if (friendGenders.contains(g)) g.code,
    ],
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
      hops: _reachFromJson(json['hops']),
      intent: DatingIntent.byCode(json['i']) ?? DatingIntent.dates,
      friendGenders: friendGenders.isEmpty ? kDatingAllGenders : friendGenders,
    );
  }
}

/// Interests on one profile, at most.
const int kDatingMaxInterests = 12;

/// The longest interest, in characters.
const int kDatingTagMaxChars = 24;

/// Interests offered with one tap (anything else can be typed).
List<String> datingTagSuggestions() => <String>[
  t('góry'),
  t('morze'),
  t('rower'),
  t('bieganie'),
  t('siłownia'),
  t('taniec'),
  t('muzyka'),
  t('koncerty'),
  t('kino'),
  t('seriale'),
  t('książki'),
  t('planszówki'),
  t('gry wideo'),
  t('gotowanie'),
  t('podróże'),
  t('fotografia'),
  t('sztuka'),
  t('zwierzęta'),
  t('wolontariat'),
  t('technologia'),
];

/// Letters with marks and their plain form, for comparing interests
/// ([datingTagKey]): "Góry", "gory" and "GÓRY" are the same interest.
const Map<String, String> _plainLetters = <String, String>{
  'ą': 'a',
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'æ': 'ae',
  'ć': 'c',
  'ç': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'ę': 'e',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ě': 'e',
  'ē': 'e',
  'ğ': 'g',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ĺ': 'l',
  'ń': 'n',
  'ñ': 'n',
  'ň': 'n',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'œ': 'oe',
  'ř': 'r',
  'ŕ': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ß': 'ss',
  'ť': 't',
  'ţ': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ů': 'u',
  'ū': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
  'ё': 'е',
  'й': 'и',
};

final RegExp _tagJunk = RegExp(
  '[\\u0000-\\u001f\\u007f\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069#,;]',
);
final RegExp _spaces = RegExp(r'\s+');

/// An interest as a person typed it, made tidy: no control characters, no
/// `#`, commas or semicolons, single spaces, lower case, at most
/// [kDatingTagMaxChars] characters. `null` when nothing is left.
String? datingTag(Object? raw) {
  if (raw is! String) {
    return null;
  }
  final String clean = raw
      .replaceAll(_tagJunk, ' ')
      .replaceAll(_spaces, ' ')
      .trim()
      .toLowerCase();
  if (clean.isEmpty) {
    return null;
  }
  final List<int> runes = clean.runes.toList();
  final String cut = runes.length > kDatingTagMaxChars
      ? String.fromCharCodes(runes.take(kDatingTagMaxChars)).trim()
      : clean;
  return cut.isEmpty ? null : cut;
}

/// What two interests are compared by: [datingTag] without letter marks
/// (case and diacritics do not matter).
String datingTagKey(String tag) {
  final String clean = datingTag(tag) ?? '';
  final StringBuffer out = StringBuffer();
  for (final int r in clean.runes) {
    final String c = String.fromCharCode(r);
    out.write(_plainLetters[c] ?? c);
  }
  return out.toString();
}

/// Interests out of [json]: tidied ([datingTag]), each once (by
/// [datingTagKey], the first spelling stays), at most [kDatingMaxInterests].
List<String> datingTagsFrom(Object? json) {
  final List<String> out = <String>[];
  final Set<String> keys = <String>{};
  if (json is! Iterable) {
    return out;
  }
  for (final Object? raw in json.take(kDatingMaxInterests * 4)) {
    final String? tag = datingTag(raw);
    if (tag != null && keys.add(datingTagKey(tag))) {
      out.add(tag);
      if (out.length >= kDatingMaxInterests) {
        break;
      }
    }
  }
  return out;
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
    this.hops = kDatingRangeGates,
    this.genders = kDatingAllGenders,
    this.interests = const <String>{},
    this.withPhoto = false,
    this.minMutual = 0,
  });

  /// Only people one fits in this way ([DatingIntent.dates] or
  /// [DatingIntent.friends]); `null`: any.
  final DatingIntent? intent;

  /// Only people this far at most (a reach, [datingReachOf]).
  final int hops;

  /// Only people of these genders.
  final Set<DatingGender> genders;

  /// Only people with at least one of these interests (empty: any), compared
  /// by [datingTagKey].
  final Set<String> interests;

  /// Only profiles with a photo.
  final bool withPhoto;

  /// Only people with at least this many mutual friends.
  final int minMutual;

  /// How many of the criteria narrow anything.
  int get active =>
      (intent == null ? 0 : 1) +
      (hops < kDatingRangeGates ? 1 : 0) +
      (genders.length < kDatingAllGenders.length ? 1 : 0) +
      (interests.isEmpty ? 0 : 1) +
      (withPhoto ? 1 : 0) +
      (minMutual > 0 ? 1 : 0);

  /// Whether a profile passes. [modes] are the ways the two fit each other
  /// ([DatingWants.sharedWith]), [mutual] the number of mutual friends.
  bool passes(SeenProfile s, {required Set<DatingIntent> modes}) {
    final DatingProfile p = s.profile;
    final Set<String> wanted = <String>{
      for (final String i in interests) datingTagKey(i),
    };
    return (intent == null || modes.contains(intent)) &&
        // An introduced person (distance unknown) came through a friend.
        (s.distance == 0 || s.reach <= hops) &&
        genders.contains(p.gender) &&
        (wanted.isEmpty ||
            p.interests.any((String i) => wanted.contains(datingTagKey(i)))) &&
        (!withPhoto || p.photoDigests.isNotEmpty) &&
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
          ? (json['hops'] as int).clamp(1, kDatingRangeGates)
          : kDatingRangeGates,
      genders: genders.isEmpty ? kDatingAllGenders : genders,
      interests: datingTagsFrom(json['it']).toSet(),
      withPhoto: json['ph'] == true,
      minMutual: mm is int ? mm.clamp(0, 50) : 0,
    );
  }
}

/// A lantern: the small thing every phone sends its friends every
/// week, with dating on or off, passed on up to [kDatingMaxHops] steps. It
/// carries only the commitment ([hash], SHA-256) to a one-off hybrid key
/// (ML-KEM-768 + X25519), new with every lantern: no dating key, nothing
/// about the person, nothing that links it to the lantern of the week
/// before. Whoever sees it asks the holder for the key itself, checks it
/// against the hash, and runs the private match test (`DatingMatch`)
/// sealed to it — so every lantern looks alike, real or not, to everyone
/// who sees or passes it on, and nothing in it rests on X25519 alone.
@immutable
final class DatingLantern {
  const DatingLantern(this.hash);

  /// SHA-256 of the lantern's one-off keys (base64url, see
  /// `datingLanternHash`).
  final String hash;

  Map<String, dynamic> toJson() => <String, dynamic>{'v': 5, 'h': hash};

  /// `null` for anything that is not a lantern this app makes.
  static DatingLantern? fromJson(Object? json) {
    if (json is! Map || json['v'] != 5) {
      return null;
    }
    final Object? h = json['h'];
    final Uint8List? hash = h is String && h.length <= 44
        ? unb64(h, length: 32)
        : null;
    return hash == null ? null : DatingLantern(base64Url.encode(hash));
  }
}

/// Vouches a profile carries (and a phone reads), at most.
const int kDatingMaxVouches = 50;

/// Vouches waiting for approval or shown, kept on this phone at most.
const int kDatingMaxVouchesKept = 60;

/// Vouches in one part of a profile sent on request.
const int kDatingVouchesPerPart = 6;

/// A word from a friend on someone's dating profile.
///
/// A vouch is **signed** by the friend's vouch key (hybrid Ed25519 +
/// ML-DSA-65, kept by their dating service): the signature covers the
/// profile's dating key, the friend's name, the text and the time. So the
/// owner of the profile cannot change the words, and cannot copy them onto
/// another profile. What a signature cannot prove to a stranger three steps
/// away is that the key really belongs to the person named — for that
/// there is "Zapytaj o opinię".
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

  /// The vouch as it travels (without the owner's approval).
  Map<String, dynamic> wireJson() => <String, dynamic>{
    'id': id,
    'by': by,
    't': text,
    'vk': signer,
    'sig': sig,
    'at': at,
  };

  /// What a profile names the vouch by ([DatingProfile.vouchDigests]).
  String get digest =>
      b64(crypto.sha256.convert(canonicalJsonBytes(wireJson())).bytes);

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...wireJson(),
    if (approved) 'ok': true,
  };

  /// `null` for anything but a signed vouch of sane size (the name and
  /// text are never cut: that would break the signature).
  static DatingVouch? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
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
      id: id is String && id.length <= 40 ? id : '',
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

/// The longest photo (base64 characters).
const int kDatingMaxPhotoChars = 48 * 1024;

/// What a profile names a photo by ([DatingProfile.photoDigests]).
String datingPhotoDigest(String photo) =>
    b64(crypto.sha256.convert(utf8.encode(photo)).bytes);

final RegExp _digest = RegExp(r'^[A-Za-z0-9_-]{43}=$');

List<String> _digestsFromJson(Object? json, int max) => <String>[
  if (json is List)
    for (final Object? d in json.take(max))
      if (d is String && _digest.hasMatch(d)) d,
];

/// A dating profile as it travels. It names the dating key, not the
/// account, and is **signed** by its owner (a hybrid Ed25519 + ML-DSA-65
/// key that belongs to the dating key, [signer]): nobody who passes it on —
/// a matchmaker, a friend on the way — can change a word, a photo or a
/// vouch, and a profile cannot be put on another dating key.
///
/// It travels in two steps: the core (everything but the photos and the
/// vouches, which it names by digest) in one answer of a fixed size, then
/// the photos and the vouches one part at a time, each checked against its
/// digest.
@immutable
final class DatingProfile {
  const DatingProfile({
    required this.key,
    required this.name,
    required this.gender,
    required this.at,
    this.pq = '',
    this.signer = '',
    this.sig = '',
    this.about = '',
    this.lookingFor = '',
    this.wants = const DatingWants(),
    this.interests = const <String>[],
    this.photoDigests = const <String>[],
    this.vouchDigests = const <String>[],
    this.photoSlots = const <String>[],
    this.vouchSlots = const <DatingVouch?>[],
  });

  /// The dating key (X25519, base64url).
  final String key;

  /// The dating key's hybrid (ML-KEM-768 + X25519) half, base64url: what
  /// likes, messages and introductions are sealed to.
  final String pq;

  /// The owner's profile signing key (its Ed25519 id) and the signature.
  final String signer;
  final String sig;

  /// When the owner signed this version (ms since epoch).
  final int at;
  final String name;
  final DatingGender gender;
  final String about;

  /// "Czego szukam".
  final String lookingFor;
  final DatingWants wants;

  /// Interests, as the owner typed them ([datingTag]).
  final List<String> interests;

  /// The photos (up to [kDatingMaxPhotos]) and the vouches (up to
  /// [kDatingMaxVouches]) the signature covers, by digest.
  final List<String> photoDigests;
  final List<String> vouchDigests;

  /// The photos that came, in the order of [photoDigests] ('' for one that
  /// has not come yet).
  final List<String> photoSlots;

  /// The vouches that came and check out, in the order of [vouchDigests].
  final List<DatingVouch?> vouchSlots;

  /// Small JPEGs (base64) that came; the first is the main one.
  List<String> get photos => <String>[
    for (final String p in photoSlots)
      if (p.isNotEmpty) p,
  ];

  String? get photo => photos.isEmpty ? null : photos.first;

  /// Vouches that came and check out.
  List<DatingVouch> get vouches => <DatingVouch>[
    for (final DatingVouch? v in vouchSlots) ?v,
  ];

  /// Whether every photo and vouch the profile names came.
  bool get complete =>
      photos.length == photoDigests.length &&
      vouches.length == vouchDigests.length;

  /// What the owner signs.
  Map<String, dynamic> core() => <String, dynamic>{
    't': 'zen_date_profile',
    'k': key,
    'q': pq,
    'sk': signer,
    'n': name,
    'g': gender.code,
    'ab': about,
    'look': lookingFor,
    'want': wants.toJson(),
    'it': interests,
    'phd': photoDigests,
    'vod': vouchDigests,
    'at': at,
  };

  /// The core with its signature: what goes out in an answer.
  Map<String, dynamic> wireJson() => <String, dynamic>{...core(), 'sig': sig};

  /// As kept on this phone: with the photos and vouches that came.
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...wireJson(),
    if (photoSlots.any((String p) => p.isNotEmpty)) 'ph': photoSlots,
    if (vouchSlots.any((DatingVouch? v) => v != null))
      'vo': <Object?>[for (final DatingVouch? v in vouchSlots) v?.toJson()],
  };

  DatingProfile copyWith({
    List<String>? photoSlots,
    List<DatingVouch?>? vouchSlots,
  }) => DatingProfile(
    key: key,
    pq: pq,
    signer: signer,
    sig: sig,
    name: name,
    gender: gender,
    at: at,
    about: about,
    lookingFor: lookingFor,
    wants: wants,
    interests: interests,
    photoDigests: photoDigests,
    vouchDigests: vouchDigests,
    photoSlots: photoSlots ?? this.photoSlots,
    vouchSlots: vouchSlots ?? this.vouchSlots,
  );

  /// The same profile with the photos and vouches of [had] that it still
  /// names (a refreshed profile does not fetch them again).
  DatingProfile withPartsOf(DatingProfile? had) {
    if (had == null) {
      return this;
    }
    final Map<String, String> photosByDigest = <String, String>{
      for (int i = 0; i < had.photoDigests.length; i++)
        if (i < had.photoSlots.length && had.photoSlots[i].isNotEmpty)
          had.photoDigests[i]: had.photoSlots[i],
    };
    final Map<String, DatingVouch> vouchesByDigest = <String, DatingVouch>{
      for (int i = 0; i < had.vouchDigests.length; i++)
        if (i < had.vouchSlots.length && had.vouchSlots[i] != null)
          had.vouchDigests[i]: had.vouchSlots[i]!,
    };
    return copyWith(
      photoSlots: <String>[
        for (final String d in photoDigests) photosByDigest[d] ?? '',
      ],
      vouchSlots: <DatingVouch?>[
        for (final String d in vouchDigests) vouchesByDigest[d],
      ],
    );
  }

  /// Signs a profile ([key] and the rest) with the owner's [signerKey].
  static Future<DatingProfile> sign({
    required LedgerKeyPair signerKey,
    required String key,
    required String pq,
    required String name,
    required DatingGender gender,
    required int at,
    String about = '',
    String lookingFor = '',
    DatingWants wants = const DatingWants(),
    List<String> interests = const <String>[],
    List<String> photos = const <String>[],
    List<DatingVouch> vouches = const <DatingVouch>[],
  }) async {
    final DatingProfile unsigned = DatingProfile(
      key: key,
      pq: pq,
      signer: signerKey.id,
      name: name,
      gender: gender,
      at: at,
      about: about,
      lookingFor: lookingFor,
      wants: wants,
      interests: interests,
      photoDigests: <String>[
        for (final String p in photos) datingPhotoDigest(p),
      ],
      vouchDigests: <String>[for (final DatingVouch v in vouches) v.digest],
      photoSlots: photos,
      vouchSlots: vouches,
    );
    // Keyed: whoever reads it has never seen the owner's key before.
    final Uint8List sig = await signerKey.signWithKey(
      canonicalJsonBytes(unsigned.core()),
    );
    return DatingProfile(
      key: key,
      pq: pq,
      signer: signerKey.id,
      sig: base64Url.encode(sig),
      name: name,
      gender: gender,
      at: at,
      about: about,
      lookingFor: lookingFor,
      wants: wants,
      interests: interests,
      photoDigests: unsigned.photoDigests,
      vouchDigests: unsigned.vouchDigests,
      photoSlots: photos,
      vouchSlots: vouches,
    );
  }

  /// Whether the owner's signature covers this core.
  Future<bool> verify() async {
    if (signer.isEmpty || sig.isEmpty) {
      return false;
    }
    return verifyLedgerSignature(
      publicKey: signer,
      message: canonicalJsonBytes(core()),
      signature: sig,
    );
  }

  static String _clip(Object? s, int max) {
    if (s is! String) {
      return '';
    }
    return s.length > max ? s.substring(0, max) : s;
  }

  /// A profile out of [json] (a core as it travels, or as kept here):
  /// `null` for a cover or anything malformed. Nothing that is signed is
  /// cut — a field too long fails the signature check instead.
  static DatingProfile? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'zen_date_profile' ||
        json['cover'] == true ||
        json['k'] is! String ||
        json['n'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final DatingGender? gender = DatingGender.byCode(json['g']);
    final Uint8List? key = decodeRelayKey(json['k']);
    if (gender == null || key == null) {
      return null;
    }
    final Object? q = json['q'];
    final Object? sk = json['sk'];
    final Object? sig = json['sig'];
    final Object? it = json['it'];
    final List<String> photoDigests = _digestsFromJson(
      json['phd'],
      kDatingMaxPhotos,
    );
    final List<String> vouchDigests = _digestsFromJson(
      json['vod'],
      kDatingMaxVouches,
    );
    final Object? ph = json['ph'];
    final Object? vo = json['vo'];
    return DatingProfile(
      key: json['k'] as String,
      pq: q is String && decodeHybridPublicKey(q) != null ? q : '',
      signer: sk is String && sk.length <= 64 ? sk : '',
      sig: sig is String && isHybridSignatureText(sig) ? sig : '',
      name: _clip(json['n'], 60),
      gender: gender,
      about: _clip(json['ab'], 4000),
      lookingFor: _clip(json['look'], 1200),
      wants: DatingWants.fromJson(json['want']),
      interests: <String>[
        if (it is List)
          for (final Object? i in it.take(kDatingMaxInterests))
            if (i is String && i.length <= kDatingTagMaxChars * 2) i,
      ],
      photoDigests: photoDigests,
      vouchDigests: vouchDigests,
      photoSlots: <String>[
        for (int i = 0; i < photoDigests.length; i++)
          ph is List &&
                  i < ph.length &&
                  ph[i] is String &&
                  (ph[i] as String).length <= kDatingMaxPhotoChars * 2
              ? ph[i] as String
              : '',
      ],
      vouchSlots: <DatingVouch?>[
        for (int i = 0; i < vouchDigests.length; i++)
          vo is List && i < vo.length ? DatingVouch.fromJson(vo[i]) : null,
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
    this.gate = false,
    this.introBy,
    this.introVia,
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

  /// The friend who passed the profile's lantern on to this phone (at one
  /// step, the person themselves).
  String? friend;

  /// Who passed it on, from their side towards us.
  List<String> path;

  /// Steps of friendship between us (0 = unknown, e.g. introduced).
  int distance;

  /// The way crossed an opened gate.
  bool gate;

  /// Introduced by a friend: their name and, when they are a friend of
  /// this person, their address (whom to ask about the introduced person).
  String? introBy;
  String? introVia;
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
  /// on to this phone straight from them. Counted here only.
  final List<String> mutual;

  /// How far, as a reach ([datingReachOf]).
  int get reach => datingReachOf(distance, gate: gate);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': profile.toJson(),
    'to': replyTo,
    'at': at,
    if (friend != null) 'f': friend,
    'path': path,
    'd': distance,
    if (gate) 'gt': true,
    if (introBy != null) 'ib': introBy,
    if (introVia != null) 'iv': introVia,
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
      gate: json['gt'] == true,
      introBy: json['ib'] is String ? json['ib'] as String : null,
      introVia: json['iv'] is String ? json['iv'] as String : null,
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
    List<String>? hiddenCircles,
    List<String>? hiddenGroups,
    List<DatingVouch>? vouches,
  }) : photos = photos ?? <String>[],
       interests = interests ?? <String>[],
       hiddenFriends = hiddenFriends ?? <String>[],
       hiddenCircles = hiddenCircles ?? <String>[],
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

  /// Interests ([datingTag], up to [kDatingMaxInterests]).
  final List<String> interests;

  /// Friends (addresses) the profile is hidden from.
  final List<String> hiddenFriends;

  /// Of [hiddenFriends], those hidden together with their circle: nothing
  /// that reaches this person through them is answered either.
  final List<String> hiddenCircles;

  /// Chat groups (ids) the profile is hidden from.
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
    if (hiddenCircles.isNotEmpty) 'hc': hiddenCircles,
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
    final Object? hc = json['hc'];
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
      interests: datingTagsFrom(json['it']),
      hiddenFriends: hf is List ? hf.whereType<String>().toList() : null,
      hiddenCircles: hc is List ? hc.whereType<String>().toList() : null,
      hiddenGroups: hg is List ? hg.whereType<String>().toList() : null,
      vouches: <DatingVouch>[
        if (vo is List)
          for (final Object? v in vo.take(kDatingMaxVouchesKept))
            if (DatingVouch.fromJson(v) != null) DatingVouch.fromJson(v)!,
      ],
    );
  }
}
