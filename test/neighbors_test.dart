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
/// sends neighbours a "new key" notice of its own making, from its door.
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
  final Uint8List sig = await old.signWithKey(canonicalJsonBytes(signed));
  await from.doorSend(to.inbox!, <String, dynamic>{
    ...signed,
    's': b64(sig),
    '_rid': 'race-${from.doorSent.length}',
  });
}

/// The household's profile under a key [key] the cheat made, with the
/// residents [members] (resident keys; their doors as they are now).
Future<FlatProfile> _fakeProfile(
  _Phone cheat,
  LedgerKeyPair key,
  List<String> members,
) {
  final FlatProfile p = cheat.service.profile!;
  return p
      .copyWith(
        key: key.id,
        members: <String, String>{
          for (final String r in members) r: p.members[r] ?? '',
        },
        rev: 1,
      )
      .signedWith(key);
}

/// Gives work the services queued without waiting for it time to finish.
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _Phone implements EventHost {
  // Hex, so the addresses are routable when they travel in a QR code.
  _Phone(this.net, this.name)
    : address = addr((0xa0 + net.length).toRadixString(16)) {
    net[address] = this;
    service = restarted();
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

  /// A resident lets in whoever knocks right away; off, knocks wait
  /// for [NeighborsService.acceptKnock].
  bool autoOpen = true;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  /// What it sent from its own address, and from its door.
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> doorSent = <Map<String, dynamic>>[];

  /// Every address something reached this phone (or its door) from.
  final Set<String> heardFrom = <String>{};

  /// The service again, as after a restart (same disk, same door).
  NeighborsService restarted() => NeighborsService(
    host: this,
    disk: disk,
    now: () => clock,
    doorInbox: () => inbox,
    doorSend: doorSend,
  );

  /// Delivers [payload] from [from] to the phone or the door at [to], as
  /// the mesh and the bridge's doors do.
  Future<void> _deliver(
    String from,
    String to,
    Map<String, dynamic> payload,
  ) async {
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
    final Object? type = payload['type'];
    if (door && (!kFlatDoorTypes.contains(type) || type == FlatTypes.seal)) {
      // Like the bridge's door: flat frames only (sealed knocks go to
      // mailbox doors).
      return;
    }
    other.heardFrom.add(from);
    await other.service.handle(
      SignalTransportFrame(
        from: from,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
        door: door,
      ),
    );
    final Object? knocker = payload['f'];
    if (door &&
        type == FlatTypes.hello &&
        other.autoOpen &&
        knocker is String) {
      await other.service.acceptKnock(knocker);
    }
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    if (online) {
      await _deliver(address, to, payload);
    }
  }

  /// [NeighborsService.doorSend]: from this phone's door.
  Future<bool> doorSend(String to, Map<String, dynamic> payload) async {
    final String? from = inbox;
    if (!online || from == null) {
      return false;
    }
    doorSent.add(payload);
    await _deliver(from, to, payload);
    return true;
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

/// [p]'s resident key.
String _rk(_Phone p) => p.service.residentKey!;

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

  test('the door code never carries the residents addresses', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    await _settle();
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

  test('neighbours see doors and resident keys only: a resident\'s own '
      'address only after "Pokaż mój profil"', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    await _settle();
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    await ania.service.setShareWithScanners(true);
    final String aniaKey = ania.service.profile!.key;
    final String bartekKey = bartek.service.profile!.key;
    await ania.service.addItem(FlatItemKind.invite, 'Grill');
    await bartek.service.sendMessage(aniaKey, 'hej');
    await ola.service.sendMessage(bartekKey, 'cześć');
    await bartek.service.signUp(
      aniaKey,
      ania.service.profile!.of(FlatItemKind.invite).single.id,
      2,
    );
    await _settle();

    // The profile names each resident by a key of its own and the door its
    // phone runs.
    final FlatProfile seen = bartek.service.neighbors.single.profile;
    expect(seen.members, <String, String>{
      _rk(ania): ania.inbox!,
      _rk(ola): ola.inbox!,
    });
    final String everything =
        '${jsonEncode(seen.toJson())} '
        '${utf8.decode(bartek.disk.files['neighbors/state']!)}';
    for (final _Phone resident in <_Phone>[ania, ola]) {
      expect(everything.contains(resident.address), isFalse);
      // Nothing came to Bartek from their own addresses, nor went to them.
      expect(bartek.heardFrom, isNot(contains(resident.address)));
    }
    expect(ania.heardFrom, isNot(contains(bartek.address)));
    expect(bartek.sent, isEmpty, reason: 'all of it went from the door');
    expect(
      ola.service.messagesWith(bartekKey).map((FlatMessage m) => m.text),
      containsAll(<String>['hej', 'cześć']),
    );
    // Neighbour frames never come phone to phone, housemates' never
    // through a door.
    expect(
      await ania.service.handle(
        SignalTransportFrame(
          from: bartek.address,
          payload: bartek.doorSent.first,
          receivedAtMillis: 0,
        ),
      ),
      isFalse,
    );
    expect(
      await ania.service.handle(
        SignalTransportFrame(
          from: ola.inbox!,
          payload: ola.sent.first,
          receivedAtMillis: 0,
          door: true,
        ),
      ),
      isFalse,
    );

    // "Pokaż mój profil": now (and only now) Bartek learns Ania's address.
    await ania.service.revealMyProfile(bartekKey);
    expect(bartek.service.revealsFrom(aniaKey).single.address, ania.address);
    expect(bartek.heardFrom, contains(ania.address));
    expect(bartek.heardFrom, isNot(contains(ola.address)));

    // What the doors took was confirmed; what reached Ola before she knew
    // Bartek is confirmed on the next try. Nothing waits to be retried.
    bartek.clock += 60 * 1000;
    await bartek.service.retryDoorSends();
    await _settle();
    expect(bartek.service.doorOutbox, 0);
    expect(ola.service.doorOutbox, 0);
  });

  test('frames that did not arrive are retried from the door until a door '
      'confirms them', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie');
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    final String aniaKey = ania.service.profile!.key;
    final String bartekKey = bartek.service.profile!.key;
    await _settle();
    expect(bartek.service.doorOutbox, 0);

    ania.online = false;
    await bartek.service.sendMessage(aniaKey, 'jesteście?');
    expect(bartek.service.doorOutbox, 1);
    // Not yet due, then due: the same frame, the same id.
    await bartek.service.retryDoorSends();
    expect(
      bartek.doorSent.where(
        (Map<String, dynamic> m) => m['type'] == FlatTypes.message,
      ),
      hasLength(1),
    );
    ania.online = true;
    bartek.clock += 60 * 1000;
    await bartek.service.retryDoorSends();
    await _settle();
    expect(ania.service.messagesWith(bartekKey).single.text, 'jesteście?');
    expect(bartek.service.doorOutbox, 0);
    final List<Map<String, dynamic>> tries = <Map<String, dynamic>>[
      for (final Map<String, dynamic> m in bartek.doorSent)
        if (m['type'] == FlatTypes.message) m,
    ];
    expect(tries, hasLength(2));
    expect(tries.first['_rid'], tries.last['_rid']);

    // A frame waits on disk, and gives up after a while.
    ania.online = false;
    await bartek.service.sendMessage(aniaKey, 'halo');
    bartek.service = bartek.restarted();
    await bartek.service.load();
    expect(bartek.service.doorOutbox, 1);
    bartek.clock += kFlatSendLife.inMilliseconds;
    await bartek.service.retryDoorSends();
    expect(bartek.service.doorOutbox, 0);
  });

  test('a knock waits for a resident: nothing goes back before "Wpuść", '
      'refused and expired knocks stay unanswered', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania')..autoOpen = false;
    final _Phone bartek = _Phone(net, 'bartek');
    final _Phone cyryl = _Phone(net, 'cyryl');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    await bartek.service.createFlat('Bartkowie');
    await cyryl.service.createFlat('Cyryl');
    final String bartekKey = bartek.service.profile!.key;

    final int before = ania.sent.length + ania.doorSent.length;
    expect(
      await bartek.service.scanDoor(ania.service.doorCode!),
      FlatScan.sent,
    );
    // Not a word from Ania's phone or door yet: an answer would say whose
    // door it is, or that its phone is online.
    await _settle();
    expect(ania.sent.length + ania.doorSent.length, before);
    expect(ania.service.neighbors, isEmpty);
    expect(bartek.service.neighbors, isEmpty);
    expect(bartek.service.pending.keys, <String>[ania.service.profile!.key]);
    expect(ania.service.knocks.single.key, bartekKey);
    expect(ania.service.knocks.single.sender, bartek.inbox);
    expect(ania.shown.last.title, 'Bartkowie puka do drzwi');
    // The knock waits on disk too (the background service took it).
    final NeighborsService again = ania.restarted();
    await again.load();
    expect(again.knocks.single.profile.name, 'Bartkowie');

    // "Wpuść": now the profiles go both ways.
    expect(await ania.service.acceptKnock(bartekKey), isTrue);
    expect(ania.service.knocks, isEmpty);
    expect(ania.service.neighbors.single.scannedUs, isTrue);
    expect(bartek.service.neighbors.single.profile.name, 'Nowakowie');
    expect(bartek.service.pending, isEmpty);
    // Let in: the knock is not retried any more.
    await _settle();
    expect(
      bartek.service.doorOutbox,
      0,
      reason: 'the knock went, the rest was confirmed',
    );

    // "Odmów": nothing goes back, and the knocker's retries of the same
    // knock do not ask again.
    await cyryl.service.scanDoor(ania.service.doorCode!);
    final Map<String, dynamic> knock = cyryl.doorSent.last;
    expect(knock['type'], FlatTypes.hello);
    final String cyrylKey = cyryl.service.profile!.key;
    final SignalTransportFrame retried = SignalTransportFrame(
      from: cyryl.inbox!,
      payload: knock,
      receivedAtMillis: 0,
      door: true,
    );
    await ania.service.handle(retried);
    expect(ania.service.knocks.single.key, cyrylKey);
    final int sentBefore = ania.sent.length + ania.doorSent.length;
    await ania.service.rejectKnock(cyrylKey);
    expect(ania.service.knocks, isEmpty);
    await ania.service.handle(retried);
    cyryl.clock += 60 * 1000;
    await cyryl.service.retryDoorSends();
    await _settle();
    expect(ania.service.knocks, isEmpty);
    expect(ania.sent.length + ania.doorSent.length, sentBefore);
    expect(cyryl.service.neighbors, isEmpty);

    // The same knock again (another retry id, as it comes through the
    // mailbox doors) does not ask again either; a new scan does, and after
    // a week it is gone.
    await ania.service.handle(
      SignalTransportFrame(
        from: cyryl.inbox!,
        payload: <String, dynamic>{...knock, '_rid': 'r2'},
        receivedAtMillis: 0,
        door: true,
      ),
    );
    expect(ania.service.knocks, isEmpty);
    await cyryl.service.scanDoor(ania.service.doorCode!);
    expect(ania.service.knocks.single.key, cyrylKey);
    ania.clock += kKnockLife.inMilliseconds;
    expect(ania.service.knocks, isEmpty);
    expect(await ania.service.acceptKnock(cyrylKey), isFalse);
    expect(ania.service.neighbors, hasLength(1));
    expect(cyryl.service.neighbors, isEmpty);

    // Housemates' frames are never taken at the door.
    expect(
      await ania.service.handle(
        SignalTransportFrame(
          from: cyryl.inbox!,
          payload: <String, dynamic>{...knock, 'type': FlatTypes.house},
          receivedAtMillis: 0,
          door: true,
        ),
      ),
      isFalse,
    );
  });

  test('knock notifications: one per knocker, a few an hour', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania')..autoOpen = false;
    await ania.service.createFlat('Nowakowie');
    final List<_Phone> knockers = <_Phone>[
      for (int i = 0; i < kKnockRingsPerHour + 3; i++) _Phone(net, 'k$i'),
    ];
    for (final _Phone k in knockers) {
      await k.service.createFlat('Flat ${k.name}');
    }
    List<RuntimeSystemNotification> rings() => <RuntimeSystemNotification>[
      for (final RuntimeSystemNotification n in ania.shown)
        if (n.id.startsWith('flat-knock')) n,
    ];

    // The same flat knocking again and again (new scans): one notification,
    // in its own slot, replaced rather than piled up.
    final _Phone first = knockers.first;
    for (int i = 0; i < 3; i++) {
      await first.service.scanDoor(ania.service.doorCode!);
      await ania.service.rejectKnock(first.service.profile!.key);
    }
    expect(rings(), hasLength(1));
    expect(rings().single.slotKey, 'flat-knock:${first.service.profile!.key}');

    // Many flats: no more than kKnockRingsPerHour an hour; the knocks still
    // wait in the list.
    for (final _Phone k in knockers.skip(1)) {
      await k.service.scanDoor(ania.service.doorCode!);
    }
    expect(rings(), hasLength(kKnockRingsPerHour));
    expect(ania.service.knocks, hasLength(knockers.length - 1));
    expect(
      rings().map((RuntimeSystemNotification n) => n.id).toSet(),
      hasLength(kKnockRingsPerHour),
    );

    // An hour later, a knock rings again.
    ania.clock += 3600 * 1000;
    await first.service.scanDoor(ania.service.doorCode!);
    expect(rings(), hasLength(kKnockRingsPerHour + 1));
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
    expect(ania.service.profile!.members, <String, String>{
      _rk(ania): ania.inbox!,
    });

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
    expect(ania.shown.last.title, 'Bartkowie, m. 14 puka do drzwi');
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
      await _settle();
      expect(ola.service.hasFlat, isTrue);
      expect(ola.service.joining, isFalse);
      expect(ola.service.profile!.key, ania.service.profile!.key);
      // Each resident with the door of its phone, never the phone.
      expect(ania.service.profile!.members, <String, String>{
        _rk(ania): ania.inbox!,
        _rk(ola): ola.inbox!,
      });
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
      expect(ania.service.profile!.members.keys, <String>[_rk(ania)]);
    },
  );

  test('a new door code makes the old one useless; forged messages are '
      'ignored', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone ola = _Phone(net, 'ola');
    final _Phone dorota = _Phone(net, 'dorota');
    final _Phone eve = _Phone(net, 'eve');
    await ania.service.createFlat('Nowakowie, m. 12');
    await ola.service.joinFlat(ania.service.homeCode!);
    await dorota.service.createFlat('Dorota, m. 7');
    await eve.service.createFlat('Eve, m. 1');
    await _settle();

    final FlatDoorCode old = ania.service.doorCode!;
    final String? oldKey = ania.service.doorKey;
    final String olaDoor = ola.inbox!;
    await ania.service.newDoor();
    await _settle();
    // A new code is a new door: new key, new address, for every resident;
    // the profile names the new doors.
    expect(ania.service.doorKey, isNot(oldKey));
    expect(ania.service.doorCode!.inbox, isNot(old.inbox));
    expect(ola.inbox, isNot(olaDoor));
    expect(ania.service.profile!.members, <String, String>{
      _rk(ania): ania.inbox!,
      _rk(ola): ola.inbox!,
    });
    expect(ola.service.profile!.members, ania.service.profile!.members);
    await dorota.service.scanDoor(old);
    // The old door's address answers no more: nothing reaches Ania.
    expect(dorota.service.neighbors, isEmpty);
    expect(dorota.service.pending.keys, <String>[old.key]);
    expect(ania.service.neighbors, isEmpty);

    // A knock at the live door with a wrong token gets no answer.
    final int before = ania.sent.length + ania.doorSent.length;
    await dorota.service.scanDoor(
      FlatDoorCode(
        key: old.key,
        door: 'guess',
        inbox: ania.service.doorCode!.inbox,
        name: old.name,
      ),
    );
    await _settle();
    expect(ania.sent.length + ania.doorSent.length, before);
    expect(ania.service.neighbors, isEmpty);
    expect(dorota.service.staleDoors, isEmpty);

    // Eve was never let in: her messages, sign-ups and profiles are dropped.
    final String ownKey = ania.service.profile!.key;
    await ania.service.handle(
      SignalTransportFrame(
        from: eve.inbox!,
        payload: <String, dynamic>{
          'type': FlatTypes.message,
          'f': eve.service.profile!.key,
          'to': ownKey,
          'b': <String, dynamic>{'id': 'x1', 't': 'spam'},
          's': 'AAAA',
        },
        receivedAtMillis: 0,
        door: true,
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
          'b': <String, dynamic>{'a': eve.address, 'rk': _rk(eve)},
          's': base64Url.encode(List<int>.filled(64, 1)),
        },
        receivedAtMillis: 0,
      ),
    );
    expect(ania.service.profile!.members, hasLength(2));
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
    await _settle();
    final FlatDoorCode oldDoor = ania.service.doorCode!;
    await bartek.service.scanDoor(oldDoor);
    await ania.service.addItem(FlatItemKind.offer, 'Pożyczę drabinę');
    await bartek.service.sendMessage(ania.service.profile!.key, 'hej');
    expect(ola.service.neighbors, hasLength(1));

    ania.clock += 100;
    await ania.service.moveOut(newPlace: 'Lipowa 3/7');
    await _settle();
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
    await _settle();
    expect(first.service.profile!.members, hasLength(13));
    expect(others.last.service.profile!.members, hasLength(13));
    expect(others.last.service.hasFlat, isTrue);
    // Every resident's door made it into the profile everyone holds.
    expect(first.service.profile!.members.values.toSet(), <String>{
      for (final _Phone p in <_Phone>[first, ...others]) p.inbox!,
    });
  });

  test('the state survives a restart', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone bartek = _Phone(net, 'bartek');
    await ania.service.createFlat('Nowakowie');
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    await bartek.service.sendMessage(ania.service.profile!.key, 'hej');

    final NeighborsService again = ania.restarted();
    await again.load();
    expect(again.hasFlat, isTrue);
    expect(again.profile!.name, 'Nowakowie');
    expect(again.door, ania.service.door);
    expect(again.residentKey, ania.service.residentKey);
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
    // So is a list of residents long enough to make other phones send to
    // doors its maker picked.
    final Map<String, dynamic> crowded = seen.toJson()
      ..['m'] = <String, String>{
        for (int i = 0; i <= FlatProfile.maxMembers; i++)
          b64(List<int>.filled(32, i)): addr(i.toRadixString(16)),
      };
    expect(FlatProfile.fromJson(crowded), isNull);
    // A resident that is not a key, or a door that is not an address, is
    // left out.
    final Map<String, dynamic> odd = seen.toJson()
      ..['m'] = <String, String>{
        'nope': addr('1'),
        b64(List<int>.filled(32, 1)): 'not an address',
        b64(List<int>.filled(32, 2)): addr('2'),
      };
    expect(FlatProfile.fromJson(odd)!.members, <String, String>{
      b64(List<int>.filled(32, 2)): addr('2'),
    });

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
    await _settle();
    expect(ania.service.profile!.members, hasLength(3));
    // Housemates know each other's names (neighbours do not).
    expect(ola.service.residentName(_rk(ania)), 'ania');
    expect(ania.service.residentName(_rk(tomek)), 'tomek');
    expect(tomek.service.residentName(_rk(ola)), 'ola');

    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    final String oldKey = ania.service.profile!.key;
    final String oldDoor = ania.service.door;
    await bartek.service.sendMessage(oldKey, 'hej');
    expect(ola.service.messagesWith(bartek.service.profile!.key), hasLength(1));

    // Nobody removes themselves this way, or a stranger.
    expect(await tomek.service.voteRemove(_rk(tomek)), isFalse);
    expect(await ania.service.voteRemove(_rk(bartek)), isFalse);

    // One vote of two needed.
    expect(ania.service.votesNeeded(_rk(tomek)), 2);
    expect(await ania.service.voteRemove(_rk(tomek)), isTrue);
    expect(ania.service.profile!.key, oldKey);
    expect(ola.service.votesFor(_rk(tomek)), <String>{_rk(ania)});
    expect(ola.shown.last.title, 'Domownicy chcą odłączyć telefon');
    expect(
      tomek.service.votesFor(_rk(tomek)),
      isEmpty,
      reason: 'the phone being removed is not asked',
    );
    // Taking the vote back, and voting again.
    await ania.service.withdrawVote(_rk(tomek));
    expect(ola.service.votesFor(_rk(tomek)), isEmpty);
    await ania.service.voteRemove(_rk(tomek));

    // The second vote decides.
    await ola.service.voteRemove(_rk(tomek));
    await _settle();
    final FlatProfile now = ania.service.profile!;
    expect(now.key, isNot(oldKey));
    expect(now.members.keys, unorderedEquals(<String>[_rk(ania), _rk(ola)]));
    expect(await now.verify(), isTrue);
    expect(ola.service.profile!.key, now.key);
    expect(ola.service.homeCode!.seed, ania.service.homeCode!.seed);
    expect(ania.service.door, isNot(oldDoor));
    expect(ola.service.door, ania.service.door);
    expect(ania.service.votesFor(_rk(tomek)), isEmpty);
    expect(ania.service.residentName(_rk(tomek)), isEmpty);
    // Tomek is left with the old key only.
    expect(tomek.service.profile!.key, oldKey);

    // The neighbour follows, messages and all, and learns the new doors.
    final NeighborFlat atBartek = bartek.service.neighbors.single;
    expect(atBartek.key, now.key);
    expect(atBartek.profile.members.keys, hasLength(2));
    expect(bartek.service.messagesWith(now.key), hasLength(1));
    expect(bartek.shown.last.title, 'Nowakowie: zmiana domowników');

    // Tomek's old key reaches nobody any more.
    await tomek.service.sendMessage(bartek.service.profile!.key, 'to wciąż ja');
    expect(bartek.service.messagesWith(now.key), hasLength(1));
    expect(bartek.service.neighbors, hasLength(1));

    // The remaining two carry on with the new key.
    await bartek.service.refresh(now.key);
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
    final NeighborsService again = ola.restarted();
    await again.load();
    expect(again.profile!.key, now.key);
  });

  test('in a household of two, one vote is enough', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = _Phone(net, 'ania');
    final _Phone tomek = _Phone(net, 'tomek');
    await ania.service.createFlat('Mieszkanie');
    await tomek.service.joinFlat(ania.service.homeCode!);
    await _settle();
    final String oldKey = ania.service.profile!.key;
    expect(ania.service.votesNeeded(_rk(tomek)), 1);
    await ania.service.voteRemove(_rk(tomek));
    expect(ania.service.profile!.key, isNot(oldKey));
    expect(ania.service.profile!.members.keys, <String>[_rk(ania)]);
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
    await _settle();
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
    expect(r.resident, _rk(ania));
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
    // Only the phone itself shows its own account: Ola cannot pass Ania's
    // address off as hers.
    final Map<String, dynamic> forged = Map<String, dynamic>.from(
      ola.sent.last,
    );
    await bartek.service.handle(
      SignalTransportFrame(
        from: ania.address,
        payload: forged,
        receivedAtMillis: 0,
        door: true,
      ),
    );
    expect(
      bartek.service.revealsFrom(aniaKey).map((FlatReveal x) => x.address),
      unorderedEquals(<String>[ania.address, ola.address]),
    );

    final NeighborsService again = bartek.restarted();
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
    await _settle();
    await bartek.service.createFlat('Bartkowie');
    await bartek.service.scanDoor(ania.service.doorCode!);
    final String oldKey = ania.service.profile!.key;
    // Bartek learnt each resident's own key with their profile.
    expect(
      bartek.service.neighbors.single.residents.keys,
      unorderedEquals(<String>[_rk(ania), _rk(ola), _rk(tomek)]),
    );
    for (final _Phone p in <_Phone>[ania, ola, tomek, bartek]) {
      p.clock += 2 * _day;
    }

    // Tomek is about to be removed and gets to Bartek first: "we removed
    // Ania", signed with the old flat key and his own resident key.
    final LedgerKeyPair fakeKey = await LedgerKeyPair.generate();
    final FlatProfile fake = await _fakeProfile(tomek, fakeKey, <String>[
      _rk(ola),
      _rk(tomek),
    ]);
    final Map<String, dynamic> asHimself = <String, dynamic>{
      'p': fake.toJson(),
      'a': _rk(ania),
      'by': _rk(tomek),
      'bs': (await tomek.service.residentSign(
        flatNewKeyBytes(oldKey, fakeKey.id, _rk(ania)),
      ))!,
      'v': <String, String>{
        _rk(tomek): (await tomek.service.residentSign(
          flatKickBytes(oldKey, _rk(ania)),
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
        'by': _rk(ola),
        'v': <String, String>{
          ...asHimself['v'] as Map<String, String>,
          _rk(ola): (await tomek.service.residentSign(
            flatKickBytes(oldKey, _rk(ania)),
          ))!,
        },
      },
    );
    expect(bartek.service.neighbors.single.key, oldKey);
    expect(bartek.service.keyRival(oldKey), isNull);

    // The real vote: Ania and Ola remove Tomek.
    await ania.service.voteRemove(_rk(tomek));
    await ola.service.voteRemove(_rk(tomek));
    await _settle();
    final FlatProfile now = ania.service.profile!;
    expect(now.key, isNot(oldKey));
    final NeighborFlat atBartek = bartek.service.neighbors.single;
    expect(atBartek.key, now.key);
    expect(
      atBartek.profile.members.keys,
      unorderedEquals(<String>[_rk(ania), _rk(ola)]),
    );
    expect(bartek.service.keyRival(now.key), isNull);
    expect(bartek.shown.last.title, 'Nowakowie: zmiana domowników');

    // Tomek's notice coming later changes nothing either.
    await _raceNewKey(from: tomek, oldKey: oldKey, to: bartek, body: asHimself);
    expect(bartek.service.neighbors.single.key, now.key);
    expect(bartek.service.keyRival(now.key), isNull);
    await bartek.service.refresh(now.key);
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
      await _settle();
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
        _rk(tomek),
      ]);
      await _raceNewKey(
        from: tomek,
        oldKey: oldKey,
        to: bartek,
        body: <String, dynamic>{
          'p': fake.toJson(),
          'a': _rk(ania),
          'by': _rk(tomek),
          'bs': (await tomek.service.residentSign(
            flatNewKeyBytes(oldKey, fakeKey.id, _rk(ania)),
          ))!,
          'v': <String, String>{
            _rk(tomek): (await tomek.service.residentSign(
              flatKickBytes(oldKey, _rk(ania)),
            ))!,
          },
        },
      );
      expect(bartek.service.neighbors.single.key, fakeKey.id);

      // Then Ania's real one comes: the first is not taken silently.
      await ania.service.voteRemove(_rk(tomek));
      await _settle();
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
      final NeighborsService again = bartek.restarted();
      await again.load();
      expect(again.neighbors.single.key, real);
      expect(again.keyRival(real), isNull);
    },
  );
}
