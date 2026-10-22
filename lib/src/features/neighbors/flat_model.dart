import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What a line on a flat's profile is.
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

/// Ready-made invitations, to start with one tap.
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

/// The public neighbour profile: it belongs to a household — a
/// family or any group living together — in the flat where it lives now,
/// not to the flat itself. When they move out, the new tenants start their
/// own from scratch. Signed with the household's own key, which every
/// resident holds. Residents' main profiles are not in it, nor their
/// addresses: each resident is a key of its own and the door its phone
/// runs.
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
    this.retired = const <String>[],
    this.signature = '',
  });

  /// Longest photo accepted in a profile (base64 characters).
  static const int maxPhotoChars = 100 * 1024;

  /// Old doors a profile lists at most ([retired]).
  static const int maxRetired = 16;

  /// Most residents a profile may name: everything for a flat goes to each
  /// one's door, so a longer list would make other phones send to
  /// addresses the profile's maker picked.
  static const int maxMembers = 32;

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

  /// The residents: each one's own resident key (Ed25519, base64url; votes
  /// and the "new key" notice are signed with it) → the address of
  /// the door that resident's phone runs ('' until it runs). Everything for
  /// the flat goes to these doors, from door to door; a resident's own
  /// address is not here (only "Pokaż mój profil" shows it).
  final Map<String, String> members;

  /// Doors of this household that stopped for good (a resident's phone
  /// got a new door key: "Nowy kod", or the household moved to another
  /// phone of the same account), newest last: whoever routes to the
  /// household never sends to them again, and what comes from them is
  /// dropped, even when an older profile still names one.
  final List<String> retired;

  /// The doors to send to.
  Iterable<String> get doors =>
      members.values.where((String d) => d.isNotEmpty && !retired.contains(d));

  /// [retired] with [door] added (the oldest go past [maxRetired]).
  List<String> retiring(String door) {
    if (door.isEmpty) {
      return retired;
    }
    final List<String> next = <String>[
      for (final String d in retired)
        if (d != door) d,
      door,
    ];
    return next.length > maxRetired
        ? next.sublist(next.length - maxRetired)
        : next;
  }

  /// The resident whose door is [door], or `null`.
  String? residentAt(String door) {
    for (final MapEntry<String, String> e in members.entries) {
      if (e.value.isNotEmpty && e.value == door) {
        return e.key;
      }
    }
    return null;
  }

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
    // Only when set.
    if (photo.isNotEmpty) 'ph': photo,
    if (retired.isNotEmpty) 'x': retired,
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
    Map<String, String>? members,
    int? rev,
    String? photo,
    String? key,
    List<String>? retired,
  }) => FlatProfile(
    key: key ?? this.key,
    name: name ?? this.name,
    place: place ?? this.place,
    about: about ?? this.about,
    items: items ?? this.items,
    members: members ?? this.members,
    rev: rev ?? this.rev,
    photo: photo ?? this.photo,
    retired: retired ?? this.retired,
  );

  Future<FlatProfile> signedWith(LedgerKeyPair pair) async {
    final Uint8List sig = await pair.signWithKey(signedBytes);
    return FlatProfile(
      key: key,
      name: name,
      place: place,
      about: about,
      items: items,
      members: members,
      rev: rev,
      photo: photo,
      retired: retired,
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
    final Object? retired = json['x'];
    if ((photo is String && photo.length > maxPhotoChars) ||
        (members is Map && members.length > maxMembers) ||
        (retired is List && retired.length > maxRetired)) {
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
      members: <String, String>{
        if (members is Map)
          for (final MapEntry<dynamic, dynamic> m in members.entries)
            if (unb64(m.key, length: 32) != null &&
                m.value is String &&
                ((m.value as String).isEmpty ||
                    isRoutablePeerAddress(m.value as String)))
              m.key as String: (m.value as String).isEmpty
                  ? ''
                  : PeerShareCodec.normalizeAddress(m.value as String),
      },
      rev: json['r'] as int,
      photo: photo is String ? photo : '',
      retired: <String>[
        if (retired is List)
          for (final Object? d in retired)
            if (d is String && isRoutablePeerAddress(d))
              PeerShareCodec.normalizeAddress(d),
      ],
      signature: json['s'] is String ? json['s'] as String : '',
    );
  }
}

