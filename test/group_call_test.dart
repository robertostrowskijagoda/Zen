import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Several devices, each with its own controller and a fake media stack,
/// wired through a simulated mesh. Proves the group call behaves like a room:
/// start without everyone answering, join late, leave and come back, lost
/// datagrams, people vanishing, two calls started at once.

String _addr(String raw) => PeerShareCodec.normalizeAddress(raw);
final String ada = _addr('200::a1');
final String bob = _addr('200::b2');
final String cyd = _addr('200::c3');
final String dan = _addr('200::d4');

const String groupId = 'group-call-test';

const LifecycleSnapshot _focused = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

typedef _Datagram = ({String from, String to, Map<String, dynamic> payload});

final class _Mesh {
  final Map<String, _Device> devices = <String, _Device>{};
  final Queue<_Datagram> queue = Queue<_Datagram>();

  /// Datagrams matching this are lost on the way.
  bool Function(_Datagram datagram)? drop;

  void carry(String from, String to, Map<String, dynamic> payload) {
    final _Device? target = devices[to];
    if (target == null || !target.online || !(devices[from]?.online ?? false)) {
      return;
    }
    final _Datagram datagram = (
      from: from,
      to: to,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
    );
    if (drop?.call(datagram) ?? false) {
      return;
    }
    queue.add(datagram);
  }

  Future<void> settle() async {
    int quiet = 0;
    for (int round = 0; round < 500 && quiet < 5; round++) {
      if (queue.isEmpty) {
        quiet++;
      } else {
        quiet = 0;
        while (queue.isNotEmpty) {
          final _Datagram d = queue.removeFirst();
          await devices[d.to]?.deliver(d.from, d.payload);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
}

final class _SimTransport implements SignalTransport {
  _SimTransport(this.mesh, this.address);

  final _Mesh mesh;
  final String address;

  @override
  Stream<SignalTransportFrame> get frames =>
      const Stream<SignalTransportFrame>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    mesh.sent.add(<String, dynamic>{
      ...payload,
      '_from': address,
      '_to': remoteAddress,
    });
    mesh.carry(address, _addr(remoteAddress), payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 1;

  @override
  Future<void> closeRelay(String callId) async {}
}

final class _Device {
  _Device(
    this.mesh,
    this.address, {
    required List<String> members,
    List<String> friends = const <String>[],
    Duration presenceTimeout = const Duration(minutes: 10),
    Duration ringWindow = const Duration(minutes: 10),
    Duration ringTimeout = Duration.zero,
    bool pendingInvite = false,
    FakeGroupCallMedia? media,
  }) : media = media ?? FakeGroupCallMedia(),
       runtime = RuntimeNodeRuntime.live(
         bootstrap: () async => RuntimeNodeSession(
           transport: MemorySignalTransport(),
           snapshot: RuntimeTransportSnapshot.started(
             localAddress: address,
             peers: 1,
           ),
         ),
       ) {
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
        signalTransportProvider.overrideWithValue(_SimTransport(mesh, address)),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          notifications,
        ),
        runtimeNodeRuntimeProvider.overrideWithValue(runtime),
        groupCallMediaProvider.overrideWithValue(this.media),
        groupCallHeartbeatIntervalProvider.overrideWithValue(Duration.zero),
        groupCallReRingIntervalProvider.overrideWithValue(Duration.zero),
        groupCallPresenceTimeoutProvider.overrideWithValue(presenceTimeout),
        groupCallRingWindowProvider.overrideWithValue(ringWindow),
        callRingingWaitTimeoutProvider.overrideWithValue(ringTimeout),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(lifecycle: _focused).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                for (final String friend in friends)
                  friend: FriendProfile(
                    address: friend,
                    displayName: 'F-$friend',
                    status: FriendRelationshipStatus.accepted,
                  ),
              },
            ),
            groups: <String, GroupProfile>{
              groupId: GroupProfile(
                id: groupId,
                name: 'Ekipa',
                createdById: members.first,
                createdAtMillis: 0,
                memberAddresses: members,
                isInvitePending: pendingInvite,
              ),
            },
          ),
        ),
      ],
    );
    // Build the controller now so the media is wired before any traffic.
    container.read(socialHubControllerProvider);
    mesh.devices[address] = this;
  }

  final _Mesh mesh;
  final String address;
  final FakeGroupCallMedia media;
  final RuntimeNodeRuntime runtime;
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  final MemoryRuntimeSystemNotificationService notifications =
      MemoryRuntimeSystemNotificationService();
  late final ProviderContainer container;
  bool online = true;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  /// Brings the node up, so the controller knows its own address.
  Future<void> boot() async {
    await runtime.start();
    expect(container.read(runtimeNodeSnapshotProvider).localAddress, address);
  }

  Future<void> shutdown() async {
    container.dispose();
    await runtime.stop();
  }

  SocialHubState get state => container.read(socialHubControllerProvider);

  CallSession? get call => state.activeCall;

  OngoingGroupCall? get running => state.groupCalls[groupId];

  Future<void> deliver(String from, Map<String, dynamic> payload) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    if (signal != null) {
      await controller.receiveSignal(signal);
    }
  }

  Future<List<String>> systemNotes() async =>
      (await timelines.load('group:$groupId'))
          .where((ChatMessage m) => m.isSystem)
          .map((ChatMessage m) => m.text)
          .toList();
}

