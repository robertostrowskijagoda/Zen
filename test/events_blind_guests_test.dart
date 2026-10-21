import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

final class _Host implements EventHost {
  _Host(this.net, String id, this.name, List<String> friends)
    : address = addr(id),
      friendList = friends.map(addr).toList() {
    net[address] = this;
    events = EventService(
      host: this,
      disk: MemoryLedgerDisk(),
      now: () => clock,
    );
  }

  final Map<String, _Host> net;
  final String name;
  final String address;
  final List<String> friendList;
  late final EventService events;
  int clock = 1000;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    await net[to]?.events.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
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
  test('friends of friends get the guest list without addresses — first '
      'names and "znasz N" — until they have a ticket', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', 'Ania Kowalska', <String>['b2', 'd4']);
    final _Host kuba = _Host(net, 'b2', 'Kuba Nowak', <String>[
      'a1',
      'c3',
      'd4',
    ]);
    final _Host ola = _Host(net, 'c3', 'Ola Wiśniewska', <String>['b2']);
    final _Host zosia = _Host(net, 'd4', 'Zosia Lis', <String>['a1', 'b2']);

    final MeetEvent e = await ania.events.create(
      title: 'Urodziny',
      startsAt: 100000,
      reach: EventReach.friendsOfFriends,
    );
    // Ola (Kuba's friend) answers "Może": on the list, and getting news.
    await ola.events.rsvp(e.id, GuestStatus.maybe);
    await kuba.events.rsvp(e.id, GuestStatus.going);
    await zosia.events.rsvp(e.id, GuestStatus.going);

    // The organizer's friends have the full list.
    expect(kuba.events.event(e.id)!.guests.keys, contains(zosia.address));
    // Ola (Kuba's friend) sees first names and hashes, no addresses.
    final MeetEvent far = ola.events.event(e.id)!;
    expect(far.blind, isTrue);
    final String stored = jsonEncode(far.toJson());
    expect(stored, isNot(contains(zosia.address)));
    expect(stored, isNot(contains(kuba.address)));
    expect(stored, isNot(contains('Nowak')));
    expect(
      far.guests.values.map((EventGuest g) => g.name),
      containsAll(<String>['Kuba', 'Zosia', 'Ola']),
    );
    expect(far.goingCount, 2);
    // "Znasz 1": Kuba, found by his hash.
    expect(far.knownGoing(ola.friends()), 1);
    final EventGuest kubaThere = far.guests.values.firstWhere(
      (EventGuest g) => g.name == 'Kuba',
    );
    expect(far.friendIn(kubaThere, ola.friends()), kuba.address);
    expect(far.guest(kuba.address), same(kubaThere));
    expect(far.guest(ola.address)!.status, GuestStatus.maybe);
    expect(ola.events.myGuest(far)!.status, GuestStatus.maybe);

    // "Będę": with her ticket comes the full list.
    await ola.events.rsvp(e.id, GuestStatus.going);
    final MeetEvent near = ola.events.event(e.id)!;
    expect(ola.events.ticket(e.id), isNotNull);
    expect(near.blind, isFalse);
    expect(near.guests.keys, contains(zosia.address));
    expect(ola.events.myGuest(near)!.status, GuestStatus.going);
    expect(near.knownGoing(ola.friends()), 1);
    // The organizer's list never lost a thing.
    expect(
      ania.events.event(e.id)!.guest(ola.address)!.broughtBy,
      kuba.address,
    );
  });

  test('a blind list reads back and passes on as blind', () {
    const MeetEvent e = MeetEvent(
      id: 'ev1',
      organizer: 'self',
      organizerName: 'Ania',
      title: 'X',
      startsAt: 1,
      guests: <String, EventGuest>{
        'aa': EventGuest(
          address: 'aa',
          name: 'Kuba Nowak',
          status: GuestStatus.going,
        ),
        'bb': EventGuest(address: 'bb', name: 'Ola', broughtBy: 'aa'),
      },
    );
    final Map<String, dynamic> json = e.toJson(blind: true);
    expect(jsonEncode(json), isNot(contains('"aa"')));
    final MeetEvent back = MeetEvent.fromJson(json)!;
    expect(back.blind, isTrue);
    expect(back.guest('aa')!.name, 'Kuba');
    expect(back.guest('bb')!.broughtBy, back.blindKey('aa'));
    expect(back.chainOf(back.guest('bb')!.address), hasLength(2));
    // Blind again: the same hashes, never the addresses.
    expect(
      jsonEncode(MeetEvent.fromJson(back.toJson(blind: true))!.toJson()),
      jsonEncode(back.toJson()),
    );
    // A hash belongs to its event only.
    expect(
      MeetEvent.guestHash('ev1', 'aa'),
      isNot(MeetEvent.guestHash('ev2', 'aa')),
    );
  });

  test('"Przyjaciele": only the close friends named are invited and nobody '
      'else may answer', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', 'Ania', <String>['b2', 'd4']);
    final _Host kuba = _Host(net, 'b2', 'Kuba', <String>['a1']);
    final _Host zosia = _Host(net, 'd4', 'Zosia', <String>['a1']);
    final MeetEvent e = await ania.events.create(
      title: 'Kolacja',
      startsAt: 100000,
      reach: EventReach.close,
      invite: <String>[zosia.address],
    );
    expect(zosia.events.event(e.id), isNotNull);
    expect(kuba.events.event(e.id), isNull);
    await kuba.send(ania.address, <String, dynamic>{
      'type': EventTypes.rsvp,
      'id': e.id,
      's': 'maybe',
    });
    expect(ania.events.event(e.id)!.guest(kuba.address), isNull);
    expect(EventReach.byName('close'), EventReach.close);
  });

  test('"Jak było?" a few hours after, once; "Powtórzymy za miesiąc?" '
      'invites those who came', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', 'Ania', <String>['b2', 'd4']);
    final _Host kuba = _Host(net, 'b2', 'Kuba', <String>['a1']);
    final _Host zosia = _Host(net, 'd4', 'Zosia', <String>['a1']);
    final int start = DateTime(2026, 10, 10, 19).millisecondsSinceEpoch;
    for (final _Host h in net.values) {
      h.clock = start - 3600 * 1000;
    }
    final MeetEvent e = await ania.events.create(
      title: 'Stół',
      startsAt: start,
      kind: EventKind.table,
      invite: <String>[kuba.address, zosia.address],
    );
    await kuba.events.rsvp(e.id, GuestStatus.going);
    await zosia.events.rsvp(e.id, GuestStatus.declined);
    expect(kuba.events.howDue(kuba.events.event(e.id)!), isFalse);
    for (final _Host h in net.values) {
      h.clock = start + EventService.howAfter.inMilliseconds;
    }
    expect(kuba.events.howDue(kuba.events.event(e.id)!), isTrue);
    expect(ania.events.howDue(ania.events.event(e.id)!), isTrue);
    expect(zosia.events.howDue(zosia.events.event(e.id)!), isFalse);
    await kuba.events.rate(e.id, 'g');
    expect(kuba.events.howOf(e.id), 'g');
    expect(kuba.events.howDue(kuba.events.event(e.id)!), isFalse);

    expect(await kuba.events.repeat(e.id), isNull, reason: 'not his');
    final MeetEvent again = (await ania.events.repeat(e.id))!;
    expect(again.startsAt, start + 28 * 24 * 3600 * 1000);
    expect(again.kind, EventKind.table);
    expect(again.guests.keys, <String>[kuba.address]);
    expect(kuba.events.event(again.id), isNotNull);
    expect(zosia.events.event(again.id), isNull);
  });
}
