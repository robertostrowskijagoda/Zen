import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/public_peers.dart';
import 'package:zen/src/features/settings/presentation/public_peers_section.dart';

const String _key =
    '000000086278b5f3ba1eb63acb5b7f6e406f04ce83990dee9c07f49011e375ae';

final class FakePublicPeersBridge implements PublicPeersBridge {
  FakePublicPeersBridge({this.refuse = false});

  bool refuse;
  final List<List<String>?> applied = <List<String>?>[];
  Map<String, PublicPeerProbe> results = <String, PublicPeerProbe>{};

  @override
  List<PublicPeer> builtIn() => const <PublicPeer>[
    PublicPeer(uri: 'tls://203.0.113.1:443', country: 'Poland'),
    PublicPeer(uri: 'quic://203.0.113.2:443', country: 'Germany'),
    PublicPeer(uri: 'tls://203.0.113.3:443', enabled: false),
  ];

  @override
  void apply(List<String>? uris) {
    if (refuse) {
      throw StateError('refused');
    }
    applied.add(uris);
  }

  @override
  Future<Map<String, PublicPeerProbe>> probe(List<String> uris) async =>
      results;
}

final class MemoryPublicPeersStore implements PublicPeersStore {
  PublicPeerList? kept;

  @override
  Future<PublicPeerList?> load() async => kept;

  @override
  Future<void> save(PublicPeerList list) async {
    kept = list.custom ? list : null;
  }
}