/// What the QR on the door holds: the flat's key, a door token
/// (a new QR makes the old one useless), the name and where to knock.
///
/// Where to knock is the flat's door: a node of its own with a random key
/// that one resident's phone runs beside its own node, never peered with it
/// (door_node.go in the bridge). It is nobody's identity, so a stranger who
/// walks past the sticker does not learn who lives there; "Nowy kod" gives
/// the door a new key and so a new address.
///
/// While that phone is offline, knocks go sealed to the flat's mailbox doors
/// ([mail], flat_door_mail.dart): run by the friends who keep the phone's
/// offline mailboxes, named by addresses that say nothing about who they
/// are.
///
/// The printed sticker carries the household's permanent token; an
/// invitation passed to people nearby carries a token of its own that works
/// only until [until] ([kNearbyCodeLife]).
@immutable
final class FlatDoorCode {
  const FlatDoorCode({
    required this.key,
    required this.door,
    required this.inbox,
    required this.name,
    this.mail,
    this.until,
  });

  final String key;

  /// The door token (secret of this sticker; "Nowy kod" replaces it).
  final String door;

  /// Where to knock: the address of the flat's door.
  final String inbox;
  final String name;

  /// The mailbox doors and the key knocks for them are sealed to; `null`
  /// before the phone has worked them out.
  final FlatMailDoor? mail;

  /// Until when a short-lived code works (milliseconds); `null` for the
  /// sticker's permanent one.
  final int? until;

  /// Whether a short-lived code is over at [now].
  bool expiredAt(int now) => until != null && until! <= now;

  static const int currentVersion = 3;

  static const String qrPrefix = 'zen-flat:';

  /// The link form (`https://<domain>/m#<code>`) is accepted too, for when
  /// a download page exists; everything after `#` stays on the phone.
  static const String linkMarker = '/m#';

  /// What goes into the code: the flat identifier, the door token and the
  /// door's address; never a resident's.
  String encode() => base64Url
      .encode(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'v': currentVersion,
            'k': key,
            'd': door,
            'a': inbox,
            'n': name,
            ...?mail?.toJson(),
            'u': ?until,
          }),
        ),
      )
      .replaceAll('=', '');

  String toQr() => '$qrPrefix${encode()}';

  /// The link form for the printed sticker: an ordinary camera opens the
  /// page (`/m#<code>`), which opens Zen (`zen://m/<code>`) or shows how to
  /// get it. The code stays after `#`, so it never reaches the web server.
  String toLink() => '${PeerShareCodec.invitePageUrl}m#${encode()}';

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
        json['a'] is! String ||
        json['v'] != currentVersion) {
      return null;
    }
    final String inbox = json['a'] as String;
    if (!isRoutablePeerAddress(inbox) || unb64(json['k'], length: 32) == null) {
      return null;
    }
    final String name = json['n'] as String;
    final Object? until = json['u'];
    return FlatDoorCode(
      key: json['k'] as String,
      door: json['d'] as String,
      inbox: PeerShareCodec.normalizeAddress(inbox),
      name: name.length > 150 ? name.substring(0, 150) : name,
      mail: FlatMailDoor.read(json['s'], json['x']),
      until: until is int ? until : null,
    );
  }
}

/// How long an invitation heard nearby works: its door code carries a
/// token of its own, never the sticker's permanent one.
const Duration kNearbyCodeLife = Duration(days: 1);

/// How long a household code ("Pokaż kod domownika") works; it works once.
const Duration kHomeCodeLife = Duration(minutes: 10);

/// What a housemate shows to let a new resident in: a one-time token valid
/// [kHomeCodeLife], the housemate's phone to ask, and which household it is
/// (its public key and name). Never the household's key: that comes sealed
/// to the new phone only once the housemate taps "Dołącz" on their phone.
@immutable
final class FlatHomeCode {
  const FlatHomeCode({
    required this.token,
    required this.address,
    required this.flatKey,
    required this.name,
    required this.until,
  });

  /// The one-time token.
  final String token;

  /// The housemate's phone, to ask to join.
  final String address;

  /// The household's public key and name.
  final String flatKey;
  final String name;

  /// Until when it works (milliseconds).
  final int until;

