import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Full stack per device: social controller -> reliable transport -> relay
/// engine -> simulated mesh. Proves the app-level promise: what you send to an
/// offline friend shows up on their side once they are back, even if you are
/// gone by then.

String _addr(String raw) => PeerShareCodec.normalizeAddress(raw);
final String alice = _addr('200::a1');
final String bob = _addr('200::b2');
final String carol = _addr('200::c3');
final String dave = _addr('200::d4');

final class _Mesh {
  int now = 5000000;
  final Map<String, _Device> devices = <String, _Device>{};
  final Queue<({String from, String to, Map<String, dynamic> payload})> queue =
      Queue<({String from, String to, Map<String, dynamic> payload})>();

  bool isOnline(String address) => devices[address]?.online ?? false;

  void carry(String from, String to, Map<String, dynamic> payload) {
    if (!isOnline(from)) {
      throw StateError('$from is offline');
    }
    if (!isOnline(to)) {
      return; // lost, like a datagram to a sleeping phone
    }
    queue.add((
      from: from,
      to: to,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
    ));
  }

  /// Runs the network and every device's async work until nothing moves.
  Future<void> settle() async {
    int quietRounds = 0;
    for (int round = 0; round < 400 && quietRounds < 6; round++) {
      if (queue.isEmpty) {
        quietRounds++;
      } else {
        quietRounds = 0;
        while (queue.isNotEmpty) {
          final ({String from, String to, Map<String, dynamic> payload}) d =
              queue.removeFirst();
          devices[d.to]?.raw.inject(d.from, d.payload, now);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> advance(Duration duration) async {
    now += duration.inMilliseconds;
    for (final _Device device in devices.values) {
      if (device.online) {
        await device.engine.tick();
      }
    }
    await settle();
  }
}

final class _RawSimTransport implements SignalTransport {
  _RawSimTransport(this.mesh, this.address);

  final _Mesh mesh;
  final String address;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast(sync: true);

  void inject(String from, Map<String, dynamic> payload, int at) {
    _frames.add(
      SignalTransportFrame(from: from, payload: payload, receivedAtMillis: at),
    );
  }

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    mesh.carry(address, _addr(remoteAddress), payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

final class _Device implements RelayPeerSource {
  _Device(this.mesh, this.address, List<String> friendAddresses) {
    raw = _RawSimTransport(mesh, address);
    engine = RelayEngine(
      store: relayStore,
      peers: this,
      send: (String to, Map<String, dynamic> payload) =>
          raw.send(remoteAddress: to, payload: payload),
      clock: () => mesh.now,
    );
    transport = ReliableSignalTransport(
      delegate: raw,
      engine: engine,
      // Ticks are driven by the test clock instead.
      tickInterval: const Duration(days: 1),
    );
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            friends: <String, FriendProfile>{
              for (final String friend in friendAddresses)
                friend: FriendProfile(
                  address: friend,
                  displayName: friend,
                  status: FriendRelationshipStatus.accepted,
                ),
            },
          ),
        ),
      ],
    );
    // What RuntimeSignalModule does in the app.
    _subscription = transport.frames.listen((SignalTransportFrame frame) {
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: frame.from,
        payload: frame.payload,
      );
      if (signal != null) {
        unawaited(
          controller.receiveSignal(
            signal,
            receivedAtMillis: frame.receivedAtMillis,
          ),
        );
      }
    });
    mesh.devices[address] = this;
  }

  final _Mesh mesh;
  final String address;
  final MemoryRelayStateStore relayStore = MemoryRelayStateStore();
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  late final _RawSimTransport raw;
  late final RelayEngine engine;
  late final ReliableSignalTransport transport;
  late final ProviderContainer container;
  late final StreamSubscription<SignalTransportFrame> _subscription;
  bool online = false;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  @override
  bool get isReady => true;

  @override
  List<RelayFriend> groupContacts() {
    final Set<String> seen = <String>{};
    return <RelayFriend>[
      for (final GroupProfile group in state.groups.values)
        for (final String member in group.memberAddresses)
          if (member != address &&
              state.friendByAddress(member) == null &&
              seen.add(member))
            RelayFriend(address: member),
    ];
  }

  @override
  String get localAddress => address;

  @override
  List<RelayFriend> acceptedFriends() => state.acceptedFriends
      .map((FriendProfile f) => RelayFriend(address: f.address))
      .toList();

  Future<void> goOnline() async {
    online = true;
    await transport.start();
    await mesh.settle();
  }

  Future<void> goOffline() async {
    online = false;
    await transport.stop();
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await transport.dispose();
    container.dispose();
  }
}

Future<_Mesh> _buildMesh() async {
  final _Mesh mesh = _Mesh();
  final List<String> everyone = <String>[alice, bob, carol, dave];
  for (final String address in everyone) {
    final _Device device = _Device(
      mesh,
      address,
      everyone.where((String a) => a != address).toList(),
    );
    addTearDown(device.dispose);
  }
  for (final _Device device in mesh.devices.values) {
    await device.goOnline();
  }
  // Relay sets are announced and confirmed.
  await mesh.advance(const Duration(seconds: 1));
  return mesh;
}

void main() {
  test('a message to an offline friend arrives via relays after the sender '
      'left, and the sender learns it was delivered', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;

    await b.goOffline();
    await a.controller.sendLocalMessage(peerAddress: bob, text: 'Hej Bob!');
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5)); // relays get a copy
    await a.goOffline();

