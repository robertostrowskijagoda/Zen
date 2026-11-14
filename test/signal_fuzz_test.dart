import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_location.dart';
import 'package:zen/src/domain/messages/chat_media_size.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/chat_poll.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Random and broken frames from the network, as anyone can send them: the
// parser must never throw on any of them, and a stranger's frames, however
// shaped, must never make a friend, change who is a friend, join a group
// or change its members, and never change, delete or vote in a friend's
// messages (a live location, a poll). Every frame type and every field
// the parser reads is in _types and _keys (test/fuzz_coverage_test.dart
// fails until a new one is); a new chat extra also gets a shape of its own
// in _value, as _poll and _location are.
// Seeded (ZEN_FUZZ_SEED), ZEN_FUZZ_FRAMES=20000
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
  'call_missed',
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
  'msgId',
  'at',
  're',
  'fwd',
  'media',
  'isTyping',
  'messageType',
  'fileName',
  'mimeType',
  'attachmentSizeBytes',
  'durationMs',
  'attachmentTransferBytes',
  'chunkCount',
  'chunkIndex',
  'chunkData',
  'attachmentData',
  'attachmentEncoding',
  'createdAt',
  'ttl',
  'ttlAt',
  'mp',
  'transferId',
  'fileSize',
  'description',
  'avatarPreset',
  'timestamp',
  'seconds',
  'status',
  'bio',
  'v',
  'participants',
  'camera',
  kMentionsKey,
  kPollKey,
  kLocationKey,
  kChangeAuthorKey,
  kGroupAddedKey,
  kGroupLeftKey,
  kGroupAddsKey,
  kCallElsewhereKey,
  kMediaWidthKey,
  kMediaHeightKey,
  // What a reading told to the account's other devices covers.
  'r',
];

/// The messages of friends the frames aim at (by id).
const List<String> _targets = <String>['loc-1', 'loc-g', 'poll-g', 'text-1'];

const String _friend = '200:1111:2222:3333:4444:5555:6666:7777';
const String _stranger = '200:dead:beef:3333:4444:5555:6666:7777';

/// Another friend, in the group too: may react, never change what [_friend]
/// wrote.
const String _other = '200:aaaa:bbbb:3333:4444:5555:6666:7777';
const String _groupId = 'g-friends';

/// A number as a position or a time might be, or a broken one.
num _number(Random r) => <num>[
  0,
  -1,
  52.23,
  21.01,
  90.0001,
  -180.5,
  1e308,
  double.nan,
  double.infinity,
  DateTime(2026).millisecondsSinceEpoch,
  1 << 62,
  r.nextDouble() * 400 - 200,
][r.nextInt(12)];

/// A poll as one is sent, mostly a little wrong.
Map<String, Object?> _poll(Random r) => <String, Object?>{
  if (r.nextInt(8) != 0) 'q': r.nextInt(6) == 0 ? _value(r, 3) : 'Kiedy?',
  if (r.nextInt(8) != 0)
    'o': <Object?>[
      for (int i = 0; i < r.nextInt(13); i++)
        r.nextInt(8) == 0 ? _value(r, 3) : 'odp $i',
    ],
  // Its time limit and its ending.
  if (r.nextInt(3) == 0) 'd': r.nextInt(6) == 0 ? _value(r, 3) : _number(r),
  if (r.nextInt(3) == 0) 'c': r.nextInt(6) == 0 ? _value(r, 3) : _number(r),
};

/// A location as one is sent, mostly a little wrong.
Map<String, Object?> _location(Random r) => <String, Object?>{
  for (final String k in <String>['la', 'lo', 'ac', 'at', 'un'])
    if (r.nextInt(8) != 0) k: r.nextInt(6) == 0 ? _value(r, 3) : _number(r),
  // Arrived ("Jestem na miejscu").
  if (r.nextInt(4) == 0) 'ar': r.nextBool() ? true : _value(r, 3),
};

