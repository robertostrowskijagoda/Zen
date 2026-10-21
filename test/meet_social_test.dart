import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/meet/table/table_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

final class _Host implements EventHost {
  _Host(this.net, this.name, List<String> friends)
    : address = addr(name),
      friendList = friends.map(addr).toList() {
    net[address] = this;
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    events = EventService(host: this, disk: disk, now: () => clock);
    ask = AskService(host: this, disk: disk, now: () => clock);
    circles = CircleService(host: this, disk: disk, now: () => clock);
    table = TableService(
      host: this,
      events: events,
      disk: disk,
      friendsOf: (String f) => lists[f] ?? const <String, String>{},
      now: () => clock,
    );
  }

  final Map<String, _Host> net;
  final String name;
  final String address;
  final List<String> friendList;
  late final EventService events;
  late final AskService ask;
  late final CircleService circles;
  late final TableService table;
  final Map<String, Map<String, String>> lists =
      <String, Map<String, String>>{};
  int clock = 1000;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Host? other = net[to];
    if (other == null) {
      return;
    }
    final SignalTransportFrame f = SignalTransportFrame(
      from: address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    await other.events.handle(f);
    await other.ask.handle(f);
    await other.circles.handle(f);
    await other.table.handle(f);
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

/// [from]'s answer to question [questionId], signed with [id] the way the
/// app does ([askAnswerSignedBytes]).
Future<Map<String, dynamic>> _signedAnswer(
  LedgerIdentity id,
  _Host from,
  String questionId,
  String text,
) async {
  final List<int> sig = await id.deviceKey.sign(
    askAnswerSignedBytes(
      id: questionId,
      answerer: from.address,
      name: from.name,
      text: text,
    ),
  );
  return <String, dynamic>{
    'type': AskTypes.answer,
    'id': questionId,
    't': text,
    'p': <String>[from.name],
    'sg': <String, dynamic>{
      'd': id.certificate.toJson(),
      's': b64(sig),
      'a': from.address,
    },
  };
}

void main() {
  test('Zapytaj sieć: answers come back the same way, with the path', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host kasia = _Host(net, 'k1', <String>['b2']);
    final _Host bartek = _Host(net, 'b2', <String>['k1', 'c3']);
    final _Host celina = _Host(net, 'c3', <String>['b2']);
    await LedgerIdentity.loadOrCreate(celina.ask.disk);
    await LedgerIdentity.loadOrCreate(bartek.ask.disk);

    final Question q = (await kasia.ask.ask('Dobry dentysta w Gdańsku?'))!;
    expect(bartek.ask.fromOthers.single.text, q.text);
    expect(celina.ask.fromOthers, isEmpty, reason: 'only by hand');

    await bartek.ask.forward(q.id, <String>[celina.address]);
    final Question atCelina = celina.ask.fromOthers.single;
    expect(atCelina.askerName, 'k1');
    expect(atCelina.via, <String>['b2']);
    expect(atCelina.hops, 0);
    expect(
      await celina.ask.forward(q.id, <String>[]),
      isFalse,
      reason: 'two steps at most',
    );

    await celina.ask.answer(q.id, 'dr Nowak, polecam');
    await bartek.ask.answer(q.id, 'Ja chodzę do Kowalskiej');
    final Question mine = kasia.ask.mine.single;
    expect(
      mine.answers.map((AskAnswer a) => answerSource(a.path)).toList(),
      <String>['c3, znajomy(-a) b2', 'b2'],
    );

    // No limit for the asker; a flooding friend is cut off by each
    // receiving phone on its own.
    for (int i = 0; i < 30; i++) {
      await kasia.ask.ask('pytanie $i');
    }
    expect(kasia.ask.mine.length, 31);
    expect(
      bartek.ask.fromOthers.length,
      kQuestionsFromFriendPerDay,
      reason: 'Kasia is his only friend asking',
    );
  });

  test('Stół na sześć: wishes reach friends of friends, the host gets '
      'guests who do not know each other', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host host = _Host(net, 'h0', <String>['a1', 'b2']);
    final _Host a = _Host(net, 'a1', <String>['h0', 'x1', 'x2']);
    final _Host b = _Host(net, 'b2', <String>['h0', 'y1']);
    final _Host x1 = _Host(net, 'x1', <String>['a1', 'x2']);
    final _Host x2 = _Host(net, 'x2', <String>['a1', 'x1']);
    final _Host y1 = _Host(net, 'y1', <String>['b2']);
    // Clocks of today: an invitation for a dinner more than a year away
    // would not be taken in.
    for (final _Host h in net.values) {
      h.clock = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    }

    final DateTime thursday = DateTime(2026, 10, 15, 19);
    for (final _Host h in <_Host>[a, x1, x2, y1]) {
      await h.table.setWish(city: 'Gdańsk', days: <int>{DateTime.thursday});
    }
    await b.table.setWish(city: 'Sopot');
    // Friends' wishes come with their address; friends of friends' without,
    // through the friend who passed them on.
    expect(host.table.wishes, hasLength(5));
    expect(
      host.table.wishes
          .where((TableWish w) => w.address.isNotEmpty)
          .map((TableWish w) => w.address)
          .toSet(),
      <String>{a.address, b.address},
    );
    final TableWish x1Wish = host.table.wishes.firstWhere(
      (TableWish w) => w.id == x1.table.myWish!.id,
    );
    expect(x1Wish.via, a.address);
    expect(x1Wish.address, isEmpty);

    host.lists[a.address] = <String, String>{
      x1.address: 'x1',
      x2.address: 'x2',
    };
    final List<TableWish> picked = host.table.pickGuests(
      ' gdańsk ',
      thursday,
      count: 2,
    );
    expect(picked, hasLength(2));
    final Set<String> vias = picked
        .map((TableWish w) => w.via ?? w.address)
        .toSet();
    expect(vias, hasLength(2), reason: 'two different friends connect them');

    final MeetEvent e = await host.table.setTable(
      city: 'Gdańsk',
      when: thursday,
      guests: host.table.pickGuests('Gdańsk', thursday),
    );
    expect(e.capacity, 6);
    // Y1 is invited through b2, says "Chcę", the host lets them in.
    final TableInvite toY1 = y1.table.invitations.single;
    expect(toY1.via, b.address);
    expect(await y1.table.answer(toY1.id, true), isTrue);
    expect(await host.table.accept(toY1.id), isTrue);
    expect(
      y1.events.event(e.id),
      isNotNull,
      reason: 'the host is no friend, but y1 said "Chcę"',
    );

    await a.table.setWish();
    expect(
      host.table.wishes.where((TableWish w) => w.address == a.address),
      isEmpty,
    );
  });

