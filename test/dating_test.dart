import 'dart:convert';
import 'dart:typed_data';

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
  _Phone(this.net, this.name, {this.pyramid, this.payable = const <String>{}})
    : address = PeerShareCodec.normalizeAddress(
        '200::${(0xb0 + net.phones.length).toRadixString(16)}',
      ) {
    net.phones[address] = this;
    service = DatingService(
      host: this,
      disk: disk,
      now: () => net.clock,
      raiseAlarm: (String note) async => alarms.add(note),
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

  test('profiles travel 3 steps through phones without dating; likes, a '
      'match and messages go back sealed', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cyryl = _Phone(net, 'cyryl');
    final _Phone darek = _Phone(net, 'darek');
    net
      ..link(ania, bob)
      ..link(bob, cyryl)
      ..link(cyryl, darek);
    await bob.service.load();
    await cyryl.service.load();
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
    // Darek's phone was not on dating yet when Ania's package passed.
    await ania.service.maybePublish(force: true);

    final SeenProfile atDarek = darek.service.toDecide.single;
    expect(atDarek.profile.name, 'Ania');
    expect(atDarek.distance, 3);
    expect(atDarek.path, <String>['cyryl', 'bob']);
    expect(atDarek.friend, cyryl.address);
    expect(ania.service.toDecide.single.profile.name, 'Darek');
    // The phones in between passed it on but kept nothing.
    expect(bob.service.toDecide, isEmpty);
    expect(cyryl.service.toDecide, isEmpty);
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

  test('phones with dating off send cover packages that look the same and '
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
        (Map<String, dynamic> p) => p['type'] == DatingTypes.package,
      ),
      isNotEmpty,
    );
    expect(
      ewa.service.toDecide,
      isEmpty,
      reason: 'a cover package shows nothing',
    );

    // Ania hides from Ewa: the profile passes Bob, but Ewa never sees it.
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

  test('a sealed package opens only with its key; its size does not tell a '
      'profile from a cover', () async {
    final DatingProfile p = DatingProfile(
      key: 'ania-key',
      name: 'Ania',
      age: 30,
      gender: DatingGender.woman,
      at: 1,
      about: 'Lubię góry',
    );
    final (Uint8List, Map<String, dynamic>) real = await DatingPackageSeal.seal(
      sender: 'ania-key',
      packageId: 'pkg1',
      content: p.toJson(),
      minBuckets: 2,
    );
    final (Uint8List, Map<String, dynamic>) cover =
        await DatingPackageSeal.seal(
          sender: 'bob-key',
          packageId: 'pkg2',
          content: const <String, dynamic>{'v': 1, 'cover': true},
          minBuckets: 2,
        );
    expect(DatingPackageSeal.isSealed(real.$2), isTrue);
    expect(DatingPackageSeal.senderOf(real.$2), 'ania-key');
    expect(jsonEncode(real.$2), isNot(contains('Ania')));
    expect(jsonEncode(real.$2), isNot(contains('góry')));
    expect((real.$2['c'] as String).length, (cover.$2['c'] as String).length);

    final Map<String, dynamic>? opened = await DatingPackageSeal.open(
      body: real.$2,
      packageId: 'pkg1',
      key: real.$1,
    );
    expect(DatingProfile.fromJson(opened)!.about, 'Lubię góry');
    expect(
      await DatingPackageSeal.open(
        body: real.$2,
        packageId: 'pkg1',
        key: cover.$1,
      ),
      isNull,
    );
    expect(
      await DatingPackageSeal.open(
        body: real.$2,
        packageId: 'other',
        key: real.$1,
      ),
      isNull,
      reason: 'bound to its package',
    );
    final Map<String, dynamic>? c = await DatingPackageSeal.open(
      body: cover.$2,
      packageId: 'pkg2',
      key: cover.$1,
    );
    expect(c!['cover'], isTrue);
  });

  test('phones on the way cannot read a profile; the one who asks for the '
      'key can, and a blocked key gets none', () async {
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

    // Bob passed it on and asked for the key like everybody, but nothing he
    // sent or keeps carries the profile in the clear.
    final List<Map<String, dynamic>> packages = bob.sent
        .where((Map<String, dynamic> p) => p['type'] == DatingTypes.package)
        .toList();
    expect(packages, isNotEmpty);
    expect(
      packages.every(
        (Map<String, dynamic> p) => DatingPackageSeal.isSealed(p['p']),
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
    // the key of her package like everyone, hers does not answer him.
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
    'a package of a shape the app never makes, or one too many from a '
    'friend in a day, goes no further; passed-on packages are sent once',
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
      Map<String, dynamic> body({int bytes = 2 * DatingPackageSeal.bucket}) =>
          <String, dynamic>{
            'v': 2,
            'k': key,
            'n': base64Url.encode(Uint8List(12)),
            'c': base64Url.encode(Uint8List(bytes)),
          };
      Future<void> package(String id, Map<String, dynamic> p) =>
          ania.send(bob.address, <String, dynamic>{
            'type': DatingTypes.package,
            'id': id,
            'hops': 2,
            'path': const <String>[],
            'p': p,
          });
      List<Map<String, dynamic>> passed() => bob.sent
          .where((Map<String, dynamic> p) => p['type'] == DatingTypes.package)
          .toList();

      await package('zly-rozmiar', body(bytes: 5000));
      await package(
        'za-duzy',
        body(bytes: DatingPackageSeal.maxBytes + DatingPackageSeal.bucket),
      );
      await package('zly-klucz', <String, dynamic>{
        ...body(),
        'k': 'nie-klucz',
      });
      expect(passed(), isEmpty);

      // Anything riding along is dropped; it goes on once, not queued.
      await package('dobry', <String, dynamic>{
        ...body(),
        'balast': 'x' * 100000,
      });
      expect(passed().single['p'], body());
      expect(passed().single[kSendOnceKey], isTrue);

      for (int i = 0; i < kDatingPackagesPerFriendPerDay + 10; i++) {
        await package('fala$i', body());
      }
      expect(passed(), hasLength(kDatingPackagesPerFriendPerDay));
      // Refused today, it may still come tomorrow.
      net.clock += 24 * 3600 * 1000 + 1;
      await package('fala${kDatingPackagesPerFriendPerDay + 5}', body());
      expect(passed(), hasLength(kDatingPackagesPerFriendPerDay + 1));

      // A message going back never gets more steps than the app gives.
      await cyryl.send(bob.address, <String, dynamic>{
        'type': DatingTypes.back,
        'to': 'dobry',
        'box': const <String, String>{'s': 'x'},
        'ttl': 1000,
      });
      expect(bob.sent.last['type'], DatingTypes.back);
      expect(bob.sent.last['ttl'], 7);
    },
  );

  test('a friend the dating profile is hidden from gets no key for it, even '
      'when the package reaches them through someone else', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone ewa = _Phone(net, 'ewa');
    final _Phone ola = _Phone(net, 'ola');
    net
      ..link(ania, bob)
      ..link(bob, ewa)
      ..link(bob, ola)
      ..link(ania, ewa);
    for (final _Phone p in <_Phone>[ania, bob, ewa, ola]) {
      await p.service.load();
    }
    // Ewa's own weekly package tells Ania's phone Ewa's dating key.
    await ewa.service.maybePublish(force: true);
    int answers(_Phone p) => p.received
        .where((Map<String, dynamic> m) => m['type'] == DatingTypes.back)
        .length;

    // Not hidden: Ewa's phone asks for the key, like every phone, and gets it.
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

    // Hidden: the package still passes Bob to Ewa, but her phone gets no key.
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