  static const String qrPrefix = 'zen-home:';

  String toQr() =>
      '$qrPrefix${base64Url.encode(utf8.encode(jsonEncode(<String, dynamic>{'t': token, 'a': address, 'k': flatKey, 'n': name, 'u': until}))).replaceAll('=', '')}';

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
          json['t'] is! String ||
          (json['t'] as String).isEmpty ||
          (json['t'] as String).length > 64 ||
          json['a'] is! String ||
          !isRoutablePeerAddress(json['a'] as String) ||
          unb64(json['k'], length: 32) == null ||
          json['n'] is! String ||
          json['u'] is! int) {
        return null;
      }
      final String name = json['n'] as String;
      return FlatHomeCode(
        token: json['t'] as String,
        address: PeerShareCodec.normalizeAddress(json['a'] as String),
        flatKey: json['k'] as String,
        name: name.length > 150 ? name.substring(0, 150) : name,
        until: json['u'] as int,
      );
    } on Object {
      return null;
    }
  }
}

/// What a new phone signs with its resident key when it asks to join with a
/// household code ([ask]: the token, its name and device, its resident key
/// and the keys the household key is sealed to).
Uint8List flatJoinAskBytes(Map<String, Object?> ask) =>
    canonicalJsonBytes(<String, Object?>{'t': 'zen_flat_join', ...ask});

/// A new phone asking to become a resident with a household code: the
/// phone that showed the code confirms it ("Dołącz") or not ("Odrzuć").
@immutable
final class FlatJoinRequest {
  const FlatJoinRequest({
    required this.id,
    required this.name,
    required this.device,
    required this.resident,
    required this.phone,
    required this.seal,
    required this.kem,
    required this.at,
  });

  /// The code's token.
  final String id;

  /// The name the new resident gave, and their device ("Telefon (Android)").
  final String name;
  final String device;

  /// Their resident key and phone.
  final String resident;
  final String phone;

  /// Where the household key goes, sealed: X25519 (base64url) and a hybrid
  /// ML-KEM-768 + X25519 key.
  final String seal;
  final Uint8List kem;
  final int at;
}

/// What a resident signs (with their own resident key) to vote the
/// resident [target] (their resident key) out of the household [flatKey].
Uint8List flatKickBytes(String flatKey, String target) => canonicalJsonBytes(
  <String, dynamic>{'t': 'zen_flat_kick', 'f': flatKey, 'a': target},
);

/// What the resident who made a household's new key signs for neighbours:
/// "[oldKey] is now [newKey], without the resident [target]".
Uint8List flatNewKeyBytes(String oldKey, String newKey, String target) =>
    canonicalJsonBytes(<String, dynamic>{
      't': 'zen_flat_newkey',
      'o': oldKey,
      'k': newKey,
      'a': target,
    });

/// What a resident signs (with their own resident key) when their phone
/// leaves the household [flatKey] ("Opuść"): the others make a new key
/// without it, and neighbours take this as the resident's own consent.
Uint8List flatLeaveBytes(String flatKey, String resident) => canonicalJsonBytes(
  <String, dynamic>{'t': 'zen_flat_leave', 'f': flatKey, 'a': resident},
);

/// What a resident signs (with their own resident key) when the household
/// moves to another phone of their account at [address] ("Przenieś
/// mieszkanie na to urządzenie": another device of the account, or a new
/// phone after a recovery) at [at]: housemates move the resident to that
/// phone, and only a later move ([at]) moves them again, so an old notice
/// sent once more changes nothing. The phone the household left steps down
/// when it sees one newer than its own start.
Uint8List flatMovedBytes(
  String flatKey,
  String resident,
  String address,
  int at,
) => canonicalJsonBytes(<String, dynamic>{
  't': 'zen_flat_moved_phone',
  'f': flatKey,
  'a': resident,
  'to': address,
  'at': at,
});

/// What a resident signs (with their own resident key) to show a
/// neighbour flat [to] their own account at [address] under [name] ("Pokaż
/// mój profil").
Uint8List flatRevealBytes(
  String flatKey,
  String to,
  String address,
  String name,
) => canonicalJsonBytes(<String, dynamic>{
  't': 'zen_flat_reveal',
  'f': flatKey,
  'to': to,
  'a': address,
  'n': name,
});

