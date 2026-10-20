import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What a line on a flat's profile is (§18.1).
enum FlatItemKind {
  /// "Zapraszamy na grilla" — with a date, seats and sign-ups.
  invite,

  /// "Pożyczę wiertarkę".
  offer,

  /// "Szukamy opieki nad kotem".
  need;

  static FlatItemKind? byName(Object? name) {
    for (final FlatItemKind k in values) {
      if (k.name == name) {
        return k;
      }
    }
    return null;
  }
}

/// Ready-made invitations (§18.1), to start with one tap.
List<String> get kFlatInviteIdeas => <String>[
  t('Zapraszamy na obiad'),
  t('Zapraszamy na kawę'),
  t('Zapraszamy na imprezę'),
  t('Zapraszamy na planszówki'),
  t('Zapraszamy na grilla'),
  t('Wspólny spacer z psem'),
];

List<String> get kFlatOfferIdeas => <String>[
  t('Pożyczę wiertarkę'),
  t('Pożyczę drabinę'),
  t('Podleję kwiaty'),
  t('Wyprowadzę psa'),
  t('Pomogę z komputerem'),
  t('Odbiorę paczkę'),
];

List<String> get kFlatNeedIdeas => <String>[
  t('Pomoc przy wnoszeniu'),
  t('Opieka nad kotem na weekend'),
  t('Podwózka'),
];

/// One invitation, offer or need on a flat's profile.
@immutable
final class FlatItem {
  const FlatItem({
    required this.id,
    required this.kind,
    required this.text,
    this.at,
    this.seats = 0,
    this.taken = 0,
  });

  final String id;
  final FlatItemKind kind;
  final String text;

  /// When (invitations only).
  final int? at;

  /// Places (0 = no limit), invitations only.
  final int seats;

  /// Places already taken by neighbours who signed up.
  final int taken;

  bool get isFull => seats > 0 && taken >= seats;

  FlatItem copyWith({int? taken}) => FlatItem(
    id: id,
    kind: kind,
    text: text,
    at: at,
    seats: seats,
    taken: taken ?? this.taken,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'k': kind.name,
    't': text,
    if (at != null) 'at': at,
    if (seats > 0) 'seats': seats,
    if (taken > 0) 'taken': taken,
  };

  static FlatItem? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final FlatItemKind? kind = FlatItemKind.byName(json['k']);
    final Object? id = json['id'];
    final Object? text = json['t'];
    if (kind == null || id is! String || id.length > 40 || text is! String) {
      return null;
    }
    return FlatItem(
      id: id,
      kind: kind,
      text: text.length > 300 ? text.substring(0, 300) : text,
      at: json['at'] is int ? json['at'] as int : null,
      seats: json['seats'] is int ? (json['seats'] as int).clamp(0, 999) : 0,
      taken: json['taken'] is int ? (json['taken'] as int).clamp(0, 9999) : 0,
    );
  }
}

/// The public neighbour profile (§18.1): it belongs to a household — a
/// family or any group living together — in the flat where it lives now,
/// not to the flat itself. When they move out, the new tenants start their
/// own from scratch. Signed with the household's own key, which every
/// resident holds. Residents' main profiles are not in it.
@immutable
final class FlatProfile {
  const FlatProfile({
    required this.key,
    required this.name,
    required this.rev,
    required this.members,
    this.place = '',
    this.about = '',
    this.items = const <FlatItem>[],
    this.photo = '',
    this.signature = '',
  });

  /// Longest photo accepted in a profile (base64 characters).
  static const int maxPhotoChars = 100 * 1024;

  /// The household's public key (its identity).
  final String key;

  /// Who: "Nowakowie", "Ania i Tomek", "Mieszkanie studenckie".
  final String name;

  /// Where they live now: "m. 12", "Lipowa 3/12, 3 piętro".
  final String place;

  /// "Mamy małe dziecko, prosimy o ciszę po 20".
  final String about;
  final List<FlatItem> items;

  /// One photo of the household (a small JPEG, base64; '' = none).
  final String photo;

  /// Where the residents' phones can be reached (only to deliver messages
  /// for the flat; nothing ties them to the residents' accounts).
  final List<String> members;

