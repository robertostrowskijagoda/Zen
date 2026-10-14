import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart'
    show kReliablePayloadTypes;
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

const int _day = 24 * 3600 * 1000;

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  int clock = 1000000;
}

/// One phone: statuses and friend lists ([MeetService]) and the contact
/// economy ([IntroService]) on one store, frames delivered at once.
final class _Phone implements MeetHost, EventHost, IntroFriending {
  _Phone(this.net, this.name, String hex, {bool background = false})
    : address = addr(hex) {
    net.phones[address] = this;
    meet = MeetService(host: this, store: MeetStore(disk), now: () => net.clock)
      ..friendNames = () => <String, String>{
        for (final String f in friendList) f: net.phones[f]?.name ?? '?',
      };
    intro = background ? openBackground() : openApp();
  }

  final _Net net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final List<String> friendList = <String>[];
  final Set<String> blocked = <String>{};
  late final MeetService meet;
  late IntroService intro;
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  /// Friend requests this phone made, and their notes.
  final List<String> requested = <String>[];
  final List<String> notes = <String>[];

  /// The app's service on this phone's store (friend requests can be made).
  IntroService openApp() => IntroService(
    host: this,
    disk: disk,
    meet: () => meet,
    friending: this,
    now: () => net.clock,
  );

  /// The background service's (no friend requests from there).
  IntroService openBackground() => IntroService(
    host: this,
    disk: disk,
    meet: () => meet,
    now: () => net.clock,
  );

  List<Object?> get sentTypes => <Object?>[
    for (final (String, Map<String, dynamic>) s in sent) s.$2['type'],
  ];

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
  bool isBlocked(String a) =>
      blocked.contains(PeerShareCodec.normalizeAddress(a));

