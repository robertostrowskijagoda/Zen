import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/table/table_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

/// Every frame that went over the wire: from, to, as JSON.
final List<(String, String, String)> wire = <(String, String, String)>[];

final class _Host implements EventHost {
  _Host(this.net, String id, this.name, List<String> friends)
    : address = addr(id),
      friendList = friends.map(addr).toList() {
    net[address] = this;
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    events = EventService(host: this, disk: disk, now: () => clock);
    table = TableService(
      host: this,
      events: events,
      disk: disk,
      friendsOf: (String _) => const <String, String>{},
      now: () => clock,
    );
  }

  final Map<String, _Host> net;
  final String name;
  final String address;
  final List<String> friendList;
  late final EventService events;
  late final TableService table;
  int clock = DateTime(2026, 10, 1).millisecondsSinceEpoch;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final String json = jsonEncode(payload);
    wire.add((address, to, json));
    final _Host? other = net[to];
    if (other == null) {
      return;
    }
    final SignalTransportFrame f = SignalTransportFrame(
      from: address,
      payload: jsonDecode(json) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    if (!await other.table.handle(f)) {
      await other.events.handle(f);
    }
  }

  @override
  List<String> friends() => friendList;

  @override
  bool isFriend(String a) =>
      friendList.contains(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);
}

