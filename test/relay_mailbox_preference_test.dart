import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String _a(String suffix) => PeerShareCodec.normalizeAddress('200::$suffix');

const int _day = 24 * 60 * 60 * 1000;

final class _Peers implements RelayPeerSource {
  _Peers(this.self, this.friends);

  final String self;
  List<RelayFriend> friends;

  @override
  bool get isReady => true;

  @override
  String get localAddress => self;

  @override
  List<RelayFriend> acceptedFriends() => friends;

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];
}

void main() {
  group('rankRelays', () {
    final int now = 100 * _day;

    test('free places go to friends whose device stays online first', () {
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(
            address: _a('c$i'),
            closeness: 2,
            lastSeenAtMillis: now - 1000,
          ),
        RelayFriend(address: _a('d1'), lastSeenAtMillis: now - 5000),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: const <String>[],
        friends: friends,
        staysOnline: (String a) => a == _a('d1'),
        nowMillis: now,
        maxRelays: 6,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, hasLength(6));
      expect(picked.first, _a('d1'));
    });

    test('a weak acquaintance does not jump the queue for staying online', () {
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(address: _a('c$i'), lastSeenAtMillis: now - 1000),
        RelayFriend(address: _a('w1'), closeness: 0, lastSeenAtMillis: now),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: const <String>[],
        friends: friends,
        staysOnline: (String a) => a == _a('w1'),
        nowMillis: now,
        maxRelays: 6,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, isNot(contains(_a('w1'))));
    });

    test('a device that stays online replaces one that does not', () {
      final List<String> current = <String>[
        for (int i = 0; i < 6; i++) _a('i$i'),
      ];
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(address: _a('i$i'), lastSeenAtMillis: now - i * 1000),
        RelayFriend(address: _a('pc'), lastSeenAtMillis: now - 60000),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        staysOnline: (String a) => a == _a('pc'),
        nowMillis: now,
        maxRelays: 6,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, contains(_a('pc')));
      // The least recently seen one made way.
      expect(picked, isNot(contains(_a('i5'))));
      expect(picked, hasLength(6));
    });

    test('kept relays stay while nothing better shows up (sticky)', () {
      final List<String> current = <String>[_a('i1'), _a('i0')];
      final List<RelayFriend> friends = <RelayFriend>[
        RelayFriend(address: _a('i0'), lastSeenAtMillis: now - 1000),
        RelayFriend(address: _a('i1'), lastSeenAtMillis: now - 2 * _day),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        staysOnline: (_) => false,
        nowMillis: now,
        maxRelays: 6,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, current);
    });

    test('a relay not seen for days makes way for a friend seen lately', () {
      final List<String> current = <String>[
        for (int i = 0; i < 6; i++) _a('i$i'),
      ];
      final List<RelayFriend> friends = <RelayFriend>[
        for (int i = 0; i < 5; i++)
          RelayFriend(address: _a('i$i'), lastSeenAtMillis: now - 1000),
        RelayFriend(address: _a('i5'), lastSeenAtMillis: now - 10 * _day),
        RelayFriend(address: _a('new'), lastSeenAtMillis: now - 1000),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        staysOnline: (_) => false,
        nowMillis: now,
        maxRelays: 6,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, contains(_a('new')));
      expect(picked, isNot(contains(_a('i5'))));
    });

    test('a stale relay stays when nobody fresher is there', () {
      final List<String> current = <String>[_a('i0')];
      final List<RelayFriend> friends = <RelayFriend>[
        RelayFriend(address: _a('i0'), lastSeenAtMillis: now - 10 * _day),
        RelayFriend(address: _a('i1'), lastSeenAtMillis: now - 20 * _day),
      ];
      final List<String> picked = RelayEngine.rankRelays(
        current: current,
        friends: friends,
        staysOnline: (_) => false,
        nowMillis: now,
        maxRelays: 1,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, <String>[_a('i0')]);
    });

    test('a former friend is dropped from the kept relays', () {
      final List<String> picked = RelayEngine.rankRelays(
        current: <String>[_a('gone'), _a('i0')],
        friends: <RelayFriend>[
          RelayFriend(address: _a('i0'), lastSeenAtMillis: now),
        ],
        staysOnline: (_) => false,
        nowMillis: now,
        maxRelays: 6,
        staleAfter: const Duration(days: 3),
      );
      expect(picked, <String>[_a('i0')]);
    });
  });

  group('staying online is announced', () {
    test('the announcement carries the flag and friends prefer it', () async {
      final String self = _a('1');
      final String computer = _a('pc');
      final List<RelayFriend> phones = <RelayFriend>[
        for (int i = 0; i < 6; i++)
          RelayFriend(address: _a('p$i'), lastSeenAtMillis: 5000 - i),
      ];
      final List<Map<String, dynamic>> sentByComputer =
          <Map<String, dynamic>>[];
      final RelayEngine computerEngine = RelayEngine(
        store: MemoryRelayStateStore(),
        peers: _Peers(computer, <RelayFriend>[RelayFriend(address: self)]),
        send: (String to, Map<String, dynamic> payload) async {
          sentByComputer.add(payload);
        },
        clock: () => 6000,
        staysOnline: true,
      );
      await computerEngine.activate();
      await computerEngine.tick();
      final Map<String, dynamic> announcement = sentByComputer.firstWhere(
        (Map<String, dynamic> p) => p['type'] == 'rly_announce',
      );
      expect(announcement['on'], isTrue);

      final MemoryRelayStateStore store = MemoryRelayStateStore();
      final _Peers peers = _Peers(self, <RelayFriend>[
        ...phones,
        RelayFriend(address: computer, lastSeenAtMillis: 1000),
      ]);
      final RelayEngine engine = RelayEngine(
        store: store,
        peers: peers,
        send: (String to, Map<String, dynamic> payload) async {},
        clock: () => 6000,
      );
      await engine.activate();
      expect((await store.load()).currentRelays, isNot(contains(computer)));

      await engine.handleIncoming(
        SignalTransportFrame(
          from: computer,
          payload: announcement,
          receivedAtMillis: 6000,
        ),
      );
      await engine.tick();
      final RelayState state = await store.load();
      expect(state.peers[computer]?.staysOnline, isTrue);
      expect(state.currentRelays, contains(computer));
      expect(state.currentRelays, hasLength(6));
      // The least recently seen phone made way.
      expect(state.currentRelays, isNot(contains(_a('p5'))));
    });

    test('an iPhone does not announce staying online', () async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final RelayEngine engine = RelayEngine(
        store: MemoryRelayStateStore(),
        peers: _Peers(_a('1'), <RelayFriend>[RelayFriend(address: _a('2'))]),
        send: (String to, Map<String, dynamic> payload) async {
          sent.add(payload);
        },
        clock: () => 6000,
      );
      await engine.activate();
      await engine.tick();
      final Map<String, dynamic> announcement = sent.firstWhere(
        (Map<String, dynamic> p) => p['type'] == 'rly_announce',
      );
      expect(announcement.containsKey('on'), isFalse);
    });

    test('the flag survives the stored state', () {
      const RelayPeerInfo info = RelayPeerInfo(
        address: '200::1',
        staysOnline: true,
      );
      expect(RelayPeerInfo.fromJson(info.toJson())?.staysOnline, isTrue);
      expect(
        RelayPeerInfo.fromJson(
          const RelayPeerInfo(address: '200::1').toJson(),
        )?.staysOnline,
        isFalse,
      );
    });
  });
}