  /// Grows with every change; the higher one wins.
  final int rev;
  final String signature;

  /// "Nowakowie · m. 12".
  String get label => place.isEmpty ? name : '$name · $place';

  Iterable<FlatItem> of(FlatItemKind kind) =>
      items.where((FlatItem i) => i.kind == kind);

  FlatItem? item(String id) {
    for (final FlatItem i in items) {
      if (i.id == id) {
        return i;
      }
    }
    return null;
  }

  Map<String, dynamic> _body() => <String, dynamic>{
    't': 'zen_flat',
    'k': key,
    'n': name,
    'pl': place,
    'ab': about,
    'i': <Map<String, dynamic>>[for (final FlatItem i in items) i.toJson()],
    'm': members,
    'r': rev,
    // Only when set, so older profiles keep their signatures.
    if (photo.isNotEmpty) 'ph': photo,
  };

  Uint8List get signedBytes => canonicalJsonBytes(_body());

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._body(),
    's': signature,
  };

  FlatProfile copyWith({
    String? name,
    String? place,
    String? about,
    List<FlatItem>? items,
    List<String>? members,
    int? rev,
    String? photo,
    String? key,
  }) => FlatProfile(
    key: key ?? this.key,
    name: name ?? this.name,
    place: place ?? this.place,
    about: about ?? this.about,
    items: items ?? this.items,
    members: members ?? this.members,
    rev: rev ?? this.rev,
    photo: photo ?? this.photo,
  );

  Future<FlatProfile> signedWith(LedgerKeyPair pair) async {
    final Uint8List sig = await pair.sign(signedBytes);
    return FlatProfile(
      key: key,
      name: name,
      place: place,
      about: about,
      items: items,
      members: members,
      rev: rev,
      photo: photo,
      signature: b64(sig),
    );
  }

  Future<bool> verify() => verifyLedgerSignature(
    publicKey: key,
    message: signedBytes,
    signature: signature,
  );

  /// Wins over [other] (same flat): a newer revision, ties by signature so
  /// both housemates end up with the same one.
  bool newerThan(FlatProfile? other) =>
      other == null ||
      rev > other.rev ||
      (rev == other.rev && signature.compareTo(other.signature) > 0);

  static FlatProfile? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'zen_flat' ||
        json['k'] is! String ||
        json['n'] is! String ||
        json['r'] is! int) {
      return null;
    }
    final Object? items = json['i'];
    final Object? members = json['m'];
    final String name = json['n'] as String;
    final Object? about = json['ab'];
    final Object? place = json['pl'];
    final Object? photo = json['ph'];
    if (photo is String && photo.length > maxPhotoChars) {
      return null;
    }
    return FlatProfile(
      key: json['k'] as String,
      name: name.length > 60 ? name.substring(0, 60) : name,
      place: place is String
          ? (place.length > 80 ? place.substring(0, 80) : place)
          : '',
      about: about is String
          ? (about.length > 1000 ? about.substring(0, 1000) : about)
          : '',
      items: <FlatItem>[
        if (items is List)
          for (final Object? i in items.take(60))
            if (FlatItem.fromJson(i) != null) FlatItem.fromJson(i)!,
      ],
      members: <String>[
        if (members is List)
          for (final String m in members.whereType<String>())
            PeerShareCodec.normalizeAddress(m),
      ],
      rev: json['r'] as int,
      photo: photo is String ? photo : '',
      signature: json['s'] is String ? json['s'] as String : '',
    );
  }
}

/// What the QR on the door holds (§18.2): the flat's key, a door secret
/// (a new QR makes the old one useless), where to knock and the name. Not
/// the residents' accounts.
@immutable
final class FlatDoorCode {
  const FlatDoorCode({
    required this.key,
    required this.door,
    required this.members,
    required this.name,
  });

  final String key;
  final String door;
  final List<String> members;
  final String name;

  static const String qrPrefix = 'zen-flat:';

  /// The link form (`https://<domain>/m#<code>`) is accepted too, for when
  /// a download page exists; everything after `#` stays on the phone.
  static const String linkMarker = '/m#';

