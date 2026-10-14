import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

const int _now = 1790000000000;
const int _bits = 8;

Future<Map<String, dynamic>> _announce(
  String uri, {
  int? expires,
  int powBits = _bits,
}) async {
  final LedgerKeyPair key = await LedgerKeyPair.generate();
  return (await BridgeAnnouncement.create(
    uri: uri,
    bridgeKey: key,
    expires: expires ?? _now + const Duration(days: 3).inMilliseconds,
    powBits: powBits,
  )).toJson();
}

BridgeBook _book({
  Future<int?> Function(String uri)? probe,
  int probesPerMinute = 100,
}) => BridgeBook(
  probe: probe ?? (String _) async => 20,
  now: () => _now,
  powBits: _bits,
  probesPerMinute: probesPerMinute,
);

void main() {
  test('a signed announcement with enough work is accepted', () async {
    final BridgeBook book = _book();
    expect(await book.add(await _announce('tls://198.51.100.7:32913')), isTrue);
    expect(book.records, hasLength(1));
  });

  test(
    'forged, lazy, expired and far-future announcements are refused',
    () async {
      final BridgeBook book = _book();
      final Map<String, dynamic> good = await _announce('tls://198.51.100.7:1');
      expect(
        await book.add(
          Map<String, dynamic>.of(good)..['uri'] = 'tls://203.0.113.9:1',
        ),
        isFalse,
        reason: 'uri swapped after signing',
      );
      final BridgeBook strict = BridgeBook(
        probe: (String _) async => 20,
        now: () => _now,
        powBits: 24,
      );
      expect(await strict.add(good), isFalse, reason: 'not enough work');
      expect(
        await book.add(
          await _announce('tls://198.51.100.8:1', expires: _now - 1),
        ),
        isFalse,
      );
      expect(
        await book.add(
          await _announce(
            'tls://198.51.100.9:1',
            expires: _now + const Duration(days: 30).inMilliseconds,
          ),
        ),
        isFalse,
      );
      expect(await book.add(<String, dynamic>{'t': 'bridge'}), isFalse);
      expect(
        await book.add(await _announce('http://198.51.100.10:80')),
        isFalse,
        reason: 'not a mesh scheme',
      );
    },
  );

  test('one network cannot fill the book', () async {
    final BridgeBook book = _book();
    int accepted = 0;
    for (int i = 1; i <= 8; i++) {
      if (await book.add(await _announce('tls://203.0.113.$i:1000'))) {
        accepted++;
      }
    }
    expect(accepted, book.maxPerSubnet);
    expect(await book.add(await _announce('tls://192.0.2.1:1000')), isTrue);
  });

  test('only bridges that answered are passed on', () async {
    final BridgeBook book = _book(
      probe: (String uri) async => uri.contains('198.51.100.1:') ? 20 : null,
    );
    await book.add(await _announce('tls://198.51.100.1:1'));
    await book.add(await _announce('tls://203.0.113.5:1'));
    expect(book.sample(10), isEmpty, reason: 'nothing checked yet');
    await book.probeSome();
    final List<Map<String, dynamic>> passed = book.sample(10);
    expect(passed, hasLength(1));
    expect(passed.single['uri'], 'tls://198.51.100.1:1');
  });

  test('probing is rate limited, so nobody can use us to scan', () async {
    int probes = 0;
    final BridgeBook book = _book(
      probe: (String _) async {
        probes++;
        return 20;
      },
      probesPerMinute: 3,
    );
    for (int i = 1; i <= 6; i++) {
      await book.add(await _announce('tls://198.18.$i.1:1'));
    }
    await book.probeSome();
    expect(probes, 3);
  });

  test('connections are spread over networks', () async {
    final BridgeBook book = _book();
    await book.add(await _announce('tls://198.51.100.1:1'));
    await book.add(await _announce('tls://198.51.100.2:1'));
    await book.add(await _announce('tls://203.0.113.1:1'));
    await book.add(await _announce('tls://192.0.2.50:1'));
    await book.probeSome();
    final List<String> chosen = book.choose(3);
    expect(chosen, contains('tls://192.0.2.50:1'));
    final Set<String> nets = chosen
        .map((String u) => bridgeSubnet(Uri.parse(u).host))
        .toSet();
    expect(nets, hasLength(3));
  });

  test('the book survives a restart', () async {
    final BridgeBook book = _book();
    await book.add(await _announce('tls://198.51.100.1:1'));
    await book.probeSome();
    final BridgeBook again = _book()..restore(book.toJson());
    expect(again.working, hasLength(1));
    expect(again.choose(1), <String>['tls://198.51.100.1:1']);
  });

  test('bridges on home networks or names are refused', () async {
    final BridgeBook book = _book();
    for (final String uri in <String>[
      'tls://192.168.1.10:32913',
      'tls://10.0.0.5:32913',
      'tls://127.0.0.1:32913',
      'tls://100.64.1.1:32913',
      'tls://[fe80::1]:32913',
      'tls://[fd00::1]:32913',
      'tls://router.local:32913',
    ]) {
      expect(await book.add(await _announce(uri)), isFalse, reason: uri);
    }
    expect(
      await book.add(await _announce('tls://[2a01:4f8::7]:32913')),
      isTrue,
    );
  });

  test('the fastest bridges win, spread over providers', () async {
    final Map<String, int> speed = <String, int>{
      'tls://198.51.100.1:1': 200,
      'tls://198.51.7.1:1': 15, // same provider block (198.51) as the next
      'tls://198.51.8.1:1': 10,
      'tls://203.0.113.1:1': 50,
    };
    final BridgeBook book = _book(probe: (String uri) async => speed[uri]);
    for (final String uri in speed.keys) {
      await book.add(await _announce(uri));
    }
    await book.probeSome();
    expect(book.choose(2), <String>[
      'tls://198.51.8.1:1',
      'tls://203.0.113.1:1',
    ]);
    expect(book.choose(3), hasLength(3));
  });

  test(
    'dead bridges are retried, then forgotten; good ones re-checked',
    () async {
      int now = _now;
      bool up = true;
      int probes = 0;
      final BridgeBook book = BridgeBook(
        probe: (String _) async {
          probes++;
          return up ? 30 : null;
        },
        now: () => now,
        powBits: _bits,
        probesPerMinute: 100,
      );
      await book.add(await _announce('tls://198.51.100.1:1'));
      await book.probeSome();
      expect(book.working, hasLength(1));
      await book.probeSome();
      expect(probes, 1, reason: 'fresh enough, not probed again');
      now += const Duration(hours: 7).inMilliseconds;
      up = false;
      await book.probeSome();
      expect(book.working, isEmpty);
      expect(book.records, hasLength(1));
      for (int i = 0; i < 2; i++) {
        now += const Duration(hours: 25).inMilliseconds;
        await book.probeSome();
      }
      expect(book.records, isEmpty, reason: 'three failures in a row');
    },
  );

  test('the probe wants the mesh greeting, not just an open port', () async {
    Future<int?> against(List<int> hello) async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((Socket s) {
        s.add(hello);
      });
      try {
        return await probeMeshPort(
          InternetAddress.loopbackIPv4,
          server.port,
          tls: false,
          timeout: const Duration(seconds: 1),
        );
      } finally {
        await server.close();
      }
    }

    expect(await against(utf8.encode('meta\x00\x40rest')), isNotNull);
    expect(await against(utf8.encode('HTTP/1.1 400')), isNull);
    expect(await against(<int>[]), isNull, reason: 'silent');
    // Never probes a home or loopback address, whatever the announcement.
    expect(await yggBridgeProbe('tls://127.0.0.1:1'), isNull);
    expect(await yggBridgeProbe('tls://192.168.0.1:1'), isNull);
  });

  test('a desktop announces itself and friends start using it', () async {
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
    final List<List<String>> chosenByBob = <List<String>>[];
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: _book(),
      clock: HlcClock(wallClock: () => _now),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: _book(),
      onBridgesChosen: chosenByBob.add,
      clock: HlcClock(wallClock: () => _now),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();
    await _settle();
    await a.announceBridge('tls://198.51.100.77:32913', powBits: _bits);
    await _settle();
    expect(chosenByBob, isNotEmpty);
    expect(chosenByBob.last, contains('tls://198.51.100.77:32913'));
  });
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
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
