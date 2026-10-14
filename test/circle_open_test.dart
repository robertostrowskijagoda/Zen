import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

final class _Host implements EventHost {
  _Host(this.net, this.name, List<String> friends)
    : address = addr(name),
      friendList = friends.map(addr).toList() {
    net[address] = this;
    circles = CircleService(host: this, disk: disk, now: () => clock);
  }

  final Map<String, _Host> net;
  final String name;
  final String address;
  final List<String> friendList;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late final CircleService circles;
  int clock = DateTime(2026, 10, 1).millisecondsSinceEpoch;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    await net[to]?.circles.handle(
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
  test('kółko otwarte: once a month every member brings one guest', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2', 'c3']);
    final _Host bob = _Host(net, 'b2', <String>['a1', 'c3', 'f6']);
    final _Host cela = _Host(net, 'c3', <String>['a1', 'b2']);
    final _Host ola = _Host(net, 'f6', <String>['b2']);
    final int start = ania.clock;
    int step = 0;
    // Everyone's clock moves on together (the newest copy of a circle wins).
    void tick() {
      step++;
      for (final _Host h in net.values) {
        h.clock = start + step;
      }
    }

    final DinnerCircle c = await ania.circles.create(
      name: 'Czwartki',
      friends: <String>[bob.address, cela.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime(2026, 10, 1),
    );
    final DateTime day = c.schedule(ania.clock).first.$1;
    expect(day, DateTime(2026, 10, 1, 19));

    // Closed circles take no guests.
    expect(
      await bob.circles.bringGuest(
        c.id,
        day,
        name: 'Ola',
        address: ola.address,
      ),
      isFalse,
    );

    tick();
    await ania.circles.setOpen(c.id, true);
    expect(bob.circles.circle(c.id)!.open, isTrue);
    expect(cela.circles.circle(c.id)!.open, isTrue);

    tick();
    expect(
      await bob.circles.bringGuest(
        c.id,
        day,
        name: 'Ola',
        address: ola.address,
      ),
      isTrue,
    );
    expect(ola.shown.single.title, 'b2 zaprasza Cię na obiad');
    expect(ola.shown.single.body, contains('Czwartki'));
    final List<(String, CircleGuest)> coming = cela.circles
        .circle(c.id)!
        .guestsOn(day);
    expect(coming.single.$1, bob.address);
    expect(coming.single.$2.name, 'Ola');
    expect(coming.single.$2.address, ola.address);
    expect(
      ania.circles.circle(c.id)!.guestsOn(day.add(const Duration(days: 7))),
      isEmpty,
    );

    // Once a month: another one in October is refused, November is fine.
    tick();
    expect(
      await bob.circles.bringGuest(
        c.id,
        DateTime(2026, 10, 15, 19),
        name: 'Ewa',
      ),
      isFalse,
    );
    expect(
      await bob.circles.bringGuest(
        c.id,
        DateTime(2026, 11, 5, 19),
        name: 'Ewa',
      ),
      isTrue,
    );
    // Every member has their own +1; members are not guests.
    tick();
    expect(
      await cela.circles.bringGuest(
        c.id,
        day,
        name: 'Bob',
        address: bob.address,
      ),
      isFalse,
    );
    expect(await cela.circles.bringGuest(c.id, day, name: 'Kasia'), isTrue);
    expect(ania.circles.circle(c.id)!.guestsOn(day), hasLength(2));

    // Taking it back frees the month.
    tick();
    await bob.circles.cancelGuest(c.id, day);
    final DinnerCircle now = ania.circles.circle(c.id)!;
    expect(now.guestOf(bob.address, day), isNull);
    expect(now.canBringGuest(bob.address, day), isTrue);
    expect(now.guestOf(bob.address, DateTime(2026, 11, 5))!.name, 'Ewa');

    // It all survives JSON.
    final DinnerCircle back = DinnerCircle.fromJson(
      jsonDecode(jsonEncode(now.toJson())),
    )!;
    expect(back.open, isTrue);
    expect(back.guestsOn(day).single.$2.name, 'Kasia');
    expect(back.guestOf(bob.address, DateTime(2026, 11, 5))!.day, '2026-11-05');

    // Closing it again.
    tick();
    await ania.circles.setOpen(c.id, false);
    expect(
      cela.circles
          .circle(c.id)!
          .canBringGuest(cela.address, DateTime(2026, 12, 3)),
      isFalse,
    );
  });
}