void main() {
  setUp(wire.clear);

  test('Stół na sześć through a friend in between: friends of friends see '
      'a first name, the city, the area and the days; addresses and the '
      'place go only to an accepted guest, sealed', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host hania = _Host(net, 'a1', 'Hania Gospodyni', <String>['b2']);
    final _Host kasia = _Host(net, 'b2', 'Kasia Środkowa', <String>[
      'a1',
      'c3',
      'd4',
    ]);
    final _Host ola = _Host(net, 'c3', 'Ola Nowak', <String>['b2']);
    final _Host gosia = _Host(net, 'd4', 'Gosia Lis', <String>['b2']);

    await ola.table.setWish(
      city: 'Gdańsk',
      area: 'Wrzeszcz',
      days: <int>{DateTime.thursday},
    );
    await gosia.table.setWish(city: 'Gdańsk');
    // Kasia (their friend) has them with their addresses; Hania (a friend of
    // a friend) only with first names, through Kasia.
    expect(kasia.table.wishes.map((TableWish w) => w.address).toSet(), <String>{
      ola.address,
      gosia.address,
    });
    final TableWish seen = hania.table.wishes.firstWhere(
      (TableWish w) => w.id == ola.table.myWish!.id,
    );
    expect(seen.address, isEmpty);
    expect(seen.name, 'Ola');
    expect(seen.area, 'Wrzeszcz');
    expect(seen.days, <int>{DateTime.thursday});
    expect(seen.via, kasia.address);
    expect(
      wire
          .where(((String, String, String) f) => f.$2 == hania.address)
          .any(
            ((String, String, String) f) =>
                f.$3.contains(ola.address) ||
                f.$3.contains(gosia.address) ||
                f.$3.contains('Nowak'),
          ),
      isFalse,
    );

    final DateTime thursday = DateTime(2026, 10, 15, 19);
    final MeetEvent e = await hania.table.setTable(
      city: 'Gdańsk',
      when: thursday,
      guests: hania.table.pickGuests('Gdańsk', thursday),
      place: 'ul. Lipowa 3, II piętro',
    );
    expect(hania.table.sentFor(e.id), hasLength(2));
    final TableInvite toOla = ola.table.invitations.single;
    expect(toOla.via, kasia.address);
    expect(toOla.name, 'Hania');
    expect(toOla.place, isEmpty);
    expect(ola.shown.last.title, 'Zaproszenie na Stół na sześć');

    // Gosia says no; Ola says "Chcę".
    expect(
      await gosia.table.answer(gosia.table.invitations.single.id, false),
      isTrue,
    );
    expect(await ola.table.answer(toOla.id, true), isTrue);
    final Map<String, TableInviteState> states = <String, TableInviteState>{
      for (final TableInvite i in hania.table.sentFor(e.id)) i.wish: i.state,
    };
    expect(states[gosia.table.myWish!.id], TableInviteState.declined);
    expect(states[ola.table.myWish!.id], TableInviteState.asked);
    expect(hania.table.waitingForMe, 1);
    // Still nobody's address at Hania's.
    expect(
      hania.table.sentFor(e.id).any((TableInvite i) => i.address.isNotEmpty),
      isFalse,
    );

    // "Przyjmij": Ola gets the place and Hania's address, Hania Ola's; the
    // event comes to Ola from Hania, who is no friend of hers.
    final String id = hania.table
        .sentFor(e.id)
        .firstWhere((TableInvite i) => i.state == TableInviteState.asked)
        .id;
    expect(await hania.table.accept(id), isTrue);
    final TableInvite olaNow = ola.table.invitations.single;
    expect(olaNow.state, TableInviteState.accepted);
    expect(olaNow.place, 'ul. Lipowa 3, II piętro');
    expect(olaNow.address, hania.address);
    expect(
      hania.table
          .sentFor(e.id)
          .firstWhere((TableInvite i) => i.id == id)
          .address,
      ola.address,
    );
    expect(ola.events.event(e.id), isNotNull);
    expect(
      hania.events.event(e.id)!.guest(ola.address)!.broughtBy,
      kasia.address,
    );

    // Kasia carried it all and read none of it.
    final Iterable<String> throughKasia = wire
        .where(
          ((String, String, String) f) =>
              f.$1 == kasia.address || f.$2 == kasia.address,
        )
        .map(((String, String, String) f) => f.$3);
    expect(throughKasia.any((String f) => f.contains('Lipowa')), isFalse);
    expect(
      wire
          .where(
            ((String, String, String) f) =>
                f.$1 == kasia.address && f.$2 == hania.address,
          )
          .any(((String, String, String) f) => f.$3.contains(ola.address)),
      isFalse,
      reason: 'Ola\'s address reaches Hania sealed only',
    );
    expect(
      wire
          .where(
            ((String, String, String) f) =>
                f.$1 == kasia.address && f.$2 == ola.address,
          )
          .any(((String, String, String) f) => f.$3.contains(hania.address)),
      isFalse,
    );
    // Neither is anything sent straight between the two before both said
    // yes (only the event, after).
    expect(kasia.table.invitations, isEmpty);
  });

  test('the host may say no; a stranger cannot invite or answer', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host hania = _Host(net, 'a1', 'Hania', <String>['b2']);
    final _Host kasia = _Host(net, 'b2', 'Kasia', <String>['a1', 'c3']);
    final _Host ola = _Host(net, 'c3', 'Ola', <String>['b2']);
    final _Host obcy = _Host(net, 'f6', 'Obcy', <String>[]);
    await ola.table.setWish(city: 'Gdańsk');
    final DateTime when = DateTime(2026, 10, 15, 19);
    final MeetEvent e = await hania.table.setTable(
      city: 'Gdańsk',
      when: when,
      guests: hania.table.pickGuests('Gdańsk', when),
    );
    final TableInvite toOla = ola.table.invitations.single;
    await ola.table.answer(toOla.id, true);
    await hania.table.decline(hania.table.sentFor(e.id).single.id);
    expect(ola.table.invitations.single.state, TableInviteState.declined);
    expect(ola.events.event(e.id), isNull);

    // Someone who is no friend of Ola's invites her straight: nothing.
    await obcy.send(ola.address, <String, dynamic>{
      'type': kTableWishType,
      'k': 'inv',
      'e': 'obce1',
      'w': ola.table.myWish!.id,
      'at': when.millisecondsSinceEpoch,
      'c': 'Gdańsk',
      'hn': 'Obcy',
      'hk': hania.table.sentFor(e.id).single.key ?? '',
    });
    expect(ola.table.invitations, hasLength(1));
    // Kasia cannot answer in Ola's name to Hania's other invitations: the
    // answer must come from where the invitation went.
    expect(kasia.table.invitations, isEmpty);
  });

  test('wishes and invitations survive JSON', () {
    const TableWish w = TableWish(
      id: 'w1',
      address: 'x',
      name: 'Ola Nowak',
      city: 'Gdańsk',
      area: 'Wrzeszcz',
      days: <int>{4},
      at: 1,
    );
    final Map<String, dynamic> blind = w.toJson(blind: true);
    expect(blind.containsKey('a'), isFalse);
    expect(blind['n'], 'Ola');
    expect(TableWish.fromJson(blind)!.address, isEmpty);
    expect(TableWish.fromJson(w.toJson())!.area, 'Wrzeszcz');
    const TableInvite i = TableInvite(
      event: 'e1',
      wish: 'w1',
      name: 'Hania',
      peer: 'p',
      at: 5,
      via: 'v',
      state: TableInviteState.asked,
      note: <String, String>{'kc': 'a', 'b': 'b'},
    );
    final TableInvite back = TableInvite.fromJson(
      jsonDecode(jsonEncode(i.toJson())),
    )!;
    expect(back.id, 'e1|w1');
    expect(back.state, TableInviteState.asked);
    expect(back.note, <String, String>{'kc': 'a', 'b': 'b'});
  });
}