  String encode() => base64Url
      .encode(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'k': key,
            'd': door,
            'a': members.take(3).toList(),
            'n': name,
          }),
        ),
      )
      .replaceAll('=', '');

  String toQr() => '$qrPrefix${encode()}';

  static FlatDoorCode? parse(String text) {
    final String t = text.trim();
    String? code;
    if (t.startsWith(qrPrefix)) {
      code = t.substring(qrPrefix.length);
    } else {
      final int i = t.indexOf(linkMarker);
      if (i >= 0 && t.startsWith('http')) {
        code = t.substring(i + linkMarker.length);
      }
    }
    if (code == null || code.isEmpty || code.length > 2000) {
      return null;
    }
    try {
      final Object? json = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(code))),
      );
      return fromJson(json);
    } on Object {
      return null;
    }
  }

  static FlatDoorCode? fromJson(Object? json) {
    if (json is! Map ||
        json['k'] is! String ||
        json['d'] is! String ||
        json['n'] is! String ||
        json['a'] is! List) {
      return null;
    }
    final List<String> members = <String>[
      for (final String a in (json['a'] as List).whereType<String>().take(3))
        if (isRoutablePeerAddress(a)) PeerShareCodec.normalizeAddress(a),
    ];
    if (members.isEmpty || unb64(json['k'], length: 32) == null) {
      return null;
    }
    final String name = json['n'] as String;
    return FlatDoorCode(
      key: json['k'] as String,
      door: json['d'] as String,
      members: members,
      name: name.length > 150 ? name.substring(0, 150) : name,
    );
  }
}

/// What a housemate shows to let a new resident in (§18.1): scanned only
/// inside the flat, because it carries the flat's private key.
@immutable
final class FlatHomeCode {
  const FlatHomeCode({required this.seed, required this.address});

  final String seed;

  /// The housemate's phone, to send "I'm in" to.
  final String address;

  static const String qrPrefix = 'zen-home:';

  String toQr() =>
      '$qrPrefix${base64Url.encode(utf8.encode(jsonEncode(<String, String>{'s': seed, 'a': address}))).replaceAll('=', '')}';

  static FlatHomeCode? parse(String text) {
    final String t = text.trim();
    if (!t.startsWith(qrPrefix)) {
      return null;
    }
    try {
      final Object? json = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(t.substring(qrPrefix.length))),
        ),
      );
      if (json is! Map ||
          unb64(json['s'], length: 32) == null ||
          json['a'] is! String ||
          !isRoutablePeerAddress(json['a'] as String)) {
        return null;
      }
      return FlatHomeCode(
        seed: json['s'] as String,
        address: PeerShareCodec.normalizeAddress(json['a'] as String),
      );
    } on Object {
      return null;
    }
  }
}

/// What a resident signs (with their own resident key) to vote the phone
/// [target] out of the household [flatKey] (§18.1).
Uint8List flatKickBytes(String flatKey, String target) => canonicalJsonBytes(
  <String, dynamic>{'t': 'zen_flat_kick', 'f': flatKey, 'a': target},
);

/// What the resident who made a household's new key signs for neighbours:
/// "[oldKey] is now [newKey], without [target]".
Uint8List flatNewKeyBytes(String oldKey, String newKey, String target) =>
    canonicalJsonBytes(<String, dynamic>{
      't': 'zen_flat_newkey',
      'o': oldKey,
      'k': newKey,
      'a': target,
    });

/// A resident's own key as a neighbour learned it (§18.3): from the flat's
/// own profile message, pinned the first time and never replaced.
@immutable
final class FlatPin {
  const FlatPin({required this.key, required this.since});

  /// The resident's public key (Ed25519, base64url).
  final String key;

  /// When this phone learned it.
  final int since;

  Map<String, dynamic> toJson() => <String, dynamic>{'k': key, 't': since};

  static FlatPin? fromJson(Object? json) {
    if (json is! Map ||
        unb64(json['k'], length: 32) == null ||
        json['t'] is! int) {
      return null;
    }
    return FlatPin(key: json['k'] as String, since: json['t'] as int);
  }
}

