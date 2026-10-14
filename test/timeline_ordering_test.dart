import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

ChatMessage _msg(String id, int at) => ChatMessage(
  id: id,
  sender: 'x',
  text: id,
  sentAtMillis: at,
  direction: ChatMessageDirection.incoming,
);

void main() {
  test('late mail lands at its send time, not at the bottom', () async {
    final MemoryMessageTimelineStore store = MemoryMessageTimelineStore();
    await store.append('p', _msg('a', 100));
    await store.append('p', _msg('c', 300));
    await store.append('p', _msg('b', 200)); // held by a relay for a while
    await store.append('p', _msg('d', 300)); // same second: stays after c

    expect((await store.load('p')).map((ChatMessage m) => m.id), <String>[
      'a',
      'b',
      'c',
      'd',
    ]);
  });

  test('messages carry the sender timestamp through the parser', () {
    final ZenSignal? direct = zenSignalFromTransportPayload(
      sender: 'peer',
      payload: <String, dynamic>{
        'type': 'message',
        'msgId': 'm',
        'text': 'hej',
        'createdAt': DateTime.utc(2026, 9, 1, 12).toIso8601String(),
      },
    );
    expect(
      direct!.sentAtMillis,
      DateTime.utc(2026, 9, 1, 12).millisecondsSinceEpoch,
    );
    final ZenSignal? group = zenSignalFromTransportPayload(
      sender: 'peer',
      payload: <String, dynamic>{
        'type': 'group_message',
        'groupId': 'g',
        'msgId': 'm',
        'text': 'hej',
        'timestamp': 1234,
      },
    );
    expect(group!.sentAtMillis, 1234);
  });

  test('group signals without a group id are rejected', () {
    for (final String type in <String>[
      'group_invite',
      'group_invite_ack',
      'group_message',
      'group_leave',
    ]) {
      expect(
        zenSignalFromTransportPayload(
          sender: 'peer',
          payload: <String, dynamic>{'type': type, 'text': 'x'},
        ),
        isNull,
        reason: type,
      );
    }
  });

  test('a malformed member list does not crash the parser', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: 'peer',
      payload: <String, dynamic>{
        'type': 'group_invite',
        'groupId': 'g',
        'memberAddresses': 'not-a-list',
      },
    );
    expect(signal, isNotNull);
    expect(signal!.memberAddresses, isNull);
  });

  test('a ringing group call survives the snapshot as a group call', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'zen-group-call-snapshot-',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final FileSocialSnapshotStore store = FileSocialSnapshotStore(
      store: FileBinaryStore(
        tempDir,
        codec: BinaryCodec(compressor: const _PassThroughCompressor()),
      ),
    );
    await store.save(
      SocialHubState.empty().copyWith(
        activeCall: const CallSession(
          id: 'call-1',
          peerAddress: 'grp-1',
          displayName: 'Ekipa',
          kind: CallInviteKind.audio,
          status: CallSessionStatus.ringing,
          startedAtMillis: 5,
          isIncoming: true,
          isGroup: true,
          groupId: 'grp-1',
          participantAddresses: <String>['a', 'b'],
        ),
      ),
    );
    final CallSession call = (await store.load())!.activeCall!;
    expect(call.isGroup, isTrue);
    expect(call.groupId, 'grp-1');
    expect(call.participantAddresses, <String>['a', 'b']);
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
