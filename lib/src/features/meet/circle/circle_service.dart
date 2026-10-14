import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class CircleTypes {
  static const String circle = 'circle';
  static const String swap = 'circle_swap';

  /// "Kółko otwarte": a member invites someone from outside for one dinner.
  static const String guest = 'circle_guest';

  static const Set<String> all = <String>{circle, swap, guest};
}

/// Someone from outside the circle a member brings to one dinner
/// ("kółko otwarte", §17.3): once a month per member.
@immutable
final class CircleGuest {
  const CircleGuest({required this.name, required this.day, this.address});

  final String name;

  /// The dinner (yyyy-mm-dd).
  final String day;

  /// Their mesh address, when they are a friend of the member (they get an
  /// invitation).
  final String? address;

  Map<String, String> toJson() => <String, String>{
    'n': name,
    'd': day,
    'a': ?address,
  };

  static CircleGuest? fromJson(Object? json) {
    if (json is! Map || json['n'] is! String || json['d'] is! String) {
      return null;
    }
    final String n = json['n'] as String;
    final String d = json['d'] as String;
    final Object? a = json['a'];
    return CircleGuest(
      name: n.length > 60 ? n.substring(0, 60) : n,
      day: d.length > 10 ? d.substring(0, 10) : d,
      address: a is String && isRoutablePeerAddress(a)
          ? PeerShareCodec.normalizeAddress(a)
          : null,
    );
  }
}

@immutable
final class CircleMember {
  const CircleMember(this.address, this.name);

  final String address;
  final String name;

  Map<String, String> toJson() => <String, String>{'a': address, 'n': name};
}

/// Kółko obiadowe (§17.3): friends taking turns hosting a regular dinner.
/// Any member may change it; the newest copy wins and goes to everyone.
@immutable
final class DinnerCircle {
  const DinnerCircle({
    required this.id,
    required this.name,
    required this.members,
    required this.weekday,
    required this.hour,
    required this.firstDinner,
    this.everyWeeks = 1,
    this.prefs = const <String, String>{},
    this.items = const <String, Map<String, String>>{},
    this.open = false,
    this.guests = const <String, Map<String, CircleGuest>>{},
    this.updatedAt = 0,
  });

  final String id;
  final String name;

  /// In hosting order.
  final List<CircleMember> members;

  /// 1 = Monday … 7 = Sunday.
  final int weekday;
  final int hour;

  /// The first dinner (local midnight of its day).
  final int firstDinner;
  final int everyWeeks;

  /// Preferences and allergies, per member address.
  final Map<String, String> prefs;

  /// Per dinner (yyyy-mm-dd): item → who brings it ('' = nobody yet).
  final Map<String, Map<String, String>> items;

  /// "Kółko otwarte": once a month every member may bring one person from
  /// outside the circle.
  final bool open;

  /// Guests brought along: month (yyyy-mm) → member address → guest.
  final Map<String, Map<String, CircleGuest>> guests;
  final int updatedAt;

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String monthKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  /// The guest [member] brings in the month of [day], if any.
  CircleGuest? guestOf(String member, DateTime day) =>
      guests[monthKey(day)]?[PeerShareCodec.normalizeAddress(member)];

  /// Whether [member] may still bring someone in the month of [day].
  bool canBringGuest(String member, DateTime day) =>
      open && hasMember(member) && guestOf(member, day) == null;

  /// Guests coming to the dinner on [day]: (who brings them, the guest).
  List<(String, CircleGuest)> guestsOn(DateTime day) {
    final String key = dayKey(day);
    return <(String, CircleGuest)>[
      for (final MapEntry<String, CircleGuest> e
          in (guests[monthKey(day)] ?? const <String, CircleGuest>{}).entries)
        if (e.value.day == key) (e.key, e.value),
    ];
  }

  /// The [count] next dinners from [now] with their hosts.
  List<(DateTime, CircleMember)> schedule(int now, {int count = 6}) {
    if (members.isEmpty) {
      return const <(DateTime, CircleMember)>[];
    }
    final DateTime start = DateTime.fromMillisecondsSinceEpoch(firstDinner);
    final DateTime first = DateTime(start.year, start.month, start.day, hour);
    final Duration step = Duration(days: 7 * everyWeeks);
    final DateTime today = DateTime.fromMillisecondsSinceEpoch(now);
    int n = 0;
    DateTime at = first;
    while (at.isBefore(DateTime(today.year, today.month, today.day))) {
      n++;
      at = DateTime(first.year, first.month, first.day + n * step.inDays, hour);
    }
    return <(DateTime, CircleMember)>[
      for (int i = 0; i < count; i++)
        (
          DateTime(
            first.year,
            first.month,
            first.day + (n + i) * step.inDays,
            hour,
          ),
          members[(n + i) % members.length],
        ),
    ];
  }