Object? _value(Random r, int depth) {
  switch (r.nextInt(depth > 2 ? 7 : 11)) {
    case 0:
      return null;
    case 1:
      return r.nextInt(1 << 31) - (1 << 30);
    case 2:
      return r.nextBool();
    case 3:
      // Now and then a number only JSON text from the wire holds (1e400
      // reads as infinity) or one with no exact integer.
      return r.nextInt(4) == 0 ? _number(r) : r.nextDouble() * 1e12;
    case 4:
      // A known address, ours or a friend's, or a group's.
      return <String>[_friend, _stranger, _groupId, 'self', '', ..._targets][r
          .nextInt(5 + _targets.length)];
    case 5:
      return String.fromCharCodes(
        List<int>.generate(r.nextInt(40), (_) => 32 + r.nextInt(0x2FF)),
      );
    case 6:
      // Now and then something huge.
      return 'x' * (r.nextInt(10) == 0 ? 200000 : r.nextInt(300));
    case 8:
      return _poll(r);
    case 9:
      return _location(r);
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
  // Now and then a picture's size, mostly near or past its bounds.
  if (r.nextInt(6) == 0) ...<String, dynamic>{
    kMediaWidthKey: _side(r),
    kMediaHeightKey: _side(r),
  },
  'type': _types[r.nextInt(_types.length)],
};

/// A side of a picture as one is sent, or one no picture has.
Object? _side(Random r) => <Object?>[
  1,
  0,
  -1,
  kMaxChatMediaSide,
  kMaxChatMediaSide + 1,
  1 + r.nextInt(5000),
  1e12,
  0.5,
  _value(r, 3),
][r.nextInt(9)];

/// What the parser lets through as a poll or a location is one the app can
/// show: answers it can number, a place on Earth, a sharing no longer
/// than the longest.
void _expectSaneExtras(Map<String, dynamic>? extras) {
  if (extras == null) {
    return;
  }
  if (extras.containsKey(kPollKey)) {
    final ChatPoll? poll = ChatPoll.fromJson(extras[kPollKey]);
    expect(poll, isNotNull);
    expect(poll!.options.length, inInclusiveRange(2, kMaxPollOptions));
  }
  if (extras.containsKey(kMediaSizeKey)) {
    // A picture's size the bubble can use: whole pixels within bounds.
    final ChatMediaSize? size = ChatMediaSize.fromJson(extras[kMediaSizeKey]);
    expect(size, isNotNull);
    expect(size!.width, inInclusiveRange(1, kMaxChatMediaSide));
    expect(size.height, inInclusiveRange(1, kMaxChatMediaSide));
  }
  if (extras.containsKey(kLocationKey)) {
    final ChatLocation? at = ChatLocation.fromJson(extras[kLocationKey]);
    expect(at, isNotNull);
    expect(at!.lat.isFinite && at.lat.abs() <= 90, isTrue);
    expect(at.lon.isFinite && at.lon.abs() <= 180, isTrue);
    expect(at.accuracy.isFinite && at.accuracy >= 0, isTrue);
    expect(
      at.untilMillis,
      lessThanOrEqualTo(at.atMillis + kMaxLocationShare.inMilliseconds),
    );
  }
}

/// A frame aimed at one of the friends' messages: their id, the group's
/// id now and then, and an edit, a reaction or a deletion most of the time.
Map<String, dynamic> _aimed(Random r) => <String, dynamic>{
  ..._payload(r),
  'msgId': _targets[r.nextInt(_targets.length)],
  if (r.nextBool()) 'groupId': _groupId,
  if (r.nextInt(3) != 0)
    'type': <String>[
      'msg_edit',
      'msg_react',
      'msg_delete',
      'message',
      'group_message',
    ][r.nextInt(5)],
  if (r.nextInt(3) == 0) 'messageId': _targets[r.nextInt(_targets.length)],
  if (r.nextBool()) 'emoji': kPollVotes[r.nextInt(kPollVotes.length)],
  // The author of the message meant: the friend's, another's, or anything.
  if (r.nextBool())
    kChangeAuthorKey: r.nextInt(4) == 0
        ? _value(r, 3)
        : <String>[_friend, _other, _stranger][r.nextInt(3)],
  if (r.nextBool()) 'text': 'zmienione ${r.nextInt(1000)}',
  if (r.nextBool())
    kLocationKey: r.nextBool()
        ? _location(r)
        // A newer, well-formed position: only its sharer may move it.
        : <String, Object?>{
            'la': 52.3,
            'lo': 21.1,
            'ac': 5,
            'at': _place.atMillis + 1 + r.nextInt(60000),
            'un': _place.untilMillis,
          },
  if (r.nextInt(4) == 0) kPollKey: _poll(r),
};

final ChatLocation _place = ChatLocation(
  lat: 52.23,
  lon: 21.01,
  accuracy: 8,
  atMillis: DateTime(2026, 11, 5).millisecondsSinceEpoch,
  untilMillis: DateTime(2026, 11, 5, 1).millisecondsSinceEpoch,
);

final ChatPoll _question = ChatPoll.of('Kiedy?', <String>[
  'jutro',
  'w piątek',
])!;

/// What ends a friendship or a membership.
const Set<ZenSignalType> _parting = <ZenSignalType>{
  ZenSignalType.friendRemove,
  ZenSignalType.friendReject,
  ZenSignalType.friendCancel,
  ZenSignalType.groupLeave,
};

/// The friend's messages the frames aim at, by conversation.
Map<String, List<ChatMessage>> _friendsMessages() {
  ChatMessage from(String id, {ChatLocation? location, ChatPoll? poll}) =>
      ChatMessage(
        id: id,
        sender: _friend,
        text: poll?.asText ?? 'tu jestem',
        sentAtMillis: _place.atMillis,
        direction: ChatMessageDirection.incoming,
        location: location,
        poll: poll,
      );
  return <String, List<ChatMessage>>{
    _friend: <ChatMessage>[from('loc-1', location: _place), from('text-1')],
    'group:$_groupId': <ChatMessage>[
      from('loc-g', location: _place),
      from('poll-g', poll: _question),
    ],
  };
}

/// The social controller of a phone with one friend and one group, its
/// conversations in [timelines].
Future<(ProviderContainer, MemorySignalTransport)> _hubWith(
  MemoryMessageTimelineStore timelines,
) async {
  final MemorySignalTransport transport = MemorySignalTransport();
  // Files a frame carries (an attachment, a chunk) land in a folder of
  // the test's own.
  final Directory files = Directory.systemTemp.createTempSync('zen-fuzz-');
  addTearDown(() => files.deleteSync(recursive: true));
  final ProviderContainer container = ProviderContainer(
    overrides: [
      mediaVaultProvider.overrideWithValue(
        MediaVault(
          masterKey: () async => Uint8List.fromList(List<int>.filled(32, 5)),
          supportDirectory: () async => files,
          temporaryDirectory: () async => files,
        ),
      ),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(timelines),
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
              _other: FriendProfile(
                address: _other,
                displayName: 'Ewa',
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
          groups: const <String, GroupProfile>{
            _groupId: GroupProfile(
              id: _groupId,
              name: 'Znajomi',
              createdById: 'self',
              memberAddresses: <String>[_friend, _other],
              createdAtMillis: 1,
            ),
          },
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await transport.start();
  return (container, transport);
}

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
        _expectSaneExtras(signal.chatExtras);
      }
    }
    // Some of them were understood, so the fuzzing reached past the door.
    expect(parsed, greaterThan(0));
  });

  test('a stranger\'s frames of any shape make no friend and change no '
      'group', () async {
    final Random r = Random(_seed + 1);
    final (ProviderContainer container, _) = await _hubWith(
      MemoryMessageTimelineStore(),
    );
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
      hasLength(2),
    );
    final GroupProfile group = state.groups[_groupId]!;
    expect(group.memberAddresses, <String>[_friend, _other]);
    expect(group.isInvitePending, isFalse);
    // A group a stranger names is only ever an invitation, never joined.
    for (final GroupProfile g in state.groups.values) {
      if (g.id != _groupId) {
        expect(g.isInvitePending, isTrue, reason: g.id);
      }
    }
  });
  test(
    "a stranger's and another friend's frames aimed at a friend's live "
    'location and poll change and delete nothing, and a vote still counts',
    () async {
      final Random r = Random(_seed + 2);
      final Map<String, List<ChatMessage>> before = _friendsMessages();
      final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore(
        before,
      );
      final (ProviderContainer container, _) = await _hubWith(timelines);
      final SocialHubController hub = container.read(
        socialHubControllerProvider.notifier,
      );
      // The other friend's vote lands: their frames reach the messages,
      // it is the checks that keep them as they are.
      await hub.receiveSignal(
        zenSignalFromTransportPayload(
          sender: _other,
          payload: <String, dynamic>{
            'type': 'msg_react',
            'msgId': 'poll-g',
            'groupId': _groupId,
            'emoji': kPollVotes[1],
          },
        )!,
        receivedAtMillis: _place.atMillis,
      );
      final ChatMessage poll = (await timelines.load(
        'group:$_groupId',
      )).singleWhere((ChatMessage m) => m.id == 'poll-g');
      expect(
        poll.reactions[PeerShareCodec.normalizeAddress(_other)],
        kPollVotes[1],
      );
      expect(
        _question.votersIn(poll.reactions)[1],
        contains(PeerShareCodec.normalizeAddress(_other)),
      );
      int understood = 0;
      for (int i = 0; i < _frames; i++) {
        final String sender = r.nextBool() ? _stranger : _other;
        final ZenSignal? signal = zenSignalFromTransportPayload(
          sender: sender,
          payload: _aimed(r),
        );
        // The other friend stays a friend and a member: a leave or a
        // removal of theirs would only test the door again.
        if (signal == null ||
            (sender == _other && _parting.contains(signal.type))) {
          continue;
        }
        understood++;
        await hub.receiveSignal(
          signal,
          receivedAtMillis: _place.atMillis + 1 + i,
        );
      }
      expect(understood, greaterThan(_frames ~/ 4));
      for (final MapEntry<String, List<ChatMessage>> thread in before.entries) {
        final List<ChatMessage> now = await timelines.load(thread.key);
        for (final ChatMessage was in thread.value) {
          final ChatMessage? kept = now
              .where((ChatMessage m) => m.id == was.id)
              .firstOrNull;
          expect(kept, isNotNull, reason: was.id);
          expect(kept!.sender, _friend, reason: was.id);
          expect(kept.text, was.text, reason: was.id);
          expect(kept.location, was.location, reason: was.id);
          expect(kept.poll, was.poll, reason: was.id);
          expect(kept.deletedAtMillis, isNull, reason: was.id);
          expect(kept.editedAtMillis, isNull, reason: was.id);
          expect(
            kept.reactions.keys,
            isNot(contains(PeerShareCodec.normalizeAddress(_stranger))),
            reason: was.id,
          );
        }
      }
    },
  );
}
