import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/bridge_host.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/port_mapper.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart'
    show yggAddressForKey;
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

const int _now = 1790000000000;
const int _bits = 8;

/// The desktop's node key, and its mesh address that follows from it.
final List<int> _deskKeyBytes = List<int>.generate(32, (int i) => i * 7 + 1);
final String _deskKey = <String>[
  for (final int b in _deskKeyBytes) b.toRadixString(16).padLeft(2, '0'),
].join();
final String _deskAddress = yggAddressForKey(_deskKeyBytes);

/// What the desktop asks friends to check (and announces) at [hostPort].
String _at(String hostPort) => 'tls://$hostPort?key=$_deskKey';

/// A friend's probe that finds the desktop's own node behind [open].
Future<String?> Function(String uri) _desk(bool Function(String uri) open) =>
    (String uri) async => open(uri) ? _deskKey : null;

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
Future<_Pair> _pair(Future<String?> Function(String uri) friendProbe) async {
  final String ada = _deskAddress;
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
  nodeKey: () => _deskKey,
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
        return uri == _at('198.51.100.50:32913') ? _deskKey : null;
      });
      final _Router router = _Router(InternetAddress('198.51.100.50'));
      final BridgeHost host = _host(p.desktop, router);
      final BridgeHostStatus s = await host.runOnce();
      expect(s.state, BridgeHostState.active);
      expect(s.uri, _at('198.51.100.50:32913'));
      expect(s.method, 'upnp');
      expect(checked, <String>[_at('198.51.100.50:32913')]);
      expect(p.desktop.ownBridge?.uri, _at('198.51.100.50:32913'));
      await _settle();
      expect(p.chosenByFriend.last, contains(_at('198.51.100.50:32913')));
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
      final _Pair p = await _pair(_desk((String _) => open));
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
      final _Pair p = await _pair(_desk((String _) => true));
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
      expect(s.uri, _at('203.0.113.7:32913'), reason: 'IPv4 first');
      expect(s.method, 'direct');
      await host.stop();
    },
  );

  test('no router, a shared address, no friend online', () async {
    final _Pair p = await _pair(_desk((String _) => true));
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
        _desk((String uri) => uri == _at('198.51.100.60:32913')),
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
      final _Pair q = await _pair(_desk((String _) => false));
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
      return _deskKey;
    });
    final List<ReachResult> results = <ReachResult>[
      for (int i = 0; i < 6; i++)
        await p.desktop.checkReachable(
          _at('198.51.100.${i + 1}:32913'),
          timeout: const Duration(milliseconds: 200),
        ),
    ];
    expect(probes, kReachChecksPerMinute);
    expect(
      results.where((ReachResult r) => r == ReachResult.reachable),
      hasLength(kReachChecksPerMinute),
    );
  });

  test('a router that names a server of its own gets nothing announced, '
      'and friends refuse the node there', () async {
    // A device on the same Wi-Fi plays the router and runs a mesh node of
    // its own at the address it names: the node answers, with its key.
    final String strangerKey = 'ee' * 32;
    final List<String> probed = <String>[];
    final _Pair p = await _pair((String uri) async {
      probed.add(uri);
      return uri.contains('198.51.100.66') ? strangerKey : null;
    });
    final BridgeHost host = _host(
      p.desktop,
      _Router(InternetAddress('198.51.100.66')),
    );
    final BridgeHostStatus s = await host.runOnce();
    expect(probed, <String>[_at('198.51.100.66:32913')]);
    expect(s.state, BridgeHostState.unreachable);
    expect(p.desktop.ownBridge, isNull);
    await _settle();
    expect(
      p.chosenByFriend.expand((List<String> c) => c),
      isNot(contains(contains('198.51.100.66'))),
    );
    await host.stop();
  });

  test('a friend confirms only the asking device\'s own node', () async {
    String? answer;
    final List<String> probed = <String>[];
    final _Pair p = await _pair((String uri) async {
      probed.add(uri);
      return answer;
    });
    Future<ReachResult> check(String uri) => p.desktop.checkReachable(
      uri,
      timeout: const Duration(milliseconds: 300),
    );
    // Another node's key at the right address.
    answer = 'ee' * 32;
    expect(await check(_at('198.51.100.1:443')), ReachResult.unreachable);
    // The desktop's key, but the address pins another one.
    answer = _deskKey;
    expect(
      await check('tls://198.51.100.2:443?key=${'ee' * 32}'),
      ReachResult.unreachable,
    );
    // Without a pin (a computer on the older version) its own node counts.
    expect(await check('tls://198.51.100.3:443'), ReachResult.reachable);
    expect(probed, hasLength(3));
  });

  test('a friend dials only a public tls address for someone else', () async {
    final List<String> probed = <String>[];
    final _Pair p = await _pair((String uri) async {
      probed.add(uri);
      return _deskKey;
    });
    for (final String uri in <String>[
      _at('192.168.1.1:80'),
      _at('127.0.0.1:8080'),
      _at('100.64.0.1:443'),
      'tls://router.example:443?key=$_deskKey',
      'tcp://198.51.100.1:443?key=$_deskKey',
      'tls://198.51.100.1:443/admin?key=$_deskKey',
      'tls://198.51.100.1:443?key=$_deskKey&password=x',
      'tls://198.51.100.1:443?key=12',
    ]) {
      expect(
        await p.desktop.checkReachable(
          uri,
          timeout: const Duration(milliseconds: 300),
        ),
        // A friend answers four checks a minute; the rest go unanswered.
        isNot(ReachResult.reachable),
        reason: uri,
      );
    }
    expect(probed, isEmpty);
  });

  test('no node key yet: nothing is checked or announced', () async {
    final List<String> probed = <String>[];
    final _Pair p = await _pair((String uri) async {
      probed.add(uri);
      return _deskKey;
    });
    final BridgeHost host = BridgeHost(
      node: p.desktop,
      nodeKey: () => '',
      mapper: _Router(InternetAddress('198.51.100.50')),
      localAddresses: () async => <InternetAddress>[],
      reachTimeout: const Duration(milliseconds: 400),
      now: () => _now,
      announcePowBits: _bits,
    );
    expect((await host.runOnce()).state, BridgeHostState.waiting);
    expect(probed, isEmpty);
    expect(p.desktop.ownBridge, isNull);
    await host.stop();
  });

  test('a device on the Wi-Fi that answers the router search is not asked '
      'for anything', () async {
    final HttpServer fake = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => fake.close(force: true));
    final List<String> seen = <String>[];
    fake.listen((HttpRequest req) async {
      seen.add('${req.method} ${req.uri}');
      await utf8.decodeStream(req);
      req.response.write(
        '<root><device><serviceList><service>'
        '<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1'
        '</serviceType><controlURL>/ctl</controlURL></service>'
        '</serviceList></device></root>',
      );
      await req.response.close();
    });
    final List<String> probed = <String>[];
    final _Pair p = await _pair((String uri) async {
      probed.add(uri);
      return 'ee' * 32;
    });
    final BridgeHost host = _host(
      p.desktop,
      RouterPortMapper(
        upnp: UpnpPortMapper(
          discover: (_) async => <Uri>[
            Uri.parse('http://127.0.0.1:${fake.port}/desc.xml'),
          ],
          gateways: () async => <InternetAddress>[
            InternetAddress('192.168.1.1'),
          ],
        ),
        natPmp: NatPmpPortMapper(gateways: () async => <InternetAddress>[]),
      ),
    );
    final BridgeHostStatus s = await host.runOnce();
    expect(s.state, BridgeHostState.noRouter);
    expect(seen, isEmpty);
    expect(probed, isEmpty, reason: 'no friend is sent anywhere');
    expect(p.desktop.ownBridge, isNull);
    await host.stop();
  });
}
