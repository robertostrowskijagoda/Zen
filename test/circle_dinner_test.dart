import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_thread.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

/// Phones that deliver at once (unless the other one is [offline]).
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
  bool offline = false;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Host? other = net[to];
    if (other == null || other.offline) {
      return;
    }
    await other.circles.handle(
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

  Iterable<String> get titles =>
      shown.map((RuntimeSystemNotification n) => n.title);
}

/// Ania, friends with everyone; the others friends with each other too.
final class _World {
  _World() {
    for (final String n in <String>['a1', 'b2', 'c3', 'd4', 'e5']) {
      _Host(net, n, <String>[
        for (final String o in <String>['a1', 'b2', 'c3', 'd4', 'e5'])
          if (o != n) o,
      ]);
    }
  }

  final Map<String, _Host> net = <String, _Host>{};

  _Host get ania => net[addr('a1')]!;
  _Host get bob => net[addr('b2')]!;
  _Host get cela => net[addr('c3')]!;
  _Host get dina => net[addr('d4')]!;
  _Host get edek => net[addr('e5')]!;

  void advance(int millis) {
    for (final _Host h in net.values) {
      h.clock += millis;
    }
  }

  Future<DinnerCircle> circle({List<_Host>? join, bool pairs = false}) async {
    final DinnerCircle c = await ania.circles.create(
      name: 'Czwartki',
      friends: <String>[bob.address, cela.address, dina.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime(2026, 10, 1),
      pairs: pairs,
    );
    for (final _Host h in join ?? <_Host>[bob, cela, dina]) {
      advance(1);
      await h.circles.answerInvite(c.id, true);
    }
    return ania.circles.circle(c.id)!;
  }
}

List<String> _names(DinnerCircle c) =>
    c.members.map((CircleMember m) => m.name).toList();

void main() {
  test('an invitation must be accepted: "Dołączam" joins at the end of the '
      'queue, "Nie, dziękuję" stays out for good', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle(join: <_Host>[]);
    expect(_names(c), <String>['a1']);
    expect(c.invited.keys, containsAll(<String>[w.bob.address]));
    // Invited, not in: nothing to do with it but answer.
    expect(w.bob.circles.circles, isEmpty);
    expect(w.bob.circles.invitations.single.id, c.id);
    expect(w.bob.titles, contains('Zaproszenie do kółka: Czwartki'));
    await w.bob.circles.rsvp(c.id, DateTime(2026, 10, 1), CircleAttendance.yes);
    expect(w.ania.circles.circle(c.id)!.rsvp, isEmpty);

    w.advance(1);
    await w.bob.circles.answerInvite(c.id, true);
    expect(w.bob.circles.circles.single.id, c.id);
    expect(_names(w.ania.circles.circle(c.id)!), <String>['a1', 'b2']);
    expect(w.ania.titles, contains('b2 dołącza do kółka'));
    // The others invited hear it too.
    expect(_names(w.cela.circles.circle(c.id)!), <String>['a1', 'b2']);

    w.advance(1);
    await w.dina.circles.answerInvite(c.id, false);
    expect(w.dina.circles.circle(c.id), isNull);
    expect(w.dina.circles.invitations, isEmpty);
    expect(w.ania.titles, contains('d4 nie dołączy do kółka'));
    final DinnerCircle seen = w.bob.circles.circle(c.id)!;
    expect(seen.isInvited(w.dina.address), isFalse);
    expect(seen.gone.keys, contains(w.dina.address));
    // An old copy still listing her as invited does not bring it back.
    await w.ania.send(w.dina.address, <String, dynamic>{
      'type': CircleTypes.circle,
      'c': c.toJson(),
    });
    expect(w.dina.circles.circle(c.id), isNull);

    w.advance(1);
    await w.cela.circles.answerInvite(c.id, true);
    // Too few: someone else is invited later and comes last.
    expect(w.ania.circles.circle(c.id)!.small, isTrue);
    w.advance(1);
    expect(await w.bob.circles.invite(c.id, <String>[w.edek.address]), 1);
    expect(w.edek.circles.invitations.single.id, c.id);
    w.advance(1);
    await w.edek.circles.answerInvite(c.id, true);
    for (final _Host h in <_Host>[w.ania, w.bob, w.cela, w.edek]) {
      final DinnerCircle mine = h.circles.circle(c.id)!;
      expect(_names(mine), <String>['a1', 'b2', 'c3', 'e5'], reason: h.name);
      expect(mine.invited, isEmpty, reason: h.name);
      expect(mine.small, isFalse);
    }
    expect(
      w.cela.circles
          .circle(c.id)!
          .schedule(w.cela.clock, count: 4)
          .map(((DateTime, CircleMember) x) => x.$2.name)
          .toList(),
      <String>['a1', 'b2', 'c3', 'e5'],
    );
  });