/// Residents' own keys as a neighbour learned them, from the flat's
/// profile: resident key → when this phone first saw it (kept, never
/// replaced).
Map<String, int> flatPinsFromJson(Object? json) => <String, int>{
  if (json is Map)
    for (final MapEntry<dynamic, dynamic> e in json.entries)
      if (unb64(e.key, length: 32) != null && e.value is int)
        e.key as String: e.value as int,
};

/// A neighbour's flat on "Moi sąsiedzi".
final class NeighborFlat {
  NeighborFlat({
    required FlatProfile profile,
    required this.addedAt,
    this.weScanned = false,
    this.scannedUs = false,
    this.following = true,
    Set<String>? seenItems,
    Map<String, int>? residents,
    Iterable<String> retired = const <String>[],
  }) : _profile = profile,
       seenItems = seenItems ?? <String>{},
       residents = residents ?? <String, int>{} {
    retire(retired);
    retire(profile.retired);
  }

  /// Old doors kept at most ([retired]).
  static const int maxRetired = 64;

  FlatProfile _profile;

  /// Their newest profile; the old doors it lists stay [retired].
  FlatProfile get profile => _profile;
  set profile(FlatProfile next) {
    _profile = next;
    retire(next.retired);
  }

  /// Their doors that stopped for good, from every profile of theirs seen
  /// ([FlatProfile.retired]): never sent to again, and what comes from one
  /// is dropped — also when an older profile (an old phone that did not
  /// hear of the move yet) names it again.
  final Set<String> retired = <String>{};

  /// Adds [doors] to [retired] (the oldest go past [maxRetired]).
  void retire(Iterable<String> doors) {
    retired.addAll(doors);
    while (retired.length > maxRetired) {
      retired.remove(retired.first);
    }
  }

  /// The doors to send to: their profile's, without the [retired] ones.
  Iterable<String> get doors =>
      _profile.doors.where((String d) => !retired.contains(d));

  final int addedAt;

  /// We scanned their door (or took their invitation nearby).
  bool weScanned;

  /// They scanned ours.
  bool scannedUs;

  /// New invitations and offers from them are announced.
  bool following;

  /// Item ids already announced (so a profile update rings only for news).
  final Set<String> seenItems;

  /// The residents' own keys and when this phone first saw each, used to
  /// check a new household key.
  final Map<String, int> residents;

  String get key => profile.key;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': profile.toJson(),
    'at': addedAt,
    if (weScanned) 'ws': true,
    if (scannedUs) 'su': true,
    if (!following) 'mute': true,
    'seen': seenItems.toList(),
    if (residents.isNotEmpty) 'rk': residents,
    if (retired.isNotEmpty) 'x': retired.toList(),
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
    final Object? retired = json['x'];
    return NeighborFlat(
      profile: p,
      addedAt: json['at'] as int,
      weScanned: json['ws'] == true,
      scannedUs: json['su'] == true,
      following: json['mute'] != true,
      seenItems: seen is List ? seen.whereType<String>().toSet() : null,
      residents: flatPinsFromJson(json['rk']),
      retired: retired is List
          ? retired.whereType<String>().take(maxRetired)
          : const <String>[],
    );
  }
}

/// A neighbour household that moved to a new key because it removed a
/// phone, remembered for a while so that a second, different "new
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

  /// The residents (resident key → door) and the keys pinned before the
  /// change.
  final Map<String, String> members;
  final Map<String, int> pins;

  /// The key followed now, which residents it removed, and who made it
  /// (resident keys).
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
    'rk': pins,
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
        json['m'] is! Map ||
        json['rm'] is! List) {
      return null;
    }
    Set<String> keys(Object? list) => <String>{
      if (list is List) ...list.whereType<String>(),
    };
    final Object? name = json['n'];
    return FlatKeySwitch(
      oldKey: json['o'] as String,
      name: name is String ? name : '',
      members: <String, String>{
        for (final MapEntry<dynamic, dynamic> e in (json['m'] as Map).entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      },
      pins: flatPinsFromJson(json['rk']),
      newKey: json['k'] as String,
      removed: keys(json['rm']),
      by: json['by'] as String,
      at: json['at'] as int,
      rival: FlatProfile.fromJson(json['rv']),
      rivalRemoved: keys(json['rvRm']),
      rivalBy: json['rvBy'] is String ? json['rvBy'] as String : '',
    );
  }
}

