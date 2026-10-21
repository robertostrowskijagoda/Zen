import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class EventTypes {
  static const String event = 'event';
  static const String rsvp = 'event_rsvp';
  static const String plusOne = 'event_plus1';

  /// A photo for the event's shared album (guest → organizer → guests).
  static const String photo = 'event_photo';

  /// A gratitude card for the host (guest → organizer).
  static const String thanks = 'event_thanks';

  /// Organizer → the friend who vouches for a guest the organizer does not
  /// know (a +1, a guest of "Stół na sześć"): "pass the invitation on to
  /// them". Invitations from someone who is not a friend are never taken
  /// on their own word; they come through the friend who vouches.
  static const String pass = 'event_pass';

  static const Set<String> all = <String>{
    event,
    rsvp,
    plusOne,
    photo,
    thanks,
    pass,
  };
}

/// What [EventService] needs from the app.
abstract interface class EventHost {
  Future<void> send(String to, Map<String, dynamic> payload);
  List<String> friends();
  bool isFriend(String address);
  String ownAddress();
  String ownName();
  String nameOf(String address);
  Future<void> notify(RuntimeSystemNotification notification);
}

/// A signed ticket: shown as a QR code at the door, checked by the
/// organizer's phone without internet.
///
/// Pinned to the guest's phone: "Będę" sends the organizer a key that only
/// this phone holds, the organizer signs it into the ticket, and the code
/// shown at the door carries a fresh signature with that key (renewed every
/// 20 s, valid ±90 s, once). A screenshot passed on to someone else stops
/// working after about a minute and a half.
@immutable
final class EventTicket {
  const EventTicket({
    required this.eventId,
    required this.guest,
    required this.name,
    required this.signature,
    required this.pin,
    this.liveAt,
    this.proof,
  });

  final String eventId;
  final String guest;
  final String name;
  final String signature;

  /// The guest phone's own public key (Ed25519) signed into the ticket.
  final String pin;

  /// The live code shown at the door: the start of its 30 s window and the
  /// phone's signature over it (`null` in a bare ticket).
  final int? liveAt;
  final String? proof;

  static const String qrPrefix = 'zen-ticket:';

  /// A live code belongs to a 30 s window.
  static const int liveWindow = 30 * 1000;

  /// How far the code's time may be from the organizer's clock.
  static const int liveSlack = 90 * 1000;

  /// How often the guest's phone renews the code on the screen.
  static const Duration liveRefresh = Duration(seconds: 20);

  /// The start of the window [millis] falls in.
  static int windowOf(int millis) => millis - millis % liveWindow;

  /// What the organizer signs.
  static Uint8List signedBytes(
    String eventId,
    String guest,
    String name,
    String pin,
  ) => canonicalJsonBytes(<String, dynamic>{
    't': 'zen_ticket',
    'e': eventId,
    'g': guest,
    'n': name,
    'k': pin,
  });

  /// What the guest's phone signs for the code shown at [at].
  static Uint8List liveBytes(String eventId, String guest, int at) =>
      canonicalJsonBytes(<String, dynamic>{
        't': 'zen_ticket_live',
        'e': eventId,
        'g': guest,
        'at': at,
      });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'e': eventId,
    'g': guest,
    'n': name,
    's': signature,
    'k': pin,
  };

  /// The ticket alone, without a live code (the door refuses it).
  String toQr() =>
      '$qrPrefix${base64Url.encode(utf8.encode(jsonEncode(toJson())))}';

  /// The live code: the ticket plus the phone's signature for [at].
  String toLiveQr(int at, String liveSignature) {
    final Map<String, dynamic> json = <String, dynamic>{
      ...toJson(),
      'at': at,
      'p': liveSignature,
    };
    return '$qrPrefix${base64Url.encode(utf8.encode(jsonEncode(json)))}';
  }

  static EventTicket? fromJson(Object? json) {
    if (json is! Map ||
        json['e'] is! String ||
        json['g'] is! String ||
        json['n'] is! String ||
        json['s'] is! String ||
        unb64(json['k'], length: 32) == null) {
      return null;
    }
    return EventTicket(
      eventId: json['e'] as String,
      guest: json['g'] as String,
      name: json['n'] as String,
      signature: json['s'] as String,
      pin: json['k'] as String,
      liveAt: json['at'] is int ? json['at'] as int : null,
      proof: json['p'] is String ? json['p'] as String : null,
    );
  }

  static EventTicket? fromQr(String text) {
    if (!text.startsWith(qrPrefix)) {
      return null;
    }
    try {
      return fromJson(
        jsonDecode(
          utf8.decode(base64Url.decode(text.substring(qrPrefix.length))),
        ),
      );
    } on Object {
      return null;
    }
  }

  /// The organizer's signature, classical Ed25519
  /// ([LedgerKeyPair.signClassical]): the ticket and its live code must fit
  /// one QR code, which a hybrid signature (5.3 KB) does not. It is checked
  /// at the door during the event, so forging one would take a quantum
  /// computer then.
  Future<bool> verify(String ticketKey) => verifyClassicalSignature(
    publicKey: ticketKey,
    message: signedBytes(eventId, guest, name, pin),
    signature: signature,
  );
}

/// What a check-in at the door found.
enum CheckIn {
  ok,
  already,
  notGoing,
  invalid,
  otherEvent,

  /// The ticket is pinned to the guest's phone, but the code is not a live
  /// one from just now (a screenshot or an old copy).
  expired,

  /// This very code has already been used at the door.
  replayed,
}

/// Events "po znajomości": the organizer's phone keeps the
/// event and its guest list and sends everyone the current copy; guests
/// answer, ask to bring someone, and pass the invitation on as far as the
/// organizer allowed.
final class EventService extends ChangeNotifier {
  EventService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
    Future<Uint8List?> Function(Uint8List bytes)? cleanPhoto,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure(),
       _cleanPhoto =
           cleanPhoto ??
           ((Uint8List b) => compute(compressRemoteEventPhoto, b));

  final EventHost host;
  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;

  /// Re-encodes a photo from another phone (an isolate in the app).
  final Future<Uint8List?> Function(Uint8List bytes) _cleanPhoto;
  static const String _key = 'meet/events';

  static const int _day = 24 * 3600 * 1000;

  /// Events are kept this long after they start.
  static const int _keepAfter = 30 * _day;

  /// How far ahead an event of someone else may be (a year and a bit):
  /// one further away would never be cleaned up.
  static const int maxAhead = 400 * _day;

