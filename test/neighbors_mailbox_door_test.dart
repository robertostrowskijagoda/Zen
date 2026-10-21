import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart'
    show kReliablePayloadTypes;
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String _n(String a) => PeerShareCodec.normalizeAddress(a);

const int _day = 24 * 3600 * 1000;

/// One payload on its way from a phone's own address: retried, as the
/// relay layer does, until it is taken or its time is up.
final class _Out {
  _Out(this.to, this.payload, this.expires);

  final String to;
  final Map<String, dynamic> payload;
  final int expires;
}

enum _Result { taken, door, nobody }

/// The mesh, the relay layer and the bridge's doors, as far as the
/// neighbours section sees them.
final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  int clock = 1000;
  int _rid = 0;

  String newRid() => 'r${_rid++}';

  /// From a phone's own address (the relay layer's send).
  Future<_Result> deliver(_Phone from, _Out o) async {
    final Map<String, dynamic> payload =
        jsonDecode(jsonEncode(o.payload)) as Map<String, dynamic>;
    final _Phone? direct = phones[o.to];
    if (direct != null) {
      if (!direct.online) {
        return _Result.nobody;
      }
      await direct.service.handle(
        SignalTransportFrame(
          from: from.address,
          payload: payload,
          receivedAtMillis: clock,
        ),
      );
      return _Result.taken;
    }
    // "Pokaż mój profil" goes from the phone to a neighbour's doors.
    return deliverDoor(from.address, o.to, payload);
  }

  /// To a door (door_node.go): the flat's own door takes flat frames, a
  /// mailbox door sealed knocks naming it.
  Future<_Result> deliverDoor(
    String from,
    String to,
    Map<String, dynamic> original,
  ) async {
    final Map<String, dynamic> payload =
        jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    final Object? type = payload['type'];
    for (final _Phone p in phones.values) {
      if (!p.online) {
        continue;
      }
      if (p.inbox == to) {
        if (kFlatDoorTypes.contains(type) && type != FlatTypes.seal) {
          await p.service.handle(
            SignalTransportFrame(
              from: from,
              payload: payload,
              receivedAtMillis: clock,
              door: true,
            ),
          );
        }
        return _Result.door;
      }
      for (final String seed in p.service.hostedDoorKeys) {
        if (await doorAddressForSeed(seed) != to) {
          continue;
        }
        // A mailbox door: sealed knocks naming it only.
        final Object? d = payload['d'];
        if (type == FlatTypes.seal && d is String && _n(d) == to) {
          p.doorFrames++;
          await p.service.handle(
            SignalTransportFrame(
              from: from,
              payload: payload,
              receivedAtMillis: clock,
              door: true,
            ),
          );
        }
        return _Result.door;
      }
    }
    return _Result.nobody;
  }

  /// Ten minutes pass: every phone online retries what it has queued, from
  /// its own address and from its door.
  Future<void> flush() async {
    clock += 10 * 60 * 1000;
    for (final _Phone p in phones.values.toList()) {
      if (p.online) {
        await p.service.retryDoorSends();
      }
    }
    for (int round = 0; round < 8; round++) {
      bool any = false;
      for (final _Phone p in phones.values.toList()) {
        if (!p.online) {
          continue;
        }
        for (final _Out o in p.outbox.toList()) {
          if (o.expires <= clock) {
            p.outbox.remove(o);
            continue;
          }
          if (await deliver(p, o) == _Result.taken) {
            p.outbox.remove(o);
            any = true;
          }
        }
      }
      if (!any) {
        return;
      }
    }
  }
}