void main() {
  group('publicPeerUriProblem', () {
    test('takes what Yggdrasil dials', () {
      for (final String good in <String>[
        'tls://203.0.113.10:443',
        ' TLS://ygg.example.org:993?key=$_key ',
        'quic://[2001:db8::1]:4443?priority=3',
        'wss://ygg.example.org/socket?maxbackoff=1m30s',
        'ws://203.0.113.5',
        'tcp://203.0.113.5:1514?password=sekret',
        'tls://203.0.113.10:443?sni=ygg.example.org',
      ]) {
        expect(publicPeerUriProblem(good), isNull, reason: good);
      }
    });

    test('refuses what the bridge refuses', () {
      for (final String bad in <String>[
        '',
        'ygg.example.org:443',
        'http://203.0.113.10:443',
        'socks://127.0.0.1:9050/203.0.113.10:443',
        'tls://203.0.113.10',
        'tls://203.0.113.10:0',
        'tls://:443',
        'tls://user@203.0.113.10:443',
        'tls://203.0.113.10:443#x',
        'tls://203.0.113.10:443/path',
        'tls://[200:1111::1]:443',
        'tls://[::]:443',
        'tls://203.0.113.10:443?key=abcd',
        'tls://203.0.113.10:443?priority=300',
        'tls://203.0.113.10:443?maxbackoff=1s',
        'tls://203.0.113.10:443?maxbackoff=soon',
        'tls://203.0.113.10:443?password=${'p' * 65}',
        'tls://203.0.113.10:443?sni=203.0.113.10',
        'tls://203.0.113.10:443?pirority=1',
        'tls://203.0.113.10:443?priority=1&priority=2',
        'tls://${'a' * 600}:443',
      ]) {
        expect(publicPeerUriProblem(bad), isNotNull, reason: bad);
      }
    });

    test('normalises the transport only and knows encrypted links', () {
      expect(
        normalizePublicPeerUri(' TLS://Ygg.Example.org:443 '),
        'tls://Ygg.Example.org:443',
      );
      expect(isEncryptedPeerUri('tls://a:1'), isTrue);
      expect(isEncryptedPeerUri('wss://a'), isTrue);
      expect(isEncryptedPeerUri('quic://a:1'), isTrue);
      expect(isEncryptedPeerUri('tcp://a:1'), isFalse);
      expect(isEncryptedPeerUri('ws://a'), isFalse);
    });
  });

  test('a kept list round-trips and needs one peer on', () {
    const PublicPeerList list = PublicPeerList(
      custom: true,
      peers: <PublicPeer>[
        PublicPeer(uri: 'tls://203.0.113.1:443', country: 'Poland'),
        PublicPeer(uri: 'tcp://203.0.113.2:1514', enabled: false),
      ],
    );
    final PublicPeerList? again = PublicPeerList.fromJson(
      jsonDecode(jsonEncode(list.toJson())),
    );
    expect(again?.peers, list.peers);
    expect(again?.active, <String>['tls://203.0.113.1:443']);
    expect(
      PublicPeerList.fromJson(<String, Object?>{
        'v': 1,
        'peers': <Object?>[
          <String, Object?>{'uri': 'tls://203.0.113.1:443', 'on': false},
          <String, Object?>{'uri': 'nonsense', 'on': true},
        ],
      }),
      isNull,
    );
  });

  test(
    'the store keeps a list in a file and removes it for defaults',
    () async {
      final Directory dir = await Directory.systemTemp.createTemp('peers');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/runtime/public_peers.json');
      final PublicPeersStore store = PublicPeersStore(file: () async => file);
      expect(await store.load(), isNull);
      await store.save(
        const PublicPeerList(
          custom: true,
          peers: <PublicPeer>[PublicPeer(uri: 'tls://203.0.113.1:443')],
        ),
      );
      expect((await store.load())?.active, <String>['tls://203.0.113.1:443']);
      await store.save(
        const PublicPeerList(custom: false, peers: <PublicPeer>[]),
      );
      expect(file.existsSync(), isFalse);
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');
      expect(await store.load(), isNull);
    },
  );

  group('PublicPeersController', () {
    late FakePublicPeersBridge bridge;
    late MemoryPublicPeersStore store;
    late ProviderContainer container;

    Future<PublicPeersController> open() async {
      container = ProviderContainer(
        overrides: [
          publicPeersBridgeProvider.overrideWithValue(bridge),
          publicPeersStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      container.read(publicPeersProvider);
      final PublicPeersController controller = container.read(
        publicPeersProvider.notifier,
      );
      await controller.loaded;
      return controller;
    }

    PublicPeersState state() => container.read(publicPeersProvider);

    setUp(() {
      bridge = FakePublicPeersBridge();
      store = MemoryPublicPeersStore();
    });

    test('starts from the built-in list', () async {
      await open();
      expect(state().loaded, isTrue);
      expect(state().custom, isFalse);
      expect(state().peers, bridge.builtIn());
      expect(bridge.applied, isEmpty);
    });

    test('an edit makes the list the user\'s and applies it', () async {
      final PublicPeersController controller = await open();
      expect(await controller.add('bad'), isNotNull);
      expect(state().custom, isFalse);
      expect(await controller.add('TLS://203.0.113.9:993?key=$_key'), isNull);
      expect(state().custom, isTrue);
      expect(bridge.applied.last, <String>[
        'tls://203.0.113.1:443',
        'quic://203.0.113.2:443',
        'tls://203.0.113.9:993?key=$_key',
      ]);
      expect(store.kept?.peers.length, 4);
      expect(
        await controller.add('tls://203.0.113.9:993?key=$_key'),
        isNotNull,
        reason: 'no repeats',
      );

      expect(
        await controller.setEnabled('quic://203.0.113.2:443', false),
        isNull,
      );
      expect(await controller.remove('tls://203.0.113.1:443'), isNull);
      expect(bridge.applied.last, <String>['tls://203.0.113.9:993?key=$_key']);
      expect(
        await controller.setEnabled('tls://203.0.113.9:993?key=$_key', false),
        isNotNull,
        reason: 'the node needs at least one peer',
      );
      expect(state().activeCount, 1);

      await controller.restoreDefaults();
      expect(state().custom, isFalse);
      expect(state().peers, bridge.builtIn());
      expect(bridge.applied.last, isNull);
      expect(store.kept, isNull);
    });

    test('a kept list is shown after a restart', () async {
      store.kept = const PublicPeerList(
        custom: true,
        peers: <PublicPeer>[PublicPeer(uri: 'tls://203.0.113.7:443')],
      );
      await open();
      expect(state().custom, isTrue);
      expect(state().peers.single.uri, 'tls://203.0.113.7:443');
    });

    test('a refused list shows an error', () async {
      bridge.refuse = true;
      final PublicPeersController controller = await open();
      await controller.add('tls://203.0.113.9:443');
      expect(state().error, isNotNull);
    });

    test('a checked key can be pinned into the URI', () async {
      bridge.results = <String, PublicPeerProbe>{
        'tls://203.0.113.1:443': const PublicPeerProbe(
          reachable: true,
          latencyMs: 20,
          key: _key,
        ),
      };
      final PublicPeersController controller = await open();
      await controller.check();
      expect(await controller.pinKey('tls://203.0.113.1:443'), isNull);
      expect(state().peers.first.uri, 'tls://203.0.113.1:443?key=$_key');
      expect(publicPeerHasPinnedKey(state().peers.first.uri), isTrue);
      expect(bridge.applied.last?.first, 'tls://203.0.113.1:443?key=$_key');
      expect(
        state().probes['tls://203.0.113.1:443?key=$_key']?.keyMatches,
        isTrue,
      );
      // Nothing to pin without a checked key.
      final int applies = bridge.applied.length;
      expect(await controller.pinKey('quic://203.0.113.2:443'), isNull);
      expect(bridge.applied.length, applies);
    });

    test('check keeps what each peer answered', () async {
      bridge.results = <String, PublicPeerProbe>{
        'tls://203.0.113.1:443': const PublicPeerProbe(
          reachable: true,
          latencyMs: 41.6,
        ),
      };
      final PublicPeersController controller = await open();
      await controller.check();
      expect(state().checking, isFalse);
      expect(state().probes['tls://203.0.113.1:443']?.latencyMs, 41.6);
    });
  });

  test('bridge answers are read', () {
    final List<PublicPeer> builtIn = builtInPublicPeersFrom(<String, dynamic>{
      'peers': <Object?>[
        <String, dynamic>{
          'uri': 'tls://203.0.113.1:443',
          'country': 'Poland',
          'chosen': true,
        },
        <String, dynamic>{'uri': 'quic://203.0.113.2:443'},
        'junk',
      ],
    });
    expect(builtIn.length, 2);
    expect(builtIn.first.enabled, isTrue);
    expect(builtIn.last.enabled, isFalse);
    final Map<String, PublicPeerProbe> probes = publicPeerProbesFrom(
      <String, dynamic>{
        'results': <Object?>[
          <String, dynamic>{
            'uri': 'tls://203.0.113.1:443?key=$_key',
            'reachable': true,
            'latencyMs': 12.5,
            'key': _key,
            'keyMatches': true,
          },
          <String, dynamic>{
            'uri': 'tcp://203.0.113.2:1',
            'reachable': false,
            'error': 'refused',
          },
        ],
      },
    );
    expect(probes['tls://203.0.113.1:443?key=$_key']?.keyMatches, isTrue);
    expect(probes['tcp://203.0.113.2:1']?.reachable, isFalse);
  });

  test('the status line of a peer', () {
    const PublicPeer encrypted = PublicPeer(
      uri: 'tls://203.0.113.1:443',
      country: 'Poland',
    );
    const PublicPeer clear = PublicPeer(uri: 'tcp://203.0.113.1:1514');
    expect(publicPeerStatusText(encrypted, null), 'Poland');
    expect(
      publicPeerStatusText(
        encrypted,
        const PublicPeerProbe(reachable: true, latencyMs: 41.6),
      ),
      'Poland · 42 ms',
    );
    expect(
      publicPeerStatusText(
        encrypted,
        const PublicPeerProbe(reachable: true, keyMatches: false),
      ),
      'Poland · Klucz się nie zgadza',
    );
    expect(
      publicPeerStatusText(clear, const PublicPeerProbe(reachable: false)),
      'Nie odpowiada · Łącze bez szyfrowania',
    );
  });
}
