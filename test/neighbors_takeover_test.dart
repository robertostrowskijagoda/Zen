import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/household_sync.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// "Przenieś mieszkanie na to urządzenie": another device of the account
/// takes the household over with a new door key; housemates and neighbours
/// follow it, the old door is refused, and the old device steps down when
/// it hears of the newer one (from the account's devices, a housemate or
/// the new phone) — never taking the household back by itself.

String _addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

/// Gives the services' queued work time to finish.
Future<void> _settle() async {
  for (int i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A phone (or another device of an account) on a small mesh, with its
/// door, as in the neighbours' tests.
final class _Phone implements EventHost {
  _Phone(this.net, this.name)
    : address = _addr((0xa0 + net.length).toRadixString(16)) {
    net[address] = this;
    service = restarted();
  }

  final Map<String, _Phone> net;
  final String name;
  final String address;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late NeighborsService service;
  int clock = 1000;
  bool online = true;

  /// What it sent from its own address (to whom), and what it was shown.
  final List<(String, Map<String, dynamic>)> sentTo =
      <(String, Map<String, dynamic>)>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final Set<String> heardFrom = <String>{};

  /// The door's address: it follows the door key, as the bridge's does.
  String? get inbox {
    final String? key = service.doorKey;
    return key != null ? _addr('d0:${key.substring(0, 4)}') : null;
  }

  NeighborsService restarted() => NeighborsService(
    host: this,
    disk: disk,
    now: () => clock,
    doorInbox: () => inbox,
    doorSend: doorSend,
    deviceName: () => 'Telefon testowy',
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
    if (door && !kFlatDoorTypes.contains(payload['type'])) {
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
    if (door && payload['type'] == FlatTypes.hello && knocker is String) {
      await other.service.acceptKnock(knocker);
    }
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sentTo.add((to, payload));
    if (online) {
      await _deliver(address, to, payload);
    }
  }

  Future<bool> doorSend(String to, Map<String, dynamic> payload) async {
    final String? from = inbox;
    if (!online || from == null) {
      return false;
    }
    await _deliver(from, to, payload);
    return true;
  }

  /// Where its last house state went.
  Set<String> houseSentTo() => <String>{
    for (final (String to, Map<String, dynamic> p) in sentTo)
      if (p['type'] == FlatTypes.house) to,
  };

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

Future<_Phone> _phone(Map<String, _Phone> net, String name) async {
  final _Phone p = _Phone(net, name);
  await p.service.load();
  return p;
}

/// [newcomer] joins [housemate]'s household with a household code.
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

/// A frame between housemates signed only with the household's key, which
/// every resident's phone holds ([seedOf]: a phone that has it).
Future<Map<String, dynamic>> _houseFrame(
  _Phone seedOf,
  String type,
  Map<String, dynamic> body,
) async {
  final LedgerKeyPair pair = await LedgerKeyPair.fromSeed(
    unb64(seedOf.service.flatSeed!, length: 32)!,
  );
  final Map<String, dynamic> signed = <String, dynamic>{
    'type': type,
    'f': pair.id,
    'to': pair.id,
    'b': body,
  };
  final Uint8List sig = await pair.signWithKey(canonicalJsonBytes(signed));
  return <String, dynamic>{...signed, 's': b64(sig)};
}

// ---- the account's devices, as in the account state tests ----

final class _Account {
  final List<_Channel> devices = <_Channel>[];
  final List<(String, Map<String, dynamic>)> log =
      <(String, Map<String, dynamic>)>[];
}

final class _Channel implements AccountSyncChannel {
  _Channel(this.account, this.device) {
    account.devices.add(this);
  }

  final _Account account;
  @override
  final String device;
  final StreamController<Map<String, dynamic>> _in =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<void> _devices = StreamController<void>.broadcast();

  /// Off: it neither sends nor gets anything; what it missed comes when it
  /// is back.
  bool online = true;
  final List<Map<String, dynamic>> _missed = <Map<String, dynamic>>[];

  void back() {
    online = true;
    for (final Map<String, dynamic> body in _missed) {
      _in.add(body);
    }
    _missed.clear();
  }

  @override
  bool get hasOtherDevices => account.devices.length > 1;

  @override
  Iterable<Map<String, dynamic>> existing() => <Map<String, dynamic>>[
    for (final (String from, Map<String, dynamic> body) in account.log)
      if (from != device) body,
  ];

  @override
  Stream<Map<String, dynamic>> get incoming => _in.stream;

  @override
  Stream<void> get devicesChanged => _devices.stream;

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    if (!online) {
      return false;
    }
    final Map<String, dynamic> sent =
        jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    account.log.add((device, sent));
    for (final _Channel d in account.devices) {
      if (d != this) {
        scheduleMicrotask(() {
          if (d.online) {
            d._in.add(sent);
          } else {
            d._missed.add(sent);
          }
        });
      }
    }
    return true;
  }
}

/// [phone] as a device of [account]: its household kept in step.
(AccountStateSync, _Channel) _device(_Account account, _Phone phone) {
  final _Channel channel = _Channel(account, phone.address);
  return (
    AccountStateSync(
      channel: channel,
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[
        HouseholdSyncDomain('held/household', phone.service),
      ],
      delay: const Duration(milliseconds: 1),
      scanEvery: const Duration(hours: 1),
    ),
    channel,
  );
}

Future<void> _settleAccount(List<AccountStateSync> syncs) async {
  for (int round = 0; round < 6; round++) {
    await _settle();
    for (final AccountStateSync s in syncs) {
      await s.flush();
    }
  }
}

void main() {
  test('another device of the account takes the household over with a new '
      'door key; housemates and neighbours follow, the old door is refused, '
      'and the old phone steps down', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = await _phone(net, 'Ania');
    final _Phone ola = await _phone(net, 'Ola');
    final _Phone dorota = await _phone(net, 'Dorota');
    final _Phone tablet = await _phone(net, 'Ania (tablet)');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    expect(await _join(ola, ania), isTrue);
    await dorota.service.createFlat('Dorota', place: 'm. 7');
    expect(
      await dorota.service.scanDoor(ania.service.doorCode!),
      FlatScan.sent,
    );
    await _settle();
    final String flat = ania.service.profile!.key;
    final String dorotaFlat = dorota.service.profile!.key;
    final String me = ania.service.residentKey!;
    final String oldDoor = ania.inbox!;
    final String oldKey = ania.service.doorKey!;
    expect(dorota.service.neighbor(flat), isNotNull);

    // The account's other device keeps a copy, without the door key, and
    // never runs it by itself.
    final Map<String, Object?> copy = ania.service.accountCopy()!;
    expect(jsonEncode(copy), isNot(contains(oldKey)));
    await tablet.service.takeAccountCopy(copy);
    expect(tablet.service.hasFlat, isFalse);
    expect(tablet.service.doorKey, isNull);
    expect(tablet.service.canTakeOver, isTrue);
    expect(tablet.service.heldFlat!.name, 'Nowakowie');
    expect(tablet.service.heldRunBy, ania.address);

    // Ania's phone is lost: the tablet takes the household over.
    ania.online = false;
    expect(await tablet.service.takeOver(), FlatTakeover.done);
    await _settle();
    expect(tablet.service.hasFlat, isTrue);
    expect(tablet.service.canTakeOver, isFalse);
    expect(tablet.service.profile!.key, flat);
    expect(tablet.service.residentKey, me);
    // A new door key, so a new door address; the old one is retired.
    expect(tablet.service.doorKey, isNot(oldKey));
    expect(tablet.inbox, isNot(oldDoor));
    expect(tablet.service.profile!.members[me], tablet.inbox);
    expect(tablet.service.profile!.retired, contains(oldDoor));
    expect(tablet.service.doorCode!.inbox, tablet.inbox);
    // Ola took the signed move and confirmed it.
    expect(tablet.service.waitingForHousemate, isFalse);
    expect(ola.service.profile!.members[me], tablet.inbox);
    expect(ola.service.profile!.retired, contains(oldDoor));
    // The neighbour sends to the new door, never to the old one.
    final NeighborFlat atDorota = dorota.service.neighbor(flat)!;
    expect(atDorota.doors, contains(tablet.inbox));
    expect(atDorota.doors, isNot(contains(oldDoor)));
    expect(atDorota.retired, contains(oldDoor));
    // The neighbours came with the copy.
    expect(tablet.service.neighbor(dorotaFlat), isNotNull);
    await dorota.service.sendMessage(flat, 'Dzień dobry');
    expect(
      tablet.service.messagesWith(dorotaFlat).map((FlatMessage m) => m.text),
      contains('Dzień dobry'),
    );

    // The old phone comes back before it heard: what it sends from the old
    // door is refused, its house state is not taken, and Ola tells it
    // where the household went — it steps down.
    await ania.service.setMyName('Stara Ania');
    ania.online = true;
    expect(
      await ania.service.sendMessage(dorotaFlat, 'Ze starych drzwi'),
      isTrue,
    );
    await _settle();
    expect(
      dorota.service.messagesWith(flat).map((FlatMessage m) => m.text),
      isNot(contains('Ze starych drzwi')),
    );
    expect(ola.service.residentName(me), isNot('Stara Ania'));
    expect(ania.service.hasFlat, isFalse);
    expect(ania.service.doorKey, isNull);
    expect(ania.inbox, isNull);
    expect(ania.service.heldRunBy, tablet.address);
    expect(
      ania.shown.map((RuntimeSystemNotification n) => n.title),
      contains('„Nowakowie” działa na innym urządzeniu'),
    );
    // Ola still has the tablet as Ania's phone.
    expect(ola.service.profile!.members[me], tablet.inbox);
    ola.sentTo.clear();
    await ola.service.setMyName('Ola');
    expect(ola.houseSentTo(), <String>{tablet.address});

    // An older copy never brings the household back to the old phone.
    await ania.service.takeAccountCopy(copy);
    expect(ania.service.hasFlat, isFalse);
    expect(ania.service.heldRunBy, tablet.address);

    // A door retired stays retired for the neighbour, also after a restart.
    dorota.service = dorota.restarted();
    await dorota.service.load();
    expect(dorota.service.neighbor(flat)!.retired, contains(oldDoor));
  });

  test('the new phone tells the old one directly, which steps down at '
      'once', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = await _phone(net, 'Ania');
    final _Phone tablet = await _phone(net, 'Ania (tablet)');
    // A household of one: nobody else to confirm it.
    await ania.service.createFlat('Ania', place: 'm. 3');
    await tablet.service.takeAccountCopy(ania.service.accountCopy()!);
    expect(await tablet.service.takeOver(), FlatTakeover.done);
    await _settle();
    expect(tablet.service.hasFlat, isTrue);
    expect(tablet.service.waitingForHousemate, isFalse);
    expect(ania.service.hasFlat, isFalse);
    expect(ania.service.doorKey, isNull);
    expect(ania.service.canTakeOver, isTrue);
  });

  test('housemates move a resident to another phone only on a signed, later '
      'move', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = await _phone(net, 'Ania');
    final _Phone ola = await _phone(net, 'Ola');
    final _Phone eve = await _phone(net, 'Eve');
    final _Phone tablet = await _phone(net, 'Ania (tablet)');
    final _Phone laptop = await _phone(net, 'Ania (laptop)');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    expect(await _join(ola, ania), isTrue);
    final String me = ania.service.residentKey!;

    await tablet.service.takeAccountCopy(ania.service.accountCopy()!);
    ania.online = false;
    expect(await tablet.service.takeOver(), FlatTakeover.done);
    await _settle();
    expect(ola.service.profile!.members[me], tablet.inbox);
    final Map<String, dynamic> tabletMove = tablet.sentTo
        .lastWhere(
          ((String, Map<String, dynamic>) s) =>
              s.$1 == ola.address && s.$2['type'] == FlatTypes.join,
        )
        .$2;

    // Signed only with the household's key (every resident's phone has
    // it), or with a signature that is not the resident's: nothing moves.
    for (final Map<String, dynamic> body in <Map<String, dynamic>>[
      <String, dynamic>{'a': eve.address, 'rk': me, 'n': 'Ania'},
      <String, dynamic>{
        'a': eve.address,
        'rk': me,
        'n': 'Ania',
        'at': 99999,
        'rs': base64Url.encode(List<int>.filled(64, 1)),
      },
    ]) {
      await ola.service.handle(
        SignalTransportFrame(
          from: eve.address,
          payload: await _houseFrame(ola, FlatTypes.join, body),
          receivedAtMillis: 0,
        ),
      );
    }
    await ola.service.handle(
      SignalTransportFrame(
        from: eve.address,
        payload: await _houseFrame(ola, FlatTypes.phone, <String, dynamic>{
          'a': me,
          'ph': eve.address,
          'at': 99999,
          'rs': base64Url.encode(List<int>.filled(64, 2)),
        }),
        receivedAtMillis: 0,
      ),
    );
    ola.sentTo.clear();
    await ola.service.setMyName('Ola K.');
    expect(ola.houseSentTo(), <String>{tablet.address});

    // A later move (the laptop takes it over from the tablet's copy).
    await laptop.service.takeAccountCopy(tablet.service.accountCopy()!);
    tablet.online = false;
    expect(await laptop.service.takeOver(), FlatTakeover.done);
    await _settle();
    expect(ola.service.profile!.members[me], laptop.inbox);

    // The tablet's older move sent again changes nothing.
    await ola.service.handle(
      SignalTransportFrame(
        from: tablet.address,
        payload: tabletMove,
        receivedAtMillis: 0,
      ),
    );
    ola.sentTo.clear();
    await ola.service.setMyName('Ola');
    expect(ola.houseSentTo(), <String>{laptop.address});

    // The tablet did not hear: its house state is not taken, Ola tells it,
    // and it steps down.
    tablet.online = true;
    await tablet.service.setMyName('Ania z tabletu');
    await _settle();
    expect(ola.service.residentName(me), isNot('Ania z tabletu'));
    expect(tablet.service.hasFlat, isFalse);
    expect(tablet.service.heldRunBy, laptop.address);
    expect(laptop.service.hasFlat, isTrue);
  });

  test('the account\'s devices keep the copy in step; the old device steps '
      'down when it learns of the newer one and never takes it back by '
      'itself', () async {
    final Map<String, _Phone> net = <String, _Phone>{};
    final _Phone ania = await _phone(net, 'Ania');
    final _Phone ola = await _phone(net, 'Ola');
    final _Phone tablet = await _phone(net, 'Ania (tablet)');
    final _Phone laptop = await _phone(net, 'Ania (laptop)');
    await ania.service.createFlat('Nowakowie', place: 'm. 12');
    expect(await _join(ola, ania), isTrue);
    final _Account account = _Account();
    final (AccountStateSync, _Channel) a = _device(account, ania);
    final (AccountStateSync, _Channel) b = _device(account, tablet);
    final (AccountStateSync, _Channel) c = _device(account, laptop);
    final List<AccountStateSync> syncs = <AccountStateSync>[a.$1, b.$1, c.$1];
    for (final AccountStateSync s in syncs) {
      await s.start();
    }
    await _settleAccount(syncs);
    expect(tablet.service.canTakeOver, isTrue);
    expect(laptop.service.canTakeOver, isTrue);
    expect(tablet.service.hasFlat, isFalse);
    expect(laptop.service.heldRunBy, ania.address);

    // Ania's phone is away (no mesh, no account); the tablet takes over.
    ania.online = false;
    a.$2.online = false;
    expect(await tablet.service.takeOver(), FlatTakeover.done);
    await _settleAccount(syncs);
    expect(laptop.service.heldRunBy, tablet.address);
    expect(laptop.service.hasFlat, isFalse);
    expect(ania.service.hasFlat, isTrue);

    // Back on the account (Ola is not around): it steps down from what the
    // account's devices say alone.
    ola.online = false;
    a.$2.back();
    ania.online = true;
    await _settleAccount(syncs);
    expect(ania.service.hasFlat, isFalse);
    expect(ania.service.doorKey, isNull);
    expect(ania.service.heldRunBy, tablet.address);
    expect(tablet.service.hasFlat, isTrue);

    // Everything sent again: still only the tablet runs it.
    for (final _Channel ch in account.devices) {
      ch._devices.add(null);
    }
    await _settleAccount(syncs);
    expect(tablet.service.hasFlat, isTrue);
    expect(ania.service.hasFlat, isFalse);
    expect(laptop.service.hasFlat, isFalse);
    expect(ania.service.accountCopy()!['run'], <String, Object?>{
      'a': tablet.address,
      'at': (tablet.service.accountCopy()!['run']! as Map)['at'],
    });

    // Leaving the household on the device that runs it: the copies go too.
    await tablet.service.leaveFlat();
    await _settleAccount(syncs);
    expect(laptop.service.canTakeOver, isFalse);
    expect(ania.service.canTakeOver, isFalse);

    for (final AccountStateSync s in syncs) {
      await s.stop();
    }
  });

  test('retired doors survive the profile round trip and a neighbour\'s '
      'storage', () async {
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final FlatProfile p = await FlatProfile(
      key: key.id,
      name: 'Nowakowie',
      rev: 3,
      members: <String, String>{
        base64Url.encode(List<int>.filled(32, 4)): _addr('d2'),
      },
      retired: <String>[_addr('d1')],
    ).signedWith(key);
    final FlatProfile back = FlatProfile.fromJson(
      jsonDecode(jsonEncode(p.toJson())),
    )!;
    expect(await back.verify(), isTrue);
    expect(back.retired, <String>[_addr('d1')]);
    expect(back.doors.toList(), <String>[_addr('d2')]);
    expect(p.retiring(_addr('d3')), <String>[_addr('d1'), _addr('d3')]);

    final NeighborFlat f = NeighborFlat(profile: back, addedAt: 1);
    expect(f.retired, contains(_addr('d1')));
    // A later profile that no longer lists it keeps it retired.
    f.profile = await back
        .copyWith(rev: 4, retired: const <String>[])
        .signedWith(key);
    expect(f.retired, contains(_addr('d1')));
    final NeighborFlat stored = NeighborFlat.fromJson(
      jsonDecode(jsonEncode(f.toJson())),
    )!;
    expect(stored.retired, contains(_addr('d1')));
  });
}