  test('Kółko obiadowe: rotation, items, preferences and swapping', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2', 'c3']);
    final _Host bob = _Host(net, 'b2', <String>['a1', 'c3']);
    final _Host cela = _Host(net, 'c3', <String>['a1', 'b2']);
    final _Host dina = _Host(net, 'd4', <String>['a1', 'b2', 'c3']);
    ania.clock = bob.clock = cela.clock = dina.clock = DateTime(
      2026,
      10,
      1,
    ).millisecondsSinceEpoch;

    final DinnerCircle c = await ania.circles.create(
      name: 'Czwartki',
      friends: <String>[bob.address, cela.address, dina.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime(2026, 10, 1),
    );
    // Nobody is in it before saying "Dołączam".
    expect(bob.circles.circles, isEmpty);
    expect(bob.circles.invitations.single.id, c.id);
    for (final _Host h in <_Host>[bob, cela, dina]) {
      await h.circles.answerInvite(c.id, true);
    }
    final List<(DateTime, CircleMember)> s = bob.circles
        .circle(c.id)!
        .schedule(bob.clock, count: 4);
    expect(s.map(((DateTime, CircleMember) x) => x.$2.name).toList(), <String>[
      'a1',
      'b2',
      'c3',
      'd4',
    ]);
    expect(s[1].$1, DateTime(2026, 10, 8, 19));

    await cela.circles.setMyPrefs(c.id, 'bez orzechów');
    expect(ania.circles.circle(c.id)!.prefs[cela.address], 'bez orzechów');

    bob.clock += 1;
    await bob.circles.addItem(c.id, s.first.$1, 'deser');
    cela.clock += 2;
    await cela.circles.claimItem(c.id, s.first.$1, 'deser');
    expect(
      ania.circles.circle(c.id)!.items[DinnerCircle.dayKey(
        s.first.$1,
      )]!['deser'],
      cela.address,
    );

    ania.clock += 3;
    await ania.circles.askSwap(c.id, bob.address);
    expect(bob.circles.swapRequests[c.id], ania.address);
    bob.clock += 4;
    await bob.circles.acceptSwap(c.id);
    expect(
      cela.circles
          .circle(c.id)!
          .members
          .map((CircleMember m) => m.name)
          .toList(),
      <String>['b2', 'a1', 'c3', 'd4'],
    );

    // Someone outside cannot change it.
    final _Host eve = _Host(net, 'e9', <String>['a1']);
    final Map<String, dynamic> fake = ania.circles.circle(c.id)!.toJson()
      ..['name'] = 'Przejęte'
      ..['upd'] = 1 << 50;
    await eve.send(ania.address, <String, dynamic>{
      'type': CircleTypes.circle,
      'c': fake,
    });
    expect(ania.circles.circle(c.id)!.name, 'Czwartki');
  });

