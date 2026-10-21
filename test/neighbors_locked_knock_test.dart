import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/locked_knocks.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String _addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

/// Gives work the services queued without waiting for it time to finish.
Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A phone with the neighbours section, on a mesh of a few phones: an
/// offline one takes nothing (its frames are what a locked phone would get).
final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = _addr((0xa0 + net.length).toRadixString(16)) {
    net[address] = this;
    service = NeighborsService(
      host: this,
      disk: MemoryLedgerDisk(),
      now: () => clock,
      doorInbox: () => inbox,
      doorSend: doorSend,
    );
  }

  final Map<String, _Phone> net;
  final String name;
  final String address;
  late final NeighborsService service;
  int clock = 1000;
  bool online = true;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> doorSent = <Map<String, dynamic>>[];

  String? get inbox {
    final String? key = service.doorKey;
    return key == null ? null : _addr('d0:${key.substring(0, 4)}');
  }

  /// What the locked background service of this phone gets from the app.
  LockedDoorKit get kit => LockedDoorKit(
    doorKey: service.doorKey,
    flatKey: service.profile?.key,
    doorToken: service.door,
    sealSeed: service.sealSeed,
    tempTokens: service.tempDoorTokens,
  );

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
    await other.service.handle(
      SignalTransportFrame(
        from: from,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
        door: door,
      ),
    );
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add(payload);
    await _deliver(address, to, payload);
  }

  Future<bool> doorSend(String to, Map<String, dynamic> payload) async {
    final String? from = inbox;
    if (from == null) {
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
  Future<void> notify(RuntimeSystemNotification n) async {}
}

/// [newcomer] joins [housemate]'s household: a one-time household code,
/// and the housemate confirms it on their phone ("Dołącz").
Future<bool> _join(_Phone newcomer, _Phone housemate) async {
  final FlatHomeCode code = housemate.service.inviteHousemate()!;
  if (!await newcomer.service.joinFlat(code)) {
    return false;
  }
  await _settle();
  final String? me = newcomer.service.residentKey;
  final FlatJoinRequest request = housemate.service.joinRequests.firstWhere(
    (FlatJoinRequest r) => r.resident == me,
  );
  if (!await housemate.service.approveJoin(request.id)) {
    return false;
  }
  await _settle();
  return true;
}

/// The household Nowakowie (Ania and Ola) and a knocker, Bartek.
Future<(_Phone, _Phone, _Phone)> _household() async {
  final Map<String, _Phone> net = <String, _Phone>{};
  final _Phone ania = _Phone(net, 'ania');
  final _Phone ola = _Phone(net, 'ola');
  final _Phone bartek = _Phone(net, 'bartek');
  await ania.service.createFlat('Nowakowie', place: 'm. 12');
  await _join(ola, ania);
  await _settle();
  await bartek.service.createFlat('Bartkowie');
  return (ania, ola, bartek);
}

SignalTransportFrame _at(String from, Map<String, dynamic> payload) =>
    SignalTransportFrame(
      from: from,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
      door: true,
    );

Map<String, dynamic> _ofType(_Phone p, String type) =>
    p.doorSent.lastWhere((Map<String, dynamic> m) => m['type'] == type);

void main() {
  test('while locked, the door kit tells a real knock from anything else, '
      'without the household\'s key', () async {
    final (_Phone ania, _Phone ola, _Phone bartek) = await _household();
    final String bartekKey = bartek.service.profile!.key;
    final FlatDoorCode code = ania.service.doorCode!;
    // Both phones of the household are locked: the frames stop at their
    // doors.
    ania.online = false;
    ola.online = false;
    await bartek.service.scanDoor(code);

    LockedKnockWatch watch(_Phone p) => LockedKnockWatch(
      flatKey: p.service.profile!.key,
      doorToken: p.service.door,
      sealSeed: p.service.sealSeed!,
      now: () => p.clock,
    );
    final LockedKnockWatch atAnia = watch(ania);
    final LockedKnockWatch atOla = watch(ola);

    // At the door on the sticker: the knock itself.
    final Map<String, dynamic> hello = _ofType(bartek, FlatTypes.hello);
    expect(await atAnia.knocker(_at(bartek.inbox!, hello)), bartekKey);
    // At a housemate's door: sealed, opened with the household's seal.
    final Map<String, dynamic> sealed = _ofType(bartek, FlatTypes.seal);
    expect(sealed['d'], ola.inbox);
    expect(jsonEncode(sealed).contains('Bartkowie'), isFalse);
    expect(await atOla.knocker(_at(bartek.inbox!, sealed)), bartekKey);
    // Held by a friend while the phone was off.
    final Map<String, dynamic> held = <String, dynamic>{
      'type': FlatTypes.held,
      'd': sealed['d'],
      'x': sealed['x'],
      'n': sealed['n'],
      'c': sealed['c'],
      'k': sealed['k'],
      'p': ?sealed['p'],
      'q': ?sealed['q'],
      'at': ania.clock,
    };
    expect(
      await atAnia.knocker(
        SignalTransportFrame(
          from: _addr('f1'),
          payload: held,
          receivedAtMillis: 0,
        ),
      ),
      bartekKey,
    );
    // A week later it no longer rings.
    ania.clock += kHeldKnockLife.inMilliseconds;
    expect(
      await atAnia.knocker(
        SignalTransportFrame(
          from: _addr('f1'),
          payload: held,
          receivedAtMillis: 0,
        ),
      ),
      isNull,
    );
    ania.clock -= kHeldKnockLife.inMilliseconds;

    // Not a knock: a wrong token, another household's door, a frame of
    // another kind, one that is not signed.
    await bartek.service.scanDoor(
      FlatDoorCode(
        key: code.key,
        door: 'guess',
        inbox: code.inbox,
        name: code.name,
      ),
    );
    expect(
      await atAnia.knocker(
        _at(bartek.inbox!, _ofType(bartek, FlatTypes.hello)),
      ),
      isNull,
    );
    final _Phone cyryl = _Phone(ania.net, 'cyryl');
    await cyryl.service.createFlat('Cyryl');
    cyryl.online = false;
    await bartek.service.scanDoor(cyryl.service.doorCode!);
    expect(
      await atAnia.knocker(
        _at(bartek.inbox!, _ofType(bartek, FlatTypes.hello)),
      ),
      isNull,
    );
    expect(
      await atAnia.knocker(
        _at(bartek.inbox!, <String, dynamic>{...hello, 'type': 'flat_msg'}),
      ),
      isNull,
    );
    expect(
      await atAnia.knocker(
        _at(bartek.inbox!, <String, dynamic>{...hello, 's': 'AAAA'}),
      ),
      isNull,
    );
    // Sealed for this household, but the kit of another opens nothing.
    expect(
      await LockedKnockWatch(
        flatKey: cyryl.service.profile!.key,
        doorToken: cyryl.service.door,
        sealSeed: cyryl.service.sealSeed!,
      ).knocker(_at(bartek.inbox!, sealed)),
      isNull,
    );
  });

  test('while locked, a knock a housemate passed on rings too', () async {
    final (_Phone ania, _Phone ola, _Phone bartek) = await _household();
    final String bartekKey = bartek.service.profile!.key;
    ola.online = false;
    // Ania's phone is unlocked and takes the knock; Ola's is locked.
    final int before = ania.sent.length;
    await bartek.service.scanDoor(ania.service.doorCode!);
    final List<Map<String, dynamic>> house = <Map<String, dynamic>>[
      for (final Map<String, dynamic> m in ania.sent.skip(before))
        if (m['type'] == FlatTypes.house) m,
    ];
    expect(house, isNotEmpty);
    final LockedKnockWatch atOla = LockedKnockWatch(
      flatKey: ola.service.profile!.key,
      doorToken: ola.service.door,
      sealSeed: ola.service.sealSeed!,
      now: () => ola.clock,
    );
    SignalTransportFrame fromAnia(Map<String, dynamic> p) =>
        SignalTransportFrame(
          from: ania.address,
          payload: jsonDecode(jsonEncode(p)) as Map<String, dynamic>,
          receivedAtMillis: 0,
        );
    expect(await atOla.knocker(fromAnia(house.first)), bartekKey);
    // Shared state without a new knock, or not signed by the household,
    // does not ring.
    final Map<String, dynamic> quiet =
        jsonDecode(jsonEncode(house.first)) as Map<String, dynamic>;
    (quiet['b'] as Map<String, dynamic>).remove('ring');
    expect(await atOla.knocker(fromAnia(quiet)), isNull);
    expect(
      await atOla.knocker(
        fromAnia(<String, dynamic>{...house.first, 's': 'AAAA'}),
      ),
      isNull,
    );

    // As in the app: one knocker rings once an hour, a few an hour in all.
    expect(atOla.mayRing(bartekKey), isTrue);
    expect(atOla.mayRing(bartekKey), isFalse);
    for (int i = 1; i < kKnockRingsPerHour; i++) {
      expect(atOla.mayRing('flat-$i'), isTrue);
    }
    expect(atOla.mayRing('one-more'), isFalse);
    ola.clock += 3600 * 1000;
    expect(atOla.mayRing(bartekKey), isTrue);
  });

  test('while locked, a knock with an invitation\'s short-lived code rings '
      'until the code is over', () async {
    final (_Phone ania, _Phone _, _Phone bartek) = await _household();
    final String grill = (await ania.service.addItem(
      FlatItemKind.invite,
      'Grill',
    ))!;
    final FlatDoorCode code = FlatDoorCode.parse(
      (await ania.service.nearbyWave(grill))!['q'] as String,
    )!;
    final LockedDoorKit kit = LockedDoorKit.fromJson(
      jsonDecode(jsonEncode(ania.kit.toJson())),
    )!;
    expect(kit.tempTokens, <String, int>{code.door: code.until!});
    ania.online = false;
    await bartek.service.scanDoor(code);
    final Map<String, dynamic> hello = _ofType(bartek, FlatTypes.hello);
    LockedKnockWatch watch(Map<String, int> temp) => LockedKnockWatch(
      flatKey: ania.service.profile!.key,
      doorToken: ania.service.door,
      sealSeed: ania.service.sealSeed!,
      tempTokens: temp,
      now: () => ania.clock,
    );
    expect(
      await watch(kit.tempTokens).knocker(_at(bartek.inbox!, hello)),
      bartek.service.profile!.key,
    );
    expect(
      await watch(const <String, int>{}).knocker(_at(bartek.inbox!, hello)),
      isNull,
    );
    ania.clock += kNearbyCodeLife.inMilliseconds;
    expect(
      await watch(kit.tempTokens).knocker(_at(bartek.inbox!, hello)),
      isNull,
    );
  });

  group('the locked receiver', () {
    late Directory support;
    late MemorySecurityCredentialsStore credentials;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('zen-knock-');
      credentials = MemorySecurityCredentialsStore();
    });

    tearDown(() async {
      if (await support.exists()) {
        await support.delete(recursive: true);
      }
    });

    test('rings "Ktoś puka do drzwi" for a real knock, says nothing of who, '
        'answers nothing, and opens the knocks', () async {
      final (_Phone ania, _Phone _, _Phone bartek) = await _household();
      ania.online = false;
      await bartek.service.scanDoor(ania.service.doorCode!);
      final Map<String, dynamic> hello = _ofType(bartek, FlatTypes.hello);

      // The kit the app writes for the background service, and back.
      final BackgroundKitFile file = lockedDoorKitFile(
        supportDirectory: () async => support,
        credentials: credentials,
        createKey: true,
      );
      await file.write(ania.kit.toJson());
      final LockedDoorKit kit = LockedDoorKit.fromJson(
        await lockedDoorKitFile(
          supportDirectory: () async => support,
          credentials: credentials,
        ).read(),
      )!;
      expect(kit.flatKey, ania.service.profile!.key);
      expect(kit.doorToken, ania.service.door);
      expect(kit.sealSeed, ania.service.sealSeed);
      expect(
        LockedDoorKit.fromJson(<String, dynamic>{
          'v': 1,
          'fk': ania.service.profile!.key,
          'dt': ania.service.door,
          'ss': 'not a seed',
        })!.knockWatch(),
        isNull,
      );

      final FileBackgroundVault appVault = FileBackgroundVault(
        supportDirectory: () async => support,
        credentials: credentials,
        createKey: true,
      );
      final Uint8List masterKey = Uint8List.fromList(
        List<int>.generate(32, (int i) => i + 3),
      );
      await appVault.publish(
        BackgroundCapabilityDraft(
          inboxPublicKey: await inboxPublicKeyFor(masterKey),
        ),
      );
      final FileBackgroundVault serviceVault = FileBackgroundVault(
        supportDirectory: () async => support,
        credentials: credentials,
      );
      final BackgroundCapability capability = (await serviceVault.load())!;
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryRuntimeSystemNotificationService notices =
          MemoryRuntimeSystemNotificationService();
      final StreamController<SignalTransportFrame> doors =
          StreamController<SignalTransportFrame>.broadcast();
      addTearDown(doors.close);
      final LockedReceiver receiver = LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: SealedInboxWriter(
          file: await serviceVault.inboxFile(),
          recipientPublicKey: capability.inboxPublicKey,
        ),
        notices: notices,
        doorFrames: doors.stream,
        knocks: kit.knockWatch(),
        mailboxPollInterval: Duration.zero,
      );
      await receiver.start();
      addTearDown(receiver.stop);
      transport.sentSignals.clear();

      await receiver.handleDoorFrame(_at(bartek.inbox!, hello));
      expect(receiver.keptCount, 1);
      expect(transport.sentSignals, isEmpty, reason: 'a door never answers');
      final RuntimeSystemNotification ring = notices.activeNotifications
          .singleWhere(
            (RuntimeSystemNotification n) => n.slotKey == kLockedKnockSlot,
          );
      expect(ring.title, 'Ktoś puka do drzwi');
      expect('${ring.title} ${ring.body}', isNot(contains('Bartkowie')));
      expect(ring.routeKey, buildFlatKnocksRouteKey());
      expect(ring.contentRedacted, isTrue);
      expect(isNeighboursNotification(ring), isTrue, reason: 'knock sound');
      expect(
        runtimeRouteIntentFromRouteKey(
          id: 'r',
          routeKey: ring.routeKey,
        )!.target,
        RuntimeRouteTarget.flatKnocks,
      );
      expect(kLockedReceiverSlots, contains(kLockedKnockSlot));

      // A knock with a token that is not on the sticker is kept for the
      // app, but rings nothing.
      await bartek.service.scanDoor(
        FlatDoorCode(
          key: ania.service.profile!.key,
          door: 'guess',
          inbox: ania.inbox!,
          name: 'Nowakowie',
        ),
      );
      final int shown = notices.activeNotifications.length;
      await receiver.handleDoorFrame(
        _at(bartek.inbox!, _ofType(bartek, FlatTypes.hello)),
      );
      expect(receiver.keptCount, 2);
      expect(notices.activeNotifications, hasLength(shown));
    });
  });
}
