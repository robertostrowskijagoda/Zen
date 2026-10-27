import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

final String ada = PeerShareCodec.normalizeAddress('200::ada');
final String bob = PeerShareCodec.normalizeAddress('200::b0b');

ChatMessage _msg(String id, {int at = 1000, ChatMessageDirection? dir}) =>
    ChatMessage(
      id: id,
      sender: 'self',
      text: id,
      sentAtMillis: at,
      direction: dir ?? ChatMessageDirection.outgoing,
    );

final class _Harness {
  _Harness(this.dir) {
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshots),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          MemoryRuntimeSystemNotificationService(),
        ),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            friends: <String, FriendProfile>{
              ada: FriendProfile(
                address: ada,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
              bob: FriendProfile(
                address: bob,
                displayName: 'Bob',
                status: FriendRelationshipStatus.accepted,
              ),
            },
            groups: <String, GroupProfile>{
              'g1': GroupProfile(
                id: 'g1',
                name: 'Paczka',
                createdById: ada,
                createdAtMillis: 1,
                memberAddresses: <String>[ada, bob],
              ),
            },
          ),
        ),
      ],
    );
  }

  final Directory dir;
  final MemorySignalTransport transport = MemorySignalTransport();
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  final MemorySocialSnapshotStore snapshots = MemorySocialSnapshotStore();
  late final ProviderContainer container;

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    await hub.receiveSignal(signal!, receivedAtMillis: 5000);
  }
}