/// A message between two flats.
@immutable
final class FlatMessage {
  const FlatMessage({
    required this.id,
    required this.flat,
    required this.mine,
    required this.text,
    required this.at,
    this.by = '',
    this.item = '',
  });

  final String id;

  /// The invitation this message is about ("czat zaproszenia"); ''
  /// = a plain message between the flats.
  final String item;

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
    if (item.isNotEmpty) 'it': item,
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
      item: json['it'] is String && (json['it'] as String).length <= 40
          ? json['it'] as String
          : '',
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

/// An invitation that came over Bluetooth from a flat nearby.
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

/// What a household shows a flat before either side lets the other in
/// ("Co widzi pukający"): the name (and place) is on the door sticker
/// anyway; the rest only when the residents tick it. The same goes out
/// with this household's own knocks, as its card. Shared by the residents.
@immutable
final class FlatDoorView {
  const FlatDoorView({
    this.photo = false,
    this.names = false,
    this.items = false,
    this.about = false,
    this.note = '',
  });

  /// Longest note for knockers.
  static const int maxNote = 200;

  /// The household's photo.
  final bool photo;

  /// The residents' first names (as housemates know them).
  final bool names;

  /// Invitations, offers and needs.
  final bool items;

  /// "O nas".
  final bool about;

  /// A short note just for knockers ("Dzwonek nie działa — pukajcie").
  final String note;

  /// Nothing beyond what the sticker says: a knock gets no answer at all
  /// before "Wpuść" (the door stays silent).
  bool get bare => !photo && !names && !items && !about && note.isEmpty;

  FlatDoorView copyWith({
    bool? photo,
    bool? names,
    bool? items,
    bool? about,
    String? note,
  }) => FlatDoorView(
    photo: photo ?? this.photo,
    names: names ?? this.names,
    items: items ?? this.items,
    about: about ?? this.about,
    note: note ?? this.note,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (photo) 'ph': true,
    if (names) 'nm': true,
    if (items) 'it': true,
    if (about) 'ab': true,
    if (note.isNotEmpty) 'nt': note,
  };

  static FlatDoorView fromJson(Object? json) {
    if (json is! Map) {
      return const FlatDoorView();
    }
    final Object? note = json['nt'];
    return FlatDoorView(
      photo: json['ph'] == true,
      names: json['nm'] == true,
      items: json['it'] == true,
      about: json['ab'] == true,
      note: note is String
          ? (note.length > maxNote ? note.substring(0, maxNote) : note)
          : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FlatDoorView &&
      other.photo == photo &&
      other.names == names &&
      other.items == items &&
      other.about == about &&
      other.note == note;

  @override
  int get hashCode => Object.hash(photo, names, items, about, note);
}

/// A household's card: what a flat shows before it is let in, or before it
/// lets the other in ([FlatDoorView]). [profile] is the household's
/// profile cut down to what the card shows, signed with the household's
/// key at revision 0 and without residents, so the full profile replaces
/// it once it comes after "Wpuść".
@immutable
final class FlatCard {
  const FlatCard({
    required this.profile,
    this.names = const <String>[],
    this.note = '',
  });

  /// Residents' first names on a card at most.
  static const int maxNames = FlatProfile.maxMembers;

  final FlatProfile profile;

  /// The residents' first names, when the household shows them.
  final List<String> names;

  /// The household's note for knockers.
  final String note;

  String get key => profile.key;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': profile.toJson(),
    if (names.isNotEmpty) 'nm': names,
    if (note.isNotEmpty) 'nt': note,
  };

  /// The card in [json] (a knock's or a door's answer body); `null`
  /// without a profile. Its signature is checked by whoever takes it.
  static FlatCard? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final FlatProfile? profile = FlatProfile.fromJson(json['p']);
    if (profile == null) {
      return null;
    }
    final Object? names = json['nm'];
    final Object? note = json['nt'];
    return FlatCard(
      profile: profile,
      names: <String>[
        if (names is List)
          for (final Object? n in names.take(maxNames))
            if (n is String && n.trim().isNotEmpty)
              n.length > 40 ? n.substring(0, 40) : n,
      ],
      note: note is String
          ? (note.length > FlatDoorView.maxNote
                ? note.substring(0, FlatDoorView.maxNote)
                : note)
          : '',
    );
  }
}

/// Someone scanned our door and knocked: nothing goes back to them
/// until a resident lets them in (or the household shows knockers a card,
/// [FlatDoorView]), so the knock alone tells them nothing about who lives
/// here. It came to a resident's door, or while the phones were offline,
/// sealed through the friends who run the mailbox doors; every resident's
/// phone has it (the housemates pass it on), and the first answer counts
/// for all ([FlatKnockDecision]).
@immutable
final class FlatKnock {
  const FlatKnock({
    required this.card,
    required this.sender,
    required this.at,
    this.id = '',
    this.reply,
  });

