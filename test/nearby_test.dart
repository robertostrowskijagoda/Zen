import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Air between fake radios: what one shows, the others see.
final class _Air {
  final List<_Radio> radios = <_Radio>[];
}

final class _Radio implements NearbyRadio {
  _Radio(this.air, this.device) {
    air.radios.add(this);
  }

  final _Air air;
  final String device;
  Uint8List? advertised;
  bool scanning = false;

  /// What this radio wrote to other phones (device, bytes).
  final List<(String, Uint8List)> written = <(String, Uint8List)>[];

  /// What other phones wrote to this one.
  final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': true,
    'permitted': true,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestEnable() async => true;

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    advertised = token;
    return true;
  }

  @override
  Future<void> stopAdvertising() async => advertised = null;

  @override
  Future<bool> startScan({bool lowPower = false}) async => scanning = true;

  @override
  Future<void> stopScan() async => scanning = false;

  /// Everyone scanning sees everyone advertising.
  void broadcast({int rssi = -55}) {
    for (final _Radio other in air.radios) {
      if (other != this && other.scanning && advertised != null) {
        other._events.add(<Object?, Object?>{
          'type': 'seen',
          'token': advertised,
          'rssi': rssi,
          'device': device,
        });
      }
    }
  }

  /// [from] wrote [json] to this phone.
  void hear(Map<String, dynamic> json, {String from = 'mac-x'}) =>
      _events.add(<Object?, Object?>{
        'type': 'wave',
        'device': from,
        'data': Uint8List.fromList(utf8.encode(jsonEncode(json))),
      });

  @override
  Future<bool> wave(String device, Uint8List data) async {
    for (final _Radio other in air.radios) {
      if (other.device == device) {
        written.add((device, data));
        other.got.add(jsonDecode(utf8.decode(data)) as Map<String, dynamic>);
        other._events.add(<Object?, Object?>{
          'type': 'wave',
          'device': this.device,
          'data': data,
        });
        return true;
      }
    }
    return false;
  }
}

final class _Phone implements MeetHost {
  _Phone(this.air, this.mesh, this.address, this.friendList, {LedgerDisk? disk})
    : disk = disk ?? MemoryLedgerDisk() {
    mesh[address] = this;
    radio = _Radio(air, 'mac-$address');
    meet = MeetService(
      host: this,
      store: MeetStore(this.disk),
      now: () => clock,
    );
    nearby = NearbyService(
      radio: radio,
      meet: meet,
      ownAddress: () => address,
      sendMesh: send,
      frames: frames.stream,
      onMet: (String friend) async => met.add(friend),
      now: () => clock,
    );
  }

  /// Friends this phone signed "met in person" for (§6.2).
  final List<String> met = <String>[];

  final _Air air;
  final Map<String, _Phone> mesh;
  final LedgerDisk disk;
  final String address;
  final List<String> friendList;
  late final _Radio radio;
  late final MeetService meet;
  late final NearbyService nearby;
  int clock = 1000000;
  final StreamController<SignalTransportFrame> frames =
      StreamController<SignalTransportFrame>.broadcast();

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Phone? other = mesh[to];
    if (other == null) {
      return;
    }
    final SignalTransportFrame f = SignalTransportFrame(
      from: address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    await other.meet.handle(f);
    other.frames.add(f);
  }

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  bool isSelf(String a) => a == address;

