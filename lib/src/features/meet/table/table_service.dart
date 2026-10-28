import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/sealed_note.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The one payload type of "Stół na sześć". Without `k` a wish (or its
/// withdrawal); with `k`: "inv" (the host invites, for a wish), "ans" (the
/// one who wished answers), "ok" / "no" (the host's decision). A friend in
/// between passes "inv" on to the wisher and the answers back, never
/// seeing more than first names and sealed notes.
const String kTableWishType = 'table_wish';

/// How long a "Chcę na Stół na sześć" is kept without being renewed.
const Duration kTableWishLife = Duration(days: 30);

/// How far a phone's clock may be ahead: a wish dated later than that is
/// taken as made now (a date far ahead would keep it forever and freeze
/// it against the person's own later changes).
const Duration kTableClockSkew = Duration(minutes: 10);

const int kTableMaxArea = 40;

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,40}$');

String _clip(Object? v, int max) {
  if (v is! String) {
    return '';
  }
  final String s = v.trim();
  return s.length > max ? s.substring(0, max) : s;
}

/// The first word of [name] ("Ania" of "Ania Kowalska").
String firstNameOf(String name) {
  final String t = name.trim();
  return t.isEmpty ? '' : t.split(RegExp(r'\s+')).first;
}

/// "Chcę na Stół na sześć": someone's city, area and the days they can.
///
/// A friend gets it with the wisher's address; a friend of a friend only
/// with the wish's [id], the first name, the city, the area and the days
/// ([address] empty) — they can invite only through [via].
@immutable
final class TableWish {
  const TableWish({
    required this.id,
    required this.address,
    required this.name,
    required this.city,
    required this.days,
    required this.at,
    this.area = '',
    this.via,
  });

  final String id;

  /// The wisher's address; empty on a friend of a friend's phone.
  final String address;
  final String name;
  final String city;

  /// Roughly where ("Wrzeszcz"), optional.
  final String area;

  /// Weekdays (1 = Monday … 7 = Sunday).
  final Set<int> days;
  final int at;

  /// The friend it came through (`null` for a friend's own wish).
  final String? via;

  bool matches(String city, DateTime when) =>
      normalizeCity(this.city) == normalizeCity(city) &&
      (days.isEmpty || days.contains(when.weekday));

  /// With [blind] what a friend of a friend gets: no address, the first
  /// name only.
  Map<String, dynamic> toJson({bool blind = false}) => <String, dynamic>{
    'id': id,
    if (!blind && address.isNotEmpty) 'a': address,
    'n': blind ? firstNameOf(name) : name,
    'city': city,
    if (area.isNotEmpty) 'area': area,
    'days': days.toList()..sort(),
    'at': at,
    if (!blind && via != null) 'via': via,
  };

  static TableWish? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        !_idPattern.hasMatch(json['id'] as String) ||
        json['city'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final Object? days = json['days'];
    final Object? a = json['a'];
    final Object? via = json['via'];
    return TableWish(
      id: json['id'] as String,
      address: a is String ? PeerShareCodec.normalizeAddress(a) : '',
      name: _clip(json['n'], 60),
      city: _clip(json['city'], 60),
      area: _clip(json['area'], kTableMaxArea),
      days: <int>{
        if (days is List)
          for (final Object? d in days)
            if (d is int && d >= 1 && d <= 7) d,
      },
      at: json['at'] as int,
      via: via is String ? PeerShareCodec.normalizeAddress(via) : null,
    );
  }
}

String normalizeCity(String city) => city.trim().toLowerCase();

/// What may stand for a mesh address opened from a sealed note.
bool _addressOk(String a) =>
    a.trim().isNotEmpty && a.length <= 100 && !a.contains(RegExp(r'\s'));

/// Where an invitation to a table stands.
enum TableInviteState {
  /// Sent, no answer yet.
  sent,

  /// "Chcę": waiting for the host.
  asked,
  accepted,
  declined;

  static TableInviteState byName(Object? n) =>
      TableInviteState.values
          .where((TableInviteState s) => s.name == n)
          .firstOrNull ??
      TableInviteState.sent;
}