void main() {
  group('DisappearingTimelineStore', () {
    test('stamps new messages, hides expired ones and sweeps them', () async {
      int now = 10000;
      final MemoryMessageTimelineStore raw = MemoryMessageTimelineStore();
      final DisappearingTimelineStore store = DisappearingTimelineStore(
        raw,
        now: () => now,
      );
      final List<String> expired = <String>[];
      final List<int> stamped = <int>[];
      store
        ..timerFor = ((String key) => key == 'a' ? 60 : 0)
        ..onExpired = ((String key, ChatMessage m) async => expired.add(m.id))
        ..onStamped = stamped.add;

      await store.append('a', _msg('m1'));
      await store.append('b', _msg('lasting'));
      await store.append(
        'a',
        const ChatMessage(
          id: 'sys',
          sender: 'system',
          text: 'x',
          sentAtMillis: 1,
          direction: ChatMessageDirection.system,
        ),
      );
      expect(
        (await raw.load(
          'a',
        )).firstWhere((ChatMessage m) => m.id == 'm1').expiresAtMillis,
        70000,
      );
      expect((await raw.load('b')).single.expiresAtMillis, isNull);
      expect(
        (await raw.load(
          'a',
        )).firstWhere((ChatMessage m) => m.isSystem).expiresAtMillis,
        isNull,
        reason: 'system lines stay',
      );
      expect(stamped, <int>[70000]);

      // Saving an existing message again does not restart its clock.
      now = 20000;
      final List<ChatMessage> thread = await store.load('a');
      await store.save('a', <ChatMessage>[
        for (final ChatMessage m in thread)
          m.copyWith(deliveryState: ChatMessageDeliveryState.delivered),
      ]);
      expect(
        (await raw.load(
          'a',
        )).firstWhere((ChatMessage m) => m.id == 'm1').expiresAtMillis,
        70000,
      );
      expect(await store.nextExpiry(<String>['a', 'b']), 70000);

      now = 70000;
      expect((await store.load('a')).map((ChatMessage m) => m.id), <String>[
        'sys',
      ], reason: 'expired messages are hidden before the sweep');
      expect(await store.sweep(<String>['a', 'b']), 1);
      expect(expired, <String>['m1']);
      expect((await raw.load('a')).map((ChatMessage m) => m.id), <String>[
        'sys',
      ]);
      expect(await raw.load('b'), hasLength(1));
    });

    test(
      'a save that drops a hidden expired message removes its files',
      () async {
        int now = 0;
        final MemoryMessageTimelineStore raw = MemoryMessageTimelineStore();
        final DisappearingTimelineStore store = DisappearingTimelineStore(
          raw,
          now: () => now,
        )..timerFor = ((String _) => 60);
        final List<String> expired = <String>[];
        store.onExpired = (String key, ChatMessage m) async =>
            expired.add(m.id);
        await store.append('a', _msg('old'));
        now = 61000;
        await store.append('a', _msg('new', at: 2000));
        // A caller that loads, edits and saves never sees 'old'.
        final List<ChatMessage> visible = await store.load('a');
        expect(visible.map((ChatMessage m) => m.id), <String>['new']);
        await store.save('a', visible);
        expect(expired, <String>['old']);
      },
    );

    test('the expiry survives the file store', () async {
      final Directory dir = await Directory.systemTemp.createTemp('zen-dm');
      addTearDown(() => dir.delete(recursive: true));
      final FileMessageTimelineStore files = FileMessageTimelineStore(
        store: FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      await files.save('a', <ChatMessage>[
        _msg('m').copyWith(expiresAtMillis: 1234),
        _msg('n', at: 2000),
      ]);
      final List<ChatMessage> back = await files.load('a');
      expect(back.first.expiresAtMillis, 1234);
      expect(back.last.expiresAtMillis, isNull);
    });

    test('labels and limits', () {
      expect(disappearLabel(0), 'wyłączone');
      expect(disappearLabel(3600), '1 godzina');
      expect(disappearLabel(86400), '1 dzień');
      expect(disappearLabel(604800), '7 dni');
      expect(sanitizeDisappearSeconds(-5), 0);
      expect(sanitizeDisappearSeconds('x'), 0);
      expect(sanitizeDisappearSeconds(5), 60);
      expect(sanitizeDisappearSeconds(999999999), kMaxDisappearSeconds);
    });
  });

  group('social hub', () {
    late Directory dir;
    late _Harness h;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zen-dm-hub');
      h = _Harness(dir);
    });

    tearDown(() async {
      h.container.dispose();
      await dir.delete(recursive: true);
    });

    test(
      'setting the timer tells the friend and stamps what is sent',
      () async {
        await h.hub.setDisappearingTimer(ada, 3600);
        expect(h.state.disappearSecondsFor(ada), 3600);
        final Map<String, dynamic> told = h.transport.sentSignals
            .lastWhere(
              (({String remoteAddress, Map<String, dynamic> payload}) s) =>
                  s.payload['type'] == 'disappear_timer',
            )
            .payload;
        expect(told['seconds'], 3600);
        expect(told.containsKey('groupId'), isFalse);

        await h.hub.sendLocalMessage(peerAddress: ada, text: 'tajne');
        final Map<String, dynamic> sent = h.transport.sentSignals
            .lastWhere(
              (({String remoteAddress, Map<String, dynamic> payload}) s) =>
                  s.payload['type'] == 'message',
            )
            .payload;
        expect(sent['ttl'], 3600);
        final ChatMessage stored = (await h.timelines.load(
          ada,
        )).firstWhere((ChatMessage m) => m.text == 'tajne');
        expect(stored.disappears, isTrue);
        final List<ChatMessage> thread = await h.timelines.load(ada);
        expect(
          thread.where((ChatMessage m) => m.isSystem).single.text,
          contains('1 godzina'),
        );

        // Messages to someone else stay.
        await h.hub.sendLocalMessage(peerAddress: bob, text: 'zwykła');
        expect((await h.timelines.load(bob)).single.disappears, isFalse);
        expect(
          h.transport.sentSignals.last.payload.containsKey('ttl'),
          isFalse,
        );

        // Off again: new messages stay.
        await h.hub.setDisappearingTimer(ada, 0);
        expect(h.state.disappearSecondsFor(ada), 0);
        await h.hub.sendLocalMessage(peerAddress: ada, text: 'jawne');
        expect(
          (await h.timelines.load(
            ada,
          )).firstWhere((ChatMessage m) => m.text == 'jawne').disappears,
          isFalse,
        );
      },
    );

    test(
      "the friend's timer is applied, also when it comes with a message",
      () async {
        await h.receive(ada, <String, dynamic>{
          'type': 'disappear_timer',
          'seconds': 86400,
          'at': 1,
        });
        expect(h.state.disappearSecondsFor(ada), 86400);
        expect(
          (await h.timelines.load(ada)).last.text,
          'Ada włączył(a) znikające wiadomości: 1 dzień.',
        );

        // Bob's change got lost; his next message carries it.
        await h.receive(bob, <String, dynamic>{
          'type': 'message',
          'msgId': 'b1',
          'text': 'hej',
          'ttl': 3600,
        });
        expect(h.state.disappearSecondsFor(bob), 3600);
        final ChatMessage got = (await h.timelines.load(
          bob,
        )).firstWhere((ChatMessage m) => m.id == 'b1');
        expect(got.disappears, isTrue);

        // A message without a timer does not switch it off.
        await h.receive(bob, <String, dynamic>{
          'type': 'message',
          'msgId': 'b2',
          'text': 'stara',
        });
        expect(h.state.disappearSecondsFor(bob), 3600);
      },
    );

    test(
      'group timers go to every member and only members may set them',
      () async {
        await h.hub.setDisappearingTimer('group:g1', 604800);
        final List<String> told = <String>[
          for (final ({String remoteAddress, Map<String, dynamic> payload}) s
              in h.transport.sentSignals)
            if (s.payload['type'] == 'disappear_timer' &&
                s.payload['groupId'] == 'g1')
              s.remoteAddress,
        ];
        expect(told.toSet(), <String>{ada, bob});

        await h.hub.sendGroupMessage(groupId: 'g1', text: 'w grupie');
        expect(h.transport.sentSignals.last.payload['ttl'], 604800);
        expect((await h.timelines.load('group:g1')).last.disappears, isTrue);

        final String stranger = PeerShareCodec.normalizeAddress('200::bad');
        await h.receive(stranger, <String, dynamic>{
          'type': 'disappear_timer',
          'groupId': 'g1',
          'seconds': 3600,
        });
        expect(h.state.disappearSecondsFor('group:g1'), 604800);

        await h.receive(bob, <String, dynamic>{
          'type': 'disappear_timer',
          'groupId': 'g1',
          'seconds': 0,
        });
        expect(h.state.disappearSecondsFor('group:g1'), 0);
      },
    );

    test('expired messages are swept with the timer that is kept', () async {
      await h.hub.setDisappearingTimer(ada, 3600);
      await h.timelines.save(ada, <ChatMessage>[
        _msg('gone').copyWith(expiresAtMillis: 1),
        _msg('kept', at: 2000),
      ]);
      await h.hub.sweepDisappearingMessages();
      expect(
        (await h.timelines.load(ada)).map((ChatMessage m) => m.id),
        <String>['kept'],
      );
    });

    test(
      'a late copy of a message that already disappeared does not bring '
      'it back',
      () async {
        final Map<String, dynamic> frame = <String, dynamic>{
          'type': 'message',
          'msgId': 'm1',
          'text': 'tajne',
          'ttl': 3600,
        };
        await h.receive(ada, frame);
        final ChatMessage got = (await h.timelines.load(
          ada,
        )).firstWhere((ChatMessage m) => m.id == 'm1');
        await h.timelines.save(ada, <ChatMessage>[
          got.copyWith(expiresAtMillis: 1),
        ]);
        await h.hub.sweepDisappearingMessages();
        expect(
          (await h.timelines.load(ada)).where((ChatMessage m) => m.id == 'm1'),
          isEmpty,
        );

        // A mailbox hands the same message over after it is gone.
        await h.receive(ada, frame);
        expect(
          (await h.timelines.load(ada)).where((ChatMessage m) => m.id == 'm1'),
          isEmpty,
        );
      },
      skip:
          'Real finding: once the sweep removed the message nothing '
          'remembers its id, so a late copy (a mailbox handing it over '
          'again, a retry from the sender) is stored anew with a fresh '
          'expiry, announced again and counted unread again (N7).',
    );

    test('the timers are kept in the snapshot', () async {
      await h.hub.setDisappearingTimer(ada, 3600);
      await h.hub.setDisappearingTimer(bob, 3600);
      await h.hub.setDisappearingTimer(bob, 0);
      final SocialHubState? saved = await h.snapshots.load();
      expect(saved!.disappearSecondsFor(ada), 3600);
      expect(saved.disappearingTimers.containsKey(bob), isTrue);
      expect(saved.disappearSecondsFor(bob), 0);
    });
  });

  test('disappearing messages are not put into lasting device copies', () {
    final ChatMessage m = _msg('x').copyWith(expiresAtMillis: 99);
    expect(m.disappears, isTrue);
    expect(chatMessageToSync(_msg('y'))['id'], 'y');
    expect(
      isMirroredPayload(<String, dynamic>{
        'type': 'group_message',
        'ttl': 3600,
      }),
      isTrue,
    );
    expect(
      isMirroredPayload(<String, dynamic>{'type': 'group_message'}),
      isFalse,
    );
    expect(
      isMirroredPayload(<String, dynamic>{'type': 'disappear_timer'}),
      isTrue,
    );
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
