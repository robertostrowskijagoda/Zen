import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// A tiny in-memory mesh: nodes, an online set, a FIFO of datagrams.
final class _SimMesh {
  _SimMesh();

  int now = 1000000;
  final Map<String, _SimNode> nodes = <String, _SimNode>{};
  final Set<String> online = <String>{};
  final Queue<({String from, String to, Map<String, dynamic> payload})>
  _inFlight = Queue<({String from, String to, Map<String, dynamic> payload})>();

  /// Hook to tamper with datagrams in flight.
  Map<String, dynamic>? Function(
    String from,
    String to,
    Map<String, dynamic> p,
  )?
  interceptor;

  _SimNode add(
    String address, {
    List<String>? friends,
    RelayConfig config = const RelayConfig(),
  }) {
    final _SimNode node = _SimNode(this, address, config: config);
    nodes[address] = node;
    online.add(address);
    return node;
  }

  void befriendAll() {
    for (final _SimNode node in nodes.values) {
      node.friends
        ..clear()
        ..addAll(nodes.keys.where((String a) => a != node.address));
    }
  }

  Future<void> send(
    String from,
    String to,
    Map<String, dynamic> payload,
  ) async {
    if (!online.contains(from)) {
      throw StateError('$from is offline');
    }
    // Like UDP over the mesh: to an offline peer the datagram just vanishes.
    if (!online.contains(to)) {
      return;
    }
    Map<String, dynamic> copy =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    final Map<String, dynamic>? Function(String, String, Map<String, dynamic>)?
    hook = interceptor;
    if (hook != null) {
      final Map<String, dynamic>? replaced = hook(from, to, copy);
      if (replaced == null) {
        return;
      }
      copy = replaced;
    }
    _inFlight.add((from: from, to: to, payload: copy));
  }

  /// Delivers datagrams until the network is quiet.
  Future<void> settle({int maxSteps = 5000}) async {
    int steps = 0;
    while (_inFlight.isNotEmpty) {
      if (++steps > maxSteps) {
        fail('network did not settle');
      }
      final ({String from, String to, Map<String, dynamic> payload}) datagram =
          _inFlight.removeFirst();
      if (!online.contains(datagram.to)) {
        continue;
      }
      await nodes[datagram.to]!.receive(datagram.from, datagram.payload);
    }
  }

  Future<void> advance(Duration duration) async {
    now += duration.inMilliseconds;
    for (final _SimNode node in nodes.values) {
      if (online.contains(node.address)) {
        await node.engine.tick();
      }
    }
    await settle();
  }

  Future<void> goOffline(String address) async {
    online.remove(address);
    nodes[address]!.engine.deactivate();
  }

  Future<void> goOnline(String address) async {
    online.add(address);
    await nodes[address]!.engine.activate();
    await settle();
  }
}

final class _SimNode implements RelayPeerSource {
  _SimNode(this.mesh, this.address, {this.config = const RelayConfig()}) {
    engine = RelayEngine(
      config: config,
      store: store,
      peers: this,
      send: (String to, Map<String, dynamic> payload) =>
          mesh.send(address, to, payload),
      clock: () => mesh.now,
    );
  }

  final RelayConfig config;
  final _SimMesh mesh;
  final String address;
  final MemoryRelayStateStore store = MemoryRelayStateStore();
  late RelayEngine engine;
  final List<String> friends = <String>[];
  final List<SignalTransportFrame> appFrames = <SignalTransportFrame>[];

  bool ready = true;

  @override
  bool get isReady => ready;

  @override
  String get localAddress => address;

  final List<String> groupMates = <String>[];

  @override
  List<RelayFriend> groupContacts() =>
      groupMates.map((String a) => RelayFriend(address: a)).toList();

  @override
  List<RelayFriend> acceptedFriends() => friends
      .map(
        (String a) => RelayFriend(
          address: a,
          // Helpers look a touch more active, so automatic selection picks
          // six of them and never alice/bob (keeps scenarios deterministic).
          lastSeenAtMillis: !mesh.online.contains(a)
              ? 0
              : mesh.now - (helpers.contains(a) ? 0 : 1),
        ),
      )
      .toList();

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    appFrames.addAll(
      await engine.handleIncoming(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: mesh.now,
        ),
      ),
    );
  }

  /// Simulates an app restart: a fresh engine over the same stored state.
  void restart() {
    engine = RelayEngine(
      config: config,
      store: store,
      peers: this,
      send: (String to, Map<String, dynamic> payload) =>
          mesh.send(address, to, payload),
      clock: () => mesh.now,
    );
  }

  List<String> get receivedTexts => appFrames
      .where((SignalTransportFrame f) => f.payload['type'] == 'message')
      .map((SignalTransportFrame f) => f.payload['text'] as String)
      .toList();

  Future<RelayState> state() => store.load();
}

