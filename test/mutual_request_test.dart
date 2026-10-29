import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

ProviderContainer _hub(SocialHubState seed, MemorySignalTransport transport) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      signalTransportProvider.overrideWithValue(transport),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(
        MemoryMessageTimelineStore(),
      ),
      socialHubSeedProvider.overrideWithValue(seed),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A routable mesh address (lifecycle signals are only sent to those).
const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';

void main() {
  test('two people inviting each other at once become friends, and the '
      'other side is told', () async {
    final MemorySignalTransport transport = MemorySignalTransport();
    final ProviderContainer c = _hub(
      SocialHubState.empty().copyWith(
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
            _ada: FriendProfile(
              address: _ada,
              displayName: 'Ada',
              status: FriendRelationshipStatus.pendingOutgoing,
            ),
          },
        ),
      ),
      transport,
    );
    await c
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.friendRequest,
            sender: _ada,
            displayName: 'Ada',
          ),
          receivedAtMillis: 5,
        );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      c.read(socialHubControllerProvider).friendByAddress(_ada)!.status,
      FriendRelationshipStatus.accepted,
    );
    expect(
      transport.sentSignals.where((s) => s.payload['type'] == 'friend_accept'),
      isNotEmpty,
    );
  });

  test(
    'a request from someone not invited from here still waits for the user',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final ProviderContainer c = _hub(SocialHubState.empty(), transport);
      await c
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendRequest,
              sender: 'ola.ygg',
              displayName: 'Ola',
            ),
            receivedAtMillis: 5,
          );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        c.read(socialHubControllerProvider).friendByAddress('ola.ygg')!.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      expect(
        transport.sentSignals.where(
          (s) => s.payload['type'] == 'friend_accept',
        ),
        isEmpty,
      );
    },
  );
}
