import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/dating/dating_crypto.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart' show kSendOnceKey;
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
  _Phone(
    this.net,
    this.name, {
    this.pyramid,
    this.payable = const <String>{},
    this.position,
    this.decoyShare = 0,
  }) : address = PeerShareCodec.normalizeAddress(
         '200::${(0xb0 + net.phones.length).toRadixString(16)}',
       ) {
    net.phones[address] = this;
    service = DatingService(
      host: this,
      disk: disk,
      now: () => net.clock,
      raiseAlarm: (String note) async => alarms.add(note),
      currentPosition: position == null ? null : () async => position,
      decoyFetchShare: decoyShare,
      pyramidKey: () => pyramid,
      canPay: (String to) => pyramid != null && payable.contains(to),
      pay: (String to, int amount, String memo) async {
        payments.add((to, amount, memo));
        return true;
      },
    );
  }

  final _Net net;
  final String name;

  /// This person's pyramid key (null: not in a pyramid) and the members
  /// they can pay.
  final String? pyramid;
  final Set<String> payable;

  /// Where this phone is, for answering a request for the location.
  final (double, double)? position;

  /// The share of lanterns this phone asks the profile of with dating off.
  final double decoyShare;
  final List<(String, int, String)> payments = <(String, int, String)>[];
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late DatingService service;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<String> alarms = <String>[];
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    final _Phone? other = net.phones[to];
    if (other == null) {
      return;
    }
    other.received.add(payload);
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

  Future<void> date({
    required String name,
    required int age,
    required DatingGender gender,
    Set<DatingGender>? wants,
    int hops = 3,
  }) async {
    await service.load();
    await service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..adult = true
        ..name = name
        ..age = age
        ..gender = gender
        ..wants = DatingWants(
          genders: wants ?? DatingGender.values.toSet(),
          hops: hops,
        );
    });
  }

  int backCount() => sent
      .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back)
      .length;
}

