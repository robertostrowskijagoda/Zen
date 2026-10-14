import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
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

  @override
  Future<bool> wave(String device, Uint8List data) async {
    for (final _Radio other in air.radios) {
      if (other.device == device) {
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
  _Phone(this.air, this.mesh, this.address, this.friendList) {
    mesh[address] = this;
    radio = _Radio(air, 'mac-$address');
    meet = MeetService(
      host: this,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => clock,
    );
    nearby = NearbyService(
      radio: radio,
      meet: meet,
      ownAddress: () => address,
      sendMesh: send,
      frames: frames.stream,
      now: () => clock,
    );
  }

  final _Air air;
  final Map<String, _Phone> mesh;
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

void main() {
  test('tokens change every 15 minutes and only friends can tell whose', () {
    final String secret = base64Url.encode(List<int>.filled(32, 7));
    final Uint8List a = nearbyToken(secret, 100);
    expect(a, hasLength(16));
    expect(nearbyToken(secret, 100), a);
    expect(nearbyToken(secret, 101), isNot(a));
    expect(
      nearbyToken(base64Url.encode(List<int>.filled(32, 8)), 100),
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
    expect(bob.meet.book.metAt('ania'), isNotNull);

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

  test(
    'a stranger can say hello once; after the answer they can talk',
    () async {
      final _Air air = _Air();
      final Map<String, _Phone> mesh = <String, _Phone>{};
      // Real mesh addresses: an address in a hello must be routable.
      final String a = PeerShareCodec.normalizeAddress('200::a1');
      final String b = PeerShareCodec.normalizeAddress('200::b2');
      final _Phone ania = _Phone(air, mesh, a, <String>[]);
      final _Phone bob = _Phone(air, mesh, b, <String>[]);
      await bob.nearby.setVisible(true);
      await ania.nearby.startScanning();
      bob.radio.broadcast();
      await _settle();

      final NearbyPerson bobSeen = ania.nearby.people.single;
      final NearbySession mine = (await ania.nearby.wave(bobSeen, 'Cześć!'))!;
      await _settle();
      expect(mine.canSend, isFalse, reason: 'one message until they answer');

      final NearbySession theirs = bob.nearby.sessions.single;
      expect(theirs.lines.single.text, 'Cześć!');
      expect(theirs.address, a);
      expect(theirs.pseudonym, ania.nearby.myPseudonym);
      expect(theirs.canSend, isTrue);

      expect(await bob.nearby.send(theirs, 'Hej, kim jesteś?'), isTrue);
      await _settle();
      expect(mine.lines.last.text, 'Hej, kim jesteś?');
      expect(mine.address, b);
      expect(mine.canSend, isTrue);

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
      expect(ania.nearby.sessions, hasLength(1));
    },
  );

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
      Future<bool> hello(String sid, String address) => spammer.wave(
        bob.radio.device,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'v': 1,
              'sid': sid,
              'n': 'Zielony Lis',
              'a': address,
              'm': 'x' * 5000,
            }),
          ),
        ),
      );

      // One address: a few conversations, cut to size.
      for (int i = 0; i < 20; i++) {
        await hello('s$i', PeerShareCodec.normalizeAddress('200::a1'));
      }
      await _settle();
      expect(
        bob.nearby.sessions,
        hasLength(NearbyService.maxSessionsPerAddress),
      );
      expect(bob.nearby.sessions.first.lines.single.text, hasLength(300));

      // Many addresses: the oldest unanswered ones make room.
      for (int i = 0; i < 100; i++) {
        await hello(
          't$i',
          PeerShareCodec.normalizeAddress(
            '200::${(0x100 + i).toRadixString(16)}',
          ),
        );
      }
      await _settle();
      expect(bob.nearby.sessions, hasLength(NearbyService.maxSessions));
      expect(bob.nearby.session('t99'), isNotNull);
    },
  );
}
