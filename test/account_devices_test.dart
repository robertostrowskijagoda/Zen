import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/account/account_link.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
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
  required List<String> friends,
  String name = 'Urządzenie',
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk,
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    deviceName: name,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

void main() {
  setUp(_Linked.nodes.clear);

  test(
    'a second device of the account becomes one person for friends',
    () async {
      final String a1 = _a('200::a1');
      final String a2 = _a('200::a2');
      final String b = _a('200::b');
      final _Linked t1 = await _transport(a1);
      final _Linked t2 = await _transport(a2);
      final _Linked tb = await _transport(b);

      final MemoryLedgerDisk d1 = MemoryLedgerDisk();
      final MemoryLedgerDisk d2 = MemoryLedgerDisk();
      final LedgerNode first = _node(t1, disk: d1, friends: <String>[b]);
      final LedgerNode bob = _node(
        tb,
        disk: MemoryLedgerDisk(),
        friends: <String>[a1],
      );
      await first.start();
      await bob.start();
      await _settle();

      // A sealed post from the first device, before the second exists.
      final LogEntry secret = await first.publish(
        'post',
        await first.seal(Audience.all, <String, dynamic>{'text': 'tajne'}),
      );

      // Link: the new device takes the account key and greets the old one.
      final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
      await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
      final LedgerNode second = _node(
        t2,
        disk: d2,
        friends: <String>[],
        name: 'Telefon (Android)',
      );
      await second.start();
      await second.rememberDeviceAddresses(<String>[a1]);
      await _settle(120);

      expect(second.account, first.account);
      expect(first.siblingAddresses, <String>[a2]);
      expect(second.siblingAddresses, contains(a1));
      expect(
        first.ownDevices.map((AccountDevice d) => d.name),
        containsAll(<String>['Urządzenie', 'Telefon (Android)']),
      );
      // The friend learns the new device (its record in `acts`, or its hello).
      expect(
        bob.addressesOfAccount(first.account),
        containsAll(<String>[a1, a2]),
      );
      expect(bob.accountOfAddress(a2), first.account);
      // Own keys travel between own devices: the old sealed post opens.
      expect(
        second.bodyOf(second.store.entryById(secret.space, secret.id)!),
        <String, dynamic>{'text': 'tajne'},
      );

      // Friends and groups backup: sealed, only own devices read it.
      expect(
        await first.publishContacts(<String, dynamic>{
          'v': 1,
          'friends': <Object>[
            <String, dynamic>{'a': b},
          ],
        }),
        isTrue,
      );
      await _settle(80);
      expect(second.latestContacts()?['friends'], hasLength(1));
      final LogEntry backup = bob.store
          .entries(accountSpace('private', first.account))
          .single;
      expect(isSealed(backup.body), isTrue, reason: 'the friend keeps a copy');
      expect(bob.bodyOf(backup), isNull, reason: '…but cannot read it');

      // The second device is lost: cut it off from the first.
      await first.unlinkDevice(second.identity.deviceKey.id);
      await _settle(80);
      expect(first.siblingAddresses, isEmpty);
      expect(bob.addressesOfAccount(first.account), isNot(contains(a2)));
      expect(second.isRevoked, isTrue, reason: 'the device itself is told');
      // Nothing it writes from now on is taken, not even by itself.
      await expectLater(
        second.publish('post', <String, dynamic>{'text': 'po kradzieży'}),
        throwsStateError,
      );
    },
  );

  test('a cut-off is per space: a busy log cannot open another', () async {
    final LedgerKeyPair account = await LedgerKeyPair.generate();
    final DeviceRevocation r = await DeviceRevocation.issue(
      account: account,
      device: (await LedgerKeyPair.generate()).id,
      cutoffs: <String, int>{
        cutoffKey('a' * 32, 'feed/x'): 2,
        cutoffKey('a' * 32, 'acts/x'): 50,
      },
      issued: 1,
    );
    final DeviceRevocation back = DeviceRevocation.fromJson(r.toJson())!;
    expect(await back.verify(), isTrue);
    final AccountDirectory dir = AccountDirectory();
    await dir.addRevocation(back);
    bool allows(String space, int seq) => dir.allowsEntry(
      account: account.id,
      device: back.device,
      writer: 'a' * 32,
      seq: seq,
      space: space,
    );
    expect(allows('feed/x', 2), isTrue);
    expect(allows('feed/x', 3), isFalse);
    expect(allows('acts/x', 50), isTrue);
    expect(allows('profile/x', 1), isFalse, reason: 'unlisted: nothing');
  });

  test('linking: same digits on both screens, then the key', () async {
    final _Linked old = await _transport('200::1');
    final _Linked fresh = await _transport('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);
    final AccountLinkSender sender = AccountLinkSender(
      transport: old,
      target: fresh.address,
    );
    addTearDown(sender.dispose);
    final String digits = await sender.start();
    expect(await receiver.digits, digits);
    expect(digits, matches(RegExp(r'^\d{3} \d{3}$')));
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final Future<void> sent = sender.send(
      seed: key.seed,
      account: key.id,
      siblings: <String>[old.address],
    );
    final LinkedAccount got = await receiver.account;
    expect(got.seed, key.seed);
    expect(got.account, key.id);
    expect(got.siblings, <String>[old.address]);
    await receiver.confirm();
    await sent;
    // Nothing readable went over the wire.
    final String wire = old.sentSignals.toString();
    expect(wire.contains(b64(key.seed)), isFalse);
  });

  group('routing', () {
    late MemorySignalTransport base;
    late _Dir dir;
    late AccountRoutingTransport routed;
    final List<(String, Map<String, dynamic>)> mirrored =
        <(String, Map<String, dynamic>)>[];

    setUp(() async {
      base = MemorySignalTransport();
      await base.start();
      dir = _Dir();
      mirrored.clear();
      routed = AccountRoutingTransport(
        delegate: base,
        directory: () => dir,
        onMirrored: (String peer, Map<String, dynamic> p) async =>
            mirrored.add((peer, p)),
      );
    });

    Set<String> sentTo(String type) => <String>{
      for (final s in base.sentSignals)
        if (s.payload['type'] == type) s.remoteAddress,
    };

    test(
      'a message reaches every device and a copy goes to my others',
      () async {
        await routed.send(
          remoteAddress: 'ania1',
          payload: <String, dynamic>{
            'type': 'message',
            'msgId': 'm',
            'text': 'hej',
          },
        );
        expect(sentTo('message'), <String>{'ania1', 'ania2'});
        expect(sentTo(kMirrorType), <String>{'me2'});
      },
    );

    test(
      'whatever another device of a friend sends looks like the friend',
      () async {
        final Future<SignalTransportFrame> next = routed.frames.first;
        await base.injectIncoming(
          from: 'ania2',
          payload: <String, dynamic>{'type': 'typing'},
        );
        final SignalTransportFrame frame = await next;
        expect(frame.from, 'ania1');
        // Which device it was stays known (what each device tells of
        // itself: presence, its nearby keys).
        expect(frame.device, 'ania2');
        expect(frame.sender, 'ania2');
        final Future<SignalTransportFrame> own = routed.frames.first;
        await base.injectIncoming(
          from: 'ania1',
          payload: <String, dynamic>{'type': 'typing'},
        );
        expect((await own).device, isNull);
      },
    );

    test('copies from my other device land in the conversation, '
        'from anyone else they are ignored', () async {
      final StreamSubscription<SignalTransportFrame> sub = routed.frames.listen(
        (_) {},
      );
      addTearDown(sub.cancel);
      final Map<String, dynamic> copy = <String, dynamic>{
        'type': kMirrorType,
        'to': 'ania1',
        'p': <String, dynamic>{'type': 'message', 'msgId': 'x', 'text': 'a'},
      };
      await base.injectIncoming(from: 'me2', payload: copy);
      await base.injectIncoming(from: 'ania2', payload: copy);
      await _settle(4);
      expect(mirrored, hasLength(1));
      expect(mirrored.single.$1, 'ania1');
    });

    test('a call belongs to the device that answered', () async {
      final StreamSubscription<SignalTransportFrame> sub = routed.frames.listen(
        (_) {},
      );
      addTearDown(sub.cancel);
      await routed.send(
        remoteAddress: 'ania1',
        payload: <String, dynamic>{'type': 'call_invite', 'callId': 'c1'},
      );
      expect(sentTo('call_invite'), <String>{'ania1', 'ania2'});
      await base.injectIncoming(
        from: 'ania2',
        payload: <String, dynamic>{'type': 'call_accept', 'callId': 'c1'},
      );
      await _settle(4);
      expect(sentTo('call_end'), <String>{'ania1'}, reason: 'stops ringing');
      base.sentSignals.clear();
      await routed.send(
        remoteAddress: 'ania1',
        payload: <String, dynamic>{'type': 'call_offer', 'callId': 'c1'},
      );
      expect(sentTo('call_offer'), <String>{'ania2'});
      await routed.openRelay(callId: 'c1', remoteAddress: 'ania1');
      expect(base.openedRelays.single.remoteAddress, 'ania2');
    });

    test('strangers and own devices pass untouched', () async {
      await routed.send(
        remoteAddress: 'obcy',
        payload: <String, dynamic>{
          'type': 'message',
          'msgId': 'm',
          'text': 'x',
        },
      );
      expect(sentTo('message'), <String>{'obcy'});
      expect(sentTo(kMirrorType), isEmpty);
    });
  });
}

final class _Dir implements AccountDeviceDirectory {
  @override
  String get ownAccount => 'ME';

  @override
  String? accountOf(String address) => switch (address) {
    'ania1' || 'ania2' => 'ANIA',
    'me2' => 'ME',
    _ => null,
  };

  @override
  List<String> addressesOf(String account) => switch (account) {
    'ANIA' => <String>['ania1', 'ania2'],
    'ME' => <String>['me2'],
    _ => const <String>[],
  };

  @override
  String? contactAddressOf(String account) =>
      account == 'ANIA' ? 'ania1' : null;

  @override
  String? unlinkedAccountOf(String address) => null;
}