/// Pinned resident keys from JSON (phone address → pin).
Map<String, FlatPin> flatPinsFromJson(Object? json) => <String, FlatPin>{
  if (json is Map)
    for (final MapEntry<dynamic, dynamic> e in json.entries)
      if (e.key is String && FlatPin.fromJson(e.value) != null)
        PeerShareCodec.normalizeAddress(e.key as String): FlatPin.fromJson(
          e.value,
        )!,
};

Map<String, dynamic> flatPinsToJson(Map<String, FlatPin> pins) =>
    <String, dynamic>{
      for (final MapEntry<String, FlatPin> e in pins.entries)
        e.key: e.value.toJson(),
    };

/// A neighbour's flat on "Moi sąsiedzi" (§18.3).
final class NeighborFlat {
  NeighborFlat({
    required this.profile,
    required this.addedAt,
    this.weScanned = false,
    this.scannedUs = false,
    this.following = true,
    Set<String>? seenItems,
    Map<String, FlatPin>? residents,
  }) : seenItems = seenItems ?? <String>{},
       residents = residents ?? <String, FlatPin>{};

  FlatProfile profile;
  final int addedAt;

  /// We scanned their door (or took their invitation nearby).
  bool weScanned;

  /// They scanned ours.
  bool scannedUs;

  /// New invitations and offers from them are announced.
  bool following;

  /// Item ids already announced (so a profile update rings only for news).
  final Set<String> seenItems;

  /// The residents' own keys (phone address → pin), used to check a new
  /// household key (§18.1).
  final Map<String, FlatPin> residents;

  String get key => profile.key;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': profile.toJson(),
    'at': addedAt,
    if (weScanned) 'ws': true,
    if (scannedUs) 'su': true,
    if (!following) 'mute': true,
    'seen': seenItems.toList(),
    if (residents.isNotEmpty) 'rk': flatPinsToJson(residents),
  };

  static NeighborFlat? fromJson(Object? json) {
    if (json is! Map || json['at'] is! int) {
      return null;
    }
    final FlatProfile? p = FlatProfile.fromJson(json['p']);
    if (p == null) {
      return null;
    }
    final Object? seen = json['seen'];
    return NeighborFlat(
      profile: p,
      addedAt: json['at'] as int,
      weScanned: json['ws'] == true,
      scannedUs: json['su'] == true,
      following: json['mute'] != true,
      seenItems: seen is List ? seen.whereType<String>().toSet() : null,
      residents: flatPinsFromJson(json['rk']),
    );
  }
}

/// A neighbour household that moved to a new key because it removed a
/// phone (§18.1), remembered for a while so that a second, different "new
/// key" for the same old one is recognised instead of silently taken.
final class FlatKeySwitch {
  FlatKeySwitch({
    required this.oldKey,
    required this.name,
    required this.members,
    required this.pins,
    required this.newKey,
    required this.removed,
    required this.by,
    required this.at,
    this.rival,
    Set<String>? rivalRemoved,
    this.rivalBy = '',
  }) : rivalRemoved = rivalRemoved ?? <String>{};

  final String oldKey;
  final String name;

  /// The residents' phones and pinned keys before the change.
  final List<String> members;
  final Map<String, FlatPin> pins;

  /// The key followed now, which phones it removed, and who made it.
  String newKey;
  Set<String> removed;
  String by;
  final int at;

  /// Another new key that also checked out ("Dwa różne nowe klucze
  /// mieszkania"): kept aside until the neighbours are asked in person.
  FlatProfile? rival;
  Set<String> rivalRemoved;
  String rivalBy;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'o': oldKey,
    'n': name,
    'm': members,
    'rk': flatPinsToJson(pins),
    'k': newKey,
    'rm': removed.toList(),
    'by': by,
    'at': at,
    'rv': ?rival?.toJson(),
    if (rival != null) 'rvRm': rivalRemoved.toList(),
    if (rival != null) 'rvBy': rivalBy,
  };

  static FlatKeySwitch? fromJson(Object? json) {
    if (json is! Map ||
        json['o'] is! String ||
        json['k'] is! String ||
        json['by'] is! String ||
        json['at'] is! int ||
        json['m'] is! List ||
        json['rm'] is! List) {
      return null;
    }
    Set<String> addresses(Object? list) => <String>{
      if (list is List)
        for (final String a in list.whereType<String>())
          PeerShareCodec.normalizeAddress(a),
    };
    final Object? name = json['n'];
    return FlatKeySwitch(
      oldKey: json['o'] as String,
      name: name is String ? name : '',
      members: addresses(json['m']).toList(),
      pins: flatPinsFromJson(json['rk']),
      newKey: json['k'] as String,
      removed: addresses(json['rm']),
      by: json['by'] as String,
      at: json['at'] as int,
      rival: FlatProfile.fromJson(json['rv']),
      rivalRemoved: addresses(json['rvRm']),
      rivalBy: json['rvBy'] is String ? json['rvBy'] as String : '',
    );
  }
}