  /// Flood guards on the receiving side (each phone protects itself; nobody
  /// central checks anything). Ordinary use never comes near them:
  /// new invitations taken in from one friend a day (their own events and
  /// those they pass on), invitations kept from one friend, and in all.
  static const int maxNewEventsPerFriendPerDay = 30;
  static const int maxEventsPerFriend = 60;
  static const int maxForeignEvents = 400;

  /// Guests who join an event through friends (not invited by name) stop
  /// being taken in at this size of the list.
  static const int maxGuests = 1000;

  /// Invitations one friend may ask this phone to pass on (as the friend
  /// who vouches) in a day.
  static const int maxPassesPerFriendPerDay = 20;

  /// People one guest may bring or ask to bring (answered or not).
  static const int maxPlusOnesPerGuest = 10;

  /// Where an event's album is kept (one file per event, so the photos
  /// are not rewritten with every answer).
  static String albumKey(String id) => 'meet/event-album/$id';

  /// Photos in one album, and per person.
  static const int maxPhotosPerEvent = 120;
  static const int maxPhotosPerGuest = 20;

  /// Photos may be added from a little before the start.
  static const int _photoLead = 15 * 60 * 1000;

  /// Shared albums (event id → photos).
  final Map<String, List<EventPhoto>> _albums = <String, List<EventPhoto>>{};

  /// Gratitude cards: for the organizer the ones received, for a guest
  /// their own (by 'self').
  final Map<String, List<EventThanks>> _thanks = <String, List<EventThanks>>{};

  final Map<String, MeetEvent> _events = <String, MeetEvent>{};

  /// Ticket signing seeds of this person's events.
  final Map<String, String> _seeds = <String, String>{};

  /// This person's tickets (event id → ticket).
  final Map<String, EventTicket> _tickets = <String, EventTicket>{};

  /// As the organizer: the keys of the guests' phones (event id → guest
  /// address → public key), sent with "Będę". Tickets are pinned to them.
  final Map<String, Map<String, String>> _guestKeys =
      <String, Map<String, String>>{};

  /// As a guest: this phone's own key for each event it said "Będę" to
  /// (event id → seed, and → public key).
  final Map<String, String> _pinSeeds = <String, String>{};
  final Map<String, String> _pinKeys = <String, String>{};
  final Map<String, LedgerKeyPair> _pinPairs = <String, LedgerKeyPair>{};

  /// Live codes already used at the door (signature → when), so the same
  /// code never opens it twice.
  final Map<String, int> _usedCodes = <String, int>{};

  /// How an invitation reached us (event id → chain of people from the
  /// organizer's friend to the one who passed it on, as JSON).
  final Map<String, String> _via = <String, String>{};
  final Set<String> _forwarded = <String>{};

  /// The invitation token the friend who passed an invitation on gave us
  /// (event id → token): the organizer takes our answer only with it
  /// (see [_hop]).
  final Map<String, String> _tokens = <String, String>{};

  /// New invitations taken in per friend (when), and invitations passed on
  /// as the one who vouches (per organizer, when; and which ones).
  final Map<String, List<int>> _newFrom = <String, List<int>>{};
  final Map<String, List<int>> _passesFrom = <String, List<int>>{};
  final Set<String> _passed = <String>{};
  Future<void> _queue = Future<void>.value();

  int get now => _now();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  List<MeetEvent> get events =>
      _events.values.toList()
        ..sort((MeetEvent a, MeetEvent b) => a.startsAt.compareTo(b.startsAt));

  MeetEvent? event(String id) => _events[id];

  EventTicket? ticket(String id) => _tickets[id];

  /// Whether this phone's ticket for [id] is pinned to this phone (the
  /// organizer signed this phone's key into it).
  bool ticketPinned(String id) {
    final EventTicket? t = _tickets[id];
    return t != null && t.pin == _pinKeys[id];
  }

  /// The organizer's real address (for sending to them).
  String organizerAddress(MeetEvent e) =>
      e.isMine ? host.ownAddress() : e.organizer;

  /// This person's own entry on [e].
  EventGuest? myGuest(MeetEvent e) =>
      e.isMine ? null : e.guest(host.ownAddress());

  static bool _went(EventGuest? g) =>
      g != null && (g.status == GuestStatus.going || g.checkedIn);

  bool _started(MeetEvent e) => _now() >= e.startsAt - _photoLead;

  /// The album of [id], oldest first.
  List<EventPhoto> photos(String id) =>
      List<EventPhoto>.of(_albums[id] ?? const <EventPhoto>[])
        ..sort((EventPhoto a, EventPhoto b) => a.at.compareTo(b.at));

  /// Whether this person may add photos to [e]: it has started, and they
  /// organize it or went.
  bool canAddPhotos(MeetEvent e) =>
      !e.cancelled && _started(e) && (e.isMine || _went(myGuest(e)));

  /// Gratitude cards the organizer got for [id], newest first.
  List<EventThanks> thanksFor(String id) =>
      (_thanks[id] ?? const <EventThanks>[])
          .where((EventThanks t) => t.by != 'self')
          .toList()
        ..sort((EventThanks a, EventThanks b) => b.at.compareTo(a.at));

  /// The card this person sent for [id], if any.
  EventThanks? myThanks(String id) => (_thanks[id] ?? const <EventThanks>[])
      .where((EventThanks t) => t.by == 'self')
      .firstOrNull;

