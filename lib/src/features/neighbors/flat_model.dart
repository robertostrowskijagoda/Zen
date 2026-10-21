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
    this.signature = '',
  });

  /// Longest photo accepted in a profile (base64 characters).
  static const int maxPhotoChars = 100 * 1024;

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

  /// The doors to send to.
  Iterable<String> get doors =>
      members.values.where((String d) => d.isNotEmpty);

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
    if ((photo is String && photo.length > maxPhotoChars) ||
        (members is Map && members.length > maxMembers)) {
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
@immutable
final class FlatDoorCode {
  const FlatDoorCode({
    required this.key,
    required this.door,
    required this.inbox,
    required this.name,
    this.mail,
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
    return FlatDoorCode(
      key: json['k'] as String,
      door: json['d'] as String,
      inbox: PeerShareCodec.normalizeAddress(inbox),
      name: name.length > 150 ? name.substring(0, 150) : name,
      mail: FlatMailDoor.read(json['s'], json['x']),
    );
  }
}

/// What a housemate shows to let a new resident in: scanned only
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
    required this.profile,
    required this.addedAt,
    this.weScanned = false,
    this.scannedUs = false,
    this.following = true,
    Set<String>? seenItems,
    Map<String, int>? residents,
  }) : seenItems = seenItems ?? <String>{},
       residents = residents ?? <String, int>{};

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

/// Someone scanned our door and knocked: nothing goes back to them
/// until a resident lets them in, so the knock alone tells them nothing
/// about who lives here. It came to the door, or while this phone was
/// offline, sealed through the friends who run its mailbox doors.
@immutable
final class FlatKnock {
  const FlatKnock({
    required this.profile,
    required this.sender,
    required this.at,
    this.reply,
  });

  /// The knocking flat's profile (signed, checked when it came); its
  /// residents' keys are pinned when they are let in.
  final FlatProfile profile;

  /// The door that knocked (the knocker's phone's door, never its own
  /// address).
  final String sender;

  /// When they knocked (a knock held by friends: when a friend took it).
  final int at;

  /// The knocker's own mailbox doors: the answer after "Wpuść" waits there
  /// too, if their phone is offline by then.
  final FlatMailDoor? reply;

  String get key => profile.key;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': profile.toJson(),
    'a': sender,
    'at': at,
    'ra': ?reply?.toJson(),
  };

  static FlatKnock? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String || json['at'] is! int) {
      return null;
    }
    final FlatProfile? profile = FlatProfile.fromJson(json['p']);
    return profile == null
        ? null
        : FlatKnock(
            profile: profile,
            sender: json['a'] as String,
            at: json['at'] as int,
            reply: FlatMailDoor.fromJson(json['ra']),
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
