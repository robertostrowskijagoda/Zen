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
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Routable mesh addresses (the controller only talks to those).
final String ada = PeerShareCodec.normalizeAddress('200::ada');
final String bob = PeerShareCodec.normalizeAddress('200::b0b');
final String cyd = PeerShareCodec.normalizeAddress('200::c0d');
final String dan = PeerShareCodec.normalizeAddress('200::da2');
final String eve = PeerShareCodec.normalizeAddress('200::e7e');
final String zed = PeerShareCodec.normalizeAddress('200::2ed');

FriendProfile _friend(String address, String name) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
);

/// A snapshot whose file (and backup) cannot be read while [broken].
final class _BrokenStore implements SocialSnapshotStore {
  _BrokenStore(this.inner);

  final MemorySocialSnapshotStore inner;
  bool broken = true;
  int saves = 0;

  @override
  Future<SocialHubState?> load() async {
    if (broken) {
      throw const FormatException('unreadable');
    }
    return inner.load();
  }

  @override
  Future<void> save(SocialHubState state) async {
    saves += 1;
    await inner.save(state);
  }
}

void main() {
  late MemorySignalTransport transport;
  late MemoryMessageTimelineStore timelines;

  ProviderContainer buildContainer({
    SocialHubState? seed,
    SocialSnapshotStore? store,
    bool autoHydrate = false,
  }) {
    transport = MemorySignalTransport();
    timelines = MemoryMessageTimelineStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          store ?? MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        socialHubAutoHydrateProvider.overrideWithValue(autoHydrate),
        socialHubSeedProvider.overrideWithValue(seed ?? SocialHubState.empty()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('an unreadable snapshot', () {
    test(
      'is not taken for "no friends": nothing is answered, nothing is '
      'saved over it, and a later good read brings everything back',
      () async {
        final _BrokenStore store = _BrokenStore(
          MemorySocialSnapshotStore(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
              ),
            ),
          ),
        );
        final ProviderContainer container = buildContainer(
          store: store,
          autoHydrate: true,
        );
        final SocialHubController hub = container.read(
          socialHubControllerProvider.notifier,
        );
        await hub.whenHydrated;
        await Future<void>.delayed(Duration.zero);

        SocialHubState state = container.read(socialHubControllerProvider);
        expect(state.snapshotUnreadable, isTrue);
        expect(hub.isHydrated, isTrue);

        // A friend's message and a stranger's request while the list is gone.
        await hub.receiveSignal(
          ZenSignal(type: ZenSignalType.message, sender: ada, content: 'hej'),
          receivedAtMillis: 10,
        );
        await hub.receiveSignal(
          ZenSignal(
            type: ZenSignalType.friendRequest,
            sender: zed,
            displayName: 'Zed',
          ),
          receivedAtMillis: 11,
        );
        expect(
          transport.sentSignals.where(
            (s) => s.payload['type'] == 'friend_remove',
          ),
          isEmpty,
        );
        expect(
          transport.sentSignals.where(
            (s) => PeerShareCodec.addressesEqual(s.remoteAddress, ada),
          ),
          isEmpty,
        );
        expect(store.saves, 0, reason: 'the stand-in must never be saved');
        expect((await store.inner.load())!.friendByAddress(ada), isNotNull);

        // The storage recovers; coming back to the app reads it again.
        store.broken = false;
        await hub.setLifecycle(
          const LifecycleSnapshot(
            visibility: AppVisibilityState.background,
            generation: 2,
            capturedAtMillis: 0,
          ),
        );
        expect(store.saves, 0);
        await hub.setLifecycle(
          const LifecycleSnapshot(
            visibility: AppVisibilityState.foregroundFocused,
            generation: 3,
            capturedAtMillis: 0,
          ),
        );
        state = container.read(socialHubControllerProvider);
        expect(state.snapshotUnreadable, isFalse);
        expect(
          state.friendByAddress(ada)?.status,
          FriendRelationshipStatus.accepted,
        );
      },
    );

    test('a failed re-read after a good one changes nothing', () async {
      final _BrokenStore store = _BrokenStore(
        MemorySocialSnapshotStore(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
            ),
          ),
        ),
      )..broken = false;
      final ProviderContainer container = buildContainer(store: store);
      final SocialHubController hub = container.read(
        socialHubControllerProvider.notifier,
      );
      await hub.hydrateFromStore();
      store.broken = true;
      await expectLater(hub.hydrateFromStore(), throwsFormatException);

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.snapshotUnreadable, isFalse);
      expect(state.friendByAddress(ada), isNotNull);
    });
  });

  group('member list of a joined group', () {
    ProviderContainer groupContainer() => buildContainer(
      seed: SocialHubState.empty().copyWith(
        book: FriendshipBook.restore(
          profiles: <String, FriendProfile>{
            ada: _friend(ada, 'Ada'),
            bob: _friend(bob, 'Bob'),
          },
        ),
        groups: <String, GroupProfile>{
          'g': GroupProfile(
            id: 'g',
            name: 'Ekipa',
            createdById: ada,
            createdAtMillis: 0,
            memberAddresses: <String>[ada, bob],
          ),
        },
      ),
    );

    ZenSignal invite(String from, List<String> members) => ZenSignal(
      type: ZenSignalType.groupInvite,
      sender: from,
      groupId: 'g',
      groupName: 'Ekipa',
      memberAddresses: members,
    );

    test('an ordinary member cannot pull in a list of strangers', () async {
      final ProviderContainer container = groupContainer();
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            invite(bob, <String>[bob, ada, cyd, dan]),
            receivedAtMillis: 10,
          );
      expect(
        container
            .read(socialHubControllerProvider)
            .groups['g']!
            .memberAddresses,
        unorderedEquals(<String>[ada, bob]),
      );
      expect(await timelines.load('group:g'), isEmpty);
    });

    test(
      'an ordinary member adds one person, and everyone sees who did',
      () async {
        final ProviderContainer container = groupContainer();
        await container
            .read(socialHubControllerProvider.notifier)
            .receiveSignal(
              invite(bob, <String>[bob, ada, cyd]),
              receivedAtMillis: 10,
            );
        expect(
          container
              .read(socialHubControllerProvider)
              .groups['g']!
              .memberAddresses,
          unorderedEquals(<String>[ada, bob, cyd]),
        );
        final List<ChatMessage> lines = await timelines.load('group:g');
        expect(lines, hasLength(1));
        expect(lines.single.direction, ChatMessageDirection.system);
        expect(lines.single.text, contains('dodał(a) do grupy'));
      },
    );

    test('the creator still extends the list as it comes', () async {
      final ProviderContainer container = groupContainer();
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            invite(ada, <String>[ada, bob, cyd, dan, eve]),
            receivedAtMillis: 10,
          );
      expect(
        container
            .read(socialHubControllerProvider)
            .groups['g']!
            .memberAddresses,
        unorderedEquals(<String>[ada, bob, cyd, dan, eve]),
      );
    });

    test('someone outside the group adds nobody', () async {
      final ProviderContainer container = groupContainer();
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(invite(zed, <String>[zed, cyd]), receivedAtMillis: 10);
      expect(
        container
            .read(socialHubControllerProvider)
            .groups['g']!
            .memberAddresses,
        unorderedEquals(<String>[ada, bob]),
      );
    });
  });
}
