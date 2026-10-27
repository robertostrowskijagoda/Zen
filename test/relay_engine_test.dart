import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/features/relay/locked_mailbox_writer.dart';
import 'package:zen/src/features/relay/locked_outbox.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
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

  /// While set, the device is locked: what reaches it goes to this
  /// transport (the locked service's node) instead of the engine.
  _LockedNode? locked;

  /// The locked service's mailbox for friends (with [locked]): it takes the
  /// mailbox duties, as the locked receiver hands them over.
  LockedMailbox? lockedMailbox;

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    final _LockedNode? node = locked;
    final LockedMailbox? mailbox = lockedMailbox;
    if (node != null &&
        mailbox != null &&
        LockedMailbox.dutyTypes.contains(payload['type'])) {
      await mailbox.handle(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: mesh.now,
        ),
      );
      return;
    }
    if (node != null) {
      await node.injectIncoming(
        from: from,
        payload: payload,
        receivedAtMillis: mesh.now,
      );
      return;
    }
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

  test('mail is sealed with the hybrid post-quantum key of the recipient, '
      'and a changed KEM ciphertext is rejected', () async {
    final _SimMesh mesh = await _meshWithRelays();
    expect(
      (await mesh.nodes[alice]!.state()).peers[bob]?.pqPublicKey,
      hasLength(kHybridPublicKeyBytes),
      reason: 'the announcement carries the hybrid key',
    );
    await mesh.goOffline(bob);
    await mesh.nodes[alice]!.engine.submit(bob, _text('kwantowo'));
    await mesh.advance(const Duration(seconds: 5));
    int held = 0;
    for (final String relay in helpers) {
      final Map<String, Map<String, dynamic>>? mail =
          (await mesh.nodes[relay]!.state()).mailbox[bob];
      for (final Map<String, dynamic> envelope
          in mail?.values ?? const <Map<String, dynamic>>[]) {
        held += 1;
        expect(envelope.containsKey('e'), isFalse);
        expect(
          base64Url.decode(envelope['q'] as String),
          hasLength(kHybridCiphertextBytes),
        );
      }
    }
    expect(held, greaterThan(0));

    mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
      if (p['type'] == 'rly_mail') {
        for (final Object? item in p['items'] as List<dynamic>) {
          final Map<String, dynamic> env = item! as Map<String, dynamic>;
          final List<int> kem = base64Url.decode(env['q'] as String);
          kem[7] ^= 0x01;
          env['q'] = base64Url.encode(kem);
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
        'q': base64Url.encode(List<int>.filled(kHybridCiphertextBytes, 1)),
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
    /// everyone's friends and hold mail as usual. Sharing mailboxes with group
    /// members is opt-in, so it is switched on here for whoever [aliceShares] /
    /// [bobShares] say; [onSend] sees every datagram from the very start.
    Future<_SimMesh> groupMesh({
      bool aliceShares = true,
      bool bobShares = true,
      void Function(String from, String to, Map<String, dynamic> payload)?
      onSend,
    }) async {
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
      if (aliceShares) {
        await mesh.nodes[alice]!.engine.setShareWithGroups(true);
      }
      if (bobShares) {
        await mesh.nodes[bob]!.engine.setShareWithGroups(true);
      }
      if (onSend != null) {
        mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
          onSend(from, to, p);
          return p;
        };
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

    test('by default the mailboxes are announced to friends only, never to '
        'group members who are not friends', () async {
      final List<String> toGroupMate = <String>[];
      final _SimMesh mesh = await groupMesh(
        aliceShares: false,
        bobShares: false,
        onSend: (String from, String to, Map<String, dynamic> p) {
          if (p['type'] == 'rly_announce' &&
              <String>{from, to}.containsAll(<String>[alice, bob])) {
            toGroupMate.add('$from>$to');
          }
        },
      );
      // Long enough for every retry of an unconfirmed announcement.
      await mesh.advance(const Duration(minutes: 5));
      await mesh.advance(const Duration(minutes: 5));

      expect(toGroupMate, isEmpty);
      for (final String who in <String>[alice, bob]) {
        final RelayState state = await mesh.nodes[who]!.state();
        expect(state.shareWithGroups, isFalse, reason: who);
        expect(
          mesh.nodes[who]!.engine.overview.value.shareWithGroups,
          isFalse,
          reason: who,
        );
        expect(
          state.peers.keys,
          everyElement(isIn(helpers)),
          reason: '$who learned mailboxes of group mates',
        );
      }
      // Friends are told as ever.
      for (final String helper in helpers) {
        expect(
          (await mesh.nodes[helper]!.state()).peers[bob]?.relays,
          (await mesh.nodes[bob]!.state()).currentRelays,
          reason: helper,
        );
      }
      expect((await mesh.nodes[bob]!.state()).currentRelays, hasLength(6));
    });

    test('opting in later shares the mailboxes with group members, and '
        'opting out stops it again', () async {
      final _SimMesh mesh = await groupMesh(
        aliceShares: false,
        bobShares: false,
      );
      expect((await mesh.nodes[alice]!.state()).peers[bob], isNull);

      await mesh.nodes[alice]!.engine.setShareWithGroups(true);
      await mesh.nodes[bob]!.engine.setShareWithGroups(true);
      await mesh.advance(const Duration(seconds: 6));
      final List<String> shared =
          (await mesh.nodes[bob]!.state()).currentRelays;
      expect((await mesh.nodes[alice]!.state()).peers[bob]?.relays, shared);
      expect(
        (await mesh.nodes[bob]!.state()).announcedVersions,
        contains(alice),
      );

      // Off again: a new relay set no longer reaches the group mate, and its
      // confirmation is forgotten.
      await mesh.nodes[bob]!.engine.setShareWithGroups(false);
      await mesh.nodes[bob]!.engine.setManualRelays(<String>[helpers[0]]);
      await mesh.advance(const Duration(minutes: 5));
      expect((await mesh.nodes[alice]!.state()).peers[bob]?.relays, shared);
      expect(
        (await mesh.nodes[bob]!.state()).announcedVersions,
        isNot(contains(alice)),
      );
      // Friends did learn it.
      expect(
        (await mesh.nodes[helpers[1]]!.state()).peers[bob]?.relays,
        <String>[helpers[0]],
      );
    });
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

  group('delivery news for the chat', () {
    /// A chat message too big for the mailboxes (the limit is 48 KB).
    Map<String, dynamic> bigMessage(String id) => <String, dynamic>{
      'type': 'message',
      'msgId': id,
      'text': 'x' * (49 * 1024),
    };

    test('a message nobody acknowledged is reported expired, once, after the '
        'retention window', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await mesh.goOffline(bob);
      await engine.submit(bob, _text('znika'));
      await mesh.advance(const Duration(seconds: 5)); // mailboxes got a copy
      await mesh.advance(const Duration(days: 13));
      expect(engine.deliveryReportCount.value, 0);
      expect(await engine.takeDeliveryReports(), isEmpty);

      await mesh.advance(const Duration(days: 2));
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
      expect(engine.deliveryReportCount.value, 1);
      final List<RelayDeliveryReport> reports = await engine
          .takeDeliveryReports();
      expect(reports, hasLength(1));
      expect(reports.single.status, RelayDeliveryStatus.expired);
      expect(reports.single.messageId, 'm-znika');
      expect(reports.single.recipient, bob);
      expect(engine.deliveryReportCount.value, 0);
      expect(await engine.takeDeliveryReports(), isEmpty);
    });

    test('an expiry survives a restart until the chat takes it, and is not '
        'handed out by an engine that does not own the node', () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, _text('po restarcie'));
      await mesh.advance(const Duration(days: 15));
      expect(
        (await mesh.nodes[alice]!.state()).deliveryReports.single.messageId,
        'm-po restarcie',
      );

      mesh.nodes[alice]!.restart();
      final RelayEngine restarted = mesh.nodes[alice]!.engine;
      expect(await restarted.takeDeliveryReports(), isEmpty);
      expect(
        (await mesh.nodes[alice]!.state()).deliveryReports,
        hasLength(1),
        reason: 'not taken by an engine that is not the writer',
      );

      await restarted.activate();
      expect(restarted.deliveryReportCount.value, 1);
      final List<RelayDeliveryReport> reports = await restarted
          .takeDeliveryReports();
      expect(reports.single.status, RelayDeliveryStatus.expired);
      expect(reports.single.messageId, 'm-po restarcie');
      expect((await mesh.nodes[alice]!.state()).deliveryReports, isEmpty);
    });

    test('delivered messages and other payload types leave no report', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await engine.submit(bob, _text('doszła'));
      await mesh.settle();
      expect(mesh.nodes[bob]!.receivedTexts, <String>['doszła']);

      // `msgId` of a receipt names the *other* side's message: never reported.
      await mesh.goOffline(bob);
      await engine.submit(bob, <String, dynamic>{
        'type': 'message_ack',
        'msgId': 'm-cudza',
      });
      await mesh.advance(const Duration(days: 15));
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
      expect(await engine.takeDeliveryReports(), isEmpty);
    });

    test('a message too large for one envelope, to someone without '
        'mailboxes, is reported as direct-only once they would have had a '
        'copy, not as failed', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await mesh.nodes[bob]!.engine.setManualRelays(<String>[]);
      await mesh.settle();
      await mesh.goOffline(bob);
      await engine.submit(bob, bigMessage('big-1'));
      await mesh.advance(const Duration(seconds: 1));
      expect(await engine.takeDeliveryReports(), isEmpty);

      await mesh.advance(const Duration(seconds: 5));
      final List<RelayDeliveryReport> reports = await engine
          .takeDeliveryReports();
      expect(reports, hasLength(1));
      expect(reports.single.status, RelayDeliveryStatus.directOnly);
      expect(reports.single.messageId, 'big-1');
      expect(reports.single.recipient, bob);
      for (final String helper in helpers) {
        expect(
          (await mesh.nodes[helper]!.state()).mailbox[bob],
          isNull,
          reason: '$helper must not hold what is too large',
        );
      }
      expect((await mesh.nodes[alice]!.state()).outbox, hasLength(1));

      // Said once, not on every tick.
      await mesh.advance(const Duration(minutes: 1));
      expect(await engine.takeDeliveryReports(), isEmpty);

      // It is still retried and arrives when both are online.
      await mesh.goOnline(bob);
      await mesh.advance(const Duration(minutes: 3));
      expect(mesh.nodes[bob]!.receivedTexts, hasLength(1));
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
      expect(await engine.takeDeliveryReports(), isEmpty);
    });

    test('a large message that is acknowledged first is not reported, and a '
        'pending report is withdrawn when it arrives', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await engine.submit(bob, bigMessage('big-2'));
      await mesh.settle(); // bob is online: received and acknowledged
      await mesh.advance(const Duration(seconds: 10));
      expect(mesh.nodes[bob]!.receivedTexts, hasLength(1));
      expect(await engine.takeDeliveryReports(), isEmpty);

      // Without mailboxes it can only go directly.
      await mesh.nodes[bob]!.engine.setManualRelays(<String>[]);
      await mesh.settle();
      await mesh.goOffline(bob);
      await engine.submit(bob, bigMessage('big-3'));
      await mesh.advance(const Duration(seconds: 6));
      expect(engine.deliveryReportCount.value, 1);

      await mesh.goOnline(bob);
      await mesh.advance(const Duration(minutes: 3));
      expect(mesh.nodes[bob]!.receivedTexts, hasLength(2));
      expect(engine.deliveryReportCount.value, 0);
      expect(await engine.takeDeliveryReports(), isEmpty);
    });

    test('a message too large for one envelope waits in the mailboxes in '
        'parts and arrives whole, once', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await mesh.goOffline(bob);
      await engine.submit(bob, bigMessage('big-parts'));
      await mesh.advance(const Duration(seconds: 5)); // cut into parts
      await mesh.advance(const Duration(seconds: 5)); // parts deposited
      expect(await engine.takeDeliveryReports(), isEmpty);

      final RelayState aliceState = await mesh.nodes[alice]!.state();
      final RelayOutboxEntry parent = aliceState.outbox.values.singleWhere(
        (RelayOutboxEntry e) => e.payload['type'] == 'message',
      );
      expect(parent.partRids, hasLength(2));
      int holding = 0;
      for (final String helper in helpers) {
        final int held =
            (await mesh.nodes[helper]!.state()).mailbox[bob]?.length ?? 0;
        expect(held, anyOf(0, 2), reason: helper);
        if (held == 2) {
          holding++;
        }
      }
      expect(holding, const RelayConfig().maxBlobCopies);
      final MessageDeliveryProgress? progress =
          engine.progress.value.messages['big-parts'];
      expect(progress?.inMailboxes, 1);
      expect(progress?.mailboxCopies, const RelayConfig().maxBlobCopies);

      // Only the mailboxes can deliver it now.
      await mesh.goOffline(alice);
      await mesh.goOnline(bob);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['x' * (49 * 1024)]);

      // Alice's own retry finds it delivered: everything is dropped, and
      // bob does not take it twice.
      await mesh.goOnline(alice);
      await mesh.advance(const Duration(minutes: 3));
      expect(mesh.nodes[bob]!.receivedTexts, hasLength(1));
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
      expect((await mesh.nodes[bob]!.state()).inParts, isEmpty);
    });

    test('the chat is told about the newest expiries when there are too '
        'many', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      // Nobody known to the relay layer: queued, never handed to a mailbox.
      final String stranger = _addr('200::dead');
      for (int i = 0; i < 205; i++) {
        await engine.submit(stranger, <String, dynamic>{
          'type': 'message',
          'msgId': 'c-$i',
          'text': '$i',
        });
      }
      await mesh.advance(const Duration(days: 15));
      final List<RelayDeliveryReport> reports = await engine
          .takeDeliveryReports();
      expect(reports, hasLength(200));
      expect(
        reports.map((RelayDeliveryReport r) => r.messageId).toSet(),
        containsAll(<String>['c-204', 'c-5']),
      );
      expect(
        reports.map((RelayDeliveryReport r) => r.messageId),
        isNot(contains('c-4')),
      );
      expect(
        reports.every(
          (RelayDeliveryReport r) => r.status == RelayDeliveryStatus.expired,
        ),
        isTrue,
      );
    });
  });

  test('a payload with its own retry life is dropped after it, and the life '
      'is not sent along (knocks at mailbox doors)', () async {
    final _SimMesh mesh = await _meshWithRelays();
    await mesh.goOffline(bob);
    await mesh.nodes[alice]!.engine.submit(bob, <String, dynamic>{
      'type': 'flat_held',
      'c': 'x',
      kReliableTtlKey: const Duration(hours: 2).inMilliseconds,
    });
    await mesh.settle();
    RelayState state = await mesh.nodes[alice]!.state();
    expect(state.outbox, hasLength(1));
    final RelayOutboxEntry entry = state.outbox.values.single;
    expect(entry.payload.containsKey(kReliableTtlKey), isFalse);
    expect(
      entry.expiresAtMillis - entry.createdAtMillis,
      const Duration(hours: 2).inMilliseconds,
    );
    expect(entry.relayable, isFalse, reason: 'direct only');
    await mesh.advance(const Duration(hours: 3));
    state = await mesh.nodes[alice]!.state();
    expect(state.outbox, isEmpty);
  });

  group('while the sender is locked', () {
    test('the queue goes out from the outbox kit: sealed, into the '
        'mailboxes, and ends with the recipient\'s confirmation', () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.goOffline(bob);
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await engine.submit(bob, _text('z zablokowanego'));
      await mesh.settle(); // not in the mailboxes yet

      final LockedOutboxKit kit = await engine.lockedOutboxKit();
      expect(kit.items, hasLength(1));
      final LockedOutboxItem item = kit.items.single;
      expect(item.recipient, bob);
      expect(
        item.mailboxes.toSet(),
        (await mesh.nodes[bob]!.state()).currentRelays.toSet(),
      );
      // Only ciphertext and where it goes: nothing the service could read.
      final String stored = jsonEncode(kit.toJson());
      expect(stored, isNot(contains('z zablokowanego')));
      final LockedOutboxKit? read = LockedOutboxKit.fromJson(
        jsonDecode(stored),
      );
      expect(read?.signature, kit.signature);

      final _LockedNode node = await _lock(mesh, alice);
      final LockedOutbox outbox = LockedOutbox(
        transport: node,
        kit: read!,
        now: () => mesh.now,
      );
      await outbox.start();
      addTearDown(outbox.stop);
      await outbox.runRound();
      await mesh.settle();
      for (final String relay in item.mailboxes) {
        expect(
          (await mesh.nodes[relay]!.state()).mailbox[bob],
          hasLength(1),
          reason: relay,
        );
      }

      await mesh.goOnline(bob);
      await Future<void>.delayed(Duration.zero);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['z zablokowanego']);
      expect(outbox.pendingCount, 0, reason: 'bob confirmed it');
    });

    test('a recipient who is online gets the queue straight from the locked '
        'service, once', () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.goOffline(bob);
      final RelayEngine engine = mesh.nodes[alice]!.engine;
      await engine.submit(bob, _text('pierwsza'));
      await engine.submit(bob, _text('druga'));
      await mesh.settle();
      final LockedOutboxKit kit = await engine.lockedOutboxKit();
      final _LockedNode node = await _lock(mesh, alice);
      final LockedOutbox outbox = LockedOutbox(
        transport: node,
        kit: kit,
        now: () => mesh.now,
      );
      await outbox.start();
      addTearDown(outbox.stop);

      await mesh.goOnline(bob);
      await outbox.runRound();
      await mesh.settle();
      await outbox.runRound(); // a repeat is taken once
      await mesh.settle();
      await Future<void>.delayed(Duration.zero);
      expect(mesh.nodes[bob]!.receivedTexts.toSet(), <String>{
        'pierwsza',
        'druga',
      });
      expect(mesh.nodes[bob]!.receivedTexts, hasLength(2));
      expect(outbox.pendingCount, 0);
    });
  });

  group('phones as mailboxes while locked', () {
    test('locked phones hold mail for an offline friend and hand it over '
        'once the friend is back, with the sender gone', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final List<String> bobRelays =
          (await mesh.nodes[bob]!.state()).currentRelays;
      // Every one of bob's six mailboxes is a phone locked (or long in the
      // background): only its background service runs.
      final Map<String, LockedMailboxKit> held = <String, LockedMailboxKit>{};
      final Map<String, LockedMailbox> boxes = <String, LockedMailbox>{
        for (final String relay in bobRelays)
          relay: await _lockAsMailbox(mesh, relay, held: held),
      };
      await mesh.goOffline(bob);

      await mesh.nodes[alice]!.engine.submit(bob, _text('czekam na Ciebie'));
      await mesh.settle();
      await mesh.advance(const Duration(seconds: 5)); // past depositAfter

      for (final String relay in bobRelays) {
        expect(boxes[relay]!.heldFor(bob), hasLength(1), reason: relay);
        expect(held[relay]?.held[bob], hasLength(1), reason: 'saved $relay');
      }
      final RelayOutboxEntry pending =
          (await mesh.nodes[alice]!.state()).outbox.values.single;
      expect(pending.depositedTo.toSet(), bobRelays.toSet());

      // The sender goes away too: only the locked phones can deliver now.
      await mesh.goOffline(alice);
      await mesh.goOnline(bob);

      expect(mesh.nodes[bob]!.receivedTexts, <String>['czekam na Ciebie']);
      for (final String relay in bobRelays) {
        expect(boxes[relay]!.heldFor(bob), isEmpty, reason: 'purged $relay');
      }

      // A mailbox phone is unlocked: what its service did is the app's now,
      // so the delivered copy does not come back.
      final String first = bobRelays.first;
      await _unlock(mesh, first, held: held[first]);
      final RelayState state = await mesh.nodes[first]!.state();
      expect(state.mailbox[bob], isNull);
      expect(
        state.tombstones.keys.where((String k) => k.startsWith('$bob|')),
        hasLength(1),
      );
      await mesh.advance(const Duration(minutes: 11));
      expect(mesh.nodes[bob]!.receivedTexts, <String>['czekam na Ciebie']);
    });

    test('mail held before the lock is handed out by the locked service; '
        'mail it took in stays with the app after the unlock', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final List<String> bobRelays =
          (await mesh.nodes[bob]!.state()).currentRelays;
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, _text('pierwsza'));
      await mesh.advance(const Duration(seconds: 5));
      for (final String relay in bobRelays) {
        expect((await mesh.nodes[relay]!.state()).mailbox[bob], hasLength(1));
      }

      final Map<String, LockedMailboxKit> held = <String, LockedMailboxKit>{};
      final Map<String, LockedMailbox> boxes = <String, LockedMailbox>{
        for (final String relay in bobRelays)
          relay: await _lockAsMailbox(mesh, relay, held: held),
      };
      for (final String relay in bobRelays) {
        expect(boxes[relay]!.heldFor(bob), hasLength(1), reason: relay);
      }
      await mesh.nodes[alice]!.engine.submit(bob, _text('druga'));
      await mesh.advance(const Duration(seconds: 5));
      await mesh.goOffline(alice);

      // One mailbox phone is unlocked before bob is back: it holds both.
      final String first = bobRelays.first;
      await _unlock(mesh, first, held: held[first]);
      expect((await mesh.nodes[first]!.state()).mailbox[bob], hasLength(2));
      // Taking the same held kit again changes nothing.
      await mesh.nodes[first]!.engine.takeLockedMailbox(held[first]);
      expect((await mesh.nodes[first]!.state()).mailbox[bob], hasLength(2));

      await mesh.goOnline(bob);
      expect(mesh.nodes[bob]!.receivedTexts.toSet(), <String>{
        'pierwsza',
        'druga',
      });
      expect(mesh.nodes[bob]!.receivedTexts, hasLength(2));
      expect((await mesh.nodes[first]!.state()).mailbox[bob], isNull);
      for (final String relay in bobRelays.skip(1)) {
        expect(boxes[relay]!.heldFor(bob), isEmpty, reason: relay);
      }
    });

    test(
      'the kit says whom the phone serves, with their deposit keys, and '
      'what the phone took already; it is written only when it changed',
      () async {
        final _SimMesh mesh = await _meshWithRelays();
        final String relay =
            (await mesh.nodes[bob]!.state()).currentRelays.first;
        await mesh.nodes[alice]!.engine.submit(relay, _text('do skrzynki'));
        await mesh.settle();
        expect(mesh.nodes[relay]!.receivedTexts, <String>['do skrzynki']);

        final List<Object?> written = <Object?>[];
        final LockedMailboxKitWriter writer = LockedMailboxKitWriter(
          engine: mesh.nodes[relay]!.engine,
          write: (Object? json) async => written.add(json),
          readHeld: () async => null,
        );
        await writer.flush();
        await writer.flush();
        expect(written, hasLength(1), reason: 'unchanged: not written again');

        final LockedMailboxKit kit = LockedMailboxKit.fromJson(
          jsonDecode(jsonEncode(written.single)),
        )!;
        expect(kit.self, relay);
        expect(kit.served[bob]?.relays, contains(relay));
        expect(kit.served[bob]?.depositKey, isNotNull);
        final String took = (await mesh.nodes[relay]!.state()).seen.keys
            .firstWhere((String k) => k.startsWith('$alice|'));
        expect(
          kit.taken,
          contains(
            LockedMailboxKit.takenTag(alice, took.substring(alice.length + 1)),
          ),
        );
        // Nothing that would open anything.
        expect(jsonEncode(written.single), isNot(contains('do skrzynki')));
      },
    );

    test('a locked mailbox takes mail only from the sender itself or a '
        'fellow mailbox, and only for a friend that chose it', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final List<String> bobRelays =
          (await mesh.nodes[bob]!.state()).currentRelays;
      final String outsider = helpers.firstWhere(
        (String h) => !bobRelays.contains(h),
      );
      await mesh.goOffline(bob);
      await mesh.nodes[alice]!.engine.submit(bob, _text('tylko od Ady'));
      await mesh.settle();
      final Map<String, dynamic> envelope =
          (await mesh.nodes[alice]!.engine.lockedOutboxKit())
              .items
              .single
              .envelope;
      final String relay = bobRelays.first;
      final LockedMailbox box = await _lockAsMailbox(mesh, relay);

      // Handed in by someone who is neither the sender nor a mailbox of bob.
      await mesh.send(outsider, relay, <String, dynamic>{
        'type': 'rly_deposit',
        'env': envelope,
      });
      await mesh.settle();
      expect(box.heldFor(bob), isEmpty);

      // For someone who never chose this phone.
      final String nobody = _addr('200::dd');
      await mesh.send(alice, relay, <String, dynamic>{
        'type': 'rly_deposit',
        'env': <String, dynamic>{...envelope, 'r': nobody},
      });
      await mesh.settle();
      expect(box.heldFor(nobody), isEmpty);
      expect(box.heldCount, 0);

      // From the sender itself.
      await mesh.send(alice, relay, <String, dynamic>{
        'type': 'rly_deposit',
        'env': envelope,
      });
      await mesh.settle();
      expect(box.heldFor(bob), hasLength(1));
    });
  });

  group('queueing rules', () {
    test('with the recipient offline and no mailboxes, the message waits '
        'at the sender, survives a restart and arrives once', () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.nodes[bob]!.engine.setManualRelays(<String>[]);
      await mesh.settle();
      expect((await mesh.nodes[alice]!.state()).peers[bob]?.relays, isEmpty);
      await mesh.goOffline(bob);

      final RelayEngine sender = mesh.nodes[alice]!.engine;
      await sender.submit(bob, _text('tylko u mnie'));
      expect(sender.progress.value.messages['m-tylko u mnie']?.sending, 1);
      await mesh.advance(const Duration(seconds: 5));
      await mesh.advance(const Duration(minutes: 1));

      MessageDeliveryProgress? progress =
          sender.progress.value.messages['m-tylko u mnie'];
      expect(progress?.waitingHere, 1);
      expect(progress?.inMailboxes, 0);
      expect((await mesh.nodes[alice]!.state()).outbox, hasLength(1));
      for (final String helper in helpers) {
        expect(
          (await mesh.nodes[helper]!.state()).mailbox[bob],
          isNull,
          reason: helper,
        );
      }

      // The app restarts: the queue and the status come back from the disk.
      await mesh.goOffline(alice);
      mesh.nodes[alice]!.restart();
      await mesh.goOnline(alice);
      final RelayEngine restarted = mesh.nodes[alice]!.engine;
      expect((await mesh.nodes[alice]!.state()).outbox, hasLength(1));
      expect(restarted.progress.value.ready, isTrue);
      expect(
        restarted.progress.value.messages['m-tylko u mnie']?.waitingHere,
        1,
      );

      // Still retried, on a long backoff, while bob stays away.
      await mesh.advance(const Duration(hours: 3));
      expect((await mesh.nodes[alice]!.state()).outbox, hasLength(1));

      await mesh.goOnline(bob);
      await mesh.advance(const Duration(minutes: 5));
      expect(mesh.nodes[bob]!.receivedTexts, <String>['tylko u mnie']);
      expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
      progress = restarted.progress.value.messages['m-tylko u mnie'];
      expect(progress?.delivered, 1);
      expect(progress?.pending, 0);

      // Later sightings do not bring it again.
      await mesh.advance(const Duration(hours: 1));
      expect(mesh.nodes[bob]!.receivedTexts, <String>['tylko u mnie']);
    });

    test('a sender that is one of the recipient\'s trusted friends keeps a '
        'copy in its own mailbox for it as well', () async {
      final _SimMesh mesh = await _meshWithRelays();
      await mesh.nodes[bob]!.engine.setManualRelays(<String>[
        alice,
        helpers[0],
      ]);
      await mesh.settle();
      expect((await mesh.nodes[alice]!.state()).peers[bob]?.relays, <String>[
        alice,
        helpers[0],
      ]);
      await mesh.goOffline(bob);

      final RelayEngine sender = mesh.nodes[alice]!.engine;
      await sender.submit(bob, _text('u mnie też'));
      await mesh.advance(const Duration(seconds: 5));

      final RelayState aliceState = await mesh.nodes[alice]!.state();
      final String rid = aliceState.outbox.keys.single;
      expect(aliceState.mailbox[bob]?.keys, <String>[rid]);
      expect(
        (await mesh.nodes[helpers[0]]!.state()).mailbox[bob]?.keys,
        <String>[rid],
      );
      final MessageDeliveryProgress? progress =
          sender.progress.value.messages['m-u mnie też'];
      expect(progress?.inMailboxes, 1);
      expect(progress?.mailboxCopies, 2);
      expect(progress?.heldBySelf, isTrue);

      // The other mailbox is away: bob collects the sender's own copy.
      await mesh.goOffline(helpers[0]);
      await mesh.goOnline(bob);
      expect(mesh.nodes[bob]!.receivedTexts, <String>['u mnie też']);
      final RelayState after = await mesh.nodes[alice]!.state();
      expect(after.outbox, isEmpty);
      expect(after.mailbox[bob], isNull, reason: 'dropped once delivered');
      expect(sender.progress.value.messages['m-u mnie też']?.delivered, 1);
    });

    test('the chat sees a message go from sending to waiting here, to the '
        'mailboxes, to delivered', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final List<String> bobRelays =
          (await mesh.nodes[bob]!.state()).currentRelays;
      await mesh.goOffline(bob);
      for (final String relay in bobRelays) {
        await mesh.goOffline(relay);
      }
      final RelayEngine sender = mesh.nodes[alice]!.engine;
      MessageDeliveryProgress? current() =>
          sender.progress.value.messages['m-po kolei'];

      await sender.submit(bob, _text('po kolei'));
      expect(current()?.sending, 1);
      await mesh.advance(const Duration(seconds: 5));
      await mesh.advance(const Duration(seconds: 10));
      expect(current()?.waitingHere, 1);

      await mesh.goOnline(bobRelays.first);
      await mesh.advance(const Duration(minutes: 3));
      expect(current()?.inMailboxes, 1);
      expect(current()?.mailboxCopies, 1);

      await mesh.goOnline(bob);
      await mesh.settle();
      expect(mesh.nodes[bob]!.receivedTexts, <String>['po kolei']);
      expect(current()?.delivered, 1);
      expect(current()?.pending, 0);
    });

    test('a group message adds up its members and is reported delivered '
        'once every member has it', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine sender = mesh.nodes[alice]!.engine;
      Map<String, dynamic> groupText() => <String, dynamic>{
        'type': 'group_message',
        'groupId': 'g',
        'msgId': 'gm-1',
        'text': 'Kto jedzie?',
      };
      await mesh.goOffline(bob);
      await sender.submit(bob, groupText());
      await sender.submit(helpers[6], groupText());
      await mesh.settle();
      MessageDeliveryProgress? progress =
          sender.progress.value.messages['gm-1'];
      expect(progress?.recipients, 2);
      expect(progress?.delivered, 1);

      await mesh.advance(const Duration(seconds: 5));
      progress = sender.progress.value.messages['gm-1'];
      expect(progress?.inMailboxes, 1);
      expect(await sender.takeDeliveryReports(), isEmpty);

      await mesh.goOnline(bob);
      await mesh.settle();
      progress = sender.progress.value.messages['gm-1'];
      expect(progress?.delivered, 2);
      expect(progress?.pending, 0);
      final List<RelayDeliveryReport> reports = await sender
          .takeDeliveryReports();
      expect(reports, hasLength(1));
      expect(reports.single.status, RelayDeliveryStatus.delivered);
      expect(reports.single.groupId, 'g');
      expect(reports.single.messageId, 'gm-1');
      expect(await sender.deliveredRecipientsOf('gm-1'), <String>{
        bob,
        helpers[6],
      });
    });

    test('a group message a member never confirmed is reported failed '
        'after the retention window', () async {
      final _SimMesh mesh = await _meshWithRelays();
      final RelayEngine sender = mesh.nodes[alice]!.engine;
      await mesh.goOffline(bob);
      await sender.submit(bob, <String, dynamic>{
        'type': 'group_message',
        'groupId': 'g',
        'msgId': 'gm-2',
        'text': 'Halo?',
      });
      await mesh.advance(const Duration(days: 15));
      final List<RelayDeliveryReport> reports = await sender
          .takeDeliveryReports();
      expect(reports.single.status, RelayDeliveryStatus.expired);
      expect(reports.single.groupId, 'g');
      expect(sender.progress.value.messages['gm-2']?.failed, 1);
    });

    test(
      'a payload goes out only once the queue holding it is stored',
      () async {
        final _FlakyStore store = _FlakyStore();
        final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
        final RelayEngine engine = RelayEngine(
          store: store,
          peers: _LonePeers(),
          send: (String to, Map<String, dynamic> payload) async {
            sent.add(payload);
          },
          clock: () => 1000000,
        );
        await engine.activate();
        List<Object?> texts() => sent
            .where((Map<String, dynamic> p) => p['type'] == 'message')
            .map((Map<String, dynamic> p) => p['text'])
            .toList();

        store.failSaves = true;
        await expectLater(
          engine.submit(bob, _text('pierwsza')),
          throwsStateError,
        );
        expect(texts(), isEmpty, reason: 'not on the disk, not sent');

        store.failSaves = false;
        await engine.submit(bob, _text('druga'));
        expect(texts(), <String>['pierwsza', 'druga']);
        expect((await store.load()).outbox, hasLength(2));
      },
    );

    test('housekeeping slows down while everything just waits', () async {
      int now = 1000000;
      final RelayEngine engine = RelayEngine(
        store: MemoryRelayStateStore(),
        peers: _LonePeers(),
        send: (String to, Map<String, dynamic> payload) async {},
        clock: () => now,
      );
      await engine.activate();
      await engine.tick();
      expect(engine.wantsFrequentTicks, isFalse);

      await engine.submit(bob, _text('czekam'));
      await engine.tick();
      expect(engine.wantsFrequentTicks, isTrue);

      for (int i = 0; i < 6; i++) {
        now += const Duration(hours: 1).inMilliseconds;
        await engine.tick();
      }
      expect(engine.wantsFrequentTicks, isFalse);
    });
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
  'q': base64Url.encode(List<int>.filled(kHybridCiphertextBytes, 1)),
  'n': base64Url.encode(List<int>.filled(12, 1)),
  'b': base64Url.encode(List<int>.filled(40, 1)),
};