Future<List<_Device>> _room(
  List<String> addresses, {
  Duration presenceTimeout = const Duration(minutes: 10),
  Duration ringWindow = const Duration(minutes: 10),
  Duration ringTimeout = Duration.zero,
}) async {
  final _Mesh mesh = _Mesh();
  final List<_Device> devices = <_Device>[
    for (final String address in addresses)
      _Device(
        mesh,
        address,
        members: addresses,
        // Deliberately *not* all friends: group calls must work between
        // people who only share the group.
        friends: address == ada ? <String>[bob] : const <String>[],
        presenceTimeout: presenceTimeout,
        ringWindow: ringWindow,
        ringTimeout: ringTimeout,
      ),
  ];
  addTearDown(() async {
    for (final _Device device in devices) {
      await device.shutdown();
    }
  });
  for (final _Device device in devices) {
    await device.boot();
  }
  return devices;
}

void _expectFullMesh(List<_Device> inCall) {
  for (final _Device device in inCall) {
    final List<String> others =
        inCall
            .where((_Device d) => d != device)
            .map((_Device d) => d.address)
            .toList()
          ..sort();
    expect(
      device.media.connectedPeers,
      others,
      reason: '${device.address} should be connected to everyone else',
    );
    expect(device.call?.participantAddresses, others);
  }
}