  bool hasMember(String address) => members.any(
    (CircleMember m) => PeerShareCodec.addressesEqual(m.address, address),
  );

  DinnerCircle copyWith({
    List<CircleMember>? members,
    Map<String, String>? prefs,
    Map<String, Map<String, String>>? items,
    bool? open,
    Map<String, Map<String, CircleGuest>>? guests,
    int? updatedAt,
  }) => DinnerCircle(
    id: id,
    name: name,
    members: members ?? this.members,
    weekday: weekday,
    hour: hour,
    firstDinner: firstDinner,
    everyWeeks: everyWeeks,
    prefs: prefs ?? this.prefs,
    items: items ?? this.items,
    open: open ?? this.open,
    guests: guests ?? this.guests,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'members': <Map<String, String>>[
      for (final CircleMember m in members) m.toJson(),
    ],
    'wd': weekday,
    'h': hour,
    'first': firstDinner,
    'every': everyWeeks,
    'prefs': prefs,
    'items': items,
    if (open) 'open': true,
    if (guests.isNotEmpty)
      'guests': <String, dynamic>{
        for (final MapEntry<String, Map<String, CircleGuest>> m
            in guests.entries)
          m.key: <String, dynamic>{
            for (final MapEntry<String, CircleGuest> g in m.value.entries)
              g.key: g.value.toJson(),
          },
      },
    'upd': updatedAt,
  };

  static DinnerCircle? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['name'] is! String ||
        json['members'] is! List ||
        json['first'] is! int) {
      return null;
    }
    String clip(Object? v, int max) =>
        v is String ? (v.length > max ? v.substring(0, max) : v) : '';
    final List<CircleMember> members = <CircleMember>[
      for (final Object? m in (json['members'] as List).take(20))
        if (m is Map && m['a'] is String)
          CircleMember(
            PeerShareCodec.normalizeAddress(m['a'] as String),
            clip(m['n'], 60),
          ),
    ];
    final Object? prefs = json['prefs'];
    final Object? items = json['items'];
    final Object? guests = json['guests'];
    return DinnerCircle(
      id: json['id'] as String,
      name: clip(json['name'], 60),
      members: members,
      weekday: json['wd'] is int ? (json['wd'] as int).clamp(1, 7) : 4,
      hour: json['h'] is int ? (json['h'] as int).clamp(0, 23) : 19,
      firstDinner: json['first'] as int,
      everyWeeks: json['every'] is int ? (json['every'] as int).clamp(1, 8) : 1,
      prefs: <String, String>{
        if (prefs is Map)
          for (final MapEntry<dynamic, dynamic> e in prefs.entries)
            if (e.key is String && e.value is String)
              e.key as String: clip(e.value, 300),
      },
      items: <String, Map<String, String>>{
        if (items is Map)
          for (final MapEntry<dynamic, dynamic> d in items.entries)
            if (d.key is String && d.value is Map)
              d.key as String: <String, String>{
                for (final MapEntry<dynamic, dynamic> i
                    in (d.value as Map).entries)
                  if (i.key is String && i.value is String)
                    clip(i.key, 60): i.value as String,
              },
      },
      open: json['open'] == true,
      guests: <String, Map<String, CircleGuest>>{
        if (guests is Map)
          for (final MapEntry<dynamic, dynamic> m in guests.entries.take(36))
            if (m.key is String && m.value is Map)
              m.key as String: <String, CircleGuest>{
                for (final MapEntry<dynamic, dynamic> g
                    in (m.value as Map).entries)
                  if (g.key is String && CircleGuest.fromJson(g.value) != null)
                    PeerShareCodec.normalizeAddress(g.key as String):
                        CircleGuest.fromJson(g.value)!,
              },
      },
      updatedAt: json['upd'] is int ? json['upd'] as int : 0,
    );
  }
}

/// How far a phone's clock may be ahead: a copy of a circle dated later
/// than that counts as made now (a date far ahead would freeze the circle
/// against everyone else's later changes).
const Duration kCircleClockSkew = Duration(minutes: 10);

final class CircleService extends ChangeNotifier {
  CircleService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;
  static const String _key = 'meet/circles';

  final Map<String, DinnerCircle> _circles = <String, DinnerCircle>{};

  /// Swap requests waiting for this person (circle id → who asks).
  final Map<String, String> swapRequests = <String, String>{};

  int get now => _now();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String get _me => _n(host.ownAddress());

  List<DinnerCircle> get circles => _circles.values.toList();