    await b.goOnline();
    await mesh.settle();

    final List<ChatMessage> bobThread = await b.timelines.load(alice);
    expect(bobThread.map((ChatMessage m) => m.text), <String>['Hej Bob!']);

    // Alice returns; bob's delivery receipt (itself queued and relayed while
    // she was away) marks her message delivered.
    await a.goOnline();
    await mesh.advance(const Duration(seconds: 12));
    final List<ChatMessage> aliceThread = await a.timelines.load(bob);
    expect(
      aliceThread.single.deliveryState,
      ChatMessageDeliveryState.delivered,
    );
    // Nothing is left pending anywhere.
    expect((await a.relayStore.load()).outbox, isEmpty);
    expect((await b.relayStore.load()).outbox, isEmpty);
    for (final String relay in <String>[carol, dave]) {
      expect(
        (await mesh.devices[relay]!.relayStore.load()).mailbox[bob],
        isNull,
        reason: relay,
      );
    }
  });

  test('a group invite reaches a member who was offline when the group was '
      'created', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;

    await b.goOffline();
    final GroupProfile group = await a.controller.createGroup(
      name: 'Wypad w góry',
      description: '',
      memberAddresses: <String>[bob, carol],
    );
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5));
    await a.goOffline();

    await b.goOnline();
    await mesh.settle();

    expect(b.state.groups[group.id]?.name, 'Wypad w góry');
    expect(b.state.groups[group.id]!.isInvitePending, isTrue);
    expect(
      b.state.inbox.where(
        (InboxEntry e) => e.type == InboxEntryType.groupInvite,
      ),
      hasLength(1),
    );

    // Carol got it directly and confirmed; bob's confirmation reaches alice
    // once she is back.
    await a.goOnline();
    await mesh.advance(const Duration(seconds: 12));
    expect(a.state.groups[group.id]!.pendingInviteAddresses, isEmpty);
  });

  test('messages sent while everyone hops on and off arrive once each, in '
      'full', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;

    for (int i = 1; i <= 5; i++) {
      if (i.isOdd) {
        await b.goOffline();
      } else {
        await b.goOnline();
      }
      await a.controller.sendLocalMessage(
        peerAddress: bob,
        text: 'wiadomość $i',
        sentAtMillis: mesh.now + i,
      );
      await mesh.advance(const Duration(seconds: 5));
    }
    await b.goOnline();
    await mesh.advance(const Duration(minutes: 3));

    final List<String> texts = (await b.timelines.load(
      alice,
    )).map((ChatMessage m) => m.text).toList();
    expect(texts.toSet(), <String>{
      for (int i = 1; i <= 5; i++) 'wiadomość $i',
    });
    expect(texts, hasLength(5), reason: 'no duplicates');
  });

  test('a group message between members who are not friends waits in the '
      'offline member\'s mailboxes', () async {
    final _Mesh mesh = _Mesh();
    // Carol knows everyone; alice and bob only know carol and dave.
    final Map<String, List<String>> friendsOf = <String, List<String>>{
      alice: <String>[carol, dave],
      bob: <String>[carol, dave],
      carol: <String>[alice, bob, dave],
      dave: <String>[alice, bob, carol],
    };
    for (final MapEntry<String, List<String>> entry in friendsOf.entries) {
      final _Device device = _Device(mesh, entry.key, entry.value);
      addTearDown(device.dispose);
    }
    for (final _Device device in mesh.devices.values) {
      await device.goOnline();
    }
    await mesh.advance(const Duration(seconds: 1));
    // Showing the mailboxes to group members who are not friends is opt-in
    // (off by default): both group mates have switched it on.
    await mesh.devices[alice]!.engine.setShareWithGroups(true);
    await mesh.devices[bob]!.engine.setShareWithGroups(true);

    final GroupProfile group = await mesh.devices[carol]!.controller
        .createGroup(
          name: 'Ekipa',
          description: '',
          memberAddresses: <String>[alice, bob],
        );
    await mesh.settle();
    // Group mates exchange keys and mailboxes.
    await mesh.advance(const Duration(seconds: 5));

    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    // Both join first: a pending invite does not let anyone write.
    await a.controller.acceptGroupInvite(groupId: group.id, groupName: 'Ekipa');
    await b.controller.acceptGroupInvite(groupId: group.id, groupName: 'Ekipa');
    await mesh.settle();
    await b.goOffline();
    await a.controller.sendGroupMessage(groupId: group.id, text: 'Kto jedzie?');
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5));
    await a.goOffline();

    await b.goOnline();
    await mesh.settle();

    final List<ChatMessage> thread = await b.timelines.load(
      'group:${group.id}',
    );
    expect(thread.map((ChatMessage m) => m.text), contains('Kto jedzie?'));
    expect(
      thread.where((ChatMessage m) => m.text == 'Kto jedzie?'),
      hasLength(1),
    );
  });
}