/// A message between two flats (§18.3).
@immutable
final class FlatMessage {
  const FlatMessage({
    required this.id,
    required this.flat,
    required this.mine,
    required this.text,
    required this.at,
    this.by = '',
  });

  final String id;

  /// The other flat's key.
  final String flat;

  /// Written from our flat (by any resident).
  final bool mine;
  final String text;
  final int at;

  /// The resident who wrote it ("Ania").
  final String by;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'f': flat,
    if (mine) 'mine': true,
    't': text,
    'at': at,
    if (by.isNotEmpty) 'by': by,
  };

  static FlatMessage? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['f'] is! String ||
        json['t'] is! String ||
        json['at'] is! int) {
      return null;
    }
    return FlatMessage(
      id: json['id'] as String,
      flat: json['f'] as String,
      mine: json['mine'] == true,
      text: json['t'] as String,
      at: json['at'] as int,
      by: json['by'] is String ? json['by'] as String : '',
    );
  }
}

/// A neighbour flat signed up for one of our invitations.
@immutable
final class FlatSignup {
  const FlatSignup({
    required this.flat,
    required this.name,
    required this.count,
    required this.at,
  });

  final String flat;
  final String name;
  final int count;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'f': flat,
    'n': name,
    'c': count,
    'at': at,
  };

  static FlatSignup? fromJson(Object? json) {
    if (json is! Map ||
        json['f'] is! String ||
        json['n'] is! String ||
        json['c'] is! int ||
        json['at'] is! int) {
      return null;
    }
    return FlatSignup(
      flat: json['f'] as String,
      name: json['n'] as String,
      count: json['c'] as int,
      at: json['at'] as int,
    );
  }
}

/// An invitation that came over Bluetooth from a flat nearby (§18.3).
@immutable
final class NearbyFlatInvite {
  const NearbyFlatInvite({
    required this.door,
    required this.text,
    required this.at,
  });

  final FlatDoorCode door;
  final String text;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'q': door.toQr(),
    't': text,
    'at': at,
  };

  static NearbyFlatInvite? fromJson(Object? json) {
    if (json is! Map ||
        json['q'] is! String ||
        json['t'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final FlatDoorCode? door = FlatDoorCode.parse(json['q'] as String);
    return door == null
        ? null
        : NearbyFlatInvite(
            door: door,
            text: json['t'] as String,
            at: json['at'] as int,
          );
  }
}

/// A resident of a neighbour flat who showed their own account ("Pokaż mój
/// profil", §18.1): their name and where to send a friend invitation.
@immutable
final class FlatReveal {
  const FlatReveal({
    required this.flat,
    required this.name,
    required this.address,
    required this.at,
  });

  /// The flat they live in (its key).
  final String flat;
  final String name;

  /// Their own phone (the account's address).
  final String address;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'f': flat,
    'n': name,
    'a': address,
    'at': at,
  };

  static FlatReveal? fromJson(Object? json) {
    if (json is! Map ||
        json['f'] is! String ||
        json['n'] is! String ||
        json['a'] is! String ||
        json['at'] is! int ||
        !isRoutablePeerAddress(json['a'] as String)) {
      return null;
    }
    final String n = json['n'] as String;
    return FlatReveal(
      flat: json['f'] as String,
      name: n.length > 60 ? n.substring(0, 60) : n,
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      at: json['at'] as int,
    );
  }
}
