import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/bridge_host.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/port_mapper.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

const int _now = 1790000000000;
const int _bits = 8;

final class _Router implements PortMapper {
  _Router(this.external);

  final InternetAddress? external;
  int maps = 0;
  int removed = 0;

  @override
  bool get routerRefused => false;

  @override
  InternetAddress? get knownExternalAddress => null;

  @override
  Future<PortMapping?> map(
    int port, {
    Duration lease = const Duration(hours: 2),
  }) async {
    maps++;
    return PortMapping(
      method: 'upnp',
      internalPort: port,
      externalPort: port,
      lease: lease,
      externalAddress: external,
      remove: () async => removed++,
    );
  }
}

final class _NoRouter implements PortMapper {
  _NoRouter({this.routerRefused = false, this.knownExternalAddress});

  @override
  final bool routerRefused;

  @override
  final InternetAddress? knownExternalAddress;

  @override
  Future<PortMapping?> map(
    int port, {
    Duration lease = const Duration(hours: 2),
  }) async => null;
}

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _Pair {
  _Pair(this.desktop, this.friend, this.chosenByFriend);

  final LedgerNode desktop;
  final LedgerNode friend;
  final List<List<String>> chosenByFriend;
}

/// A desktop and a friend's phone; [friendProbe] is how the phone sees the
/// desktop from outside.
Future<_Pair> _pair(Future<int?> Function(String uri) friendProbe) async {
  final String ada = PeerShareCodec.normalizeAddress('200::a');
  final String bob = PeerShareCodec.normalizeAddress('200::b');
  final _Linked ta = _Linked(ada);
  final _Linked tb = _Linked(bob);
  _Linked.nodes
    ..clear()
    ..[ada] = ta
    ..[bob] = tb;
  await ta.start();
  await tb.start();
  final List<List<String>> chosen = <List<String>>[];
  final LedgerNode a = LedgerNode(
    transport: ta,
    disk: MemoryLedgerDisk(),
    friendAddresses: () => <String>[bob],
    bridges: BridgeBook(probe: (String _) async => 20, powBits: _bits),
    clock: HlcClock(wallClock: () => _now),
  );
  final LedgerNode b = LedgerNode(
    transport: tb,
    disk: MemoryLedgerDisk(),
    friendAddresses: () => <String>[ada],
    bridges: BridgeBook(
      probe: (String _) async => 20,
      powBits: _bits,
      now: () => _now,
    ),
    onBridgesChosen: chosen.add,
    reachProbe: friendProbe,
    clock: HlcClock(wallClock: () => _now),
  );
  addTearDown(a.stop);
  addTearDown(b.stop);
  await a.start();
  await b.start();
  await _settle();
  return _Pair(a, b, chosen);
}

BridgeHost _host(
  LedgerNode node,
  PortMapper mapper, {
  List<InternetAddress>? own,
}) => BridgeHost(
  node: node,
  mapper: mapper,
  localAddresses: () async => own ?? <InternetAddress>[],
  reachTimeout: const Duration(milliseconds: 400),
  now: () => _now,
  announcePowBits: _bits,
);

