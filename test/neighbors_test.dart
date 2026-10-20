import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

const int _day = 24 * 3600 * 1000;

/// A removed phone that cheats: it still holds the household's old key and
/// sends neighbours a "new key" notice of its own making.
Future<void> _raceNewKey({
  required _Phone from,
  required String oldKey,
  required _Phone to,
  required Map<String, dynamic> body,
}) async {
  final LedgerKeyPair old = await LedgerKeyPair.fromSeed(
    unb64(from.service.homeCode!.seed, length: 32)!,
  );
  final Map<String, dynamic> signed = <String, dynamic>{
    'type': FlatTypes.newKey,
    'f': oldKey,
    'to': to.service.profile!.key,
    'b': body,
  };
  final Uint8List sig = await old.sign(canonicalJsonBytes(signed));
  await from.send(to.address, <String, dynamic>{...signed, 's': b64(sig)});
}

/// The household's profile under a key [key] the cheat made, with [members].
Future<FlatProfile> _fakeProfile(
  _Phone cheat,
  LedgerKeyPair key,
  List<String> members,
) => cheat.service.profile!
    .copyWith(key: key.id, members: members, rev: 1)
    .signedWith(key);

final class _Phone implements EventHost {
  // Hex, so the addresses are routable when they travel in a QR code.
  _Phone(this.net, this.name)
    : address = addr((0xa0 + net.length).toRadixString(16)) {
    net[address] = this;
    service = NeighborsService(
      host: this,
      disk: disk,
      now: () => clock,
      doorInbox: () => inbox,
    );
  }

  final Map<String, _Phone> net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late NeighborsService service;
  int clock = 1000;

  /// Whether this phone's door runs (it runs with the node, door_node.go).
  bool doorUp = true;

  /// The door's address: it follows the door key, as the bridge's does.
  String? get inbox {
    final String? key = service.doorKey;
    return doorUp && key != null ? addr('d0:${key.substring(0, 4)}') : null;
  }

  bool online = true;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    _Phone? other = net[to];
    bool door = false;
    for (final _Phone p in net.values) {
      if (other == null && p.inbox == to) {
        other = p;
        door = true;
      }
    }
    if (other == null || !other.online) {
      return;
    }
    if (door && payload['type'] != FlatTypes.hello) {
      // Like the bridge's door: knocks only.
      return;
    }
    await other.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
        door: door,
      ),
    );
  }

  @override
  List<String> friends() => const <String>[];

  @override
  bool isFriend(String a) => false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);
}