  @override
  String nameOf(String a) => a.toUpperCase();

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits for [done] (the sealed answer takes a few rounds of crypto).
Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 1000 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> _json(Uint8List data) =>
    jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

List<int> _unhexed(String hex) => <int>[
  for (int i = 0; i + 1 < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

void main() {
  test('tokens change every slot and only friends can tell whose', () {
    final NearbyOwnKeys keys = NearbyOwnKeys(
      base64Url.encode(List<int>.filled(32, 7)),
    );
    final Uint8List a = keys.token(100);
    expect(a, hasLength(16));
    expect(keys.token(100), a);
    expect(keys.token(101), isNot(a));
    expect(
      NearbyOwnKeys(base64Url.encode(List<int>.filled(32, 8))).token(100),
      isNot(a),
    );
    expect(nearbyPseudonym(a), matches(RegExp(r'^\S+ \S+$')));
    expect(nearbyDistance(-50), 'blisko');
    expect(nearbyDistance(-70), 'w pokoju');
    expect(nearbyDistance(-95), 'dalej');
  });

  test('a friend nearby is recognised and met in person; a stranger is a '
      'pseudonym', () async {
    final _Air air = _Air();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final _Phone ania = _Phone(air, mesh, 'ania', <String>['bob']);
    final _Phone bob = _Phone(air, mesh, 'bob', <String>['ania']);
    final _Phone obcy = _Phone(air, mesh, 'obcy', <String>[]);

    await ania.meet.shareNearbySecret('bob');
    await ania.nearby.setVisible(true);
    await obcy.nearby.setVisible(true);
    await bob.nearby.startScanning();

    ania.radio.broadcast(rssi: -60);
    obcy.radio.broadcast(rssi: -85);
    await _settle();

    final List<NearbyPerson> seen = bob.nearby.people;
    expect(seen, hasLength(2));
    expect(seen.first.friend, 'ania', reason: 'friends first');
    expect(seen.last.friend, isNull);
    expect(seen.last.pseudonym, obcy.nearby.myPseudonym);
    expect(bob.met, <String>['ania']);

    // 15 minutes later Ania's token is new, Bob still knows her.
    ania.clock += 15 * 60 * 1000;
    bob.clock += 15 * 60 * 1000;
    await ania.nearby.setVisible(true);
    ania.radio.broadcast();
    await _settle();
    expect(
      bob.nearby.people.where((NearbyPerson p) => p.friend == 'ania'),
      isNotEmpty,
    );
  });

  test('S5: a hello carries no address; the answer comes over Bluetooth, '
      'sealed, and only then do both learn the addresses', () async {
    final _Air air = _Air();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    // Real mesh addresses: an address in an answer must be routable.
    final String a = PeerShareCodec.normalizeAddress('200::a1');
    final String b = PeerShareCodec.normalizeAddress('200::b2');
    final _Phone ania = _Phone(air, mesh, a, <String>[]);
    final _Phone bob = _Phone(air, mesh, b, <String>[]);
    await ania.nearby.setVisible(true);
    await bob.nearby.setVisible(true);
    await ania.nearby.startScanning();
    await bob.nearby.startScanning();
    ania.radio.broadcast();
    bob.radio.broadcast();
    await _settle();

    final NearbyPerson bobSeen = ania.nearby.people.single;
    final NearbySession mine = (await ania.nearby.wave(bobSeen, 'Cześć!'))!;
    await _settle();
    expect(mine.canSend, isFalse, reason: 'one message until they answer');
    final Uint8List hello = ania.radio.written.last.$2;
    expect(_json(hello)['v'], kNearbyHelloVersion);
    expect(_json(hello), isNot(contains('a')));
    expect(utf8.decode(hello), isNot(contains(a)));

    final NearbySession theirs = bob.nearby.sessions.single;
    expect(theirs.lines.single.text, 'Cześć!');
    expect(theirs.address, isNull);
    expect(theirs.pseudonym, ania.nearby.myPseudonym);
    expect(theirs.canSend, isTrue);
    expect(bob.nearby.sessionsWith(ania.nearby.myToken), hasLength(1));

    // A second hello from the same phone before Bob answers: dropped.
    await ania.nearby.wave(bobSeen, 'Halo?');
    await _settle();
    expect(bob.nearby.sessions, hasLength(1));

    // Before the answer nothing comes over the network.
    await ania.send(b, <String, dynamic>{
      'type': kNearbyMessageType,
      'sid': theirs.id,
      'm': 'spam',
    });
    await _settle();
    expect(theirs.lines, hasLength(1));

    // Bob answers over Bluetooth; his address goes sealed.
    expect(await bob.nearby.send(theirs, 'Hej, kim jesteś?'), isTrue);
    await _until(() => mine.address != null);
    final Uint8List answer = bob.radio.written.last.$2;
    expect(_json(answer)['v'], kNearbyReplyVersion);
    expect(utf8.decode(answer), isNot(contains(b)));
    expect(mine.address, b);
    expect(mine.lines.last.text, 'Hej, kim jesteś?');
    expect(mine.canSend, isTrue);
    expect(theirs.canSend, isFalse);
    expect(theirs.waitsForThem, isTrue);

    // Someone who heard the conversation id cannot take Ania's place.
    final _Phone ewa = _Phone(
      air,
      mesh,
      PeerShareCodec.normalizeAddress('200::e5'),
      <String>[],
    );
    await ewa.send(b, <String, dynamic>{
      'type': kNearbyMessageType,
      'sid': theirs.id,
      'm': 'to ja!',
    });
    await _settle();
    expect(theirs.address, isNull);

    // Ania writes over the network: now Bob learns her address.
    expect(await ania.nearby.send(mine, 'Jestem Ania'), isTrue);
    await _settle();
    expect(theirs.address, a);
    expect(theirs.lines.last.text, 'Jestem Ania');
    expect(theirs.canSend, isTrue);
    expect(await bob.nearby.send(theirs, 'Miło mi'), isTrue);
    await _settle();
    expect(mine.lines.last.text, 'Miło mi');

    // Blocked: nothing more comes through.
    bob.nearby.block(theirs);
    await ania.nearby.send(mine, 'halo?');
    await _settle();
    expect(bob.nearby.sessions, isEmpty);

    // A message for a conversation that does not exist is dropped.
    await bob.send(a, <String, dynamic>{
      'type': kNearbyMessageType,
      'sid': 'nieznana',
      'm': 'spam',
    });
    await _settle();
    expect(ania.nearby.sessions, hasLength(2), reason: 'hers, two hellos');
  });

  test('blocks are kept across restarts', () async {
    final _Air air = _Air();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final String a = PeerShareCodec.normalizeAddress('200::a1');
    final String b = PeerShareCodec.normalizeAddress('200::b2');
    final _Phone ania = _Phone(air, mesh, a, <String>[]);
    final _Phone bob = _Phone(air, mesh, b, <String>[]);
    await ania.nearby.setVisible(true);
    await bob.nearby.setVisible(true);
    await ania.nearby.startScanning();
    await bob.nearby.startScanning();
    ania.radio.broadcast();
    bob.radio.broadcast();
    await _settle();
    final NearbySession mine = (await ania.nearby.wave(
      ania.nearby.people.single,
      'Cześć',
    ))!;
    await _settle();
    final NearbySession theirs = bob.nearby.sessions.single;
    expect(await bob.nearby.send(theirs, 'Hej'), isTrue);
    await _until(() => mine.address != null);
    expect(await ania.nearby.send(mine, 'Jestem Ania'), isTrue);
    await _settle();
    expect(theirs.address, a);

    bob.nearby.block(theirs);
    await _until(() => bob.meet.book.nearbyBlocked.isNotEmpty);
    expect(bob.nearby.blockedCount, 1);

    // The phone starts again: the block is still there.
    final _Phone again = _Phone(air, mesh, b, <String>[], disk: bob.disk);
    await again.meet.reload();
    expect(again.meet.book.nearbyBlocked, <String>{a});
    expect(again.nearby.blockedCount, 1);

    await again.nearby.unblockAll();
    expect(again.nearby.blockedCount, 0);
  });

  test('visibility is remembered', () async {
    final MeetBook book = MeetBook()..nearbyVisible = false;
    expect(
      MeetBook.fromJson(jsonDecode(jsonEncode(book.toJson()))).nearbyVisible,
      isFalse,
    );
    expect(
      MeetBook.fromJson(
        jsonDecode(jsonEncode(MeetBook().toJson())),
      ).nearbyVisible,
      isTrue,
    );
  });

  test(
    'hellos from phones nearby cannot fill the list of conversations',
    () async {
      final _Air air = _Air();
      final Map<String, _Phone> mesh = <String, _Phone>{};
      final _Phone bob = _Phone(
        air,
        mesh,
        PeerShareCodec.normalizeAddress('200::b2'),
        <String>[],
      );
      final _Radio spammer = _Radio(air, 'mac-spam');
      final String key = base64Url.encode(List<int>.filled(32, 4));
      String token(int i) => i.toRadixString(16).padLeft(32, '0');
      Future<bool> hello(String sid, String from) => spammer.wave(
        bob.radio.device,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'v': kNearbyHelloVersion,
              'sid': sid,
              'n': 'Zielony Lis',
              't': from,
              'e': key,
              'm': 'x' * 5000,
            }),
          ),
        ),
      );

      // One token: one hello until Bob answers, cut to size.
      for (int i = 0; i < 20; i++) {
        await hello('s$i', token(1));
      }
      await _settle();
      expect(bob.nearby.sessions, hasLength(1));
      expect(bob.nearby.sessions.first.lines.single.text, hasLength(300));

      // Many tokens: the oldest unanswered ones make room.
      for (int i = 0; i < 100; i++) {
        await hello('t$i', token(0x100 + i));
      }
      await _settle();
      expect(bob.nearby.sessions, hasLength(NearbyService.maxSessions));
      expect(bob.nearby.session('t99'), isNotNull);
    },
  );

  test('S6 tokens: a new one every 10 minutes, checked along a one-way '
      'chain that friends cannot run forward', () {
    final NearbyOwnKeys keys = NearbyOwnKeys(
      base64Url.encode(List<int>.filled(32, 3)),
    );
    const int slot = 3 * kNearbyChainSlots + 100;
    final int now = slot * kNearbySlot.inMilliseconds;
    expect(keys.advert(slot), hasLength(16 + kNearbyHintLength));
    expect(keys.token(slot + 1), isNot(keys.token(slot)));

    final FriendNearbyKey bob = FriendNearbyKey.parse(
      keys.materialFor('bob', now),
    )!;
    final FriendNearbyKey cyryl = FriendNearbyKey.parse(
      keys.materialFor('cyryl', now),
    )!;
    expect(bob.pair, isNot(cyryl.pair), reason: 'a key per friend');
    expect(bob.mask, cyryl.mask, reason: 'unmasking is the same for all');
    // The private key itself never goes to a friend.
    expect(
      utf8.decode(
        base64Url.decode(
          base64Url.normalize(
            keys.materialFor('bob', now).substring(kNearbyKeyPrefix.length),
          ),
        ),
      ),
      isNot(contains(base64Url.encode(List<int>.filled(32, 3)))),
    );

    final List<int> value = bob.open(keys.token(slot), slot)!;
    expect(bob.open(keys.token(slot), slot + 1), isNull);
    expect(
      bob.open(keys.token(slot + 1), slot + 1, last: (slot, value)),
      isNotNull,
    );
    // What a friend saw cannot be made into the next slot's token.
    final List<int> mask = nearbyMask(bob.mask, slot + 1);
    final List<int> replayed = <int>[
      for (int i = 0; i < 16; i++) value[i] ^ mask[i],
    ];
    expect(bob.open(replayed, slot + 1, last: (slot, value)), isNull);
    expect(bob.open(replayed, slot + 1), isNull);

    // Across the end of a chain: the next chain's anchor came along.
    const int end = 4 * kNearbyChainSlots - 1;
    expect(bob.open(keys.token(end), end), isNotNull);
    expect(bob.open(keys.token(end + 1), end + 1), isNotNull);

    // A bare secret is not a friend's keys; junk is not either.
    expect(
      FriendNearbyKey.parse(base64Url.encode(List<int>.filled(32, 7))),
      isNull,
    );
    expect(bob.radioKey, startsWith(kNearbyPairKeyPrefix));
    expect(FriendNearbyKey.parse('${kNearbyKeyPrefix}xyz'), isNull);
  });

  test('S6: a friend can show neither another friend\'s presence nor an '
      'alarm wave in their name', () async {
    final _Air air = _Air();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final _Phone ania = _Phone(air, mesh, 'ania', <String>['bob', 'cyryl']);
    final _Phone bob = _Phone(air, mesh, 'bob', <String>['ania', 'cyryl']);
    final _Phone cyryl = _Phone(air, mesh, 'cyryl', <String>['ania', 'bob']);
    await ania.meet.shareNearbySecret('bob');
    await ania.meet.shareNearbySecret('cyryl');
    await bob.meet.shareNearbySecret('ania');
    final String bobHas = bob.meet.book.friendNearbySecrets['ania']!;
    final String cyrylHas = cyryl.meet.book.friendNearbySecrets['ania']!;
    expect(bobHas, startsWith(kNearbyKeyPrefix));
    expect(cyrylHas, isNot(bobHas));

    await ania.nearby.setVisible(true);
    await bob.nearby.startScanning();
    ania.radio.broadcast();
    await _settle();
    expect(bob.nearby.people.single.friend, 'ania');
    final NearbyPerson seen = bob.nearby.people.single;

    // Ten minutes on, Ania is gone. Cyryl knows all he was given and the
    // token she showed, and tries to be her.
    ania.radio.advertised = null;
    for (final _Phone p in <_Phone>[ania, bob, cyryl]) {
      p.clock += kNearbySlot.inMilliseconds;
    }
    final FriendNearbyKey given = FriendNearbyKey.parse(cyrylHas)!;
    final int slot = nearbySlot(bob.clock);
    final List<int> before = given.open(_unhexed(seen.token), slot - 1)!;
    final List<int> mask = nearbyMask(given.mask, slot);
    final _Radio fake = _Radio(air, 'mac-fake');
    for (final List<int> guess in <List<int>>[
      before,
      crypto.sha256.convert(before).bytes.sublist(0, 16),
    ]) {
      fake
        ..advertised = Uint8List.fromList(<int>[
          for (int i = 0; i < 16; i++) guess[i] ^ mask[i],
          ...nearbyHint(given.mask, slot),
        ])
        ..broadcast();
    }
    await _settle();
    expect(bob.nearby.people, hasLength(2));
    expect(
      bob.nearby.people.every((NearbyPerson p) => p.friend == null),
      isTrue,
    );

    // Ania herself, back: still known.
    await ania.nearby.setVisible(true);
    ania.radio.broadcast();
    await _settle();
    expect(
      bob.nearby.people.where((NearbyPerson p) => p.friend == 'ania'),
      hasLength(1),
    );

    // Her alarm wave to Bob is signed for the two of them.
    bob.nearby.alarmWaveHandlers.add(
      (Map<dynamic, dynamic> json, String device) => unawaitedLogged(
        bob.meet.onAlarmWave(
          json,
          friend: bob.nearby.friendOfToken(json['t']),
          source: device,
        ),
        context: 'test',
      ),
    );
    await bob.nearby.setVisible(true);
    await ania.nearby.startScanning();
    bob.radio.broadcast();
    await _settle();
    final AlarmRecord alarm = await ania.meet.raiseAlarm(note: 'pomocy');
    expect(await ania.nearby.waveAll(ania.meet.alarmWave(alarm)), 1);
    expect(bob.radio.got.last['t'], isNotNull, reason: 'signed for the pair');
    await _until(() => bob.meet.book.alarm(alarm.id) != null);
    expect(bob.meet.book.alarm(alarm.id)!.from, 'ania');

    // Cyryl's wave "from Ania", with the key she gave him. It does not
    // ring at Bob, even named as hers.
    final Map<String, dynamic> pairWave = AlarmWave.buildPair(
      id: 'falsz2',
      at: bob.clock,
      ended: false,
      pairKey: given.pair,
    );
    expect(bob.nearby.friendOfToken(pairWave['t']), isNull);
    await bob.meet.onAlarmWave(pairWave, friend: 'ania', source: 'mac-c2');
    expect(bob.meet.book.alarm('falsz2'), isNull);
  });
}
