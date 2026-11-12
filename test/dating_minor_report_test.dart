import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  final Map<String, Set<String>> friends = <String, Set<String>>{};
  int clock = 1000000;

  void link(_Phone a, _Phone b) {
    (friends[a.address] ??= <String>{}).add(b.address);
    (friends[b.address] ??= <String>{}).add(a.address);
  }
}

final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = PeerShareCodec.normalizeAddress(
        '200::${(0xb0 + net.phones.length).toRadixString(16)}',
      ) {
    net.phones[address] = this;
    service = _make(disk);
  }

  final _Net net;
  final String name;
  final String address;
  MemoryLedgerDisk disk = MemoryLedgerDisk();
  late DatingService service;

  /// Dating keys the pyramid switched off, and the ones this person hid
  /// after reporting them.
  final Set<String> banned = <String>{};
  final Set<String> hidden = <String>{};
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  DatingService _make(MemoryLedgerDisk d) => DatingService(
    host: this,
    disk: d,
    now: () => net.clock,
    isBanned: banned.contains,
    isHiddenByMe: hidden.contains,
  );

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Phone? other = net.phones[to];
    if (other == null) {
      return;
    }
    await other.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => (net.friends[address] ?? const <String>{}).toList();

  @override
  bool isFriend(String a) => net.friends[address]?.contains(a) ?? false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net.phones[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  Future<void> date(String n, DatingGender g) async {
    await service.load();
    await service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = n
        ..gender = g
        ..wants = DatingWants(
          genders: DatingGender.values.toSet(),
          hops: kDatingMaxHops,
          intent: DatingIntent.dates,
          friendGenders: kDatingAllGenders,
        );
    });
    await service.maybePublish(force: true);
  }

  /// The same person on the same phone starts over with a new dating key
  /// (a modified app can do so at will) and keeps everything else, their
  /// reports of a minor among it. With [tellFriends] the new key goes to
  /// the friends at once.
  Future<void> newDatingKey({bool tellFriends = false}) async {
    final Map<String, dynamic> state =
        jsonDecode(utf8.decode((await disk.read('dating/state'))!))
              as Map<String, dynamic>
          ..remove('id')
          ..remove('vs')
          ..remove('ps');
    if (tellFriends) {
      state.remove('ksent');
    }
    disk = MemoryLedgerDisk();
    await disk.write('dating/state', utf8.encode(jsonEncode(state)));
    service = _make(disk);
    await service.load();
    await service.maybePublish(force: true);
  }

  Set<String> matchKeys() => <String>{
    for (final SeenProfile s in service.matches) s.profile.key,
  };
}

