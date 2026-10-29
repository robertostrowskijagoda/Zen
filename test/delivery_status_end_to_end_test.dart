import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Full stack per device (social controller -> reliable transport -> relay
/// engine -> simulated mesh), with the relay engine visible to the chat:
/// what the bubbles' delivery status is made of.

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
        relayEngineProvider.overrideWithValue(engine),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                for (final String friend in friendAddresses)
                  friend: FriendProfile(
                    address: friend,
                    displayName: friend,
                    status: FriendRelationshipStatus.accepted,
                  ),
              },
            ),
          ),
        ),
      ],
    );
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
  List<RelayFriend> groupContacts() => const <RelayFriend>[];

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

  /// The bubble's status of [message] here, as the chat screen works it out.
  MessageDeliveryStatus? statusOf(ChatMessage message, {bool group = false}) {
    final RelayProgressSnapshot progress = engine.progress.value;
    return MessageDeliveryStatus.of(
      message,
      progress: progress.messages[message.id],
      queueKnown: progress.ready,
      isGroup: group,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
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
    // Starts taking the relay layer's delivery reports, as at app start.
    await device.controller.hydrateFromStore();
  }
  for (final _Device device in mesh.devices.values) {
    await device.goOnline();
  }
  await mesh.advance(const Duration(seconds: 1));
  return mesh;
}

Future<ChatMessage> _mine(_Device device, String thread, String text) async {
  return (await device.timelines.load(
    thread,
  )).singleWhere((ChatMessage m) => m.isOutgoing && m.text == text);
}

void main() {
  test('a group message is sent, waits in the offline member\'s mailboxes '
      'and is delivered once every member has it', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    final GroupProfile group = await a.controller.createGroup(
      name: 'Ekipa',
      description: '',
      memberAddresses: <String>[bob, carol],
    );
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5));
    final String thread = 'group:${group.id}';

    await b.goOffline();
    await a.controller.sendGroupMessage(groupId: group.id, text: 'Kto jedzie?');
    await mesh.settle();
    ChatMessage mine = await _mine(a, thread, 'Kto jedzie?');
    expect(mine.deliveryState, ChatMessageDeliveryState.sent);
    MessageDeliveryProgress? progress =
        a.engine.progress.value.messages[mine.id];
    expect(progress?.recipients, 2);
    expect(progress?.delivered, 1, reason: 'carol is online');

    await mesh.advance(const Duration(seconds: 5));
    final MessageDeliveryStatus held = a.statusOf(mine, group: true)!;
    expect(held.stage, MessageDeliveryStage.inMailboxes);
    expect(held.isPartial, isTrue);

    await b.goOnline();
    await mesh.settle();
    await mesh.settle();
    mine = await _mine(a, thread, 'Kto jedzie?');
    expect(mine.deliveryState, ChatMessageDeliveryState.delivered);
    expect(
      a.statusOf(mine, group: true)?.stage,
      MessageDeliveryStage.delivered,
    );
    progress = a.engine.progress.value.messages[mine.id];
    expect(progress?.delivered, 2);

    final List<ChatMessage> bobThread = await b.timelines.load(thread);
    expect(
      bobThread.where((ChatMessage m) => m.text == 'Kto jedzie?'),
      hasLength(1),
    );
  });

  test('sending a group message again reaches only who is missing it, and '
      'nobody keeps it twice', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    final _Device c = mesh.devices[carol]!;
    final GroupProfile group = await a.controller.createGroup(
      name: 'Ekipa',
      description: '',
      memberAddresses: <String>[bob, carol],
    );
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5));
    final String thread = 'group:${group.id}';

    await b.goOffline();
    await a.controller.sendGroupMessage(groupId: group.id, text: 'Jeszcze raz');
    await mesh.settle();
    final ChatMessage mine = await _mine(a, thread, 'Jeszcze raz');

    await a.controller.retryOutgoingMessage(
      conversationKey: thread,
      messageId: mine.id,
    );
    await mesh.settle();
    final RelayState queue = await a.relayStore.load();
    expect(
      queue.outbox.values
          .where((RelayOutboxEntry e) => e.payload['type'] == 'group_message')
          .map((RelayOutboxEntry e) => e.recipient)
          .toSet(),
      <String>{bob},
      reason: 'carol confirmed it already',
    );

    await b.goOnline();
    await mesh.advance(const Duration(minutes: 3));
    for (final _Device member in <_Device>[b, c]) {
      expect(
        (await member.timelines.load(
          thread,
        )).where((ChatMessage m) => m.text == 'Jeszcze raz'),
        hasLength(1),
        reason: member.address,
      );
    }
    expect(
      (await _mine(a, thread, 'Jeszcze raz')).deliveryState,
      ChatMessageDeliveryState.delivered,
    );
  });

  test('a message that never reached the queue shows as failed and goes '
      'out once when sent again', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    // As if the app was closed between showing the message and queueing it.
    final int written =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(minutes: 5).inMilliseconds;
    await a.timelines.append(
      bob,
      ChatMessage(
        id: 'outgoing-$written-$bob',
        sender: 'self',
        text: 'Zgubiona?',
        sentAtMillis: written,
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.sending,
      ),
    );
    ChatMessage mine = await _mine(a, bob, 'Zgubiona?');
    final MessageDeliveryStatus lost = a.statusOf(mine)!;
    expect(lost.stage, MessageDeliveryStage.failed);
    expect(lost.canRetry, isTrue);

    await a.controller.retryOutgoingMessage(
      conversationKey: bob,
      messageId: mine.id,
    );
    await mesh.settle();
    await mesh.settle();
    expect(
      (await b.timelines.load(
        alice,
      )).where((ChatMessage m) => m.text == 'Zgubiona?'),
      hasLength(1),
    );
    mine = await _mine(a, bob, 'Zgubiona?');
    expect(mine.deliveryState, ChatMessageDeliveryState.delivered);
    expect(a.statusOf(mine)?.stage, MessageDeliveryStage.delivered);
  });

  test('a chat message to a friend who is away shows where it waits', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    await b.goOffline();

    await a.controller.sendLocalMessage(
      peerAddress: bob,
      text: 'Gdzie jesteś?',
    );
    await mesh.settle();
    ChatMessage mine = await _mine(a, bob, 'Gdzie jesteś?');
    expect(mine.deliveryState, ChatMessageDeliveryState.sent);
    expect(a.statusOf(mine)?.stage, MessageDeliveryStage.sending);

    await mesh.advance(const Duration(seconds: 5));
    final MessageDeliveryStatus held = a.statusOf(mine)!;
    expect(held.stage, MessageDeliveryStage.inMailboxes);
    // Bob's mailboxes are his other friends; alice is one of them herself.
    expect(held.heldBySelf, isTrue);
    expect(held.mailboxCopies, 3);

    await b.goOnline();
    await mesh.settle();
    await mesh.settle();
    mine = await _mine(a, bob, 'Gdzie jesteś?');
    expect(mine.deliveryState, ChatMessageDeliveryState.delivered);
  });
}