  @override
  Future<void> befriend(
    String address, {
    required String name,
    required String note,
  }) async {
    requested.add(address);
    notes.add(note);
    final _Phone? other = net.phones[address];
    // Two requests that cross become a friendship (as in the app).
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

/// Ania knows Bartek, Bartek knows Celina, Darek and Ewa.
({
  _Net net,
  _Phone ania,
  _Phone bartek,
  _Phone celina,
  _Phone darek,
  _Phone ewa,
})
_world({bool aniaInBackground = false}) {
  final _Net net = _Net();
  final _Phone ania = _Phone(net, 'Ania', 'a1', background: aniaInBackground);
  final _Phone bartek = _Phone(net, 'Bartek', 'b2');
  final _Phone celina = _Phone(net, 'Celina', 'c3');
  final _Phone darek = _Phone(net, 'Darek', 'd4');
  final _Phone ewa = _Phone(net, 'Ewa', 'e5');
  _befriend(ania, bartek);
  _befriend(bartek, celina);
  _befriend(bartek, darek);
  _befriend(bartek, ewa);
  return (
    net: net,
    ania: ania,
    bartek: bartek,
    celina: celina,
    darek: darek,
    ewa: ewa,
  );
}

void main() {
  test('who sees the friend list: on request, agreed, taken back', () async {
    final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = _world();
    await bartek.meet.setFriendListAudience(FriendListAudience.onRequest);
    await bartek.meet.shareFriendList(bartek.meet.friendNames!(), force: true);
    expect(ania.meet.book.friendsOf(bartek.address), isEmpty);
    // What Ania holds matches Bartek's hello: nothing is asked again.
    await ania.meet.onHello(bartek.address, bartek.meet.helloFor(ania.address));
    expect(ania.sentTypes, isNot(contains(MeetTypes.request)));

    final IntroCase? asked = await ania.intro.askList(bartek.address);
    expect(asked, isNotNull);
    expect(bartek.intro.needsMe.single.kind, IntroKind.list);
    expect(bartek.shown.last.title, contains('Ania'));
    // Asking again while waiting is the same request.
    expect((await ania.intro.askList(bartek.address))!.id, asked!.id);
    expect(bartek.intro.needsMe, hasLength(1));

    expect(
      await bartek.intro.approveList(bartek.intro.needsMe.single.id),
      isTrue,
    );
    expect(ania.intro.caseOf(asked.id)!.status, IntroStatus.accepted);
    expect(
      ania.meet.book.friendsOf(bartek.address).keys,
      contains(celina.address),
    );
    expect(
      celina.meet.book.friendsOf(bartek.address),
      isEmpty,
      reason: 'Celina did not ask',
    );
    await ania.meet.onHello(bartek.address, bartek.meet.helloFor(ania.address));
    expect(ania.sentTypes, isNot(contains(MeetTypes.request)));

    // Taken back: Ania forgets the list.
    await bartek.meet.allowFriendList(ania.address, allow: false);
    expect(ania.meet.book.friendsOf(bartek.address), isEmpty);

    // Nobody: refused without asking Bartek.
    await bartek.meet.setFriendListAudience(FriendListAudience.nobody);
    final IntroCase? no = await ania.intro.askList(bartek.address);
    expect(ania.intro.caseOf(no!.id)!.status, IntroStatus.declined);
    expect(bartek.intro.needsMe, isEmpty);

    // Everyone: the list comes at once.
    await bartek.meet.setFriendListAudience(FriendListAudience.all);
    final IntroCase? yes = await ania.intro.askList(bartek.address);
    expect(ania.intro.caseOf(yes!.id)!.status, IntroStatus.accepted);
    expect(
      ania.meet.book.friendsOf(bartek.address).keys,
      contains(celina.address),
    );
  });

  test('the audience is kept', () {
    final String a = addr('a1');
    final MeetBook book = MeetBook()
      ..friendListAudience = FriendListAudience.onRequest
      ..friendListAllowed.add(a);
    final Map<String, dynamic> json =
        jsonDecode(jsonEncode(book.toJson())) as Map<String, dynamic>;
    expect(json['listAsk'], isTrue);
    expect(json.containsKey('noList'), isFalse);
    final MeetBook back = MeetBook.fromJson(json);
    expect(back.friendListAudience, FriendListAudience.onRequest);
    expect(back.showsFriendListTo(a), isTrue);
    expect(back.showsFriendListTo(addr('c3')), isFalse);
    expect(back.shareFriendList, isTrue);
    expect(
      MeetBook.fromJson(<String, dynamic>{
        'v': 1,
        'noList': true,
      }).friendListAudience,
      FriendListAudience.nobody,
    );
    expect(
      MeetBook.fromJson(<String, dynamic>{'v': 1}).shareFriendList,
      isTrue,
    );
  });

  test('an introduction: passed on with a note, accepted, both invite '
      'each other and become friends', () async {
    final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = _world();
    final IntroCase? c = await ania.intro.askIntro(
      middle: bartek.address,
      target: celina.address,
      targetName: 'Celina',
      note: 'Gramy w jednej drużynie',
    );
    expect(c, isNotNull);
    final IntroCase atBartek = bartek.intro.needsMe.single;
    expect(atBartek.role, IntroRole.middle);
    expect(atBartek.asker, ania.address);
    expect(atBartek.target, celina.address);
    expect(atBartek.text, 'Gramy w jednej drużynie');
    expect(bartek.shown.last.title, 'Ania prosi o przedstawienie');
    // Asking again while it is going is the same request.
    expect(
      (await ania.intro.askIntro(
        middle: bartek.address,
        target: celina.address,
        targetName: 'Celina',
      ))!.id,
      c!.id,
    );
    expect(bartek.intro.needsMe, hasLength(1));
    expect(celina.intro.needsMe, isEmpty, reason: 'Bartek decides first');

    expect(
      await bartek.intro.forward(atBartek.id, note: 'Fajna osoba'),
      isTrue,
    );
    expect(ania.intro.caseOf(c.id)!.status, IntroStatus.forwarded);
    final IntroCase atCelina = celina.intro.needsMe.single;
    expect(atCelina.role, IntroRole.target);
    expect(atCelina.asker, ania.address);
    expect(atCelina.askerName, 'Ania');
    expect(atCelina.middle, bartek.address);
    expect(atCelina.note, 'Fajna osoba');
    expect(atCelina.text, 'Gramy w jednej drużynie');
    expect(celina.shown.last.title, 'Bartek przedstawia Ci: Ania');

    expect(await celina.intro.accept(atCelina.id), isTrue);
    expect(celina.requested, <String>[ania.address]);
    expect(ania.requested, <String>[celina.address]);
    expect(ania.notes.single, 'Poznaliśmy się przez: Bartek');
    expect(ania.isFriend(celina.address), isTrue);
    expect(celina.isFriend(ania.address), isTrue);
    expect(ania.intro.caseOf(c.id)!.status, IntroStatus.accepted);
    expect(ania.intro.caseOf(c.id)!.befriendDue, isFalse);
    expect(bartek.intro.caseOf(c.id)!.status, IntroStatus.accepted);
    expect(celina.intro.needsMe, isEmpty);
    // Kept in this phone's store.
    expect(ania.disk.files.containsKey('meet/intros'), isTrue);
  });

  test('declined by the middle friend: the asker learns, the other never '
      'sees it', () async {
    final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = _world();
    final IntroCase? c = await ania.intro.askIntro(
      middle: bartek.address,
      target: celina.address,
      targetName: 'Celina',
    );
    expect(await bartek.intro.decline(bartek.intro.needsMe.single.id), isTrue);
    expect(ania.intro.caseOf(c!.id)!.status, IntroStatus.declined);
    expect(celina.intro.needsMe, isEmpty);
    expect(celina.sent, isEmpty);
    expect(ania.requested, isEmpty);
  });

  test(
    'declined by the one introduced: only the middle friend learns',
    () async {
      final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = _world();
      final IntroCase? c = await ania.intro.askIntro(
        middle: bartek.address,
        target: celina.address,
        targetName: 'Celina',
      );
      await bartek.intro.forward(bartek.intro.needsMe.single.id);
      expect(await celina.intro.refuse(celina.intro.needsMe.single.id), isTrue);
      expect(bartek.intro.caseOf(c!.id)!.status, IntroStatus.refused);
      expect(ania.intro.caseOf(c.id)!.status, IntroStatus.forwarded);
      expect(ania.requested, isEmpty);
      expect(celina.requested, isEmpty);
    },
  );

  test('only a friend of the middle friend can be introduced', () async {
    final (:net, :ania, :bartek, celina: _, darek: _, ewa: _) = _world();
    final _Phone obcy = _Phone(net, 'Obcy', 'f6');
    final IntroCase? c = await ania.intro.askIntro(
      middle: bartek.address,
      target: obcy.address,
      targetName: 'Obcy',
    );
    expect(ania.intro.caseOf(c!.id)!.status, IntroStatus.declined);
    expect(bartek.intro.needsMe, isEmpty);
    // Not through someone who is not a friend.
    expect(
      await ania.intro.askIntro(
        middle: obcy.address,
        target: bartek.address,
        targetName: 'Bartek',
      ),
      isNull,
    );
  });

  test('letters: passed on within limits, the recipient can only invite '
      'or ignore', () async {
    final (:net, :ania, :bartek, :celina, :darek, :ewa) = _world();
    final List<IntroCase> letters = <IntroCase>[];
    for (final _Phone to in <_Phone>[celina, darek, ewa]) {
      final IntroCase? c = await ania.intro.sendLetter(
        middle: bartek.address,
        target: to.address,
        targetName: to.name,
        text: 'Cześć, ${to.name}!',
      );
      expect(c, isNotNull);
      letters.add(c!);
      expect(ania.intro.caseOf(c.id)!.status, IntroStatus.forwarded);
      final IntroCase got = to.intro.needsMe.single;
      expect(got.kind, IntroKind.letter);
      expect(got.text, 'Cześć, ${to.name}!');
      expect(got.askerName, 'Ania');
    }
    expect(bartek.intro.needsMe, isEmpty, reason: 'letters pass by themselves');
    expect(bartek.intro.handled, hasLength(3));
    expect(ania.intro.lettersLeft(bartek.address), 0);
    expect(
      await ania.intro.sendLetter(
        middle: bartek.address,
        target: celina.address,
        targetName: 'Celina',
        text: 'Jeszcze raz',
      ),
      isNull,
    );

    // A modified app ignores its own limit: Bartek's phone stops it anyway.
    await ania.send(bartek.address, <String, dynamic>{
      'type': IntroTypes.ask,
      'id': 'zzzzzzzzzz01',
      'k': IntroKind.letter.name,
      'a': celina.address,
      't': 'Jeszcze raz',
    });
    expect(bartek.intro.caseOf('zzzzzzzzzz01'), isNull);
    expect(bartek.sent.last.$2['s'], 'no');

    // Darek invites Ania: they become friends.
    await darek.intro.accept(darek.intro.needsMe.single.id);
    expect(ania.isFriend(darek.address), isTrue);
    expect(ania.intro.caseOf(letters[1].id)!.status, IntroStatus.accepted);
    // Ewa ignores it: Ania is not told.
    await ewa.intro.refuse(ewa.intro.needsMe.single.id);
    expect(ania.intro.caseOf(letters[2].id)!.status, IntroStatus.forwarded);

    // A week later there are letters again.
    net.clock += 8 * _day;
    expect(ania.intro.lettersLeft(bartek.address), kLettersPerWeek);

    // Bartek stops passing letters on.
    await bartek.intro.setRelayLetters(false);
    final IntroCase? off = await ania.intro.sendLetter(
      middle: bartek.address,
      target: celina.address,
      targetName: 'Celina',
      text: 'Hej',
    );
    expect(ania.intro.caseOf(off!.id)!.status, IntroStatus.declined);
  });

  test(
    'only friends may send these frames; names and texts are cleaned',
    () async {
      final (:net, ania: _, :bartek, :celina, darek: _, ewa: _) = _world();
      final _Phone obcy = _Phone(net, 'Obcy', 'f6');
      // A stranger cannot pass anything on.
      await obcy.send(celina.address, <String, dynamic>{
        'type': IntroTypes.forward,
        'id': 'aaaaaaaaaa01',
        'k': IntroKind.letter.name,
        'a': obcy.address,
        'n': 'Obcy',
        't': 'Hej',
      });
      expect(celina.intro.needsMe, isEmpty);

      // A friend's frame: the name is one clean line, the letter cut.
      await bartek.send(celina.address, <String, dynamic>{
        'type': IntroTypes.forward,
        'id': 'aaaaaaaaaa02',
        'k': IntroKind.letter.name,
        'a': addr('f7'),
        'n': 'Ewa\u202e\n${'x' * 200}',
        't': 'a' * 5000,
      });
      final IntroCase got = celina.intro.needsMe.single;
      expect(got.askerName.length, lessThanOrEqualTo(60));
      expect(got.askerName, isNot(contains('\u202e')));
      expect(got.askerName, isNot(contains('\n')));
      expect(got.text.length, kLetterMaxChars);

      // Too big, a bad id, or a second one from the same person: dropped.
      await bartek.send(celina.address, <String, dynamic>{
        'type': IntroTypes.forward,
        'id': 'aaaaaaaaaa03',
        'k': IntroKind.letter.name,
        'a': addr('f8'),
        't': 'x' * 9000,
      });
      await bartek.send(celina.address, <String, dynamic>{
        'type': IntroTypes.forward,
        'id': 'BAD',
        'k': IntroKind.letter.name,
        'a': addr('f9'),
        't': 'Hej',
      });
      await bartek.send(celina.address, <String, dynamic>{
        'type': IntroTypes.forward,
        'id': 'aaaaaaaaaa04',
        'k': IntroKind.letter.name,
        'a': addr('f7'),
        't': 'Drugi list',
      });
      expect(celina.intro.needsMe, hasLength(1));

      // Someone Celina blocked never reaches her.
      celina.blocked.add(addr('fa'));
      await bartek.send(celina.address, <String, dynamic>{
        'type': IntroTypes.forward,
        'id': 'aaaaaaaaaa05',
        'k': IntroKind.intro.name,
        'a': addr('fa'),
        'n': 'Zablokowany',
      });
      expect(celina.intro.needsMe, hasLength(1));
    },
  );

  test('an answer that came while the app was away becomes a friend '
      'request when it opens', () async {
    final (net: _, :ania, :bartek, :celina, darek: _, ewa: _) = _world(
      aniaInBackground: true,
    );
    expect(MeetInbox.handles(IntroTypes.result), isTrue);
    // A friend who is offline gets them later.
    expect(kReliablePayloadTypes, containsAll(IntroTypes.all));
    final IntroCase? c = await ania.intro.askIntro(
      middle: bartek.address,
      target: celina.address,
      targetName: 'Celina',
    );
    await bartek.intro.forward(bartek.intro.needsMe.single.id);
    await celina.intro.accept(celina.intro.needsMe.single.id);
    expect(ania.requested, isEmpty, reason: 'no friend requests from there');
    expect(ania.intro.caseOf(c!.id)!.befriendDue, isTrue);

    // The app opens on the same store.
    ania.intro = ania.openApp();
    await ania.intro.load();
    await ania.intro.settle();
    expect(ania.requested, <String>[celina.address]);
    expect(ania.isFriend(celina.address), isTrue);
    expect(ania.intro.caseOf(c.id)!.befriendDue, isFalse);
  });
}
