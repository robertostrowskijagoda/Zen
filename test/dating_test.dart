import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
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

/// A question a probing phone got answered: its key, blinding secret, points
/// and the answer.
typedef _Probe = (
  RelayIdentity,
  RelayIdentity,
  List<String>,
  Map<String, dynamic>,
);

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

  /// Turns dating on and sends a lantern (saving alone sends nothing).
  Future<void> date({
    required String name,
    required DatingGender gender,
    Set<DatingGender>? wants,
    int hops = kDatingMaxHops,
  }) async {
    await service.load();
    await service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = name
        ..gender = gender
        ..wants = DatingWants(
          genders: wants ?? DatingGender.values.toSet(),
          hops: hops,
        );
    });
    await service.maybePublish(force: true);
  }

  int backCount() => sent
      .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back)
      .length;

  /// Back messages received that are big enough to be a profile (or a
  /// cover): a match test and its answer are much smaller.
  int profilesIn() => received
      .where(
        (Map<String, dynamic> p) =>
            p['type'] == DatingTypes.back &&
            jsonEncode(p).length > kDatingBucket,
      )
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
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await darek.date(
      name: 'Darek',
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
      'when the match test says the two fit', () async {
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
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    // Ewa dates too, but is a woman and Ania looks for men.
    await ewa.date(
      name: 'Ewa',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await ania.date(
      name: 'Ania',
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

    // Two steps away, but it does not fit Ewa: her phone runs only the
    // small sealed match test, never gets the profile, and the lantern costs
    // the network well under 100 bytes.
    expect(
      ewa.received.any((Map<String, dynamic> p) => p['id'] == lanternId),
      isTrue,
    );
    expect(ewa.backCount(), greaterThan(0));
    expect(ewa.profilesIn(), 0);
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
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ania.service.maybePublish(force: true);
    expect(fred.service.toDecide.single.profile.name, 'Ania');
    expect(fred.service.toDecide.single.distance, 2);
    expect(fred.backCount(), greaterThan(0));
  });

  test('every phone runs the match test; a share of the lanterns that do not '
      'fit is asked for the profile anyway and the answer dropped', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob', decoyShare: 1);
    final _Phone cyryl = _Phone(net, 'cyryl');
    final _Phone ewa = _Phone(net, 'ewa', decoyShare: 1);
    net
      ..link(ania, bob)
      ..link(bob, cyryl)
      ..link(ania, ewa);
    await bob.service.load();
    await cyryl.service.load();
    // Ewa dates, but looks for women only and Ania for men.
    await ewa.date(
      name: 'Ewa',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    expect(bob.profilesIn(), greaterThan(0), reason: 'asked like a dater');
    expect(bob.service.toDecide, isEmpty);
    expect(bob.shown, isEmpty);
    expect(ewa.profilesIn(), greaterThan(0), reason: 'dating on asks alike');
    expect(ewa.service.toDecide, isEmpty);
    expect(cyryl.backCount(), greaterThan(0), reason: 'the match test');
    expect(cyryl.profilesIn(), 0, reason: 'a share of 0 asks for nothing');
  });

  test('preferences fit both ways; the match test tells only whether two '
      'people fit', () async {
    const DatingWants hers = DatingWants(
      genders: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    expect(hers.accepts(gender: DatingGender.man, distance: 1), isTrue);
    expect(hers.accepts(gender: DatingGender.woman, distance: 1), isFalse);
    expect(hers.accepts(gender: DatingGender.man, distance: 2), isFalse);
    expect(
      DatingWants.fromJson(jsonDecode(jsonEncode(hers.toJson()))).genders,
      hers.genders,
    );

    // Ania (a woman looking for men) has a lantern; who fits?
    final Set<String> offer = hers.offerTags(DatingGender.woman);
    Future<bool> fitsHer(DatingGender gender, Set<DatingGender> wants) async {
      final (RelayIdentity, List<String>) q = await DatingMatch.ask(
        DatingWants(genders: wants).seekTags(gender),
        Random(1),
      );
      final (List<String>, List<String>)? a = await DatingMatch.answer(
        jsonDecode(jsonEncode(q.$2)),
        offer,
        Random(2),
      );
      // Always the same number of points, real or filler.
      expect(q.$2, hasLength(DatingMatch.slots));
      expect(a!.$1, hasLength(DatingMatch.slots));
      expect(a.$2, hasLength(DatingMatch.slots));
      final bool fit = await DatingMatch.fits(q.$1, a.$1, a.$2);
      // The proof of fit holds exactly when they fit; a made-up secret
      // proves nothing.
      expect(await DatingMatch.proves(q.$1, q.$2, offer), fit);
      expect(
        await DatingMatch.proves(await RelayIdentity.generate(), q.$2, offer),
        isFalse,
      );
      return fit;
    }

    expect(
      await fitsHer(DatingGender.man, <DatingGender>{DatingGender.woman}),
      isTrue,
    );
    expect(
      await fitsHer(DatingGender.man, DatingGender.values.toSet()),
      isTrue,
    );
    expect(
      await fitsHer(DatingGender.man, <DatingGender>{DatingGender.man}),
      isFalse,
      reason: 'his genders',
    );
    expect(
      await fitsHer(DatingGender.woman, DatingGender.values.toSet()),
      isFalse,
      reason: 'her genders',
    );

    // Fillers only (dating off, or hidden) never fit.
    final (RelayIdentity, List<String>) none = await DatingMatch.ask(
      const <String>{},
      Random(3),
    );
    final (List<String>, List<String>)? a = await DatingMatch.answer(
      none.$2,
      offer,
      Random(4),
    );
    expect(await DatingMatch.fits(none.$1, a!.$1, a.$2), isFalse);
    final (RelayIdentity, List<String>) man = await DatingMatch.ask(
      const DatingWants().seekTags(DatingGender.man),
      Random(5),
    );
    final (List<String>, List<String>)? off = await DatingMatch.answer(
      man.$2,
      const <String>{},
      Random(6),
    );
    expect(await DatingMatch.fits(man.$1, off!.$1, off.$2), isFalse);
    // Nothing in the answer is a tag in the clear.
    expect(jsonEncode(<Object>[a.$1, a.$2]), isNot(contains('k>m')));
    expect(await DatingMatch.answer(<String>['x'], offer, Random(7)), isNull);

    // The proof of a lantern's answer: the same on both sides, nobody else.
    final RelayIdentity lantern = await RelayIdentity.generate();
    final RelayIdentity asker = await RelayIdentity.generate();
    final RelayIdentity eve = await RelayIdentity.generate();
    final String proof = await datingLanternProof(
      lantern,
      asker.publicKey,
      'id1',
      'ania-key',
    );
    expect(
      await datingLanternProof(asker, lantern.publicKey, 'id1', 'ania-key'),
      proof,
    );
    expect(
      await datingLanternProof(eve, lantern.publicKey, 'id1', 'ania-key'),
      isNot(proof),
    );
    expect(
      await datingLanternProof(asker, lantern.publicKey, 'id1', 'eve-key'),
      isNot(proof),
    );
  });

  test('a lantern carries only a new one-off key, with dating on or off; it '
      'goes out only on the weekly schedule', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cyryl = _Phone(net, 'cyryl');
    net
      ..link(ania, cyryl)
      ..link(bob, cyryl);
    await cyryl.service.load();
    await bob.service.load();
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await bob.service.maybePublish(force: true);
    List<Map<String, dynamic>> lanterns(_Phone p) => <Map<String, dynamic>>[
      for (final Map<String, dynamic> m in p.sent)
        if (m['type'] == DatingTypes.lantern) m,
    ];

    // Changing the profile or turning dating off sends nothing.
    final int before = lanterns(ania).length;
    await ania.service.saveMine((MyDating m) => m.about = 'Nowe');
    await ania.service.saveMine((MyDating m) => m.enabled = false);
    await ania.service.maybePublish();
    expect(lanterns(ania), hasLength(before));
    // A week later: a new lantern, nothing like the last one.
    net.clock += kDatingPublishEvery.inMilliseconds;
    await ania.service.maybePublish();
    await bob.service.maybePublish(force: true);
    expect(lanterns(ania), hasLength(before + 1));

    final Map<String, dynamic> a1 = lanterns(ania).first;
    final Map<String, dynamic> a2 = lanterns(ania).last;
    final Map<String, dynamic> b1 = lanterns(bob).first;
    for (final Map<String, dynamic> l in <Map<String, dynamic>>[a1, a2, b1]) {
      expect((l['l'] as Map).keys.toSet(), <String>{'v', 'k'});
      expect(jsonEncode(l['l']).length, lessThan(80));
      expect(DatingLantern.fromJson(l['l']), isNotNull);
    }
    expect(a1['id'], isNot(a2['id']));
    expect(a1['l']['k'], isNot(a2['l']['k']));
    expect(a1['l']['k'], isNot(ania.service.myKey));
    expect(jsonEncode(lanterns(cyryl)), isNot(contains(ania.service.myKey)));

    // Anything this app never makes is not a lantern.
    final Map<String, dynamic> json = a1['l'] as Map<String, dynamic>;
    Map<String, dynamic> withField(String field, Object? value) =>
        <String, dynamic>{...json, field: value};
    expect(DatingLantern.fromJson(withField('v', 3)), isNull);
    expect(DatingLantern.fromJson(withField('k', 5)), isNull);
    expect(DatingLantern.fromJson(withField('k', 'x' * 65)), isNull);
    expect(DatingLantern.fromJson(withField('k', 'AAAA')), isNull);
    expect(DatingLantern.fromJson(withField('h', 'AAAA'))!.toJson(), json);
    expect(DatingLantern.fromJson('x'), isNull);
  });

  test('a phone with dating off never fits; hidden people never see a '
      'profile', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone ewa = _Phone(net, 'ewa');
    net
      ..link(ania, bob)
      ..link(bob, ewa);
    await bob.service.load();
    await ewa.date(name: 'Ewa', gender: DatingGender.woman);
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
      reason: 'a phone with dating off shows nothing',
    );

    // Ania hides from Ewa: the lantern passes Bob, but Ewa never sees the
    // profile.
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..hiddenFriends.add(ewa.address);
    });
    await ania.service.maybePublish(force: true);
    expect(ewa.service.toDecide, isEmpty);
    await ewa.service.maybePublish(force: true);
    expect(ewa.service.toDecide, isEmpty);
    expect(ania.service.toDecide.single.profile.name, 'Ewa');

    // Preferences count both ways: a profile for men only skips Ewa.
    final _Phone ola = _Phone(net, 'ola');
    net.link(ola, bob);
    await ola.date(
      name: 'Ola',
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
    await marta.date(name: 'Marek', gender: DatingGender.man);
    await xenia.date(
      name: 'Xenia',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    await yann.date(name: 'Yann', gender: DatingGender.man, hops: 1);
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
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await darek.date(name: 'Darek', gender: DatingGender.man);
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
    // The approved word travels with the profile asked for after the next
    // lantern.
    await ania.service.maybePublish(force: true);
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
    await mia.date(name: 'Mia', gender: DatingGender.woman);
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await ewa.date(name: 'Ewa', gender: DatingGender.woman);
    await darek.date(name: 'Darek', gender: DatingGender.man);
    await fred.date(name: 'Fred', gender: DatingGender.man);
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
    await ania.service.maybePublish(force: true);
    expect(ania.service.isMinorOff(miaKey), isTrue);
    expect(sees(ania), isFalse);
    expect(sees(darek), isTrue, reason: 'one report is not enough');

    // The same reporter again counts once.
    await ania.service.maybePublish(force: true);
    expect(sees(darek), isTrue);

    // A second, independent reporter: the profile goes for everybody who
    // sees the packages of both.
    await ewa.service.reportMinor(miaKey);
    await ewa.service.maybePublish(force: true);
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
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await darek.date(name: 'Darek', gender: DatingGender.man);
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
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await darek.date(name: 'Darek', gender: DatingGender.man);
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
    await ania.service.maybePublish(force: true);
    final List<DatingVouch> seen = darek.service
        .profile(aniaKey)!
        .profile
        .vouches;
    expect(seen.map((DatingVouch v) => v.text), <String>['Gotuje genialnie']);
  });

  test('up to four photos travel with the profile', () async {
    String jpeg(int shade) => base64Encode(
      img.encodeJpg(
        img.Image(width: 24, height: 24)..clear(img.ColorRgb8(shade, 40, 90)),
      ),
    );
    final List<String> photos = <String>[jpeg(10), jpeg(80), jpeg(160)];
    final DatingProfile p = DatingProfile(
      key: 'k',
      name: 'Ola',
      gender: DatingGender.woman,
      at: 1,
      photos: photos,
    );
    final Map<String, dynamic> json =
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
    expect(json['ph'], photos);
    expect(DatingProfile.fromJson(json)!.photos, photos);
    expect(DatingProfile.fromJson(json)!.photo, photos.first);

    // Too many photos.
    expect(
      DatingProfile.fromJson(<String, dynamic>{
        ...json,
        'ph': <String>[for (int i = 0; i < 6; i++) jpeg(i * 30)],
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
    await darek.date(name: 'Darek', gender: DatingGender.man);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..photos.addAll(photos);
    });
    await ania.service.maybePublish(force: true);
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
    await darek.date(name: 'Darek', gender: DatingGender.man);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..about = 'Tajemnica-123';
    });
    await ania.service.maybePublish(force: true);
    expect(darek.service.toDecide.single.profile.about, 'Tajemnica-123');

    // Bob passed the lantern on, but nothing he sent or keeps carries the
    // profile in the clear (it passed him only sealed).
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

    // Ola blocked Darek's dating key before she started: his phone runs the
    // match test like everyone, and never fits.
    final _Phone ola = _Phone(net, 'ola');
    net.link(ola, bob);
    await ola.service.load();
    await ola.service.block(darek.service.myKey!);
    await ola.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ola'
        ..gender = DatingGender.woman;
    });
    await ola.service.maybePublish(force: true);
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
    await marek.date(name: 'Marek', gender: DatingGender.man);
    await xenia.date(
      name: 'Xenia',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    await yann.date(name: 'Yann', gender: DatingGender.man, hops: 1);
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
      final Map<String, dynamic> lantern = DatingLantern(key).toJson();
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
      await send('zla-wersja', <String, dynamic>{...lantern, 'v': 3});
      await send('krotki-klucz', <String, dynamic>{...lantern, 'k': 'AAAA'});
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

  test('a dating key is answered with a match test and a profile only so '
      'often a day', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    net.link(ania, darek);
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await darek.date(name: 'Darek', gender: DatingGender.man);
    int answers() => ania.sent
        .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back)
        .length;
    // Her own match test and request for Darek's profile.
    final int start = answers();
    expect(start, 2);
    const int weeks = kDatingFetchesPerKeyPerDay + 5;
    for (int i = 0; i < weeks; i++) {
      await ania.service.maybePublish(force: true);
    }
    // One match test per lantern; profiles only up to the daily limit.
    expect(answers() - start, weeks + kDatingFetchesPerKeyPerDay);
    expect(darek.service.toDecide.single.profile.name, 'Ania');
    net.clock += 24 * 3600 * 1000 + 1;
    final int before = answers();
    await ania.service.maybePublish(force: true);
    expect(answers(), before + 2, reason: 'a match test and a profile');
  });

  test('a modified friend asking with a new key every time gets only a few '
      'answers per lantern, no profile without a proof of fit, and nothing '
      'when hidden', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone eve = _Phone(net, 'eve');
    net.link(ania, eve);
    await eve.service.load();
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman;
    });
    int marks = 0;
    late String lanternId;
    late Uint8List lanternKey;
    Future<void> publish() async {
      await ania.service.maybePublish(force: true);
      final Map<String, dynamic> l = ania.sent.lastWhere(
        (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
      );
      lanternId = l['id'] as String;
      lanternKey = decodeRelayKey((l['l'] as Map)['k'])!;
    }

    // Sends [payload] sealed to the lantern from [me], as Eve's phone would,
    // and opens what comes back.
    Future<Map<String, dynamic>?> ask(
      RelayIdentity me,
      Map<String, dynamic> payload,
    ) async {
      final int before = eve.received.length;
      await eve.send(ania.address, <String, dynamic>{
        'type': DatingTypes.back,
        'to': lanternId,
        'm': 'mark-${marks++}',
        'box': await DatingBox.seal(
          me: me,
          recipient: lanternKey,
          payload: payload,
        ),
        'ttl': 7,
      });
      final List<Map<String, dynamic>> back = <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in eve.received.sublist(before))
          if (m['type'] == DatingTypes.back) m,
      ];
      if (back.isEmpty) {
        return null;
      }
      return (await DatingBox.open(me: me, box: back.single['box']))?.$2;
    }

    // Probing: a new key for every question, as a friend and as if passed on.
    // Returns the answered questions (key, blinding secret, points, answer).
    Future<List<_Probe>> probe(int times) async {
      final List<_Probe> got = <_Probe>[];
      for (int i = 0; i < times; i++) {
        final RelayIdentity fresh = await RelayIdentity.generate();
        final (RelayIdentity, List<String>) q = await DatingMatch.ask(
          const DatingWants().seekTags(DatingGender.man),
          Random(i),
        );
        final Map<String, dynamic>? a = await ask(fresh, <String, dynamic>{
          'k': 'match',
          'id': lanternId,
          'd': i.isEven ? 1 : 2,
          'q': q.$2,
        });
        if (a != null) {
          got.add((fresh, q.$1, q.$2, a));
        }
      }
      return got;
    }

    await publish();
    final List<_Probe> answered = await probe(40);
    expect(
      answered,
      hasLength(kDatingMatchFarPerFriend),
      reason:
          'keys are free; answers per lantern and friend are not (her '
          "own phone already asked once as herself, so no other key does)",
    );
    // A new secret for every answer: no two answers can be put together.
    expect(answered[1].$4['o'], isNot(answered[2].$4['o']));
    // A man looking for anyone fits Ania (a woman looking for anyone).
    final _Probe far = answered.first;
    expect(await DatingMatch.fits(far.$2, far.$4['r'], far.$4['o']), isTrue);

    // Without a proof of fit (a made-up secret) only a cover comes back.
    final Map<String, dynamic>? cover = await ask(far.$1, <String, dynamic>{
      'k': 'fetch',
      'id': lanternId,
      'a': far.$4['a'],
      'b': (await RelayIdentity.generate()).toJson(),
    });
    expect((cover!['p'] as Map)['cover'], isTrue);
    // The same answer cannot be used twice.
    expect(
      await ask(far.$1, <String, dynamic>{
        'k': 'fetch',
        'id': lanternId,
        'a': far.$4['a'],
        'b': far.$2.toJson(),
      }),
      isNull,
    );
    // With the proof: the profile, as for anyone who fits.
    final _Probe other = answered.last;
    final Map<String, dynamic>? real = await ask(other.$1, <String, dynamic>{
      'k': 'fetch',
      'id': lanternId,
      'a': other.$4['a'],
      'b': other.$2.toJson(),
    });
    expect((real!['p'] as Map)['n'], 'Ania');

    // Hidden from Eve: whatever keys she asks with, she never fits and gets
    // no profile, even with a valid proof.
    await ania.service.saveMine(
      (MyDating m) => m.hiddenFriends.add(eve.address),
    );
    await publish();
    final List<_Probe> hidden = await probe(40);
    expect(hidden, hasLength(kDatingMatchFarPerFriend));
    for (final _Probe h in hidden) {
      expect(await DatingMatch.fits(h.$2, h.$4['r'], h.$4['o']), isFalse);
    }
    final Map<String, dynamic>? none =
        await ask(hidden.last.$1, <String, dynamic>{
          'k': 'fetch',
          'id': lanternId,
          'a': hidden.last.$4['a'],
          'b': hidden.last.$2.toJson(),
        });
    expect((none!['p'] as Map)['cover'], isTrue);
  });

  test('a friend the dating profile is hidden from never fits, even when the '
      'lantern reaches them through someone else', () async {
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
    await bob.service.load();
    // Ewa and Ola both date and both fit Ania (and each other: so the
    // checks below look for Ania's profile on Ewa's phone, not any).
    await ewa.date(name: 'Ewa', gender: DatingGender.woman);
    await ola.date(name: 'Ola', gender: DatingGender.woman);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..hiddenFriends.add(ewa.address);
    });
    // The first lantern reaches Ewa through Bob first, then from Ania
    // herself: the profile is dropped on Ewa's phone, and her match test
    // from one step away tells Ania's phone Ewa's dating key.
    await ania.service.maybePublish(force: true);
    expect(ewa.service.profile(ania.service.myKey!), isNull);
    expect(ola.service.toDecide.single.profile.name, 'Ania');

    // From now on Ewa never fits — directly or through Bob — and gets no
    // profile at all; Ola still does.
    ewa.received.clear();
    ola.received.clear();
    await ania.service.maybePublish(force: true);
    expect(
      ewa.received.where(
        (Map<String, dynamic> m) => m['type'] == DatingTypes.lantern,
      ),
      hasLength(2),
      reason: 'the same lantern as everyone, directly and through Bob',
    );
    expect(ewa.profilesIn(), 0);
    expect(ewa.service.profile(ania.service.myKey!), isNull);
    expect(ola.profilesIn(), greaterThan(0));
  });
}