/// One invitation to a table, as the host or the guest keeps it.
@immutable
final class TableInvite {
  const TableInvite({
    required this.event,
    required this.wish,
    required this.name,
    required this.peer,
    required this.at,
    this.city = '',
    this.area = '',
    this.via,
    this.state = TableInviteState.sent,
    this.seed,
    this.key,
    this.note,
    this.address = '',
    this.place = '',
  });

  /// The event of the table.
  final String event;

  /// The wish it answers.
  final String wish;

  /// The host's side: the guest's first name; the guest's: the host's.
  final String name;

  /// Where messages about it go: the other one, or the friend in between.
  final String peer;

  /// When the dinner is.
  final int at;
  final String city;
  final String area;

  /// The friend in between (`null`: directly between friends).
  final String? via;
  final TableInviteState state;

  /// This side's private seed (base64url) for what the other one seals.
  final String? seed;

  /// The other side's public key (base64url).
  final String? key;

  /// The host's side: what the guest sealed (their address), as JSON.
  final Map<String, String>? note;

  /// The host's side, once accepted: the guest's address. The guest's side,
  /// once accepted: the host's address.
  final String address;

  /// The guest's side, once accepted: where the dinner is.
  final String place;

  String get id => '$event|$wish';

  TableInvite copyWith({
    TableInviteState? state,
    String? seed,
    String? key,
    Map<String, String>? note,
    String? address,
    String? place,
    String? name,
  }) => TableInvite(
    event: event,
    wish: wish,
    name: name ?? this.name,
    peer: peer,
    at: at,
    city: city,
    area: area,
    via: via,
    state: state ?? this.state,
    seed: seed ?? this.seed,
    key: key ?? this.key,
    note: note ?? this.note,
    address: address ?? this.address,
    place: place ?? this.place,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'e': event,
    'w': wish,
    'n': name,
    'p': peer,
    'at': at,
    if (city.isNotEmpty) 'c': city,
    if (area.isNotEmpty) 'ar': area,
    'via': ?via,
    's': state.name,
    'sd': ?seed,
    'k': ?key,
    'nt': ?note,
    if (address.isNotEmpty) 'a': address,
    if (place.isNotEmpty) 'pl': place,
  };

