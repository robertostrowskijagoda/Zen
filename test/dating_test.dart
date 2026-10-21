import 'dart:convert';

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
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// A question a probing phone got answered: its key, the wishes it would
/// prove a fit with, and the answer.
typedef _Probe = (RelayIdentity, String, Map<String, dynamic>);

/// Asks the holder of the lantern [id] for its keys, as [phone]'s app would
/// through its friend [next] (with [mark] for the answer), and returns them
/// (X25519, hybrid), checked against the lantern's [hash] when given.
Future<(Uint8List, Uint8List)> _lanternKeys(
  _Phone phone,
  _Phone next,
  String id,
  String mark, {
  String? hash,
}) async {
  final int before = phone.received.length;
  await phone.send(next.address, <String, dynamic>{
    'type': DatingTypes.back,
    'to': id,
    'm': mark,
    'box': const <String, dynamic>{'lk': 1},
    'ttl': 7,
    'n': 1,
  });
  final Map<String, dynamic> back = phone.received
      .sublist(before)
      .lastWhere((Map<String, dynamic> m) => m['type'] == DatingTypes.back);
  final Map<dynamic, dynamic> keys =
      (back['box'] as Map<dynamic, dynamic>)['lkr'] as Map<dynamic, dynamic>;
  final Uint8List x = decodeRelayKey(keys['k'])!;
  final Uint8List pq = decodeHybridPublicKey(keys['q'])!;
  if (hash != null) {
    expect(datingLanternHash(x, pq), hash);
  }
  return (x, pq);
}

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  final Map<String, Set<String>> friends = <String, Set<String>>{};
  int clock = 1000000;

  void link(_Phone a, _Phone b) {
    (friends[a.address] ??= <String>{}).add(b.address);
    (friends[b.address] ??= <String>{}).add(a.address);
  }

  /// [a] opened a gate to [b] (an introduction that came through): both
  /// phones count the other as a person across a gate.
  void gate(_Phone a, _Phone b) {
    a.gates.add(b.address);
    b.gates.add(a.address);
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
      gateContacts: () => gates,
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

  /// People across a gate this person opened (or who opened one to them).
  final Set<String> gates = <String>{};
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
    DatingIntent intent = DatingIntent.dates,
    Set<DatingGender> friendGenders = kDatingAllGenders,
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
          intent: intent,
          friendGenders: friendGenders,
        );
    });
    await service.maybePublish(force: true);
  }

  int backCount() => sent
      .where((Map<String, dynamic> p) => p['type'] == DatingTypes.back)
      .length;

  /// Back messages received that are big enough to be a profile (or a
  /// cover, or a part of one): match tests and their answers are much
  /// smaller.
  int profilesIn() => received
      .where(
        (Map<String, dynamic> p) =>
            p['type'] == DatingTypes.back &&
            jsonEncode(p).length > kDatingCoreBytes,
      )
      .length;

  /// Names of the profiles waiting for a decision here.
  Set<String> names() => <String>{
    for (final SeenProfile s in service.toDecide) s.profile.name,
  };
}

/// A small JPEG of one shade (base64).
String _jpeg(int shade) => base64Encode(
  img.encodeJpg(
    img.Image(width: 24, height: 24)..clear(img.ColorRgb8(shade, 40, 90)),
  ),
);