void main() {
  test(
    'starting a call puts the caller in at once and rings the others',
    () async {
      final List<_Device> d = await _room(<String>[ada, bob, cyd]);
      final _Mesh mesh = d.first.mesh;

      await d[0].controller.startGroupCall(
        groupId: groupId,
        kind: CallInviteKind.audio,
      );
      await mesh.settle();

      expect(d[0].call!.status, CallSessionStatus.active);
      expect(d[0].call!.participantAddresses, isEmpty);
      expect(d[0].media.startCount, 1);
      for (final _Device callee in d.skip(1)) {
        expect(callee.call!.status, CallSessionStatus.ringing);
        expect(callee.call!.isIncoming, isTrue);
        expect(callee.call!.isGroup, isTrue);
        expect(callee.call!.id, d[0].call!.id);
        expect(callee.call!.participantAddresses, <String>[ada]);
      }
    },
  );

  test('people join one by one and end up in a full mesh', () async {
    final List<_Device> d = await _room(<String>[ada, bob, cyd]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.video,
    );
    await mesh.settle();

    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();
    _expectFullMesh(<_Device>[d[0], d[1]]);
    // Carol is still ringing, and sees who is in.
    expect(d[2].call!.status, CallSessionStatus.ringing);
    expect(d[2].call!.participantAddresses, <String>[ada, bob]);

    await d[2].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();
    _expectFullMesh(d);

    // Every pair was offered exactly once, by its lower address.
    expect(d[0].media.offersSent, <String, int>{bob: 1, cyd: 1});
    expect(d[1].media.offersSent, <String, int>{cyd: 1});
    expect(d[2].media.offersSent, isEmpty);
  });

  test(
    'leaving keeps the call going for the rest, and you can come back',
    () async {
      final List<_Device> d = await _room(<String>[ada, bob, cyd]);
      final _Mesh mesh = d.first.mesh;
      await d[0].controller.startGroupCall(
        groupId: groupId,
        kind: CallInviteKind.audio,
      );
      await mesh.settle();
      await d[1].controller.acceptIncomingCall(peerAddress: groupId);
      await d[2].controller.acceptIncomingCall(peerAddress: groupId);
      await mesh.settle();
      _expectFullMesh(d);

      await d[1].controller.endActiveCall(peerAddress: groupId);
      await mesh.settle();
      expect(d[1].call, isNull);
      expect(d[1].media.activeCallId, isNull);
      _expectFullMesh(<_Device>[d[0], d[2]]);
      // Bob still sees the call running - and is not rung back into it.
      expect(d[1].running!.participantAddresses, <String>[ada, cyd]);

      await d[1].controller.joinGroupCall(groupId: groupId);
      await mesh.settle();
      _expectFullMesh(d);
    },
  );

  test('the last one out ends the call for good', () async {
    final List<_Device> d = await _room(<String>[ada, bob, cyd]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();

    await d[0].controller.endActiveCall(peerAddress: groupId);
    await mesh.settle();
    // Bob is alone but still in it.
    expect(d[1].call!.status, CallSessionStatus.active);
    expect(d[1].call!.participantAddresses, isEmpty);
    // Carol, still ringing, keeps ringing while Bob is there.
    expect(d[2].call!.status, CallSessionStatus.ringing);

    await d[1].controller.endActiveCall(peerAddress: groupId);
    await mesh.settle();
    for (final _Device device in d) {
      expect(device.running, isNull, reason: device.address);
    }
    // Nobody left to talk to: Carol's ring ends as a missed call.
    expect(d[2].call, isNull);
    expect(await d[2].systemNotes(), contains(startsWith('Nieodebrane')));
  });

  test('declining stops the ring for good, the call carries on', () async {
    final List<_Device> d = await _room(<String>[ada, bob, cyd]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();

    await d[1].controller.declineIncomingCall(peerAddress: groupId);
    await mesh.settle();
    expect(d[1].call, isNull);
    expect(d[0].call!.status, CallSessionStatus.active);

    // The caller's re-ring skips Bob, and a stray one would not ring anyway.
    mesh.sent.clear();
    await d[0].controller.reRingGroupCall(d[0].call!.id);
    await mesh.settle();
    final Iterable<Map<String, dynamic>> rings = mesh.sent.where(
      (Map<String, dynamic> p) => p['type'] == 'group_call_invite',
    );
    expect(rings.map((Map<String, dynamic> p) => p['_to']), <String>[cyd]);
    expect(d[1].call, isNull);

    // Bob can still join on his own later.
    await d[1].controller.joinGroupCall(groupId: groupId);
    await mesh.settle();
    _expectFullMesh(<_Device>[d[0], d[1]]);
  });

  test('a call nobody joins ends by itself after the ringing window', () async {
    final List<_Device> d = await _room(<String>[
      ada,
      bob,
    ], ringWindow: Duration.zero);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    expect(d[1].call!.status, CallSessionStatus.ringing);

    await d[0].controller.reRingGroupCall(d[0].call!.id);
    await mesh.settle();
    expect(d[0].call, isNull);
    expect(
      await d[0].systemNotes(),
      contains('Nikt nie dołączył do połączenia grupowego.'),
    );
    expect(d[1].call, isNull);
    expect(d[1].running, isNull);
  });

  test('an unanswered ring turns into one missed-call note', () async {
    final List<_Device> d = await _room(
      <String>[ada, bob],
      // Long enough that a busy test machine still sees the ring first.
      ringTimeout: const Duration(milliseconds: 500),
    );
    final _Mesh mesh = d.first.mesh;
    await d[1].controller.setLifecycle(
      const LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: 2,
        capturedAtMillis: 0,
      ),
    );
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    expect(d[1].call!.status, CallSessionStatus.ringing);

    await Future<void>.delayed(const Duration(milliseconds: 900));
    await mesh.settle();
    expect(d[1].call, isNull);
    expect(
      (await d[1].systemNotes()).where(
        (String t) => t.startsWith('Nieodebrane'),
      ),
      hasLength(1),
    );
    expect(
      d[1].notifications.activeNotifications.where(
        (RuntimeSystemNotification n) =>
            n.title == 'Nieodebrane połączenie grupowe',
      ),
      hasLength(1),
    );
    // The caller stops ringing Bob.
    mesh.sent.clear();
    await d[0].controller.reRingGroupCall(d[0].call!.id);
    await mesh.settle();
    expect(
      mesh.sent.where(
        (Map<String, dynamic> p) => p['type'] == 'group_call_invite',
      ),
      isEmpty,
    );
  });

  test('a lost offer is repeated until the leg connects', () async {
    final List<_Device> d = await _room(<String>[ada, bob]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    int dropped = 0;
    mesh.drop = (_Datagram datagram) {
      if (datagram.payload['type'] == 'gc_offer' && dropped == 0) {
        dropped++;
        return true;
      }
      return false;
    };
    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();
    expect(dropped, 1);
    expect(d[0].media.connectedPeers, isEmpty);

    await d[0].controller.tickGroupCalls();
    await mesh.settle();
    _expectFullMesh(d);
  });

  test('a lost answer is answered again from the repeated offer', () async {
    final List<_Device> d = await _room(<String>[ada, bob]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    int dropped = 0;
    mesh.drop = (_Datagram datagram) {
      if (datagram.payload['type'] == 'gc_answer' && dropped == 0) {
        dropped++;
        return true;
      }
      return false;
    };
    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();
    expect(d[0].media.connectedPeers, isEmpty);

    await d[0].controller.tickGroupCalls();
    await mesh.settle();
    _expectFullMesh(d);
  });

  test(
    'someone who vanishes without a word is dropped after the timeout',
    () async {
      final List<_Device> d = await _room(<String>[
        ada,
        bob,
        cyd,
      ], presenceTimeout: const Duration(milliseconds: 400));
      final _Mesh mesh = d.first.mesh;
      await d[0].controller.startGroupCall(
        groupId: groupId,
        kind: CallInviteKind.audio,
      );
      await mesh.settle();
      await d[1].controller.acceptIncomingCall(peerAddress: groupId);
      await d[2].controller.acceptIncomingCall(peerAddress: groupId);
      await mesh.settle();
      _expectFullMesh(d);

      d[2].online = false; // battery died
      // Ada and Bob keep announcing themselves; Carol stays silent.
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await d[0].controller.tickGroupCalls();
        await mesh.settle();
        await d[1].controller.tickGroupCalls();
        await mesh.settle();
      }

      _expectFullMesh(<_Device>[d[0], d[1]]);
      expect(d[0].running!.participantAddresses, <String>[bob]);
    },
  );

  test('a stale participant list cannot bring back someone who left', () async {
    final List<_Device> d = await _room(<String>[ada, bob, cyd]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await d[2].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();
    await d[2].controller.endActiveCall(peerAddress: groupId);
    await mesh.settle();

    // An old heartbeat of Bob's, still listing Carol, arrives late.
    await d[0].deliver(bob, <String, dynamic>{
      'type': 'group_call_state',
      'groupId': groupId,
      'callId': d[0].call!.id,
      'kind': 'audio',
      'participants': <String>[ada, cyd],
    });
    expect(d[0].call!.participantAddresses, <String>[bob]);
  });

  test('two calls started at the same moment merge into one', () async {
    final List<_Device> d = await _room(<String>[ada, bob, cyd]);
    final _Mesh mesh = d.first.mesh;
    // Neither hears the other before starting.
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await d[1].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();

    expect(d[0].call!.id, d[1].call!.id);
    _expectFullMesh(<_Device>[d[0], d[1]]);
    // Carol rings for exactly that one call.
    expect(d[2].call!.id, d[0].call!.id);
  });

  test(
    'someone who comes back after a crash gets a fresh connection',
    () async {
      final List<_Device> d = await _room(<String>[ada, bob]);
      final _Mesh mesh = d.first.mesh;
      await d[0].controller.startGroupCall(
        groupId: groupId,
        kind: CallInviteKind.audio,
      );
      await mesh.settle();
      await d[1].controller.acceptIncomingCall(peerAddress: groupId);
      await mesh.settle();
      expect(d[0].media.offersSent[bob], 1);

      // Bob's app restarted: its leg is gone, Ada's still looks fine.
      await d[1].media.close();
      await d[0].deliver(bob, <String, dynamic>{
        'type': 'group_call_join',
        'groupId': groupId,
        'callId': d[0].call!.id,
        'kind': 'audio',
      });
      await mesh.settle();
      expect(d[0].media.offersSent[bob], 2);
    },
  );

  test('moving into the older of two calls keeps you muted', () async {
    final List<_Device> d = await _room(<String>[ada, bob]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await d[1].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await d[1].controller.toggleActiveCallMute();
    expect(d[1].call!.isMuted, isTrue);
    await mesh.settle();

    expect(d[1].call!.id, d[0].call!.id);
    expect(d[1].call!.isMuted, isTrue);
    expect(d[1].media.muted, isTrue);
  });

  test('turning the camera on is announced to everyone in the call', () async {
    final List<_Device> d = await _room(<String>[ada, bob]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();
    expect(d[1].media.peers[ada]!.hasVideo, isFalse);

    await d[0].controller.toggleActiveCallCamera();
    await mesh.settle();
    expect(d[0].call!.isCameraEnabled, isTrue);
    expect(d[1].media.peers[ada]!.hasVideo, isTrue);
    // No renegotiation: still the one offer.
    expect(d[0].media.offersSent[bob], 1);
  });

  test('mute and speaker act on the group media', () async {
    final List<_Device> d = await _room(<String>[ada, bob]);
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await d[0].controller.toggleActiveCallMute();
    await d[0].controller.toggleActiveCallSpeaker();
    expect(d[0].media.muted, isTrue);
    expect(d[0].media.speakerOn, isTrue);
    expect(d[0].call!.isMuted, isTrue);
  });

  test(
    'outsiders and people who have not joined the group get nothing',
    () async {
      final _Mesh mesh = _Mesh();
      final _Device a = _Device(mesh, ada, members: <String>[ada, bob, cyd]);
      final _Device b = _Device(
        mesh,
        bob,
        members: <String>[ada, bob, cyd],
        pendingInvite: true,
      );
      // Dan is in nobody's group.
      final _Device outsider = _Device(mesh, dan, members: <String>[dan]);
      addTearDown(() async {
        await a.shutdown();
        await b.shutdown();
        await outsider.shutdown();
      });
      await a.boot();
      await b.boot();
      await outsider.boot();

      await a.controller.startGroupCall(
        groupId: groupId,
        kind: CallInviteKind.audio,
      );
      await mesh.settle();
      expect(b.call, isNull, reason: 'pending invitation must not ring');

      await a.deliver(dan, <String, dynamic>{
        'type': 'group_call_join',
        'groupId': groupId,
        'callId': a.call!.id,
        'kind': 'audio',
      });
      await mesh.settle();
      expect(a.call!.participantAddresses, isEmpty);
      expect(a.media.offersSent, isEmpty);
    },
  );

  test('leaving the group while in its call leaves the call', () async {
    final List<_Device> d = await _room(<String>[ada, bob]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    await d[1].controller.acceptIncomingCall(peerAddress: groupId);
    await mesh.settle();

    await d[1].controller.leaveGroup(groupId: groupId);
    await mesh.settle();
    expect(d[1].call, isNull);
    expect(d[1].media.activeCallId, isNull);
    expect(d[0].call!.participantAddresses, isEmpty);
  });

  test('starting while a call runs in the group joins it instead', () async {
    final List<_Device> d = await _room(<String>[ada, bob, cyd]);
    final _Mesh mesh = d.first.mesh;
    await d[0].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    await d[1].controller.declineIncomingCall(peerAddress: groupId);
    await mesh.settle();

    await d[1].controller.startGroupCall(
      groupId: groupId,
      kind: CallInviteKind.audio,
    );
    await mesh.settle();
    expect(d[1].call!.id, d[0].call!.id);
    _expectFullMesh(<_Device>[d[0], d[1]]);
  });

  test('media that cannot start leaves no call behind', () async {
    final _Mesh mesh = _Mesh();
    final _Device b = _Device(
      mesh,
      bob,
      members: <String>[ada, bob],
      media: FakeGroupCallMedia(failStart: true),
    );
    addTearDown(b.shutdown);
    await b.boot();

    await expectLater(
      b.controller.startGroupCall(groupId: groupId, kind: CallInviteKind.audio),
      throwsA(isA<FormatException>()),
    );
    expect(b.call, isNull);
    expect(b.running, isNull);
  });
}
