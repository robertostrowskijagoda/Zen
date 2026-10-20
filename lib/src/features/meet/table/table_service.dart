import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

const String kTableWishType = 'table_wish';

/// How long a "Chcę na Stół na sześć" is kept without being renewed.
const Duration kTableWishLife = Duration(days: 30);

/// How far a phone's clock may be ahead: a wish dated later than that is
/// taken as made now (a date far ahead would keep it forever and freeze
/// it against the person's own later changes).
const Duration kTableClockSkew = Duration(minutes: 10);

/// "Chcę na Stół na sześć" (§17.4): someone's city and the days they can.
@immutable
final class TableWish {
  const TableWish({
    required this.address,
    required this.name,
    required this.city,
    required this.days,
    required this.at,
    this.via,
  });

  final String address;
  final String name;
  final String city;

  /// Weekdays (1 = Monday … 7 = Sunday).
  final Set<int> days;
  final int at;

  /// The friend it came through (`null` for a friend's own wish).
  final String? via;

  bool matches(String city, DateTime when) =>
      normalizeCity(this.city) == normalizeCity(city) &&
      (days.isEmpty || days.contains(when.weekday));

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    'n': name,
    'city': city,
    'days': days.toList()..sort(),
    'at': at,
    if (via != null) 'via': via,
  };

  static TableWish? fromJson(Object? json) {
    if (json is! Map ||
        json['a'] is! String ||
        json['city'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final Object? days = json['days'];
    final Object? n = json['n'];
    return TableWish(
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      name: n is String ? (n.length > 60 ? n.substring(0, 60) : n) : '',
      city: (json['city'] as String).length > 60
          ? (json['city'] as String).substring(0, 60)
          : json['city'] as String,
      days: <int>{
        if (days is List)
          for (final Object? d in days)
            if (d is int && d >= 1 && d <= 7) d,
      },
      at: json['at'] as int,
      via: json['via'] is String ? json['via'] as String : null,
    );
  }
}

String normalizeCity(String city) => city.trim().toLowerCase();

/// Stół na sześć (§17.4): people who want to have dinner with friends of
/// friends say so (city, days); it reaches their friends and the friends'
/// friends. Whoever sets a table gets 5 guests picked from that, each
/// connected to the host, knowing each other as little as possible.
final class TableService extends ChangeNotifier {
  TableService({
    required this.host,
    required this.events,
    required this.disk,
    required this.friendsOf,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random();

  final EventHost host;
  final EventService events;
  final LedgerDisk disk;

  /// The friend list a friend shared (address → name), for avoiding
  /// people who already know each other.
  final Map<String, String> Function(String friend) friendsOf;
  final int Function() _now;
  final Random _random;
  static const String _key = 'meet/table';

  TableWish? myWish;
  final Map<String, TableWish> _wishes = <String, TableWish>{};

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  List<TableWish> get wishes {
    final int t = _now();
    return _wishes.values
        .where((TableWish w) => t - w.at < kTableWishLife.inMilliseconds)
        .toList();
  }

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
      if (json is Map) {
        myWish = TableWish.fromJson(json['mine']);
        _wishes.clear();
        for (final Object? w
            in (json['wishes'] as List?) ?? const <Object?>[]) {
          final TableWish? wish = TableWish.fromJson(w);
          if (wish != null) {
            _wishes[wish.address] = wish;
          }
        }
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt Stołu na sześć', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          if (myWish != null) 'mine': myWish!.toJson(),
          'wishes': <Map<String, dynamic>>[
            for (final TableWish w in wishes) w.toJson(),
          ],
        }),
      ),
    );
    notifyListeners();
  }

  /// Turns "Chcę na Stół na sześć" on (city, days) or off (`null`), and
  /// tells friends (who pass it to their friends).
  Future<void> setWish({String? city, Set<int> days = const <int>{}}) async {
    final bool on = city != null && city.trim().isNotEmpty;
    myWish = on
        ? TableWish(
            address: _n(host.ownAddress()),
            name: host.ownName(),
            city: city.trim(),
            days: days,
            at: _now(),
          )
        : null;
    await _save();
    for (final String f in host.friends()) {
      await _send(f, <String, dynamic>{
        'type': kTableWishType,
        'w': on
            ? myWish!.toJson()
            : <String, dynamic>{
                'a': _n(host.ownAddress()),
                'city': '',
                'at': _now(),
              },
        'hops': 1,
      });
    }
  }

  Future<bool> handle(SignalTransportFrame frame) async {
    if (frame.payload['type'] != kTableWishType) {
      return false;
    }
    final String from = _n(frame.from);
    if (!host.isFriend(from)) {
      return true;
    }
    final TableWish? w = TableWish.fromJson(frame.payload['w']);
    final Object? hops = frame.payload['hops'];
    if (w == null || w.address == _n(host.ownAddress())) {
      return true;
    }
    final bool own = w.address == from;
    if (!own && hops != 0) {
      return true; // a friend's friend's wish comes with hops 0 only
    }
    final int latest = _now() + kTableClockSkew.inMilliseconds;
    final TableWish stored = TableWish(
      address: w.address,
      name: w.name,
      city: w.city,
      days: w.days,
      at: min(w.at, latest),
      via: own ? null : from,
    );
    final TableWish? had = _wishes[w.address];
    if (had != null && had.at > stored.at) {
      return true;
    }
    if (w.city.isEmpty) {
      _wishes.remove(w.address);
    } else {
      _wishes[w.address] = stored;
    }
    await _save();
    // A friend's own wish goes one step further.
    if (own && hops is int && hops > 0) {
      for (final String f in host.friends()) {
        if (_n(f) != from) {
          await _send(f, <String, dynamic>{
            'type': kTableWishType,
            'w': stored.toJson(),
            'hops': 0,
          });
        }
      }
    }
    return true;
  }

  /// Picks up to [count] guests for a table in [city] on [when]: everyone
  /// connected to the host (friends, or friends of friends through
  /// [TableWish.via]), as few of whom know each other as possible.
  List<TableWish> pickGuests(String city, DateTime when, {int count = 5}) {
    final List<TableWish> pool =
        wishes.where((TableWish w) => w.matches(city, when)).toList()
          ..shuffle(_random);
    // Friends of friends first: the point is meeting new people.
    pool.sort(
      (TableWish a, TableWish b) =>
          (a.via == null ? 1 : 0).compareTo(b.via == null ? 1 : 0),
    );
    final List<TableWish> chosen = <TableWish>[];
    final Map<String, int> perVia = <String, int>{};
    bool knows(TableWish a, TableWish b) =>
        friendsOf(a.address).containsKey(b.address) ||
        friendsOf(b.address).containsKey(a.address) ||
        (a.via != null && a.via == b.address) ||
        (b.via != null && b.via == a.address);
    // Two passes: first strictly (nobody knows anybody, one per friend who
    // connects them), then filling up.
    for (final bool strict in <bool>[true, false]) {
      for (final TableWish w in pool) {
        if (chosen.length >= count || chosen.contains(w)) {
          continue;
        }
        final String link = w.via ?? w.address;
        if (strict &&
            ((perVia[link] ?? 0) > 0 ||
                chosen.any((TableWish c) => knows(c, w)))) {
          continue;
        }
        chosen.add(w);
        perVia[link] = (perVia[link] ?? 0) + 1;
      }
    }
    return chosen;
  }

  /// Sets a table: an event for six with [guests] invited (through the
  /// friend who connects each of them).
  Future<MeetEvent> setTable({
    required String city,
    required DateTime when,
    required List<TableWish> guests,
    String place = '',
  }) async {
    return events.create(
      title: t('Stół na sześć — {city}', {'city': city}),
      kind: EventKind.table,
      startsAt: when.millisecondsSinceEpoch,
      place: place,
      description: t(
        'Kolacja dla sześciu osób połączonych przez znajomych. Każdy zna '
        'kogoś, kto zna gospodarza.',
      ),
      capacity: 6,
      askForPlusOne: false,
      invite: <String>[for (final TableWish g in guests) g.address],
      vouchers: <String, String>{
        for (final TableWish g in guests)
          if (g.via != null) g.address: g.via!,
      },
    );
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Stół na sześć: do $to: $error');
    }
  }
}