  /// The knocking flat's card (signed, checked when it came): only its
  /// name and what it chose to show, never its residents.
  final FlatCard card;

  /// The knocking flat's (cut down) profile.
  FlatProfile get profile => card.profile;

  /// The door that knocked (the knocker's phone's door, never its own
  /// address).
  final String sender;

  /// When they knocked (a knock held by friends: when a friend took it).
  final int at;

  /// The knock's own id: every copy of one knock has it.
  final String id;

  /// The knocker's own mailbox doors: the answer after "Wpuść" waits there
  /// too, if their phone is offline by then.
  final FlatMailDoor? reply;

  String get key => profile.key;

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...card.toJson(),
    'a': sender,
    'at': at,
    if (id.isNotEmpty) 'id': id,
    'ra': ?reply?.toJson(),
  };

  static FlatKnock? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String || json['at'] is! int) {
      return null;
    }
    final FlatCard? card = FlatCard.fromJson(json);
    final Object? id = json['id'];
    return card == null
        ? null
        : FlatKnock(
            card: card,
            sender: json['a'] as String,
            at: json['at'] as int,
            id: id is String && id.length <= 40 ? id : '',
            reply: FlatMailDoor.fromJson(json['ra']),
          );
  }
}

/// A knock answered on one of the residents' phones: let in ([ok]) or
/// not. Every phone of the household closes that knock.
@immutable
final class FlatKnockDecision {
  const FlatKnockDecision({
    required this.flat,
    required this.id,
    required this.at,
    required this.ok,
  });

  /// The flat that knocked.
  final String flat;

  /// The knock ([FlatKnock.id]).
  final String id;
  final int at;
  final bool ok;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'f': flat,
    'id': id,
    'at': at,
    if (ok) 'ok': true,
  };

  static FlatKnockDecision? fromJson(Object? json) {
    if (json is! Map ||
        json['f'] is! String ||
        json['id'] is! String ||
        (json['id'] as String).length > 40 ||
        json['at'] is! int) {
      return null;
    }
    return FlatKnockDecision(
      flat: json['f'] as String,
      id: json['id'] as String,
      at: json['at'] as int,
      ok: json['ok'] == true,
    );
  }
}

/// A resident of a neighbour flat who showed their own account ("Pokaż mój
/// profil"): their name and where to send a friend invitation.
@immutable
final class FlatReveal {
  const FlatReveal({
    required this.flat,
    required this.name,
    required this.address,
    required this.resident,
    required this.at,
  });

  /// The flat they live in (its key).
  final String flat;
  final String name;

  /// Their own phone (the account's address): the only place a neighbour
  /// learns it.
  final String address;

  /// Their resident key in the flat's profile.
  final String resident;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'f': flat,
    'n': name,
    'a': address,
    'r': resident,
    'at': at,
  };

  static FlatReveal? fromJson(Object? json) {
    if (json is! Map ||
        json['f'] is! String ||
        json['n'] is! String ||
        json['a'] is! String ||
        json['r'] is! String ||
        json['at'] is! int ||
        !isRoutablePeerAddress(json['a'] as String)) {
      return null;
    }
    final String n = json['n'] as String;
    return FlatReveal(
      flat: json['f'] as String,
      name: n.length > 60 ? n.substring(0, 60) : n,
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      resident: json['r'] as String,
      at: json['at'] as int,
    );
  }
}