void main() {
  test(
    'door codes and home codes survive the QR round trip; links work too',
    () {
      final FlatDoorCode code = FlatDoorCode(
        key: base64Url.encode(List<int>.filled(32, 7)),
        door: 'abc',
        inbox: addr('d1'),
        name: 'Nowakowie, m. 12',
      );
      final FlatDoorCode back = FlatDoorCode.parse(code.toQr())!;
      expect(back.key, code.key);
      expect(back.door, 'abc');
      expect(back.inbox, addr('d1'));
      expect(back.name, 'Nowakowie, m. 12');
      expect(
        FlatDoorCode.parse('https://example.org/m#${code.encode()}')!.name,
        code.name,
      );
      expect(FlatDoorCode.parse('zen-flat:nonsense'), isNull);
      expect(FlatDoorCode.parse('zen-ticket:abc'), isNull);

      final FlatHomeCode home = FlatHomeCode(
        seed: base64Url.encode(List<int>.filled(32, 3)),
        address: addr('a1'),
      );
      expect(FlatHomeCode.parse(home.toQr())!.address, addr('a1'));
      expect(FlatHomeCode.parse(code.toQr()), isNull);
    },
  );

  test('the door code never carries the residents addresses (§18.2)', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    expect(ania.service.profile!.members, hasLength(2));

    String payload(String qr) => utf8.decode(
      base64Url.decode(
        base64Url.normalize(qr.substring(FlatDoorCode.qrPrefix.length)),
      ),
    );
    final FlatDoorCode code = ania.service.doorCode!;
    final String raw = payload(code.toQr());
    expect(jsonDecode(raw)['v'], FlatDoorCode.currentVersion);
    // Only the door's own address: no resident's.
    expect(jsonDecode(raw)['a'], ania.inbox);
    expect(code.inbox, isNot(ania.address));
    expect(raw.contains(ania.address), isFalse, reason: 'resident not in QR');
    expect(raw.contains(ola.address), isFalse, reason: 'housemate not in QR');
    expect(code.toLink(), contains('/m#'));
    expect(FlatDoorCode.parse(code.toLink())!.key, code.key);
    // The door key stays on its phone: the housemate runs a door of its
    // own (one key never runs twice on the mesh), with the same token.
    expect(ola.service.doorKey, isNot(ania.service.doorKey));
    expect(ola.service.doorCode!.door, code.door);

    // No door running, no door QR (never a resident's address instead).
    ania.doorUp = false;
    expect(ania.service.doorCode, isNull);
    ania.doorUp = true;

    // A sticker without the current version is not read.
    final Map<String, dynamic> noVersion =
        jsonDecode(raw) as Map<String, dynamic>..remove('v');
    expect(
      FlatDoorCode.parse(
        '${FlatDoorCode.qrPrefix}${base64Url.encode(utf8.encode(jsonEncode(noVersion))).replaceAll('=', '')}',
      ),
      isNull,
    );
    final FlatDoorCode old = FlatDoorCode.parse(ania.service.doorCode!.toQr())!;
    await bartek.service.createFlat('Bartkowie');
    expect(await bartek.service.scanDoor(old), FlatScan.sent);
    expect(bartek.service.neighbors.single.profile.name, 'Nowakowie');
  });

  test('the small chat about an invitation stays on its thread', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie');
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    await ania.service.setShareWithScanners(true);
    final String grill = (await ania.service.addItem(
      FlatItemKind.invite,
      'Zapraszamy na grilla',
    ))!;
    final String aniaKey = ania.service.profile!.key;
    final String bartekKey = bartek.service.profile!.key;
    expect(bartek.service.neighbor(aniaKey)!.profile.item(grill), isNotNull);

    expect(
      await bartek.service.sendMessage(aniaKey, 'Co przynieść?', itemId: grill),
      isTrue,
    );
    await bartek.service.sendMessage(aniaKey, 'Cześć');
    expect(ania.service.threadAbout(bartekKey, grill), hasLength(1));
    expect(
      ania.service.threadAbout(bartekKey, grill).single.text,
      'Co przynieść?',
    );
    expect(ania.service.messagesWith(bartekKey), hasLength(2));
    await ania.service.sendMessage(bartekKey, 'Sałatkę', itemId: grill);
    expect(bartek.service.threadAbout(aniaKey, grill), hasLength(2));
    // An unknown invitation falls back to the plain thread.
    await bartek.service.sendMessage(aniaKey, 'x', itemId: 'nope');
    expect(bartek.service.threadAbout(aniaKey, 'nope'), isEmpty);
  });

  test('scanning a door makes two flats neighbours; invitations, sign-ups '
      'and places', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    final _Phone cyryl = _Phone(net, 'cyryl');

    await ania.service.createFlat('Nowakowie, m. 12', about: 'Cisza po 20');
    await bartek.service.createFlat('Bartkowie, m. 14');
    await cyryl.service.createFlat('Cyryl, m. 3');
    expect(ania.service.hasFlat, isTrue);
    expect(ania.service.profile!.members, <String>[ania.address]);

    final FlatDoorCode door = ania.service.doorCode!;
    expect(await ania.service.scanDoor(door), FlatScan.own);
    expect(await bartek.service.scanDoor(door), FlatScan.sent);

    // Both sides know each other now; Ania's phone rang.
    final NeighborFlat atBartek = bartek.service.neighbors.single;
    expect(atBartek.profile.name, 'Nowakowie, m. 12');
    expect(atBartek.weScanned, isTrue);
    expect(bartek.service.pending, isEmpty);
    final NeighborFlat atAnia = ania.service.neighbors.single;
    expect(atAnia.profile.name, 'Bartkowie, m. 14');
    expect(atAnia.scannedUs, isTrue);
    expect(atAnia.weScanned, isFalse);
    expect(ania.shown.last.title, 'Nowi sąsiedzi');
    expect(await bartek.service.scanDoor(door), FlatScan.alreadyNeighbor);
    await cyryl.service.scanDoor(door);

    // Only flats Ania scanned get her news, unless she allows the others.
    final String grill = (await ania.service.addItem(
      FlatItemKind.invite,
      'Zapraszamy na grilla',
      at: 5000,
      seats: 4,
    ))!;
    expect(bartek.service.neighbors.single.profile.items, isEmpty);
    await ania.service.setShareWithScanners(true);
    expect(bartek.service.neighbors.single.profile.item(grill)!.seats, 4);
    expect(bartek.shown.last.title, 'Nowakowie, m. 12 zapraszają');

    // Signing up takes places; a flat that does not fit is told so.
    expect(
      await bartek.service.signUp(ania.service.profile!.key, grill, 3),
      isTrue,
    );
    expect(ania.service.profile!.item(grill)!.taken, 3);
    expect(ania.service.signupsFor(grill).single.name, 'Bartkowie, m. 14');
    expect(bartek.service.mySignup(ania.service.profile!.key, grill), 3);
    expect(ania.shown.last.title, 'Bartkowie, m. 14 przyjdą');

    await cyryl.service.signUp(ania.service.profile!.key, grill, 2);
    expect(ania.service.profile!.item(grill)!.taken, 3);
    expect(cyryl.service.mySignup(ania.service.profile!.key, grill), 0);
    expect(cyryl.shown.last.title, 'Brak miejsc');

    // Fewer places is fine, and frees them.
    await bartek.service.signUp(ania.service.profile!.key, grill, 1);
    expect(ania.service.profile!.item(grill)!.taken, 1);
    await cyryl.service.signUp(ania.service.profile!.key, grill, 2);
    expect(ania.service.profile!.item(grill)!.taken, 3);
    expect(cyryl.service.mySignup(ania.service.profile!.key, grill), 2);

    // Messages between flats.
    await bartek.service.sendMessage(
      ania.service.profile!.key,
      'Przyniesiemy sałatkę',
    );
    final FlatMessage m = ania.service
        .messagesWith(bartek.service.profile!.key)
        .single;
    expect(m.text, 'Przyniesiemy sałatkę');
    expect(m.mine, isFalse);
    expect(m.by, 'bartek');
    expect(ania.service.unread(bartek.service.profile!.key), 1);
    await ania.service.markRead(bartek.service.profile!.key);
    expect(ania.service.unread(bartek.service.profile!.key), 0);
  });

  test(
    'housemates share the flat: joining, messages to all, leaving',
    () async {
      final Map<String, _Phone> net = <String, _Phone>{};
      final _Phone ania = _Phone(net, 'ania');
      final _Phone ola = _Phone(net, 'ola');
      final _Phone bartek = _Phone(net, 'bartek');
      await ania.service.createFlat('Nowakowie, m. 12');
      await bartek.service.createFlat('Bartkowie, m. 14');
      await bartek.service.scanDoor(ania.service.doorCode!);
      await ania.service.addItem(FlatItemKind.offer, 'Pożyczę drabinę');

      // Ola scans Ania's home code.
      expect(await ola.service.joinFlat(ania.service.homeCode!), isTrue);
      expect(ola.service.hasFlat, isTrue);
      expect(ola.service.joining, isFalse);
      expect(ola.service.profile!.key, ania.service.profile!.key);
      expect(ania.service.profile!.members, <String>[
        ania.address,
        ola.address,
      ]);
      expect(
        ola.service.profile!.of(FlatItemKind.offer).single.text,
        'Pożyczę drabinę',
      );
      expect(ola.service.neighbors.single.profile.name, 'Bartkowie, m. 14');
      expect(ola.service.door, ania.service.door);
      expect(ola.shown.last.title, 'Jesteś domownikiem');

      // Bartek learns the new member when he refreshes, then reaches both.
      await bartek.service.refresh(ania.service.profile!.key);
      expect(bartek.service.neighbors.single.profile.members, hasLength(2));
      await bartek.service.sendMessage(
        ania.service.profile!.key,
        'Dzień dobry!',
      );
      expect(
        ania.service.messagesWith(bartek.service.profile!.key),
        hasLength(1),
      );
      expect(
        ola.service.messagesWith(bartek.service.profile!.key),
        hasLength(1),
      );

      // Ola answers; Ania sees it too (house sync).
      bartek.clock += 10;
      await ola.service.sendMessage(
        bartek.service.profile!.key,
        'Dzień dobry, tu Ola',
      );
      expect(
        ania.service
            .messagesWith(bartek.service.profile!.key)
            .map((FlatMessage m) => m.text),
        contains('Dzień dobry, tu Ola'),
      );
      expect(
        bartek.service.messagesWith(ania.service.profile!.key).last.by,
        'ola',
      );

      // A profile change by one housemate reaches the other.
      await ola.service.editProfile(about: 'Mamy psa');
      expect(ania.service.profile!.about, 'Mamy psa');

      // A neighbour removed by one stays removed for the other.
      await ania.service.removeNeighbor(bartek.service.profile!.key);
      expect(ola.service.neighbors, isEmpty);
      await ola.service.editProfile(about: 'Mamy dwa psy');
      expect(ania.service.neighbors, isEmpty);

      // Ola leaves; Ania keeps the flat.
      await ola.service.leaveFlat();
      expect(ola.service.hasFlat, isFalse);
      expect(ania.service.profile!.members, <String>[ania.address]);
    },
  );

  test('a new door code makes the old one useless; forged messages are '
      'ignored', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone dorota = _Phone(net, 'dorota');
    final _Phone eve = _Phone(net, 'eve');
    await ania.service.createFlat('Nowakowie, m. 12');
    await dorota.service.createFlat('Dorota, m. 7');
    await eve.service.createFlat('Eve, m. 1');

    final FlatDoorCode old = ania.service.doorCode!;
    final String? oldKey = ania.service.doorKey;
    await ania.service.newDoor();
    // A new code is a new door: new key, new address.
    expect(ania.service.doorKey, isNot(oldKey));
    expect(ania.service.doorCode!.inbox, isNot(old.inbox));
    await dorota.service.scanDoor(old);
    // The old door's address answers no more: nothing reaches Ania.
    expect(dorota.service.neighbors, isEmpty);
    expect(dorota.service.pending.keys, <String>[old.key]);
    expect(ania.service.neighbors, isEmpty);

    // A knock at the live door with a wrong token gets no answer: one from
    // Ania's phone would tell whose door it is.
    final int before = ania.sent.length;
    await dorota.service.scanDoor(
      FlatDoorCode(
        key: old.key,
        door: 'guess',
        inbox: ania.service.doorCode!.inbox,
        name: old.name,
      ),
    );
    expect(ania.sent.length, before);
    expect(ania.service.neighbors, isEmpty);
    expect(dorota.service.staleDoors, isEmpty);

    // The door takes knocks only.
    expect(
      await ania.service.handle(
        SignalTransportFrame(
          from: eve.address,
          payload: <String, dynamic>{
            'type': FlatTypes.get,
            'f': eve.service.profile!.key,
            'to': ania.service.profile!.key,
            'b': <String, dynamic>{},
            's': 'AAAA',
          },
          receivedAtMillis: 0,
          door: true,
        ),
      ),
      isFalse,
    );

    // Eve was never let in: her messages, sign-ups and profiles are dropped.
    final String ownKey = ania.service.profile!.key;
    await ania.service.handle(
      SignalTransportFrame(
        from: eve.address,
        payload: <String, dynamic>{
          'type': FlatTypes.message,
          'f': eve.service.profile!.key,
          'to': ownKey,
          'b': <String, dynamic>{'id': 'x1', 't': 'spam'},
          's': 'AAAA',
        },
        receivedAtMillis: 0,
      ),
    );
    expect(ania.service.messagesWith(eve.service.profile!.key), isEmpty);

    // A house message must be signed with the flat's own key.
    await ania.service.handle(
      SignalTransportFrame(
        from: eve.address,
        payload: <String, dynamic>{
          'type': FlatTypes.join,
          'f': ownKey,
          'to': ownKey,
          'b': <String, dynamic>{'a': eve.address},
          's': base64Url.encode(List<int>.filled(64, 1)),
        },
        receivedAtMillis: 0,
      ),
    );
    expect(ania.service.profile!.members, <String>[ania.address]);
  });

  test('an invitation goes over Bluetooth to people nearby and turns into '
      'a neighbour', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Mieszkanie 12');
    await bartek.service.createFlat('Bartkowie');
    final String grill = (await ania.service.addItem(
      FlatItemKind.invite,
      'Grill w sobotę',
    ))!;
    final Map<String, dynamic> wave = ania.service.nearbyWave(grill)!;
    expect(utf8.encode(jsonEncode(wave)).length, lessThan(500));

    await bartek.service.onNearbyWave(
      jsonDecode(jsonEncode(wave)) as Map<String, dynamic>,
    );
    await bartek.service.onNearbyWave(
      jsonDecode(jsonEncode(wave)) as Map<String, dynamic>,
    );
    final NearbyFlatInvite invite = bartek.service.nearbyInvites.single;
    expect(invite.text, 'Mieszkanie 12: Grill w sobotę');
    expect(bartek.shown.single.title, 'Zaproszenie w pobliżu');

    // Own waves are ignored.
    await ania.service.onNearbyWave(wave);
    expect(ania.service.nearbyInvites, isEmpty);

    await bartek.service.scanDoor(invite.door);
    expect(
      bartek.service.neighbors.single.profile
          .of(FlatItemKind.invite)
          .single
          .text,
      'Grill w sobotę',
    );

    // Old ones fade away.
    bartek.clock += kNearbyInviteLife.inMilliseconds;
    expect(bartek.service.nearbyInvites, isEmpty);
  });

  test('a household moves out: neighbours are told, the door code dies, '
      'new tenants start from scratch', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone bartek = _Phone(net, 'bartek');
    final _Phone nowi = _Phone(net, 'nowi');
    await ania.service.createFlat(
      'Nowakowie',
      place: 'm. 12',
      about: 'Mamy psa',
    );
    expect(ania.service.profile!.label, 'Nowakowie · m. 12');
    expect(ania.service.doorCode!.name, 'Nowakowie · m. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    await bartek.service.createFlat('Bartkowie', place: 'm. 14');
    final FlatDoorCode oldDoor = ania.service.doorCode!;
    await bartek.service.scanDoor(oldDoor);
    await ania.service.addItem(FlatItemKind.offer, 'Pożyczę drabinę');
    await bartek.service.sendMessage(ania.service.profile!.key, 'hej');
    expect(ola.service.neighbors, hasLength(1));

    ania.clock += 100;
    await ania.service.moveOut(newPlace: 'Lipowa 3/7');
    final FlatProfile moved = ania.service.profile!;
    expect(moved.name, 'Nowakowie');
    expect(moved.place, 'Lipowa 3/7');
    expect(moved.about, 'Mamy psa');
    expect(moved.items, isEmpty);
    expect(moved.members, hasLength(2), reason: 'the household stays');
    expect(ania.service.neighbors, isEmpty);
    expect(ania.service.door, isNot(oldDoor.door));
    // The housemate follows.
    expect(ola.service.profile!.place, 'Lipowa 3/7');
    expect(ola.service.neighbors, isEmpty);
    expect(ola.service.messagesWith(bartek.service.profile!.key), isEmpty);
    expect(ola.service.door, ania.service.door);
    // The old neighbour is told and drops them.
    expect(bartek.service.neighbors, isEmpty);
    expect(bartek.shown.last.title, 'Nowakowie wyprowadzili się');
    expect(bartek.service.messagesWith(moved.key), isEmpty);

    // The new tenants make their own profile; the old sticker leads nowhere
    // (its door's key is gone with the old code).
    await nowi.service.createFlat('Kowalscy', place: 'm. 12');
    await nowi.service.scanDoor(oldDoor);
    expect(nowi.service.neighbors, isEmpty);
    expect(ania.service.doorCode!.inbox, isNot(oldDoor.inbox));
    await bartek.service.scanDoor(nowi.service.doorCode!);
    expect(bartek.service.neighbors.single.profile.label, 'Kowalscy · m. 12');
  });

  test('a household has no limit of residents', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone first = _Phone(net, 'p0');
    await first.service.createFlat('Akademik', place: 'pok. 5');
    final List<_Phone> others = <_Phone>[
      for (int i = 1; i <= 12; i++) _Phone(net, 'p$i'),
    ];
    for (final _Phone p in others) {
      expect(await p.service.joinFlat(first.service.homeCode!), isTrue);
    }
    expect(first.service.profile!.members, hasLength(13));
    expect(others.last.service.profile!.members, hasLength(13));
    expect(others.last.service.hasFlat, isTrue);
  });

  test('the state survives a restart', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie');
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    await bartek.service.sendMessage(ania.service.profile!.key, 'hej');

    final NeighborsService again = NeighborsService(
      host: ania,
      disk: ania.disk,
      now: () => ania.clock,
    );
    await again.load();
    expect(again.hasFlat, isTrue);
    expect(again.profile!.name, 'Nowakowie');
    expect(again.door, ania.service.door);
    expect(again.neighbors.single.profile.name, 'Bartkowie');
    expect(again.messagesWith(bartek.service.profile!.key).single.text, 'hej');
    // Still signs as the same flat.
    ania.service = again;
    await again.editProfile(about: 'nowe');
    await bartek.service.refresh(again.profile!.key);
    expect(bartek.service.neighbors.single.profile.about, 'nowe');
  });

  test('a flat has one small photo, signed with its profile', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie');
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    expect(bartek.service.neighbors.single.profile.photo, isEmpty);

    final Uint8List jpeg = compressFlatPhoto(
      Uint8List.fromList(img.encodePng(img.Image(width: 900, height: 600))),
    )!;
    expect(img.decodeJpg(jpeg)!.width, kFlatPhotoSide);
    expect(await ania.service.setPhoto(jpeg), isTrue);
    expect(base64Decode(ania.service.profile!.photo), jpeg);
    expect(await ania.service.profile!.verify(), isTrue);

    await bartek.service.refresh(ania.service.profile!.key);
    final FlatProfile seen = bartek.service.neighbors.single.profile;
    expect(base64Decode(seen.photo), jpeg);
    expect(await seen.verify(), isTrue);
    // It survives JSON; tampering with it breaks the signature.
    final FlatProfile back = FlatProfile.fromJson(
      jsonDecode(jsonEncode(seen.toJson())),
    )!;
    expect(await back.verify(), isTrue);
    final Map<String, dynamic> changed = seen.toJson()
      ..['ph'] = base64Encode(<int>[1, 2, 3]);
    expect(await FlatProfile.fromJson(changed)!.verify(), isFalse);
    // Too big is refused, also when it comes from elsewhere.
    expect(
      await ania.service.setPhoto(Uint8List(FlatProfile.maxPhotoChars)),
      isFalse,
    );
    final Map<String, dynamic> huge = seen.toJson()
      ..['ph'] = 'A' * (FlatProfile.maxPhotoChars + 4);
    expect(FlatProfile.fromJson(huge), isNull);

    expect(await ania.service.setPhoto(null), isTrue);
    expect(ania.service.profile!.photo, isEmpty);
    expect(ania.service.profile!.toJson().containsKey('ph'), isFalse);
  });

  test('housemates remove a phone that will not leave: a majority votes, '
      'the household gets a new key and door, neighbours follow', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone tomek = _Phone(net, 'tomek');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    await tomek.service.joinFlat(ania.service.homeCode!);
    expect(ania.service.profile!.members, hasLength(3));
    // Housemates know each other's names (neighbours do not).
    expect(ola.service.residentName(ania.address), 'ania');
    expect(ania.service.residentName(tomek.address), 'tomek');
    expect(tomek.service.residentName(ola.address), 'ola');

    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    final String oldKey = ania.service.profile!.key;
    final String oldDoor = ania.service.door;
    await bartek.service.sendMessage(oldKey, 'hej');
    expect(ola.service.messagesWith(bartek.service.profile!.key), hasLength(1));

    // Nobody removes themselves this way, or a stranger.
    expect(await tomek.service.voteRemove(tomek.address), isFalse);
    expect(await ania.service.voteRemove(bartek.address), isFalse);

    // One vote of two needed.
    expect(ania.service.votesNeeded(tomek.address), 2);
    expect(await ania.service.voteRemove(tomek.address), isTrue);
    expect(ania.service.profile!.key, oldKey);
    expect(ola.service.votesFor(tomek.address), <String>{ania.address});
    expect(ola.shown.last.title, 'Domownicy chcą odłączyć telefon');
    expect(
      tomek.service.votesFor(tomek.address),
      isEmpty,
      reason: 'the phone being removed is not asked',
    );
    // Taking the vote back, and voting again.
    await ania.service.withdrawVote(tomek.address);
    expect(ola.service.votesFor(tomek.address), isEmpty);
    await ania.service.voteRemove(tomek.address);

    // The second vote decides.
    await ola.service.voteRemove(tomek.address);
    final FlatProfile now = ania.service.profile!;
    expect(now.key, isNot(oldKey));
    expect(now.members, unorderedEquals(<String>[ania.address, ola.address]));
    expect(await now.verify(), isTrue);
    expect(ola.service.profile!.key, now.key);
    expect(ola.service.homeCode!.seed, ania.service.homeCode!.seed);
    expect(ania.service.door, isNot(oldDoor));
    expect(ola.service.door, ania.service.door);
    expect(ania.service.votesFor(tomek.address), isEmpty);
    expect(ania.service.residentName(tomek.address), isEmpty);
    // Tomek is left with the old key only.
    expect(tomek.service.profile!.key, oldKey);

    // The neighbour follows, messages and all.
    final NeighborFlat atBartek = bartek.service.neighbors.single;
    expect(atBartek.key, now.key);
    expect(atBartek.profile.members, hasLength(2));
    expect(bartek.service.messagesWith(now.key), hasLength(1));
    expect(bartek.shown.last.title, 'Nowakowie: zmiana domowników');

    // Tomek's old key reaches nobody any more.
    await tomek.service.sendMessage(bartek.service.profile!.key, 'to wciąż ja');
    expect(bartek.service.messagesWith(now.key), hasLength(1));
    expect(bartek.service.neighbors, hasLength(1));

    // The remaining two carry on with the new key.
    await bartek.service.sendMessage(now.key, 'cześć');
    expect(
      ania.service.messagesWith(bartek.service.profile!.key),
      hasLength(2),
    );
    expect(ola.service.messagesWith(bartek.service.profile!.key), hasLength(2));
    expect(
      tomek.service
          .messagesWith(bartek.service.profile!.key)
          .map((FlatMessage m) => m.text),
      isNot(contains('cześć')),
    );
    // A restart keeps the new key.
    final NeighborsService again = NeighborsService(
      host: ola,
      disk: ola.disk,
      now: () => ola.clock,
    );
    await again.load();
    expect(again.profile!.key, now.key);
  });

  test('in a household of two, one vote is enough', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone tomek = _Phone(net, 'tomek');
    await ania.service.createFlat('Mieszkanie');
    await tomek.service.joinFlat(ania.service.homeCode!);
    final String oldKey = ania.service.profile!.key;
    expect(ania.service.votesNeeded(tomek.address), 1);
    await ania.service.voteRemove(tomek.address);
    expect(ania.service.profile!.key, isNot(oldKey));
    expect(ania.service.profile!.members, <String>[ania.address]);
    expect(tomek.service.profile!.key, oldKey);
  });

  test('"Pokaż mój profil": one resident shows their own account to a '
      'neighbour flat', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie');
    await ola.service.joinFlat(ania.service.homeCode!);
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    final String aniaKey = ania.service.profile!.key;
    final String bartekKey = bartek.service.profile!.key;

    expect(bartek.service.revealsFrom(aniaKey), isEmpty);
    expect(await ania.service.revealMyProfile(bartekKey), isTrue);
    expect(ania.service.revealedTo(bartekKey), isTrue);
    expect(
      ola.service.revealedTo(bartekKey),
      isFalse,
      reason: 'each resident decides for themselves',
    );
    final FlatReveal r = bartek.service.revealsFrom(aniaKey).single;
    expect(r.name, 'ania');
    expect(r.address, ania.address);
    expect(bartek.shown.last.title, 'Nowakowie: ania pokazuje swój profil');

    // Again: no duplicate; Ola too.
    await ania.service.revealMyProfile(bartekKey);
    await ola.service.revealMyProfile(bartekKey);
    expect(
      bartek.service.revealsFrom(aniaKey).map((FlatReveal x) => x.name),
      unorderedEquals(<String>['ania', 'ola']),
    );
    // Not to strangers.
    expect(await ania.service.revealMyProfile('nieznany'), isFalse);

    final NeighborsService again = NeighborsService(
      host: bartek,
      disk: bartek.disk,
      now: () => bartek.clock,
    );
    await again.load();
    expect(again.revealsFrom(aniaKey), hasLength(2));
  });

  test('a removed phone that races a made-up new key to the neighbours '
      'gets nowhere: they follow the one the others made', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone tomek = _Phone(net, 'tomek');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    await tomek.service.joinFlat(ania.service.homeCode!);
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    final String oldKey = ania.service.profile!.key;
    // Bartek learnt each resident's own key with their profile.
    expect(
      bartek.service.neighbors.single.residents.keys,
      unorderedEquals(<String>[ania.address, ola.address, tomek.address]),
    );
    expect(
      bartek.service.neighbors.single.residents[tomek.address]!.key,
      tomek.service.residentKey,
    );
    for (final _Phone p in <_Phone>[ania, ola, tomek, bartek]) {
      p.clock += 2 * _day;
    }

    // Tomek is about to be removed and gets to Bartek first: "we removed
    // Ania", signed with the old flat key and his own resident key.
    final LedgerKeyPair fakeKey = await LedgerKeyPair.generate();
    final FlatProfile fake = await _fakeProfile(tomek, fakeKey, <String>[
      ola.address,
      tomek.address,
    ]);
    final Map<String, dynamic> asHimself = <String, dynamic>{
      'p': fake.toJson(),
      'a': ania.address,
      'by': tomek.address,
      'bs': (await tomek.service.residentSign(
        flatNewKeyBytes(oldKey, fakeKey.id, ania.address),
      ))!,
      'v': <String, String>{
        tomek.address: (await tomek.service.residentSign(
          flatKickBytes(oldKey, ania.address),
        ))!,
      },
    };
    await _raceNewKey(from: tomek, oldKey: oldKey, to: bartek, body: asHimself);
    // A notice with no one's signature but the flat's.
    await _raceNewKey(
      from: tomek,
      oldKey: oldKey,
      to: bartek,
      body: <String, dynamic>{'p': fake.toJson()},
    );
    // Pretending Ola made it, and voted.
    await _raceNewKey(
      from: tomek,
      oldKey: oldKey,
      to: bartek,
      body: <String, dynamic>{
        ...asHimself,
        'by': ola.address,
        'v': <String, String>{
          ...asHimself['v'] as Map<String, String>,
          ola.address: (await tomek.service.residentSign(
            flatKickBytes(oldKey, ania.address),
          ))!,
        },
      },
    );
    expect(bartek.service.neighbors.single.key, oldKey);
    expect(bartek.service.keyRival(oldKey), isNull);

    // The real vote: Ania and Ola remove Tomek.
    await ania.service.voteRemove(tomek.address);
    await ola.service.voteRemove(tomek.address);
    final FlatProfile now = ania.service.profile!;
    expect(now.key, isNot(oldKey));
    final NeighborFlat atBartek = bartek.service.neighbors.single;
    expect(atBartek.key, now.key);
    expect(
      atBartek.profile.members,
      unorderedEquals(<String>[ania.address, ola.address]),
    );
    expect(bartek.service.keyRival(now.key), isNull);
    expect(bartek.shown.last.title, 'Nowakowie: zmiana domowników');

    // Tomek's notice coming later changes nothing either.
    await _raceNewKey(from: tomek, oldKey: oldKey, to: bartek, body: asHimself);
    expect(bartek.service.neighbors.single.key, now.key);
    expect(bartek.service.keyRival(now.key), isNull);
    await bartek.service.sendMessage(now.key, 'cześć');
    expect(ola.service.messagesWith(bartek.service.profile!.key), hasLength(1));
    expect(tomek.service.messagesWith(bartek.service.profile!.key), isEmpty);
  });

  test(
    'in a household of two, two different new keys raise a warning '
    'instead of the first one winning; their new door code settles it',
    () async {
      final Map<String, _Phone> net = <String, _Phone>{};
      final _Phone ania = _Phone(net, 'ania');
      final _Phone tomek = _Phone(net, 'tomek');
      final _Phone bartek = _Phone(net, 'bartek');
      await ania.service.createFlat('Mieszkanie', place: 'm. 3');
      await tomek.service.joinFlat(ania.service.homeCode!);
      await bartek.service.createFlat('Bartkowie');
      await bartek.service.scanDoor(ania.service.doorCode!);
      final String oldKey = ania.service.profile!.key;
      final String bartekKey = bartek.service.profile!.key;
      for (final _Phone p in <_Phone>[ania, tomek, bartek]) {
        p.clock += 2 * _day;
      }

      // Tomek gets there first with "we removed Ania" — one vote of one, so
      // on its own it checks out.
      final LedgerKeyPair fakeKey = await LedgerKeyPair.generate();
      final FlatProfile fake = await _fakeProfile(tomek, fakeKey, <String>[
        tomek.address,
      ]);
      await _raceNewKey(
        from: tomek,
        oldKey: oldKey,
        to: bartek,
        body: <String, dynamic>{
          'p': fake.toJson(),
          'a': ania.address,
          'by': tomek.address,
          'bs': (await tomek.service.residentSign(
            flatNewKeyBytes(oldKey, fakeKey.id, ania.address),
          ))!,
          'v': <String, String>{
            tomek.address: (await tomek.service.residentSign(
              flatKickBytes(oldKey, ania.address),
            ))!,
          },
        },
      );
      expect(bartek.service.neighbors.single.key, fakeKey.id);

      // Then Ania's real one comes: the first is not taken silently.
      await ania.service.voteRemove(tomek.address);
      final String real = ania.service.profile!.key;
      expect(real, isNot(oldKey));
      expect(bartek.service.neighbors, hasLength(1));
      expect(bartek.service.keyRival(fakeKey.id)!.key, real);
      expect(bartek.shown.last.title, kFlatKeyConflict);

      // Bartek asks in person and scans the new code on their door.
      expect(
        await bartek.service.scanDoor(ania.service.doorCode!),
        FlatScan.alreadyNeighbor,
      );
      expect(bartek.service.neighbors.single.key, real);
      expect(bartek.service.keyRival(real), isNull);
      await bartek.service.sendMessage(real, 'dzień dobry');
      expect(ania.service.messagesWith(bartekKey), hasLength(1));
      // It stays settled after a restart.
      final NeighborsService again = NeighborsService(
        host: bartek,
        disk: bartek.disk,
        now: () => bartek.clock,
      );
      await again.load();
      expect(again.neighbors.single.key, real);
      expect(again.keyRival(real), isNull);
    },
  );
}