  test('the graph puts friends on rings by level and friends of friends '
      'outside, linked to whoever knows them', () {
    final String a = addr('a1');
    final String b = addr('b2');
    final String x = addr('x9');
    final SocialHubState social = SocialHubState.empty().copyWith(
      friends: <String, FriendProfile>{
        a: FriendProfile(
          address: a,
          displayName: 'Ania',
          status: FriendRelationshipStatus.accepted,
        ),
        b: FriendProfile(
          address: b,
          displayName: 'Bob',
          status: FriendRelationshipStatus.accepted,
        ),
      },
    );
    final MeetBook book = MeetBook()
      ..friendLists[a] = <String, String>{x: 'Xawery', b: 'Bob'}
      ..friendLists[b] = <String, String>{x: 'Xawery'};
    final List<GraphNode> nodes = buildGraph(
      social: social,
      book: book,
      levelOf: (String s) => s == a ? FriendLevel.close : FriendLevel.weak,
    );
    expect(nodes.firstWhere((GraphNode n) => n.address == a).ring, 1);
    expect(nodes.firstWhere((GraphNode n) => n.address == b).ring, 3);
    final GraphNode far = nodes.firstWhere((GraphNode n) => n.address == x);
    expect(far.ring, 4);
    expect(far.via.toSet(), <String>{a, b});
    expect(
      nodes.where((GraphNode n) => n.address == b),
      hasLength(1),
      reason: 'a friend is not also a friend of a friend',
    );
  });