  test('"Opuść kółko": out for everyone, the queue is worked out again, and '
      'an older copy does not bring the member back', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle();
    final DinnerCircle before = w.bob.circles.circle(c.id)!;
    expect(_names(before), <String>['a1', 'b2', 'c3', 'd4']);

    w.advance(10);
    await w.cela.circles.leave(c.id);
    expect(w.cela.circles.circle(c.id), isNull);
    for (final _Host h in <_Host>[w.ania, w.bob, w.dina]) {
      expect(_names(h.circles.circle(c.id)!), <String>['a1', 'b2', 'd4']);
      expect(h.titles, contains('c3 opuszcza kółko'));
    }
    expect(
      w.ania.circles
          .circle(c.id)!
          .schedule(w.ania.clock, count: 3)
          .map(((DateTime, CircleMember) x) => x.$2.name)
          .toList(),
      <String>['a1', 'b2', 'd4'],
    );

    // Bob was offline and changes his old copy: Cela stays out.
    final Map<String, dynamic> stale = before.toJson()
      ..['name'] = 'Czwartki u Bartka'
      ..['upd'] = w.bob.clock + 5;
    await w.bob.send(w.ania.address, <String, dynamic>{
      'type': CircleTypes.circle,
      'c': stale,
    });
    final DinnerCircle merged = w.ania.circles.circle(c.id)!;
    expect(merged.name, 'Czwartki u Bartka');
    expect(_names(merged), <String>['a1', 'b2', 'd4']);
    // And she gets nothing more.
    expect(w.cela.circles.circle(c.id), isNull);
    // Only an invitation brings her back.
    w.advance(10);
    await w.ania.circles.invite(c.id, <String>[w.cela.address]);
    expect(w.cela.circles.invitations.single.id, c.id);
  });

  test('copies merge to the same circle whatever order they come in', () {
    const DinnerCircle base = DinnerCircle(
      id: 'x1',
      name: 'Czwartki',
      members: <CircleMember>[CircleMember('a', 'A', pos: 1, at: 1)],
      weekday: 4,
      hour: 19,
      firstDinner: 0,
      invited: <String, CircleInvite>{
        'b': CircleInvite(name: 'B', by: 'a', at: 1),
        'c': CircleInvite(name: 'C', by: 'a', at: 1),
      },
      updatedAt: 1,
    );
    // B joined on one phone, C on another; D left after joining.
    final DinnerCircle one = base.copyWith(
      members: <CircleMember>[
        ...base.members,
        const CircleMember('b', 'B', pos: 5, at: 5),
      ],
      invited: <String, CircleInvite>{'c': base.invited['c']!},
      rsvp: <String, Map<String, CircleMark<CircleAttendance>>>{
        '2026-10-01': <String, CircleMark<CircleAttendance>>{
          'a': const CircleMark<CircleAttendance>(CircleAttendance.yes, 7),
        },
      },
    );
    final DinnerCircle two = base.copyWith(
      members: <CircleMember>[
        ...base.members,
        const CircleMember('c', 'C', pos: 4, at: 4),
      ],
      invited: <String, CircleInvite>{'b': base.invited['b']!},
      rsvp: <String, Map<String, CircleMark<CircleAttendance>>>{
        '2026-10-01': <String, CircleMark<CircleAttendance>>{
          'a': const CircleMark<CircleAttendance>(CircleAttendance.no, 9),
          'c': const CircleMark<CircleAttendance>(CircleAttendance.maybe, 6),
        },
      },
      gone: <String, int>{'d': 8},
    );
    final DinnerCircle ab = DinnerCircle.merge(one, two);
    final DinnerCircle ba = DinnerCircle.merge(two, one);
    for (final DinnerCircle m in <DinnerCircle>[ab, ba]) {
      expect(_names(m), <String>['A', 'C', 'B']);
      expect(m.invited, isEmpty);
      expect(m.attendanceOf('a', '2026-10-01'), CircleAttendance.no);
      expect(m.attendanceOf('c', '2026-10-01'), CircleAttendance.maybe);
      expect(m.gone['d'], 8);
    }
    expect(jsonEncode(ab.toJson()), jsonEncode(ba.toJson()));
    // A member who joined before leaving stays out; one who came back
    // after leaving is in.
    final DinnerCircle left = DinnerCircle.merge(
      ab,
      ab.copyWith(gone: <String, int>{'b': 6}),
    );
    expect(_names(left), <String>['A', 'C']);
    final DinnerCircle back = DinnerCircle.merge(
      left,
      left.copyWith(
        members: <CircleMember>[
          ...left.members,
          const CircleMember('b', 'B', pos: 20, at: 20),
        ],
      ),
    );
    expect(_names(back), <String>['A', 'C', 'B']);
  });

  test('"Kto będzie w czwartek?": answers, the cook\'s count with diets and '
      'guests, and two answers at once both stay', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle();
    final DateTime day = DateTime(2026, 10, 1, 19);
    await w.bob.circles.setMyDiets(c.id, <CircleDiet>{CircleDiet.noGluten});
    await w.cela.circles.setMyDiets(c.id, <CircleDiet>{
      CircleDiet.vegetarian,
      CircleDiet.noNuts,
    });
    w.advance(1);
    // Ania is offline: Bob's and Cela's answers meet only on her phone.
    w.ania.offline = true;
    await w.bob.circles.rsvp(c.id, day, CircleAttendance.yes);
    await w.cela.circles.rsvp(c.id, day, CircleAttendance.yes);
    await w.dina.circles.rsvp(c.id, day, CircleAttendance.maybe);
    w.ania.offline = false;
    // Then the copies arrive in any order.
    for (final _Host h in <_Host>[w.dina, w.cela, w.bob]) {
      await h.send(w.ania.address, <String, dynamic>{
        'type': CircleTypes.circle,
        'c': h.circles.circle(c.id)!.toJson(),
      });
    }
    await w.ania.circles.rsvp(c.id, day, CircleAttendance.yes);
    final DinnerCircle seen = w.dina.circles.circle(c.id)!;
    expect(
      seen.attendanceOf(w.bob.address, '2026-10-01'),
      CircleAttendance.yes,
    );
    expect(
      seen.attendanceOf(w.cela.address, '2026-10-01'),
      CircleAttendance.yes,
    );
    final CircleHeadcount count = w.ania.circles.circle(c.id)!.headcountOn(day);
    expect(count.yes, 3);
    expect(count.maybe, 1);
    expect(count.people, 3);
    expect(count.diets[CircleDiet.noGluten], 1);
    expect(count.diets[CircleDiet.vegetarian], 1);
    expect(
      circleCountText(count),
      '3 osoby · Wegetariańska dieta: 1 · Bez glutenu: 1 · Bez orzechów: 1 · '
      'Może: 1',
    );
    // A guest of the open circle sits at the table too.
    w.advance(1);
    await w.ania.circles.setOpen(c.id, true);
    w.advance(1);
    await w.bob.circles.bringGuest(c.id, day, name: 'Ola', vouch: true);
    expect(w.cela.circles.circle(c.id)!.headcountOn(day).people, 4);
    // Changing one's mind replaces the answer.
    w.advance(1);
    await w.bob.circles.rsvp(c.id, day, CircleAttendance.no);
    expect(w.ania.circles.circle(c.id)!.headcountOn(day).yes, 2);
  });

  test('the reminder the day before (the cook gets the count) and "Jak '
      'było?" after, each once', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle();
    final DateTime day = DateTime(2026, 10, 1, 19);
    await w.bob.circles.rsvp(c.id, day, CircleAttendance.yes);
    await w.dina.circles.rsvp(c.id, day, CircleAttendance.no);
    // A week and a day before: nothing yet.
    for (final _Host h in w.net.values) {
      h.clock = DateTime(2026, 9, 29, 19).millisecondsSinceEpoch;
      await h.circles.tick();
    }
    expect(w.ania.titles.where((String t) => t.startsWith('Jutro')), isEmpty);
    for (final _Host h in w.net.values) {
      h.clock = DateTime(2026, 9, 30, 20).millisecondsSinceEpoch;
      await h.circles.tick();
      await h.circles.tick();
    }
    expect(
      w.ania.titles.where((String t) => t == 'Jutro gotujesz: Czwartki'),
      hasLength(1),
    );
    expect(
      w.ania.shown
          .where((RuntimeSystemNotification n) => n.title.startsWith('Jutro'))
          .single
          .body,
      contains('1 osoba'),
    );
    expect(w.bob.titles, contains('Jutro obiad: Czwartki'));
    expect(
      w.cela.shown
          .where((RuntimeSystemNotification n) => n.title.startsWith('Jutro'))
          .single
          .body,
      contains('Będziesz?'),
    );
    expect(w.edek.shown, isEmpty);

    // Three hours after it started: "Jak było?" (not for who did not come).
    for (final _Host h in w.net.values) {
      h.clock = DateTime(2026, 10, 1, 21).millisecondsSinceEpoch;
    }
    expect(w.bob.circles.howPending(c.id), isNull);
    for (final _Host h in w.net.values) {
      h.clock = DateTime(2026, 10, 1, 22, 30).millisecondsSinceEpoch;
      await h.circles.tick();
      await h.circles.tick();
    }
    expect(w.bob.circles.howPending(c.id), day);
    expect(
      w.bob.titles.where((String t) => t == 'Jak było? Czwartki'),
      hasLength(1),
    );
    expect(w.dina.titles, isNot(contains('Jak było? Czwartki')));
    expect(w.dina.circles.howPending(c.id), isNull);
    await w.bob.circles.rate(c.id, day, CircleHow.great);
    await w.cela.circles.rate(c.id, day, CircleHow.fine);
    expect(w.bob.circles.howPending(c.id), isNull);
    final DinnerCircle seen = w.ania.circles.circle(c.id)!;
    expect(seen.how['2026-10-01']![w.bob.address]!.value, CircleHow.great);
    expect(seen.how['2026-10-01']![w.cela.address]!.value, CircleHow.fine);
    // Two days on, no longer asked.
    for (final _Host h in w.net.values) {
      h.clock = DateTime(2026, 10, 4).millisecondsSinceEpoch;
    }
    expect(w.ania.circles.howPending(c.id), isNull);
  });

  test('"Kto komu ile": equal parts of the shopping, the transfers and '
      '"Rozliczone ✓" by one of the two', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle();
    final DateTime day = DateTime(2026, 10, 1, 19);
    for (final _Host h in <_Host>[w.ania, w.bob, w.cela]) {
      await h.circles.rsvp(c.id, day, CircleAttendance.yes);
    }
    await w.dina.circles.rsvp(c.id, day, CircleAttendance.no);
    w.advance(1);
    expect(await w.ania.circles.setSpent(c.id, day, 9000), isTrue);
    expect(await w.bob.circles.setSpent(c.id, day, 3000), isTrue);
    expect(await w.bob.circles.setSpent(c.id, day, -1), isFalse);
    final DinnerCircle seen = w.dina.circles.circle(c.id)!;
    expect(seen.spentOn('2026-10-01'), 12000);
    expect(seen.settleUp('2026-10-01'), <CircleTransfer>[
      CircleTransfer(w.cela.address, w.ania.address, 4000),
      CircleTransfer(w.bob.address, w.ania.address, 1000),
    ]);
    // Only one of the two marks it.
    final CircleTransfer celaPays = seen.settleUp('2026-10-01').first;
    await w.dina.circles.markSettled(c.id, day, celaPays);
    expect(
      w.ania.circles.circle(c.id)!.isSettled('2026-10-01', celaPays),
      isFalse,
    );
    w.advance(1);
    await w.cela.circles.markSettled(c.id, day, celaPays);
    for (final _Host h in <_Host>[w.ania, w.bob, w.cela, w.dina]) {
      expect(
        h.circles.circle(c.id)!.isSettled('2026-10-01', celaPays),
        isTrue,
        reason: h.name,
      );
    }
    // A different amount is a different transfer.
    w.advance(1);
    await w.bob.circles.setSpent(c.id, day, 0);
    final List<CircleTransfer> again = w.ania.circles
        .circle(c.id)!
        .settleUp('2026-10-01');
    expect(again.map((CircleTransfer x) => x.cents), <int>[3000, 3000]);
    expect(
      again.any(
        (CircleTransfer x) =>
            w.ania.circles.circle(c.id)!.isSettled('2026-10-01', x),
      ),
      isFalse,
    );
  });

  test(
    'settling up rounds to the grosz and nobody answered means everyone',
    () {
      final DinnerCircle c = DinnerCircle(
        id: 'x',
        name: 'X',
        members: const <CircleMember>[
          CircleMember('a', 'A', pos: 1),
          CircleMember('b', 'B', pos: 2),
          CircleMember('c', 'C', pos: 3),
        ],
        weekday: 4,
        hour: 19,
        firstDinner: 0,
        spent: <String, Map<String, CircleMark<int>>>{
          '2026-10-01': <String, CircleMark<int>>{
            'a': const CircleMark<int>(10000, 1),
          },
        },
      );
      final List<CircleTransfer> x = c.settleUp('2026-10-01');
      // 100 zł over three: the first pays a grosz more.
      expect(x.fold<int>(0, (int s, CircleTransfer t) => s + t.cents), 6666);
      expect(x.every((CircleTransfer t) => t.to == 'a'), isTrue);
      expect(c.settleUp('2026-10-08'), isEmpty);
    },
  );

  test('the small chat of a dinner: every member gets it, unread counts, '
      'strangers stay out', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle();
    final DateTime day = DateTime(2026, 10, 1, 19);
    w.advance(1);
    expect(
      await w.bob.circles.sendChat(c.id, day, '  Spóźnię się 10 min '),
      isTrue,
    );
    expect(await w.bob.circles.sendChat(c.id, day, '   '), isFalse);
    for (final _Host h in <_Host>[w.ania, w.cela, w.dina]) {
      final List<MeetThreadMessage> thread = h.circles.thread(c.id, day);
      expect(thread.single.text, 'Spóźnię się 10 min', reason: h.name);
      expect(thread.single.from, w.bob.address);
      expect(h.circles.unread(c.id, day), 1);
      expect(h.titles, contains('b2 · Czwartki'));
    }
    expect(w.bob.circles.unread(c.id, day), 0);
    expect(w.bob.circles.thread(c.id, day).single.mine, isTrue);
    await w.cela.circles.markRead(c.id, day);
    expect(w.cela.circles.unread(c.id, day), 0);
    // Another dinner has its own chat.
    expect(w.cela.circles.thread(c.id, DateTime(2026, 10, 8, 19)), isEmpty);
    // Someone outside the circle cannot write in it.
    await w.edek.send(w.ania.address, <String, dynamic>{
      'type': CircleTypes.circle,
      'k': 'chat',
      'id': c.id,
      'd': '2026-10-01',
      'm': 'obcy1',
      'x': 'Hej',
      't': w.edek.clock,
    });
    expect(w.ania.circles.thread(c.id, day), hasLength(1));
    // The chat is kept on disk.
    final CircleService again = CircleService(
      host: w.ania,
      disk: w.ania.disk,
      now: () => w.ania.clock,
    );
    await again.load();
    expect(again.thread(c.id, day).single.text, 'Spóźnię się 10 min');
    expect(again.unread(c.id, day), 1);
  });

  test('everything new survives JSON', () async {
    final _World w = _World();
    final DinnerCircle c = await w.circle(join: <_Host>[w.bob]);
    final DateTime day = DateTime(2026, 10, 1, 19);
    await w.bob.circles.setMyDiets(c.id, <CircleDiet>{CircleDiet.vegan});
    await w.bob.circles.rsvp(c.id, day, CircleAttendance.maybe);
    await w.bob.circles.setSpent(c.id, day, 1234);
    await w.bob.circles.rate(c.id, day, CircleHow.meh);
    final DinnerCircle had = w.ania.circles.circle(c.id)!;
    final DinnerCircle back = DinnerCircle.fromJson(
      jsonDecode(jsonEncode(had.toJson())),
    )!;
    expect(jsonEncode(back.toJson()), jsonEncode(had.toJson()));
    expect(back.invited.keys, contains(w.cela.address));
    expect(back.diets[w.bob.address], <CircleDiet>{CircleDiet.vegan});
    expect(
      back.attendanceOf(w.bob.address, '2026-10-01'),
      CircleAttendance.maybe,
    );
    expect(back.spent['2026-10-01']![w.bob.address]!.value, 1234);
    expect(back.how['2026-10-01']![w.bob.address]!.value, CircleHow.meh);
    // Nonsense in the answers is dropped.
    final Map<String, dynamic> bad = had.toJson()
      ..['rsvp'] = <String, dynamic>{
        'nie-data': <String, dynamic>{
          'x': <Object>['y', 1],
        },
        '2026-10-01': <String, dynamic>{
          'x': <Object>['?', 1],
          'y': 'y',
        },
      };
    expect(DinnerCircle.fromJson(bad)!.rsvp['2026-10-01'], isEmpty);
    expect(DinnerCircle.fromJson(bad)!.rsvp.containsKey('nie-data'), isFalse);
  });
}