  /// A guest who went may thank the host once the event has started.
  bool canThank(MeetEvent e) =>
      !e.isMine && !e.cancelled && _now() >= e.startsAt && _went(myGuest(e));

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
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
      _events.clear();
      for (final Object? e in (json['events'] as List?) ?? const <Object?>[]) {
        final MeetEvent? ev = MeetEvent.fromJson(e);
        if (ev != null) {
          _events[ev.id] = ev;
        }
      }
      (json['seeds'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is String) {
          _seeds[k] = v;
        }
      });
      (json['tickets'] as Map?)?.forEach((Object? k, Object? v) {
        final EventTicket? t = EventTicket.fromJson(v);
        if (k is String && t != null) {
          _tickets[k] = t;
        }
      });
      _guestKeys.clear();
      (json['gkeys'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          _guestKeys[k] = <String, String>{
            for (final MapEntry<dynamic, dynamic> g in v.entries)
              if (g.key is String && unb64(g.value, length: 32) != null)
                _n(g.key as String): g.value as String,
          };
        }
      });
      _pinSeeds.clear();
      _pinKeys.clear();
      _pinPairs.clear();
      (json['pins'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String &&
            v is Map &&
            unb64(v['s'], length: 32) != null &&
            unb64(v['k'], length: 32) != null) {
          _pinSeeds[k] = v['s'] as String;
          _pinKeys[k] = v['k'] as String;
        }
      });
      _via.clear();
      (json['via'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is String) {
          _via[k] = v;
        }
      });
      _forwarded
        ..clear()
        ..addAll(
          ((json['fwd'] as List?) ?? const <Object?>[]).whereType<String>(),
        );
      _tokens.clear();
      (json['tok'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && unb64(v, length: 32) != null) {
          _tokens[k] = v as String;
        }
      });
      _thanks.clear();
      (json['thanks'] as Map?)?.forEach((Object? k, Object? v) {
        if (k is String && v is List) {
          _thanks[k] = <EventThanks>[
            for (final Object? t in v.take(500))
              if (EventThanks.fromJson(t) != null) EventThanks.fromJson(t)!,
          ];
        }
      });
      _albums.clear();
      for (final String id in _events.keys) {
        final Uint8List? album = await disk.read(albumKey(id));
        final Object? list = album == null
            ? null
            : jsonDecode(utf8.decode(album));
        if (list is List) {
          _albums[id] = <EventPhoto>[
            for (final Object? p in list.take(maxPhotosPerEvent))
              if (EventPhoto.fromJson(p) != null) EventPhoto.fromJson(p)!,
          ];
        }
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt wydarzeń', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    // Old events go after a month.
    final int cutoff = _now() - _keepAfter;
    final List<String> gone = <String>[
      for (final MeetEvent e in _events.values)
        if (e.startsAt < cutoff) e.id,
    ];
    for (final String id in gone) {
      _events.remove(id);
      _thanks.remove(id);
      _guestKeys.remove(id);
      _pinSeeds.remove(id);
      _pinKeys.remove(id);
      _pinPairs.remove(id);
      _albums.remove(id);
      // Always, even when this copy never loaded the album (another copy of
      // the service, e.g. the one in the background, may have written it).
      await disk.delete(albumKey(id));
    }
    // How invitations came, and which were passed on, go with their events.
    _via.removeWhere((String id, String _) => !_events.containsKey(id));
    _forwarded.removeWhere((String id) => !_events.containsKey(id));
    _tokens.removeWhere((String id, String _) => !_events.containsKey(id));
    await disk.write(
      _key,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'events': <Map<String, dynamic>>[
              for (final MeetEvent e in _events.values) e.toJson(),
            ],
            'seeds': <String, String>{
              for (final MapEntry<String, String> s in _seeds.entries)
                if (_events.containsKey(s.key)) s.key: s.value,
            },
            'tickets': <String, dynamic>{
              for (final MapEntry<String, EventTicket> t in _tickets.entries)
                if (_events.containsKey(t.key)) t.key: t.value.toJson(),
            },
            'gkeys': <String, dynamic>{
              for (final MapEntry<String, Map<String, String>> g
                  in _guestKeys.entries)
                if (_events.containsKey(g.key) && g.value.isNotEmpty)
                  g.key: g.value,
            },
            'pins': <String, dynamic>{
              for (final MapEntry<String, String> p in _pinSeeds.entries)
                if (_events.containsKey(p.key) && _pinKeys[p.key] != null)
                  p.key: <String, String>{'s': p.value, 'k': _pinKeys[p.key]!},
            },
            'via': _via,
            'fwd': _forwarded.toList(),
            if (_tokens.isNotEmpty) 'tok': _tokens,
            'thanks': <String, dynamic>{
              for (final MapEntry<String, List<EventThanks>> t
                  in _thanks.entries)
                if (_events.containsKey(t.key))
                  t.key: <Map<String, dynamic>>[
                    for (final EventThanks c in t.value) c.toJson(),
                  ],
            },
          }),
        ),
      ),
    );
    notifyListeners();
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Wydarzenia', error, stack);
      }
    });
  }

  /// Waits for queued work (tests).
  Future<void> get idle => _queue;

  String _newId() => List<String>.generate(
    16,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  // ---- organizing ----

  /// Creates an event and invites [invite] (for "wybrane osoby") or all
  /// friends (wider reaches).
  Future<MeetEvent> create({
    required String title,
    required int startsAt,
    EventKind kind = EventKind.other,
    String description = '',
    String place = '',
    EventReach reach = EventReach.selected,
    int capacity = 0,
    bool askForPlusOne = true,
    List<String> invite = const <String>[],
    Map<String, String> vouchers = const <String, String>{},
  }) async {
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final List<String> to = reach == EventReach.selected
        ? invite
        : host.friends();
    final MeetEvent e = MeetEvent(
      id: _newId(),
      organizer: 'self',
      organizerName: host.ownName(),
      title: title,
      kind: kind,
      description: description,
      place: place,
      startsAt: startsAt,
      reach: reach,
      capacity: capacity,
      askForPlusOne: askForPlusOne,
      ticketKey: key.id,
      guests: <String, EventGuest>{
        for (final String a in to)
          _n(a): EventGuest(
            address: _n(a),
            name: host.nameOf(a),
            // Someone the host does not know directly (Stół na sześć):
            // the friend in between vouches for the invitation.
            broughtBy: vouchers[a] == null ? null : _n(vouchers[a]!),
          ),
      },
      updatedAt: _now(),
    );
    _events[e.id] = e;
    _seeds[e.id] = b64(key.seed);
    await _save();
    await _broadcast(
      e,
      passFor: <String>[
        for (final EventGuest g in e.guests.values)
          if (g.broughtBy != null) g.address,
      ],
    );
    return e;
  }

  /// Changes this person's event [id] and sends everyone the new copy;
  /// guests in [passFor] (newly invited people the organizer does not know)
  /// get the invitation through the friend who vouches for them.
  Future<MeetEvent?> _change(
    String id,
    MeetEvent Function(MeetEvent e) change, {
    Iterable<String> passFor = const <String>[],
  }) async {
    final MeetEvent? e = _events[id];
    if (e == null || !e.isMine) {
      return null;
    }
    final MeetEvent updated = change(e).copyWith(updatedAt: _now());
    _events[id] = updated;
    await _save();
    await _broadcast(updated, passFor: passFor);
    return updated;
  }

  Future<void> cancel(String id) =>
      _change(id, (MeetEvent e) => e.copyWith(cancelled: true));

  Future<void> inviteMore(String id, List<String> addresses) => _change(
    id,
    (MeetEvent e) => e.copyWith(
      guests: <String, EventGuest>{
        ...e.guests,
        for (final String a in addresses)
          if (!e.guests.containsKey(_n(a)))
            _n(a): EventGuest(address: _n(a), name: host.nameOf(a)),
      },
    ),
  );

  /// Lets [guest] bring [count] people without asking.
  Future<void> allowPlusOnes(String id, String guest, int count) => _change(
    id,
    (MeetEvent e) => e.copyWith(
      guests: <String, EventGuest>{
        ...e.guests,
        if (e.guest(guest) != null)
          _n(guest): e.guest(guest)!.copyWith(plusOnes: count),
      },
    ),
  );

  /// Accepts or refuses a +1 request.
  Future<void> decidePlusOne(String id, String address, bool accept) {
    final EventGuest? asked = _events[id]?.guest(address);
    return _change(
      id,
      (MeetEvent e) {
        final EventGuest? g = e.guest(address);
        if (g == null || g.status != GuestStatus.requested) {
          return e;
        }
        final Map<String, EventGuest> guests = Map<String, EventGuest>.of(
          e.guests,
        );
        if (accept) {
          guests[g.address] = g.copyWith(status: GuestStatus.invited);
        } else {
          guests.remove(g.address);
        }
        return e.copyWith(guests: guests);
      },
      passFor: <String>[
        if (accept && asked != null && asked.status == GuestStatus.requested)
          asked.address,
      ],
    );
  }

  Future<void> removeGuest(String id, String address) {
    _guestKeys[id]?.remove(_n(address));
    return _change(id, (MeetEvent e) {
      final Map<String, EventGuest> guests = Map<String, EventGuest>.of(
        e.guests,
      )..remove(_n(address));
      return e.copyWith(guests: guests);
    });
  }

  /// The ticket of [g], pinned to the key of their phone (`null` before it
  /// came).
  Future<EventTicket?> _ticketFor(MeetEvent e, EventGuest g) async {
    final String? pin = _guestKeys[e.id]?[g.address];
    if (pin == null) {
      return null;
    }
    final LedgerKeyPair key = await LedgerKeyPair.fromSeed(
      unb64(_seeds[e.id], length: 32)!,
    );
    // Classical: the ticket goes into a QR code at the door.
    final Uint8List sig = await key.signClassical(
      EventTicket.signedBytes(e.id, g.address, g.name, pin),
    );
    return EventTicket(
      eventId: e.id,
      guest: g.address,
      name: g.name,
      signature: b64(sig),
      pin: pin,
    );
  }

  /// Sends the current copy to every guest (with their ticket when they
  /// are coming). The first send to the organizer's friends carries how far
  /// it may be passed on, and the key for passing it on ([_hop]). Guests in
  /// [passFor] who do not know the organizer get it through the friend who
  /// vouches for them ([EventTypes.pass]).
  Future<void> _broadcast(
    MeetEvent e, {
    Iterable<String> passFor = const <String>[],
  }) async {
    final String own = host.ownAddress();
    final Map<String, dynamic> eventJson = e.toJson()..['org'] = own;
    final Uint8List? root = _rootKey(e.id);
    for (final String a in passFor) {
      final EventGuest? g = e.guest(a);
      final String? by = g?.broughtBy;
      if (g == null ||
          by == null ||
          g.status == GuestStatus.requested ||
          by == _n(own) ||
          e.cancelled) {
        continue;
      }
      await _send(by, <String, dynamic>{
        'type': EventTypes.pass,
        'e': eventJson,
        'to': g.address,
      });
    }
    for (final EventGuest g in e.guests.values) {
      if (g.status == GuestStatus.requested) {
        continue;
      }
      final EventTicket? t = g.status == GuestStatus.going && !e.cancelled
          ? await _ticketFor(e, g)
          : null;
      final bool passes = e.reach.hops > 0 && g.broughtBy == null;
      await _send(g.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': eventJson,
        if (t != null) 't': t.toJson(),
        if (passes) 'hops': e.reach.hops,
        if (passes && root != null) 'fk': b64(_hop(root, 'fwd', g.address)),
      });
    }
  }

  // ---- who may answer ("zasięg w krokach") ----

  /// One step of the invitation keys. The organizer derives, from its own
  /// secret, a key for each friend it invites (`fwd`); whoever passes the
  /// invitation on derives from their key the next one for the friend they
  /// pass it to (`fwd`) and an invitation token for that friend's address
  /// (`inv`). The organizer recomputes the whole chain, so an answer from
  /// someone it does not know counts only when the invitation really
  /// reached that address along the chain it names — a stranger cannot
  /// just claim to be "a friend of Kuba".
  static Uint8List _hop(List<int> key, String label, String address) =>
      Uint8List.fromList(
        crypto.Hmac(crypto.sha256, key)
            .convert(
              utf8.encode(
                'zen-event|$label|${PeerShareCodec.normalizeAddress(address)}',
              ),
            )
            .bytes,
      );

  /// The organizer's secret for the invitation keys of its event [id]
  /// (derived from the event's ticket seed, so nothing new is stored).
  Uint8List? _rootKey(String id) {
    final Uint8List? seed = unb64(_seeds[id], length: 32);
    if (seed == null) {
      return null;
    }
    return Uint8List.fromList(
      crypto.Hmac(
        crypto.sha256,
        seed,
      ).convert(utf8.encode('zen-event-root|$id')).bytes,
    );
  }

  /// Whether [token] shows that the invitation to this person's event [e]
  /// reached [from] along [chain] (see [_hop]).
  bool _tokenFits(
    MeetEvent e,
    List<Map<String, String>> chain,
    String from,
    Object? token,
  ) {
    final Uint8List? root = _rootKey(e.id);
    final Uint8List? got = unb64(token, length: 32);
    if (root == null || got == null || chain.isEmpty) {
      return false;
    }
    List<int> key = _hop(root, 'fwd', chain.first['a']!);
    for (int i = 1; i < chain.length; i++) {
      key = _hop(key, 'fwd', chain[i]['a']!);
    }
    final Uint8List want = _hop(key, 'inv', from);
    int diff = 0;
    for (int i = 0; i < want.length; i++) {
      diff |= want[i] ^ got[i];
    }
    return diff == 0;
  }

  /// Checks a ticket at the door (offline): a valid ticket of a guest who
  /// is coming, used once, and only with a live code from the phone it is
  /// pinned to (from the last ±90 s, not used before).
  Future<(CheckIn, EventGuest?)> checkIn(String eventId, String qr) async {
    final MeetEvent? e = _events[eventId];
    final EventTicket? t = EventTicket.fromQr(qr);
    if (e == null || !e.isMine || t == null) {
      return (CheckIn.invalid, null);
    }
    if (t.eventId != e.id) {
      return (CheckIn.otherEvent, null);
    }
    if (!await t.verify(e.ticketKey)) {
      return (CheckIn.invalid, null);
    }
    final EventGuest? g = e.guest(t.guest);
    if (g == null || g.status != GuestStatus.going) {
      return (CheckIn.notGoing, g);
    }
    final String pin = _guestKeys[e.id]?[g.address] ?? t.pin;
    final int now = _now();
    final int? at = t.liveAt;
    final String? proof = t.proof;
    if (at == null ||
        proof == null ||
        (now - at).abs() > EventTicket.liveSlack) {
      return (CheckIn.expired, g);
    }
    if (!await verifyClassicalSignature(
      publicKey: pin,
      message: EventTicket.liveBytes(t.eventId, t.guest, at),
      signature: proof,
    )) {
      return (CheckIn.invalid, null);
    }
    _usedCodes.removeWhere(
      (String _, int when) =>
          now - when > 2 * EventTicket.liveSlack + EventTicket.liveWindow,
    );
    if (_usedCodes.containsKey(proof)) {
      return (CheckIn.replayed, g);
    }
    _usedCodes[proof] = now;
    if (g.checkedIn) {
      return (CheckIn.already, g);
    }
    await _change(
      e.id,
      (MeetEvent ev) => ev.copyWith(
        guests: <String, EventGuest>{
          ...ev.guests,
          g.address: g.copyWith(checkedIn: true),
        },
      ),
    );
    return (CheckIn.ok, g);
  }

  // ---- as a guest ----

  /// Answers an invitation. "Będę" also sends this phone's own key for the
  /// event, so the ticket gets pinned to this phone. Saying it
  /// again pins a ticket that is not pinned yet.
  Future<void> rsvp(String id, GuestStatus status) async {
    final MeetEvent? e = _events[id];
    if (e == null || e.isMine) {
      return;
    }
    final LedgerKeyPair? pin = status == GuestStatus.going
        ? await _pinPair(id)
        : null;
    await _send(e.organizer, <String, dynamic>{
      'type': EventTypes.rsvp,
      'id': id,
      's': status.name,
      'n': host.ownName(),
      if (pin != null) 'pk': pin.id,
      if (_via[id] != null) 'chain': jsonDecode(_via[id]!),
      if (_tokens[id] != null) 'tok': _tokens[id],
    });
  }

  /// This phone's own key for the event [id] (made the first time).
  Future<LedgerKeyPair> _pinPair(String id) async {
    final LedgerKeyPair? had = _pinPairs[id];
    if (had != null) {
      return had;
    }
    final Uint8List? seed = unb64(_pinSeeds[id], length: 32);
    final LedgerKeyPair pair = seed == null
        ? await LedgerKeyPair.generate()
        : await LedgerKeyPair.fromSeed(seed);
    _pinPairs[id] = pair;
    if (seed == null) {
      _pinSeeds[id] = b64(pair.seed);
      _pinKeys[id] = pair.id;
      await _save();
    }
    return pair;
  }

  /// What this phone shows at the door for [id] right now (`null` without
  /// a ticket): the ticket with a fresh signature of this phone's key,
  /// which changes every 30 s, so a screenshot forwarded to someone else is
  /// useless after about a minute and a half.
  Future<String?> ticketQr(String id) async {
    final EventTicket? t = _tickets[id];
    if (t == null) {
      return null;
    }
    final LedgerKeyPair pair = await _pinPair(id);
    final int at = EventTicket.windowOf(_now());
    final Uint8List sig = await pair.signClassical(
      EventTicket.liveBytes(t.eventId, t.guest, at),
    );
    return t.toLiveQr(at, b64(sig));
  }

  /// The chain an invitation came through ({a, n} items), or empty.
  List<Map<String, String>> _chainOf(Object? json) {
    if (json is! List || json.length > 5) {
      return const <Map<String, String>>[];
    }
    final List<Map<String, String>> out = <Map<String, String>>[];
    for (final Object? item in json) {
      if (item is! Map || item['a'] is! String) {
        return const <Map<String, String>>[];
      }
      final Object? n = item['n'];
      out.add(<String, String>{
        'a': _n(item['a'] as String),
        'n': n is String ? (n.length > 60 ? n.substring(0, 60) : n) : '',
      });
    }
    return out;
  }

  /// Asks to bring [address] (a friend of this person) along.
  Future<void> askPlusOne(String id, String address) async {
    final MeetEvent? e = _events[id];
    if (e == null || e.isMine) {
      return;
    }
    await _send(e.organizer, <String, dynamic>{
      'type': EventTypes.plusOne,
      'id': id,
      'a': _n(address),
      'n': host.nameOf(address),
    });
  }

  // ---- incoming ----

  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !EventTypes.all.contains(type)) {
      return false;
    }
    final Completer<void> done = Completer<void>();
    _enqueue(() async {
      try {
        switch (type) {
          case EventTypes.event:
            await _onEvent(_n(frame.from), frame.payload);
          case EventTypes.rsvp:
            await _onRsvp(_n(frame.from), frame.payload);
          case EventTypes.plusOne:
            await _onPlusOne(_n(frame.from), frame.payload);
          case EventTypes.photo:
            await _onPhoto(_n(frame.from), frame.payload);
          case EventTypes.thanks:
            await _onThanks(_n(frame.from), frame.payload);
          case EventTypes.pass:
            await _onPass(_n(frame.from), frame.payload);
        }
      } finally {
        done.complete();
      }
    });
    await done.future;
    return true;
  }

  /// Event ids this app makes (letters, digits, `-` and `_`): anything else
  /// is not taken in.
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,40}$');

  /// Who gave this phone [e]: the friend who passed it on, or the organizer.
  String _sourceOf(MeetEvent e) {
    final String? via = _via[e.id];
    if (via != null) {
      try {
        final List<Map<String, String>> chain = _chainOf(jsonDecode(via));
        if (chain.isNotEmpty) {
          return chain.last['a']!;
        }
      } on FormatException {
        // a damaged entry: count it for the organizer
      }
    }
    return _n(e.organizer);
  }

  /// Whether a new invitation from the friend [from] may be taken in (the
  /// flood guards: per day, per friend, in all). Counts it when it may.
  bool _takeNew(String from) {
    final int t = _now();
    final List<int> recent = (_newFrom[from] ??= <int>[])
      ..removeWhere((int at) => t - at > _day);
    if (recent.length >= maxNewEventsPerFriendPerDay) {
      return false;
    }
    int foreign = 0;
    int fromThem = 0;
    for (final MeetEvent e in _events.values) {
      if (e.isMine) {
        continue;
      }
      foreign++;
      if (_sourceOf(e) == from) {
        fromThem++;
      }
    }
    if (foreign >= maxForeignEvents || fromThem >= maxEventsPerFriend) {
      return false;
    }
    recent.add(t);
    return true;
  }

  Future<void> _onEvent(String from, Map<String, dynamic> payload) async {
    final MeetEvent? got = MeetEvent.fromJson(payload['e']);
    if (got == null || got.organizer == 'self') {
      return;
    }
    final String org = _n(got.organizer);
    final MeetEvent? had = _events[got.id];
    if (had != null && had.isMine) {
      return; // our own event echoed back
    }
    final int nowMs = _now();
    // Nothing that would never be cleaned up (far ahead), nothing long over.
    if (got.startsAt > nowMs + maxAhead || got.startsAt < nowMs - _keepAfter) {
      return;
    }
    final bool fromOrganizer = from == org;
    final List<Map<String, String>> chain = _chainOf(payload['chain']);
    if (had == null) {
      // New: only from a friend — the organizer, or a friend passing it on
      // (the last link of the chain). Someone who is not a friend is never
      // taken on their word, not even naming a friend who vouches: such an
      // invitation comes through that friend ([EventTypes.pass]).
      if (!host.isFriend(from) ||
          !_idPattern.hasMatch(got.id) ||
          (!fromOrganizer && (chain.isEmpty || chain.last['a'] != from)) ||
          !_takeNew(from)) {
        return;
      }
      if (!fromOrganizer) {
        _via[got.id] = jsonEncode(chain);
        final Object? token = payload['tok'];
        if (unb64(token, length: 32) != null) {
          _tokens[got.id] = token as String;
        }
      }
    } else if (!fromOrganizer || _n(had.organizer) != org) {
      return; // only the organizer updates an event
    }
    if (had != null && had.updatedAt > got.updatedAt) {
      return;
    }
    final MeetEvent stored = MeetEvent(
      id: got.id,
      organizer: org,
      organizerName: got.organizerName,
      title: got.title,
      kind: got.kind,
      description: got.description,
      place: got.place,
      startsAt: got.startsAt,
      reach: got.reach,
      capacity: got.capacity,
      askForPlusOne: got.askForPlusOne,
      ticketKey: had?.ticketKey ?? got.ticketKey,
      guests: got.guests,
      cancelled: got.cancelled,
      updatedAt: got.updatedAt,
    );
    _events[got.id] = stored;
    final EventTicket? ticket = EventTicket.fromJson(payload['t']);
    if (ticket != null &&
        ticket.eventId == got.id &&
        _n(ticket.guest) == _n(host.ownAddress()) &&
        await ticket.verify(stored.ticketKey)) {
      _tickets[got.id] = ticket;
    }
    await _save();
    if (had == null) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'event-${got.id}',
          title: t('Zaproszenie: {title}', {'title': got.title}),
          body: fromOrganizer
              ? t('Od {name}.', {'name': got.organizerName})
              : t('{name}, przez {via}.', {
                  'name': got.organizerName,
                  'via': host.nameOf(from),
                }),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'event:${got.id}',
        ),
      );
    } else if (got.cancelled && !had.cancelled) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'event-cancel-${got.id}',
          title: t('Odwołane: {title}', {'title': got.title}),
          body: t('{name} odwołał(a) wydarzenie.', {'name': got.organizerName}),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'event:${got.id}',
        ),
      );
    }
    // Pass it on as far as the organizer allowed: never further
    // than the event's own reach, counted along the chain — whatever the
    // frame says.
    final Object? hops = payload['hops'];
    final int left = hops is int
        ? min(hops, got.reach.hops - (fromOrganizer ? 0 : chain.length))
        : 0;
    if (left > 0 && !got.cancelled && _forwarded.add(got.id)) {
      // The key for passing it on came with this copy (from the organizer,
      // or from the friend who passed it to us).
      final Uint8List? key = unb64(payload['fk'], length: 32);
      final List<Map<String, String>> next = <Map<String, String>>[
        ...fromOrganizer ? const <Map<String, String>>[] : chain,
        <String, String>{'a': _n(host.ownAddress()), 'n': host.ownName()},
      ];
      final Set<String> skip = <String>{org, from, ...got.guests.keys};
      for (final String f in host.friends()) {
        if (!skip.contains(_n(f))) {
          await _send(f, <String, dynamic>{
            'type': EventTypes.event,
            'e': got.toJson(),
            'hops': left - 1,
            'chain': next,
            if (key != null) 'tok': b64(_hop(key, 'inv', f)),
            if (key != null && left > 1) 'fk': b64(_hop(key, 'fwd', f)),
          });
        }
      }
      await _save();
    }
  }

  /// As the friend who vouches: the organizer (a friend) asks this phone to
  /// pass its invitation on to a friend of ours it lists as brought by us.
  Future<void> _onPass(String from, Map<String, dynamic> payload) async {
    final MeetEvent? got = MeetEvent.fromJson(payload['e']);
    final Object? to = payload['to'];
    if (got == null ||
        to is! String ||
        !host.isFriend(from) ||
        _n(got.organizer) != from ||
        got.cancelled ||
        !_idPattern.hasMatch(got.id)) {
      return;
    }
    final String me = _n(host.ownAddress());
    final String guest = _n(to);
    final EventGuest? g = got.guest(guest);
    if (g == null ||
        g.broughtBy == null ||
        _n(g.broughtBy!) != me ||
        g.status == GuestStatus.requested ||
        guest == me ||
        guest == from ||
        !host.isFriend(guest)) {
      return;
    }
    final int t = _now();
    final List<int> recent = (_passesFrom[from] ??= <int>[])
      ..removeWhere((int at) => t - at > _day);
    if (recent.length >= maxPassesPerFriendPerDay ||
        !_passed.add('${got.id}|$guest')) {
      return;
    }
    recent.add(t);
    if (_passed.length > 500) {
      _passed.remove(_passed.first);
    }
    await _send(guest, <String, dynamic>{
      'type': EventTypes.event,
      'e': got.toJson(),
      'chain': <Map<String, String>>[
        <String, String>{'a': me, 'n': host.ownName()},
      ],
    });
  }

  Future<void> _onRsvp(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final MeetEvent? e = id is String ? _events[id] : null;
    if (e == null || !e.isMine || e.cancelled) {
      return;
    }
    final GuestStatus status = GuestStatus.byName(payload['s']);
    // "Będę" comes with the key of the guest's phone: the ticket is pinned
    // to it.
    final Object? pk = payload['pk'];
    if (status == GuestStatus.requested ||
        (status == GuestStatus.going && unb64(pk, length: 32) == null)) {
      return;
    }
    final Object? raw = payload['n'];
    final String? n = raw is String
        ? (raw.length > 60 ? raw.substring(0, 60) : raw)
        : null;
    final List<Map<String, String>> chain = _chainOf(payload['chain']);
    EventGuest? g = e.guest(from);
    final Map<String, EventGuest> extra = <String, EventGuest>{};
    if (g == null) {
      // Not invited by name: someone the invitation reached through
      // friends, within the reach the organizer chose. The chain starts
      // at one of the organizer's own guests, and the invitation token
      // shows the invitation really reached this address along it (the
      // organizer's own friends need none).
      final bool friend = host.isFriend(from);
      final bool viaChain =
          !friend &&
          chain.isNotEmpty &&
          chain.length <= e.reach.hops &&
          e.guest(chain.first['a']!) != null &&
          e.guest(chain.first['a']!)!.broughtBy == null &&
          _tokenFits(e, chain, from, payload['tok']);
      final bool reachable = switch (e.reach) {
        EventReach.selected => false,
        EventReach.friends => friend,
        EventReach.friendsOfFriends ||
        EventReach.twoSteps => friend || viaChain,
      };
      if (!reachable || e.guests.length + chain.length >= maxGuests) {
        return;
      }
      g = EventGuest(
        address: from,
        name: n ?? host.nameOf(from),
        broughtBy: friend ? null : chain.last['a'],
      );
      if (!friend) {
        // The people in between appear on the list as the ones who passed
        // it on ("Ola, przyprowadzona przez Kubę, którego przyprowadziła
        // Ania"), even if they do not come themselves.
        for (int i = 1; i < chain.length; i++) {
          final String a = chain[i]['a']!;
          if (e.guest(a) == null && a != from) {
            extra[a] = EventGuest(
              address: a,
              name: chain[i]['n']!,
              broughtBy: chain[i - 1]['a'],
            );
          }
        }
      }
    }
    if (status == GuestStatus.going &&
        g.status != GuestStatus.going &&
        e.isFull) {
      // Full: they stay where they were and get the current copy.
      await _broadcastTo(e, g);
      return;
    }
    // A newer key replaces the older one (only that phone can send it).
    if (status == GuestStatus.going) {
      (_guestKeys[e.id] ??= <String, String>{})[g.address] = pk as String;
    }
    final bool wasGoing = g.status == GuestStatus.going;
    final EventGuest updated = g.copyWith(
      status: status,
      name: n != null && n.isNotEmpty ? n : g.name,
    );
    await _change(
      e.id,
      (MeetEvent ev) => ev.copyWith(
        guests: <String, EventGuest>{
          ...ev.guests,
          ...extra,
          updated.address: updated,
        },
      ),
    );
    if (status == GuestStatus.going && !wasGoing) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'event-rsvp-${e.id}-$from',
          title: t('{name} będzie: {title}', {
            'name': updated.name,
            'title': e.title,
          }),
          body: e.capacity > 0
              ? t('Gości: {count} z {capacity}.', {
                  'count': e.goingCount + 1,
                  'capacity': e.capacity - 1,
                })
              : t('Gości: {count}.', {'count': e.goingCount + 1}),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'event-rsvp:${e.id}',
        ),
      );
    }
  }

  Future<void> _broadcastTo(MeetEvent e, EventGuest g) async {
    await _send(g.address, <String, dynamic>{
      'type': EventTypes.event,
      'e': e.toJson()..['org'] = host.ownAddress(),
    });
  }

  Future<void> _onPlusOne(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? a = payload['a'];
    final Object? n = payload['n'];
    final MeetEvent? e = id is String ? _events[id] : null;
    final EventGuest? asker = e?.guest(from);
    if (e == null ||
        !e.isMine ||
        e.cancelled ||
        asker == null ||
        a is! String ||
        !isRoutablePeerAddress(a) ||
        e.guest(a) != null) {
      return;
    }
    if (!e.askForPlusOne && asker.plusOnes == 0) {
      return;
    }
    final int used = e.guests.values
        .where((EventGuest g) => g.broughtBy == asker.address)
        .length;
    // A guest asks for a few people, not for a crowd.
    if (used >= maxPlusOnesPerGuest || e.guests.length >= maxGuests) {
      return;
    }
    final bool free = used < asker.plusOnes;
    final EventGuest guest = EventGuest(
      address: _n(a),
      name: n is String ? (n.length > 60 ? n.substring(0, 60) : n) : '',
      broughtBy: asker.address,
      status: free ? GuestStatus.invited : GuestStatus.requested,
    );
    await _change(
      e.id,
      (MeetEvent ev) => ev.copyWith(
        guests: <String, EventGuest>{...ev.guests, guest.address: guest},
      ),
      // Without asking: the invitation goes out now, through the asker.
      passFor: <String>[if (free) guest.address],
    );
    if (!free) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'event-plus1-${e.id}-$a',
          title: t('{name} chce przyprowadzić {guest}', {
            'name': asker.name,
            'guest': guest.name,
          }),
          body: e.title,
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'event-plus1:${e.id}',
        ),
      );
    }
  }

  // ---- after the event: shared album and gratitude cards ----

  Future<void> _saveAlbum(String id) async {
    if (_diskUnreadable) {
      return;
    }
    await disk.write(
      albumKey(id),
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<Map<String, dynamic>>[
            for (final EventPhoto p in _albums[id] ?? const <EventPhoto>[])
              p.toJson(),
          ]),
        ),
      ),
    );
  }

  /// Adds a photo (already compressed with [compressEventPhoto]) to the
  /// album of [id]. The organizer passes it on to everyone who went.
  Future<EventPhoto?> addPhoto(String id, Uint8List jpeg) async {
    final MeetEvent? e = _events[id];
    if (e == null ||
        !canAddPhotos(e) ||
        jpeg.isEmpty ||
        jpeg.length > kMaxSharedPhotoBytes) {
      return null;
    }
    final String own = _n(host.ownAddress());
    final List<EventPhoto> album = _albums[id] ?? const <EventPhoto>[];
    if (album.length >= maxPhotosPerEvent ||
        album.where((EventPhoto p) => p.by == own).length >=
            maxPhotosPerGuest) {
      return null;
    }
    final EventPhoto photo = EventPhoto(
      id: _newId(),
      by: own,
      byName: host.ownName(),
      at: _now(),
      data: base64Encode(jpeg),
    );
    _albums[id] = <EventPhoto>[...album, photo];
    await _saveAlbum(id);
    notifyListeners();
    if (e.isMine) {
      await _sharePhoto(e, photo, except: own);
    } else {
      await _send(e.organizer, <String, dynamic>{
        'type': EventTypes.photo,
        'id': id,
        'p': photo.toJson(),
      });
    }
    return photo;
  }

  /// Sends [photo] to every guest who went (but [except]).
  Future<void> _sharePhoto(
    MeetEvent e,
    EventPhoto photo, {
    required String except,
  }) async {
    final String own = _n(host.ownAddress());
    for (final EventGuest g in e.guests.values) {
      if (_went(g) && g.address != except && g.address != own) {
        await _send(g.address, <String, dynamic>{
          'type': EventTypes.photo,
          'id': e.id,
          'p': photo.toJson(),
        });
      }
    }
  }

  Future<void> _onPhoto(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final MeetEvent? e = id is String ? _events[id] : null;
    final EventPhoto? got = EventPhoto.fromJson(payload['p']);
    if (e == null || got == null || e.cancelled) {
      return;
    }
    final List<EventPhoto> album = _albums[e.id] ?? const <EventPhoto>[];
    if (album.length >= maxPhotosPerEvent ||
        album.any((EventPhoto p) => p.id == got.id)) {
      return;
    }
    String name = got.byName;
    if (e.isMine) {
      // A guest who went, with their own photo, once it started.
      final EventGuest? g = e.guest(from);
      if (!_went(g) ||
          got.by != from ||
          !_started(e) ||
          album.where((EventPhoto p) => p.by == from).length >=
              maxPhotosPerGuest) {
        return;
      }
      name = g!.name;
    } else if (from != _n(e.organizer) || !_went(myGuest(e))) {
      // Only from the organizer, and only for those who went.
      return;
    }
    Uint8List? clean;
    try {
      final Uint8List? raw =
          got.data.length > kMaxRemotePhotoInputBytes * 4 ~/ 3 + 4
          ? null
          : base64Decode(got.data);
      clean = raw == null || raw.length > kMaxRemotePhotoInputBytes
          ? null
          : await _cleanPhoto(raw);
    } on Object {
      clean = null;
    }
    if (clean == null || clean.length > kMaxSharedPhotoBytes) {
      return;
    }
    final EventPhoto photo = EventPhoto(
      id: got.id,
      by: got.by,
      byName: name,
      at: got.at,
      data: base64Encode(clean),
    );
    // The album may have changed while the photo was being cleaned.
    final List<EventPhoto> current = _albums[e.id] ?? const <EventPhoto>[];
    if (current.any((EventPhoto p) => p.id == photo.id)) {
      return;
    }
    _albums[e.id] = <EventPhoto>[...current, photo];
    await _saveAlbum(e.id);
    notifyListeners();
    if (e.isMine) {
      await _sharePhoto(e, photo, except: from);
    }
    await host.notify(
      RuntimeSystemNotification(
        id: 'event-photo-${e.id}-${photo.id}',
        title: t('Nowe zdjęcie: {title}', {'title': e.title}),
        body: t('Dodał(a) {name}.', {
          'name': photo.byName.isEmpty ? t('ktoś z gości') : photo.byName,
        }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'event-album:${e.id}',
      ),
    );
  }

  /// Sends the host a gratitude card ("karta wdzięczności") for [id].
  /// Sending again replaces the earlier card.
  Future<bool> sendThanks(String id, String text) async {
    final MeetEvent? e = _events[id];
    final String t = text.trim();
    if (e == null ||
        !canThank(e) ||
        t.isEmpty ||
        t.length > EventThanks.maxChars) {
      return false;
    }
    final EventThanks card = EventThanks(
      by: 'self',
      byName: host.ownName(),
      text: t,
      at: _now(),
    );
    _thanks[id] = <EventThanks>[
      ...(_thanks[id] ?? const <EventThanks>[]).where(
        (EventThanks c) => c.by != 'self',
      ),
      card,
    ];
    await _save();
    await _send(e.organizer, <String, dynamic>{
      'type': EventTypes.thanks,
      'id': id,
      't': t,
      'n': host.ownName(),
    });
    return true;
  }

  Future<void> _onThanks(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? text = payload['t'];
    final MeetEvent? e = id is String ? _events[id] : null;
    final EventGuest? g = e?.guest(from);
    if (e == null ||
        !e.isMine ||
        e.cancelled ||
        _now() < e.startsAt ||
        !_went(g) ||
        text is! String ||
        text.trim().isEmpty) {
      return;
    }
    final String trimmed = text.trim();
    final EventThanks card = EventThanks(
      by: from,
      byName: g!.name,
      text: trimmed.length > EventThanks.maxChars
          ? trimmed.substring(0, EventThanks.maxChars)
          : trimmed,
      at: _now(),
    );
    _thanks[e.id] = <EventThanks>[
      ...(_thanks[e.id] ?? const <EventThanks>[]).where(
        (EventThanks c) => c.by != from,
      ),
      card,
    ];
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'event-thanks-${e.id}-$from',
        title: t('Karta wdzięczności: {title}', {'title': e.title}),
        body: '${card.byName}: ${card.text}',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'event-thanks:${e.id}',
      ),
    );
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Wydarzenia: ${payload['type']} do $to: $error');
    }
  }
}
