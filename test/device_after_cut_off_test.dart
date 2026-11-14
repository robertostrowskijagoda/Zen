// After a device of the account was cut off ("Odłącz"), whoever kept the
// account key on it can certify a new device of the account. The account's
// own devices do not take such a device silently: they ask the person,
// show it as unconfirmed, sync nothing to it and take nothing it wrote
// until it is confirmed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle([int rounds = 60]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<_Linked> _transport(String address) async {
  final _Linked t = _Linked(_a(address));
  _Linked.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(
  _Linked t, {
  required MemoryLedgerDisk disk,
  List<String> friends = const <String>[],
  String name = 'Urządzenie',
  HlcClock? clock,
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk,
    clock: clock,
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    deviceName: name,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

/// Ledger frames [from] sent to [to] of [type].
int _sent(_Linked from, String to, String type) => from.sentSignals
    .where(
      (({String remoteAddress, Map<String, dynamic> payload}) s) =>
          _a(s.remoteAddress) == to && s.payload['type'] == type,
    )
    .length;

AccountDevice? _deviceOf(LedgerNode node, String device) {
  for (final AccountDevice d in node.ownDevices) {
    if (d.device == device) {
      return d;
    }
  }
  return null;
}

void main() {
  setUp(_Linked.nodes.clear);

  test('a cut-off device that comes back as a new device of the account '
      'gets nothing from the owner\'s devices until the person confirms '
      'it', () async {
    final String a1 = _a('200::a1');
    final String a2 = _a('200::a2');
    final String a3 = _a('200::a3');
    final String b = _a('200::b');
    final _Linked t1 = await _transport(a1);
    final _Linked t2 = await _transport(a2);
    final _Linked t3 = await _transport(a3);
    final _Linked tb = await _transport(b);

    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    final LedgerNode first = _node(t1, disk: d1, friends: <String>[b]);
    final LedgerNode bob = _node(
      tb,
      disk: MemoryLedgerDisk(),
      friends: <String>[a1, a3],
    );
    await first.start();
    await bob.start();
    await _settle();

    final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
    await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
    final LedgerNode second = _node(
      t2,
      disk: d2,
      friends: <String>[b],
      name: 'Skradziony telefon',
    );
    await second.start();
    await second.rememberDeviceAddresses(<String>[a1]);
    await _settle(120);
    expect(first.siblingAddresses, <String>[a2]);

    await first.unlinkDevice(second.identity.deviceKey.id);
    await _settle(80);
    expect(second.isRevoked, isTrue);

    // Whoever kept the account key on it certifies a new device.
    final LedgerKeyPair kept = second.identity.accountKey!;
    final MemoryLedgerDisk d3 = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(d3, kept.seed);
    final LedgerNode third = _node(
      t3,
      disk: d3,
      friends: <String>[b],
      name: 'Telefon',
    );
    await third.start();
    await third.rememberDeviceAddresses(<String>[a1]);
    await _settle(160);
    final String thirdDevice = third.identity.deviceKey.id;

    // Not one of the owner's devices: listed, but unconfirmed.
    expect(first.siblingAddresses, isNot(contains(a3)));
    expect(first.isFriendAddress(a3), isFalse);
    final AccountDevice listed = _deviceOf(first, thirdDevice)!;
    expect(listed.confirmed, isFalse);
    expect(listed.address, a3);
    expect(
      first.unconfirmedDevices.map((AccountDevice d) => d.device),
      <String>[thirdDevice],
    );

    // Nothing the owner's devices share goes there.
    final LogEntry mine = (await first.publishForOwnDevices(
      'chat',
      <String, dynamic>{'text': 'tylko dla moich urządzeń'},
    ))!;
    await _settle(80);
    expect(third.store.entryById(mine.space, mine.id), isNull);
    expect(_sent(t1, a3, kLedgerSiblingType), 0);
    expect(_sent(t1, a3, kLedgerKeysType), 0);

    // What it writes for the account's devices is not taken (it reaches
    // the owner through a friend, who keeps a copy of the private space).
    final LogEntry its = (await third.publishForOwnDevices(
      'contacts',
      <String, dynamic>{'friends': <Object>[]},
      spaceKind: 'private',
    ))!;
    bob.greet(a1);
    first.greet(b);
    await _settle(160);
    final LogEntry? arrived = first.store.entryById(its.space, its.id);
    expect(arrived, isNotNull, reason: 'the friend passed it on');
    expect(first.bodyOf(arrived!), isNull);

    // The person says it is theirs: from now on it is an own device.
    await first.confirmDevice(thirdDevice);
    await _settle(120);
    expect(_deviceOf(first, thirdDevice)!.confirmed, isTrue);
    expect(first.siblingAddresses, contains(a3));
    expect(first.bodyOf(arrived), isNotNull);
    expect(first.unconfirmedDevices, isEmpty);

    // And it stays so after a restart.
    await first.stop();
    final LedgerNode again = _node(_Linked(a1), disk: d1);
    await again.start();
    expect(_deviceOf(again, thirdDevice)!.confirmed, isTrue);
    expect(accountSpace('own', first.account), isNotEmpty);
  });

  test('a device that appeared shortly before a cut-off must be confirmed '
      'again on every device; one linked from here after it is taken, and '
      'the account\'s other devices take it on this one\'s word', () async {
    // The devices' clock: the laptop joined a month ago.
    int now = DateTime.now().millisecondsSinceEpoch - 30 * 86400000;
    final HlcClock clock = HlcClock(wallClock: () => now);
    final String a1 = _a('200::c1');
    final String a2 = _a('200::c2');
    final String a3 = _a('200::c3');
    final String a4 = _a('200::c4');
    final _Linked t1 = await _transport(a1);
    final _Linked t2 = await _transport(a2);
    final _Linked t3 = await _transport(a3);
    final _Linked t4 = await _transport(a4);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final LedgerNode first = _node(t1, disk: d1, clock: clock);
    await first.start();
    final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
    final LedgerNode laptop = _node(t2, disk: d2, name: 'Laptop', clock: clock);
    await laptop.start();
    await laptop.rememberDeviceAddresses(<String>[a1]);
    await _settle(120);
    expect(first.siblingAddresses, <String>[a2]);

    // Two days ago a device was made with a key taken from a lost tablet,
    // before anybody noticed.
    now += 28 * 86400000;
    final MemoryLedgerDisk d3 = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(d3, id1.accountKey!.seed);
    final LedgerNode early = _node(t3, disk: d3, name: 'Telefon', clock: clock);
    await early.start();
    await early.rememberDeviceAddresses(<String>[a1, a2]);
    await _settle(160);
    // Nobody co-signed it: it waits a day before it counts anywhere.
    final String earlyId = early.identity.deviceKey.id;
    for (final LedgerNode n in <LedgerNode>[first, laptop]) {
      expect(n.pendingOwnDevices.map((AccountDevice d) => d.device), <String>[
        earlyId,
      ]);
      expect(n.siblingAddresses, isNot(contains(a3)));
    }
    now += 25 * 3600000;
    await first.rememberDeviceAddresses(<String>[a3]);
    await laptop.rememberDeviceAddresses(<String>[a3]);
    await _settle(160);
    expect(first.siblingAddresses, containsAll(<String>[a2, a3]));
    expect(laptop.siblingAddresses, containsAll(<String>[a1, a3]));

    // Now the tablet is cut off.
    now += 86400000;
    final LedgerKeyPair tablet = await LedgerKeyPair.generate();
    await first.store.directory.addCertificate(
      await DeviceCertificate.issue(
        account: id1.accountKey!,
        device: tablet,
        name: 'Tablet',
        issued: 1,
      ),
    );
    await first.unlinkDevice(tablet.id);
    await _settle(160);
    final String earlyDevice = early.identity.deviceKey.id;
    for (final LedgerNode n in <LedgerNode>[first, laptop]) {
      expect(n.unconfirmedDevices.map((AccountDevice d) => d.device), <String>[
        earlyDevice,
      ]);
    }
    expect(first.siblingAddresses, <String>[a2]);
    expect(laptop.siblingAddresses, <String>[a1]);

    // A new device linked from the first one after the cut-off.
    await first.expectOwnDevice(a4);
    final MemoryLedgerDisk d4 = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(d4, id1.accountKey!.seed);
    final LedgerNode fresh = _node(
      t4,
      disk: d4,
      name: 'Nowy telefon',
      clock: clock,
    );
    await fresh.start();
    await fresh.expectOwnDevice(a1);
    await fresh.rememberDeviceAddresses(<String>[a1, a2]);
    await _settle(240);
    final String freshDevice = fresh.identity.deviceKey.id;
    expect(first.siblingAddresses, unorderedEquals(<String>[a2, a4]));
    // The laptop takes it on the first device's word, and it the laptop.
    expect(_deviceOf(laptop, freshDevice)?.confirmed, isTrue);
    expect(laptop.siblingAddresses, unorderedEquals(<String>[a1, a4]));
    expect(fresh.siblingAddresses, unorderedEquals(<String>[a1, a2]));
    // The early device stays unconfirmed everywhere, also on the new one.
    for (final LedgerNode n in <LedgerNode>[first, laptop, fresh]) {
      expect(n.siblingAddresses, isNot(contains(a3)));
    }
  });
}
