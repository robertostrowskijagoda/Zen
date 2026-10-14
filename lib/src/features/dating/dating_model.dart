import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// Gender on a dating profile (§19.1).
enum DatingGender {
  woman('k', 'kobieta'),
  man('m', 'mężczyzna'),
  other('i', 'inna osoba');

  const DatingGender(this.code, this.label);

  final String code;
  final String label;

  static DatingGender? byCode(Object? code) {
    for (final DatingGender g in values) {
      if (g.code == code) {
        return g;
      }
    }
    return null;
  }
}

/// Whom one is looking for.
@immutable
final class DatingWants {
  const DatingWants({
    this.minAge = 18,
    this.maxAge = 99,
    this.genders = const <DatingGender>{
      DatingGender.woman,
      DatingGender.man,
      DatingGender.other,
    },
    this.hops = 3,
  });

  final int minAge;
  final int maxAge;
  final Set<DatingGender> genders;

  /// How far in the friendship graph (1–3 steps).
  final int hops;

  bool accepts({
    required int age,
    required DatingGender gender,
    required int distance,
  }) =>
      age >= minAge &&
      age <= maxAge &&
      genders.contains(gender) &&
      distance <= hops;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'min': minAge,
    'max': maxAge,
    'g': <String>[for (final DatingGender g in genders) g.code],
    'hops': hops,
  };

  static DatingWants fromJson(Object? json) {
    if (json is! Map) {
      return const DatingWants();
    }
    final Object? g = json['g'];
    final Set<DatingGender> genders = <DatingGender>{
      if (g is List)
        for (final Object? c in g)
          if (DatingGender.byCode(c) != null) DatingGender.byCode(c)!,
    };
    return DatingWants(
      minAge: json['min'] is int ? (json['min'] as int).clamp(18, 99) : 18,
      maxAge: json['max'] is int ? (json['max'] as int).clamp(18, 99) : 99,
      genders: genders.isEmpty ? const DatingWants().genders : genders,
      hops: json['hops'] is int ? (json['hops'] as int).clamp(1, 3) : 3,
    );
  }
}

/// A word from a friend on someone's dating profile (§19.3).
///
/// A vouch is **signed** by the friend's vouch key (Ed25519, kept by their
/// dating service): the signature covers the profile's dating key, the
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

  /// The friend's vouch key (Ed25519, base64url) and signature.
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
    final Uint8List sig = await signer.sign(
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
        sig.length > 128 ||
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

List<String> _photosFromJson(Object? first, Object? rest) => <String>[
  if (first is String && first.length <= 48 * 1024) first,
  if (rest is List)
    for (final Object? p in rest.take(kDatingMaxPhotos))
      if (p is String && p.length <= 48 * 1024) p,
].take(kDatingMaxPhotos).toList();

/// A dating profile as it travels (§19.1). It names the dating key, not
/// the account.
@immutable
final class DatingProfile {
  const DatingProfile({
    required this.key,
    required this.name,
    required this.age,
    required this.gender,
    required this.at,
    this.about = '',
    this.lookingFor = '',
    this.wants = const DatingWants(),
    this.photos = const <String>[],
    this.salt = '',
    this.hidden = const <String>[],
    this.vouches = const <DatingVouch>[],
  });

  /// The dating key (X25519, base64url).
  final String key;
  final String name;
  final int age;
  final DatingGender gender;
  final String about;

  /// "Czego szukam".
  final String lookingFor;
  final DatingWants wants;

  /// Small JPEGs, base64 (up to [kDatingMaxPhotos]); the first is the main
  /// one.
  final List<String> photos;

  String? get photo => photos.isEmpty ? null : photos.first;

  /// Salt and hashes of the people it must not be shown to (§19.1).
  final String salt;
  final List<String> hidden;
  final List<DatingVouch> vouches;
  final int at;

  DatingProfile copyWith({List<String>? photos, List<DatingVouch>? vouches}) =>
      DatingProfile(
        key: key,
        name: name,
        age: age,
        gender: gender,
        at: at,
        about: about,
        lookingFor: lookingFor,
        wants: wants,
        photos: photos ?? this.photos,
        salt: salt,
        hidden: hidden,
        vouches: vouches ?? this.vouches,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'k': key,
    'n': name,
    'age': age,
    'g': gender.code,
    'ab': about,
    'look': lookingFor,
    'want': wants.toJson(),
    // The first photo, the rest beside it.
    if (photos.isNotEmpty) 'ph': photos.first,
    if (photos.length > 1) 'phx': photos.sublist(1),
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
        json['age'] is! int ||
        json['at'] is! int) {
      return null;
    }
    final DatingGender? gender = DatingGender.byCode(json['g']);
    final int age = json['age'] as int;
    if (gender == null || age < 18 || age > 120) {
      return null;
    }
    final Object? ex = json['ex'];
    final Object? vo = json['vo'];
    return DatingProfile(
      key: json['k'] as String,
      name: _clip(json['n'], 40),
      age: age,
      gender: gender,
      about: _clip(json['ab'], 1000),
      lookingFor: _clip(json['look'], 300),
      wants: DatingWants.fromJson(json['want']),
      photos: _photosFromJson(json['ph'], json['phx']),
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
  });

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

  /// Introduced by a friend (§19.3).
  String? introBy;
  String? introNote;

  /// The matchmaker's pyramid key, when they are in a pyramid (for "Podziękuj
  /// swatowi", §19.3 / §23).
  String? introPyr;

  /// When this person thanked the matchmaker with currency.
  int? thankedAt;

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

/// "Co sądzisz o …?" between friends (§19.3).
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

/// "Idę na randkę" (§19.4): one side shares, the other watches.
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
    );
  }
}

/// This person's own dating settings and profile draft.
final class MyDating {
  MyDating({
    this.enabled = false,
    this.adult = false,
    this.name = '',
    this.age = 0,
    this.gender = DatingGender.other,
    this.about = '',
    this.lookingFor = '',
    this.wants = const DatingWants(),
    List<String>? photos,
    List<String>? hiddenFriends,
    List<String>? hiddenGroups,
    List<DatingVouch>? vouches,
  }) : photos = photos ?? <String>[],
       hiddenFriends = hiddenFriends ?? <String>[],
       hiddenGroups = hiddenGroups ?? <String>[],
       vouches = vouches ?? <DatingVouch>[];

  bool enabled;

  /// Declared 18+ (no documents, §19.1).
  bool adult;
  String name;
  int age;
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

  /// Friends (addresses) and chat groups (ids) it is hidden from.
  final List<String> hiddenFriends;
  final List<String> hiddenGroups;
  final List<DatingVouch> vouches;

  bool get complete => name.trim().isNotEmpty && age >= 18;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (enabled) 'on': true,
    if (adult) 'adult': true,
    'n': name,
    'age': age,
    'g': gender.code,
    'ab': about,
    'look': lookingFor,
    'want': wants.toJson(),
    if (photos.isNotEmpty) 'ph': photos.first,
    if (photos.length > 1) 'phx': photos.sublist(1),
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
      adult: json['adult'] == true,
      name: json['n'] is String ? json['n'] as String : '',
      age: json['age'] is int ? json['age'] as int : 0,
      gender: DatingGender.byCode(json['g']) ?? DatingGender.other,
      about: json['ab'] is String ? json['ab'] as String : '',
      lookingFor: json['look'] is String ? json['look'] as String : '',
      wants: DatingWants.fromJson(json['want']),
      photos: <String>[
        if (json['ph'] is String) json['ph'] as String,
        if (json['phx'] is List) ...(json['phx'] as List).whereType<String>(),
      ].take(kDatingMaxPhotos).toList(),
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