  test('Zapytaj sieć: answers only from the friends the question went to, '
      'cut to size and not without end', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host kasia = _Host(net, 'k1', <String>['b2']);
    final _Host bartek = _Host(net, 'b2', <String>['k1']);
    final LedgerIdentity id = await LedgerIdentity.loadOrCreate(
      bartek.ask.disk,
    );
    final Question q = (await kasia.ask.ask('Dobry dentysta w Gdańsku?'))!;
    // A friend added later never got the question.
    final _Host nowy = _Host(net, 'n9', <String>['k1']);
    kasia.friendList.add(nowy.address);
    final LedgerIdentity nowyId = await LedgerIdentity.loadOrCreate(
      nowy.ask.disk,
    );
    await nowy.send(
      kasia.address,
      await _signedAnswer(nowyId, nowy, q.id, 'reklama'),
    );
    expect(kasia.ask.mine.single.answers, isEmpty);

    // Too long: dropped, even signed.
    await bartek.send(
      kasia.address,
      await _signedAnswer(id, bartek, q.id, 'd' * 5000),
    );
    expect(kasia.ask.mine.single.answers, isEmpty);
    await bartek.send(
      kasia.address,
      await _signedAnswer(id, bartek, q.id, 'd' * kAnswerMaxChars),
    );
    final AskAnswer got = kasia.ask.mine.single.answers.single;
    expect(got.text, hasLength(kAnswerMaxChars));
    for (int i = 0; i < kAnswersFromFriendPerQuestion + 10; i++) {
      await bartek.send(
        kasia.address,
        await _signedAnswer(id, bartek, q.id, 'odpowiedź $i'),
      );
    }
    expect(
      kasia.ask.mine.single.answers,
      hasLength(kAnswersFromFriendPerQuestion),
    );
    // Who it came from survives a restart.
    final AskService again = AskService(
      host: kasia,
      disk: kasia.ask.disk,
      now: () => kasia.clock,
    );
    await again.load();
    expect(again.mine.single.answers.first.from, bartek.address);
    expect(again.mine.single.sentTo, contains(bartek.address));
  });

  test('Stół na sześć and kółka: a date far ahead does not freeze a wish or '
      'a circle against later changes', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2', 'c3']);
    final _Host bob = _Host(net, 'b2', <String>['a1', 'c3']);
    final _Host cela = _Host(net, 'c3', <String>['a1', 'b2']);
    final _Host dina = _Host(net, 'd4', <String>['a1', 'b2', 'c3']);
    for (final _Host h in net.values) {
      h.clock = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    }

    // Bob's (broken) app dates his wish a century ahead.
    await bob.table.setWish(city: 'Gdańsk');
    await bob.send(ania.address, <String, dynamic>{
      'type': kTableWishType,
      'w': TableWish(
        id: bob.table.myWish!.id,
        address: bob.address,
        name: 'b2',
        city: 'Gdańsk',
        days: const <int>{},
        at: bob.clock + 100 * 365 * 24 * 3600 * 1000,
      ).toJson(),
      'hops': 0,
    });
    expect(
      ania.table.wishes.single.at,
      lessThanOrEqualTo(ania.clock + kTableClockSkew.inMilliseconds),
    );
    // A little later his own "off" still counts, and the wish expires.
    bob.clock = ania.clock += kTableClockSkew.inMilliseconds + 1;
    await bob.table.setWish();
    expect(ania.table.wishes, isEmpty);

    final DinnerCircle c = await ania.circles.create(
      name: 'Czwartki',
      friends: <String>[bob.address, cela.address, dina.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime(2026, 10, 1),
    );
    for (final _Host h in <_Host>[bob, cela, dina]) {
      await h.circles.answerInvite(c.id, true);
    }
    // A member's copy dated far ahead is taken as made now…
    final Map<String, dynamic> ahead = c.toJson()
      ..['name'] = 'Zamrożone'
      ..['upd'] = 1 << 50;
    await bob.send(cela.address, <String, dynamic>{
      'type': CircleTypes.circle,
      'c': ahead,
    });
    expect(cela.circles.circle(c.id)!.name, 'Zamrożone');
    expect(
      cela.circles.circle(c.id)!.updatedAt,
      lessThanOrEqualTo(cela.clock + kCircleClockSkew.inMilliseconds),
    );
    // …so the others' later changes still go through.
    for (final _Host h in net.values) {
      h.clock += kCircleClockSkew.inMilliseconds + 1;
    }
    await ania.circles.setMyPrefs(c.id, 'bez glutenu');
    expect(cela.circles.circle(c.id)!.prefs[ania.address], 'bez glutenu');
  });

  group('Zapytaj sieć: answers are signed by the answerer', () {
    test('a signed answer comes back through a middle friend and checks '
        'out; without keys nothing is sent', () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host kasia = _Host(net, 'k1', <String>['b2']);
      final _Host bartek = _Host(net, 'b2', <String>['k1', 'c3']);
      final _Host celina = _Host(net, 'c3', <String>['b2']);
      await LedgerIdentity.loadOrCreate(celina.ask.disk);
      await LedgerIdentity.loadOrCreate(bartek.ask.disk);

      final Question q = (await kasia.ask.ask('Dobry dentysta?'))!;
      await bartek.ask.forward(q.id, <String>[celina.address]);
      await celina.ask.answer(q.id, 'dr Nowak', pyramidKey: 'kk');
      await bartek.ask.answer(q.id, 'Kowalska');
      final List<AskAnswer> got = kasia.ask.mine.single.answers;
      expect(got, hasLength(2));
      expect(got.first.path, <String>['c3', 'b2']);
      expect(got.first.pyramidKey, 'kk');

      // It survives a restart and a tip.
      final AskAnswer back = AskAnswer.fromJson(
        jsonDecode(jsonEncode(got.first.withTip(100).toJson())),
      )!;
      expect(back.tipped, 100);
      expect(back.text, 'dr Nowak');

      // Nobody signs without keys: such an answer is not sent.
      final _Host ola = _Host(net, 'o5', <String>['k1']);
      kasia.friendList.add(ola.address);
      final Question q2 = (await kasia.ask.ask('Hydraulik?'))!;
      await ola.ask.answer(q2.id, 'Pan Zenek');
      expect(
        kasia.ask.mine.firstWhere((Question x) => x.id == q2.id).answers,
        isEmpty,
      );

      // An answer that arrives without a signature is dropped.
      await ola.send(kasia.address, <String, dynamic>{
        'type': AskTypes.answer,
        'id': q2.id,
        't': 'Pan Zenek',
        'p': <String>['o5'],
      });
      expect(
        kasia.ask.mine.firstWhere((Question x) => x.id == q2.id).answers,
        isEmpty,
      );
    });

    test('changed words, name or tip key, or a signature for another '
        'question, are dropped', () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host kasia = _Host(net, 'k1', <String>['b2']);
      final _Host bartek = _Host(net, 'b2', <String>['k1']);
      final LedgerIdentity id = await LedgerIdentity.loadOrCreate(
        bartek.ask.disk,
      );
      final Question q = (await kasia.ask.ask('Dobry dentysta?'))!;
      final Question other = (await kasia.ask.ask('Hydraulik?'))!;

      Future<Map<String, dynamic>> frame({
        String? signId,
        String? signedText,
        String? signedName,
        String? signedAddress,
        String text = 'dr Nowak',
        String name = 'b2',
        String? key,
      }) async {
        final String who = signedAddress ?? bartek.address;
        final List<int> sig = await id.deviceKey.sign(
          askAnswerSignedBytes(
            id: signId ?? q.id,
            answerer: who,
            name: signedName ?? name,
            text: signedText ?? text,
            pyramidKey: key,
          ),
        );
        return <String, dynamic>{
          'type': AskTypes.answer,
          'id': q.id,
          't': text,
          'p': <String>[name],
          'k': ?key,
          'sg': <String, dynamic>{
            'd': id.certificate.toJson(),
            's': b64(sig),
            'a': who,
          },
        };
      }

      // The genuine one.
      await bartek.send(kasia.address, await frame());
      expect(kasia.ask.question(q.id)!.answers, hasLength(1));

      Future<void> expectDropped(Map<String, dynamic> f) async {
        final int before = kasia.ask.question(q.id)!.answers.length;
        await bartek.send(kasia.address, f);
        expect(kasia.ask.question(q.id)!.answers, hasLength(before));
      }

      // A relay (or anyone) changes the words, the name, the tip key, or
      // replays a signature made for another question.
      await expectDropped(await frame(signedText: 'dr Nowak, ale drogo'));
      await expectDropped(await frame(signedName: 'Inna osoba'));
      await expectDropped((await frame())..['k'] = 'zlodziej');
      await expectDropped(await frame(signId: other.id));
      await expectDropped((await frame())..['sg'] = 'śmieci');
      await expectDropped(
        (await frame())
          ..['sg'] = <String, dynamic>{'s': 'x', 'a': bartek.address},
      );

      // Sound, but under another address than the friend who answered.
      await expectDropped(await frame(signedAddress: addr('f7'), text: 'inna'));
    });
  });
}