void main() {
  test('a sealed box opens only for its recipient and tells who sent it; to '
      'a hybrid key it is post-quantum hybrid, with a fresh KEM every '
      'time', () async {
    final RelayIdentity a = await RelayIdentity.generateHybrid();
    final RelayIdentity b = await RelayIdentity.generateHybrid();
    final RelayIdentity eve = await RelayIdentity.generateHybrid();
    Future<Map<String, String>> seal() => DatingBox.seal(
      me: a,
      recipient: b.publicKey,
      recipientPq: b.pqPublicKey,
      payload: <String, dynamic>{'k': 'msg', 't': 'hej'},
    );
    final Map<String, String> box = await seal();
    expect(DatingBox.isHybrid(box), isTrue);
    expect(
      jsonEncode(box),
      isNot(contains(base64Url.encode(a.publicKey))),
      reason: 'the sender is hidden',
    );
    final (Uint8List, Map<String, dynamic>)? opened = await DatingBox.open(
      me: b,
      box: box,
    );
    expect(base64Url.encode(opened!.$1), base64Url.encode(a.publicKey));
    expect(opened.$2['t'], 'hej');
    expect(await DatingBox.open(me: eve, box: box), isNull);
    // Without the hybrid half of the key it does not open at all.
    expect(
      await DatingBox.open(
        me: RelayIdentity(privateKey: b.privateKey, publicKey: b.publicKey),
        box: box,
      ),
      isNull,
    );
    // Changed on the way: refused.
    final String x = box['x']!;
    final Map<String, String> bent = <String, String>{
      ...box,
      'x': '${x.substring(0, 10)}${x[10] == 'A' ? 'B' : 'A'}${x.substring(11)}',
    };
    expect(await DatingBox.open(me: b, box: bent), isNull);
    // Two boxes to one person share nothing a phone on the way could link.
    final Map<String, String> again = await seal();
    expect(again['c'], isNot(box['c']));
    expect(again['e'], isNot(box['e']));
    expect(again['x']!.length, box['x']!.length);

    // To a lantern's small classical key: no KEM, and it still opens.
    final RelayIdentity lantern = await RelayIdentity.generate();
    final Map<String, String> q = await DatingBox.seal(
      me: a,
      recipient: lantern.publicKey,
      payload: <String, dynamic>{'k': 'match'},
    );
    expect(DatingBox.isHybrid(q), isFalse);
    expect((await DatingBox.open(me: lantern, box: q))!.$2['k'], 'match');

    // The pair's own key: both sides get the same from their two "Tak"s.
    final (String, Uint8List) ab = await datingPairEncapsulate(b.pqPublicKey!);
    final (String, Uint8List) ba = await datingPairEncapsulate(a.pqPublicKey!);
    final Uint8List? atB = await datingPairDecapsulate(b, ab.$1);
    final Uint8List? atA = await datingPairDecapsulate(a, ba.$1);
    expect(atB, ab.$2);
    expect(atA, ba.$2);
    expect(await datingPairDecapsulate(eve, ab.$1), isNot(ab.$2));
    final String ka = base64Url.encode(a.publicKey);
    final String kb = base64Url.encode(b.publicKey);
    final Uint8List onA = datingPairKey(
      myKey: ka,
      theirKey: kb,
      mine: ab.$2,
      theirs: atA!,
    );
    final Uint8List onB = datingPairKey(
      myKey: kb,
      theirKey: ka,
      mine: ba.$2,
      theirs: atB!,
    );
    expect(onA, onB);
    expect(
      datingMessageMac(onA, 'id1', 'hej'),
      datingMessageMac(onB, 'id1', 'hej'),
    );
    expect(
      datingMessageMac(onA, 'id1', 'hej!'),
      isNot(datingMessageMac(onB, 'id1', 'hej')),
    );
  });

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

  test('a lantern goes 3 steps (no gate needed) and no further; "Jak daleko '
      'chcesz widzieć" narrows it both ways', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cyryl = _Phone(net, 'cyryl');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone zenek = _Phone(net, 'zenek');
    net
      ..link(ania, bob)
      ..link(bob, cyryl)
      ..link(cyryl, darek)
      ..link(darek, zenek);
    await bob.service.load();
    await cyryl.service.load();
    await darek.date(
      name: 'Darek',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await zenek.date(
      name: 'Zenek',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await darek.service.maybePublish(force: true);
    final String lanternId =
        ania.sent.lastWhere(
              (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
            )['id']
            as String;

    // Three steps away: no gate needed.
    final SeenProfile atDarek = darek.service.toDecide.single;
    expect(atDarek.profile.name, 'Ania');
    expect(atDarek.distance, 3);
    expect(atDarek.gate, isFalse);
    expect(atDarek.path, <String>['cyryl', 'bob']);
    expect(ania.names(), <String>{'Darek'});
    // Four steps away: the lantern never arrives.
    expect(
      zenek.received.where((Map<String, dynamic> p) => p['id'] == lanternId),
      isEmpty,
    );
    expect(zenek.service.toDecide, isEmpty);
    for (final _Phone p in <_Phone>[ania, bob, cyryl, darek, zenek]) {
      for (final Map<String, dynamic> l in p.sent.where(
        (Map<String, dynamic> m) => m['type'] == DatingTypes.lantern,
      )) {
        expect((l['path'] as List).length, lessThanOrEqualTo(2));
        expect(jsonEncode(l['l']).length, lessThan(100));
      }
    }

    // Two steps at most, on Ania's side: someone three steps away does not
    // fit any more (her test is closed), and she asks with fillers only.
    await ania.service.saveMine(
      (MyDating m) => m.wants = const DatingWants(
        genders: <DatingGender>{DatingGender.man},
        hops: 2,
      ),
    );
    final _Phone emil = _Phone(net, 'emil');
    net.link(emil, cyryl);
    await emil.date(
      name: 'Emil',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ania.service.maybePublish(force: true);
    expect(emil.service.toDecide, isEmpty);
    expect(ania.names(), isNot(contains('Emil')));
    // And on the asker's side: two steps is too far for someone who looks
    // only among friends.
    final _Phone filip = _Phone(net, 'filip');
    net.link(filip, bob);
    await filip.date(
      name: 'Filip',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
      hops: 1,
    );
    await ania.service.maybePublish(force: true);
    expect(filip.service.toDecide, isEmpty);
    expect(ania.names(), isNot(contains('Filip')));
    expect(datingReachLabel(kDatingRangeGates), 'Dalej przez otwarte bramy');
  });

  test('across an opened gate lanterns go on, marked so: people there are '
      'seen only with "dalej przez otwarte bramy"; strangers send '
      'nothing', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone xawery = _Phone(net, 'xawery');
    final _Phone yorik = _Phone(net, 'yorik');
    final _Phone obcy = _Phone(net, 'obcy');
    net
      ..link(xawery, yorik)
      // Ania opened a gate to Xawery (they are not friends).
      ..gate(ania, xawery);
    await xawery.date(
      name: 'Xawery',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
      hops: kDatingRangeGates,
    );
    await yorik.date(
      name: 'Yorik',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await xawery.service.maybePublish(force: true);
    // Three steps is her reach: across the gate is further.
    expect(ania.service.toDecide, isEmpty);
    expect(xawery.service.toDecide, isEmpty);

    await ania.service.saveMine(
      (MyDating m) => m.wants = const DatingWants(
        genders: <DatingGender>{DatingGender.man},
        hops: kDatingRangeGates,
      ),
    );
    await ania.service.maybePublish(force: true);
    await xawery.service.maybePublish(force: true);
    await yorik.service.maybePublish(force: true);
    final SeenProfile atAnia = ania.service.toDecide.single;
    expect(atAnia.profile.name, 'Xawery');
    expect(atAnia.gate, isTrue);
    expect(atAnia.reach, kDatingRangeGates);
    expect(xawery.service.toDecide.single.profile.name, 'Ania');
    // Yorik looks three steps: a way across a gate is too far for him, and
    // the phones on the way, not Ania, say it crossed one.
    expect(ania.names(), isNot(contains('Yorik')));
    expect(yorik.service.toDecide, isEmpty);
    expect(
      yorik.received.any(
        (Map<String, dynamic> m) =>
            m['type'] == DatingTypes.lantern && m['g'] == true,
      ),
      isTrue,
    );

    // Someone who is neither a friend nor across a gate is not listened to.
    await obcy.service.load();
    final int before = ania.sent.length;
    await obcy.send(ania.address, <String, dynamic>{
      'type': DatingTypes.lantern,
      'id': 'obcy-1',
      'hops': 2,
      'path': const <String>[],
      'l': DatingLantern(base64Url.encode(List<int>.filled(32, 1))).toJson(),
    });
    expect(ania.sent, hasLength(before));
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

  test('preferences fit both ways; the match test is a sealed offer of a few '
      'bits; the proof of a lantern\'s answer is a MAC only the two know', () {
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
    final String offer = DatingMatch.bits(hers.offerTags(DatingGender.woman));
    bool fitsHer(DatingGender gender, Set<DatingGender> wants) =>
        DatingMatch.fits(
          DatingMatch.bits(DatingWants(genders: wants).seekTags(gender)),
          offer,
        );
    expect(
      fitsHer(DatingGender.man, <DatingGender>{DatingGender.woman}),
      isTrue,
    );
    expect(fitsHer(DatingGender.man, DatingGender.values.toSet()), isTrue);
    expect(
      fitsHer(DatingGender.man, <DatingGender>{DatingGender.man}),
      isFalse,
      reason: 'his genders',
    );
    expect(
      fitsHer(DatingGender.woman, DatingGender.values.toSet()),
      isFalse,
      reason: 'her genders',
    );

    // A fixed universe of 18 tags; every offer and wish is 18 bits, so every
    // answer is the same size, real or empty (dating off, hidden).
    expect(DatingMatch.universe, hasLength(18));
    expect(DatingMatch.universe.toSet(), hasLength(18));
    expect(
      DatingMatch.universe.toSet(),
      containsAll(
        const DatingWants(
          intent: DatingIntent.both,
        ).offerTags(DatingGender.other),
      ),
    );
    expect(offer, hasLength(18));
    expect(DatingMatch.none, hasLength(18));
    expect(DatingMatch.fits(DatingMatch.none, offer), isFalse);
    expect(
      DatingMatch.fits(
        DatingMatch.bits(const DatingWants().seekTags(DatingGender.man)),
        DatingMatch.none,
      ),
      isFalse,
    );
    expect(DatingMatch.tagsOf(offer), hers.offerTags(DatingGender.woman));
    expect(DatingMatch.fits('x', offer), isFalse);
    expect(DatingMatch.fits('2' * 18, offer), isFalse);
    expect(DatingMatch.tagsOf('1' * 17), isEmpty);
    // Nothing in an answer is a tag in the clear for a phone on the way: it
    // travels only inside a hybrid box.
    expect(offer, isNot(contains('k>m')));

    // The proof of a lantern's answer: a MAC with the secret of the sealed
    // answer, the same on both sides, different for anything else.
    final List<int> nonce = List<int>.generate(32, (int i) => i);
    final String proof = datingLanternProof(nonce, 'id1', 'ania-key');
    expect(datingLanternProof(List<int>.of(nonce), 'id1', 'ania-key'), proof);
    expect(
      datingLanternProof(List<int>.filled(32, 7), 'id1', 'ania-key'),
      isNot(proof),
    );
    expect(datingLanternProof(nonce, 'id2', 'ania-key'), isNot(proof));
    expect(datingLanternProof(nonce, 'id1', 'eve-key'), isNot(proof));

    // A lantern commits to both halves of its key.
    final String h = datingLanternHash(<int>[1, 2], <int>[3, 4]);
    expect(h, hasLength(44));
    expect(datingLanternHash(<int>[1, 2], <int>[3, 5]), isNot(h));
    expect(datingLanternHash(<int>[1, 3], <int>[3, 4]), isNot(h));

    // The first phone on the way vouches for the asker's key without
    // naming it.
    final String tag = datingOriginTag('key-a', 'eph-1');
    expect(datingOriginTag('key-a', 'eph-1'), tag);
    expect(datingOriginTag('key-b', 'eph-1'), isNot(tag));
    expect(datingOriginTag('key-a', 'eph-2'), isNot(tag));
    expect(tag, isNot(contains('key-a')));
  });

  test('a lantern carries only the hash of a new one-off key, with dating on '
      'or off; it '
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
      expect((l['l'] as Map).keys.toSet(), <String>{'v', 'h'});
      expect(jsonEncode(l['l']).length, lessThan(80));
      expect(DatingLantern.fromJson(l['l']), isNotNull);
    }
    expect(a1['id'], isNot(a2['id']));
    expect(a1['l']['h'], isNot(a2['l']['h']));
    expect(a1['l']['h'], isNot(ania.service.myKey));
    expect(jsonEncode(lanterns(cyryl)), isNot(contains(ania.service.myKey)));

    // Anything this app never makes is not a lantern.
    final Map<String, dynamic> json = a1['l'] as Map<String, dynamic>;
    Map<String, dynamic> withField(String field, Object? value) =>
        <String, dynamic>{...json, field: value};
    expect(DatingLantern.fromJson(withField('v', 4)), isNull);
    expect(DatingLantern.fromJson(withField('h', 5)), isNull);
    expect(DatingLantern.fromJson(withField('h', 'x' * 65)), isNull);
    expect(DatingLantern.fromJson(withField('h', 'AAAA')), isNull);
    expect(DatingLantern.fromJson(withField('k', 'AAAA'))!.toJson(), json);
    expect(DatingLantern.fromJson('x'), isNull);
  });

  test('a phone with dating off never fits; a hidden friend never sees the '
      'profile, whichever way the lantern reaches them, and hiding with the '
      'circle also keeps out those who come only through them', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone ewa = _Phone(net, 'ewa');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone piotr = _Phone(net, 'piotr');
    net
      ..link(ania, bob)
      ..link(ania, ewa)
      ..link(bob, ewa)
      ..link(bob, ola)
      // Piotr reaches Ania only through Ewa.
      ..link(ewa, piotr);
    await bob.service.load();
    // With dating off, the phone tells its friends its dating key all the
    // same (so nobody can tell), and shows nothing.
    await bob.service.maybePublish(force: true);
    expect(bob.service.toDecide, isEmpty);
    await ewa.date(name: 'Ewa', gender: DatingGender.woman);
    await ola.date(name: 'Ola', gender: DatingGender.woman);
    await piotr.date(name: 'Piotr', gender: DatingGender.man);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..hiddenFriends.add(ewa.address);
    });
    // Ewa's dating key is known before any lantern of Ania's goes out, so
    // it does not matter which way her questions come.
    expect(ania.service.knownKeyOf(ewa.address), ewa.service.myKey);
    expect(ania.service.knownKeyOf(bob.address), bob.service.myKey);
    final String aniaKey = ania.service.myKey!;

    await ania.service.maybePublish(force: true);
    expect(
      ewa.received.where(
        (Map<String, dynamic> m) => m['type'] == DatingTypes.lantern,
      ),
      isNotEmpty,
      reason: 'the same lantern as everyone, directly and through Bob',
    );
    expect(ewa.service.profile(aniaKey), isNull);
    // (Ewa's phone passes Piotr's request and Ania's answer on, sealed;
    // none of it is for her.)
    expect(
      ewa.shown.where((RuntimeSystemNotification n) => n.body.contains('Ania')),
      isEmpty,
    );
    expect(ola.names(), contains('Ania'));
    // Hidden only from Ewa: her circle still meets Ania, also through her.
    expect(piotr.names(), contains('Ania'));
    // Hiding is one way: Ania still sees Ewa.
    await ewa.service.maybePublish(force: true);
    expect(ania.names(), contains('Ewa'));

    // Hidden from Ewa and her circle: whoever comes only through Ewa is out.
    await ania.service.saveMine(
      (MyDating m) => m.hiddenCircles.add(ewa.address),
    );
    expect(ania.service.hiddenCircles(), <String>{ewa.address});
    final _Phone rafal = _Phone(net, 'rafal');
    net.link(rafal, ewa);
    // Two steps at most: the way round through Bob is too far for him.
    await rafal.date(name: 'Rafał', gender: DatingGender.man, hops: 2);
    await ania.service.maybePublish(force: true);
    expect(rafal.names(), isNot(contains('Ania')));
    expect(ewa.service.profile(aniaKey), isNull);
    final _Phone sara = _Phone(net, 'sara');
    net.link(sara, bob);
    await sara.date(name: 'Sara', gender: DatingGender.woman);
    await ania.service.maybePublish(force: true);
    expect(sara.names(), contains('Ania'), reason: 'through Bob all is open');
    // The profile carries no list of hidden people anybody could probe.
    final DatingProfile atSara = sara.service.profile(aniaKey)!.profile;
    expect(atSara.wireJson().keys, isNot(contains('ex')));
    expect(atSara.wireJson().keys, isNot(contains('xs')));
  });

  test('a friend introduces two of their friends, whatever their own wishes '
      'and without dating at all: both get the other one\'s signed profile '
      'and the note, the matchmaker learns nothing, and only people who fit '
      'each other meet', () async {
    final _Net net = _Net();
    final _Phone marek = _Phone(net, 'marek');
    final _Phone xenia = _Phone(net, 'xenia');
    final _Phone yann = _Phone(net, 'yann');
    final _Phone zuza = _Phone(net, 'zuza');
    net
      ..link(marek, xenia)
      ..link(marek, yann)
      ..link(marek, zuza);
    // Marek does not date at all.
    await marek.service.load();
    await xenia.date(
      name: 'Xenia',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    await yann.date(
      name: 'Yann',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
      hops: 1,
    );
    await zuza.date(
      name: 'Zuza',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    final String x = xenia.service.myKey!;
    final String y = yann.service.myKey!;
    final String z = zuza.service.myKey!;
    expect(xenia.service.profile(y), isNull, reason: 'too far for her');

    expect(
      await marek.service.introduce(
        DatingEnd.friend(xenia.address),
        DatingEnd.friend(yann.address),
        'Oboje kochacie góry',
      ),
      isTrue,
    );
    final SeenProfile atX = xenia.service.profile(y)!;
    expect(atX.introBy, 'marek');
    expect(atX.introNote, 'Oboje kochacie góry');
    expect(atX.introVia, marek.address);
    expect(atX.distance, 0);
    expect(await atX.profile.verify(), isTrue);
    expect(yann.service.profile(x)!.introBy, 'marek');
    expect(xenia.shown.last.title, 'marek chce Cię komuś przedstawić');
    expect(xenia.names(), contains('Yann'));
    // Marek's phone handed the lanterns over and passed sealed boxes: no
    // profile, no name.
    expect(marek.service.profile(x), isNull);
    expect(marek.service.profile(y), isNull);
    expect(jsonEncode(marek.received), isNot(contains('Xenia')));
    expect(jsonEncode(marek.sent), isNot(contains('Yann')));
    // The one who introduced them is whom they can ask.
    expect(xenia.service.opinionFriends(y), <String>[marek.address]);

    // Two women who both look for men: introduced, but they do not fit, so
    // neither sees the other.
    expect(
      await marek.service.introduce(
        DatingEnd.friend(xenia.address),
        DatingEnd.friend(zuza.address),
        '',
      ),
      isTrue,
    );
    expect(xenia.service.profile(z), isNull);
    expect(zuza.service.profile(x), isNull);
    // One cannot be introduced to oneself, nor to a stranger.
    expect(
      await marek.service.introduce(
        DatingEnd.friend(xenia.address),
        DatingEnd.friend(xenia.address),
        '',
      ),
      isFalse,
    );
    expect(
      await marek.service.introduce(
        DatingEnd.friend(xenia.address),
        const DatingEnd.friend('200::dead'),
        '',
      ),
      isFalse,
    );

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

  test('someone from the matchmaker\'s Dating can be introduced to a friend '
      'far away; a match from it can thank the matchmaker in currency, '
      'only within one pyramid', () async {
    final _Net net = _Net();
    final _Phone marek = _Phone(net, 'marek', pyramid: 'pyr-marek');
    final _Phone piotr = _Phone(net, 'piotr');
    final _Phone zofia = _Phone(net, 'zofia');
    final _Phone yann = _Phone(
      net,
      'yann',
      pyramid: 'pyr-yann',
      payable: <String>{'pyr-marek'},
    );
    net
      ..link(marek, piotr)
      ..link(piotr, zofia)
      ..link(marek, yann);
    await piotr.service.load();
    await zofia.date(
      name: 'Zofia',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await yann.date(
      name: 'Yann',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
      hops: 1,
    );
    // Marek dates, men only: Zofia (two steps away) is in his Dating.
    await marek.date(
      name: 'Marek',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.man},
      intent: DatingIntent.friends,
    );
    await zofia.service.maybePublish(force: true);
    final String z = zofia.service.myKey!;
    final String y = yann.service.myKey!;
    expect(marek.service.profile(z), isNull, reason: 'not his wish');
    await marek.service.saveMine(
      (MyDating m) => m.wants = const DatingWants(
        genders: <DatingGender>{DatingGender.woman},
      ),
    );
    await zofia.service.maybePublish(force: true);
    expect(marek.service.profile(z), isNotNull);
    expect(yann.service.profile(z), isNull);

    expect(
      await marek.service.introduce(
        DatingEnd.profile(z),
        DatingEnd.friend(yann.address),
        'Pasujecie',
      ),
      isTrue,
    );
    final SeenProfile atYann = yann.service.profile(z)!;
    expect(atYann.introBy, 'marek');
    expect(atYann.introPyr, 'pyr-marek');
    final SeenProfile atZofia = zofia.service.profile(y)!;
    expect(atZofia.introBy, 'marek');
    expect(atZofia.introNote, 'Pasujecie');
    expect(atZofia.introVia, isNull, reason: 'Marek is not her friend');
    expect(zofia.service.opinionFriends(y), isEmpty);

    // Not before the match.
    expect(yann.service.canThank(z), isFalse);
    await yann.service.decide(z, true);
    await zofia.service.decide(y, true);
    expect(yann.service.isMatch(z), isTrue);
    expect(zofia.service.isMatch(y), isTrue);
    expect(yann.service.canThank(z), isTrue);
    // Zofia is in no pyramid: no button for her.
    expect(zofia.service.canThank(y), isFalse);
    expect(await zofia.service.thankMatchmaker(y, 5), isFalse);
    expect(zofia.payments, isEmpty);
    expect(await yann.service.thankMatchmaker(z, 5), isTrue);
    expect(yann.payments.single, ('pyr-marek', 5, 'Podziękowanie'));
    expect(yann.service.thanked(z), isTrue);
    // A match without an introduction has nobody to thank.
    expect(marek.service.canThank(z), isFalse);
  });

  test('"Zapytaj o opinię" goes to someone who knows the person — never to '
      'the person themselves', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cela = _Phone(net, 'cela');
    final _Phone darek = _Phone(net, 'darek');
    net
      ..link(ania, bob)
      ..link(ania, cela)
      ..link(bob, cela)
      ..link(bob, darek);
    await cela.service.load();
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    await bob.date(
      name: 'Bob',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await darek.date(
      name: 'Darek',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await bob.service.maybePublish(force: true);
    await darek.service.maybePublish(force: true);
    final String bobKey = bob.service.myKey!;
    final String darekKey = darek.service.myKey!;

    // Bob is Ania's friend: she can ask Cela, who knows them both — not Bob.
    final SeenProfile atAnia = ania.service.profile(bobKey)!;
    expect(atAnia.distance, 1);
    expect(atAnia.mutual, <String>[cela.address]);
    expect(ania.service.opinionFriends(bobKey), <String>[cela.address]);
    expect(
      await ania.service.askOpinion(
        bobKey,
        'Co sądzisz o Bobie?',
        friend: bob.address,
      ),
      isFalse,
      reason: 'never to the person',
    );
    expect(
      await ania.service.askOpinion(bobKey, 'Co sądzisz o Bobie?'),
      isTrue,
    );
    expect(bob.service.asksToMe, isEmpty);
    expect(cela.service.asksToMe.single.name, 'Bob');

    // Darek is two steps away, through Bob: Bob knows him.
    expect(ania.service.opinionFriends(darekKey), contains(bob.address));
    expect(
      await ania.service.askOpinion(
        darekKey,
        'Co sądzisz o Darku?',
        friend: bob.address,
      ),
      isTrue,
    );
    final OpinionAsk asked = bob.service.asksToMe.single;
    expect(asked.question, 'Co sądzisz o Darku?');
    expect(asked.name, 'Darek');
    await bob.service.answerOpinion(asked.id, 'Świetny, polecam');
    expect(
      ania.service.myAsks
          .firstWhere((OpinionAsk a) => a.name == 'Darek')
          .answer,
      'Świetny, polecam',
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

  test('up to 50 vouches: friends sign them, the owner approves them, and a '
      'viewer gets every one in parts, each checked', () async {
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

    // More than two parts' worth of words from friends.
    const int many = kDatingVouchesPerPart * 2 + 1;
    for (int i = 0; i < many; i++) {
      await ania.service.requestVouch(bob.address);
      await bob.service.writeVouch(
        bob.service.vouchRequests.keys.single,
        'Słowo $i',
      );
    }
    expect(bob.service.vouchRequests, isEmpty);
    expect(ania.service.me.vouches, hasLength(many));
    expect(ania.service.me.vouches.first.by, 'bob');
    expect(ania.service.me.vouches.first.approved, isFalse);
    for (final DatingVouch v in List<DatingVouch>.of(ania.service.me.vouches)) {
      await ania.service.setVouch(v.id, keep: true);
    }
    await ania.service.maybePublish(force: true);
    final DatingProfile atDarek = darek.service.profile(aniaKey)!.profile;
    expect(atDarek.vouchDigests, hasLength(many));
    expect(atDarek.vouches, hasLength(many));
    expect(atDarek.complete, isTrue);
    expect(atDarek.vouches.map((DatingVouch v) => v.text).toSet(), <String>{
      for (int i = 0; i < many; i++) 'Słowo $i',
    });

    // At most 50 shown on a profile; a few more may wait for approval.
    final LedgerKeyPair friend = await LedgerKeyPair.generate();
    await ania.service.saveMine((MyDating m) => m.vouches.clear());
    final List<DatingVouch> lots = <DatingVouch>[
      for (int i = 0; i < kDatingMaxVouches + 5; i++)
        await DatingVouch.sign(
          signer: friend,
          id: 'v$i',
          forKey: aniaKey,
          by: 'Kasia',
          text: 'Super $i',
          at: i,
        ),
    ];
    await ania.service.saveMine((MyDating m) => m.vouches.addAll(lots));
    for (final DatingVouch v in lots) {
      await ania.service.setVouch(v.id, keep: true);
    }
    expect(
      ania.service.me.vouches.where((DatingVouch v) => v.approved),
      hasLength(kDatingMaxVouches),
    );
    final MyDating back = MyDating.fromJson(
      jsonDecode(jsonEncode(ania.service.me.toJson())),
    );
    expect(back.vouches, hasLength(kDatingMaxVouches + 5));
  });

  test('a profile answer and a cover are exactly one size; photos come '
      'after it, one part of one size each, checked against the signed '
      'profile', () async {
    final Map<String, dynamic> small = datingPadded(<String, dynamic>{
      'cover': true,
    });
    int size(Map<String, dynamic> m) => utf8.encode(jsonEncode(m)).length;
    expect(size(small), kDatingCoreBytes);
    expect(
      size(
        datingPadded(<String, dynamic>{
          'ph': 'x' * 40000,
        }, size: kDatingPartBytes),
      ),
      kDatingPartBytes,
    );
    expect(
      size(
        datingPadded(<String, dynamic>{'cover': true}, size: kDatingPartBytes),
      ),
      kDatingPartBytes,
    );

    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone ewa = _Phone(net, 'ewa', decoyShare: 1);
    net
      ..link(ania, darek)
      ..link(ania, ewa);
    await darek.date(name: 'Darek', gender: DatingGender.man);
    // Ewa does not fit Ania; her phone asks for the profile anyway (a decoy)
    // and gets a cover.
    await ewa.date(
      name: 'Ewa',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.woman},
    );
    final List<String> photos = <String>[_jpeg(10), _jpeg(80), _jpeg(160)];
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..wants = const DatingWants(genders: <DatingGender>{DatingGender.man})
        ..about = 'Lubię góry'
        ..photos.addAll(photos);
    });
    await ania.service.maybePublish(force: true);
    final DatingProfile atDarek = darek.service.toDecide.single.profile;
    expect(atDarek.photoDigests, hasLength(3));
    expect(atDarek.photos, hasLength(3));
    for (final String ph in atDarek.photos) {
      expect(img.decodeJpg(base64Decode(ph)), isNotNull);
    }
    expect(ewa.service.toDecide, isEmpty);

    // What Ania's phone sent back: the answers to profile requests (Darek's
    // real one, Ewa's cover) all one size, the parts all another.
    final List<int> big = <int>[
      for (final Map<String, dynamic> m in ania.sent)
        if (m['type'] == DatingTypes.back &&
            jsonEncode(m).length > kDatingCoreBytes)
          ((m['box'] as Map)['x'] as String).length,
    ];
    final Set<int> cores = big.where((int n) => n < kDatingPartBytes).toSet();
    final Set<int> parts = big.where((int n) => n >= kDatingPartBytes).toSet();
    expect(cores, hasLength(1), reason: 'a real profile and a cover alike');
    expect(parts, hasLength(1));
    expect(
      big.where((int n) => n < kDatingPartBytes).length,
      greaterThanOrEqualTo(2),
    );
    // The answer itself never carries a photo.
    expect(cores.single, lessThan(kDatingCoreBytes * 2));

    // Kept here with the photos, they survive a restart.
    final DatingService again = DatingService(
      host: darek,
      disk: darek.disk,
      now: () => net.clock,
    );
    await again.load();
    expect(again.profile(ania.service.myKey!)!.profile.photos, hasLength(3));
  });

  test('a profile is signed by its owner: a changed word, photo, wish or key '
      'breaks the signature', () async {
    final LedgerKeyPair signer = await LedgerKeyPair.generate();
    final RelayIdentity id = await RelayIdentity.generateHybrid();
    final RelayIdentity other = await RelayIdentity.generateHybrid();
    final String photo = _jpeg(10);
    final DatingProfile p = await DatingProfile.sign(
      signerKey: signer,
      key: base64Url.encode(id.publicKey),
      pq: base64Url.encode(id.pqPublicKey!),
      name: 'Ania',
      gender: DatingGender.woman,
      at: 5,
      about: 'Góry',
      interests: <String>['góry'],
      photos: <String>[photo],
    );
    expect(await p.verify(), isTrue);
    final Map<String, dynamic> wire =
        jsonDecode(jsonEncode(p.wireJson())) as Map<String, dynamic>;
    expect(wire.containsKey('ph'), isFalse, reason: 'photos come as parts');
    expect(wire['phd'], <String>[datingPhotoDigest(photo)]);
    expect(await DatingProfile.fromJson(wire)!.verify(), isTrue);
    for (final Map<String, dynamic> change in <Map<String, dynamic>>[
      <String, dynamic>{'n': 'Ewa'},
      <String, dynamic>{'ab': 'Morze'},
      <String, dynamic>{
        'it': <String>['morze'],
      },
      <String, dynamic>{
        'phd': <String>[datingPhotoDigest(_jpeg(99))],
      },
      <String, dynamic>{'k': base64Url.encode(other.publicKey)},
      <String, dynamic>{'q': base64Url.encode(other.pqPublicKey!)},
      <String, dynamic>{'want': const DatingWants(hops: 1).toJson()},
      <String, dynamic>{'sig': 'x'},
    ]) {
      final DatingProfile? changed = DatingProfile.fromJson(<String, dynamic>{
        ...wire,
        ...change,
      });
      expect(await changed!.verify(), isFalse, reason: '$change');
    }
    expect(DatingProfile.fromJson(<String, dynamic>{'cover': true}), isNull);
    // Kept here with the photo, still the same signed core.
    final DatingProfile kept = DatingProfile.fromJson(
      jsonDecode(jsonEncode(p.toJson())),
    )!;
    expect(kept.photos, <String>[photo]);
    expect(await kept.verify(), isTrue);
  });

  test('the distance is counted by the phones on the way, not claimed by the '
      'asker: a far asker cannot pass for a friend', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone eve = _Phone(net, 'eve');
    net
      ..link(ania, bob)
      ..link(bob, eve);
    await eve.service.load();
    await bob.date(
      name: 'Bob',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    // Ania meets friends only.
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      hops: 1,
    );
    await bob.service.maybePublish(force: true);
    final String bobKey = bob.service.myKey!;
    expect(ania.service.knownKeyOf(bob.address), bobKey);
    final Map<String, dynamic> lantern = eve.received.lastWhere(
      (Map<String, dynamic> m) =>
          m['type'] == DatingTypes.lantern &&
          (m['path'] as List).isNotEmpty &&
          ania.sent.any((Map<String, dynamic> a) => a['id'] == m['id']),
    );
    final String id = lantern['id'] as String;
    final (Uint8List, Uint8List) keys = await _lanternKeys(
      eve,
      bob,
      id,
      'eve-keys',
      hash: (lantern['l'] as Map)['h'] as String,
    );

    // Eve's modified phone claims to be one step away, in every way it can.
    final RelayIdentity fresh = await RelayIdentity.generateHybrid();
    final String seek = DatingMatch.bits(
      const DatingWants(
        genders: <DatingGender>{DatingGender.woman},
      ).seekTags(DatingGender.man),
    );
    final int before = eve.received.length;
    await eve.send(bob.address, <String, dynamic>{
      'type': DatingTypes.back,
      'to': id,
      'm': 'eve-mark',
      'box': await DatingBox.seal(
        me: fresh,
        recipient: keys.$1,
        recipientPq: keys.$2,
        payload: <String, dynamic>{
          'k': 'match',
          'id': id,
          'd': 1,
          'pq': base64Url.encode(fresh.pqPublicKey!),
        },
      ),
      'ttl': 7,
      'n': -5,
    });
    final Map<String, dynamic> answer = eve.received
        .sublist(before)
        .lastWhere((Map<String, dynamic> m) => m['type'] == DatingTypes.back);
    final Map<String, dynamic> opened = (await DatingBox.open(
      me: fresh,
      box: answer['box'],
    ))!.$2;
    // Two steps, as Bob's phone counted: out of Ania's reach, so no fit.
    expect(DatingMatch.fits(seek, opened['o']), isFalse);
    expect(opened['o'], DatingMatch.none);
    // Bob's key stays Bob's, and Bob still meets Ania.
    expect(ania.service.knownKeyOf(bob.address), bobKey);
    expect(ania.names(), contains('Bob'));
    expect(bob.names(), contains('Ania'));
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

      await send('zly-klucz', <String, dynamic>{...lantern, 'h': 5});
      await send('zla-wersja', <String, dynamic>{...lantern, 'v': 4});
      await send('krotki-klucz', <String, dynamic>{...lantern, 'h': 'AAAA'});
      await send('nic', null);
      expect(passed(), isEmpty);

      // Anything riding along is dropped; it goes on once, not queued, and
      // never further than the app takes a lantern.
      await send('dobra', <String, dynamic>{
        ...lantern,
        'balast': 'x' * 100000,
      }, hops: 5);
      expect(passed().single['l'], lantern);
      // Three steps: one left after the friend it goes to.
      expect(passed().single['hops'], 1);
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
    // Her own request for the lantern's keys, match test and request for
    // Darek's profile.
    final int start = answers();
    expect(start, 3);
    const int weeks = kDatingFetchesPerKeyPerDay + 5;
    for (int i = 0; i < weeks; i++) {
      await ania.service.maybePublish(force: true);
    }
    // The keys and one match test per lantern; profiles only up to the daily
    // limit.
    expect(answers() - start, 2 * weeks + kDatingFetchesPerKeyPerDay);
    expect(darek.service.toDecide.single.profile.name, 'Ania');
    net.clock += 24 * 3600 * 1000 + 1;
    final int before = answers();
    await ania.service.maybePublish(force: true);
    expect(
      answers(),
      before + 3,
      reason: 'the keys, a match test and a profile',
    );
  });

  test('a modified friend asking with a new key every time gets only a few '
      'answers per lantern and no profile without a proof of fit; hidden '
      'with their circle, nothing that comes through them fits', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone eve = _Phone(net, 'eve');
    net.link(ania, eve);
    await eve.service.load();
    // Eve's phone tells Ania its dating key, as every phone does.
    await eve.service.maybePublish(force: true);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman;
    });
    int marks = 0;
    late String lanternId;
    late (Uint8List, Uint8List) keys;
    Future<void> publish() async {
      await ania.service.maybePublish(force: true);
      final Map<String, dynamic> l = ania.sent.lastWhere(
        (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
      );
      lanternId = l['id'] as String;
      keys = await _lanternKeys(
        eve,
        ania,
        lanternId,
        'keys-${marks++}',
        hash: (l['l'] as Map)['h'] as String,
      );
    }

    // Sends [payload] sealed to the lantern from [me], as Eve's phone would
    // (claiming it passed [n] phones before hers), and opens what comes
    // back.
    Future<Map<String, dynamic>?> ask(
      RelayIdentity me,
      Map<String, dynamic> payload, {
      int n = 0,
    }) async {
      final int before = eve.received.length;
      await eve.send(ania.address, <String, dynamic>{
        'type': DatingTypes.back,
        'to': lanternId,
        'm': 'mark-${marks++}',
        'box': await DatingBox.seal(
          me: me,
          recipient: keys.$1,
          recipientPq: keys.$2,
          payload: payload,
        ),
        'ttl': 7,
        'n': n,
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

    // Probing: a new key for every question. Returns the answered questions
    // (key, the wishes of a man looking for anyone, answer).
    final String seek = DatingMatch.bits(
      const DatingWants().seekTags(DatingGender.man),
    );
    Future<List<_Probe>> probe(int times, {required int n}) async {
      final List<_Probe> got = <_Probe>[];
      for (int i = 0; i < times; i++) {
        final RelayIdentity fresh = await RelayIdentity.generateHybrid();
        final Map<String, dynamic>? a = await ask(fresh, <String, dynamic>{
          'k': 'match',
          'id': lanternId,
          'pq': base64Url.encode(fresh.pqPublicKey!),
        }, n: n);
        if (a != null) {
          got.add((fresh, seek, a));
        }
      }
      return got;
    }

    Future<Map<String, dynamic>?> fetch(_Probe p, String wishes) =>
        ask(p.$1, <String, dynamic>{
          'k': 'fetch',
          'id': lanternId,
          'a': p.$3['a'],
          's': wishes,
        });

    await publish();
    // As herself: her own phone already asked once, so no other key does.
    expect(await probe(5, n: 0), isEmpty);
    // Pretending to pass questions on: a limited number per lantern.
    final List<_Probe> answered = await probe(
      kDatingMatchFarPerFriend + 10,
      n: 1,
    );
    expect(answered, hasLength(kDatingMatchFarPerFriend));
    // A new secret for every answer: no two answers can be put together.
    expect(answered[1].$3['n'], isNot(answered[2].$3['n']));
    // A man looking for anyone fits Ania (a woman looking for anyone).
    final _Probe far = answered.first;
    expect(DatingMatch.fits(far.$2, far.$3['o']), isTrue);

    // Without a proof of fit (no wishes) only a cover comes back.
    final Map<String, dynamic>? cover = await fetch(far, DatingMatch.none);
    expect((cover!['p'] as Map)['cover'], isTrue);
    // The same answer cannot be used twice.
    expect(await fetch(far, far.$2), isNull);
    // With the proof: the signed profile, as for anyone who fits — exactly
    // as long as the cover, and its proof made with the answer's secret.
    final Map<String, dynamic>? real = await fetch(
      answered.last,
      answered.last.$2,
    );
    final DatingProfile profile = DatingProfile.fromJson(real!['p'])!;
    expect(profile.name, 'Ania');
    expect(await profile.verify(), isTrue);
    expect(jsonEncode(real['p']).length, jsonEncode(cover['p']).length);
    expect(
      real['lp'],
      datingLanternProof(
        base64Url.decode(answered.last.$3['n'] as String),
        lanternId,
        ania.service.myKey!,
      ),
    );

    // Hidden from Eve and her circle: whatever keys come through her, they
    // never fit and get no profile, even with fitting wishes.
    await ania.service.saveMine((MyDating m) {
      m
        ..hiddenFriends.add(eve.address)
        ..hiddenCircles.add(eve.address);
    });
    await publish();
    final List<_Probe> hidden = await probe(10, n: 1);
    expect(hidden, hasLength(10));
    for (final _Probe h in hidden) {
      expect(h.$3['o'], DatingMatch.none);
    }
    final Map<String, dynamic>? none = await fetch(hidden.last, seek);
    expect((none!['p'] as Map)['cover'], isTrue);
  });

  test('a hidden friend\'s app asking with a new key through a mutual friend '
      'is noticed by the first phone on the way; pretending to pass a '
      'question on is not (the limit the hiding option tells)', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone mia = _Phone(net, 'mia');
    final _Phone eve = _Phone(net, 'eve');
    net
      ..link(ania, mia)
      ..link(mia, eve)
      ..link(ania, eve);
    await mia.service.load();
    await mia.service.maybePublish(force: true);
    // Eve's phone told her friends her key.
    await eve.service.load();
    await eve.service.maybePublish(force: true);
    await ania.service.load();
    await ania.service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = 'Ania'
        ..gender = DatingGender.woman
        ..hiddenFriends.add(eve.address);
    });
    await ania.service.maybePublish(force: true);
    final Map<String, dynamic> l = ania.sent.lastWhere(
      (Map<String, dynamic> p) => p['type'] == DatingTypes.lantern,
    );
    final String id = l['id'] as String;
    final (Uint8List, Uint8List) keys = await _lanternKeys(
      eve,
      mia,
      id,
      'eve-keys',
      hash: (l['l'] as Map)['h'] as String,
    );
    final String seek = DatingMatch.bits(
      const DatingWants().seekTags(DatingGender.man),
    );
    Future<String?> offerVia(int n) async {
      final RelayIdentity fresh = await RelayIdentity.generateHybrid();
      final int before = eve.received.length;
      await eve.send(mia.address, <String, dynamic>{
        'type': DatingTypes.back,
        'to': id,
        'm': 'eve-$n',
        'box': await DatingBox.seal(
          me: fresh,
          recipient: keys.$1,
          recipientPq: keys.$2,
          payload: <String, dynamic>{
            'k': 'match',
            'id': id,
            'pq': base64Url.encode(fresh.pqPublicKey!),
          },
        ),
        'ttl': 7,
        'n': n,
      });
      final List<Map<String, dynamic>> back = <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in eve.received.sublist(before))
          if (m['type'] == DatingTypes.back) m,
      ];
      if (back.isEmpty) {
        return null;
      }
      return (await DatingBox.open(me: fresh, box: back.single['box']))!.$2['o']
          as String;
    }

    // Asking as herself with a new key: Mia's phone says which key Eve told
    // her, Ania's sees it is another one, and offers nothing.
    expect(await offerVia(0), DatingMatch.none);
    expect(
      mia.sent.any(
        (Map<String, dynamic> m) =>
            m['type'] == DatingTypes.back && m['oa'] is String,
      ),
      isTrue,
    );
    // Pretending to pass someone else's question on: Mia cannot tell (the
    // honest UI says so).
    final String? pretending = await offerVia(1);
    expect(DatingMatch.fits(seek, pretending), isTrue);
  });

  test('a filter passes a profile by the kind of meeting, reach, gender, '
      'interests (as typed, compared without case or marks), a photo and '
      'mutual friends', () {
    SeenProfile seen({
      DatingGender gender = DatingGender.woman,
      int distance = 2,
      bool gate = false,
      List<String> interests = const <String>[],
      List<String> photos = const <String>[],
      List<String>? mutual,
    }) => SeenProfile(
      profile: DatingProfile(
        key: 'k',
        name: 'Ola',
        gender: gender,
        at: 1,
        interests: interests,
        photoDigests: <String>[
          for (final String p in photos) datingPhotoDigest(p),
        ],
      ),
      replyTo: 'r',
      at: 1,
      distance: distance,
      gate: gate,
      mutual: mutual,
    );
    const Set<DatingIntent> dates = <DatingIntent>{DatingIntent.dates};
    const Set<DatingIntent> either = <DatingIntent>{
      DatingIntent.dates,
      DatingIntent.friends,
    };
    const DatingFilter none = DatingFilter();
    expect(none.active, 0);
    expect(none.passes(seen(), modes: dates), isTrue);
    expect(none.passes(seen(gate: true), modes: dates), isTrue);

    const DatingFilter friends = DatingFilter(intent: DatingIntent.friends);
    expect(friends.passes(seen(), modes: dates), isFalse);
    expect(friends.passes(seen(), modes: either), isTrue);

    const DatingFilter near = DatingFilter(hops: 1);
    expect(near.passes(seen(), modes: dates), isFalse);
    expect(near.passes(seen(distance: 1), modes: dates), isTrue);
    expect(
      near.passes(seen(distance: 0), modes: dates),
      isTrue,
      reason: 'introduced by a friend',
    );
    const DatingFilter three = DatingFilter(hops: 3);
    expect(three.passes(seen(distance: 3), modes: dates), isTrue);
    expect(
      three.passes(seen(distance: 1, gate: true), modes: dates),
      isFalse,
      reason: 'across a gate is further than three steps',
    );

    const DatingFilter men = DatingFilter(
      genders: <DatingGender>{DatingGender.man},
    );
    expect(men.passes(seen(), modes: dates), isFalse);
    expect(men.passes(seen(gender: DatingGender.man), modes: dates), isTrue);

    const DatingFilter hills = DatingFilter(interests: <String>{'GORY'});
    expect(
      hills.passes(seen(interests: <String>['książki']), modes: dates),
      isFalse,
    );
    expect(
      hills.passes(seen(interests: <String>['książki', 'góry']), modes: dates),
      isTrue,
    );

    const DatingFilter photo = DatingFilter(withPhoto: true);
    expect(photo.passes(seen(), modes: dates), isFalse);
    expect(photo.passes(seen(photos: <String>['x']), modes: dates), isTrue);

    const DatingFilter mutual = DatingFilter(minMutual: 2);
    expect(mutual.passes(seen(mutual: <String>['a']), modes: dates), isFalse);
    expect(
      mutual.passes(seen(mutual: <String>['a', 'b']), modes: dates),
      isTrue,
    );

    const DatingFilter all = DatingFilter(
      intent: DatingIntent.friends,
      hops: 1,
      genders: <DatingGender>{DatingGender.man},
      interests: <String>{'żeglarstwo'},
      withPhoto: true,
      minMutual: 1,
    );
    expect(all.active, 6);
    final DatingFilter back = DatingFilter.fromJson(
      jsonDecode(jsonEncode(all.toJson())),
    );
    expect(back.intent, DatingIntent.friends);
    expect(back.hops, 1);
    expect(back.genders, <DatingGender>{DatingGender.man});
    expect(back.interests, <String>{'żeglarstwo'});
    expect(back.withPhoto, isTrue);
    expect(back.minMutual, 1);

    // Interests are typed freely: tidied, compared without case or marks,
    // each once, a few at most, none too long.
    expect(datingTag('  Góry  #Wysokie\n'), 'góry wysokie');
    expect(datingTag('   '), isNull);
    expect(datingTag(5), isNull);
    expect(datingTag('x' * 40)!.length, kDatingTagMaxChars);
    expect(datingTagKey('GÓRY'), 'gory');
    expect(datingTagKey('Żeglarstwo'), datingTagKey('zeglarstwo'));
    expect(datingTagKey('Łódź'), 'lodz');
    expect(
      datingTagsFrom(<Object?>['Góry', 'gory', 'GÓRY', 'morze', 5, '']),
      <String>['góry', 'morze'],
    );
    expect(
      datingTagsFrom(<String>[for (int i = 0; i < 30; i++) 'pasja $i']),
      hasLength(kDatingMaxInterests),
    );
    expect(datingTagSuggestions(), contains('góry'));
    // A profile keeps them as typed (the owner's signature covers them).
    const DatingProfile p = DatingProfile(
      key: 'k',
      name: 'Ola',
      gender: DatingGender.woman,
      at: 1,
      interests: <String>['planszówki', 'muzyka'],
    );
    expect(
      DatingProfile.fromJson(<String, dynamic>{
        ...p.wireJson(),
        'k': base64Url.encode(List<int>.filled(32, 7)),
      })!.interests,
      <String>['planszówki', 'muzyka'],
    );
    expect(
      MyDating.fromJson(
        MyDating(interests: <String>['Góry', 'góry', 'Morze']).toJson(),
      ).interests,
      <String>['góry', 'morze'],
    );
  });

  test('"Bezpieczna randka": a pair sees the friends they have in common only '
      'once both agreed, and can ask them about each other', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cela = _Phone(net, 'cela');
    final _Phone fela = _Phone(net, 'fela');
    final _Phone gosia = _Phone(net, 'gosia');
    net
      ..link(ania, bob)
      ..link(darek, bob)
      ..link(ania, cela)
      ..link(darek, cela)
      ..link(ania, fela)
      ..link(darek, gosia);
    for (final _Phone p in <_Phone>[bob, cela, fela, gosia]) {
      await p.service.load();
    }
    await ania.date(name: 'Ania', gender: DatingGender.woman);
    await darek.date(name: 'Darek', gender: DatingGender.man);
    await ania.service.maybePublish(force: true);
    final String aniaKey = ania.service.myKey!;
    final String darekKey = darek.service.myKey!;
    expect(await ania.service.shareMutualFriends(darekKey), isFalse);
    await ania.service.decide(darekKey, true);
    await darek.service.decide(aniaKey, true);
    expect(ania.service.isMatch(darekKey), isTrue);

    expect(ania.service.mutualFriendsWith(darekKey), isNull);
    expect(await ania.service.shareMutualFriends(darekKey), isTrue);
    expect(ania.service.mutualConsent(darekKey), (true, false));
    // Darek holds Ania's marks, but sees nothing before he agrees himself.
    expect(darek.service.mutualConsent(aniaKey), (false, true));
    expect(darek.service.mutualFriendsWith(aniaKey), isNull);
    expect(ania.service.mutualFriendsWith(darekKey), isNull);

    await darek.service.shareMutualFriends(aniaKey);
    expect(ania.service.mutualFriendsWith(darekKey)!.toSet(), <String>{
      bob.address,
      cela.address,
    });
    expect(darek.service.mutualFriendsWith(aniaKey)!.toSet(), <String>{
      bob.address,
      cela.address,
    });
    expect(
      ania.service.opinionFriends(darekKey).toSet(),
      containsAll(<String>[bob.address, cela.address]),
    );
    // What went out names nobody: only marks made with the pair's own key.
    final String out = jsonEncode(<Object>[ania.sent, darek.sent]);
    expect(out, isNot(contains(fela.address)));
    expect(out, isNot(contains(gosia.address)));
  });

  test(
    'the intention is one more private wish in the match test: two fit '
    'only when both look for the same way of meeting and fit in it',
    () async {
      const DatingGender woman = DatingGender.woman;
      const DatingGender man = DatingGender.man;

      // Runs the private match test of [owner]'s lantern as [asker].
      Future<bool> psi(
        DatingWants asker,
        DatingGender askerGender,
        DatingWants owner,
        DatingGender ownerGender,
      ) async {
        final String offer = DatingMatch.bits(owner.offerTags(ownerGender));
        final String seek = DatingMatch.bits(asker.seekTags(askerGender));
        expect(offer, hasLength(DatingMatch.universe.length));
        expect(seek, hasLength(DatingMatch.universe.length));
        // The proof of fit (the wishes) holds on the holder's side exactly
        // when the asker sees a fit.
        final bool fit = DatingMatch.fits(seek, offer);
        expect(DatingMatch.fits(offer, seek), fit);
        return fit;
      }

      const DatingIntent d = DatingIntent.dates;
      const DatingIntent f = DatingIntent.friends;
      const DatingIntent b = DatingIntent.both;
      // A woman and a man who want each other's gender for dates, and anyone
      // for friends (the default).
      final Map<(DatingIntent, DatingIntent), Set<DatingIntent>> matrix =
          <(DatingIntent, DatingIntent), Set<DatingIntent>>{
            (d, d): <DatingIntent>{d},
            (d, f): <DatingIntent>{},
            (d, b): <DatingIntent>{d},
            (f, d): <DatingIntent>{},
            (f, f): <DatingIntent>{f},
            (f, b): <DatingIntent>{f},
            (b, d): <DatingIntent>{d},
            (b, f): <DatingIntent>{f},
            (b, b): <DatingIntent>{d, f},
          };
      for (final MapEntry<(DatingIntent, DatingIntent), Set<DatingIntent>> e
          in matrix.entries) {
        final DatingWants her = DatingWants(
          genders: const <DatingGender>{man},
          intent: e.key.$1,
        );
        final DatingWants his = DatingWants(
          genders: const <DatingGender>{woman},
          intent: e.key.$2,
        );
        final String what = '${e.key.$1.name} × ${e.key.$2.name}';
        expect(
          her.sharedWith(own: woman, other: man, theirs: his),
          e.value,
          reason: what,
        );
        expect(
          his.sharedWith(own: man, other: woman, theirs: her),
          e.value,
          reason: what,
        );
        expect(
          await psi(his, man, her, woman),
          e.value.isNotEmpty,
          reason: what,
        );
        expect(
          await psi(her, woman, his, man),
          e.value.isNotEmpty,
          reason: what,
        );
        expect(
          DatingWants.fromJson(jsonDecode(jsonEncode(her.toJson()))).intent,
          e.key.$1,
        );
      }

      // Two women who want men for dates still fit as new friends (any gender
      // by default), and only as that.
      const DatingWants ola = DatingWants(
        genders: <DatingGender>{man},
        intent: DatingIntent.both,
      );
      expect(
        ola.sharedWith(own: woman, other: woman, theirs: ola),
        <DatingIntent>{DatingIntent.friends},
      );
      expect(await psi(ola, woman, ola, woman), isTrue);
      // Genders narrowed for friends count both ways.
      const DatingWants menOnly = DatingWants(
        intent: DatingIntent.friends,
        friendGenders: <DatingGender>{man},
      );
      expect(
        menOnly.sharedWith(own: woman, other: woman, theirs: ola),
        isEmpty,
      );
      expect(await psi(menOnly, woman, ola, woman), isFalse);
      expect(await psi(ola, woman, menOnly, woman), isFalse);
      // The distance still counts.
      expect(
        const DatingWants(hops: 1).sharedWith(
          own: woman,
          other: man,
          theirs: const DatingWants(),
          distance: 2,
        ),
        isEmpty,
      );

      // Whatever the wishes — dates, friends, both, or none (dating off) —
      // a question carries none, an answer and a profile request are the same
      // bit strings, and all seal (hybrid) to the same sizes: a decoy still
      // looks like anything else.
      const List<DatingWants> kinds = <DatingWants>[
        DatingWants(),
        DatingWants(intent: DatingIntent.friends),
        DatingWants(intent: DatingIntent.both),
      ];
      final RelayIdentity asker = await RelayIdentity.generateHybrid();
      final RelayIdentity lantern = await RelayIdentity.generateHybrid();
      final Set<int> requests = <int>{};
      final Set<int> answers = <int>{};
      for (final Set<String> wishes in <Set<String>>[
        const <String>{},
        for (final DatingWants k in kinds) k.seekTags(man),
        for (final DatingWants k in kinds) k.offerTags(woman),
      ]) {
        final Map<String, String> fetch = await DatingBox.seal(
          me: asker,
          recipient: lantern.publicKey,
          recipientPq: lantern.pqPublicKey,
          payload: <String, dynamic>{
            'k': 'fetch',
            'id': 'l' * 16,
            'a': 'a' * 16,
            's': DatingMatch.bits(wishes),
          },
        );
        requests.add(fetch['x']!.length);
        final Map<String, String> back = await DatingBox.seal(
          me: lantern,
          recipient: asker.publicKey,
          recipientPq: asker.pqPublicKey,
          payload: <String, dynamic>{
            'k': 'match_re',
            'id': 'l' * 16,
            'a': 'a' * 16,
            'o': DatingMatch.bits(wishes),
            'n': base64Url.encode(List<int>.filled(32, 1)),
          },
        );
        answers.add(back['x']!.length);
        expect(DatingBox.isHybrid(back), isTrue);
      }
      expect(requests, hasLength(1));
      expect(answers, hasLength(1));
    },
  );

  test('"Nowi znajomi": a person looking only for friends meets only people '
      'open to friends, and nothing then speaks of dating', () async {
    final _Net net = _Net();
    final _Phone bob = _Phone(net, 'bob');
    final _Phone ania = _Phone(net, 'ania');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone piotr = _Phone(net, 'piotr');
    final List<_Phone> daters = <_Phone>[ania, darek, ola, piotr];
    for (final _Phone p in daters) {
      net.link(p, bob);
    }
    await bob.service.load();
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      intent: DatingIntent.friends,
    );
    await darek.date(
      name: 'Darek',
      gender: DatingGender.man,
      wants: <DatingGender>{DatingGender.woman},
    );
    await ola.date(
      name: 'Ola',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
      intent: DatingIntent.both,
    );
    await piotr.date(
      name: 'Piotr',
      gender: DatingGender.man,
      intent: DatingIntent.friends,
    );
    // Everyone's lantern once more, now that all of them date.
    for (final _Phone p in daters) {
      await p.service.maybePublish(force: true);
    }
    Set<String> names(_Phone p) => <String>{
      for (final SeenProfile s in p.service.toDecide) s.profile.name,
    };
    expect(names(ania), <String>{'Ola', 'Piotr'});
    expect(names(darek), <String>{'Ola'});
    expect(names(ola), <String>{'Ania', 'Darek', 'Piotr'});
    expect(names(piotr), <String>{'Ania', 'Ola'});
    final String aniaKey = ania.service.myKey!;
    final String darekKey = darek.service.myKey!;
    final String olaKey = ola.service.myKey!;
    final String piotrKey = piotr.service.myKey!;
    // Darek's phone never even got a profile of someone looking for friends
    // only, nor theirs his.
    expect(darek.service.profile(aniaKey), isNull);
    expect(darek.service.profile(piotrKey), isNull);
    expect(ania.service.profile(darekKey), isNull);
    expect(bob.service.toDecide, isEmpty);

    expect(ania.service.friendsOnly(olaKey), isTrue);
    expect(ola.service.friendsOnly(aniaKey), isTrue);
    expect(ola.service.friendsOnly(darekKey), isFalse);
    expect(darek.service.friendsOnly(olaKey), isFalse);
    expect(
      ola.service.modesWith(ola.service.profile(darekKey)!),
      <DatingIntent>{DatingIntent.dates},
    );
    expect(
      ola.service.profile(aniaKey)!.profile.wants.intent,
      DatingIntent.friends,
    );
    List<String> titles(_Phone p) => <String>[
      for (final RuntimeSystemNotification n in p.shown) n.title,
    ];
    expect(titles(ania), contains('Nowa osoba do poznania'));
    expect(titles(ania), isNot(contains('Nowe dopasowanie')));
    expect(titles(darek), contains('Nowe dopasowanie'));
    expect(titles(darek), isNot(contains('Nowa osoba do poznania')));

    // Someone who stops looking for dates no longer gets dating profiles in
    // the stack (and gets them back with the wish).
    await ola.service.saveMine(
      (MyDating m) => m.wants = const DatingWants(
        genders: <DatingGender>{DatingGender.man},
        intent: DatingIntent.friends,
      ),
    );
    expect(names(ola), <String>{'Ania', 'Piotr'});
    await ola.service.saveMine(
      (MyDating m) => m.wants = const DatingWants(
        genders: <DatingGender>{DatingGender.man},
        intent: DatingIntent.both,
      ),
    );
    expect(names(ola), <String>{'Ania', 'Darek', 'Piotr'});

    // "Tak" both ways: a new acquaintance, not a couple.
    await ania.service.decide(piotrKey, true);
    await piotr.service.decide(aniaKey, true);
    expect(ania.service.isMatch(piotrKey), isTrue);
    expect(ania.shown.last.title, 'Nowa znajomość! 👋');
    await ola.service.decide(darekKey, true);
    await darek.service.decide(olaKey, true);
    expect(darek.shown.last.title, 'Para! ❤️');
  });

  test('filters stay on the phone: the distance works in the match test as '
      'fillers only (like not fitting), the rest on the profiles that came; '
      'the asked wishes never change, so nobody can tell', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bob = _Phone(net, 'bob');
    final _Phone cyryl = _Phone(net, 'cyryl');
    final _Phone darek = _Phone(net, 'darek');
    final _Phone ewa = _Phone(net, 'ewa');
    for (final _Phone p in <_Phone>[ania, darek, ewa]) {
      net
        ..link(p, bob)
        ..link(p, cyryl);
    }
    await bob.service.load();
    await cyryl.service.load();
    await darek.date(
      name: 'Darek',
      gender: DatingGender.man,
      intent: DatingIntent.both,
    );
    // Darek wants to see only people to meet as friends.
    await darek.service.setFilter(
      const DatingFilter(intent: DatingIntent.friends),
    );
    await ania.date(
      name: 'Ania',
      gender: DatingGender.woman,
      wants: <DatingGender>{DatingGender.man},
    );
    // Ewa does not fit Ania (Ania looks for men).
    await ewa.date(name: 'Ewa', gender: DatingGender.woman);
    final String aniaKey = ania.service.myKey!;

    String lantern() =>
        ania.sent.lastWhere(
              (Map<String, dynamic> m) => m['type'] == DatingTypes.lantern,
            )['id']
            as String;
    // The sizes of what [p] sent back for the lantern [id], sealed: its
    // match test, and its request for the profile (not the request for the
    // lantern's keys, which every phone makes alike).
    // (Only what the phone itself sent: with three steps it also passes
    // other phones' questions on, counted by `n`.)
    List<int> asked(_Phone p, String id) => <int>[
      for (final Map<String, dynamic> m in p.sent)
        if (m['type'] == DatingTypes.back &&
            m['to'] == id &&
            m['n'] == 0 &&
            (m['box'] as Map)['x'] is String)
          ((m['box'] as Map)['x'] as String).length,
    ];
    Set<String> names(DatingService s) => <String>{
      for (final SeenProfile p in s.toDecide) p.profile.name,
    };

    // Ania and Darek fit (dates): his phone asked with all his wishes, proved
    // the fit and got her profile, as without a filter; it only stays out of
    // his stack, without a notification.
    final List<int> filtered = asked(darek, lantern());
    expect(filtered, hasLength(2));
    expect(darek.service.profile(aniaKey), isNotNull);
    expect(darek.service.toDecide, isEmpty);
    expect(darek.service.filteredOut, 2, reason: 'Ania and Ewa');
    expect(
      darek.shown.where(
        (RuntimeSystemNotification n) => n.id.startsWith('date-new'),
      ),
      isEmpty,
    );

    // Clearing the filter shows them at once, with nothing sent.
    final int sentBefore = darek.sent.length;
    await darek.service.setFilter(const DatingFilter());
    expect(names(darek.service), <String>{'Ania', 'Ewa'});
    expect(darek.sent, hasLength(sentBefore));

    // Without the filter, the next lantern is asked exactly alike.
    await ania.service.maybePublish(force: true);
    expect(asked(darek, lantern()), filtered);

    // Both friends in common passed the lanterns on: two mutual friends.
    expect(darek.service.profile(aniaKey)!.mutual, hasLength(2));
    await darek.service.setFilter(const DatingFilter(minMutual: 3));
    expect(darek.service.toDecide, isEmpty);
    await darek.service.setFilter(const DatingFilter(minMutual: 2));
    expect(names(darek.service), <String>{'Ania', 'Ewa'});

    // The filter and the mutual friends survive a restart.
    final DatingService again = DatingService(
      host: darek,
      disk: darek.disk,
      now: () => net.clock,
    );
    await again.load();
    expect(again.filter.minMutual, 2);
    expect(names(again), <String>{'Ania', 'Ewa'});

    // Only friends of friends one step away: Ania's next lantern (two steps
    // away) is asked with fillers only — the same size as Ewa's question,
    // who does not fit — and no profile is asked for.
    await darek.service.setFilter(const DatingFilter(hops: 1));
    await ania.service.maybePublish(force: true);
    final String id = lantern();
    expect(asked(darek, id), hasLength(1));
    expect(asked(darek, id), asked(ewa, id));
    expect(darek.service.toDecide, isEmpty, reason: 'both are two steps away');
  });
}