void main() {
  test(
    'a sealed box opens only for its recipient, and tells who sent it',
    () async {
      final RelayIdentity a = await RelayIdentity.generate();
      final RelayIdentity b = await RelayIdentity.generate();
      final RelayIdentity eve = await RelayIdentity.generate();
      final Map<String, String> box = await DatingBox.seal(
        me: a,
        recipient: b.publicKey,
        payload: <String, dynamic>{'k': 'msg', 't': 'hej'},
      );
      expect(
        box['s'],
        isNot(base64Url.encode(a.publicKey)),
        reason: 'the sender is hidden',
      );
      final (List<int>, Map<String, dynamic>)? opened = await DatingBox.open(
        me: b,
        box: box,
      );
      expect(base64Url.encode(opened!.$1), base64Url.encode(a.publicKey));
      expect(opened.$2['t'], 'hej');
      expect(await DatingBox.open(me: eve, box: box), isNull);

      // Both sides compute the same "Tak" token; a third key gets another.
      expect(
        await datingLikeToken(a, b.publicKey),
        await datingLikeToken(b, a.publicKey),
      );
      expect(
        await datingLikeToken(a, eve.publicKey),
        isNot(await datingLikeToken(a, b.publicKey)),
      );
    },
  );

  test('profiles are fetched 2 steps away through phones without dating; '
      'likes, a match and messages go back sealed', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone darek = _Phone(net, 'darek');
    net
      ..link(ania, bob)
      ..link(bob, darek);
    await bob.service.load();
    await ania.date(
      name: 'Ania',
      age: 30,
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await darek.date(
      name: 'Darek',
      age: 32,
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    // Darek's phone was not on dating yet when Ania's lantern passed.
    await ania.service.maybePublish(force: true);

    final SeenProfile atDarek = darek.service.toDecide.single;
    expect(atDarek.profile.name, 'Ania');
    expect(atDarek.distance, 2);
    expect(atDarek.path, <String>['bob']);
    expect(atDarek.friend, bob.address);
    expect(ania.service.toDecide.single.profile.name, 'Darek');
    // The phone in between passed the lanterns on but kept nothing.
    expect(bob.service.toDecide, isEmpty);
    expect(bob.shown, isEmpty);

    final String aniaKey = ania.service.myKey!;
    final String darekKey = darek.service.myKey!;

    // "Nie" sends nothing at all.
    final int before = darek.backCount();
    await darek.service.decide(aniaKey, false);
    expect(darek.backCount(), before);

    // "Tak" from Ania: no match yet, Darek learns nothing visible.
    await ania.service.decide(darekKey, true);
    expect(ania.service.isMatch(darekKey), isFalse);
    expect(darek.service.isMatch(aniaKey), isFalse);
    expect(ania.service.liked.single.profile.name, 'Darek');

    // Darek changes his mind: a match on both sides.
    await darek.service.decide(aniaKey, true);
    expect(darek.service.isMatch(aniaKey), isTrue);
    expect(ania.service.isMatch(darekKey), isTrue);
    expect(ania.shown.last.title, 'Para! ❤️');

    await ania.service.sendMessage(darekKey, 'Cześć!');
    expect(darek.service.chat(aniaKey).single.text, 'Cześć!');
    await darek.service.sendMessage(aniaKey, 'Hej :)');
    expect(ania.service.chat(darekKey).last.text, 'Hej :)');
    expect(ania.service.chat(darekKey).last.mine, isFalse);

    // Messages through Bob are sealed: his phone sees no text.
    expect(
      bob.sent.where(
        (Map<String, dynamic> p) => jsonEncode(p).contains('Hej :)'),
      ),
      isEmpty,
    );
  });

  test('a lantern goes 2 steps and no further; a profile is asked for only '
      'when the lantern fits', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cyryl = _Phone(net, 'cyryl');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone ewa = _Phone(net, 'ewa');
    net
      ..link(ania, bob)
      ..link(bob, cyryl)
      ..link(cyryl, darek)
      ..link(bob, ewa);
    await bob.service.load();
    await cyryl.service.load();
    await darek.date(
      name: 'Darek',
      age: 32,
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    // Ewa dates too, but is a woman and Ania looks for men.
    await ewa.date(
      name: 'Ewa',
      age: 28,
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await ania.date(
      name: 'Ania',
      age: 30,
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await ania.service.maybePublish(force: true);

    // Three steps away: the lantern never arrives.
    final String lanternId =
        ania.sent.lastWhere(
              (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
            )['id']
            as String;
    expect(
      darek.received.where((Map<String, dynamic> p) => p['id'] == lanternId),
      isEmpty,
    );
    expect(darek.service.toDecide, isEmpty);
    expect(cyryl.service.toDecide, isEmpty);

    // Two steps away, but it does not fit Ewa: her phone asks for nothing
    // (and sends nothing) while the lantern costs the network ~100 bytes.
    expect(
      ewa.received.any((Map<String, dynamic> p) => p['id'] == lanternId),
      isTrue,
    );
    expect(ewa.backCount(), 0);
    expect(ewa.service.toDecide, isEmpty);
    final List<Map<String, dynamic>> lanterns = <Map<String, dynamic>>[
      for (final _Phone p in <_Phone>[ania, bob, cyryl, darek, ewa])
        ...p.sent.where(
          (Map<String, dynamic> m) => m['type'] == DatingTypes.lantern,
        ),
    ];
    expect(lanterns, isNotEmpty);
    for (final Map<String, dynamic> l in lanterns) {
      expect(jsonEncode(l['l']).length, lessThan(100));
      expect(DatingLantern.fromJson(l['l']), isNotNull);
      expect((l['path'] as List).length, lessThanOrEqualTo(1));
    }
    expect(jsonEncode(lanterns), isNot(contains('Ania')));

    // A fitting person two steps away is asked.
    final _Phone fred = _Phone(net, 'fred');
    net.link(fred, bob);
    await fred.date(
      name: 'Fred',
      age: 33,
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ania.service.maybePublish(force: true);
    expect(fred.service.toDecide.single.profile.name, 'Ania');
    expect(fred.service.toDecide.single.distance, 2);
    expect(fred.backCount(), greaterThan(0));
  });

  test('a phone with dating off asks for the profile of a share of the '
      'lanterns and drops the answer', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob', decoyShare: 1);
    final _Phone cyryl = _Phone(net, 'cyryl');
    net
      ..link(ania, bob)
      ..link(bob, cyryl);
    await bob.service.load();
    await cyryl.service.load();
    await ania.date(name: 'Ania', age: 30, gender: DatingGender.woman);
    expect(bob.backCount(), greaterThan(0), reason: 'asked like a dater');
    expect(bob.service.toDecide, isEmpty);
    expect(bob.shown, isEmpty);
    expect(cyryl.backCount(), 0, reason: 'a share of 0 asks for nothing');
  });

  test(
    'a lantern fits both ways; a decoy has the same shape as a real one',
    () {
      const DatingWants wants = DatingWants(
        minAge: 25,
        maxAge: 40,
        genders: <DatingGender>{DatingGender.man},
        hops: 1,
      );
      final DatingLantern real = DatingLantern.of(
        key: 'ania-key',
        age: 30,
        gender: DatingGender.woman,
        wants: wants,
      );
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(real.toJson())) as Map<String, dynamic>;
      expect(jsonEncode(json).length, lessThan(100));
      final DatingLantern back = DatingLantern.fromJson(json)!;
      expect(back.key, 'ania-key');
      expect(back.age, 30);
      expect(back.gender, DatingGender.woman);
      expect(back.wants.minAge, 25);
      expect(back.wants.maxAge, 40);
      expect(back.wants.genders, <DatingGender>{DatingGender.man});
      expect(back.wants.hops, 1);

      bool fits({
        int age = 35,
        DatingGender gender = DatingGender.man,
        int distance = 1,
        DatingWants mine = const DatingWants(),
      }) => back.fits(
        myAge: age,
        myGender: gender,
        myWants: mine,
        distance: distance,
      );
      expect(fits(), isTrue);
      expect(fits(age: 41), isFalse, reason: 'her range');
      expect(fits(gender: DatingGender.woman), isFalse, reason: 'her genders');
      expect(fits(distance: 2), isFalse, reason: 'her distance');
      expect(
        fits(mine: const DatingWants(minAge: 18, maxAge: 29)),
        isFalse,
        reason: 'his range',
      );
      expect(
        fits(
          mine: const DatingWants(genders: <DatingGender>{DatingGender.man}),
        ),
        isFalse,
        reason: 'his genders',
      );

      // A decoy is valid and shaped like a real lantern, whatever the dice say.
      for (int seed = 0; seed < 200; seed++) {
        final Map<String, dynamic> decoy = DatingLantern.decoy(
          'ania-key',
          Random(seed),
        ).toJson();
        expect(DatingLantern.fromJson(decoy), isNotNull, reason: 'seed $seed');
        expect(decoy.keys.toSet(), json.keys.toSet());
        expect((decoy['h'] as String).length, (json['h'] as String).length);
      }

      // Anything this app never makes is not a lantern.
      Map<String, dynamic> withField(String field, Object? value) =>
          <String, dynamic>{...json, field: value};
      List<int> bytes({int? age, int? mask, int? hops, int? min, int? max}) =>
          <int>[age ?? 30, 1, min ?? 25, max ?? 40, mask ?? 2, hops ?? 1];
      String h(List<int> b) => base64Url.encode(b);
      expect(DatingLantern.fromJson(withField('v', 2)), isNull);
      expect(DatingLantern.fromJson(withField('k', 5)), isNull);
      expect(DatingLantern.fromJson(withField('k', 'x' * 65)), isNull);
      expect(DatingLantern.fromJson(withField('h', 'abc')), isNull);
      expect(
        DatingLantern.fromJson(withField('h', h(<int>[30, 1, 25, 40, 2]))),
        isNull,
      );
      expect(DatingLantern.fromJson(withField('h', h(bytes(age: 17)))), isNull);
      expect(DatingLantern.fromJson(withField('h', h(bytes(min: 17)))), isNull);
      expect(
        DatingLantern.fromJson(withField('h', h(bytes(max: 100)))),
        isNull,
      );
      expect(DatingLantern.fromJson(withField('h', h(bytes(mask: 0)))), isNull);
      expect(DatingLantern.fromJson(withField('h', h(bytes(mask: 8)))), isNull);
      expect(DatingLantern.fromJson(withField('h', h(bytes(hops: 0)))), isNull);
      expect(
        DatingLantern.fromJson(
          withField('h', h(bytes(hops: kDatingMaxHops + 1))),
        ),
        isNull,
      );
      expect(DatingLantern.fromJson(withField('h', h(bytes()))), isNotNull);
      expect(DatingLantern.fromJson('x'), isNull);
    },
  );

  test('phones with dating off send decoy lanterns that look the same and '
      'are dropped; hidden people never see a profile', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone ewa = _Phone(net, 'ewa');
    net
      ..link(ania, bob)
      ..link(bob, ewa);
    await bob.service.load();
    await ewa.date(name: 'Ewa', age: 28, gender: DatingGender.woman);
    await bob.service.maybePublish(force: true);
    expect(
      bob.sent.where(
        (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
      ),
      isNotEmpty,
    );
    expect(
      ewa.service.toDecide,
      isEmpty,
      reason: 'a decoy lantern shows nothing',
    );

    // Ania hides from Ewa: the lantern passes Bob, but Ewa never sees the
    // profile.
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..adult = true
        ..name = 'Ania'
        ..age = 30
        ..gender = DatingGender.woman
        ..hiddenFriends.add(ewa.address);
    });
    expect(ewa.service.toDecide, isEmpty);
    await ewa.service.maybePublish(force: true);
    expect(ewa.service.toDecide, isEmpty);
    expect(ania.service.toDecide.single.profile.name, 'Ewa');

    // Preferences count both ways: a profile for men only skips Ewa.
    final _Phone ola = _Phone(net, 'ola');
    net.link(ola, bob);
    await ola.date(
      name: 'Ola',
      age: 25,
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    expect(
      ewa.service.toDecide.where((SeenProfile s) => s.profile.name == 'Ola'),
      isEmpty,
    );
  });

  test('a friend introduces two people who would not meet otherwise', () async {
    final _Net net = _Net();
    final _Phone marta = _Phone(net, 'marek');
    final _Phone xenia = _Phone(net, 'xenia');
    final _Phone yann = _Phone(net, 'yann');
    net
      ..link(marta, xenia)
      ..link(marta, yann);
    await marta.date(name: 'Marek', age: 35, gender: DatingGender.man);
    await xenia.date(
      name: 'Xenia',
      age: 29,
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    await yann.date(name: 'Yann', age: 31, gender: DatingGender.man, hops: 1);
    await marta.service.maybePublish(force: true);
    await xenia.service.maybePublish(force: true);
    await yann.service.maybePublish(force: true);
    expect(
      xenia.service.toDecide.where((SeenProfile s) => s.profile.name == 'Yann'),
      isEmpty,
      reason: 'two steps is too far for her',
    );
    expect(
      marta.service.toDecide.map((SeenProfile s) => s.profile.name),
      containsAll(<String>['Xenia', 'Yann']),
    );

    final String x = xenia.service.myKey!;
    final String y = yann.service.myKey!;
    expect(await marta.service.introduce(x, y, 'Oboje kochacie góry'), isTrue);
    final SeenProfile atX = xenia.service.profile(y)!;
    expect(atX.introBy, 'marek');
    expect(atX.introNote, 'Oboje kochacie góry');
    expect(yann.service.profile(x)!.introBy, 'marek');
    expect(xenia.shown.last.title, 'marek chce Cię komuś przedstawić');

    await xenia.service.decide(y, true);
    await yann.service.decide(x, true);
    expect(xenia.service.isMatch(y), isTrue);
    expect(yann.service.isMatch(x), isTrue);
    await yann.service.sendMessage(x, 'Które góry?');
    expect(xenia.service.chat(y).single.text, 'Które góry?');
    await xenia.service.sendMessage(y, 'Tatry!');
    expect(yann.service.chat(x).last.text, 'Tatry!');
    expect(yann.service.chat(x).last.mine, isFalse);
  });

  test('asking a friend for an opinion, and a friend vouching', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone darek = _Phone(net, 'darek');
    net
      ..link(ania, bob)
      ..link(bob, darek);
    await bob.service.load();
    await ania.date(name: 'Ania', age: 30, gender: DatingGender.woman);
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    await ania.service.maybePublish(force: true);
    final String aniaKey = ania.service.myKey!;

    expect(
      await darek.service.askOpinion(aniaKey, 'Co sądzisz o Ani?'),
      isTrue,
    );
    final OpinionAsk asked = bob.service.asksToMe.single;
    expect(asked.question, 'Co sądzisz o Ani?');
    expect(asked.name, 'Ania');
    await bob.service.answerOpinion(asked.id, 'Świetna, polecam');
    expect(darek.service.myAsks.single.answer, 'Świetna, polecam');

    await ania.service.requestVouch(bob.address);
    final String req = bob.service.vouchRequests.keys.single;
    await bob.service.writeVouch(req, 'Najlepsza kucharka na osiedlu');
    expect(bob.service.vouchRequests, isEmpty);
    final DatingVouch v = ania.service.me.vouches.single;
    expect(v.by, 'bob');
    expect(v.approved, isFalse);
    await ania.service.setVouch(v.id, keep: true);
    // The approved word travels with the next package.
    expect(
      darek.service.profile(aniaKey)!.profile.vouches.single.text,
      'Najlepsza kucharka na osiedlu',
    );
  });

  test('"Idę na randkę": a reminder, then an alarm on both sides; "Wszystko '
      'OK" ends it', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    net.link(ania, bob);
    await ania.service.load();
    await bob.service.load();

    final SafeDate d = (await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 2),
      note: 'Kawiarnia na rynku',
      lat: 52.2,
      lon: 21.0,
    ))!;
    final SafeDate watched = bob.service.safeDates.single;
    expect(watched.note, 'Kawiarnia na rynku');
    expect(watched.lat, 52.2);
    expect(bob.shown.last.title, 'ania idzie na randkę');

    net.clock = d.until + 1;
    await ania.service.tick();
    await bob.service.tick();
    expect(ania.shown.last.title, 'Wszystko OK?');
    expect(bob.shown.last.title, 'ania miał(a) dać znać');
    expect(ania.alarms, isEmpty);

    net.clock = d.until + SafeDate.grace.inMilliseconds + 1;
    await ania.service.tick();
    await bob.service.tick();
    expect(ania.alarms, hasLength(1));
    expect(bob.shown.last.category, RuntimeSystemNotificationCategory.alarm);

    await ania.service.safeOk();
    expect(bob.service.safeDates, isEmpty);
    expect(bob.shown.last.title, 'ania: wszystko OK');
    expect(ania.service.mySafeDate, isNull);
  });

  test('the location of a date on request: the dater is asked for consent '
      'and answers once', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    net.link(ania, bob);
    await ania.service.load();
    await bob.service.load();
    await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 2),
    );
    final SafeDate watched = bob.service.safeDates.single;
    expect(watched.lat, isNull);

    expect(await bob.service.requestSafeLocation(watched.id), isTrue);
    expect(watched.locationPending, isTrue);
    // Asked again at once: nothing goes out.
    expect(await bob.service.requestSafeLocation(watched.id), isFalse);
    final SafeDate mine = ania.service.mySafeDate!;
    expect(mine.locationAsked, isTrue);
    expect(ania.shown.last.title, 'bob prosi o Twoje położenie');
    expect(mine.lat, isNull, reason: 'nothing is sent without consent');

    // Refused: no location, no answer, the question is gone.
    await ania.service.answerLocationRequest(allow: false);
    expect(ania.service.mySafeDate!.locationAsked, isFalse);
    expect(bob.service.safeDates.single.lat, isNull);

    net.clock += kDatingLocationAskEvery.inMilliseconds + 1;
    expect(await bob.service.requestSafeLocation(watched.id), isTrue);
    await ania.service.answerLocationRequest(
      allow: true,
      lat: 52.25,
      lon: 21.01,
    );
    expect(bob.service.safeDates.single.lat, 52.25);
    expect(bob.service.safeDates.single.lon, 21.01);
    expect(bob.service.safeDates.single.locationPending, isFalse);
    expect(ania.service.mySafeDate!.locationAsked, isFalse);

    // Only the watching friend can ask, and only for a running date.
    final _Phone eve = _Phone(net, 'eve');
    net.link(ania, eve);
    await eve.service.load();
    await ania.service.handle(
      SignalTransportFrame(
        from: eve.address,
        payload: <String, dynamic>{
          'type': DatingTypes.locationRequest,
          'id': mine.id,
        },
        receivedAtMillis: 0,
      ),
    );
    expect(ania.service.mySafeDate!.locationAsked, isFalse);
  });

  test('a request for the location is answered at once when the dater agreed '
      'beforehand', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', position: (50.06, 19.94));
    final _Phone bob = _Phone(net, 'bob');
    net.link(ania, bob);
    await ania.service.load();
    await bob.service.load();
    await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 2),
      autoShareLocation: true,
    );
    final String id = bob.service.safeDates.single.id;
    await bob.service.requestSafeLocation(id);
    expect(ania.service.mySafeDate!.locationAsked, isFalse);
    expect(bob.service.safeDates.single.lat, 50.06);
    expect(bob.service.safeDates.single.lon, 19.94);
    expect(
      ania.shown.where(
        (RuntimeSystemNotification n) => n.id.startsWith('date-loc-ask'),
      ),
      isEmpty,
    );

    // The agreement survives a restart.
    final DatingService again = DatingService(
      host: ania,
      disk: ania.disk,
      now: () => net.clock,
    );
    await again.load();
    expect(again.mySafeDate!.autoShare, isTrue);
  });

  test('a report of a minor switches the profile off here at once; two '
      'independent reports switch it off for the people around', () async {
    final _Net net = _Net();
    final _Phone hub = _Phone(net, 'hub');
    final _Phone mia = _Phone(net, 'mia');
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ewa = _Phone(net, 'ewa');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone fred = _Phone(net, 'fred');
    for (final _Phone p in <_Phone>[mia, ania, ewa, darek, fred]) {
      net.link(hub, p);
    }
    await hub.service.load();
    await mia.date(name: 'Mia', age: 19, gender: DatingGender.woman);
    await ania.date(name: 'Ania', age: 30, gender: DatingGender.woman);
    await ewa.date(name: 'Ewa', age: 31, gender: DatingGender.woman);
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    await fred.date(name: 'Fred', age: 33, gender: DatingGender.man);
    for (final _Phone p in <_Phone>[mia, ania, ewa, darek, fred]) {
      await p.service.maybePublish(force: true);
    }
    final String miaKey = mia.service.myKey!;
    bool sees(_Phone p) =>
        p.service.toDecide.any((SeenProfile s) => s.profile.key == miaKey);
    expect(sees(ania), isTrue);
    expect(sees(darek), isTrue);

    // Ania's report: gone from her phone at once, one report elsewhere.
    await ania.service.reportMinor(miaKey);
    expect(ania.service.isMinorOff(miaKey), isTrue);
    expect(sees(ania), isFalse);
    expect(sees(darek), isTrue, reason: 'one report is not enough');

    // The same reporter again counts once.
    await ania.service.maybePublish(force: true);
    expect(sees(darek), isTrue);

    // A second, independent reporter: the profile goes for everybody who
    // sees the packages of both.
    await ewa.service.reportMinor(miaKey);
    expect(sees(ewa), isFalse);
    expect(sees(darek), isFalse);
    expect(sees(fred), isFalse);
    expect(darek.service.isMinorOff(miaKey), isTrue);
    expect(darek.service.hiddenProfiles, isEmpty);

    // A profile switched off is not taken in again, and the state survives
    // a restart.
    await mia.service.maybePublish(force: true);
    expect(sees(darek), isFalse);
    final DatingService again = DatingService(
      host: darek,
      disk: darek.disk,
      now: () => net.clock,
    );
    await again.load();
    expect(again.isMinorOff(miaKey), isTrue);

    // The reported person's own phone gets nothing out of it.
    expect(mia.service.isMinorOff(miaKey), isFalse);
  });

  test('the dating key and decisions survive a restart', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    net.link(ania, darek);
    await ania.date(name: 'Ania', age: 30, gender: DatingGender.woman);
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    final String key = ania.service.myKey!;
    await ania.service.decide(darek.service.myKey!, true);

    final DatingService again = DatingService(
      host: ania,
      disk: ania.disk,
      now: () => net.clock,
    );
    await again.load();
    expect(again.myKey, key);
    expect(again.active, isTrue);
    expect(again.decision(darek.service.myKey!), isTrue);
    expect(again.liked.single.profile.name, 'Darek');
  });

  test('a vouch is signed for one profile; changing the words or moving '
      'them to another profile breaks the signature', () async {
    final LedgerKeyPair bob = await LedgerKeyPair.generate();
    const String ania = 'ania-dating-key';
    final DatingVouch v = await DatingVouch.sign(
      signer: bob,
      id: 'v1',
      forKey: ania,
      by: 'Bob',
      text: 'Gotuje genialnie',
      at: 42,
    );
    expect(v.signer, bob.id);
    expect(await v.verify(ania), isTrue);
    expect(
      await v.verify('someone-else'),
      isFalse,
      reason: 'bound to one profile',
    );

    // Survives the trip as JSON, approval included.
    final DatingVouch back = DatingVouch.fromJson(
      jsonDecode(jsonEncode(v.approve().toJson())),
    )!;
    expect(back.approved, isTrue);
    expect(await back.verify(ania), isTrue);

    final DatingVouch changed = DatingVouch.fromJson(<String, dynamic>{
      ...v.toJson(),
      't': 'Gotuje fatalnie',
    })!;
    expect(await changed.verify(ania), isFalse);

    // An unsigned vouch is not read at all.
    expect(
      DatingVouch.fromJson(<String, dynamic>{
        'id': 'x',
        'by': 'Ola',
        't': 'Super',
      }),
      isNull,
    );
  });

  test('a friend signs the vouch; viewers keep it and drop a forged '
      'one', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone darek = _Phone(net, 'darek');
    net
      ..link(ania, bob)
      ..link(bob, darek);
    await bob.service.load();
    await ania.date(name: 'Ania', age: 30, gender: DatingGender.woman);
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    final String aniaKey = ania.service.myKey!;

    await ania.service.requestVouch(bob.address);
    await bob.service.writeVouch(
      bob.service.vouchRequests.keys.single,
      'Gotuje genialnie',
    );
    final DatingVouch got = ania.service.me.vouches.single;
    expect(got.signer, bob.service.vouchKey);
    expect(await got.verify(aniaKey), isTrue);

    await ania.service.saveMine((MyDating m) {
      m.vouches
        ..[0] = m.vouches[0].approve()
        // Ania "improves" Bob's words: the signature no longer fits.
        ..add(
          DatingVouch(
            id: 'forged',
            by: got.by,
            text: 'Najlepsza osoba na świecie',
            approved: true,
            signer: got.signer,
            sig: got.sig,
            at: got.at,
          ),
        );
    });
    final List<DatingVouch> seen = darek.service
        .profile(aniaKey)!
        .profile
        .vouches;
    expect(seen.map((DatingVouch v) => v.text), <String>['Gotuje genialnie']);
  });

  test('up to four photos travel with the profile; older apps still find the '
      'first one', () async {
    String jpeg(int shade) => base64Encode(
      img.encodeJpg(
        img.Image(width: 24, height: 24)..clear(img.ColorRgb8(shade, 40, 90)),
      ),
    );
    final List<String> photos = <String>[jpeg(10), jpeg(80), jpeg(160)];
    final DatingProfile p = DatingProfile(
      key: 'k',
      name: 'Ola',
      age: 25,
      gender: DatingGender.woman,
      at: 1,
      photos: photos,
    );
    final Map<String, dynamic> json =
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
    expect(json['ph'], photos.first, reason: 'where older apps look');
    expect(json['phx'], photos.sublist(1));
    expect(DatingProfile.fromJson(json)!.photos, photos);
    expect(DatingProfile.fromJson(json)!.photo, photos.first);

    // An older profile with one photo, and too many photos.
    expect(
      DatingProfile.fromJson(<String, dynamic>{...json}..remove('phx'))!.photos,
      <String>[photos.first],
    );
    expect(
      DatingProfile.fromJson(<String, dynamic>{
        ...json,
        'phx': <String>[for (int i = 0; i < 6; i++) jpeg(i * 30)],
      })!.photos,
      hasLength(kDatingMaxPhotos),
    );

    // The own settings keep them in order.
    final MyDating me = MyDating(photos: List<String>.of(photos));
    expect(
      MyDating.fromJson(jsonDecode(jsonEncode(me.toJson()))).photos,
      photos,
    );
    me.photo = null;
    expect(me.photos, isEmpty);

    // Over the network, each photo is re-encoded and all of them arrive.
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    net.link(ania, darek);
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..adult = true
        ..name = 'Ania'
        ..age = 30
        ..gender = DatingGender.woman
        ..photos.addAll(photos);
    });
    final DatingProfile atDarek = darek.service.toDecide.single.profile;
    expect(atDarek.photos, hasLength(3));
    for (final String ph in atDarek.photos) {
      expect(img.decodeJpg(base64Decode(ph)), isNotNull);
    }
  });

  test('a profile and a cover are padded to whole buckets, at least as many '
      'as asked', () {
    final DatingProfile p = DatingProfile(
      key: 'ania-key',
      name: 'Ania',
      age: 30,
      gender: DatingGender.woman,
      at: 1,
      about: 'Lubię góry',
    );
    int size(Map<String, dynamic> m) => utf8.encode(jsonEncode(m)).length;
    final Map<String, dynamic> real = datingPadded(p.toJson(), minBuckets: 2);
    final Map<String, dynamic> cover = datingPadded(const <String, dynamic>{
      'v': 1,
      'cover': true,
    }, minBuckets: 2);
    expect(size(real), 2 * kDatingBucket);
    expect(size(cover), 2 * kDatingBucket);
    expect(DatingProfile.fromJson(real)!.about, 'Lubię góry');
    expect(cover['cover'], isTrue);

    // A big profile takes as many buckets as it needs.
    final Map<String, dynamic> big = datingPadded(
      DatingProfile(
        key: 'k',
        name: 'Ola',
        age: 25,
        gender: DatingGender.woman,
        at: 1,
        about: 'x' * 5000,
      ).toJson(),
    );
    expect(size(big) % kDatingBucket, 0);
    expect(size(big), 2 * kDatingBucket);
  });

  test('phones on the way cannot read a profile; the one who asks for it '
      'can, and a blocked key gets none', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone darek = _Phone(net, 'darek');
    net
      ..link(ania, bob)
      ..link(bob, darek);
    await bob.service.load();
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..adult = true
        ..name = 'Ania'
        ..age = 30
        ..gender = DatingGender.woman
        ..about = 'Tajemnica-123';
    });
    expect(darek.service.toDecide.single.profile.about, 'Tajemnica-123');

    // Bob passed the lantern on, but nothing he sent or keeps carries the
    // profile in the clear (it never passed him at all, only a request).
    final List<Map<String, dynamic>> lanterns = bob.sent
        .where((Map<String, dynamic> p) => p['type'] == DatingTypes.lantern)
        .toList();
    expect(lanterns, isNotEmpty);
    expect(
      lanterns.every(
        (Map<String, dynamic> p) => DatingLantern.fromJson(p['l']) != null,
      ),
      isTrue,
    );
    expect(
      bob.sent.where(
        (Map<String, dynamic> p) => jsonEncode(p).contains('Tajemnica'),
      ),
      isEmpty,
    );
    expect(
      utf8.decode(bob.disk.files.values.single),
      isNot(contains('Tajemnica')),
    );
    expect(bob.service.toDecide, isEmpty);

    // Ola blocked Darek's dating key before she started: his phone asks for
    // her profile like everyone, hers does not answer him.
    final _Phone ola = _Phone(net, 'ola');
    net.link(ola, bob);
    await ola.service.load();
    await ola.service.block(darek.service.myKey!);
    await ola.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..adult = true
        ..name = 'Ola'
        ..age = 27
        ..gender = DatingGender.woman;
    });
    expect(
      darek.service.toDecide.where((SeenProfile s) => s.profile.name == 'Ola'),
      isEmpty,
    );
    expect(ania.service.toDecide.single.profile.name, 'Ola');
  });

  test('a match from an introduction can thank the matchmaker in currency, '
      'only within one pyramid', () async {
    final _Net net = _Net();
    final _Phone marek = _Phone(net, 'marek', pyramid: 'pyr-marek');
    final _Phone xenia = _Phone(
      net,
      'xenia',
      pyramid: 'pyr-xenia',
      payable: <String>{'pyr-marek'},
    );
    final _Phone yann = _Phone(net, 'yann');
    net
      ..link(marek, xenia)
      ..link(marek, yann);
    await marek.date(name: 'Marek', age: 35, gender: DatingGender.man);
    await xenia.date(
      name: 'Xenia',
      age: 29,
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    await yann.date(name: 'Yann', age: 31, gender: DatingGender.man, hops: 1);
    await marek.service.maybePublish(force: true);
    await xenia.service.maybePublish(force: true);
    await yann.service.maybePublish(force: true);
    final String x = xenia.service.myKey!;
    final String y = yann.service.myKey!;
    expect(await marek.service.introduce(x, y, 'Pasujecie'), isTrue);
    expect(xenia.service.profile(y)!.introPyr, 'pyr-marek');

    // Not before the match.
    expect(xenia.service.canThank(y), isFalse);
    await xenia.service.decide(y, true);
    await yann.service.decide(x, true);
    expect(xenia.service.canThank(y), isTrue);
    // Yann is in no pyramid: no button for him.
    expect(yann.service.canThank(x), isFalse);
    expect(await yann.service.thankMatchmaker(x, 5), isFalse);
    expect(yann.payments, isEmpty);

    expect(await xenia.service.thankMatchmaker(y, 5), isTrue);
    expect(xenia.payments.single, ('pyr-marek', 5, 'Podziękowanie'));
    expect(xenia.service.thanked(y), isTrue);

    // A match without an introduction has nobody to thank.
    expect(marek.service.canThank(x), isFalse);
  });

  test('"Idę na randkę" deadlines in the background service: the alarm is '
      'raised only where it can be, and never twice', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    net.link(ania, bob);
    await ania.service.load();
    await bob.service.load();
    final SafeDate d = (await ania.service.startSafeDate(
      friend: bob.address,
      length: const Duration(hours: 1),
    ))!;

    // A service that cannot raise the alarm (like an old background one)
    // reminds, but leaves the alarm for one that can.
    final DatingService noAlarm = DatingService(
      host: ania,
      disk: ania.disk,
      now: () => net.clock,
    );
    net.clock = d.until + SafeDate.grace.inMilliseconds + 1;
    await noAlarm.backgroundTick();
    expect(ania.shown.last.title, 'Wszystko OK?');
    expect(noAlarm.mySafeDate!.alarmedAt, isNull);

    final List<String> raised = <String>[];
    final DatingService background = DatingService(
      host: ania,
      disk: ania.disk,
      now: () => net.clock,
      raiseAlarm: (String note) async => raised.add(note),
    );
    await background.backgroundTick();
    expect(raised, hasLength(1));
    final int reminders = ania.shown
        .where((RuntimeSystemNotification n) => n.title == 'Wszystko OK?')
        .length;
    expect(reminders, 1, reason: 'the reminder is not repeated');

    // The app's own service reads what the background did: no second alarm.
    await ania.service.tick();
    expect(ania.alarms, isEmpty);
    expect(raised, hasLength(1));
  });

  test('people the dating profile is hidden from are listed for the '
      '„Randkuję” status', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    await ania.service.load();
    await ania.service.saveMine((MyDating m) => m.hiddenFriends.add('200::B1'));
    expect(ania.service.hiddenAddresses(), <String>{
      PeerShareCodec.normalizeAddress('200::b1'),
    });
  });

  test(
    'a lantern of a shape the app never makes, or one too many from a '
    'friend in a day, goes no further; passed-on lanterns are sent once',
    () async {
      final _Net net = _Net();
      final _Phone ania = _Phone(net, 'ania');
      final _Phone bob = _Phone(net, 'bob');
      final _Phone cyryl = _Phone(net, 'cyryl');
      net
        ..link(ania, bob)
        ..link(bob, cyryl);
      await bob.service.load();
      await cyryl.service.load();
      final String key = base64Url.encode(
        (await RelayIdentity.generate()).publicKey,
      );
      final Map<String, dynamic> lantern = DatingLantern.of(
        key: key,
        age: 30,
        gender: DatingGender.woman,
        wants: const DatingWants(),
      ).toJson();
      Future<void> send(String id, Object? l, {int hops = 1}) =>
          ania.send(bob.address, <String, dynamic>{
            'type': DatingTypes.lantern,
            'id': id,
            'hops': hops,
            'path': const <String>[],
            'l': l,
          });
      List<Map<String, dynamic>> passed() => bob.sent
          .where((Map<String, dynamic> p) => p['type'] == DatingTypes.lantern)
          .toList();

      await send('zly-klucz', <String, dynamic>{...lantern, 'k': 5});
      await send('zla-wersja', <String, dynamic>{...lantern, 'v': 2});
      await send('zly-opis', <String, dynamic>{...lantern, 'h': 'AAAA'});
      await send('nic', null);
      expect(passed(), isEmpty);

      // Anything riding along is dropped; it goes on once, not queued, and
      // never further than the app takes a lantern.
      await send('dobra', <String, dynamic>{
        ...lantern,
        'balast': 'x' * 100000,
      }, hops: 5);
      expect(passed().single['l'], lantern);
      expect(passed().single['hops'], 0);
      expect(passed().single[kSendOnceKey], isTrue);

      for (int i = 0; i < kDatingLanternsPerFriendPerDay + 10; i++) {
        await send('fala$i', lantern);
      }
      expect(passed(), hasLength(kDatingLanternsPerFriendPerDay));
      // Refused today, it may still come tomorrow.
      net.clock += 24 * 3600 * 1000 + 1;
      await send('fala${kDatingLanternsPerFriendPerDay + 5}', lantern);
      expect(passed(), hasLength(kDatingLanternsPerFriendPerDay + 1));

      // A message going back never gets more steps than the app gives.
      await cyryl.send(bob.address, <String, dynamic>{
        'type': DatingTypes.back,
        'to': 'dobra',
        'box': const <String, String>{'s': 'x'},
        'ttl': 1000,
      });
      expect(bob.sent.last['type'], DatingTypes.back);
      expect(bob.sent.last['ttl'], 7);
    },
  );

  test('a dating key is answered with a profile only so often a day', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    net.link(ania, darek);
    await ania.date(name: 'Ania', age: 30, gender: DatingGender.woman);
    await darek.date(name: 'Darek', age: 32, gender: DatingGender.man);
    int answers() => ania.sent
        .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back)
        .length;
    for (int i = 0; i < kDatingFetchesPerKeyPerDay + 5; i++) {
      await ania.service.maybePublish(force: true);
    }
    // Her own request for Darek's profile is one of them.
    final int first = answers();
    expect(first, lessThanOrEqualTo(kDatingFetchesPerKeyPerDay + 1));
    expect(first, greaterThan(kDatingFetchesPerKeyPerDay));
    expect(darek.service.toDecide.single.profile.name, 'Ania');
    net.clock += 24 * 3600 * 1000 + 1;
    await ania.service.maybePublish(force: true);
    expect(answers(), first + 1);
  });

  test('a friend the dating profile is hidden from gets no profile, even '
      'when the lantern reaches them through someone else', () async {
    final _Net net = _Net();
    // Phones with dating off ask for a share of the profiles; all of them do.
    final _Phone ania = _Phone(net, 'ania', decoyShare: 1);
    final _Phone bob = _Phone(net, 'bob', decoyShare: 1);
    final _Phone ewa = _Phone(net, 'ewa', decoyShare: 1);
    final _Phone ola = _Phone(net, 'ola', decoyShare: 1);
    net
      ..link(ania, bob)
      ..link(bob, ewa)
      ..link(bob, ola)
      ..link(ania, ewa);
    for (final _Phone p in <_Phone>[ania, bob, ewa, ola]) {
      await p.service.load();
    }
    // Ewa's own weekly lantern tells Ania's phone Ewa's dating key.
    await ewa.service.maybePublish(force: true);
    int answers(_Phone p) => p.received
        .where((Map<String, dynamic> m) => m['type'] == DatingTypes.back)
        .length;

    // Not hidden: Ewa's phone asks for the profile, like every phone, and
    // gets an answer.
    ewa.received.clear();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..adult = true
        ..name = 'Ania'
        ..age = 30
        ..gender = DatingGender.woman;
    });
    expect(answers(ewa), greaterThan(0));

    // Hidden: the lantern still passes Bob to Ewa, but her phone gets no
    // answer.
    ewa.received.clear();
    ola.received.clear();
    await ania.service.saveMine(
      (MyDating m) => m.hiddenFriends.add(ewa.address),
    );
    expect(answers(ewa), 0);
    expect(
      answers(ola),
      greaterThan(0),
      reason: 'everyone else still gets one',
    );
  });
}
