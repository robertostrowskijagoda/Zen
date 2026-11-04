import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Random and broken frames from the network, as anyone can send them: the
// parser must never throw on any of them, and a stranger's frames, however
// shaped, must never make a friend, change who is a friend, join a group
// or change its members. Seeded (ZEN_FUZZ_SEED), ZEN_FUZZ_FRAMES=20000
// tries more locally.

int get _seed =>
    int.tryParse(Platform.environment['ZEN_FUZZ_SEED'] ?? '') ?? 20261105;
int get _frames =>
    int.tryParse(Platform.environment['ZEN_FUZZ_FRAMES'] ?? '') ?? 1500;

const List<String> _types = <String>[
  'friend_request',
  'friend_accept',
  'friend_reject',
  'friend_cancel',
  'friend_remove',
  'message_ack',
  'message_read',
  'typing',
  'message_placeholder',
  'message_chunk',
  'message_chunk_ack',
  'message',
  'message_transfer_cancel',
  'transfer_offer',
  'transfer_answer',
  'call_invite',
  'offer',
  'answer',
  'ringing',
  'call_accept',
  'call_decline',
  'call_offer_request',
  'busy',
  'hangup',
  'call_end',
  'group_invite',
  'group_invite_ack',
  'group_message',
  'msg_react',
  'msg_edit',
  'msg_delete',
  'disappear_timer',
  'group_leave',
  'profile_update',
  'group_call_invite',
  'group_call_join',
  'group_call_state',
  'group_call_leave',
  'group_call_decline',
  'gc_offer',
  'gc_answer',
  'nonsense',
  '',
];

const List<String> _keys = <String>[
  'type',
  'senderName',
  'message',
  'messageId',
  'groupId',
  'groupName',
  'memberAddresses',
  'memberNames',
  'inviteId',
  'it',
  'content',
  'callId',
  'sdp',
  'kind',
  'emoji',
  'text',
  'ids',
  'timer',
  'joined',
  'createdBy',
  'attachment',
  'mini',
  'replyTo',
  'seq',
  'total',
  'data',
  'name',
  'avatar',
];

const String _friend = '200:1111:2222:3333:4444:5555:6666:7777';
const String _stranger = '200:dead:beef:3333:4444:5555:6666:7777';
const String _groupId = 'g-friends';

Object? _value(Random r, int depth) {
  switch (r.nextInt(depth > 2 ? 7 : 9)) {
    case 0:
      return null;
    case 1:
      return r.nextInt(1 << 31) - (1 << 30);
    case 2:
      return r.nextBool();
    case 3:
      return r.nextDouble() * 1e12;
    case 4:
      // A known address, ours or a friend's, or a group's.
      return <String>[_friend, _stranger, _groupId, 'self', ''][r.nextInt(5)];
    case 5:
      return String.fromCharCodes(
        List<int>.generate(r.nextInt(40), (_) => 32 + r.nextInt(0x2FF)),
      );
    case 6:
      // Now and then something huge.
      return 'x' * (r.nextInt(10) == 0 ? 200000 : r.nextInt(300));
    case 7:
      return <Object?>[
        for (int i = 0; i < r.nextInt(5); i++) _value(r, depth + 1),
      ];
    default:
      return <String, Object?>{
        for (int i = 0; i < r.nextInt(5); i++)
          _keys[r.nextInt(_keys.length)]: _value(r, depth + 1),
      };
  }
}

Map<String, dynamic> _payload(Random r) => <String, dynamic>{
  for (int i = 0; i < r.nextInt(8); i++)
    _keys[r.nextInt(_keys.length)]: _value(r, 0),
  'type': _types[r.nextInt(_types.length)],
};

void main() {
  test('the parser takes any frame without throwing', () {
    final Random r = Random(_seed);
    int parsed = 0;
    for (int i = 0; i < _frames * 4; i++) {
      final Map<String, dynamic> payload = _payload(r);
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: r.nextBool() ? _stranger : _friend,
        payload: payload,
      );
      if (signal != null) {
        parsed++;
      }
    }
    // Some of them were understood, so the fuzzing reached past the door.
    expect(parsed, greaterThan(0));
  });

  test('a stranger\'s frames of any shape make no friend and change no '
      'group', () async {
    final Random r = Random(_seed + 1);
    final MemorySignalTransport transport = MemorySignalTransport();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          MemoryRuntimeSystemNotificationService(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _friend: FriendProfile(
                  address: _friend,
                  displayName: 'Ola',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            groups: const <String, GroupProfile>{
              _groupId: GroupProfile(
                id: _groupId,
                name: 'Znajomi',
                createdById: 'self',
                memberAddresses: <String>[_friend],
                createdAtMillis: 1,
              ),
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await transport.start();
    final SocialHubController hub = container.read(
      socialHubControllerProvider.notifier,
    );
    for (int i = 0; i < _frames; i++) {
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: _stranger,
        payload: _payload(r),
      );
      if (signal == null) {
        continue;
      }
      await hub.receiveSignal(signal, receivedAtMillis: 1000 + i);
    }
    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(
      state.friendByAddress(_friend)?.status,
      FriendRelationshipStatus.accepted,
    );
    expect(
      state.friendByAddress(_stranger)?.status,
      isNot(FriendRelationshipStatus.accepted),
    );
    expect(
      state.friends.values.where(
        (FriendProfile f) => f.status == FriendRelationshipStatus.accepted,
      ),
      hasLength(1),
    );
    final GroupProfile group = state.groups[_groupId]!;
    expect(group.memberAddresses, <String>[_friend]);
    expect(group.isInvitePending, isFalse);
    // A group a stranger names is only ever an invitation, never joined.
    for (final GroupProfile g in state.groups.values) {
      if (g.id != _groupId) {
        expect(g.isInvitePending, isTrue, reason: g.id);
      }
    }
  });
}