void main() {
  test(
    'a desktop behind a router becomes a bridge once a friend got in',
    () async {
      final List<String> checked = <String>[];
      final _Pair p = await _pair((String uri) async {
        checked.add(uri);
        return uri == 'tls://198.51.100.50:32913' ? 15 : null;
      });
      final _Router router = _Router(InternetAddress('198.51.100.50'));
      final BridgeHost host = _host(p.desktop, router);
      final BridgeHostStatus s = await host.runOnce();
      expect(s.state, BridgeHostState.active);
      expect(s.uri, 'tls://198.51.100.50:32913');
      expect(s.method, 'upnp');
      expect(checked, <String>['tls://198.51.100.50:32913']);
      expect(p.desktop.ownBridge?.uri, 'tls://198.51.100.50:32913');
      await _settle();
      expect(p.chosenByFriend.last, contains('tls://198.51.100.50:32913'));
      // The next round renews the port but does not redo the proof of work.
      final int expires = p.desktop.ownBridge!.expires;
      await host.runOnce();
      expect(router.maps, 2);
      expect(p.desktop.ownBridge!.expires, expires);
      await host.stop();
      expect(router.removed, 1, reason: 'the port is closed again');
    },
  );

  test(
    'nobody gets in: nothing is announced, and an old one is withdrawn',
    () async {
      bool open = true;
      final _Pair p = await _pair((String _) async => open ? 15 : null);
      final BridgeHost host = _host(
        p.desktop,
        _Router(InternetAddress('198.51.100.50')),
      );
      expect((await host.runOnce()).state, BridgeHostState.active);
      open = false;
      final BridgeHostStatus s = await host.runOnce();
      expect(s.state, BridgeHostState.unreachable);
      expect(p.desktop.ownBridge, isNull);
      await host.stop();
    },
  );

  test(
    'a public address on the computer itself works without a router',
    () async {
      final _Pair p = await _pair((String _) async => 15);
      final BridgeHost host = _host(
        p.desktop,
        _NoRouter(),
        own: <InternetAddress>[
          InternetAddress('192.168.1.7'),
          InternetAddress('2a01:4f8::7'),
          InternetAddress('203.0.113.7'),
        ],
      );
      final BridgeHostStatus s = await host.runOnce();
      expect(s.state, BridgeHostState.active);
      expect(s.uri, 'tls://203.0.113.7:32913', reason: 'IPv4 first');
      expect(s.method, 'direct');
      await host.stop();
    },
  );

  test('no router, a shared address, no friend online', () async {
    final _Pair p = await _pair((String _) async => 15);
    BridgeHost host = _host(p.desktop, _NoRouter());
    expect((await host.runOnce()).state, BridgeHostState.noRouter);
    await host.stop();
    host = _host(p.desktop, _NoRouter(routerRefused: true));
    expect((await host.runOnce()).state, BridgeHostState.routerRefused);
    await host.stop();
    host = _host(p.desktop, _Router(InternetAddress('100.64.9.9')));
    expect((await host.runOnce()).state, BridgeHostState.sharedAddress);
    await host.stop();
    _Linked.nodes.clear(); // the friend went offline
    host = _host(p.desktop, _Router(InternetAddress('198.51.100.50')));
    expect((await host.runOnce()).state, BridgeHostState.noFriendsOnline);
    await host.stop();
  });

  test(
    'a port forwarded by hand works even if the router refuses UPnP',
    () async {
      final _Pair p = await _pair(
        (String uri) async => uri == 'tls://198.51.100.60:32913' ? 15 : null,
      );
      final BridgeHost host = _host(
        p.desktop,
        _NoRouter(
          routerRefused: true,
          knownExternalAddress: InternetAddress('198.51.100.60'),
        ),
      );
      final BridgeHostStatus s = await host.runOnce();
      expect(s.state, BridgeHostState.active);
      expect(s.method, 'manual');
      await host.stop();
      // Not forwarded: the refusal is what the settings explain.
      final _Pair q = await _pair((String _) async => null);
      final BridgeHost again = _host(
        q.desktop,
        _NoRouter(
          routerRefused: true,
          knownExternalAddress: InternetAddress('198.51.100.60'),
        ),
      );
      expect((await again.runOnce()).state, BridgeHostState.routerRefused);
      await again.stop();
    },
  );

  test('a friend checks for others only a few times a minute', () async {
    int probes = 0;
    final _Pair p = await _pair((String _) async {
      probes++;
      return 15;
    });
    final List<ReachResult> results = <ReachResult>[
      for (int i = 0; i < 6; i++)
        await p.desktop.checkReachable(
          'tls://198.51.100.${i + 1}:32913',
          timeout: const Duration(milliseconds: 200),
        ),
    ];
    expect(probes, kReachChecksPerMinute);
    expect(
      results.where((ReachResult r) => r == ReachResult.reachable),
      hasLength(kReachChecksPerMinute),
    );
  });
}
