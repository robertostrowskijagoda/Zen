import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/chat_attachment_transport_codec.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/test_harness_server.dart';
import 'package:zen/src/features/runtime/zstd_frame_guard.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Limits on what peers - strangers above all - can make this device store,
// decode or do. Each group pins one fix from the security review.

final String _ada = PeerShareCodec.normalizeAddress('200::ada');

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);

/// The `n`-th throwaway node address (`200::/8`, one key each).
String _nodeAddress(int n) =>
    PeerShareCodec.normalizeAddress('200::${(n + 1).toRadixString(16)}');

final class _Hub {
  _Hub({SocialHubState? seed, Directory? supportDirectory}) {
    container = ProviderContainer(
      overrides: [
        if (supportDirectory != null)
          supportDirectoryResolverProvider.overrideWithValue(
            _resolverFor(supportDirectory),
          ),
        signalQueueStoreProvider.overrideWithValue(queue),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        attachmentTransferStoreProvider.overrideWithValue(transfers),
        signalTransportProvider.overrideWithValue(transport),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          notifications,
        ),
        socialHubSeedProvider.overrideWithValue(
          seed ??
              SocialHubState.empty().copyWith(
                book: FriendshipBook.restore(
                  profiles: <String, FriendProfile>{
                    _ada: FriendProfile(
                      address: _ada,
                      displayName: 'Ada',
                      status: FriendRelationshipStatus.accepted,
                    ),
                  },
                ),
              ),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  final MemorySignalQueueStore queue = MemorySignalQueueStore();
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  final MemoryAttachmentTransferStore transfers =
      MemoryAttachmentTransferStore();
  final MemorySignalTransport transport = MemorySignalTransport();
  final MemoryRuntimeSystemNotificationService notifications =
      MemoryRuntimeSystemNotificationService();
  late final ProviderContainer container;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  Future<void> start() => transport.start();

  /// Invitations to groups from people who are not friends are taken (off
  /// by default).
  Future<void> allowInvitesFromAnyone() => container
      .read(appSettingsControllerProvider.notifier)
      .setGroupInviteFrom(GroupInviteFrom.everyone);

  Future<void> deliver(
    String from,
    Map<String, dynamic> payload, {
    int at = 1000,
  }) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    expect(signal, isNotNull, reason: 'payload must parse: $payload');
    await controller.receiveSignal(signal!, receivedAtMillis: at);
    await Future<void>.delayed(Duration.zero);
  }

  int get pendingIncoming => state.friends.values
      .where(
        (FriendProfile f) =>
            f.status == FriendRelationshipStatus.pendingIncoming,
      )
      .length;
}

SupportDirectoryResolver _resolverFor(Directory directory) =>
    () async => directory;

/// A zstd frame that declares [declared] bytes of content (single segment,
/// 4-byte size field), followed by [blocks] as (type, size, payload).
Uint8List _zstdFrame(int declared, List<(int, int, List<int>)> blocks) {
  final BytesBuilder out = BytesBuilder()
    ..add(<int>[0x28, 0xB5, 0x2F, 0xFD])
    ..addByte(0xA0)
    ..add(<int>[
      declared & 0xFF,
      (declared >> 8) & 0xFF,
      (declared >> 16) & 0xFF,
      (declared >> 24) & 0xFF,
    ]);
  for (int i = 0; i < blocks.length; i++) {
    final (int type, int size, List<int> payload) = blocks[i];
    final int header =
        (i == blocks.length - 1 ? 1 : 0) | (type << 1) | (size << 3);
    out
      ..add(<int>[header & 0xFF, (header >> 8) & 0xFF, (header >> 16) & 0xFF])
      ..add(payload);
  }
  return out.toBytes();
}

/// [content] as a valid (uncompressed, raw-block) zstd frame.
Uint8List _rawFrame(List<int> content) => _zstdFrame(
  content.length,
  <(int, int, List<int>)>[(0, content.length, content)],
);

void main() {
  group('friend requests from strangers', () {
    test('the oldest unanswered requests make room; friends stay', () async {
      final _Hub hub = _Hub();
      await hub.start();
      const int extra = 5;
      for (int i = 0; i < kMaxPendingIncomingFriendRequests + extra; i++) {
        await hub.deliver(_nodeAddress(i), <String, dynamic>{
          'type': 'friend_request',
          'senderName': 'Ktoś $i',
        }, at: 1000 + i);
      }

      expect(hub.pendingIncoming, kMaxPendingIncomingFriendRequests);
      for (int i = 0; i < extra; i++) {
        expect(hub.state.friendByAddress(_nodeAddress(i)), isNull);
      }
      expect(
        hub.state
            .friendByAddress(
              _nodeAddress(kMaxPendingIncomingFriendRequests + extra - 1),
            )
            ?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      expect(
        hub.state.friendByAddress(_ada)?.status,
        FriendRelationshipStatus.accepted,
      );
    });

    test('one /64 subnet cannot flood; a node address still gets in', () async {
      final _Hub hub = _Hub();
      await hub.start();
      // `3xx:` addresses all route to one node owning the whole /64.
      for (int i = 1; i <= 60; i++) {
        await hub.deliver(
          PeerShareCodec.normalizeAddress('300:1:2:3::${i.toRadixString(16)}'),
          <String, dynamic>{'type': 'friend_request'},
          at: 1000 + i,
        );
      }
      expect(hub.pendingIncoming, greaterThan(0));
      expect(hub.pendingIncoming, lessThan(60));

      final String someone = PeerShareCodec.normalizeAddress('200::beef');
      await hub.deliver(someone, <String, dynamic>{
        'type': 'friend_request',
      }, at: 2000);
      expect(
        hub.state.friendByAddress(someone)?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
    });

    test('a subnet counts as one identity, node addresses each as one', () {
      expect(
        PeerShareCodec.identityKeyForAddress('300:1:2:3:4:5:6:7'),
        PeerShareCodec.identityKeyForAddress('300:1:2:3:aaaa::1'),
      );
      expect(
        PeerShareCodec.identityKeyForAddress('200:1:2:3:4:5:6:7'),
        isNot(PeerShareCodec.identityKeyForAddress('200:1:2:3:4:5:6:8')),
      );
    });

    test('names and notes are clipped', () {
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: _ada,
        payload: <String, dynamic>{
          'type': 'friend_request',
          'senderName': 'M' * 5000,
          'message': 'x' * 50000,
        },
      );
      expect(signal!.displayName!.length, kMaxSignalSenderNameChars);
      expect(signal.content!.length, kMaxFriendRequestMessageChars);
    });

    test('copies queued in the background are capped (oldest go)', () async {
      final _Hub hub = _Hub(seed: SocialHubState.empty(lifecycle: _background));
      await hub.start();
      for (int i = 0; i < kMaxQueuedInvitations + 10; i++) {
        await hub.deliver(_nodeAddress(i), <String, dynamic>{
          'type': 'friend_request',
        }, at: 1000 + i);
      }
      final List<QueuedSignal> queued = await hub.queue.load();
      expect(
        queued
            .where(
              (QueuedSignal q) => q.signal.type == ZenSignalType.friendRequest,
            )
            .length,
        kMaxQueuedInvitations,
      );
      // The newest is still there; and every request is in the state anyway.
      expect(
        queued.last.signal.sender,
        _nodeAddress(kMaxQueuedInvitations + 9),
      );
      expect(hub.pendingIncoming, kMaxQueuedInvitations + 10);
    });
  });

  group('group invitations', () {
    test('member lists are capped and huge ids refused', () {
      final ZenSignal? invite = zenSignalFromTransportPayload(
        sender: _ada,
        payload: <String, dynamic>{
          'type': 'group_invite',
          'groupId': 'g-1',
          'groupName': 'G' * 1000,
          'memberAddresses': <String>[
            for (int i = 0; i < 1000; i++) _nodeAddress(i),
          ],
        },
      );
      expect(invite!.memberAddresses, hasLength(kMaxGroupMemberCount));
      expect(invite.groupName!.length, kMaxSignalGroupNameChars);

      expect(
        zenSignalFromTransportPayload(
          sender: _ada,
          payload: <String, dynamic>{
            'type': 'group_invite',
            'groupId': 'g' * (kMaxSignalIdChars + 1),
          },
        ),
        isNull,
      );
    });

    test('a stranger cannot post into the invitation they sent', () async {
      final _Hub hub = _Hub();
      await hub.start();
      // Only when invitations from anyone are taken (not the default).
      await hub.allowInvitesFromAnyone();
      final String stranger = _nodeAddress(7);
      await hub.deliver(stranger, <String, dynamic>{
        'type': 'group_invite',
        'groupId': 'g-spam',
        'groupName': 'Promocje',
        'memberAddresses': <String>[stranger],
      });
      expect(hub.state.groups['g-spam']?.isInvitePending, isTrue);

      for (int i = 0; i < 5; i++) {
        await hub.deliver(stranger, <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g-spam',
          'msgId': 'spam-$i',
          'text': 'x' * 10000,
        }, at: 2000 + i);
      }
      expect(await hub.timelines.load('group:g-spam'), isEmpty);
    });

    test('unanswered invitations are capped; joined groups stay', () async {
      const GroupProfile joined = GroupProfile(
        id: 'g-joined',
        name: 'Rodzina',
        createdById: 'self',
        createdAtMillis: 1,
        memberAddresses: <String>[],
      );
      final _Hub hub = _Hub(
        seed: SocialHubState.empty().copyWith(
          groups: const <String, GroupProfile>{'g-joined': joined},
        ),
      );
      await hub.start();
      await hub.allowInvitesFromAnyone();
      const int extra = 3;
      for (int i = 0; i < kMaxPendingGroupInvites + extra; i++) {
        await hub.deliver(_nodeAddress(i), <String, dynamic>{
          'type': 'group_invite',
          'groupId': 'g-$i',
          'groupName': 'Grupa $i',
        }, at: 1000 + i);
      }

      final Iterable<GroupProfile> pending = hub.state.groups.values.where(
        (GroupProfile g) => g.isInvitePending,
      );
      expect(pending, hasLength(kMaxPendingGroupInvites));
      for (int i = 0; i < extra; i++) {
        expect(hub.state.groups['g-$i'], isNull);
      }
      expect(hub.state.groups['g-joined'], isNotNull);
    });
  });

  group('attachment transfers', () {
    test('only plausible announcements are taken', () {
      expect(
        isPlausibleIncomingTransfer(transferBytes: 4, chunkCount: 2),
        isTrue,
      );
      expect(
        isPlausibleIncomingTransfer(
          transferBytes: kMaxIncomingAttachmentBytes + 1,
          chunkCount: 1000,
        ),
        isFalse,
      );
      expect(
        isPlausibleIncomingTransfer(transferBytes: 100, chunkCount: 101),
        isFalse,
      );
      // One chunk cannot carry ten megabytes.
      expect(
        isPlausibleIncomingTransfer(
          transferBytes: 10 * 1024 * 1024,
          chunkCount: 1,
        ),
        isFalse,
      );
    });

    test('a chunk must fit the transfer it claims to belong to', () {
      final IncomingAttachmentTransfer transfer = IncomingAttachmentTransfer(
        peerAddress: _ada,
        messageId: 'm',
        text: 'plik',
        sentAtMillis: 1,
        type: ChatMessageType.file,
        transferBytes: 4,
        chunkCount: 2,
      ).addChunk(0, Uint8List.fromList(<int>[1, 2]));

      expect(transfer.acceptsChunk(1, 2), isTrue);
      expect(transfer.acceptsChunk(2, 2), isFalse);
      expect(transfer.acceptsChunk(1, 3), isFalse);
      expect(
        transfer.acceptsChunk(1, kMaxIncomingAttachmentChunkBytes + 1),
        isFalse,
      );
    });

    test('stale transfers can be swept, and are counted per peer', () async {
      final MemoryAttachmentTransferStore store =
          MemoryAttachmentTransferStore();
      await store.saveIncoming(
        IncomingAttachmentTransfer(
          peerAddress: _ada,
          messageId: 'm',
          text: 'plik',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          transferBytes: 4,
          chunkCount: 1,
        ),
      );
      expect(await store.countIncoming(_ada), 1);
      expect(await store.countIncoming(_nodeAddress(3)), 0);
      expect(await store.deleteStaleIncoming(olderThanMillis: 0), 0);
      expect(
        await store.deleteStaleIncoming(
          olderThanMillis: DateTime.now().millisecondsSinceEpoch + 1,
        ),
        1,
      );
      expect(await store.countIncoming(_ada), 0);
    });

    test('chunks outside the announced transfer are ignored', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-transfer-limits-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final _Hub hub = _Hub(supportDirectory: tempDir);
      await hub.start();
      Map<String, dynamic> chunk(int index, List<int> bytes) =>
          <String, dynamic>{
            'type': 'message_chunk',
            'msgId': 'file-1',
            'text': 'raport.txt',
            'messageType': 'file',
            'fileName': 'raport.txt',
            'attachmentTransferBytes': 4,
            'chunkIndex': index,
            'chunkCount': 2,
            'chunkData': base64Encode(bytes),
          };
      int acks() => hub.transport.sentSignals
          .where((s) => s.payload['type'] == 'message_chunk_ack')
          .length;

      // Out of range, and more bytes than announced.
      await hub.deliver(_ada, chunk(5, <int>[9, 9]));
      await hub.deliver(_ada, chunk(0, List<int>.filled(10, 7)));
      expect(acks(), 0);
      expect(
        (await hub.transfers.loadIncoming(_ada, 'file-1'))?.receivedBytes ?? 0,
        0,
      );

      // The real ones still complete it.
      await hub.deliver(_ada, chunk(0, <int>[1, 2]));
      await hub.deliver(_ada, chunk(1, <int>[3, 4]));
      expect(acks(), 2);
      final List<ChatMessage> thread = await hub.timelines.load(_ada);
      // Kept encrypted; opened through the vault.
      expect(
        await hub.container
            .read(mediaVaultProvider)
            .read(thread.last.attachmentPath!),
        <int>[1, 2, 3, 4],
      );
    });

    test(
      'an oversized transfer is refused before anything is buffered',
      () async {
        final _Hub hub = _Hub();
        await hub.start();
        await hub.deliver(_ada, <String, dynamic>{
          'type': 'message_placeholder',
          'msgId': 'huge',
          'messageType': 'file',
          'fileName': 'huge.bin',
          'attachmentTransferBytes': kMaxIncomingAttachmentBytes + 1,
          'chunkCount': kMaxIncomingAttachmentChunks,
        });

        expect(await hub.transfers.loadIncoming(_ada, 'huge'), isNull);
        final List<ChatMessage> thread = await hub.timelines.load(_ada);
        expect(thread.single.deliveryState, ChatMessageDeliveryState.failed);
      },
    );

    test('one peer cannot keep endless transfers open', () async {
      final _Hub hub = _Hub();
      await hub.start();
      for (int i = 0; i <= kMaxConcurrentIncomingTransfersPerPeer; i++) {
        await hub.deliver(_ada, <String, dynamic>{
          'type': 'message_placeholder',
          'msgId': 'file-$i',
          'messageType': 'file',
          'fileName': 'plik-$i.bin',
          'attachmentTransferBytes': 1000,
          'chunkCount': 1,
        }, at: 1000 + i);
      }

      expect(
        await hub.transfers.countIncoming(_ada),
        kMaxConcurrentIncomingTransfersPerPeer,
      );
      final List<ChatMessage> thread = await hub.timelines.load(_ada);
      expect(thread.last.deliveryState, ChatMessageDeliveryState.failed);
    });
  });

  group('zstd input', () {
    test('frame headers bound the output without decompressing', () async {
      final ZstdOutputBounds? bounds = readZstdOutputBounds(
        _rawFrame(utf8.encode('hello')),
      );
      expect(bounds!.declaredBytes, 5);
      expect(bounds.worstCaseBytes, 5);

      // No declared content size (window descriptor, no size field): the
      // blocks still bound it, but nothing declares it.
      final Uint8List unsized = Uint8List.fromList(<int>[
        0x28, 0xB5, 0x2F, 0xFD, //
        0x00, 0x00, // descriptor, window
        0x29, 0x00, 0x00, 0x68, 0x65, 0x6C, 0x6C, 0x6F, // raw "hello"
      ]);
      final ZstdOutputBounds? unsizedBounds = readZstdOutputBounds(unsized);
      expect(unsizedBounds!.declaredBytes, isNull);
      expect(unsizedBounds.worstCaseBytes, 5);
      await expectLater(
        boundedZstdDecompress(
          unsized,
          maxBytes: 100,
          decompress: (Uint8List input) async => input,
        ),
        throwsFormatException,
      );
      // Not zstd at all.
      expect(
        readZstdOutputBounds(Uint8List.fromList(<int>[1, 2, 3, 4])),
        isNull,
      );
      // Truncated in the middle of a block.
      final Uint8List frame = _rawFrame(utf8.encode('hello'));
      expect(
        readZstdOutputBounds(Uint8List.sublistView(frame, 0, frame.length - 1)),
        isNull,
      );
    });

    test('a bomb is refused before the decoder ever sees it', () async {
      bool called = false;
      Future<Uint8List?> decoder(Uint8List input) async {
        called = true;
        return Uint8List(0);
      }

      // Declares far more than allowed.
      await expectLater(
        boundedZstdDecompress(
          _zstdFrame(1 << 30, <(int, int, List<int>)>[
            (0, 1, <int>[0]),
          ]),
          maxBytes: 2 * 1024 * 1024,
          decompress: decoder,
        ),
        throwsFormatException,
      );
      // Declares little, but its RLE blocks would regenerate far more.
      await expectLater(
        boundedZstdDecompress(
          _zstdFrame(100, <(int, int, List<int>)>[
            for (int i = 0; i < 20000; i++) (1, 100, <int>[0x41]),
          ]),
          maxBytes: 1000,
          decompress: decoder,
        ),
        throwsFormatException,
      );
      // No declared size either, and blocks that could regenerate far more.
      final BytesBuilder unsizedBomb = BytesBuilder()
        ..add(<int>[
          0x28,
          0xB5,
          0x2F,
          0xFD,
          0x00,
          0x58,
        ]); // 2 MiB window, no size
      for (int i = 0; i < 2000; i++) {
        // Compressed blocks (type 2) of one byte each: up to 128 KiB apiece.
        final int header = (i == 1999 ? 1 : 0) | (2 << 1) | (1 << 3);
        unsizedBomb
          ..add(<int>[header & 0xFF, (header >> 8) & 0xFF, 0])
          ..addByte(0);
      }
      await expectLater(
        boundedZstdDecompress(
          unsizedBomb.toBytes(),
          maxBytes: 2 * 1024 * 1024,
          decompress: decoder,
        ),
        throwsFormatException,
      );
      expect(called, isFalse);
    });

    test('a legitimate frame decodes, and the result is checked too', () async {
      final Uint8List frame = _rawFrame(utf8.encode('hello'));
      expect(
        await boundedZstdDecompress(
          frame,
          maxBytes: 100,
          decompress: (Uint8List input) async =>
              Uint8List.fromList(utf8.encode('hello')),
        ),
        utf8.encode('hello'),
      );
      // A decoder that produced more than the frame admitted.
      await expectLater(
        boundedZstdDecompress(
          frame,
          maxBytes: 5,
          decompress: (Uint8List input) async => Uint8List(6),
        ),
        throwsFormatException,
      );
    });

    test('an attachment bomb is refused by the attachment codec', () async {
      await expectLater(
        ChatAttachmentTransportCodec().decode(
          base64Data: base64Encode(
            _zstdFrame(1 << 30, <(int, int, List<int>)>[
              (0, 1, <int>[0]),
            ]),
          ),
          encoding: 'zstd',
        ),
        throwsFormatException,
      );
    });
  });

  group('call accept routes', () {
    const String peer = '200:1111:2222:3333:4444:5555:6666:7777';

    test('a link cannot answer a call: accept=1 only opens it', () {
      final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
        id: 'x',
        routeKey: 'zen://call/$peer?accept=1',
      );
      expect(intent!.target, RuntimeRouteTarget.call);
      expect(intent.autoAcceptCall, isFalse);
    });

    test('a route built here answers, for its own peer only', () {
      final String routeKey = buildCallRouteKey(
        peerAddress: peer,
        title: 'Ada',
        autoAccept: true,
      );
      expect(
        runtimeRouteIntentFromRouteKey(
          id: 'a',
          routeKey: routeKey,
        )!.autoAcceptCall,
        isTrue,
      );
      final String token = Uri.parse(routeKey).queryParameters['accept']!;
      expect(token.length, greaterThanOrEqualTo(32));
      expect(
        runtimeRouteIntentFromRouteKey(
          id: 'b',
          routeKey: 'zen://call/${_nodeAddress(9)}?accept=$token',
        )!.autoAcceptCall,
        isFalse,
      );
    });

    test(
      'the native card route answers with the ringing call\'s own token',
      () async {
        const CallSession ringing = CallSession(
          id: 'call-1',
          peerAddress: peer,
          displayName: 'Ada',
          kind: CallInviteKind.audio,
          status: CallSessionStatus.ringing,
          startedAtMillis: 1,
          isIncoming: true,
          acceptToken: 'call-secret-token',
        );
        final _Hub hub = _Hub(
          seed: SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                peer: FriendProfile(
                  address: peer,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            activeCall: ringing,
          ),
        );

        await hub.controller.requestLaunchFromRouteKey(
          'zen://call/$peer?accept=guessed',
        );
        expect(hub.state.pendingLaunchIntent!.autoAcceptCall, isFalse);

        await hub.controller.requestLaunchFromRouteKey(
          buildCallRouteKey(
            peerAddress: peer,
            autoAccept: true,
            acceptToken: 'call-secret-token',
          ),
        );
        expect(hub.state.pendingLaunchIntent!.autoAcceptCall, isTrue);

        // A plain link to the same call cannot undo the pending answer.
        await hub.controller.requestLaunchFromRouteKey('zen://call/$peer');
        expect(hub.state.pendingLaunchIntent!.autoAcceptCall, isTrue);
      },
    );

    test('the call token survives the stored snapshot', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-call-token-',
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
            peerAddress: peer,
            displayName: 'Ada',
            kind: CallInviteKind.audio,
            status: CallSessionStatus.ringing,
            startedAtMillis: 1,
            isIncoming: true,
            acceptToken: 'call-secret-token',
          ),
        ),
      );
      expect(
        (await store.load())!.activeCall!.acceptToken,
        'call-secret-token',
      );
    });
  });

  group('notification content', () {
    RuntimeSystemNotification notification(
      RuntimeSystemNotificationCategory category, {
      bool redacted = false,
    }) => RuntimeSystemNotification(
      id: 'n-${category.name}',
      title: 'Kasia',
      body: 'Tajna treść',
      createdAtMillis: 1,
      category: category,
      slotKey: 'slot-${category.name}',
      contentRedacted: redacted,
    );

    test(
      'with the setting on, no feature puts its text in the shade',
      () async {
        final MemoryRuntimeSystemNotificationService shade =
            MemoryRuntimeSystemNotificationService();
        final PrivacyRedactingNotificationService service =
            PrivacyRedactingNotificationService(
              shade,
              privacy: () => NotificationPrivacy.senderOnly,
            );

        await service.show(
          notification(RuntimeSystemNotificationCategory.social),
        );
        await service.show(
          notification(RuntimeSystemNotificationCategory.message),
        );
        await service.show(
          notification(RuntimeSystemNotificationCategory.call),
        );
        final Map<String, RuntimeSystemNotification> bySlot =
            <String, RuntimeSystemNotification>{
              for (final RuntimeSystemNotification n
                  in shade.activeNotifications)
                n.slotKey!: n,
            };
        expect(bySlot['slot-social']!.body, isNot(contains('Tajna')));
        expect(bySlot['slot-social']!.title, 'Kasia');
        expect(bySlot['slot-message']!.body, 'Nowa wiadomość');
        // The ringing UI has to say who calls.
        expect(bySlot['slot-call']!.body, 'Tajna treść');
      },
    );

    test('what a poster already redacted, and everything with the setting '
        'off, stays as it is', () async {
      final MemoryRuntimeSystemNotificationService shade =
          MemoryRuntimeSystemNotificationService();
      NotificationPrivacy level = NotificationPrivacy.senderOnly;
      final PrivacyRedactingNotificationService service =
          PrivacyRedactingNotificationService(shade, privacy: () => level);

      await service.show(
        notification(RuntimeSystemNotificationCategory.message, redacted: true),
      );
      expect(shade.activeNotifications.single.body, 'Tajna treść');

      level = NotificationPrivacy.senderAndContent;
      await service.show(
        notification(RuntimeSystemNotificationCategory.social),
      );
      expect(
        shade.activeNotifications
            .firstWhere(
              (RuntimeSystemNotification n) => n.slotKey == 'slot-social',
            )
            .body,
        'Tajna treść',
      );
    });
  });

  test('the test harness only answers requests addressed to loopback', () {
    expect(isLoopbackHarnessHost('127.0.0.1:48888'), isTrue);
    expect(isLoopbackHarnessHost('localhost:48900'), isTrue);
    expect(isLoopbackHarnessHost('[::1]:48888'), isTrue);
    expect(isLoopbackHarnessHost('127.0.0.1'), isTrue);
    // DNS rebinding: the page's own name, pointed at 127.0.0.1.
    expect(isLoopbackHarnessHost('evil.example:48888'), isFalse);
    expect(isLoopbackHarnessHost('127.0.0.1.evil.example'), isFalse);
    expect(isLoopbackHarnessHost(null), isFalse);
    expect(isLoopbackHarnessHost(''), isFalse);
  });

  test('the diagnostics log keeps only a prefix of peer addresses', () {
    final String redacted = redactPeerAddresses(
      'call from 200:1111:2222:3333:4444:5555:6666:7777 failed, '
      'retrying [201:abcd::1]:9001 at 2026-10-13T23:29:01.123',
    );
    expect(redacted, isNot(contains('3333')));
    expect(redacted, isNot(contains('abcd::1')));
    expect(redacted, contains('200:1111:…'));
    expect(redacted, contains('201:abcd:…'));
    // Timestamps and other numbers are left alone.
    expect(redacted, contains('2026-10-13T23:29:01.123'));
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