Map<String, dynamic> _text(String text) => <String, dynamic>{
  'type': 'message',
  'msgId': 'm-$text',
  'text': text,
};

// Canonical mesh addresses, exactly as the engine will spell them.
String _addr(String raw) => PeerShareCodec.normalizeAddress(raw);
final String alice = _addr('200::a');
final String bob = _addr('200::b');
final List<String> helpers = <String>[
  for (int i = 1; i <= 7; i++) _addr('200::c$i'),
];

/// Everyone befriended, all online, relay sets announced and confirmed.
Future<_SimMesh> _meshWithRelays() async {
  final _SimMesh mesh = _SimMesh();
  mesh.add(alice);
  mesh.add(bob);
  for (final String helper in helpers) {
    mesh.add(helper);
  }
  mesh.befriendAll();
  for (final _SimNode node in mesh.nodes.values) {
    await node.engine.activate();
  }
  await mesh.settle();
  // First ticks announce every relay set to every friend.
  await mesh.advance(const Duration(seconds: 1));
  return mesh;
}

void main() {
  test(
    'online recipient gets the message exactly once, outbox clears',
    () async {
      final _SimMesh mesh = await _meshWithRelays();

      await mesh.nodes[alice]!.engine.submit(bob, _text('hej'));
      await mesh.settle();

      expect(mesh.nodes[bob]!.receivedTexts, <String>['hej']);
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
    },
  );

  test('every device picks at most six relays and announces them', () async {
    final _SimMesh mesh = await _meshWithRelays();

    final RelayState bobState = await mesh.nodes[bob]!.state();
    expect(bobState.currentRelays, hasLength(6));
    expect(bobState.currentRelays, isNot(contains(bob)));
    final RelayState aliceState = await mesh.nodes[alice]!.state();
    expect(aliceState.peers[bob]?.relays, bobState.currentRelays);
    expect(aliceState.peers[bob]?.publicKey, isNotNull);
    expect(bobState.currentRelays.every(helpers.contains), isTrue);
    expect(bobState.announcedVersions[alice], bobState.relaySetVersion);
  });

  test(
    'offline recipient gets its mail from relays when it comes back',
    () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.goOffline(bob);

      await mesh.nodes[alice]!.engine.submit(bob, _text('jesteś?'));
      await mesh.settle();
      await mesh.advance(const Duration(seconds: 5)); // past depositAfter

      final List<String> bobRelays =
          (await mesh.nodes[bob]!.state()).currentRelays;
      for (final String relay in bobRelays) {
        final RelayState relayState = await mesh.nodes[relay]!.state();
        expect(relayState.mailbox[bob], hasLength(1), reason: relay);
      }

      // Alice goes away too; only the relays can deliver now.
      await mesh.goOffline(alice);
      await mesh.goOnline(bob);

      expect(mesh.nodes[bob]!.receivedTexts, <String>['jesteś?']);
      for (final String relay in bobRelays) {
        expect(
          (await mesh.nodes[relay]!.state()).mailbox[bob],
          isNull,
          reason: 'purged at $relay',
        );
      }

      // Alice comes back: bob's direct ack arrives on her next retry, and the
      // repeat copy is not delivered to bob's app a second time.
      await mesh.goOnline(alice);
      await mesh.advance(const Duration(minutes: 3));
      expect(mesh.nodes[bob]!.receivedTexts, <String>['jesteś?']);
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
    },
  );

  test('a relay that was offline catches up from the other relays', () async {
    final _SimMesh mesh = await _meshWithRelays();
    final List<String> bobRelays =
        (await mesh.nodes[bob]!.state()).currentRelays;
    final String lateRelay = bobRelays.first;
    await mesh.goOffline(bob);
    await mesh.goOffline(lateRelay);

    await mesh.nodes[alice]!.engine.submit(bob, _text('dla spóźnialskich'));
    await mesh.advance(const Duration(seconds: 5));
    expect((await mesh.nodes[lateRelay]!.state()).mailbox[bob], isNull);

    // Alice leaves before the late relay returns: only co-relays can help.
    await mesh.goOffline(alice);
    await mesh.goOnline(lateRelay);
    await mesh.advance(const Duration(minutes: 11));
    expect((await mesh.nodes[lateRelay]!.state()).mailbox[bob], hasLength(1));

    // Every other relay disappears; bob can still get it from the late one.
    for (final String relay in bobRelays.skip(1)) {
      await mesh.goOffline(relay);
    }
    await mesh.goOnline(bob);
    expect(mesh.nodes[bob]!.receivedTexts, <String>['dla spóźnialskich']);
  });

  test(
    'relays delivered while one relay was away get purged there later',
    () async {
      final _SimMesh mesh = await _meshWithRelays();
      final List<String> bobRelays =
          (await mesh.nodes[bob]!.state()).currentRelays;
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, _text('raz'));
      await mesh.advance(const Duration(seconds: 5));

      final String away = bobRelays.last;
      await mesh.goOffline(away);
      await mesh.goOnline(bob);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['raz']);
      expect((await mesh.nodes[away]!.state()).mailbox[bob], hasLength(1));

      // Back online: a co-relay's tombstones clear the stale copy, and bob does
      // not get it a second time.
      await mesh.goOnline(away);
      await mesh.advance(const Duration(minutes: 11));
      expect((await mesh.nodes[away]!.state()).mailbox[bob], isNull);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['raz']);
    },
  );

  test('relays only ever hold ciphertext, and tampering is rejected', () async {
    final _SimMesh mesh = await _meshWithRelays();
    await mesh.goOffline(bob);
    await mesh.nodes[alice]!.engine.submit(bob, _text('tajne hasło'));
    await mesh.advance(const Duration(seconds: 5));

    for (final String relay in helpers) {
      final RelayState relayState = await mesh.nodes[relay]!.state();
      expect(relayState.toJsonString(), isNot(contains('tajne')));
    }

    // Flip one ciphertext byte in every mail delivery.
    mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
      if (p['type'] == 'rly_mail') {
        for (final Object? item in p['items'] as List<dynamic>) {
          final Map<String, dynamic> env = item! as Map<String, dynamic>;
          final List<int> body = base64Url.decode(env['b'] as String);
          body[0] ^= 0xFF;
          env['b'] = base64Url.encode(body);
        }
      }
      return p;
    };
    await mesh.goOnline(bob);
    expect(mesh.nodes[bob]!.receivedTexts, isEmpty);
  });

  test('a relay swapping the sender is rejected', () async {
    final _SimMesh mesh = await _meshWithRelays();
    await mesh.goOffline(bob);
    await mesh.nodes[alice]!.engine.submit(bob, _text('od alice'));
    await mesh.advance(const Duration(seconds: 5));

    mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
      if (p['type'] == 'rly_mail') {
        for (final Object? item in p['items'] as List<dynamic>) {
          (item! as Map<String, dynamic>)['s'] = helpers.last;
        }
      }
      return p;
    };
    await mesh.goOnline(bob);
    expect(mesh.nodes[bob]!.appFrames, isEmpty);
  });

  test('duplicate direct copies reach the app once', () async {
    final _SimMesh mesh = await _meshWithRelays();
    final Map<String, dynamic> payload = <String, dynamic>{
      ..._text('echo'),
      kReliableIdKey: 'fixed-id',
    };
    await mesh.nodes[bob]!.receive(alice, payload);
    await mesh.nodes[bob]!.receive(alice, payload);
    expect(mesh.nodes[bob]!.receivedTexts, <String>['echo']);
  });

  test('outbox survives a restart and still delivers', () async {
    final _SimMesh mesh = await _meshWithRelays();
    await mesh.goOffline(bob);
    // Deliberately before depositAfter: nothing reached the relays yet.
    await mesh.nodes[alice]!.engine.submit(bob, _text('po restarcie'));
    await mesh.settle();

    await mesh.goOffline(alice);
    mesh.nodes[alice]!.restart();
    await mesh.goOnline(alice);
    await mesh.goOnline(bob);
    await mesh.advance(const Duration(seconds: 12));

    expect(mesh.nodes[bob]!.receivedTexts, <String>['po restarcie']);
    expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
  });

  test('changing relays in settings propagates to friends', () async {
    final _SimMesh mesh = await _meshWithRelays();
    final List<String> chosen = <String>[helpers[5], helpers[6]];

    await mesh.nodes[bob]!.engine.setManualRelays(chosen);
    await mesh.settle();

    final RelayState bobState = await mesh.nodes[bob]!.state();
    expect(bobState.currentRelays, chosen);
    expect(bobState.manualRelays, chosen);
    expect((await mesh.nodes[alice]!.state()).peers[bob]?.relays, chosen);

    // Mail now goes to exactly the chosen relays.
    await mesh.goOffline(bob);
    await mesh.nodes[alice]!.engine.submit(bob, _text('nowe skrzynki'));
    await mesh.advance(const Duration(seconds: 5));
    for (final String helper in helpers) {
      final bool holds =
          (await mesh.nodes[helper]!.state()).mailbox[bob]?.isNotEmpty ?? false;
      expect(holds, chosen.contains(helper), reason: helper);
    }

    // Back to automatic.
    await mesh.nodes[bob]!.engine.setManualRelays(null);
    expect((await mesh.nodes[bob]!.state()).manualRelays, isNull);
  });

  test(
    'a friend that was offline during a relay change learns it later',
    () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.goOffline(alice);
      await mesh.nodes[bob]!.engine.setManualRelays(<String>[helpers[0]]);
      await mesh.settle();

      await mesh.goOnline(alice);
      // Alice's presence reaches bob (any frame counts); bob re-announces.
      await mesh.nodes[alice]!.engine.submit(bob, _text('ping'));
      await mesh.advance(const Duration(seconds: 6));

      expect((await mesh.nodes[alice]!.state()).peers[bob]?.relays, <String>[
        helpers[0],
      ]);
    },
  );

  test('automatic relay set is sticky and fills vacancies only', () async {
    final _SimMesh mesh = await _meshWithRelays();
    final List<String> before = (await mesh.nodes[bob]!.state()).currentRelays;
    final int version = (await mesh.nodes[bob]!.state()).relaySetVersion;

    await mesh.advance(const Duration(minutes: 1));
    expect((await mesh.nodes[bob]!.state()).relaySetVersion, version);

    // A relay stops being a friend: exactly that slot is refilled.
    final String dropped = before.first;
    mesh.nodes[bob]!.friends.remove(dropped);
    await mesh.advance(const Duration(seconds: 6));
    final List<String> after = (await mesh.nodes[bob]!.state()).currentRelays;
    expect(after, isNot(contains(dropped)));
    expect(after, hasLength(6));
    expect(after.toSet().intersection(before.toSet()), hasLength(5));
  });

  test(
    'an app start with the friend list not loaded yet changes nothing',
    () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayState before = await mesh.nodes[bob]!.state();

      // Restart bob with an empty, not-yet-loaded friend list.
      await mesh.goOffline(bob);
      final List<String> savedFriends = List<String>.of(
        mesh.nodes[bob]!.friends,
      );
      mesh.nodes[bob]!
        ..friends.clear()
        ..ready = false
        ..restart();
      await mesh.goOnline(bob);
      await mesh.advance(const Duration(seconds: 6));

      RelayState during = await mesh.nodes[bob]!.state();
      expect(during.currentRelays, before.currentRelays);
      expect(during.relaySetVersion, before.relaySetVersion);

      // Loaded: still the same set, no churn.
      mesh.nodes[bob]!
        ..friends.addAll(savedFriends)
        ..ready = true;
      await mesh.advance(const Duration(seconds: 6));
      during = await mesh.nodes[bob]!.state();
      expect(during.currentRelays, before.currentRelays);
      expect(during.relaySetVersion, before.relaySetVersion);
    },
  );

  test('relays refuse mail for peers that did not choose them', () async {
    final _SimMesh mesh = await _meshWithRelays();
    final List<String> bobRelays =
        (await mesh.nodes[bob]!.state()).currentRelays;
    final String outsider = helpers.firstWhere(
      (String h) => !bobRelays.contains(h),
    );
    await mesh.nodes[outsider]!.receive(alice, <String, dynamic>{
      'type': 'rly_deposit',
      'env': <String, dynamic>{
        'id': 'x',
        's': alice,
        'r': bob,
        'c': mesh.now,
        'x': mesh.now + 100000,
        'e': base64Url.encode(List<int>.filled(32, 1)),
        'n': base64Url.encode(List<int>.filled(12, 1)),
        'b': base64Url.encode(List<int>.filled(40, 1)),
      },
    });
    expect((await mesh.nodes[outsider]!.state()).mailbox, isEmpty);
  });

  test('non-reliable payload types are not queued', () {
    expect(isReliablePayload(<String, dynamic>{'type': 'typing'}), isFalse);
    expect(isReliablePayload(<String, dynamic>{'type': 'ping'}), isFalse);
    expect(
      isReliablePayload(<String, dynamic>{'type': 'call_invite'}),
      isFalse,
    );
    expect(
      isReliablePayload(<String, dynamic>{
        'type': 'message',
        kSendOnceKey: true,
      }),
      isFalse,
    );
    expect(
      isReliablePayload(<String, dynamic>{'type': 'group_invite'}),
      isTrue,
    );
    expect(isReliablePayload(<String, dynamic>{'type': 'message'}), isTrue);
  });

  group('group members who are not friends', () {
    /// Alice and bob share a group but are not friends; the helpers are
    /// everyone's friends and hold mail as usual.
    Future<_SimMesh> groupMesh({bool bobShares = true}) async {
      final _SimMesh mesh = _SimMesh();
      mesh.add(alice);
      mesh.add(bob);
      for (final String helper in helpers) {
        mesh.add(helper);
      }
      mesh.befriendAll();
      mesh.nodes[alice]!
        ..friends.remove(bob)
        ..groupMates.add(bob);
      mesh.nodes[bob]!
        ..friends.remove(alice)
        ..groupMates.add(alice);
      if (!bobShares) {
        await mesh.nodes[bob]!.engine.setShareWithGroups(false);
      }
      for (final _SimNode node in mesh.nodes.values) {
        await node.engine.activate();
      }
      await mesh.settle();
      await mesh.advance(const Duration(seconds: 1));
      return mesh;
    }

    Map<String, dynamic> groupText(String text) => <String, dynamic>{
      'type': 'group_message',
      'groupId': 'g',
      'msgId': 'gm-$text',
      'text': text,
    };

    test('a group message waits in the offline member\'s mailboxes', () async {
      final _SimMesh mesh = await groupMesh();
      expect(
        (await mesh.nodes[alice]!.state()).peers[bob]?.relays,
        hasLength(6),
        reason: 'bob announced his mailboxes to his group mate',
      );
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, groupText('zbiórka'));
      await mesh.advance(const Duration(seconds: 5));
      await mesh.goOffline(alice);

      await mesh.goOnline(bob);
      final List<String> texts = mesh.nodes[bob]!.appFrames
          .where(
            (SignalTransportFrame f) => f.payload['type'] == 'group_message',
          )
          .map((SignalTransportFrame f) => f.payload['text'] as String)
          .toList();
      expect(texts, <String>['zbiórka']);
    });

    test('with sharing off nothing about the mailboxes leaks, and delivery '
        'falls back to direct retries', () async {
      final _SimMesh mesh = await groupMesh(bobShares: false);
      expect((await mesh.nodes[alice]!.state()).peers[bob], isNull);

      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, groupText('później'));
      await mesh.advance(const Duration(seconds: 5));
      for (final String helper in helpers) {
        expect((await mesh.nodes[helper]!.state()).mailbox[bob], isNull);
      }

      await mesh.goOnline(bob);
      await mesh.advance(const Duration(minutes: 3));
      expect(
        mesh.nodes[bob]!.appFrames.where(
          (SignalTransportFrame f) => f.payload['text'] == 'później',
        ),
        hasLength(1),
      );
    });

    test(
      'a relay refuses envelopes handed in on someone else\'s behalf',
      () async {
        final _SimMesh mesh = await groupMesh();
        final String relay =
            (await mesh.nodes[bob]!.state()).currentRelays.first;
        final String mallory = _addr('200::bad');
        mesh.add(mallory);
        await mesh.nodes[relay]!.receive(mallory, <String, dynamic>{
          'type': 'rly_deposit',
          'env': _fakeEnvelope(
            id: 'spoof',
            sender: alice,
            recipient: bob,
            now: mesh.now,
          ),
        });
        expect((await mesh.nodes[relay]!.state()).mailbox[bob], isNull);
      },
    );
  });

  test('a flooding sender only ever pushes out its own mail', () async {
    final _SimMesh mesh = _SimMesh();
    mesh.add(alice);
    mesh.add(bob);
    final String relay = helpers.first;
    final String carol = helpers[1];
    mesh.add(relay, config: const RelayConfig(maxHeldPerSender: 3));
    mesh.add(carol);
    mesh.befriendAll();
    for (final _SimNode node in mesh.nodes.values) {
      await node.engine.activate();
    }
    await mesh.advance(const Duration(seconds: 1));
    expect((await mesh.nodes[bob]!.state()).currentRelays, contains(relay));

    await mesh.goOffline(bob);
    await mesh.nodes[relay]!.receive(carol, <String, dynamic>{
      'type': 'rly_deposit',
      'env': _fakeEnvelope(
        id: 'carol-1',
        sender: carol,
        recipient: bob,
        now: mesh.now,
      ),
    });
    for (int i = 0; i < 10; i++) {
      mesh.now += 1;
      await mesh.nodes[relay]!.receive(alice, <String, dynamic>{
        'type': 'rly_deposit',
        'env': _fakeEnvelope(
          id: 'alice-$i',
          sender: alice,
          recipient: bob,
          now: mesh.now,
        ),
      });
    }
    final Map<String, Map<String, dynamic>> held =
        (await mesh.nodes[relay]!.state()).mailbox[bob]!;
    expect(
      held.keys,
      containsAll(<String>['carol-1', 'alice-7', 'alice-8', 'alice-9']),
    );
    expect(held, hasLength(4));
  });

  group('hardening', () {
    Map<String, dynamic> deposit(Map<String, dynamic> envelope) =>
        <String, dynamic>{'type': 'rly_deposit', 'env': envelope};

    Future<String> firstRelayOf(_SimMesh mesh, String recipient) async =>
        (await mesh.nodes[recipient]!.state()).currentRelays.first;

    test(
      'only the recipient clears its held mail, and only what is held',
      () async {
        final _SimMesh mesh = await _meshWithRelays();
        final String relay = await firstRelayOf(mesh, bob);
        await mesh.goOffline(bob);
        await mesh.nodes[alice]!.engine.submit(bob, _text('zostaje'));
        await mesh.advance(const Duration(seconds: 5));
        final List<String> held = (await mesh.nodes[relay]!.state())
            .mailbox[bob]!
            .keys
            .toList();
        expect(held, hasLength(1));

        final String mallory = _addr('200::bad');
        final List<String> junk = <String>[
          for (int i = 0; i < 1000; i++) 'junk-$i',
        ];
        await mesh.nodes[relay]!.receive(mallory, <String, dynamic>{
          'type': 'rly_mail_ack',
          'ids': <String>[...held, ...junk],
        });
        await mesh.nodes[relay]!.receive(mallory, <String, dynamic>{
          'type': 'rly_purge',
          'ids': junk,
        });
        // Even the recipient cannot make the relay remember ids it never held.
        await mesh.nodes[relay]!.receive(bob, <String, dynamic>{
          'type': 'rly_purge',
          'ids': junk,
        });
        RelayState state = await mesh.nodes[relay]!.state();
        expect(state.mailbox[bob]!.keys, held);
        expect(state.tombstones, isEmpty);

        await mesh.nodes[relay]!.receive(bob, <String, dynamic>{
          'type': 'rly_mail_ack',
          'ids': held,
        });
        state = await mesh.nodes[relay]!.state();
        expect(state.mailbox[bob], isNull);
        expect(state.tombstones.keys, <String>['$bob|${held.single}']);
      },
    );

    test('announcement confirmations count only from contacts', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayState before = await mesh.nodes[bob]!.state();
      for (int i = 0; i < 50; i++) {
        await mesh.nodes[bob]!.receive(_addr('200::f:$i'), <String, dynamic>{
          'type': 'rly_announce_ack',
          'v': before.relaySetVersion,
        });
      }
      final RelayState after = await mesh.nodes[bob]!.state();
      expect(
        after.announcedVersions.keys.toSet(),
        before.announcedVersions.keys.toSet(),
      );
    });

    test(
      'reliable frames from strangers are de-duplicated in memory only',
      () async {
        final _SimMesh mesh = await _meshWithRelays();
        final String stranger = _addr('200::5');
        const Map<String, dynamic> request = <String, dynamic>{
          'type': 'friend_request',
          kReliableIdKey: 'req-1',
        };
        await mesh.nodes[bob]!.receive(stranger, request);
        await mesh.nodes[bob]!.receive(stranger, request);
        for (int i = 0; i < 20; i++) {
          await mesh.nodes[bob]!.receive(stranger, <String, dynamic>{
            'type': 'friend_request',
            kReliableIdKey: 'flood-$i',
          });
        }
        await mesh.nodes[bob]!.receive(stranger, <String, dynamic>{
          'type': 'friend_request',
          kReliableIdKey: 'x' * 500,
        });
        final Iterable<SignalTransportFrame> requests = mesh
            .nodes[bob]!
            .appFrames
            .where(
              (SignalTransportFrame f) => f.payload['type'] == 'friend_request',
            );
        expect(requests, hasLength(21));
        expect(
          (await mesh.nodes[bob]!.state()).seen.keys.where(
            (String key) => key.startsWith('$stranger|'),
          ),
          isEmpty,
        );

        // A friend's receipts are stored as before.
        await mesh.nodes[bob]!.receive(alice, <String, dynamic>{
          ..._text('od przyjaciela'),
          kReliableIdKey: 'f-1',
        });
        expect((await mesh.nodes[bob]!.state()).seen, contains('$alice|f-1'));
      },
    );

    test('deposits from strangers only compete with each other', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final String relay = await firstRelayOf(mesh, bob);
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, _text('od alice'));
      await mesh.advance(const Duration(seconds: 5));

      // Throwaway addresses: each its own /64, and many inside one /64.
      for (int i = 0; i < 60; i++) {
        final String sybil = _addr('200:${i + 1}::1');
        mesh.now += 1;
        await mesh.nodes[relay]!.receive(
          sybil,
          deposit(
            _fakeEnvelope(
              id: 'junk-$i',
              sender: sybil,
              recipient: bob,
              now: mesh.now,
            ),
          ),
        );
      }
      for (int i = 0; i < 30; i++) {
        final String neighbour = _addr('200:abcd::${i + 1}');
        mesh.now += 1;
        await mesh.nodes[relay]!.receive(
          neighbour,
          deposit(
            _fakeEnvelope(
              id: 'net-$i',
              sender: neighbour,
              recipient: bob,
              now: mesh.now,
            ),
          ),
        );
      }
      final Map<String, Map<String, dynamic>> held =
          (await mesh.nodes[relay]!.state()).mailbox[bob]!;
      final List<Map<String, dynamic>> unvouched = held.values
          .where((Map<String, dynamic> e) => e['hv'] == false)
          .toList();
      expect(unvouched.length, lessThanOrEqualTo(30));
      expect(
        held.keys.where((String id) => id.startsWith('net-')).length,
        lessThanOrEqualTo(10),
      );
      expect(
        held.values.where((Map<String, dynamic> e) => e['s'] == alice),
        hasLength(1),
        reason: 'a friend\'s mail is never pushed out by strangers',
      );

      await mesh.goOffline(alice);
      await mesh.goOnline(bob);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['od alice']);
    });

    test(
      'a sender the relay does not know shows the recipient\'s token',
      () async {
        final _SimMesh mesh = _SimMesh();
        mesh.add(alice);
        mesh.add(bob);
        for (final String helper in helpers) {
          mesh.add(helper);
        }
        mesh.befriendAll();
        // Alice only knows bob; bob's relays (the helpers) do not know alice.
        mesh.nodes[alice]!.friends
          ..clear()
          ..add(bob);
        for (final String helper in helpers) {
          mesh.nodes[helper]!.friends.remove(alice);
        }
        for (final _SimNode node in mesh.nodes.values) {
          await node.engine.activate();
        }
        await mesh.settle();
        await mesh.advance(const Duration(seconds: 1));
        final List<String> bobRelays =
            (await mesh.nodes[bob]!.state()).currentRelays;
        expect(bobRelays.every(helpers.contains), isTrue);
        expect(
          (await mesh.nodes[alice]!.state()).peers[bob]?.depositToken,
          isNotNull,
        );

        await mesh.goOffline(bob);
        await mesh.nodes[alice]!.engine.submit(bob, _text('przez obcych'));
        await mesh.advance(const Duration(seconds: 5));
        for (final String relay in bobRelays) {
          final Map<String, Map<String, dynamic>> held =
              (await mesh.nodes[relay]!.state()).mailbox[bob]!;
          expect(held.values.single['hv'], isTrue, reason: relay);
        }

        // A flood of strangers does not push it out.
        final String target = bobRelays.first;
        for (int i = 0; i < 60; i++) {
          final String sybil = _addr('200:${i + 1}::2');
          await mesh.nodes[target]!.receive(
            sybil,
            deposit(
              _fakeEnvelope(
                id: 'junk-$i',
                sender: sybil,
                recipient: bob,
                now: mesh.now,
              ),
            ),
          );
        }
        expect(
          (await mesh.nodes[target]!.state()).mailbox[bob]!.values.where(
            (Map<String, dynamic> e) => e['s'] == alice,
          ),
          hasLength(1),
        );

        await mesh.goOffline(alice);
        for (final String other in bobRelays.skip(1)) {
          await mesh.goOffline(other);
        }
        await mesh.goOnline(bob);
        expect(mesh.nodes[bob]!.receivedTexts, <String>['przez obcych']);
      },
    );

    test('relays hold mail no longer than a message lives', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final String relay = await firstRelayOf(mesh, bob);
      await mesh.goOffline(bob);
      final Map<String, dynamic> far = _fakeEnvelope(
        id: 'far',
        sender: alice,
        recipient: bob,
        now: mesh.now,
      )..['x'] = mesh.now + const Duration(days: 400).inMilliseconds;
      await mesh.nodes[relay]!.receive(alice, deposit(far));
      expect((await mesh.nodes[relay]!.state()).mailbox[bob], contains('far'));

      await mesh.advance(const Duration(days: 15));
      expect((await mesh.nodes[relay]!.state()).mailbox[bob], isNull);
    });

    test('a relay does not resend unchanged mail at every sighting', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final String relay = await firstRelayOf(mesh, bob);
      final String stranger = _addr('200:77::1');
      await mesh.nodes[relay]!.receive(
        stranger,
        deposit(
          _fakeEnvelope(
            id: 'unknown',
            sender: stranger,
            recipient: bob,
            now: mesh.now,
          ),
        ),
      );
      await mesh.settle();

      int pushes = 0;
      mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
        if (from == relay && to == bob && p['type'] == 'rly_mail') {
          pushes++;
        }
        return p;
      };
      for (int i = 0; i < 5; i++) {
        mesh.now += 6000; // past the sighting throttle
        await mesh.nodes[relay]!.receive(bob, <String, dynamic>{
          'type': 'typing',
        });
      }
      expect(pushes, 0);

      // Asking explicitly still gets everything.
      await mesh.nodes[relay]!.receive(bob, <String, dynamic>{
        'type': 'rly_poll',
      });
      expect(pushes, 1);
    });

    test(
      'mail handed over by someone who is not a friend is ignored',
      () async {
        final _SimMesh mesh = await _meshWithRelays();
        final String mallory = _addr('200::bad');
        mesh.add(mallory);
        final List<Object?> sentByBob = <Object?>[];
        mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
          if (from == bob) {
            sentByBob.add(p['type']);
          }
          return p;
        };
        await mesh.nodes[bob]!.receive(mallory, <String, dynamic>{
          'type': 'rly_mail',
          'items': <Object?>[
            for (int i = 0; i < 20; i++)
              _fakeEnvelope(
                id: 'm$i',
                sender: alice,
                recipient: bob,
                now: mesh.now,
              ),
          ],
        });
        await mesh.settle();
        expect(sentByBob, isNot(contains('rly_mail_ack')));
        expect(sentByBob, isNot(contains('rly_purge')));
      },
    );

    Future<Map<String, dynamic>> deliverViaRelays(
      _SimMesh mesh,
      String text,
    ) async {
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, _text(text));
      await mesh.advance(const Duration(seconds: 5));
      await mesh.goOffline(alice);
      Map<String, dynamic>? captured;
      mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
        if (to == bob && p['type'] == 'rly_mail') {
          captured ??= jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
        }
        return p;
      };
      await mesh.goOnline(bob);
      mesh.interceptor = null;
      expect(mesh.nodes[bob]!.receivedTexts, <String>[text]);
      expect(captured, isNotNull);
      return captured!;
    }

    test('an expired copy handed over again is refused', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final Map<String, dynamic> copy = await deliverViaRelays(mesh, 'raz');

      // Long after: the receipt has expired, and so has the envelope.
      mesh.now += const Duration(days: 15).inMilliseconds;
      await mesh.nodes[bob]!.engine.tick();
      final String relay = await firstRelayOf(mesh, bob);
      await mesh.nodes[bob]!.receive(relay, copy);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['raz']);
    });

    test('a copy older than a forgotten receipt is refused', () async {
      final _SimMesh mesh = _SimMesh();
      mesh.add(alice);
      mesh.add(bob, config: const RelayConfig(maxSeenEntries: 2));
      for (final String helper in helpers) {
        mesh.add(helper);
      }
      mesh.befriendAll();
      for (final _SimNode node in mesh.nodes.values) {
        await node.engine.activate();
      }
      await mesh.settle();
      await mesh.advance(const Duration(seconds: 1));
      final Map<String, dynamic> copy = await deliverViaRelays(
        mesh,
        'pierwsza',
      );

      await mesh.goOnline(alice);
      await mesh.advance(const Duration(minutes: 3));
      for (final String text in <String>['druga', 'trzecia', 'czwarta']) {
        mesh.now += 1000;
        await mesh.nodes[alice]!.engine.submit(bob, _text(text));
        await mesh.settle();
      }
      await mesh.nodes[bob]!.engine.tick(); // receipts trimmed to two
      final RelayState state = await mesh.nodes[bob]!.state();
      expect(state.seen, hasLength(2));
      expect(
        state.seenFloors.values.single,
        greaterThan(0),
        reason: 'only the sender whose receipts were dropped gets a floor',
      );

      final String relay = await firstRelayOf(mesh, bob);
      await mesh.nodes[bob]!.receive(relay, copy);
      expect(mesh.nodes[bob]!.receivedTexts, <String>[
        'pierwsza',
        'druga',
        'trzecia',
        'czwarta',
      ]);
    });

    test(
      'mail nobody can attribute is dropped after the grace period',
      () async {
        final _SimMesh mesh = await _meshWithRelays();
        final String relay = await firstRelayOf(mesh, bob);
        final String stranger = _addr('200:99::1');
        await mesh.nodes[relay]!.receive(
          stranger,
          deposit(
            _fakeEnvelope(
              id: 'who',
              sender: stranger,
              recipient: bob,
              now: mesh.now,
            ),
          ),
        );
        await mesh.settle();
        expect(
          (await mesh.nodes[relay]!.state()).mailbox[bob],
          contains('who'),
        );

        await mesh.advance(const Duration(hours: 1));
        expect(
          (await mesh.nodes[relay]!.state()).mailbox[bob],
          contains('who'),
        );

        await mesh.advance(const Duration(hours: 12));
        expect((await mesh.nodes[relay]!.state()).mailbox[bob], isNull);
      },
    );
  });
}

Map<String, dynamic> _fakeEnvelope({
  required String id,
  required String sender,
  required String recipient,
  required int now,
}) => <String, dynamic>{
  'id': id,
  's': sender,
  'r': recipient,
  'c': now,
  'x': now + 100000000,
  'e': base64Url.encode(List<int>.filled(32, 1)),
  'n': base64Url.encode(List<int>.filled(12, 1)),
  'b': base64Url.encode(List<int>.filled(40, 1)),
};