  DinnerCircle? circle(String id) => _circles[id];

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      _diskUnreadable = false;
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is List) {
        _circles.clear();
        for (final Object? c in json) {
          final DinnerCircle? circle = DinnerCircle.fromJson(c);
          if (circle != null) {
            _circles[circle.id] = circle;
          }
        }
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt kółek', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<Map<String, dynamic>>[
          for (final DinnerCircle c in _circles.values) c.toJson(),
        ]),
      ),
    );
    notifyListeners();
  }

  Future<void> _publish(DinnerCircle c) async {
    // Always newer than the copy we have, even when another phone's clock
    // ran a little ahead.
    final DinnerCircle stamped = c.copyWith(
      updatedAt: max(_now(), (_circles[c.id]?.updatedAt ?? 0) + 1),
    );
    _circles[c.id] = stamped;
    await _save();
    for (final CircleMember m in stamped.members) {
      if (m.address != _me) {
        await _send(m.address, <String, dynamic>{
          'type': CircleTypes.circle,
          'c': stamped.toJson(),
        });
      }
    }
  }

  Future<DinnerCircle> create({
    required String name,
    required List<String> friends,
    required int weekday,
    required int hour,
    required DateTime firstDinner,
    int everyWeeks = 1,
  }) async {
    final DinnerCircle c = DinnerCircle(
      id: List<String>.generate(
        14,
        (_) => _random.nextInt(36).toRadixString(36),
      ).join(),
      name: name,
      members: <CircleMember>[
        CircleMember(_me, host.ownName()),
        for (final String f in friends) CircleMember(_n(f), host.nameOf(f)),
      ],
      weekday: weekday,
      hour: hour,
      firstDinner: DateTime(
        firstDinner.year,
        firstDinner.month,
        firstDinner.day,
      ).millisecondsSinceEpoch,
      everyWeeks: everyWeeks,
    );
    await _publish(c);
    return _circles[c.id]!;
  }

  Future<void> setMyPrefs(String id, String text) async {
    final DinnerCircle? c = _circles[id];
    if (c == null) {
      return;
    }
    await _publish(
      c.copyWith(prefs: <String, String>{...c.prefs, _me: text.trim()}),
    );
  }

  /// Adds something to bring to the dinner on [day] (unclaimed).
  Future<void> addItem(String id, DateTime day, String item) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || item.trim().isEmpty) {
      return;
    }
    final String key = DinnerCircle.dayKey(day);
    await _publish(
      c.copyWith(
        items: <String, Map<String, String>>{
          ...c.items,
          key: <String, String>{...?c.items[key], item.trim(): ''},
        },
      ),
    );
  }

  /// "Ja przynoszę" (or, again, "już nie").
  Future<void> claimItem(String id, DateTime day, String item) async {
    final DinnerCircle? c = _circles[id];
    final String key = DinnerCircle.dayKey(day);
    final String? who = c?.items[key]?[item];
    if (c == null || who == null) {
      return;
    }
    await _publish(
      c.copyWith(
        items: <String, Map<String, String>>{
          ...c.items,
          key: <String, String>{...c.items[key]!, item: who == _me ? '' : _me},
        },
      ),
    );
  }

  /// Asks [other] to swap places in the hosting order.
  Future<void> askSwap(String id, String other) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || !c.hasMember(other)) {
      return;
    }
    await _send(_n(other), <String, dynamic>{
      'type': CircleTypes.swap,
      'id': id,
    });
  }

  /// Agrees to the swap [from] asked for.
  Future<void> acceptSwap(String id) async {
    final DinnerCircle? c = _circles[id];
    final String? from = swapRequests.remove(id);
    if (c == null || from == null) {
      return;
    }
    final List<CircleMember> order = List<CircleMember>.of(c.members);
    final int a = order.indexWhere((CircleMember m) => m.address == _me);
    final int b = order.indexWhere((CircleMember m) => m.address == from);
    if (a < 0 || b < 0) {
      return;
    }
    final CircleMember t = order[a];
    order[a] = order[b];
    order[b] = t;
    await _publish(c.copyWith(members: order));
  }

  void declineSwap(String id) {
    swapRequests.remove(id);
    notifyListeners();
  }

  /// Opens (or closes) the circle: once a month every member may bring
  /// one person from outside (§17.3).
  Future<void> setOpen(String id, bool open) async {
    final DinnerCircle? c = _circles[id];
    if (c == null || c.open == open) {
      return;
    }
    await _publish(c.copyWith(open: open));
  }

  /// Brings [name] (a friend at [address], who then gets an invitation,
  /// or anyone by name) to the dinner on [day]. Once a month, in an open
  /// circle. Returns whether it worked.
  Future<bool> bringGuest(
    String id,
    DateTime day, {
    required String name,
    String? address,
  }) async {
    final DinnerCircle? c = _circles[id];
    final String n = name.trim();
    if (c == null || n.isEmpty || !c.canBringGuest(_me, day)) {
      return false;
    }
    if (address != null && c.hasMember(address)) {
      return false; // already in the circle
    }
    final String month = DinnerCircle.monthKey(day);
    final CircleGuest guest = CircleGuest(
      name: n.length > 60 ? n.substring(0, 60) : n,
      day: DinnerCircle.dayKey(day),
      address: address == null ? null : _n(address),
    );
    await _publish(
      c.copyWith(
        guests: <String, Map<String, CircleGuest>>{
          ...c.guests,
          month: <String, CircleGuest>{...?c.guests[month], _me: guest},
        },
      ),
    );
    final String? to = guest.address;
    if (to != null) {
      final CircleMember? cook = c
          .schedule(day.millisecondsSinceEpoch, count: 1)
          .firstOrNull
          ?.$2;
      await _send(to, <String, dynamic>{
        'type': CircleTypes.guest,
        'c': c.name,
        'at': DateTime(
          day.year,
          day.month,
          day.day,
          c.hour,
        ).millisecondsSinceEpoch,
        if (cook != null) 'cook': cook.name,
      });
    }
    return true;
  }

  /// Takes back this person's guest for the month of [day].
  Future<void> cancelGuest(String id, DateTime day) async {
    final DinnerCircle? c = _circles[id];
    final String month = DinnerCircle.monthKey(day);
    if (c == null || c.guests[month]?[_me] == null) {
      return;
    }
    final Map<String, CircleGuest> left = <String, CircleGuest>{
      ...c.guests[month]!,
    }..remove(_me);
    final Map<String, Map<String, CircleGuest>> guests =
        <String, Map<String, CircleGuest>>{...c.guests};
    if (left.isEmpty) {
      guests.remove(month);
    } else {
      guests[month] = left;
    }
    await _publish(c.copyWith(guests: guests));
  }

  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !CircleTypes.all.contains(type)) {
      return false;
    }
    final String from = _n(frame.from);
    if (type == CircleTypes.guest) {
      // A friend brings us to their circle's dinner.
      final Object? name = frame.payload['c'];
      final Object? at = frame.payload['at'];
      final Object? cook = frame.payload['cook'];
      if (host.isFriend(from) && name is String && at is int) {
        final DateTime d = DateTime.fromMillisecondsSinceEpoch(at);
        String two(int v) => v.toString().padLeft(2, '0');
        await host.notify(
          RuntimeSystemNotification(
            id: 'circle-guest-$from-$at',
            title: '${host.nameOf(from)} zaprasza Cię na obiad',
            body:
                '„${name.length > 60 ? name.substring(0, 60) : name}”, '
                '${two(d.day)}.${two(d.month)} o ${two(d.hour)}:00'
                '${cook is String && cook.isNotEmpty ? ' — gotuje ${cook.length > 60 ? cook.substring(0, 60) : cook}' : ''}.',
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'circle-guest:$from',
          ),
        );
      }
      return true;
    }
    if (type == CircleTypes.swap) {
      final Object? id = frame.payload['id'];
      final DinnerCircle? c = id is String ? _circles[id] : null;
      if (c != null && c.hasMember(from)) {
        swapRequests[c.id] = from;
        notifyListeners();
        await host.notify(
          RuntimeSystemNotification(
            id: 'circle-swap-${c.id}-$from',
            title: '${host.nameOf(from)} chce zamienić się kolejką',
            body: c.name,
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'circle:${c.id}',
          ),
        );
      }
      return true;
    }
    final DinnerCircle? parsed = DinnerCircle.fromJson(frame.payload['c']);
    if (parsed == null || !parsed.hasMember(_me) || !parsed.hasMember(from)) {
      return true;
    }
    final int latest = _now() + kCircleClockSkew.inMilliseconds;
    final DinnerCircle got = parsed.updatedAt > latest
        ? parsed.copyWith(updatedAt: latest)
        : parsed;
    final DinnerCircle? had = _circles[got.id];
    if (had == null && !host.isFriend(from)) {
      return true;
    }
    if (had != null &&
        (had.updatedAt > got.updatedAt || !had.hasMember(from))) {
      return true;
    }
    _circles[got.id] = got;
    await _save();
    if (had == null) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-${got.id}',
          title: 'Nowe kółko obiadowe: ${got.name}',
          body: 'Od ${host.nameOf(from)}.',
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'circle:${got.id}',
        ),
      );
    }
    return true;
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Kółko obiadowe: do $to: $error');
    }
  }
}
