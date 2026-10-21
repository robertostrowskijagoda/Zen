import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  int clock = 1000000;
}

/// One phone: friend lists and the contact economy, frames delivered at
/// once, friend requests that cross become a friendship.
final class _Phone implements MeetHost, EventHost, IntroFriending {
  _Phone(this.net, this.name, String hex) : address = addr(hex) {
    net.phones[address] = this;
    meet = MeetService(host: this, store: MeetStore(disk), now: () => net.clock)
      ..friendNames = () => <String, String>{
        for (final String f in friendList) f: net.phones[f]?.name ?? '?',
      };
    intro = IntroService(
      host: this,
      disk: disk,
      meet: () => meet,
      friending: this,
      now: () => net.clock,
    );
  }

  final _Net net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final List<String> friendList = <String>[];
  late final MeetService meet;
  late final IntroService intro;
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<String> requested = <String>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add((to, payload));
    final _Phone? other = net.phones[PeerShareCodec.normalizeAddress(to)];
    if (other == null) {
      return;
    }
    final SignalTransportFrame f = SignalTransportFrame(
      from: address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    await other.meet.handle(f);
    await other.intro.handle(f);
  }

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) =>
      friendList.contains(PeerShareCodec.normalizeAddress(a));

  @override
  bool isSelf(String a) => PeerShareCodec.addressesEqual(a, address);

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) =>
      net.phones[PeerShareCodec.normalizeAddress(a)]?.name ?? 'Ktoś';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  @override
  Future<void> dismissNotification(String slotKey) async {}

  @override
  bool isBlocked(String a) => false;

  @override
  Future<void> befriend(
    String address, {
    required String name,
    required String note,
  }) async {
    requested.add(address);
    final _Phone? other = net.phones[address];
    if (other != null && other.requested.contains(this.address)) {
      _befriend(this, other);
    }
  }
}

void _befriend(_Phone a, _Phone b) {
  if (!a.friendList.contains(b.address)) {
    a.friendList.add(b.address);
  }
  if (!b.friendList.contains(a.address)) {
    b.friendList.add(a.address);
  }
}

/// Ania knows Bartek; Bartek knows Celina.
Future<({_Net net, _Phone ania, _Phone bartek, _Phone celina})> _world() async {
  final _Net net = _Net();
  final _Phone ania = _Phone(net, 'Ania', 'a1');
  final _Phone bartek = _Phone(net, 'Bartek', 'b2');
  final _Phone celina = _Phone(net, 'Celina', 'c3');
  _befriend(ania, bartek);
  _befriend(bartek, celina);
  for (final _Phone p in <_Phone>[ania, bartek, celina]) {
    await LedgerIdentity.loadOrCreate(p.disk);
  }
  return (net: net, ania: ania, bartek: bartek, celina: celina);
}

