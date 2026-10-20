import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  ProviderContainer buildContainer({
    required SocialHubState seed,
    SignalTransport? transport,
  }) {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        if (transport != null)
          signalTransportProvider.overrideWithValue(transport),
        socialHubSeedProvider.overrideWithValue(seed),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  SocialHubState seedWithFriend(
    String address,
    FriendRelationshipStatus status,
  ) {
    return SocialHubState.empty().copyWith(
      friends: <String, FriendProfile>{
        address: FriendProfile(
          address: address,
          displayName: 'Ada',
          status: status,
        ),
      },
    );
  }

  test('friend gate drops messages from strangers and blocked peers', () async {
    final ProviderContainer container = buildContainer(
      seed: seedWithFriend('blocked.ygg', FriendRelationshipStatus.blocked),
    );
    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.message,
        sender: 'stranger.ygg',
        content: 'spam od obcego',
      ),
      receivedAtMillis: 10,
    );
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.message,
        sender: 'blocked.ygg',
        content: 'spam od zablokowanego',
      ),
      receivedAtMillis: 11,
    );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.inbox, isEmpty);
    expect(state.friends.containsKey('stranger.ygg'), isFalse);
  });

  test('friend gate drops call offers from non-friends', () async {
    final ProviderContainer container = buildContainer(
      seed: SocialHubState.empty(),
    );
    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.callInvite,
        sender: 'stranger.ygg',
        callId: 'call-1',
      ),
      receivedAtMillis: 10,
    );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.activeCall, isNull);
    expect(state.inbox, isEmpty);
  });

  test('friend gate drops deep link signals from blocked peers', () async {
    final ProviderContainer container = buildContainer(
      seed: seedWithFriend('blocked.ygg', FriendRelationshipStatus.blocked),
    );
    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.deepLink,
        sender: 'blocked.ygg',
        routeKey: 'zen://inbox',
      ),
      receivedAtMillis: 10,
    );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.pendingLaunchIntent, isNull);
  });

  test(
    'friend requests stay open for unknown peers but not blocked ones',
    () async {
      final ProviderContainer container = buildContainer(
        seed: seedWithFriend('blocked.ygg', FriendRelationshipStatus.blocked),
      );
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );

      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'stranger.ygg',
          displayName: 'Stranger',
        ),
        receivedAtMillis: 10,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'blocked.ygg',
          displayName: 'Blocked',
        ),
        receivedAtMillis: 11,
      );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(
        state.friends['stranger.ygg']?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      expect(
        state.friends['blocked.ygg']?.status,
        FriendRelationshipStatus.blocked,
      );
    },
  );

  test('messages flow from accepted friends', () async {
    final ProviderContainer container = buildContainer(
      seed: seedWithFriend('ada.ygg', FriendRelationshipStatus.accepted),
    );
    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.message,
        sender: 'ada.ygg',
        content: 'czesc!',
      ),
      receivedAtMillis: 10,
    );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.inbox, hasLength(1));
    expect(state.friends['ada.ygg']?.lastMessagePreview, 'czesc!');
  });

  test(
    'unauthorized message from a stranger is dropped without any reply',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      const String stranger = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = buildContainer(
        seed: SocialHubState.empty(),
        transport: transport,
      );
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );

      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: stranger,
          content: 'Siemanko',
        ),
        receivedAtMillis: 10,
      );

      // An answer would confirm the device is online at this address, and
      // an automatic `friend_remove` ended real friendships whenever this
      // side had merely lost its friend list.
      expect(transport.sentSignals, isEmpty);
      expect(
        container.read(socialHubControllerProvider).friendByAddress(stranger),
        isNull,
      );
    },
  );

  test(
    'removeFriend with lowercase unnormalized address removes friend and clears timeline',
    () async {
      const String canonical = '200:1111:2222:3333:4444:5555:6666:7777';
      const String lowercase = '200:1111:2222:3333:4444:5555:6666:7777';
      final MemorySignalTransport transport = MemorySignalTransport();
      final ProviderContainer container = buildContainer(
        seed: SocialHubState.empty().copyWith(
          friends: <String, FriendProfile>{
            canonical: const FriendProfile(
              address: canonical,
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
            ),
          },
        ),
        transport: transport,
      );

      final MessageTimelineStore timeline = container.read(
        messageTimelineStoreProvider,
      );
      await timeline.save(canonical, <ChatMessage>[
        ChatMessage(
          id: 'msg-1',
          sender: canonical,
          text: 'stara wiadomość',
          sentAtMillis: 100,
          direction: ChatMessageDirection.incoming,
        ),
      ]);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.removeFriend(peerAddress: lowercase.toLowerCase());

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.friendByAddress(canonical), isNull);
      expect(
        transport.sentSignals.any(
          (entry) =>
              PeerShareCodec.addressesEqual(entry.remoteAddress, canonical) &&
              entry.payload['type'] == 'friend_remove',
        ),
        isTrue,
      );

      final List<ChatMessage> thread = await timeline.load(canonical);
      expect(thread, isEmpty);
    },
  );

  test(
    'cancelOutgoingRequest with lowercase address cancels correctly',
    () async {
      const String canonical = '200:1111:2222:3333:4444:5555:6666:7777';
      final MemorySignalTransport transport = MemorySignalTransport();
      final ProviderContainer container = buildContainer(
        seed: SocialHubState.empty().copyWith(
          friends: <String, FriendProfile>{
            canonical: const FriendProfile(
              address: canonical,
              displayName: 'Ada',
              status: FriendRelationshipStatus.pendingOutgoing,
            ),
          },
        ),
        transport: transport,
      );

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.cancelOutgoingRequest(
        peerAddress: canonical.toLowerCase(),
      );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.friendByAddress(canonical), isNull);
      expect(
        transport.sentSignals.any(
          (entry) =>
              PeerShareCodec.addressesEqual(entry.remoteAddress, canonical) &&
              entry.payload['type'] == 'friend_cancel',
        ),
        isTrue,
      );
    },
  );

  test('an accept nobody asked for never makes a friend', () async {
    // Regression: `friend_accept` from any non-blocked peer used to create
    // an accepted friend, who could then message, call and see presence.
    const String stranger = '200:1111:2222:3333:4444:5555:6666:7777';
    final MemorySignalTransport transport = MemorySignalTransport();
    final ProviderContainer container = buildContainer(
      seed: SocialHubState.empty(),
      transport: transport,
    );
    await transport.start();
    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.friendAccept,
        sender: stranger,
        displayName: 'Mama',
      ),
      receivedAtMillis: 10,
    );

    SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.acceptedFriends, isEmpty);
    // What it amounts to: an invitation the user can still turn down.
    expect(
      state.friendByAddress(stranger)?.status,
      FriendRelationshipStatus.pendingIncoming,
    );
    expect(state.inbox.single.type, InboxEntryType.friendRequest);
    // Nothing a friend gets: no profile sent back, no "connection ready".
    expect(
      transport.sentSignals.where(
        (entry) => entry.payload['type'] == 'profile_update',
      ),
      isEmpty,
    );
    final MessageTimelineStore timeline = container.read(
      messageTimelineStoreProvider,
    );
    expect(await timeline.load(stranger), isEmpty);

    // And the gate stays shut for everything a friend could send.
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.message,
        sender: stranger,
        content: 'Kliknij ten link',
      ),
      receivedAtMillis: 20,
    );
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.callInvite,
        sender: stranger,
        callId: 'call-x',
      ),
      receivedAtMillis: 21,
    );
    state = container.read(socialHubControllerProvider);
    expect(await timeline.load(stranger), isEmpty);
    expect(state.activeCall, isNull);

    // Only the user's own accept makes them a friend.
    await controller.acceptFriendRequest(peerAddress: stranger);
    expect(
      container
          .read(socialHubControllerProvider)
          .acceptedFriends
          .single
          .address,
      PeerShareCodec.normalizeAddress(stranger),
    );
  });

  test('an accept completes an invitation sent from here', () async {
    final ProviderContainer container = buildContainer(
      seed: seedWithFriend('ada.ygg', FriendRelationshipStatus.pendingOutgoing),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(type: ZenSignalType.friendAccept, sender: 'ada.ygg'),
          receivedAtMillis: 10,
        );

    expect(
      container.read(socialHubControllerProvider).friends['ada.ygg']?.status,
      FriendRelationshipStatus.accepted,
    );
  });

  test(
    'a request followed by its sender\'s own accept stays a request',
    () async {
      final ProviderContainer container = buildContainer(
        seed: SocialHubState.empty(),
      );
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'kuba.ygg',
          displayName: 'Kuba',
        ),
        receivedAtMillis: 10,
      );
      await controller.receiveSignal(
        const ZenSignal(type: ZenSignalType.friendAccept, sender: 'kuba.ygg'),
        receivedAtMillis: 11,
      );

      expect(
        container.read(socialHubControllerProvider).friends['kuba.ygg']?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
    },
  );

  test('a blocked peer\'s accept changes nothing', () async {
    final ProviderContainer container = buildContainer(
      seed: seedWithFriend('blocked.ygg', FriendRelationshipStatus.blocked),
    );
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendAccept,
            sender: 'blocked.ygg',
          ),
          receivedAtMillis: 10,
        );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(
      state.friends['blocked.ygg']?.status,
      FriendRelationshipStatus.blocked,
    );
    expect(state.inbox, isEmpty);
  });
}
