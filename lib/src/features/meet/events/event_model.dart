import 'package:flutter/foundation.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// How far an event reaches (§17.1): only the people the organizer
/// picked, or as far as friends / friends of friends pass it on.
enum EventReach {
  selected('Wybrane osoby', 0),
  friends('Znajomi', 0),
  friendsOfFriends('Znajomi znajomych', 1),
  twoSteps('Znajomi znajomych znajomych', 2);

  const EventReach(this.label, this.hops);

  final String label;

  /// How many times the invitation is passed on beyond the organizer's
  /// friends.
  final int hops;

  static EventReach byName(Object? n) =>
      EventReach.values.where((EventReach r) => r.name == n).firstOrNull ??
      EventReach.selected;
}

enum GuestStatus {
  invited('Zaproszony(-a)'),
  going('Będzie'),
  maybe('Może'),
  declined('Nie będzie'),

  /// Asked to come as someone's +1; the organizer decides.
  requested('Prosi o zaproszenie');

  const GuestStatus(this.label);

  final String label;

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

  static EventGuest? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String) {
      return null;
    }
    final Object? n = json['n'];
    return EventGuest(
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      name: n is String ? (n.length > 60 ? n.substring(0, 60) : n) : '',
      status: GuestStatus.byName(json['s']),
      broughtBy: json['by'] is String ? json['by'] as String : null,
      plusOnes: json['p1'] is int ? (json['p1'] as int).clamp(0, 5) : 0,
      checkedIn: json['in'] == true,
    );
  }
}

/// What kind of gathering.
enum EventKind {
  party('Impreza'),
  dinner('Posiłek'),
  table('Stół na sześć'),
  meeting('Spotkanie'),
  other('Inne');

  const EventKind(this.label);

  final String label;

  static EventKind byName(Object? n) =>
      EventKind.values.where((EventKind k) => k.name == n).firstOrNull ??
      EventKind.other;
}

/// An event "po znajomości" (§17): the organizer's device holds the truth
/// and sends every guest the current copy.
@immutable
final class MeetEvent {
  const MeetEvent({
    required this.id,
    required this.organizer,
    required this.organizerName,
    required this.title,
    required this.startsAt,
    required this.ticketKey,
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

  /// Public key the tickets are signed with.
  final String ticketKey;
  final Map<String, EventGuest> guests;
  final bool cancelled;
  final int updatedAt;

  bool get isMine => organizer == 'self';

  int get goingCount => guests.values
      .where((EventGuest g) => g.status == GuestStatus.going)
      .length;

  bool get isFull => capacity > 0 && goingCount + 1 >= capacity;

  EventGuest? guest(String address) =>
      guests[PeerShareCodec.normalizeAddress(address)];

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
    ticketKey: ticketKey,
    guests: guests ?? this.guests,
    cancelled: cancelled ?? this.cancelled,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Who brought [address], all the way back to the organizer
  /// ("Ola ← Kuba ← Ania").
  List<String> chainOf(String address) {
    final List<String> chain = <String>[];
    String? at = PeerShareCodec.normalizeAddress(address);
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

  Map<String, dynamic> toJson() => <String, dynamic>{
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
    'tk': ticketKey,
    'guests': <Map<String, dynamic>>[
      for (final EventGuest g in guests.values) g.toJson(),
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
    final Object? tk = json['tk'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 40 ||
        org is! String ||
        title is! String ||
        at is! int ||
        tk is! String) {
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
      ticketKey: tk,
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

String _clipText(Object? v, int max) =>
    v is String ? (v.length > max ? v.substring(0, max) : v) : '';

/// A photo in an event's shared album (§17.1, "po wydarzeniu"): added by a
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

  /// The JPEG, base64.
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

/// A gratitude card for the host ("karta wdzięczności", §17.1): a short
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
