import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/presentation/circle_screen.dart';
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
    final _Host dina = _Host(net, 'd4', <String>['a1', 'b2', 'c3']);
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
      friends: <String>[bob.address, cela.address, dina.address],
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
        vouch: true,
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
        vouch: true,
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
        vouch: true,
      ),
      isFalse,
    );
    expect(
      await bob.circles.bringGuest(
        c.id,
        DateTime(2026, 11, 5, 19),
        name: 'Ewa',
        vouch: true,
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
        vouch: true,
      ),
      isFalse,
    );
    expect(
      await cela.circles.bringGuest(c.id, day, name: 'Kasia', vouch: true),
      isTrue,
    );
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

  Future<(_Host, _Host, _Host, _Host, _Host)> table() async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2', 'c3', 'd4', 'e5']);
    final _Host bob = _Host(net, 'b2', <String>['a1', 'c3', 'd4', 'e5']);
    final _Host cela = _Host(net, 'c3', <String>['a1', 'b2', 'd4', 'e5']);
    final _Host dina = _Host(net, 'd4', <String>['a1', 'b2', 'c3', 'e5']);
    final _Host edek = _Host(net, 'e5', <String>['a1', 'b2', 'c3', 'd4']);
    return (ania, bob, cela, dina, edek);
  }

  test('a circle has 4–8 members, the host included', () async {
    final (_Host ania, _Host bob, _Host cela, _Host dina, _Host edek) =
        await table();
    Future<DinnerCircle> make(List<String> friends, {bool pairs = false}) =>
        ania.circles.create(
          name: 'Czwartki',
          friends: friends,
          weekday: DateTime.thursday,
          hour: 19,
          firstDinner: DateTime(2026, 10, 1),
          pairs: pairs,
        );

    // Three people (host + 2) are too few, nine too many.
    await expectLater(
      make(<String>[bob.address, cela.address]),
      throwsArgumentError,
    );
    await expectLater(make(<String>[]), throwsArgumentError);
    await expectLater(
      make(<String>[for (int i = 0; i < 8; i++) addr('f$i')]),
      throwsArgumentError,
    );
    // Duplicates and the host himself do not count.
    await expectLater(
      make(<String>[bob.address, bob.address, ania.address, cela.address]),
      throwsArgumentError,
    );
    expect(ania.circles.circles, isEmpty);

    final DinnerCircle four = await make(<String>[
      bob.address,
      cela.address,
      dina.address,
    ]);
    expect(four.members, hasLength(4));
    expect(four.pairs, isFalse);
    expect(four.headcount, 4);
    expect(DinnerCircle.validSize(8), isTrue);
    expect(DinnerCircle.validSize(9), isFalse);

    // "Pairs": every member stands for two people; it reaches the others.
    final DinnerCircle couples = await make(<String>[
      bob.address,
      cela.address,
      dina.address,
      edek.address,
    ], pairs: true);
    expect(couples.pairs, isTrue);
    expect(couples.headcount, 10);
    expect(edek.circles.circle(couples.id)!.pairs, isTrue);

    // Old data without the flag still loads.
    final Map<String, dynamic> old = four.toJson()..remove('pairs');
    expect(DinnerCircle.fromJson(old)!.pairs, isFalse);
  });

  test('the one who brings a guest vouches for them', () async {
    final (_Host ania, _Host bob, _Host cela, _Host dina, _Host _) =
        await table();
    final DinnerCircle c = await ania.circles.create(
      name: 'Czwartki',
      friends: <String>[bob.address, cela.address, dina.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime(2026, 10, 1),
    );
    await ania.circles.setOpen(c.id, true);
    final DateTime day = c.schedule(ania.clock).first.$1;

    // No vouching, no guest.
    expect(await bob.circles.bringGuest(c.id, day, name: 'Ola'), isFalse);
    expect(
      await bob.circles.bringGuest(c.id, day, name: 'Ola', vouch: true),
      isTrue,
    );
    final CircleGuest g = cela.circles.circle(c.id)!.guestsOn(day).single.$2;
    expect(g.vouchedBy, bob.address);

    final DinnerCircle back = DinnerCircle.fromJson(
      jsonDecode(jsonEncode(cela.circles.circle(c.id)!.toJson())),
    )!;
    expect(back.guestsOn(day).single.$2.vouchedBy, bob.address);
    // A guest saved before vouching existed has nobody listed.
    expect(
      CircleGuest.fromJson(<String, String>{
        'n': 'X',
        'd': '2026-10-01',
      })!.vouchedBy,
      isNull,
    );
  });

  test(
    'the shared kitty: contributions, shares and own entries only',
    () async {
      final (_Host ania, _Host bob, _Host cela, _Host dina, _Host _) =
          await table();
      final DinnerCircle c = await ania.circles.create(
        name: 'Czwartki',
        friends: <String>[bob.address, cela.address, dina.address],
        weekday: DateTime.thursday,
        hour: 19,
        firstDinner: DateTime(2026, 10, 1),
      );
      for (final _Host h in <_Host>[ania, bob, cela, dina]) {
        h.clock += 10;
      }
      expect(
        await ania.circles.addToKitty(c.id, 5000, note: 'warzywa'),
        isTrue,
      );
      bob.clock += 20;
      expect(await bob.circles.addToKitty(c.id, 3000), isTrue);
      expect(await bob.circles.addToKitty(c.id, 0), isFalse);

      final DinnerCircle seen = cela.circles.circle(c.id)!;
      expect(seen.kittyTotal, 8000);
      expect(seen.paidBy(ania.address), 5000);
      expect(seen.paidBy(bob.address), 3000);
      expect(seen.kittyShare, 2000);
      expect(seen.kitty.first.note, 'warzywa');

      // Only the author takes back an entry.
      cela.clock += 40;
      await cela.circles.removeKittyEntry(c.id, 0);
      expect(cela.circles.circle(c.id)!.kitty, hasLength(2));
      ania.clock += 50;
      await ania.circles.removeKittyEntry(c.id, 0);
      expect(dina.circles.circle(c.id)!.kittyTotal, 3000);

      // Garbage in the stored list is dropped.
      final Map<String, dynamic> bad = seen.toJson()
        ..['kitty'] = <Object?>[
          <String, Object?>{'a': ania.address, 'c': 0, 't': 1},
          'x',
          <String, Object?>{'a': ania.address, 'c': 700, 't': 1},
        ];
      expect(DinnerCircle.fromJson(bad)!.kittyTotal, 700);
    },
  );

  test('kitty amounts are read in złoty and shown with a comma', () {
    expect(parseKittyCents('12'), 1200);
    expect(parseKittyCents(' 12,50 '), 1250);
    expect(parseKittyCents('12.5'), 1250);
    expect(parseKittyCents('0,05'), 5);
    expect(parseKittyCents('-20'), -2000);
    expect(parseKittyCents('0'), isNull);
    expect(parseKittyCents('abc'), isNull);
    expect(parseKittyCents('1,234'), isNull);
    expect(parseKittyCents(null), isNull);
    expect(formatKitty(2550), '25,50');
    expect(formatKitty(5), '0,05');
    expect(formatKitty(-1200), '-12,00');
  });
}
