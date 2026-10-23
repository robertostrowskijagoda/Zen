import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
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

  /// Hellos sent to [to], oldest first.
  List<Map<String, dynamic>> hellosTo(String to) => <Map<String, dynamic>>[
    for (final ({String remoteAddress, Map<String, dynamic> payload}) s
        in sentSignals)
      if (PeerShareCodec.normalizeAddress(s.remoteAddress) == to &&
          s.payload['type'] == kLedgerHelloType)
        s.payload,
  ];
}

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Unforced hellos go out at most once a second.
Future<void> _pastHelloGap() =>
    Future<void>.delayed(const Duration(milliseconds: 1100));

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<_Linked> _transport(String address) async {
  final _Linked t = _Linked(_a(address));
  _Linked.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(
  _Linked t, {
  List<String> friends = const <String>[],
  HlcClock? clock,
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: MemoryLedgerDisk(),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    helloInterval: Duration.zero,
    syncInterval: Duration.zero,
    clock: clock,
  );
  addTearDown(n.stop);
  return n;
}

void main() {
  setUp(_Linked.nodes.clear);

  test('a friend gets the whole certificate once, then only its name, and '
      'the proof is signed once', () async {
    final String a = _a('200::a');
    final String b = _a('200::b');
    final _Linked ta = await _transport(a);
    final _Linked tb = await _transport(b);
    final LedgerNode ania = _node(ta, friends: <String>[b]);
    final LedgerNode bob = _node(tb, friends: <String>[a]);
    await ania.start();
    await bob.start();
    await _settle();
    expect(bob.accountOfAddress(a), ania.account);

    await _pastHelloGap();
    await ania.greetFriends();
    await _settle();
    final List<Map<String, dynamic>> hellos = ta.hellosTo(b);
    expect(hellos.length, greaterThanOrEqualTo(2));
    expect(hellos.first.containsKey('cert'), isTrue);
    final Map<String, dynamic> last = hellos.last;
    expect(last.containsKey('cert'), isFalse, reason: 'about 10 KB less');
    expect((last['cd'] as Map<String, dynamic>)['a'], ania.account);
    // The same proof: signed once, not for every hello.
    expect(
      (last['p'] as Map<String, dynamic>)['s'],
      (hellos.first['p'] as Map<String, dynamic>)['s'],
    );
    // Still recognised from the name alone.
    expect(bob.accountOfAddress(a), ania.account);
  });

  test('a friend who lacks the certificate asks for it and gets it', () async {
    final String a = _a('200::a');
    final String b = _a('200::b');
    final _Linked ta = await _transport(a);
    final _Linked tb = await _transport(b);
    final LedgerNode ania = _node(ta, friends: <String>[b]);
    final LedgerNode bob = _node(tb, friends: <String>[a]);
    await ania.start();
    await bob.start();
    await _settle();
    await bob.stop();

    // Bob's phone was set up again at the same address: Ania's node still
    // thinks it has her certificate.
    final _Linked tb2 = await _transport(b);
    final LedgerNode bob2 = _node(tb2, friends: <String>[a]);
    await _pastHelloGap();
    final int before = ta.hellosTo(b).length;
    await bob2.start();
    await _settle(160);
    expect(
      tb2.hellosTo(a).any((Map<String, dynamic> h) => h['nc'] == 1),
      isTrue,
      reason: 'asked for the whole certificate',
    );
    // Sent again although the old phone at that address had it (and had
    // asked for it itself a moment ago: a new device is not held back).
    expect(
      ta
          .hellosTo(b)
          .skip(before)
          .any((Map<String, dynamic> h) => h.containsKey('cert')),
      isTrue,
    );
    expect(bob2.accountOfAddress(a), ania.account);
  });

  test('a friend naming a new device each time cannot make this device '
      'send its whole certificate more than a few times a minute', () async {
    final String a = _a('200::a');
    final String b = _a('200::b');
    final _Linked ta = await _transport(a);
    final _Linked tb = await _transport(b);
    // One minute that never ends: per-minute limits cannot roll over.
    HlcClock still() => HlcClock(wallClock: () => 1790000000000);
    final LedgerNode ania = _node(ta, friends: <String>[b], clock: still());
    final LedgerNode bob = _node(tb, friends: <String>[a], clock: still());
    await ania.start();
    await bob.start();
    await _settle();
    expect(ania.accountOfAddress(b), bob.account);
    final int before = ta
        .hellosTo(b)
        .where((Map<String, dynamic> h) => h.containsKey('cert'))
        .length;

    // A changed app at Bob's address asks again and again, each time
    // "from" another device.
    for (int i = 0; i < 20; i++) {
      await ta.injectIncoming(
        from: b,
        payload: <String, dynamic>{
          'type': kLedgerHelloType,
          'cd': <String, dynamic>{'a': bob.account, 'd': 'urzadzenie$i'},
          'p': <String, dynamic>{'f': b, 's': 'x'},
          'nc': 1,
        },
      );
    }
    await _settle();
    final int whole =
        ta
            .hellosTo(b)
            .where((Map<String, dynamic> h) => h.containsKey('cert'))
            .length -
        before;
    // Three asked for, and at most one asking for a certificate named
    // that is not known here.
    expect(whole, inInclusiveRange(1, 4));
  });

  test('the periodic round greets only who was heard from lately', () async {
    final String a = _a('200::a');
    final String quiet = _a('200::c');
    final String heard = _a('200::d');
    final _Linked ta = await _transport(a);
    final LedgerNode ania = _node(ta, friends: <String>[quiet, heard]);
    await ania.start();
    await _settle();
    // Both greeted when the node starts.
    expect(ta.hellosTo(quiet), isNotEmpty);
    expect(ta.hellosTo(heard), isNotEmpty);

    await ta.injectIncoming(
      from: heard,
      payload: const <String, dynamic>{'type': 'chat'},
    );
    await _settle();
    await _pastHelloGap();
    ta.sentSignals.clear();
    await ania.greetFriends(onlyHeard: true);
    await _settle();
    expect(ta.hellosTo(heard), hasLength(1));
    expect(ta.hellosTo(quiet), isEmpty, reason: 'locked or offline');

    // When Zen starts or comes back, everyone is greeted.
    await _pastHelloGap();
    ta.sentSignals.clear();
    await ania.greetFriends();
    await _settle();
    expect(ta.hellosTo(quiet), hasLength(1));
  });
}