void main() {
  test('one person with two dating keys does not switch an adult\'s profile '
      'and match off on a third phone', () async {
    final _Net net = _Net();
    final _Phone hub = _Phone(net, 'hub');
    final _Phone mia = _Phone(net, 'mia');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone eve = _Phone(net, 'eve');
    for (final _Phone p in <_Phone>[mia, darek, eve]) {
      net.link(hub, p);
    }
    await hub.service.load();
    await mia.date('Mia', DatingGender.woman);
    await darek.date('Darek', DatingGender.man);
    await eve.date('Eve', DatingGender.woman);
    for (final _Phone p in <_Phone>[mia, darek, eve]) {
      await p.service.maybePublish(force: true);
    }
    final String miaKey = mia.service.myKey!;
    final String darekKey = darek.service.myKey!;
    await darek.service.decide(miaKey, true);
    await mia.service.decide(darekKey, true);
    expect(darek.matchKeys(), contains(miaKey));

    // Eve reports Mia, then her app takes a second dating key and reports
    // with it as well: two keys, one person.
    final String eveKey = eve.service.myKey!;
    await eve.service.reportMinor(miaKey);
    await eve.service.maybePublish(force: true);
    await eve.newDatingKey();
    expect(eve.service.myKey, isNot(eveKey));
    expect(eve.service.reportedMinor(miaKey), isTrue);

    expect(darek.service.isMinorOff(miaKey), isFalse);
    expect(darek.matchKeys(), contains(miaKey));
    // Two keys nobody here can put a person to: a warning, nothing more.
    expect(darek.service.minorWarning(miaKey), isTrue);

    // Mia's messages still reach Darek.
    final int before = darek.shown.length;
    expect(await mia.service.sendMessage(darekKey, 'Hej!'), isTrue);
    expect(darek.service.chat(miaKey).single.text, 'Hej!');
    expect(darek.shown.length, before + 1);
  });

  test('two of this person\'s friends switch a profile off here; one friend '
      'with two keys is one reporter; a stranger sees a warning; a withdrawn '
      'report brings the profile, the match and its chat back', () async {
    final _Net net = _Net();
    final _Phone hub = _Phone(net, 'hub');
    final _Phone mia = _Phone(net, 'mia');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone eve = _Phone(net, 'eve');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone fred = _Phone(net, 'fred');
    for (final _Phone p in <_Phone>[mia, darek, eve, ola, fred]) {
      net.link(hub, p);
    }
    net
      ..link(darek, eve)
      ..link(darek, ola);
    await hub.service.load();
    await mia.date('Mia', DatingGender.woman);
    await darek.date('Darek', DatingGender.man);
    await eve.date('Eve', DatingGender.woman);
    await ola.date('Ola', DatingGender.woman);
    await fred.date('Fred', DatingGender.man);
    for (final _Phone p in <_Phone>[mia, darek, eve, ola, fred]) {
      await p.service.maybePublish(force: true);
    }
    final String miaKey = mia.service.myKey!;
    final String darekKey = darek.service.myKey!;
    await darek.service.decide(miaKey, true);
    await mia.service.decide(darekKey, true);
    expect(darek.matchKeys(), contains(miaKey));
    bool fredSees() =>
        fred.service.toDecide.any((SeenProfile s) => s.profile.key == miaKey);
    expect(fredSees(), isTrue);

    // One friend: a warning on Darek's phone.
    await eve.service.reportMinor(miaKey);
    await eve.service.maybePublish(force: true);
    expect(darek.service.isMinorOff(miaKey), isFalse);
    expect(darek.service.minorWarning(miaKey), isTrue);

    // The same friend with a new key (told to Darek) is still one friend.
    await eve.newDatingKey(tellFriends: true);
    expect(darek.service.knownKeyOf(eve.address), eve.service.myKey);
    expect(darek.service.isMinorOff(miaKey), isFalse);
    expect(darek.matchKeys(), contains(miaKey));

    // A second friend of Darek's: switched off on his phone, match and all.
    await ola.service.reportMinor(miaKey);
    await ola.service.maybePublish(force: true);
    expect(darek.service.isMinorOff(miaKey), isTrue);
    expect(darek.service.minorWarning(miaKey), isFalse);
    expect(darek.matchKeys(), isEmpty);
    expect(darek.service.isMatch(miaKey), isFalse);
    // Fred knows none of the reporters: three keys, shown with a warning.
    expect(fred.service.isMinorOff(miaKey), isFalse);
    expect(fred.service.minorWarning(miaKey), isTrue);
    expect(fredSees(), isTrue);

    // Mia, who is told nothing, writes: kept, not announced, not answerable.
    final int before = darek.shown.length;
    expect(await mia.service.sendMessage(darekKey, 'Halo?'), isTrue);
    expect(darek.shown.length, before);
    expect(await darek.service.sendMessage(miaKey, 'Hej'), isFalse);
    expect(mia.service.isMatch(darekKey), isTrue);

    // Ola withdraws; her next answer withdraws it on Darek's phone too.
    await ola.service.withdrawMinor(miaKey);
    expect(ola.service.reportedMinor(miaKey), isFalse);
    await ola.service.maybePublish(force: true);
    expect(darek.service.isMinorOff(miaKey), isFalse);
    expect(darek.service.minorWarning(miaKey), isTrue);
    expect(darek.matchKeys(), contains(miaKey));
    expect(darek.service.chat(miaKey).map((DatingLine l) => l.text), <String>[
      'Halo?',
    ]);
    expect(await darek.service.sendMessage(miaKey, 'Hej'), isTrue);

    // Eve withdraws as well: no warning left.
    await eve.service.withdrawMinor(miaKey);
    await eve.service.maybePublish(force: true);
    expect(darek.service.minorWarning(miaKey), isFalse);

    // The rule holds after a restart.
    await ola.service.reportMinor(miaKey);
    await ola.service.maybePublish(force: true);
    await eve.service.reportMinor(miaKey);
    await eve.service.maybePublish(force: true);
    expect(darek.service.isMinorOff(miaKey), isTrue);
    final DatingService again = DatingService(
      host: darek,
      disk: darek.disk,
      now: () => net.clock,
    );
    await again.load();
    expect(again.isMinorOff(miaKey), isTrue);
    // A reporter who is no longer a friend no longer counts.
    net.friends[darek.address]!.remove(ola.address);
    expect(again.isMinorOff(miaKey), isFalse);
    expect(again.minorWarning(miaKey), isTrue);
  });

  test('this person\'s own report hides the profile at once, keeps the '
      'match unannounced, and can be withdrawn', () async {
    final _Net net = _Net();
    final _Phone mia = _Phone(net, 'mia');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone fred = _Phone(net, 'fred');
    net
      ..link(mia, darek)
      ..link(darek, fred)
      ..link(mia, fred);
    await mia.date('Mia', DatingGender.woman);
    await darek.date('Darek', DatingGender.man);
    await fred.date('Fred', DatingGender.man);
    for (final _Phone p in <_Phone>[mia, darek, fred]) {
      await p.service.maybePublish(force: true);
    }
    final String miaKey = mia.service.myKey!;
    final String darekKey = darek.service.myKey!;
    await darek.service.decide(miaKey, true);
    await mia.service.decide(darekKey, true);
    expect(darek.matchKeys(), contains(miaKey));

    await darek.service.reportMinor(miaKey);
    expect(darek.service.isMinorOff(miaKey), isTrue);
    expect(darek.matchKeys(), isEmpty);
    expect(darek.service.reportedMinors.single.profile.key, miaKey);
    expect(darek.service.opinionFriends(miaKey), isEmpty);
    expect(darek.service.canIntroduce(DatingEnd.profile(miaKey)), isFalse);
    expect(await darek.service.shareMutualFriends(miaKey), isFalse);
    final int before = darek.shown.length;
    await mia.service.sendMessage(darekKey, 'Hej?');
    expect(darek.shown.length, before);

    // Fred, Darek's friend, hears of it: one friend, a warning.
    await darek.service.maybePublish(force: true);
    expect(fred.service.minorWarning(miaKey), isTrue);

    await darek.service.withdrawMinor(miaKey);
    expect(darek.service.isMinorOff(miaKey), isFalse);
    expect(darek.service.reportedMinors, isEmpty);
    expect(darek.matchKeys(), contains(miaKey));
    expect(darek.service.chat(miaKey).single.text, 'Hej?');
    await darek.service.maybePublish(force: true);
    expect(fred.service.minorWarning(miaKey), isFalse);
  });

  test('a match switched off by the pyramid or hidden after a report reaches '
      'the person nowhere: no match or message announced, nothing sent, '
      'and it is back once that ends', () async {
    final _Net net = _Net();
    final _Phone mia = _Phone(net, 'mia');
    final _Phone darek = _Phone(net, 'darek');
    net.link(mia, darek);
    await mia.date('Mia', DatingGender.woman);
    await darek.date('Darek', DatingGender.man);
    await mia.service.maybePublish(force: true);
    final String miaKey = mia.service.myKey!;
    final String darekKey = darek.service.myKey!;
    bool announced(String prefix) => darek.shown.any(
      (RuntimeSystemNotification n) => n.id.startsWith(prefix),
    );

    // Darek says "Tak", then the pyramid bans Mia; her "Tak" makes the
    // match, unannounced.
    await darek.service.decide(miaKey, true);
    darek.banned.add(miaKey);
    await mia.service.decide(darekKey, true);
    expect(mia.service.isMatch(darekKey), isTrue);
    expect(announced('date-match-'), isFalse);
    expect(darek.matchKeys(), isEmpty);
    expect(darek.service.isMatch(miaKey), isFalse);
    await mia.service.sendMessage(darekKey, 'Raz');
    expect(announced('date-msg-'), isFalse);
    expect(await darek.service.sendMessage(miaKey, 'Hej'), isFalse);
    expect(await darek.service.shareMutualFriends(miaKey), isFalse);
    expect(darek.service.opinionFriends(miaKey), isEmpty);

    // The ban is lifted: the match and its chat are there.
    darek.banned.remove(miaKey);
    expect(darek.matchKeys(), contains(miaKey));
    expect(darek.service.chat(miaKey).single.text, 'Raz');

    // Hidden after a report: the same.
    darek.hidden.add(miaKey);
    expect(darek.matchKeys(), isEmpty);
    await mia.service.sendMessage(darekKey, 'Dwa');
    expect(announced('date-msg-'), isFalse);
    expect(await darek.service.sendMessage(miaKey, 'Hej'), isFalse);
    darek.hidden.remove(miaKey);
    expect(darek.matchKeys(), contains(miaKey));
    await mia.service.sendMessage(darekKey, 'Trzy');
    expect(announced('date-msg-'), isTrue);
    expect(await darek.service.sendMessage(miaKey, 'Hej'), isTrue);
  });
}