/// A store whose writes can be made to fail (a full disk).
final class _FlakyStore implements RelayStateStore {
  final MemoryRelayStateStore _inner = MemoryRelayStateStore();
  bool failSaves = false;

  @override
  Future<RelayState> load() => _inner.load();

  @override
  Future<void> save(RelayState state) async {
    if (failSaves) {
      throw StateError('disk full');
    }
    await _inner.save(state);
  }
}

/// Alice with bob as her only friend.
final class _LonePeers implements RelayPeerSource {
  @override
  bool get isReady => true;

  @override
  String get localAddress => alice;

  @override
  List<RelayFriend> acceptedFriends() => <RelayFriend>[
    RelayFriend(address: bob),
  ];

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];
}

/// The locked Android service's node in the simulated mesh: it sends as the
/// device and receives what reaches the device.
final class _LockedNode extends MemorySignalTransport {
  _LockedNode(this.mesh, this.address);

  final _SimMesh mesh;
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) => mesh.send(address, remoteAddress, payload);
}

/// Locks the phone [address] with its mailbox kit, as the app hands it to
/// the locked service: the service's node takes its frames and its mailbox
/// for friends goes on. [held] gets what the service writes back.
Future<LockedMailbox> _lockAsMailbox(
  _SimMesh mesh,
  String address, {
  Map<String, LockedMailboxKit>? held,
}) async {
  final _SimNode node = mesh.nodes[address]!;
  final LockedMailboxKit kit = LockedMailboxKit.fromJson(
    jsonDecode(jsonEncode((await node.engine.lockedMailboxKit()).toJson())),
  )!;
  final _LockedNode transport = await _lock(mesh, address);
  final LockedMailbox mailbox = LockedMailbox(
    transport: transport,
    kit: kit,
    isFriend: node.friends.contains,
    isContact: node.friends.contains,
    save: (LockedMailboxKit saved) async {
      // Through JSON, as the service's file does it.
      held?[address] = LockedMailboxKit.fromJson(
        jsonDecode(jsonEncode(saved.toJson())),
      )!;
    },
    now: () => mesh.now,
  );
  node.lockedMailbox = mailbox;
  return mailbox;
}

/// Unlocks [address]: the app takes over what its locked service held and
/// owns the node again.
Future<void> _unlock(
  _SimMesh mesh,
  String address, {
  LockedMailboxKit? held,
}) async {
  final _SimNode node = mesh.nodes[address]!;
  node
    ..locked = null
    ..lockedMailbox = null;
  await node.engine.takeLockedMailbox(held);
  await node.engine.activate();
  await mesh.settle();
}

/// Locks [address]: its engine stops, the service's node takes its frames.
Future<_LockedNode> _lock(_SimMesh mesh, String address) async {
  final _SimNode node = mesh.nodes[address]!;
  node.engine.deactivate();
  final _LockedNode locked = _LockedNode(mesh, address);
  await locked.start();
  node.locked = locked;
  return locked;
}
