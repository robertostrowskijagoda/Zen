import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// How far an event reaches: only the people the organizer
/// picked, or as far as friends / friends of friends pass it on.
enum EventReach {
  selected(0),

  /// Only this person's close friends ("przyjaciele").
  close(0),
  friends(0),
  friendsOfFriends(1),
  twoSteps(2);

  const EventReach(this.hops);

  String get label => switch (this) {
    EventReach.selected => t('Wybrane osoby'),
    EventReach.close => t('Przyjaciele'),
    EventReach.friends => t('Znajomi'),
    EventReach.friendsOfFriends => t('Znajomi znajomych'),
    EventReach.twoSteps => t('Znajomi znajomych znajomych'),
  };

  /// How many times the invitation is passed on beyond the organizer's
  /// friends.
  final int hops;

  static EventReach byName(Object? n) =>
      EventReach.values.where((EventReach r) => r.name == n).firstOrNull ??
      EventReach.selected;
}

enum GuestStatus {
  invited,
  going,
  maybe,
  declined,

  /// Asked to come as someone's +1; the organizer decides.
  requested;

  String get label => switch (this) {
    GuestStatus.invited => t('Zaproszony(-a)'),
    GuestStatus.going => t('Będzie'),
    GuestStatus.maybe => t('Może'),
    GuestStatus.declined => t('Nie będzie'),
    GuestStatus.requested => t('Prosi o zaproszenie'),
  };

  static GuestStatus byName(Object? n) =>
      GuestStatus.values.where((GuestStatus s) => s.name == n).firstOrNull ??
      GuestStatus.invited;
}

/// Someone on an event's list.
@immutable
final class EventGuest {
  const EventGuest({
    required this.address,
    required this.name,
    this.status = GuestStatus.invited,
    this.broughtBy,
    this.plusOnes = 0,
    this.checkedIn = false,
  });

  final String address;
  final String name;
  final GuestStatus status;

  /// Who brought them (forwarded the invitation / asked for the +1).
  final String? broughtBy;

  /// How many people they may bring without asking.
  final int plusOnes;
  final bool checkedIn;

  EventGuest copyWith({
    String? name,
    GuestStatus? status,
    int? plusOnes,
    bool? checkedIn,
  }) => EventGuest(
    address: address,
    name: name ?? this.name,
    status: status ?? this.status,
    broughtBy: broughtBy,
    plusOnes: plusOnes ?? this.plusOnes,
    checkedIn: checkedIn ?? this.checkedIn,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    'n': name,
    's': status.name,
    if (broughtBy != null) 'by': broughtBy,
    if (plusOnes > 0) 'p1': plusOnes,
    if (checkedIn) 'in': true,
  };

  /// Reads a guest; on a list without addresses ([MeetEvent.toJson] with
  /// `blind`) the guest's address is `#` and the guest's hash
  /// ([MeetEvent.guestHash]).
  static EventGuest? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? a = json['a'];
    final Object? h = json['h'];
    final String address;
    if (a is String) {
      address = PeerShareCodec.normalizeAddress(a);
    } else if (h is String && _hashPattern.hasMatch(h)) {
      address = '#$h';
    } else {
      return null;
    }
    final Object? n = json['n'];
    final Object? by = json['by'];
    return EventGuest(
      address: address,
      name: n is String ? (n.length > 60 ? n.substring(0, 60) : n) : '',
      status: GuestStatus.byName(json['s']),
      broughtBy: by is String && by.length <= 100 ? by : null,
      plusOnes: json['p1'] is int ? (json['p1'] as int).clamp(0, 5) : 0,
      checkedIn: json['in'] == true,
    );
  }
}

/// What kind of gathering.
enum EventKind {
  party,
  dinner,
  table,
  meeting,
  other;

  String get label => switch (this) {
    EventKind.party => t('Impreza'),
    EventKind.dinner => t('Posiłek'),
    EventKind.table => t('Stół na sześć'),
    EventKind.meeting => t('Spotkanie'),
    EventKind.other => t('Inne'),
  };

  static EventKind byName(Object? n) =>
      EventKind.values.where((EventKind k) => k.name == n).firstOrNull ??
      EventKind.other;
}