  static TableInvite? fromJson(Object? json) {
    if (json is! Map ||
        json['e'] is! String ||
        json['w'] is! String ||
        json['p'] is! String ||
        json['at'] is! int) {
      return null;
    }
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    final Object? nt = json['nt'];
    return TableInvite(
      event: json['e'] as String,
      wish: json['w'] as String,
      name: _clip(json['n'], 60),
      peer: json['p'] as String,
      at: json['at'] as int,
      city: _clip(json['c'], 60),
      area: _clip(json['ar'], kTableMaxArea),
      via: s(json['via']),
      state: TableInviteState.byName(json['s']),
      seed: s(json['sd']),
      key: s(json['k']),
      note: nt is Map
          ? <String, String>{
              for (final MapEntry<dynamic, dynamic> e in nt.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : null,
      address: _clip(json['a'], 100),
      place: _clip(json['pl'], 200),
    );
  }
}

/// Stół na sześć: people who want to have dinner with friends of
/// friends say so (city, area, days); friends see it with the address,
/// friends of friends only with a first name, through the friend who
/// passed it on. Whoever sets a table gets 5 guests picked from that, each
/// connected to the host, knowing each other as little as possible, and
/// invites them — friends of friends through the friend in between.
///
/// Nobody's address is given away before both say yes: the one who wished
/// answers "Chcę" with their address sealed for the host (and a key of
/// their own); the host answers "Przyjmij" with the place and their own
/// address sealed for the guest (sealed_note.dart). The friend in between
/// carries only first names, the date, the city and ciphertext. Then the
/// host puts the guest on the dinner's event, which goes to them directly.
final class TableService extends ChangeNotifier {
  TableService({
    required this.host,
    required this.events,
    required this.disk,
    required this.friendsOf,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

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

  /// Wishes by their id.
  final Map<String, TableWish> _wishes = <String, TableWish>{};

  /// The host's invitations and the guest's, by [TableInvite.id].
  final Map<String, TableInvite> _sent = <String, TableInvite>{};
  final Map<String, TableInvite> _got = <String, TableInvite>{};

  /// As the friend in between: invitation id → (host, guest).
  final Map<String, (String, String)> _relays = <String, (String, String)>{};

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String get _me => _n(host.ownAddress());

  int get now => _now();

  List<TableWish> get wishes {
    final int t = _now();
    return _wishes.values
        .where((TableWish w) => t - w.at < kTableWishLife.inMilliseconds)
        .toList();
  }

  /// The host's invitations to the table of [event].
  List<TableInvite> sentFor(String event) => <TableInvite>[
    for (final TableInvite i in _sent.values)
      if (i.event == event) i,
  ];

  /// Events of tables this person set, newest first.
  List<String> get tables {
    final List<TableInvite> all = _sent.values.toList()
      ..sort((TableInvite a, TableInvite b) => b.at.compareTo(a.at));
    return <String>{for (final TableInvite i in all) i.event}.toList();
  }

  /// Invitations this person got.
  List<TableInvite> get invitations =>
      _got.values.toList()
        ..sort((TableInvite a, TableInvite b) => a.at.compareTo(b.at));

  /// Answers waiting for this person as a host.
  int get waitingForMe => _sent.values
      .where((TableInvite i) => i.state == TableInviteState.asked)
      .length;

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
            _wishes[wish.id] = wish;
          }
        }
        void invites(Map<String, TableInvite> into, Object? raw) {
          into.clear();
          if (raw is List) {
            for (final Object? i in raw.take(500)) {
              if (TableInvite.fromJson(i) case final TableInvite x) {
                into[x.id] = x;
              }
            }
          }
        }

        invites(_sent, json['sent']);
        invites(_got, json['got']);
        _relays.clear();
        (json['rel'] as Map?)?.forEach((Object? k, Object? v) {
          if (k is String && v is List && v.length == 2) {
            if (v[0] case final String h) {
              if (v[1] case final String g) {
                _relays[k] = (h, g);
              }
            }
          }
        });
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Reading Table for six', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    // Tables long past go.
    final int cutoff = _now() - const Duration(days: 30).inMilliseconds;
    _sent.removeWhere((String _, TableInvite i) => i.at < cutoff);
    _got.removeWhere((String _, TableInvite i) => i.at < cutoff);
    while (_relays.length > 500) {
      _relays.remove(_relays.keys.first);
    }
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          if (myWish != null) 'mine': myWish!.toJson(),
          'wishes': <Map<String, dynamic>>[
            for (final TableWish w in wishes) w.toJson(),
          ],
          'sent': <Map<String, dynamic>>[
            for (final TableInvite i in _sent.values) i.toJson(),
          ],
          'got': <Map<String, dynamic>>[
            for (final TableInvite i in _got.values) i.toJson(),
          ],
          'rel': <String, List<String>>{
            for (final MapEntry<String, (String, String)> r in _relays.entries)
              r.key: <String>[r.value.$1, r.value.$2],
          },
        }),
      ),
    );
    notifyListeners();
  }

  String _newId() => List<String>.generate(
    14,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  /// Turns "Chcę na Stół na sześć" on (city, area, days) or off (`null`),
  /// and tells friends (who pass it, without the address, to theirs).
  Future<void> setWish({
    String? city,
    Set<int> days = const <int>{},
    String area = '',
  }) async {
    final bool on = city != null && city.trim().isNotEmpty;
    final String id = myWish?.id ?? _newId();
    myWish = on
        ? TableWish(
            id: id,
            address: _me,
            name: host.ownName(),
            city: _clip(city, 60),
            area: _clip(area, kTableMaxArea),
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
            : <String, dynamic>{'id': id, 'a': _me, 'city': '', 'at': _now()},
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
    switch (frame.payload['k']) {
      case null:
        await _onWish(from, frame.payload);
      case 'inv':
        await _onInvite(from, frame.payload);
      case 'ans':
        await _onAnswer(from, frame.payload);
      case 'ok' || 'no':
        await _onDecision(from, frame.payload);
    }
    return true;
  }

  Future<void> _onWish(String from, Map<String, dynamic> payload) async {
    final TableWish? w = TableWish.fromJson(payload['w']);
    final Object? hops = payload['hops'];
    if (w == null || w.address == _me || w.id == myWish?.id) {
      return;
    }
    final bool own = w.address == from;
    if (!own && hops != 0) {
      return; // a friend's friend's wish comes with hops 0 only
    }
    final int latest = _now() + kTableClockSkew.inMilliseconds;
    final TableWish stored = TableWish(
      id: w.id,
      // A friend's friend's wish never names them, whatever it says.
      address: own ? w.address : '',
      name: own ? w.name : firstNameOf(w.name),
      city: w.city,
      area: w.area,
      days: w.days,
      at: min(w.at, latest),
      via: own ? null : from,
    );
    final TableWish? had = _wishes[w.id];
    if (had != null &&
        (had.at > stored.at ||
            // The wisher's own copy beats one passed on.
            (had.address.isNotEmpty && !own) ||
            (had.address.isNotEmpty && own && had.address != w.address))) {
      return;
    }
    if (w.city.isEmpty) {
      _wishes.remove(w.id);
    } else {
      _wishes[w.id] = stored;
    }
    await _save();
    // A friend's own wish goes one step further, without the address.
    if (own && hops is int && hops > 0) {
      for (final String f in host.friends()) {
        if (_n(f) != from) {
          await _send(f, <String, dynamic>{
            'type': kTableWishType,
            'w': w.city.isEmpty
                ? <String, dynamic>{'id': w.id, 'city': '', 'at': stored.at}
                : stored.toJson(blind: true),
            'hops': 0,
          });
        }
      }
    }
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
        (a.address.isNotEmpty &&
            b.address.isNotEmpty &&
            (friendsOf(a.address).containsKey(b.address) ||
                friendsOf(b.address).containsKey(a.address))) ||
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

  static String _context(String side, String event, String wish) =>
      'zen.table|$side|$event|$wish';

  /// Sets a table: an event for six, and an invitation to each of
  /// [guests] — directly to a friend, through the friend in between to a
  /// friend of a friend. Guests come onto the event once they said "Chcę"
  /// and this person said "Przyjmij" ([accept]).
  Future<MeetEvent> setTable({
    required String city,
    required DateTime when,
    required List<TableWish> guests,
    String place = '',
  }) async {
    final MeetEvent e = await events.create(
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
    );
    for (final TableWish g in guests) {
      final String peer = g.via ?? g.address;
      if (peer.isEmpty) {
        continue;
      }
      final HybridKeyPair keys = await HybridKeyPair.generate();
      final TableInvite invite = TableInvite(
        event: e.id,
        wish: g.id,
        name: g.name,
        peer: peer,
        at: e.startsAt,
        city: g.city,
        area: g.area,
        via: g.via,
        seed: base64Url.encode(keys.seed),
      );
      _sent[invite.id] = invite;
      await _save();
      await _send(peer, <String, dynamic>{
        'type': kTableWishType,
        'k': 'inv',
        'e': e.id,
        'w': g.id,
        'at': e.startsAt,
        'c': city,
        'hn': firstNameOf(host.ownName()),
        'hk': base64Url.encode(keys.publicKey),
      });
    }
    return e;
  }

  /// An invitation: for this person's wish (from the host, or through the
  /// friend in between), or, as the friend in between, for a friend's.
  Future<void> _onInvite(String from, Map<String, dynamic> payload) async {
    final Object? e = payload['e'];
    final Object? w = payload['w'];
    final Object? at = payload['at'];
    final Object? hk = payload['hk'];
    if (e is! String ||
        w is! String ||
        !_idPattern.hasMatch(e) ||
        !_idPattern.hasMatch(w) ||
        at is! int ||
        decodeHybridPublicKey(hk) == null) {
      return;
    }
    final String id = '$e|$w';
    final TableWish? mine = myWish;
    if (mine != null && mine.id == w) {
      if (_got.containsKey(id)) {
        return;
      }
      final bool relayed = payload['r'] == true;
      final TableInvite invite = TableInvite(
        event: e,
        wish: w,
        name: _clip(payload['hn'], 60),
        peer: from,
        at: at,
        city: _clip(payload['c'], 60),
        via: relayed ? from : null,
        key: hk as String,
      );
      _got[id] = invite;
      await _save();
      final DateTime when = DateTime.fromMillisecondsSinceEpoch(at);
      await host.notify(
        RuntimeSystemNotification(
          id: 'circle-table-$id',
          title: t('Zaproszenie na Stół na sześć'),
          body: relayed
              ? t('{date}, {city} — u {name}, przez {via}.', {
                  'date': ZenFormat.dayMonthTime(when),
                  'city': invite.city,
                  'name': invite.name,
                  'via': host.nameOf(from),
                })
              : t('{date}, {city} — u {name}.', {
                  'date': ZenFormat.dayMonthTime(when),
                  'city': invite.city,
                  'name': host.nameOf(from),
                }),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'table:$id',
        ),
      );
      return;
    }
    // A friend's wish: passed on to them, without saying who the host is.
    final TableWish? wish = _wishes[w];
    if (wish == null ||
        wish.address.isEmpty ||
        wish.address == from ||
        _relays.containsKey(id)) {
      return;
    }
    _relays[id] = (from, wish.address);
    await _save();
    await _send(wish.address, <String, dynamic>{
      'type': kTableWishType,
      'k': 'inv',
      'e': e,
      'w': w,
      'at': at,
      'c': _clip(payload['c'], 60),
      'hn': firstNameOf(_clip(payload['hn'], 60)),
      'hk': hk,
      'r': true,
    });
  }

  /// "Chcę" ([yes]) or "Nie, dziękuję" to an invitation. "Chcę" seals this
  /// person's address for the host and sends a key for the host's answer;
  /// the dinner's event is then taken from the host even when they are no
  /// friend.
  Future<bool> answer(String id, bool yes) async {
    final TableInvite? i = _got[id];
    final Uint8List? hk = decodeHybridPublicKey(i?.key);
    if (i == null || hk == null || i.state != TableInviteState.sent) {
      return false;
    }
    if (!yes) {
      _got[id] = i.copyWith(state: TableInviteState.declined);
      await _save();
      await _send(i.peer, <String, dynamic>{
        'type': kTableWishType,
        'k': 'ans',
        'e': i.event,
        'w': i.wish,
        'y': false,
      });
      return true;
    }
    final HybridKeyPair keys = await HybridKeyPair.generate();
    final SealedNote note = await sealNote(
      hk,
      _context('guest', i.event, i.wish),
      <String, dynamic>{'a': _me, 'n': host.ownName()},
    );
    _got[id] = i.copyWith(
      state: TableInviteState.asked,
      seed: base64Url.encode(keys.seed),
    );
    await _save();
    await events.expect(i.event);
    await _send(i.peer, <String, dynamic>{
      'type': kTableWishType,
      'k': 'ans',
      'e': i.event,
      'w': i.wish,
      'y': true,
      'n': firstNameOf(host.ownName()),
      's': note.toJson(),
      'ek': base64Url.encode(keys.publicKey),
    });
    return true;
  }

  Future<void> _onAnswer(String from, Map<String, dynamic> payload) async {
    final Object? e = payload['e'];
    final Object? w = payload['w'];
    if (e is! String || w is! String) {
      return;
    }
    final String id = '$e|$w';
    final (String, String)? relay = _relays[id];
    if (relay != null && relay.$2 == from) {
      await _send(relay.$1, <String, dynamic>{
        'type': kTableWishType,
        'k': 'ans',
        'e': e,
        'w': w,
        'y': payload['y'] == true,
        if (payload['n'] is String) 'n': firstNameOf(payload['n'] as String),
        if (payload['s'] is Map) 's': payload['s'],
        if (payload['ek'] is String) 'ek': payload['ek'],
      });
      return;
    }
    final TableInvite? i = _sent[id];
    if (i == null || i.peer != from || i.state != TableInviteState.sent) {
      return;
    }
    if (payload['y'] != true) {
      _sent[id] = i.copyWith(state: TableInviteState.declined);
      await _save();
      return;
    }
    final SealedNote? note = SealedNote.fromJson(payload['s']);
    final Object? ek = payload['ek'];
    if (note == null || decodeHybridPublicKey(ek) == null) {
      return;
    }
    final Object? n = payload['n'];
    _sent[id] = i.copyWith(
      state: TableInviteState.asked,
      key: ek as String,
      note: note.toJson(),
      name: n is String && n.trim().isNotEmpty ? firstNameOf(n) : null,
    );
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'circle-table-ans-$id',
        title: t('{name} chce przyjść na Stół na sześć', {
          'name': _sent[id]!.name,
        }),
        body: i.via == null
            ? t('Przyjmij albo odmów w aplikacji.')
            : t('Przez {via}. Przyjmij albo odmów w aplikacji.', {
                'via': host.nameOf(i.via!),
              }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'table:$e',
      ),
    );
  }

  /// "Przyjmij": the guest's address opens here, the place and this
  /// person's address go to them sealed, and they come onto the event.
  Future<bool> accept(String id) async {
    final TableInvite? i = _sent[id];
    final Uint8List? seed = noteBytes(i?.seed, maxChars: 100);
    final Uint8List? ek = decodeHybridPublicKey(i?.key);
    final SealedNote? sealed = SealedNote.fromJson(i?.note);
    if (i == null ||
        seed == null ||
        ek == null ||
        sealed == null ||
        i.state != TableInviteState.asked) {
      return false;
    }
    final Map<String, dynamic>? who = await openNote(
      seed,
      _context('guest', i.event, i.wish),
      sealed,
    );
    final Object? a = who?['a'];
    final Object? n = who?['n'];
    if (a is! String || !_addressOk(a)) {
      return false;
    }
    final MeetEvent? e = events.event(i.event);
    final SealedNote back = await sealNote(
      ek,
      _context('host', i.event, i.wish),
      <String, dynamic>{'pl': e?.place ?? '', 'h': _me, 'n': host.ownName()},
    );
    final String guest = _n(a);
    final String name = n is String && n.trim().isNotEmpty
        ? _clip(n, 60)
        : i.name;
    _sent[id] = i.copyWith(
      state: TableInviteState.accepted,
      address: guest,
      name: name,
    );
    await _save();
    await _send(i.peer, <String, dynamic>{
      'type': kTableWishType,
      'k': 'ok',
      'e': i.event,
      'w': i.wish,
      's': back.toJson(),
    });
    await events.addGuest(i.event, guest, name: name, broughtBy: i.via);
    return true;
  }

  /// "Odmów".
  Future<void> decline(String id) async {
    final TableInvite? i = _sent[id];
    if (i == null ||
        (i.state != TableInviteState.asked &&
            i.state != TableInviteState.sent)) {
      return;
    }
    _sent[id] = i.copyWith(state: TableInviteState.declined);
    await _save();
    await _send(i.peer, <String, dynamic>{
      'type': kTableWishType,
      'k': 'no',
      'e': i.event,
      'w': i.wish,
    });
  }

  Future<void> _onDecision(String from, Map<String, dynamic> payload) async {
    final Object? e = payload['e'];
    final Object? w = payload['w'];
    final Object? k = payload['k'];
    if (e is! String || w is! String) {
      return;
    }
    final String id = '$e|$w';
    final (String, String)? relay = _relays[id];
    if (relay != null && relay.$1 == from) {
      await _send(relay.$2, <String, dynamic>{
        'type': kTableWishType,
        'k': k,
        'e': e,
        'w': w,
        if (payload['s'] is Map) 's': payload['s'],
      });
      return;
    }
    final TableInvite? i = _got[id];
    if (i == null || i.peer != from || i.state != TableInviteState.asked) {
      return;
    }
    if (k == 'no') {
      _got[id] = i.copyWith(state: TableInviteState.declined);
      await _save();
      return;
    }
    final Uint8List? seed = noteBytes(i.seed, maxChars: 100);
    final SealedNote? sealed = SealedNote.fromJson(payload['s']);
    final Map<String, dynamic>? opened = seed == null || sealed == null
        ? null
        : await openNote(seed, _context('host', e, w), sealed);
    final Object? h = opened?['h'];
    if (h is! String || !_addressOk(h)) {
      return;
    }
    final Object? n = opened?['n'];
    _got[id] = i.copyWith(
      state: TableInviteState.accepted,
      address: _n(h),
      place: _clip(opened?['pl'], 200),
      name: n is String && n.trim().isNotEmpty ? _clip(n, 60) : null,
    );
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'circle-table-ok-$id',
        title: t('Przyjęte: Stół na sześć'),
        body: t('{name} czeka na Ciebie. Szczegóły w aplikacji.', {
          'name': _got[id]!.name,
        }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'table:$id',
      ),
    );
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Table for six: to $to: $error');
    }
  }
}
