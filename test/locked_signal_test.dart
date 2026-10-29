import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// The encrypted snapshot: unreadable until the app is unlocked.
final class _LockedStore implements SocialSnapshotStore {
  _LockedStore(this.inner);

  final MemorySocialSnapshotStore inner;
  bool locked = true;

  @override
  Future<SocialHubState?> load() async {
    if (locked) {
      throw StateError('no key yet');
    }
    return inner.load();
  }

  @override
  Future<void> save(SocialHubState state) => inner.save(state);
}

void main() {
  test(
    'signals arriving while the app is locked wait for the stored friends',
    () async {
      final _LockedStore store = _LockedStore(
        MemorySocialSnapshotStore(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ),
      );
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        hasPassword: true,
        locked: true,
      );
      final MemorySignalTransport transport = MemorySignalTransport();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          appSecurityServiceProvider.overrideWithValue(security),
          signalTransportProvider.overrideWithValue(transport),
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(store),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController hub = container.read(
        socialHubControllerProvider.notifier,
      );
      final Future<void> request = hub.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'ola.ygg',
          displayName: 'Ola',
        ),
        receivedAtMillis: 5,
      );
      final Future<void> fromFriend = hub.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 6,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        transport.sentSignals.where(
          (s) => s.payload['type'] == 'friend_remove',
        ),
        isEmpty,
        reason: 'a friend must never look like a stranger while locked',
      );

      store.locked = false;
      // No stored credentials in the test service: unlocking simply opens it.
      await security.unlock('haslo');
      expect(security.isLocked, isFalse);
      await Future.wait(<Future<void>>[request, fromFriend]);

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.friendByAddress('ada.ygg'), isNotNull);
      expect(
        state.friendByAddress('ola.ygg'),
        isNotNull,
        reason: 'the request that came in while locked is kept',
      );
      expect(
        transport.sentSignals.where(
          (s) => s.payload['type'] == 'friend_remove',
        ),
        isEmpty,
      );
    },
  );
}