final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = _n('200::${(0xa0 + net.phones.length).toRadixString(16)}') {
    net.phones[address] = this;
    service = restarted();
  }

  final _Net net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late NeighborsService service;
  bool online = true;
  final Set<String> friendSet = <String>{};

  /// This phone's mailboxes (the relay layer's choice).
  List<String>? boxes;
  final List<_Out> outbox = <_Out>[];
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> doorSent = <Map<String, dynamic>>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  /// Frames its mailbox doors let in.
  int doorFrames = 0;

  String? get inbox {
    final String? key = service.doorKey;
    return online && key != null ? _n('200::d0:${key.substring(0, 4)}') : null;
  }

  NeighborsService restarted() => NeighborsService(
    host: this,
    disk: disk,
    now: () => net.clock,
    doorInbox: () => inbox,
    doorSend: doorSend,
    mailboxes: () => boxes,
  );

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    final Object? ttl = payload['_ttl'];
    final _Out o = _Out(
      _n(to),
      Map<String, dynamic>.from(payload)
        ..remove('_ttl')
        ..['_rid'] = net.newRid(),
      net.clock + (ttl is int ? ttl : 14 * _day),
    );
    outbox.add(o);
    if (online && await net.deliver(this, o) == _Result.taken) {
      outbox.remove(o);
    }
  }

  /// [NeighborsService.doorSend]: from this phone's door.
  Future<bool> doorSend(String to, Map<String, dynamic> payload) async {
    final String? from = inbox;
    if (from == null) {
      return false;
    }
    doorSent.add(payload);
    await net.deliverDoor(from, _n(to), payload);
    return true;
  }

  Future<void> goOnline() async {
    online = true;
    await net.flush();
  }

  @override
  List<String> friends() => friendSet.toList();

  @override
  bool isFriend(String a) => friendSet.contains(_n(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net.phones[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);
}

/// [resident] with [friends] holding its mailboxes; each runs one of its
/// mailbox doors.
Future<void> _withMailboxes(_Phone resident, List<_Phone> friends) async {
  for (final _Phone f in friends) {
    f.friendSet.add(resident.address);
    resident.friendSet.add(f.address);
  }
  resident.boxes = <String>[for (final _Phone f in friends) f.address];
  await resident.service.mailboxesChanged();
}

/// What a phone sent and keeps on disk, as text.
String _everything(_Phone p) =>
    '${jsonEncode(p.sent)} ${jsonEncode(p.doorSent)} '
    '${utf8.decode(p.disk.files['neighbors/state'] ?? Uint8List(0))}';

Uint8List _unhex(String hex) => Uint8List.fromList(<int>[
  for (int i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// Gives work the services started without waiting for it time to finish.
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
    'mailbox door addresses match the bridge (yggdrasil AddrForKey)',
    () async {
      // The same vectors as TestDoorAddressVectors in door_node_test.go.
      final Map<String, String> vectors = <String, String>{
        '42' * 32: '202:f568:3973:2437:16dd:d66d:e8f5:68a',
        'ff' * 32: '201:257a:9b7e:ed64:6c2b:bb66:90d6:3167',
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f':
            '206:2f7c:2006:18f7:a0f1:4791:738c:5a1f',
      };
      for (final MapEntry<String, String> v in vectors.entries) {
        expect(await doorAddressForSeed(v.key), _n(v.value));
      }
      expect(await doorAddressForSeed('xyz'), isNull);
      // What goes phone to phone is retried by the relay layer until it is
      // taken or its time is up (doors retry what they send themselves); so
      // is "Pokaż mój profil", the one frame a phone sends to a door.
      expect(kReliablePayloadTypes, containsAll(FlatTypes.atPhone));
      expect(kReliablePayloadTypes, contains(FlatTypes.reveal));
      // Everything that comes through a door is a frame the bridge lets in.
      expect(kFlatDoorTypes, containsAll(FlatTypes.atDoor));
    },
  );

  test(
    'a sealed knock opens only with the door key it was sealed for',
    () async {
      final FlatDoorKeys keys = (await FlatDoorKeys.derive('42' * 32))!;
      final FlatDoorKeys other = (await FlatDoorKeys.derive('43' * 32))!;
      expect(keys.slots, hasLength(kDoorSlots));
      expect(keys.slots.toSet(), hasLength(kDoorSlots));
      expect(keys.slots, isNot(contains(other.slots.first)));
      final Map<String, dynamic> box = (await FlatSeal.seal(<String, dynamic>{
        'e': <String, dynamic>{'type': FlatTypes.hello, 'n': 'Bartkowie'},
      }, keys.seal.publicKeyBase64))!;
      expect(jsonEncode(box).contains('Bartkowie'), isFalse);
      expect((await FlatSeal.open(box, keys.seal))!['e']['n'], 'Bartkowie');
      expect(await FlatSeal.open(box, other.seal), isNull);
      // A friend holds a slot key; it does not open the box.
      final RelayIdentity slotKey = RelayIdentity(
        privateKey: _unhex(keys.slotSeeds.first),
        publicKey: keys.seal.publicKey,
      );
      expect(await FlatSeal.open(box, slotKey), isNull);

      // The door code carries the slots taken and the sealing key.
      final FlatDoorCode code = FlatDoorCode(
        key: base64Url.encode(List<int>.filled(32, 7)),
        door: 'abc',
        inbox: _n('200::d1'),
        name: 'Nowakowie',
        mail: keys.mailDoor(<int>[3, 0]),
      );
      final FlatDoorCode back = FlatDoorCode.parse(code.toQr())!;
      expect(back.mail!.slots, <String>[keys.slots[0], keys.slots[3]]);
      expect(back.mail!.seal, keys.seal.publicKeyBase64);
      expect(keys.mailDoor(const <int>[]), isNull);
    },
  );

  test('nobody home: up to six friends take the knock sealed, the resident '
      'gets it on return, and the answer waits for the knocker too', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final List<_Phone> friends = <_Phone>[
      for (int i = 0; i < 7; i++) _Phone(net, 'friend$i'),
    ];
    final _Phone bartek = _Phone(net, 'bartek');
    final List<_Phone> bartekFriends = <_Phone>[
      _Phone(net, 'bf0'),
      _Phone(net, 'bf1'),
    ];
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await bartek.service.createFlat('Bartkowie', place: 'm. 14');
    await bartek.service.setPhoto(Uint8List.fromList(List<int>.filled(64, 1)));
    // The relay layer picks at most six.
    await _withMailboxes(ania, friends.take(kDoorSlots).toList());
    await _withMailboxes(bartek, bartekFriends);
    for (final _Phone f in friends.take(kDoorSlots)) {
      expect(f.service.hostedDoorKeys, hasLength(1));
    }
    expect(friends.last.service.hostedDoorKeys, isEmpty);

    // The sticker lists six mailbox doors, none of them a friend's address.
    final FlatDoorCode code = ania.service.doorCode!;
    expect(code.mail!.slots, hasLength(kDoorSlots));
    final String qr = utf8.decode(
      base64Url.decode(
        base64Url.normalize(
          code.toQr().substring(FlatDoorCode.qrPrefix.length),
        ),
      ),
    );
    for (final _Phone f in friends) {
      expect(code.mail!.slots, isNot(contains(f.address)));
      expect(qr.contains(f.address), isFalse);
    }
    expect(qr.contains(ania.address), isFalse);

    // Ania's phone is off; Bartek knocks.
    ania.online = false;
    expect(await bartek.service.scanDoor(code), FlatScan.sent);
    for (final _Phone f in friends.take(kDoorSlots)) {
      expect(f.doorFrames, 1);
      expect(f.outbox.single.payload['type'], FlatTypes.held);
    }
    // Retries of the same knock are taken once.
    await net.flush();
    for (final _Phone f in friends.take(kDoorSlots)) {
      expect(f.doorFrames, greaterThan(1));
      expect(f.outbox, hasLength(1));
    }
    // The friends hold it without being able to read it: no name, no flat
    // key, no address of the knocker (its phone or its door), on the wire
    // or on disk.
    for (final _Phone f in friends) {
      final String all = _everything(f);
      expect(all.contains('Bartkowie'), isFalse);
      expect(all.contains(bartek.service.profile!.key), isFalse);
      expect(all.contains(bartek.address), isFalse);
      expect(all.contains(bartek.inbox!), isFalse);
      expect(all.contains('Nowakowie'), isFalse);
    }
    // The knock went out from Bartek's door, never from his phone (which
    // only handed its own mailbox doors to its friends).
    expect(
      bartek.sent.map((Map<String, dynamic> m) => m['type']).toSet(),
      <String>{FlatTypes.slot},
    );

    // Ania is back: one knock, one notification, however many copies.
    await ania.goOnline();
    expect(ania.service.knocks.single.profile.name, 'Bartkowie');
    expect(
      ania.shown.where(
        (RuntimeSystemNotification n) => n.title == 'Bartkowie puka do drzwi',
      ),
      hasLength(1),
    );
    expect(bartek.service.neighbors, isEmpty);

    // Bartek is offline now; Ania lets him in and goes offline too: the
    // answer waits at Bartek's friends' mailbox doors.
    bartek.online = false;
    expect(await ania.service.acceptKnock(bartek.service.profile!.key), isTrue);
    expect(ania.service.neighbors.single.profile.name, 'Bartkowie');
    ania.online = false;
    for (final _Phone f in bartekFriends) {
      expect(f.outbox.single.payload['type'], FlatTypes.held);
      expect(_everything(f).contains('Nowakowie'), isFalse);
    }
    await bartek.goOnline();
    expect(bartek.service.pending, isEmpty);
    expect(bartek.service.neighbors.single.profile.name, 'Nowakowie');
    // Both online again: the full profiles follow, photo and all.
    await _settle();
    await ania.goOnline();
    await _settle();
    expect(ania.service.neighbors.single.profile.photo, isNotEmpty);
    expect(ania.service.neighbors.single.profile.rev, greaterThan(0));
    expect(bartek.service.neighbors.single.profile.rev, greaterThan(0));
  });

  test('the answer waits on disk; "Odmów" sends nothing, late copies do not '
      'ask again; held knocks expire after a week', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final List<_Phone> friends = <_Phone>[
      for (int i = 0; i < 3; i++) _Phone(net, 'friend$i'),
    ];
    final _Phone cyryl = _Phone(net, 'cyryl');
    final _Phone dorota = _Phone(net, 'dorota');
    await ania.service.createFlat('Nowakowie');
    await cyryl.service.createFlat('Cyryl');
    await dorota.service.createFlat('Dorota');
    await _withMailboxes(ania, friends);
    final FlatDoorCode code = ania.service.doorCode!;

    // The knocker's pending door, and the knock waiting to be retried,
    // survive a restart.
    ania.online = false;
    friends[2].online = false;
    await cyryl.service.scanDoor(code);
    final NeighborsService again = cyryl.restarted();
    await again.load();
    expect(again.pending.keys, <String>[ania.service.profile!.key]);
    expect(again.doorOutbox, cyryl.service.doorOutbox);
    expect(again.doorOutbox, greaterThan(0));

    await ania.goOnline();
    final String cyrylKey = cyryl.service.profile!.key;
    expect(ania.service.knocks.single.key, cyrylKey);
    final int before = ania.sent.length + ania.doorSent.length;
    await ania.service.rejectKnock(cyrylKey);
    // The third friend comes back later and its door takes the knock still
    // being retried: nothing asks again, nothing goes to Cyryl.
    friends[2].online = true;
    await net.flush();
    expect(friends[2].doorFrames, greaterThan(0));
    expect(ania.service.knocks, isEmpty);
    expect(ania.sent.length + ania.doorSent.length, before);
    expect(cyryl.service.neighbors, isEmpty);

    // A knock held six days still waits; on the seventh day it is gone.
    ania.online = false;
    await dorota.service.scanDoor(code);
    net.clock += 6 * _day;
    await ania.goOnline();
    expect(ania.service.knocks.single.profile.name, 'Dorota');
    net.clock += _day;
    expect(ania.service.knocks, isEmpty);
    expect(
      await ania.service.acceptKnock(dorota.service.profile!.key),
      isFalse,
    );

    // One held for longer than a week is not shown at all.
    final _Phone ewa = _Phone(net, 'ewa');
    await ewa.service.createFlat('Ewa');
    ania.online = false;
    await ewa.service.scanDoor(code);
    net.clock += 8 * _day;
    await ania.goOnline();
    expect(ania.service.knocks, isEmpty);
    for (final _Phone f in friends) {
      expect(f.outbox, isEmpty, reason: 'nothing kept past a week');
    }
  });

  test('a mailbox door takes a few knocks per knocker, per day and per week '
      'only; a phone runs at most eight doors', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final _Phone friend = _Phone(net, 'friend');
    await ania.service.createFlat('Nowakowie');
    await _withMailboxes(ania, <_Phone>[friend]);
    final FlatMailDoor mail = ania.service.doorCode!.mail!;
    final String door = mail.slots.single;
    ania.online = false;

    final Map<String, dynamic> box = (await FlatSeal.seal(<String, dynamic>{
      'e': <String, dynamic>{},
    }, mail.seal))!;
    Future<void> knock(String from, String rid) => friend.service.handle(
      SignalTransportFrame(
        from: from,
        payload: <String, dynamic>{
          'type': FlatTypes.seal,
          'd': door,
          ...box,
          '_rid': rid,
        },
        receivedAtMillis: 0,
        door: true,
      ),
    );
    int held() => friend.outbox
        .where((_Out o) => o.payload['type'] == FlatTypes.held)
        .length;

    // One knocker: the same knock retried counts once, two knocks a week.
    final String stranger = _n('200::5001');
    await knock(stranger, 'a');
    await knock(stranger, 'a');
    expect(held(), 1);
    await knock(stranger, 'b');
    await knock(stranger, 'c');
    expect(held(), 2);
    // Everyone together: four a day (a burst of fresh keys does not take
    // the whole week), ten a week.
    for (int i = 0; i < 12; i++) {
      await knock(_n('200::60${i.toRadixString(16).padLeft(2, '0')}'), 'x');
    }
    expect(held(), kHeldPerDoorPerDay);
    for (int day = 1; day < 4; day++) {
      net.clock += _day;
      for (int i = 0; i < 6; i++) {
        await knock(_n('200::7${day}0$i'), 'x');
      }
    }
    expect(held(), kHeldPerDoor);
    net.clock += 7 * _day;
    await knock(stranger, 'd');
    expect(held(), kHeldPerDoor + 1);

    // Not through a door, or for a door this phone does not run: nothing.
    expect(
      await friend.service.handle(
        SignalTransportFrame(
          from: stranger,
          payload: <String, dynamic>{'type': FlatTypes.seal, 'd': door, ...box},
          receivedAtMillis: 0,
        ),
      ),
      isFalse,
    );
    await friend.service.handle(
      SignalTransportFrame(
        from: stranger,
        payload: <String, dynamic>{
          'type': FlatTypes.seal,
          'd': _n('200::77'),
          ...box,
          '_rid': 'z',
        },
        receivedAtMillis: 0,
        door: true,
      ),
    );
    expect(held(), kHeldPerDoor + 1);
    // Too large to be a sealed card: dropped.
    await friend.service.handle(
      SignalTransportFrame(
        from: stranger,
        payload: <String, dynamic>{
          'type': FlatTypes.seal,
          'd': door,
          ...box,
          'c': 'A' * (kMaxSealedChars + 1),
          '_rid': 'big',
        },
        receivedAtMillis: 0,
        door: true,
      ),
    );
    expect(held(), kHeldPerDoor + 1);

    // At most eight friends' doors on one phone.
    final _Phone popular = _Phone(net, 'popular');
    for (int i = 0; i < kMaxHostedDoors + 1; i++) {
      final _Phone owner = _Phone(net, 'owner$i');
      await owner.service.createFlat('Flat $i');
      await _withMailboxes(owner, <_Phone>[popular]);
    }
    expect(popular.service.hostedDoorKeys, hasLength(kMaxHostedDoors));
  });

  test('mailbox doors follow the mailboxes; "Nowy kod" gives them new keys; '
      'a slot keeps its address when another friend takes it', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania');
    final List<_Phone> friends = <_Phone>[
      for (int i = 0; i < 3; i++) _Phone(net, 'friend$i'),
    ];
    await ania.service.createFlat('Nowakowie');
    await _withMailboxes(ania, friends.take(2).toList());
    final List<String> slots = ania.service.doorCode!.mail!.slots;
    expect(slots, hasLength(2));
    final String second = friends[1].service.hostedDoorKeys.single;

    // friend1 is no mailbox any more, friend2 is: it gets the same door.
    friends[2].friendSet.add(ania.address);
    ania.friendSet.add(friends[2].address);
    ania.boxes = <String>[friends[0].address, friends[2].address];
    await ania.service.mailboxesChanged();
    expect(friends[1].service.hostedDoorKeys, isEmpty);
    expect(friends[2].service.hostedDoorKeys.single, second);
    expect(ania.service.doorCode!.mail!.slots, slots);

    // A new code: new keys everywhere, the old sticker's doors are gone.
    await ania.service.newDoor();
    expect(friends[2].service.hostedDoorKeys.single, isNot(second));
    expect(
      ania.service.doorCode!.mail!.slots.toSet().intersection(slots.toSet()),
      isEmpty,
    );

    // Leaving the flat takes all doors back; a stranger cannot hand one over.
    await ania.service.leaveFlat();
    expect(friends[0].service.hostedDoorKeys, isEmpty);
    expect(friends[2].service.hostedDoorKeys, isEmpty);
    await friends[0].service.handle(
      SignalTransportFrame(
        from: _n('200::5001'),
        payload: <String, dynamic>{
          'type': FlatTypes.slot,
          's': '42' * 32,
          'at': 99999999,
        },
        receivedAtMillis: 0,
      ),
    );
    expect(friends[0].service.hostedDoorKeys, isEmpty);
  });
}