void main() {
  test('a friend request through a mutual friend: passed on by their phone '
      'by itself, accepted, both become friends', () async {
    final (net: _, :ania, :bartek, :celina) = await _world();
    final IntroCase? c = await ania.intro.askFriend(
      target: celina.address,
      targetName: 'Celina',
      middle: bartek.address,
      note: 'Gramy razem w kosza',
    );
    expect(c, isNotNull);
    expect(c!.kind, IntroKind.friend);
    expect(bartek.intro.needsMe, isEmpty, reason: 'no decision for Bartek');
    expect(bartek.shown, isEmpty);
    final IntroCase atCelina = celina.intro.needsMe.single;
    expect(atCelina.kind, IntroKind.friend);
    expect(atCelina.asker, ania.address);
    expect(atCelina.askerName, 'Ania');
    expect(atCelina.middle, bartek.address);
    expect(atCelina.text, 'Gramy razem w kosza');
    expect(celina.shown.last.title, 'Ania chce dodać Cię do znajomych');
    expect(ania.intro.caseOf(c.id)!.status, IntroStatus.forwarded);
    expect(ania.shown, isEmpty, reason: 'nothing to tell while it waits');
    // Asking again is the same request.
    expect(
      (await ania.intro.askFriend(
        target: celina.address,
        targetName: 'Celina',
        middle: bartek.address,
      ))!.id,
      c.id,
    );

    expect(await celina.intro.accept(atCelina.id), isTrue);
    expect(ania.isFriend(celina.address), isTrue);
    expect(celina.isFriend(ania.address), isTrue);
    expect(ania.intro.caseOf(c.id)!.status, IntroStatus.accepted);
    expect(ania.shown.last.title, 'Zaproszenie przyjęte: Celina');
    // Bartek sees later what went through him.
    expect(bartek.intro.handled.single.kind, IntroKind.friend);
    expect(bartek.intro.handled.single.status, IntroStatus.accepted);
  });

  test('refused: the asker is not told; a middle friend who hides the list '
      'passes nothing', () async {
    final (net: _, :ania, :bartek, :celina) = await _world();
    final IntroCase? c = await ania.intro.askFriend(
      target: celina.address,
      targetName: 'Celina',
      middle: bartek.address,
    );
    expect(await celina.intro.refuse(celina.intro.needsMe.single.id), isTrue);
    expect(ania.intro.caseOf(c!.id)!.status, IntroStatus.forwarded);
    expect(ania.requested, isEmpty);
    expect(ania.isFriend(celina.address), isFalse);

    final (net: _, ania: ania2, bartek: bartek2, celina: celina2) =
        await _world();
    await bartek2.meet.setFriendListAudience(FriendListAudience.nobody);
    final IntroCase? no = await ania2.intro.askFriend(
      target: celina2.address,
      targetName: 'Celina',
      middle: bartek2.address,
    );
    expect(ania2.intro.caseOf(no!.id)!.status, IntroStatus.declined);
    expect(celina2.intro.needsMe, isEmpty);
    expect(ania2.shown.last.title, 'Zaproszenie nie poszło');
  });

  test('limits: the sender\'s week and the middle friend\'s week', () async {
    final (net: _, :ania, :bartek, celina: _) = await _world();
    final List<String> people = <String>[
      for (int i = 0; i < 12; i++) addr('d$i'),
    ];
    bartek.friendList.addAll(people);
    final List<IntroCase?> cases = <IntroCase?>[
      for (final String p in people)
        await ania.intro.askFriend(
          target: p,
          targetName: 'X',
          middle: bartek.address,
        ),
    ];
    expect(
      cases.take(kFriendAsksPerWeek).every((IntroCase? c) => c != null),
      isTrue,
    );
    expect(cases.skip(kFriendAsksPerWeek), everyElement(isNull));
    expect(ania.intro.friendAsksLeft(), 0);
    final List<IntroStatus> statuses = <IntroStatus>[
      for (final IntroCase? c in cases.take(kFriendAsksPerWeek))
        ania.intro.caseOf(c!.id)!.status,
    ];
    expect(
      statuses.take(kFriendRelaysPerSenderWeek),
      everyElement(IntroStatus.forwarded),
    );
    expect(
      statuses.skip(kFriendRelaysPerSenderWeek),
      everyElement(IntroStatus.declined),
      reason: 'Bartek passes on 5 a week from one friend',
    );
    // A week later the sender may ask again.
    ania.net.clock += 8 * 24 * 3600 * 1000;
    expect(ania.intro.friendAsksLeft(), kFriendAsksPerWeek);
  });

  test('with no friend in between: a direct friend request, counted the '
      'same', () async {
    final (net: _, :ania, bartek: _, :celina) = await _world();
    final int left = ania.intro.friendAsksLeft();
    final IntroCase? c = await ania.intro.askFriend(
      target: celina.address,
      targetName: 'Celina',
    );
    expect(c!.middle, isEmpty);
    expect(c.status, IntroStatus.forwarded);
    expect(ania.requested, <String>[celina.address]);
    expect(ania.intro.friendAsksLeft(), left - 1);
    expect(ania.intro.friendAskTo(celina.address)!.id, c.id);
    // Not to friends, not to oneself.
    expect(
      await ania.intro.askFriend(target: ania.address, targetName: 'Ja'),
      isNull,
    );
    expect(
      await celina.intro.askFriend(target: ania.address, targetName: 'Ania'),
      isNotNull,
    );
    expect(ania.isFriend(celina.address), isTrue, reason: 'requests crossed');
    // Kept in the store.
    expect(
      IntroCase.fromJson(jsonDecode(jsonEncode(c.toJson())))!.kind,
      IntroKind.friend,
    );
  });
}
