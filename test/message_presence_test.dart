import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

import 'support/friends_world.dart';

/// What messages say of a friend's presence and of the chat list: writing
/// to a friend says nothing of them, a copy that waited in a mailbox says
/// nothing of whether they are there now, and a late copy of an older
/// message does not put older words back at the top of the chat list.

const String _ada = 'ada.ygg';

/// A hub on the screen with Ada, a friend last seen [seenAt] and offline.
Future<SocialHubController> _hub({required int seenAt}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        hydrationEnabled: false,
      ),
      signalTransportProvider.overrideWithValue(MemorySignalTransport()),
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
      socialHubSeedProvider.overrideWithValue(
        SocialHubState.empty(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.foregroundFocused,
            generation: 1,
            capturedAtMillis: 0,
          ),
        ).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
              _ada: FriendProfile(
                address: _ada,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
                lastPresenceAtMillis: seenAt,
              ),
            },
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final SocialHubController hub = container.read(
    socialHubControllerProvider.notifier,
  );
  await hub.whenHydrated;
  return hub;
}

Future<void> _message(
  SocialHubController hub,
  String id,
  String text, {
  required int sentAt,
  required int receivedAt,
}) => hub.receiveSignal(
  ZenSignal(
    type: ZenSignalType.message,
    sender: _ada,
    messageId: id,
    content: text,
    sentAtMillis: sentAt,
  ),
  receivedAtMillis: receivedAt,
);

void main() {
  test('writing to a friend who is offline leaves them offline and as last '
      'seen', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.setOnline(b, false);
    await w.advance(const Duration(hours: 1));
    await a.hub.decayPresence(
      offlineAfter: const Duration(minutes: 10),
      foregroundFor: const Duration(minutes: 5),
      nowMillis: w.now,
    );
    final FriendProfile before = a.state.friendByAddress(b.address)!;
    expect(before.isOnline, isFalse);
    await w.send(a, b, 'Odezwij się');
    final FriendProfile after = a.state.friendByAddress(b.address)!;
    expect(after.isOnline, isFalse, reason: 'B never answered');
    expect(after.lastPresenceAtMillis, before.lastPresenceAtMillis);
    expect(after.lastMessagePreview, 'Odezwij się');
  });

  test('a message that waited in a mailbox does not make its sender '
      'online or just seen; one straight from them does', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int seenAt = now - const Duration(days: 9).inMilliseconds;
    final SocialHubController hub = await _hub(seenAt: seenAt);
    // Written an hour ago, picked up from a mailbox now.
    await _message(
      hub,
      'm-1',
      'Z skrzynki',
      sentAt: now - const Duration(hours: 1).inMilliseconds,
      receivedAt: now,
    );
    FriendProfile ada = hub.state.friendByAddress(_ada)!;
    expect(ada.isOnline, isFalse);
    expect(ada.lastPresenceAtMillis, seenAt);
    expect(ada.lastMessagePreview, 'Z skrzynki');
    expect(ada.unreadCount, 1);

    await _message(hub, 'm-2', 'Teraz', sentAt: now, receivedAt: now + 500);
    ada = hub.state.friendByAddress(_ada)!;
    expect(ada.isOnline, isTrue);
    expect(ada.lastPresenceAtMillis, now + 500);
  });

  test('a late copy of an older message keeps the newer line in the chat '
      'list', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final SocialHubController hub = await _hub(seenAt: now);
    await _message(hub, 'm-new', 'Nowsza', sentAt: now, receivedAt: now);
    final FriendProfile before = hub.state.friendByAddress(_ada)!;
    expect(before.lastMessagePreview, 'Nowsza');
    // A message Ada wrote half an hour earlier, from a mailbox only now.
    await _message(
      hub,
      'm-old',
      'Starsza',
      sentAt: now - const Duration(minutes: 30).inMilliseconds,
      receivedAt: now + 1000,
    );
    final FriendProfile after = hub.state.friendByAddress(_ada)!;
    expect(after.lastMessagePreview, 'Nowsza');
    expect(after.lastActivityLabel, before.lastActivityLabel);
    expect(after.unreadCount, before.unreadCount + 1);
  });
}