/// An event "po znajomości": the organizer's device holds the truth
/// and sends every guest the current copy.
@immutable
final class MeetEvent {
  const MeetEvent({
    required this.id,
    required this.organizer,
    required this.organizerName,
    required this.title,
    required this.startsAt,
    this.kind = EventKind.other,
    this.description = '',
    this.place = '',
    this.reach = EventReach.selected,
    this.capacity = 0,
    this.askForPlusOne = true,
    this.guests = const <String, EventGuest>{},
    this.cancelled = false,
    this.updatedAt = 0,
  });

  final String id;

  /// The organizer's mesh address ('self' when it is this person).
  final String organizer;
  final String organizerName;
  final String title;
  final EventKind kind;
  final String description;
  final String place;
  final int startsAt;
  final EventReach reach;

  /// 0 = no limit.
  final int capacity;

  /// Guests may ask to bring someone (+1); the organizer decides.
  final bool askForPlusOne;

  final Map<String, EventGuest> guests;
  final bool cancelled;
  final int updatedAt;

  bool get isMine => organizer == 'self';

  /// What stands for [address] on a list without addresses: a hash bound
  /// to this event, so it says nothing elsewhere. Only who already knows
  /// the address can tell it is on the list.
  static String guestHash(String eventId, String address) => crypto.sha256
      .convert(
        utf8.encode(
          'zen-event-guest|$eventId|${PeerShareCodec.normalizeAddress(address)}',
        ),
      )
      .toString()
      .substring(0, 32);

  /// [address] as a key of a list without addresses.
  String blindKey(String address) => '#${guestHash(id, address)}';

  /// The list came without addresses (friends of friends see first names
  /// and how many they know, not where to find everyone).
  bool get blind => guests.keys.any((String k) => k.startsWith('#'));

  /// Which of [friends] the guest [g] is, also on a list without
  /// addresses (`null`: none of them).
  String? friendIn(EventGuest g, Iterable<String> friends) {
    for (final String f in friends) {
      final String a = PeerShareCodec.normalizeAddress(f);
      if (g.address == a || g.address == blindKey(a)) {
        return a;
      }
    }
    return null;
  }

  /// How many of those coming are among [friends] ("znasz 5").
  int knownGoing(Iterable<String> friends) {
    final Set<String> keys = <String>{
      for (final String f in friends) ...<String>[
        PeerShareCodec.normalizeAddress(f),
        blindKey(f),
      ],
    };
    return guests.values
        .where(
          (EventGuest g) =>
              g.status == GuestStatus.going && keys.contains(g.address),
        )
        .length;
  }

  int get goingCount => guests.values
      .where((EventGuest g) => g.status == GuestStatus.going)
      .length;

  bool get isFull => capacity > 0 && goingCount + 1 >= capacity;

  EventGuest? guest(String address) =>
      guests[PeerShareCodec.normalizeAddress(address)] ??
      guests[blindKey(address)];

  MeetEvent copyWith({
    String? title,
    String? description,
    String? place,
    int? startsAt,
    int? capacity,
    Map<String, EventGuest>? guests,
    bool? cancelled,
    int? updatedAt,
  }) => MeetEvent(
    id: id,
    organizer: organizer,
    organizerName: organizerName,
    title: title ?? this.title,
    kind: kind,
    description: description ?? this.description,
    place: place ?? this.place,
    startsAt: startsAt ?? this.startsAt,
    reach: reach,
    capacity: capacity ?? this.capacity,
    askForPlusOne: askForPlusOne,
    guests: guests ?? this.guests,
    cancelled: cancelled ?? this.cancelled,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Who brought [address], all the way back to the organizer
  /// ("Ola ← Kuba ← Ania").
  List<String> chainOf(String address) {
    final List<String> chain = <String>[];
    String? at = address.startsWith('#')
        ? address
        : PeerShareCodec.normalizeAddress(address);
    final Set<String> seen = <String>{};
    while (at != null && seen.add(at)) {
      final EventGuest? g = guests[at];
      if (g == null) {
        break;
      }
      chain.add(at);
      at = g.broughtBy;
    }
    return chain;
  }

  /// A guest as a list without addresses has them: the hash, the first
  /// name, the answer, who brought them (hashed too).
  Map<String, dynamic> _blindGuest(EventGuest g) {
    final String? by = g.broughtBy;
    final String first = g.name.trim().split(RegExp(r'\s+')).first;
    return <String, dynamic>{
      'h': g.address.startsWith('#')
          ? g.address.substring(1)
          : guestHash(id, g.address),
      'n': first,
      's': g.status.name,
      if (by != null) 'by': by.startsWith('#') ? by : blindKey(by),
      if (g.checkedIn) 'in': true,
    };
  }

  /// With [blind] the guest list has no addresses: what friends of friends
  /// get, who see only first names and how many they know. Guests with a
  /// ticket (and the organizer's friends) get the full list.
  Map<String, dynamic> toJson({bool blind = false}) => <String, dynamic>{
    'id': id,
    'org': organizer,
    'orgName': organizerName,
    'title': title,
    'kind': kind.name,
    if (description.isNotEmpty) 'desc': description,
    if (place.isNotEmpty) 'place': place,
    'at': startsAt,
    'reach': reach.name,
    if (capacity > 0) 'cap': capacity,
    if (!askForPlusOne) 'noPlus1': true,
    'guests': <Map<String, dynamic>>[
      for (final EventGuest g in guests.values)
        blind ? _blindGuest(g) : g.toJson(),
    ],
    if (cancelled) 'cancelled': true,
    'upd': updatedAt,
  };

  static MeetEvent? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? org = json['org'];
    final Object? title = json['title'];
    final Object? at = json['at'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 40 ||
        org is! String ||
        title is! String ||
        at is! int) {
      return null;
    }
    String clip(Object? v, int max) =>
        v is String ? (v.length > max ? v.substring(0, max) : v) : '';
    final Object? guests = json['guests'];
    return MeetEvent(
      id: id,
      organizer: org,
      organizerName: clip(json['orgName'], 60),
      title: clip(title, 100),
      kind: EventKind.byName(json['kind']),
      description: clip(json['desc'], 2000),
      place: clip(json['place'], 200),
      startsAt: at,
      reach: EventReach.byName(json['reach']),
      capacity: json['cap'] is int ? (json['cap'] as int).clamp(0, 10000) : 0,
      askForPlusOne: json['noPlus1'] != true,
      guests: <String, EventGuest>{
        if (guests is List)
          for (final Object? g in guests.take(2000))
            if (EventGuest.fromJson(g) != null)
              EventGuest.fromJson(g)!.address: EventGuest.fromJson(g)!,
      },
      cancelled: json['cancelled'] == true,
      updatedAt: json['upd'] is int ? json['upd'] as int : 0,
    );
  }
}

final RegExp _hashPattern = RegExp(r'^[0-9a-f]{32}$');

String _clipText(Object? v, int max) =>
    v is String ? (v.length > max ? v.substring(0, max) : v) : '';

/// A photo in an event's shared album ("po wydarzeniu"): added by a
/// guest who went (or the organizer), seen only by the event's guests.
@immutable
final class EventPhoto {
  const EventPhoto({
    required this.id,
    required this.by,
    required this.byName,
    required this.at,
    required this.data,
  });

  final String id;

  /// Who added it (mesh address; 'self' never travels).
  final String by;
  final String byName;
  final int at;

  /// The JPEG (or a small animated GIF, see `compressEventPhoto`),
  /// base64.
  final String data;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'by': by,
    'n': byName,
    'at': at,
    'd': data,
  };

  static EventPhoto? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        (json['id'] as String).length > 40 ||
        json['by'] is! String ||
        json['at'] is! int ||
        json['d'] is! String) {
      return null;
    }
    return EventPhoto(
      id: json['id'] as String,
      by: PeerShareCodec.normalizeAddress(json['by'] as String),
      byName: _clipText(json['n'], 60),
      at: json['at'] as int,
      data: json['d'] as String,
    );
  }
}

/// A gratitude card for the host ("karta wdzięczności"): a short
/// thank-you from a guest after the event.
@immutable
final class EventThanks {
  const EventThanks({
    required this.by,
    required this.byName,
    required this.text,
    required this.at,
  });

  /// Who thanked (mesh address; 'self' for this person's own card).
  final String by;
  final String byName;
  final String text;
  final int at;

  static const int maxChars = 200;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'by': by,
    'n': byName,
    't': text,
    'at': at,
  };

  static EventThanks? fromJson(Object? json) {
    if (json is! Map ||
        json['by'] is! String ||
        json['t'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final String by = json['by'] as String;
    return EventThanks(
      by: by == 'self' ? by : PeerShareCodec.normalizeAddress(by),
      byName: _clipText(json['n'], 60),
      text: _clipText(json['t'], maxChars),
      at: json['at'] as int,
    );
  }
}
