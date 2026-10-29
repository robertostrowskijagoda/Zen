import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/chat_attachment_transport_codec.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/realtime_attachment_transfer.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  test(
    'friend accept updates chats immediately in focused foreground',
    () async {
      final MemorySignalQueueStore queueStore = MemorySignalQueueStore();
      final MemorySocialSnapshotStore snapshotStore =
          MemorySocialSnapshotStore();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final MemoryRuntimeNotificationCenter notificationCenter =
          MemoryRuntimeNotificationCenter();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(queueStore),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          runtimeNotificationCenterProvider.overrideWithValue(
            notificationCenter,
          ),
          socialHubSeedProvider.overrideWithValue(_seedWithAdaInvited()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: 'ada.ygg',
              displayName: 'Ada',
            ),
            receivedAtMillis: 42,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      final List<ChatMessage> thread = await timelineStore.load('ada.ygg');
      expect(state.pendingSignalCount, 0);
      expect(state.acceptedFriends, hasLength(1));
      expect(state.acceptedFriends.single.displayLabel, 'Ada');
      expect(
        state.acceptedFriends.single.status,
        FriendRelationshipStatus.accepted,
      );
      expect(state.inbox, isEmpty);
      expect(notificationCenter.activeNotifications, isEmpty);
      expect(thread.single.direction, ChatMessageDirection.system);
      expect(thread.single.text, 'Połączenie z Ada jest gotowe.');
      expect(await queueStore.load(), isEmpty);
      expect(
        (await snapshotStore.load())!.acceptedFriends.single.displayLabel,
        'Ada',
      );
    },
  );

  test(
    'lifecycle inbox labels fall back to share code instead of raw address',
    () async {
      const String address = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(type: ZenSignalType.friendRequest, sender: address),
            receivedAtMillis: 5,
          );

      final String title = container
          .read(socialHubControllerProvider)
          .inbox
          .single
          .title;
      expect(title, contains(PeerShareCodec.shareIdForAddress(address)));
      expect(title, isNot(contains(address)));
    },
  );

  test(
    'inbox labels prefer the locally assigned friend name over the share code',
    () async {
      const String address = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  address: FriendProfile(
                    address: address,
                    displayName: 'Krysia',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // The signal carries no display name — the local name must win.
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.message,
              sender: address,
              content: 'hej',
            ),
            receivedAtMillis: 7,
          );

      final String title = container
          .read(socialHubControllerProvider)
          .inbox
          .first
          .title;
      expect(title, contains('Krysia'));
      expect(title, isNot(contains(PeerShareCodec.shareIdForAddress(address))));
    },
  );

  test(
    'global settings seed retention defaults into new accepted relation',
    () async {
      final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
        const AppSettings(inboxLimitMb: 80, autoCleanupDays: 14),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(settingsStore),
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(_seedWithAdaInvited()),
        ],
      );
      addTearDown(container.dispose);

      container.read(appSettingsControllerProvider);
      await Future<void>.delayed(Duration.zero);
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: 'ada.ygg',
              displayName: 'Ada',
            ),
            receivedAtMillis: 9,
          );

      final FriendProfile ada = container
          .read(socialHubControllerProvider)
          .friends['ada.ygg']!;
      expect(ada.status, FriendRelationshipStatus.accepted);
      expect(ada.inboxLimitMb, 80);
      expect(ada.autoCleanupDays, 14);
    },
  );

  test(
    'background friend accept waits in queue until lifecycle is interactive',
    () async {
      final MemorySignalQueueStore queueStore = MemorySignalQueueStore();
      final MemorySocialSnapshotStore snapshotStore =
          MemorySocialSnapshotStore();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final MemoryRuntimeSystemNotificationService notificationService =
          MemoryRuntimeSystemNotificationService();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(queueStore),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          runtimeSystemNotificationServiceProvider.overrideWithValue(
            notificationService,
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(book: FriendshipBook.restore(profiles: _adaInvited)),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: 'ada.ygg',
              displayName: 'Ada',
            ),
            receivedAtMillis: 77,
          );

      SocialHubState state = container.read(socialHubControllerProvider);
      // The relationship change itself lands right away so a snapshot written
      // while backgrounded cannot restore the stale "pending" status; the
      // signal still waits in the queue for the interactive replay below.
      expect(state.acceptedFriends.single.displayLabel, 'Ada');
      expect(state.pendingSignalCount, 1);
      expect(
        state.backgroundAlerts.first.title,
        'Ada zaakceptował(a) zaproszenie',
      );
      expect(
        notificationService.activeNotifications.single.title,
        'Ada zaakceptował(a) zaproszenie',
      );
      expect(await queueStore.load(), hasLength(1));

      await container
          .read(socialHubControllerProvider.notifier)
          .setLifecycle(
            const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 2,
              capturedAtMillis: 90,
            ),
          );

      state = container.read(socialHubControllerProvider);
      expect(state.acceptedFriends.single.displayLabel, 'Ada');
      expect(state.pendingSignalCount, 0);
      expect(state.backgroundAlerts, hasLength(1));
      expect(await queueStore.load(), isEmpty);
      expect((await snapshotStore.load())!.pendingSignalCount, 0);

      await container
          .read(socialHubControllerProvider.notifier)
          .dismissBackgroundAlert(state.backgroundAlerts.single.id);

      state = container.read(socialHubControllerProvider);
      expect(state.backgroundAlerts, isEmpty);
      expect(notificationService.activeNotifications, isEmpty);
    },
  );

  test(
    'duplicate background lifecycle alerts collapse to the newest notification',
    () async {
      final MemoryRuntimeSystemNotificationService notificationService =
          MemoryRuntimeSystemNotificationService();
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
            notificationService,
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(book: FriendshipBook.restore(profiles: _adaInvited)),
          ),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 10,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 11,
      );

      // The second copy is the sender's retry of the same event: folded into
      // the first instead of re-posting (and re-buzzing) the notification.
      SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.backgroundAlerts, hasLength(1));
      expect(state.backgroundAlerts.single.createdAtMillis, 10);
      expect(notificationService.activeNotifications, hasLength(1));
      expect(notificationService.audibleAlertCount, 1);

      // A genuinely new event later on still collapses into the same slot,
      // showing the newest one.
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 60000,
      );
      state = container.read(socialHubControllerProvider);
      expect(state.backgroundAlerts, hasLength(1));
      expect(state.backgroundAlerts.single.createdAtMillis, 60000);
      expect(notificationService.activeNotifications, hasLength(1));
      expect(
        notificationService.activeNotifications.single.createdAtMillis,
        60000,
      );
    },
  );

  test(
    'background social lifecycle keeps only the latest state for a peer',
    () async {
      final MemoryRuntimeSystemNotificationService notificationService =
          MemoryRuntimeSystemNotificationService();
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
            notificationService,
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 10,
      );
      // (This used to be Ada's own `friend_accept`, which made her a friend
      // without the user ever confirming - see 'an accept nobody asked for
      // never makes a friend'. Her withdrawing the request is the next real
      // lifecycle step.)
      await controller.receiveSignal(
        const ZenSignal(type: ZenSignalType.friendCancel, sender: 'ada.ygg'),
        receivedAtMillis: 11,
      );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.backgroundAlerts, hasLength(1));
      expect(
        state.backgroundAlerts.single.type,
        InboxEntryType.friendCancelled,
      );
      expect(notificationService.activeNotifications, hasLength(1));
      expect(
        notificationService.activeNotifications.single.title,
        'Ada wycofał(a) zaproszenie',
      );
    },
  );

  test('global inbox limit trims oversized inbox entries for a peer', () async {
    final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        appSettingsStoreProvider.overrideWithValue(settingsStore),
        socialHubSeedProvider.overrideWithValue(
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
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(appSettingsControllerProvider.notifier)
        .setInboxLimitMb(5);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    final String payload1 = String.fromCharCodes(
      Uint8List(3 * 1024 * 1024)..fillRange(0, 3 * 1024 * 1024, 65),
    );
    final String payload2 = String.fromCharCodes(
      Uint8List(3 * 1024 * 1024)..fillRange(0, 3 * 1024 * 1024, 66),
    );

    await controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.message,
        sender: 'ada.ygg',
        content: '$payload1-older',
      ),
      receivedAtMillis: 10,
    );
    await controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.message,
        sender: 'ada.ygg',
        content: '$payload2-newer',
      ),
      receivedAtMillis: 11,
    );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.inbox, hasLength(1));
    expect(state.inbox.single.peerAddress, 'ada.ygg');
    expect(state.inbox.single.body.endsWith('-newer'), isTrue);
  });

  test('an accept after their own request does not skip the user (the request '
      'stays pending, message and inbox entry intact)', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
    );
    addTearDown(container.dispose);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.friendRequest,
        sender: 'kuba.ygg',
        displayName: 'Kuba',
        content: 'Mam paczke plikow na wieczor.',
      ),
      receivedAtMillis: 10,
    );
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.friendAccept,
        sender: 'kuba.ygg',
        displayName: 'Kuba',
      ),
      receivedAtMillis: 11,
    );

    // Kuba "accepting" his own request used to make him a friend. Only
    // the user's own accept may do that.
    final SocialHubState state = container.read(socialHubControllerProvider);
    final FriendProfile kuba = state.friends['kuba.ygg']!;
    expect(kuba.status, FriendRelationshipStatus.pendingIncoming);
    expect(kuba.requestMessage, 'Mam paczke plikow na wieczor.');
    expect(state.acceptedFriends, isEmpty);
    expect(state.inbox, hasLength(1));
    expect(state.inbox.single.type, InboxEntryType.friendRequest);
    expect(state.inbox.single.body, 'Mam paczke plikow na wieczor.');
  });

  test(
    'accepting a pending request sends friend_accept and clears inbox item',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryRuntimeNotificationCenter
      notificationCenter = MemoryRuntimeNotificationCenter(const <
        RuntimeNotification
      >[
        RuntimeNotification(
          id: 'foreground-friendRequest-200:1111:2222:3333:4444:5555:6666:7777',
          title: 'Nowe zaproszenie od Ada',
          body: 'Hej',
          createdAtMillis: 1,
          routeKey: 'zen://inbox',
        ),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          runtimeNotificationCenterProvider.overrideWithValue(
            notificationCenter,
          ),
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                    address: '200:1111:2222:3333:4444:5555:6666:7777',
                    displayName: 'Ada',
                    requestMessage: 'Hej',
                    status: FriendRelationshipStatus.pendingIncoming,
                  ),
                },
              ),
              inbox: const <InboxEntry>[
                InboxEntry(
                  id: 'req-1',
                  type: InboxEntryType.friendRequest,
                  title: 'Nowe zaproszenie od Ada',
                  body: 'Hej',
                  createdAtMillis: 1,
                  routeKey: 'zen://inbox',
                  peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
                ),
              ],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .acceptFriendRequest(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(
        state.acceptedFriends.single.status,
        FriendRelationshipStatus.accepted,
      );
      expect(state.inbox, isEmpty);
      expect(notificationCenter.activeNotifications, isEmpty);
      expect(transport.sentSignals.single.payload, <String, dynamic>{
        'type': 'friend_accept',
      });
    },
  );

  test(
    'incoming friend_accept brings their own name and keeps the nickname',
    () async {
      const String address = '200:AAAA:BBBB:CCCC:DDDD:EEEE:FFFF:0001';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  address: FriendProfile(
                    address: address,
                    nickname: 'Ania z pracy',
                    status: FriendRelationshipStatus.pendingOutgoing,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: address,
              displayName: 'Anna Nowak',
            ),
            receivedAtMillis: 12,
          );

      final FriendProfile friend = container
          .read(socialHubControllerProvider)
          .acceptedFriends
          .single;
      expect(friend.displayName, 'Anna Nowak');
      expect(friend.nickname, 'Ania z pracy');
    },
  );

  test(
    'incoming friend_accept upgrades the pending invite even when case differs',
    () async {
      const String storedAddress = '200:AAAA:BBBB:CCCC:DDDD:EEEE:FFFF:0001';
      const String packetAddress = '200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  storedAddress: FriendProfile(
                    address: storedAddress,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.pendingOutgoing,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: packetAddress,
              displayName: 'Ada',
            ),
            receivedAtMillis: 9,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.friends, hasLength(1));
      expect(state.pendingOutgoingFriends, isEmpty);
      expect(state.acceptedFriends, hasLength(1));
      expect(
        state.acceptedFriends.single.status,
        FriendRelationshipStatus.accepted,
      );
      expect(
        state.acceptedFriends.single.address,
        PeerShareCodec.normalizeAddress(storedAddress),
      );
    },
  );

  test('rejecting a pending request removes the local relation', () async {
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
        signalTransportProvider.overrideWithValue(transport),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                  address: '200:1111:2222:3333:4444:5555:6666:7777',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.pendingIncoming,
                ),
              },
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await transport.start();

    await container
        .read(socialHubControllerProvider.notifier)
        .rejectFriendRequest(
          peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
        );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.friends, isEmpty);
    expect(transport.sentSignals.single.payload, <String, dynamic>{
      'type': 'friend_reject',
    });
  });

  test(
    'incoming reject and cancel signals clean up pending relationships',
    () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.pendingOutgoing,
                  ),
                  'maks.ygg': FriendProfile(
                    address: 'maks.ygg',
                    displayName: 'Maks',
                    status: FriendRelationshipStatus.pendingIncoming,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(type: ZenSignalType.friendReject, sender: 'ada.ygg'),
        receivedAtMillis: 3,
      );
      await controller.receiveSignal(
        const ZenSignal(type: ZenSignalType.friendCancel, sender: 'maks.ygg'),
        receivedAtMillis: 4,
      );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.friends, isEmpty);
      expect(
        state.inbox.take(2).map((InboxEntry entry) => entry.type),
        <InboxEntryType>[
          InboxEntryType.friendCancelled,
          InboxEntryType.friendRejected,
        ],
      );
    },
  );

  test('a nickname is saved, kept under the name and can be removed', () async {
    final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(
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
      ],
    );
    addTearDown(container.dispose);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.setFriendNickname(
      peerAddress: 'ada.ygg',
      nickname: ' Ada z chóru ',
    );

    FriendProfile ada = container
        .read(socialHubControllerProvider)
        .friends['ada.ygg']!;
    expect(ada.displayLabel, 'Ada', reason: 'the name stays theirs');
    expect(ada.nickname, 'Ada z chóru');
    expect(
      (await snapshotStore.load())!.friends['ada.ygg']!.nickname,
      'Ada z chóru',
    );

    // Their next answer brings a new name; the nickname is not touched.
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.friendAccept,
        sender: 'ada.ygg',
        displayName: 'Ada Kowalska',
      ),
      receivedAtMillis: 5,
    );
    ada = container.read(socialHubControllerProvider).friends['ada.ygg']!;
    expect(ada.displayLabel, 'Ada Kowalska');
    expect(ada.nickname, 'Ada z chóru');

    await controller.setFriendNickname(peerAddress: 'ada.ygg', nickname: '');
    ada = container.read(socialHubControllerProvider).friends['ada.ygg']!;
    expect(ada.hasNickname, isFalse);
    expect((await snapshotStore.load())!.friends['ada.ygg']!.nickname, isEmpty);
  });

  test(
    'conversation retention prunes expired messages and cleans transfer state',
    () async {
      final int nowMillis = DateTime.now().millisecondsSinceEpoch;
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-retention-attachments-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      // Kept encrypted in the vault, as every received file is.
      final File managedAttachment = File(
        await _testVault(tempDir).put(Uint8List.fromList(<int>[1, 2, 3])),
      );
      final MemoryMessageTimelineStore
      timelineStore = MemoryMessageTimelineStore(<String, List<ChatMessage>>{
        'ada.ygg': <ChatMessage>[
          ChatMessage(
            id: 'old-file',
            sender: 'ada.ygg',
            text: 'Stary plik',
            sentAtMillis: nowMillis - const Duration(days: 8).inMilliseconds,
            direction: ChatMessageDirection.incoming,
            type: ChatMessageType.file,
            attachmentPath: managedAttachment.path,
            attachmentSizeBytes: 512000,
          ),
          ChatMessage(
            id: 'fresh-text',
            sender: 'ada.ygg',
            text: 'Swiezy wpis',
            sentAtMillis: nowMillis - const Duration(hours: 3).inMilliseconds,
            direction: ChatMessageDirection.incoming,
          ),
        ],
      });
      final MemoryAttachmentTransferStore transferStore =
          MemoryAttachmentTransferStore();
      await transferStore.saveIncoming(
        const IncomingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'old-file',
          text: 'Stary plik',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          transferBytes: 512000,
          chunkCount: 1,
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          attachmentTransferStoreProvider.overrideWithValue(transferStore),
          supportDirectoryResolverProvider.overrideWithValue(
            () async => tempDir,
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                    lastMessagePreview: 'Stary plik',
                    lastActivityLabel: 'Wczoraj',
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .configureConversationRetention(
            peerAddress: 'ada.ygg',
            inboxLimitMb: 0,
            autoCleanupDays: 2,
          );

      final List<ChatMessage> thread = await timelineStore.load('ada.ygg');
      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(thread.map((ChatMessage message) => message.id), <String>[
        'fresh-text',
      ]);
      expect(await managedAttachment.exists(), isFalse);
      expect(await transferStore.loadIncoming('ada.ygg', 'old-file'), isNull);
      expect(state.friends['ada.ygg']!.autoCleanupDays, 2);
      expect(state.friends['ada.ygg']!.lastMessagePreview, 'Swiezy wpis');
    },
  );

  test(
    'conversation retention trims oldest entries when size limit is exceeded',
    () async {
      final int nowMillis = DateTime.now().millisecondsSinceEpoch;
      final MemoryMessageTimelineStore
      timelineStore = MemoryMessageTimelineStore(<String, List<ChatMessage>>{
        'ada.ygg': <ChatMessage>[
          ChatMessage(
            id: 'first-big',
            sender: 'self',
            text: 'Pierwszy plik',
            sentAtMillis: nowMillis - const Duration(hours: 2).inMilliseconds,
            direction: ChatMessageDirection.outgoing,
            type: ChatMessageType.file,
            attachmentSizeBytes: 700000,
          ),
          ChatMessage(
            id: 'second-big',
            sender: 'self',
            text: 'Drugi plik',
            sentAtMillis: nowMillis - const Duration(hours: 1).inMilliseconds,
            direction: ChatMessageDirection.outgoing,
            type: ChatMessageType.file,
            fileName: 'drugi.pdf',
            attachmentSizeBytes: 700000,
          ),
        ],
      });
      final MemoryAttachmentTransferStore transferStore =
          MemoryAttachmentTransferStore();
      await transferStore.saveOutgoing(
        OutgoingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'first-big',
          text: 'Pierwszy plik',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          attachmentBytes: Uint8List.fromList(const <int>[1, 2, 3]),
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          attachmentTransferStoreProvider.overrideWithValue(transferStore),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                    lastMessagePreview: 'Pierwszy plik',
                    lastActivityLabel: 'Teraz',
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .configureConversationRetention(
            peerAddress: 'ada.ygg',
            inboxLimitMb: 1,
            autoCleanupDays: 0,
          );

      final List<ChatMessage> thread = await timelineStore.load('ada.ygg');
      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(thread.map((ChatMessage message) => message.id), <String>[
        'second-big',
      ]);
      expect(await transferStore.loadOutgoing('ada.ygg', 'first-big'), isNull);
      expect(state.friends['ada.ygg']!.inboxLimitMb, 1);
      expect(
        state.friends['ada.ygg']!.lastMessagePreview,
        chatMessageLabelForType(ChatMessageType.file, fileName: 'drugi.pdf'),
      );
    },
  );

  test('blocking a friend clears alerts and drops later signals', () async {
    final MemoryMessageTimelineStore timelineStore =
        MemoryMessageTimelineStore();
    final MemoryRuntimeNotificationCenter notificationCenter =
        MemoryRuntimeNotificationCenter(const <RuntimeNotification>[
          RuntimeNotification(
            id: 'alert-ada',
            title: 'Alert',
            body: 'Hej',
            createdAtMillis: 1,
            routeKey: 'zen://chat/ada.ygg?title=Ada',
          ),
        ]);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        runtimeNotificationCenterProvider.overrideWithValue(notificationCenter),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                  isOnline: true,
                ),
              },
            ),
            inbox: const <InboxEntry>[
              InboxEntry(
                id: 'inbox-ada',
                type: InboxEntryType.message,
                title: 'Nowa wiadomość od Ada',
                body: 'Hej',
                createdAtMillis: 1,
                routeKey: 'zen://chat/ada.ygg?title=Ada',
                peerAddress: 'ada.ygg',
              ),
            ],
            backgroundAlerts: const <InboxEntry>[
              InboxEntry(
                id: 'alert-ada',
                type: InboxEntryType.message,
                title: 'Nowa wiadomość od Ada',
                body: 'Hej',
                createdAtMillis: 1,
                routeKey: 'zen://chat/ada.ygg?title=Ada',
                peerAddress: 'ada.ygg',
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.blockFriend(peerAddress: 'ada.ygg', note: 'spam');

    SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.friends['ada.ygg']!.status, FriendRelationshipStatus.blocked);
    expect(state.friends['ada.ygg']!.blockNote, 'spam');
    expect(state.inbox, isEmpty);
    expect(state.backgroundAlerts, isEmpty);
    expect(notificationCenter.activeNotifications, isEmpty);

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.message,
        sender: 'ada.ygg',
        displayName: 'Ada',
        content: 'Czy to jeszcze przejdzie?',
      ),
      receivedAtMillis: 9,
    );

    state = container.read(socialHubControllerProvider);
    expect(state.inbox, isEmpty);
    expect(await timelineStore.load('ada.ygg'), isEmpty);

    await controller.unblockFriend(peerAddress: 'ada.ygg');
    state = container.read(socialHubControllerProvider);
    expect(state.friends['ada.ygg']!.status, FriendRelationshipStatus.none);
    expect(state.friends['ada.ygg']!.blockNote, isNull);
  });

  test('controller can hydrate social state from persisted snapshot', () async {
    final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore(
      SocialHubState(
        lifecycle: const LifecycleSnapshot(
          visibility: AppVisibilityState.foregroundFocused,
          generation: 4,
          capturedAtMillis: 123,
        ),
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
            'ada.ygg': FriendProfile(
              address: 'ada.ygg',
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
              isOnline: true,
              lastMessagePreview: 'Hej!',
              lastActivityLabel: 'Teraz',
            ),
          },
        ),
        inbox: const <InboxEntry>[
          InboxEntry(
            id: 'saved-1',
            type: InboxEntryType.friendAccepted,
            title: 'Ada zaakceptował(a) zaproszenie',
            body: 'Stan wracal po restarcie.',
            createdAtMillis: 1,
          ),
        ],
        pendingSignalCount: 0,
        backgroundAlerts: const <InboxEntry>[],
        activeCall: const CallSession(
          id: 'persisted-call',
          peerAddress: 'ada.ygg',
          displayName: 'Ada',
          kind: CallInviteKind.audio,
          status: CallSessionStatus.active,
          startedAtMillis: 321,
        ),
      ),
    );
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(socialHubControllerProvider.notifier)
        .hydrateFromStore();

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.acceptedFriends.single.displayLabel, 'Ada');
    expect(state.inbox.single.title, 'Ada zaakceptował(a) zaproszenie');
    // An active call cannot outlive the media session behind it, so a
    // snapshot written before the process died must not resurrect one.
    expect(state.activeCall, isNull);
  });

  test(
    'hydration keeps a persisted active call the media session owns',
    () async {
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController()
            ..activeCallIdValue = 'persisted-call';
      final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore(
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
          activeCall: const CallSession(
            id: 'persisted-call',
            peerAddress: 'ada.ygg',
            displayName: 'Ada',
            kind: CallInviteKind.audio,
            status: CallSessionStatus.active,
            startedAtMillis: 321,
          ),
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .hydrateFromStore();

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.id, 'persisted-call');
      expect(state.activeCall!.status, CallSessionStatus.active);
    },
  );

  test(
    'hydration restores a persisted ringing call so the service handoff keeps it',
    () async {
      final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore(
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
          activeCall: CallSession(
            id: 'handoff-call',
            peerAddress: 'ada.ygg',
            displayName: 'Ada',
            kind: CallInviteKind.audio,
            status: CallSessionStatus.ringing,
            startedAtMillis: DateTime.now().millisecondsSinceEpoch,
            isIncoming: true,
          ),
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .hydrateFromStore();

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.id, 'handoff-call');
      expect(state.activeCall!.status, CallSessionStatus.ringing);
    },
  );

  test('an early write cannot wipe the stored friends', () async {
    final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore(
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
    );
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
    );
    addTearDown(container.dispose);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    // Both of these land before the stored snapshot has been read back — the
    // lifecycle bridge publishes on the very first frame — and both persist.
    // On the empty seed that used to overwrite the real snapshot: every friend
    // gone from the app, and the background service left with no peer whose
    // call it is allowed to accept.
    await Future.wait(<Future<void>>[
      controller.setLifecycle(
        const LifecycleSnapshot(
          visibility: AppVisibilityState.background,
          generation: 2,
          capturedAtMillis: 1,
        ),
      ),
      controller.dismissBackgroundAlert('not-there'),
    ]);

    expect(
      container.read(socialHubControllerProvider).friends,
      hasLength(1),
      reason: 'hydration still has to win over the empty seed',
    );
    expect((await snapshotStore.load())!.friends, hasLength(1));
  });

  test(
    'hydration drops a ringing call older than the ringing window',
    () async {
      final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore(
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
          activeCall: const CallSession(
            id: 'stale-call',
            peerAddress: 'ada.ygg',
            displayName: 'Ada',
            kind: CallInviteKind.audio,
            status: CallSessionStatus.ringing,
            startedAtMillis: 321,
            isIncoming: true,
          ),
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .hydrateFromStore();

      expect(
        container.read(socialHubControllerProvider).activeCall,
        isNull,
        reason: 'the app must not ring for a call that ended while it was down',
      );
    },
  );

  test(
    'hydration keeps a live in-memory call over an older persisted one',
    () async {
      final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore(
        SocialHubState(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.foregroundFocused,
            generation: 4,
            capturedAtMillis: 123,
          ),
          book: FriendshipBook.restore(
            profiles: const <String, FriendProfile>{
              'ada.ygg': FriendProfile(
                address: 'ada.ygg',
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
          inbox: const <InboxEntry>[],
          pendingSignalCount: 0,
          backgroundAlerts: const <InboxEntry>[],
          activeCall: const CallSession(
            id: 'persisted-call',
            peerAddress: 'ada.ygg',
            displayName: 'Ada',
            kind: CallInviteKind.audio,
            status: CallSessionStatus.ringing,
            startedAtMillis: 100,
          ),
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
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
              activeCall: const CallSession(
                id: 'live-call',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.video,
                status: CallSessionStatus.active,
                startedAtMillis: 200,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .hydrateFromStore();

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.id, 'live-call');
      expect(state.activeCall!.kind, CallInviteKind.video);
      expect(state.activeCall!.status, CallSessionStatus.active);
    },
  );

  test(
    'deep link exposes a pending launch intent after foreground resume',
    () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
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
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
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

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.deepLink,
          sender: 'ada.ygg',
          routeKey: 'zen://chat/ada.ygg?title=Ada',
        ),
        receivedAtMillis: 7,
      );

      SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.pendingSignalCount, 1);
      expect(state.pendingLaunchIntent, isNull);

      await controller.setLifecycle(
        const LifecycleSnapshot(
          visibility: AppVisibilityState.foregroundFocused,
          generation: 2,
          capturedAtMillis: 8,
        ),
      );

      state = container.read(socialHubControllerProvider);
      expect(state.pendingSignalCount, 0);
      expect(
        state.pendingLaunchIntent!.target,
        RuntimeRouteTarget.conversation,
      );
      expect(state.pendingLaunchIntent!.peerAddress, 'ada.ygg');

      await controller.clearPendingLaunchIntent();
      expect(
        container.read(socialHubControllerProvider).pendingLaunchIntent,
        isNull,
      );
    },
  );

  test(
    'message signals append to timelines and refresh chat previews',
    () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(_seedWithAdaInvited()),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 1,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          displayName: 'Ada',
          content: 'Hej, już jestem.',
        ),
        receivedAtMillis: 2,
      );

      final SocialHubState state = container.read(socialHubControllerProvider);
      final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      expect(messages, hasLength(2));
      expect(messages.first.direction, ChatMessageDirection.system);
      expect(messages.last.text, 'Hej, już jestem.');
      expect(messages.last.direction, ChatMessageDirection.incoming);
      expect(
        state.acceptedFriends.single.lastMessagePreview,
        'Hej, już jestem.',
      );
      expect(state.acceptedFriends.single.unreadCount, 1);
    },
  );

  test(
    'sending a local message persists the outgoing timeline entry',
    () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalMessage(
            peerAddress: 'maks.ygg',
            displayName: 'Maks',
            text: 'Wrzucam build.',
            sentAtMillis: 5,
          );

      final List<ChatMessage> messages = await timelineStore.load('maks.ygg');
      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(messages.single.direction, ChatMessageDirection.outgoing);
      expect(messages.single.text, 'Wrzucam build.');
      expect(messages.single.deliveryState, ChatMessageDeliveryState.delivered);
      expect(state.acceptedFriends.single.displayLabel, 'Maks');
      expect(state.acceptedFriends.single.lastMessagePreview, 'Wrzucam build.');
    },
  );

  test(
    'clearing conversation history removes managed attachment files and preview',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-clear-history-attachments-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      // A voice message recorded here: kept encrypted in the vault.
      final File managedAttachment = File(
        await _testVault(tempDir).put(Uint8List.fromList(<int>[4, 5, 6])),
      );
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore(<String, List<ChatMessage>>{
            'ada.ygg': <ChatMessage>[
              ChatMessage(
                id: 'msg-1',
                sender: 'ada.ygg',
                text: 'Hej',
                sentAtMillis: 1,
                direction: ChatMessageDirection.incoming,
              ),
              ChatMessage(
                id: 'msg-2',
                sender: 'self',
                text: 'Plik',
                sentAtMillis: 2,
                direction: ChatMessageDirection.outgoing,
                type: ChatMessageType.file,
                attachmentPath: managedAttachment.path,
                attachmentSizeBytes: 2048,
              ),
            ],
          });
      final MemoryAttachmentTransferStore transferStore =
          MemoryAttachmentTransferStore();
      final Uint8List outgoingBytes = Uint8List.fromList(<int>[1, 2, 3]);
      await transferStore.saveIncoming(
        const IncomingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'msg-2',
          text: 'Plik',
          sentAtMillis: 2,
          type: ChatMessageType.file,
          transferBytes: 2048,
          chunkCount: 1,
        ),
      );
      await transferStore.saveOutgoing(
        OutgoingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'msg-2',
          text: 'Plik',
          sentAtMillis: 2,
          type: ChatMessageType.file,
          attachmentBytes: outgoingBytes,
        ),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          attachmentTransferStoreProvider.overrideWithValue(transferStore),
          supportDirectoryResolverProvider.overrideWithValue(
            () async => tempDir,
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                    lastMessagePreview: 'Plik',
                    lastActivityLabel: 'Teraz',
                    unreadCount: 3,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      final preview = await controller.previewConversationHistory(
        peerAddress: 'ada.ygg',
      );
      expect(preview.messageCount, 2);
      expect(preview.attachmentBytes, 2048);

      await controller.clearConversationHistory(peerAddress: 'ada.ygg');

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(await timelineStore.load('ada.ygg'), isEmpty);
      expect(await managedAttachment.exists(), isFalse);
      expect(await transferStore.loadIncoming('ada.ygg', 'msg-2'), isNull);
      expect(await transferStore.loadOutgoing('ada.ygg', 'msg-2'), isNull);
      expect(state.friends['ada.ygg']!.lastMessagePreview, isEmpty);
      expect(state.friends['ada.ygg']!.lastActivityLabel, isEmpty);
      expect(state.friends['ada.ygg']!.unreadCount, 0);
    },
  );

  test(
    'sending a local message forwards a network payload for routable peers',
    () async {
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
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                    address: '200:1111:2222:3333:4444:5555:6666:7777',
                    displayName: 'Maks',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalMessage(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            displayName: 'Maks',
            text: 'Wrzucam build.',
            sentAtMillis: 5,
          );

      expect(transport.sentSignals, hasLength(1));
      expect(transport.sentSignals.single.payload, <String, dynamic>{
        'type': 'message',
        'msgId': 'outgoing-5-200:1111:2222:3333:4444:5555:6666:7777',
        'text': 'Wrzucam build.',
        'createdAt': DateTime.fromMillisecondsSinceEpoch(
          5,
        ).toUtc().toIso8601String(),
      });
    },
  );

  test(
    'sending typing state forwards signal payload to routable peers',
    () async {
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
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                    address: '200:1111:2222:3333:4444:5555:6666:7777',
                    displayName: 'Maks',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendTypingState(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            isTyping: true,
          );

      expect(transport.sentSignals, hasLength(1));
      expect(transport.sentSignals.single.payload, <String, dynamic>{
        'type': 'typing',
        'isTyping': true,
      });
    },
  );

  test(
    'sending a call invite forwards signal payload and logs a system entry',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                    address: '200:1111:2222:3333:4444:5555:6666:7777',
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
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendCallInvite(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            kind: CallInviteKind.video,
          );

      final List<ChatMessage> thread = await timelineStore.load(
        '200:1111:2222:3333:4444:5555:6666:7777',
      );
      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(transport.sentSignals.single.payload['type'], 'call_invite');
      expect(transport.sentSignals.single.payload['kind'], 'video');
      expect(transport.sentSignals.single.payload['callId'], isNotEmpty);
      expect(callMedia.startedOutgoingCallId, state.activeCall?.id);
      expect(
        callMedia.startedOutgoingRemoteAddress,
        '200:1111:2222:3333:4444:5555:6666:7777',
      );
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.status, CallSessionStatus.ringing);
      expect(thread.single.direction, ChatMessageDirection.system);
      expect(thread.single.text, 'Wysłano zaproszenie do rozmowy wideo.');
    },
  );

  test(
    'sending a local attachment stores bytes and forwards attachment payload',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalAttachment(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            displayName: 'Ada',
            fileName: 'raport.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList(utf8.encode('hej')),
            sentAtMillis: 12,
          );

      final List<ChatMessage> messages = await timelineStore.load(
        '200:1111:2222:3333:4444:5555:6666:7777',
      );
      expect(messages.single.type, ChatMessageType.file);
      expect(messages.single.fileName, 'raport.txt');
      expect(messages.single.attachmentBytes, utf8.encode('hej'));
      expect(transport.sentSignals.single.payload['messageType'], 'file');
      expect(transport.sentSignals.single.payload['fileName'], 'raport.txt');
      expect(transport.sentSignals.single.payload['attachmentData'], 'aGVq');
    },
  );

  test(
    'sending a GIF attachment keeps gif metadata in timeline and payload',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalAttachment(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            displayName: 'Ada',
            fileName: 'gif.gif',
            mimeType: 'image/gif',
            bytes: Uint8List.fromList(<int>[71, 73, 70]),
            sentAtMillis: 13,
          );

      final List<ChatMessage> messages = await timelineStore.load(
        '200:1111:2222:3333:4444:5555:6666:7777',
      );
      expect(messages.single.type, ChatMessageType.image);
      expect(messages.single.attachmentBytes, <int>[71, 73, 70]);
      expect(messages.single.mimeType, 'image/gif');
      expect(messages.single.fileName, 'gif.gif');
      expect(transport.sentSignals.single.payload['messageType'], 'image');
      expect(transport.sentSignals.single.payload, isNot(contains('gifUrl')));
      expect(transport.sentSignals.single.payload['mimeType'], 'image/gif');
    },
  );

  test(
    'sending a voice attachment from file path keeps duration metadata',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-voice-attachment-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File clipFile = File(
        '${tempDir.path}${Platform.pathSeparator}voice.m4a',
      );
      await clipFile.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalAttachment(
            peerAddress: 'ada.ygg',
            displayName: 'Ada',
            attachmentPath: clipFile.path,
            fileName: 'voice.m4a',
            mimeType: 'audio/mp4',
            type: ChatMessageType.voice,
            durationMs: 4200,
            sentAtMillis: 14,
          );

      final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      expect(messages, hasLength(1));
      expect(messages.single.type, ChatMessageType.voice);
      expect(messages.single.fileName, 'voice.m4a');
      expect(messages.single.durationMs, 4200);
      expect(messages.single.attachmentPath, clipFile.path);
      expect(messages.single.attachmentSizeBytes, 4);
      expect(messages.single.deliveryState, ChatMessageDeliveryState.delivered);
    },
  );

  test(
    'sending a large attachment falls back to placeholder and chunk signals',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final MemoryAttachmentTransferStore transferStore =
          MemoryAttachmentTransferStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(_friendSnapshot(_meshPeer)),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          attachmentTransferStoreProvider.overrideWithValue(transferStore),
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalAttachment(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            displayName: 'Ada',
            fileName: 'duzy.bin',
            mimeType: 'application/octet-stream',
            bytes: Uint8List.fromList(
              List<int>.filled(kInlineAttachmentTransportMaxBytes + 1024, 7),
            ),
            sentAtMillis: 22,
          );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      final Iterable<int> chunkIndexes = transport.sentSignals
          .where((signal) => signal.payload['type'] == 'message_chunk')
          .map((signal) => signal.payload['chunkIndex'] as int);
      for (final int chunkIndex in chunkIndexes) {
        await controller.receiveSignal(
          ZenSignal(
            type: ZenSignalType.messageChunkAck,
            sender: '200:1111:2222:3333:4444:5555:6666:7777',
            messageId: 'outgoing-22-200:1111:2222:3333:4444:5555:6666:7777',
            chunkIndex: chunkIndex,
          ),
          receivedAtMillis: 30 + chunkIndex,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final List<ChatMessage> messages = await timelineStore.load(
        '200:1111:2222:3333:4444:5555:6666:7777',
      );
      final OutgoingAttachmentTransfer? transfer = await transferStore
          .loadOutgoing(
            '200:1111:2222:3333:4444:5555:6666:7777',
            messages.single.id,
          );

      expect(messages.single.attachmentBytes, isNotNull);
      expect(messages.single.deliveryState, ChatMessageDeliveryState.delivered);
      expect(transfer, isNull);
      expect(
        transport.sentSignals.any(
          (signal) => signal.payload['type'] == 'message_placeholder',
        ),
        isTrue,
      );
      expect(
        transport.sentSignals.any(
          (signal) => signal.payload['type'] == 'message_chunk',
        ),
        isTrue,
      );
    },
  );

  test(
    'sending a large attachment from file path streams chunks without timeline bytes',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-path-attachment-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File payload = File(
        '${tempDir.path}${Platform.pathSeparator}duzy.bin',
      );
      await payload.writeAsBytes(
        List<int>.filled(kInlineAttachmentTransportMaxBytes + 1024, 7),
        flush: true,
      );
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final MemoryAttachmentTransferStore transferStore =
          MemoryAttachmentTransferStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(_friendSnapshot(_meshPeer)),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          attachmentTransferStoreProvider.overrideWithValue(transferStore),
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendLocalAttachment(
            peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
            displayName: 'Ada',
            fileName: 'duzy.bin',
            mimeType: 'application/octet-stream',
            attachmentPath: payload.path,
            sentAtMillis: 42,
          );
      const String messageId =
          'outgoing-42-200:1111:2222:3333:4444:5555:6666:7777';
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      final Set<int> ackedChunkIndexes = <int>{};
      for (int attempt = 0; attempt < 12; attempt += 1) {
        final Iterable<int> chunkIndexes = transport.sentSignals
            .where((signal) => signal.payload['type'] == 'message_chunk')
            .map((signal) => signal.payload['chunkIndex'] as int);
        for (final int chunkIndex in chunkIndexes) {
          if (!ackedChunkIndexes.add(chunkIndex)) {
            continue;
          }
          await controller.receiveSignal(
            ZenSignal(
              type: ZenSignalType.messageChunkAck,
              sender: '200:1111:2222:3333:4444:5555:6666:7777',
              messageId: messageId,
              chunkIndex: chunkIndex,
            ),
            receivedAtMillis: 60 + chunkIndex,
          );
        }
        final OutgoingAttachmentTransfer? remaining = await transferStore
            .loadOutgoing('200:1111:2222:3333:4444:5555:6666:7777', messageId);
        if (remaining == null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final List<ChatMessage> messages = await timelineStore.load(
        '200:1111:2222:3333:4444:5555:6666:7777',
      );

      expect(messages.single.attachmentBytes, isNull);
      expect(messages.single.attachmentPath, payload.path);
      expect(messages.single.deliveryState, ChatMessageDeliveryState.delivered);
      expect(
        transport.sentSignals.any(
          (signal) => signal.payload['type'] == 'message_placeholder',
        ),
        isTrue,
      );
      expect(
        transport.sentSignals.any(
          (signal) => signal.payload['type'] == 'message_chunk',
        ),
        isTrue,
      );
      expect(
        await transferStore.loadOutgoing(
          '200:1111:2222:3333:4444:5555:6666:7777',
          messageId,
        ),
        isNull,
      );
    },
  );

  test('large attachment prefers realtime transfer when available', () async {
    final MemorySignalTransport transport = MemorySignalTransport();
    final MemoryMessageTimelineStore timelineStore =
        MemoryMessageTimelineStore();
    final MemoryAttachmentTransferStore transferStore =
        MemoryAttachmentTransferStore();
    final _FakeRealtimeAttachmentTransferSession session =
        _FakeRealtimeAttachmentTransferSession();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        attachmentTransferStoreProvider.overrideWithValue(transferStore),
        signalTransportProvider.overrideWithValue(transport),
        realtimeAttachmentTransferFactoryProvider.overrideWithValue(
          ({required String transferId, required String remoteAddress}) =>
              session,
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
    );
    addTearDown(container.dispose);
    await transport.start();

    await container
        .read(socialHubControllerProvider.notifier)
        .sendLocalAttachment(
          peerAddress: '200:1111:2222:3333:4444:5555:6666:7777',
          displayName: 'Ada',
          fileName: 'duzy.bin',
          mimeType: 'application/octet-stream',
          bytes: Uint8List.fromList(
            List<int>.filled(kInlineAttachmentTransportMaxBytes + 1024, 7),
          ),
          sentAtMillis: 32,
        );
    await Future<void>.delayed(Duration.zero);

    final List<ChatMessage> messages = await timelineStore.load(
      '200:1111:2222:3333:4444:5555:6666:7777',
    );

    expect(session.sentBytes, isNotNull);
    expect(messages.single.deliveryState, ChatMessageDeliveryState.delivered);
    expect(
      transport.sentSignals.any(
        (signal) => signal.payload['type'] == 'message_placeholder',
      ),
      isTrue,
    );
    expect(
      transport.sentSignals.any(
        (signal) => signal.payload['type'] == 'message_chunk',
      ),
      isFalse,
    );
    expect(
      await transferStore.loadOutgoing(
        '200:1111:2222:3333:4444:5555:6666:7777',
        messages.single.id,
      ),
      isNull,
    );
  });

  test(
    'incoming inline attachment is persisted and previews the chat list',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-inline-incoming-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          supportDirectoryResolverProvider.overrideWithValue(
            () async => tempDir,
          ),
          socialHubSeedProvider.overrideWithValue(_seedWithAdaInvited()),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 1,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          messageId: 'file-1',
          content: '📎 raport.txt',
          messageType: ChatMessageType.file,
          fileName: 'raport.txt',
          mimeType: 'text/plain',
          attachmentSizeBytes: 3,
          attachmentData: 'aGVq',
        ),
        receivedAtMillis: 2,
      );

      final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      expect(messages.last.type, ChatMessageType.file);
      expect(messages.last.fileName, 'raport.txt');
      expect(messages.last.attachmentBytes, isNull);
      expect(messages.last.attachmentPath, isNotNull);
      expect(
        await container
            .read(mediaVaultProvider)
            .read(messages.last.attachmentPath!),
        utf8.encode('hej'),
      );
      await _expectSealed(
        messages.last.attachmentPath!,
        utf8.encode('hej'),
        hidden: <String>['raport', 'ada.ygg', _b64Name('ada.ygg')],
      );
      expect(
        container
            .read(socialHubControllerProvider)
            .acceptedFriends
            .single
            .lastMessagePreview,
        '📎 raport.txt',
      );
    },
  );

  test(
    'incoming call invite lands in inbox and timeline with kind label',
    () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(
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
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callInvite,
              sender: 'ada.ygg',
              displayName: 'Ada',
              content: 'video',
            ),
            receivedAtMillis: 9,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      final List<ChatMessage> thread = await timelineStore.load('ada.ygg');
      expect(state.inbox.first.type, InboxEntryType.callInvite);
      expect(state.inbox.first.body, contains('wideo'));
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.isIncoming, isTrue);
      expect(state.activeCall!.kind, CallInviteKind.video);
      expect(state.activeCall!.isCameraEnabled, isFalse);
      expect(thread.single.text, 'Przyszło zaproszenie do rozmowy wideo.');
    },
  );

  test('a remote video offer does not turn on this side\'s camera', () async {
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController()
          ..activeCallIdValue = 'call-privacy'
          ..activeKindValue = CallInviteKind.audio
          ..cameraEnabledValue = false;
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            activeCall: const CallSession(
              id: 'call-privacy',
              peerAddress: _peer,
              displayName: 'Ada',
              kind: CallInviteKind.audio,
              status: CallSessionStatus.active,
              startedAtMillis: 9,
              isIncoming: true,
              isCameraEnabled: false,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.callOffer,
            sender: _peer,
            callId: 'call-privacy',
            content: 'video',
            sessionDescription: <String, dynamic>{
              'type': 'offer',
              'sdp': 'v=0',
            },
          ),
          receivedAtMillis: 12,
        );

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.activeCall!.kind, CallInviteKind.video);
    expect(state.activeCall!.isCameraEnabled, isFalse);
    expect(callMedia.cameraEnabledValue, isFalse);
  });

  test(
    'accepting an incoming call uses pending WebRTC offer and activates session',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-1',
                peerAddress: peerAddress,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 5,
                isIncoming: true,
              ),
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
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
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: peerAddress,
              callId: 'call-1',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 6,
          );

      await container
          .read(socialHubControllerProvider.notifier)
          .acceptIncomingCall(peerAddress: peerAddress);

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(callMedia.acceptedIncomingCallId, 'call-1');
      expect(callMedia.acceptedRemoteAddress, peerAddress);
      expect(callMedia.acceptedDescription, <String, dynamic>{
        'type': 'offer',
        'sdp': 'v=0',
      });
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.status, CallSessionStatus.active);
      expect(state.activeCall!.isIncoming, isFalse);
    },
  );

  test(
    'simultaneous incoming glare keeps the preferred local outgoing call',
    () async {
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
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-100',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 10,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callInvite,
              sender: 'ada.ygg',
              callId: 'call-200',
              content: 'audio',
            ),
            receivedAtMillis: 11,
          );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: 'ada.ygg',
              callId: 'call-200',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 12,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.id, 'call-100');
      expect(
        transport.sentSignals.where(
          (signal) => signal.payload['type'] == 'busy',
        ),
        isEmpty,
      );
    },
  );

  test(
    'ending a call clears it locally even when the peer is unreachable',
    () async {
      final _UnreachableSignalTransport transport =
          _UnreachableSignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController()..activeCallIdValue = 'call-dead';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  _peer: FriendProfile(
                    address: _peer,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
              activeCall: const CallSession(
                id: 'call-dead',
                peerAddress: _peer,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.active,
                startedAtMillis: 10,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .endActiveCall(peerAddress: _peer);

      expect(transport.sendAttempts, greaterThan(0));
      expect(callMedia.closed, isTrue);
      expect(container.read(socialHubControllerProvider).activeCall, isNull);
    },
  );

  test(
    'declining a call clears it locally even when the peer is unreachable',
    () async {
      final _UnreachableSignalTransport transport =
          _UnreachableSignalTransport();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  _peer: FriendProfile(
                    address: _peer,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                },
              ),
              activeCall: const CallSession(
                id: 'call-dead-2',
                peerAddress: _peer,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 10,
                isIncoming: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .declineIncomingCall(peerAddress: _peer);

      expect(container.read(socialHubControllerProvider).activeCall, isNull);
    },
  );

  test('an unanswered incoming call expires on the ringing deadline', () async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await transport.start();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(
          _FakeCallMediaSessionController(),
        ),
        callRingingWaitTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 40),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
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

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.callOffer,
            sender: _peer,
            callId: 'call-ghost',
            content: 'audio',
            sessionDescription: <String, dynamic>{
              'type': 'offer',
              'sdp': 'v=0',
            },
          ),
          receivedAtMillis: 11,
        );

    expect(
      container.read(socialHubControllerProvider).activeCall,
      isNotNull,
      reason: 'the offer should raise a ringing session',
    );

    await Future<void>.delayed(const Duration(milliseconds: 160));

    expect(
      container.read(socialHubControllerProvider).activeCall,
      isNull,
      reason: 'nobody answered, so the ghost popup must clear itself',
    );
    expect(
      transport.sentSignals
          .where((signal) => signal.payload['type'] == 'call_decline')
          .length,
      1,
      reason: 'the caller has to learn the call was missed',
    );
  });

  test(
    'an incoming call does not raise a system notification while it is ringing',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
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
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
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
                  _peer: FriendProfile(
                    address: _peer,
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

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callInvite,
              sender: _peer,
              callId: 'call-notify',
              content: 'audio',
            ),
            receivedAtMillis: 11,
          );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: _peer,
              callId: 'call-notify',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 12,
          );

      expect(
        notifications.activeNotifications,
        isEmpty,
        reason:
            'the popup is the ringing UI; the shade waits for a missed call',
      );
      expect(
        container.read(socialHubControllerProvider).activeCall?.status,
        CallSessionStatus.ringing,
      );
    },
  );

  test(
    'an incoming call does not raise a system notification while the app is on screen',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
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
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  _peer: FriendProfile(
                    address: _peer,
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

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callInvite,
              sender: _peer,
              callId: 'call-heads-up',
              content: 'audio',
            ),
            receivedAtMillis: 11,
          );

      expect(notifications.activeNotifications, isEmpty);
      expect(
        container.read(socialHubControllerProvider).activeCall?.status,
        CallSessionStatus.ringing,
      );
    },
  );

  test(
    'the peer hanging up replaces the ringing notification with a missed call',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
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
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
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
                  _peer: FriendProfile(
                    address: _peer,
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

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callInvite,
          sender: _peer,
          callId: 'call-cancelled',
          content: 'audio',
        ),
        receivedAtMillis: 11,
      );
      expect(
        notifications.activeNotifications,
        isEmpty,
        reason: 'ringing itself must not occupy the shade',
      );

      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callEnd,
          sender: _peer,
          callId: 'call-cancelled',
          content: 'audio',
        ),
        receivedAtMillis: 12,
      );

      final List<RuntimeSystemNotification> callNotifications = notifications
          .activeNotifications
          .where(
            (RuntimeSystemNotification entry) =>
                entry.category == RuntimeSystemNotificationCategory.call,
          )
          .toList(growable: false);
      expect(callNotifications, hasLength(1));
      expect(
        callNotifications.single.isRingingCall,
        isFalse,
        reason: 'the missed-call note must be dismissible',
      );
      expect(callNotifications.single.title, contains('Nieodebrane'));
      expect(callNotifications.single.slotKey, callNotificationSlotKey(_peer));
      expect(container.read(socialHubControllerProvider).activeCall, isNull);
    },
  );

  test(
    'an unanswered call after the popup still leaves a missed-call notification',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      final MemorySignalTransport transport = MemorySignalTransport();
      await transport.start();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          runtimeSystemNotificationServiceProvider.overrideWithValue(
            notifications,
          ),
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
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
                  _peer: FriendProfile(
                    address: _peer,
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

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callInvite,
          sender: _peer,
          callId: 'call-popup-test',
          content: 'audio',
        ),
        receivedAtMillis: 11,
      );
      expect(notifications.activeNotifications, isEmpty);

      await controller.markCallPopupPresented(_peer, 'call-popup-test');
      expect(notifications.activeNotifications, isEmpty);

      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callEnd,
          sender: _peer,
          callId: 'call-popup-test',
          content: 'audio',
        ),
        receivedAtMillis: 12,
      );

      expect(
        notifications.activeNotifications.single.title,
        contains('Nieodebrane'),
      );
      expect(container.read(socialHubControllerProvider).activeCall, isNull);
    },
  );

  test('a re-ringed invite leaves an answered call answered', () async {
    final MemoryMessageTimelineStore timelineStore =
        MemoryMessageTimelineStore();
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController();
    final MemorySignalTransport transport = MemorySignalTransport();
    await transport.start();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
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

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.callInvite,
        sender: _peer,
        callId: 'call-rering',
        content: 'audio',
      ),
      receivedAtMillis: 11,
    );
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.callOffer,
        sender: _peer,
        callId: 'call-rering',
        content: 'audio',
        sessionDescription: <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      ),
      receivedAtMillis: 12,
    );
    await controller.acceptIncomingCall(peerAddress: _peer);
    expect(callMedia.acceptedIncomingCallId, 'call-rering');
    expect(
      container.read(socialHubControllerProvider).activeCall!.isIncoming,
      isFalse,
    );

    final int messagesAfterAccept = (await timelineStore.load(_peer)).length;

    // The caller keeps re-sending its invite until it sees the answer.
    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.callInvite,
        sender: _peer,
        callId: 'call-rering',
        content: 'audio',
      ),
      receivedAtMillis: 13,
    );

    final CallSession? session = container
        .read(socialHubControllerProvider)
        .activeCall;
    expect(session, isNotNull);
    expect(
      session!.isIncoming,
      isFalse,
      reason: 'a re-ring must not drop the user back into the accept overlay',
    );
    expect(
      await timelineStore.load(_peer),
      hasLength(messagesAfterAccept),
      reason: 'the repeat has nothing new to say in the conversation',
    );
  });

  test('a re-ringed invite re-sends a lost answer', () async {
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController()
          ..activeCallIdValue = 'call-answer-lost';
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            // Answered here, but the caller is still inviting: its copy of the
            // answer never arrived.
            activeCall: const CallSession(
              id: 'call-answer-lost',
              peerAddress: _peer,
              displayName: 'Ada',
              kind: CallInviteKind.audio,
              status: CallSessionStatus.ringing,
              startedAtMillis: 10,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.callInvite,
            sender: _peer,
            callId: 'call-answer-lost',
            content: 'audio',
          ),
          receivedAtMillis: 30,
        );

    expect(callMedia.resendAnswerCallIds, <String>['call-answer-lost']);
    expect(
      container.read(socialHubControllerProvider).activeCall!.isIncoming,
      isFalse,
    );
  });

  test('a repeated hangup is applied once', () async {
    final MemoryMessageTimelineStore timelineStore =
        MemoryMessageTimelineStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        callMediaSessionControllerProvider.overrideWithValue(
          _FakeCallMediaSessionController(),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            activeCall: const CallSession(
              id: 'call-repeat-end',
              peerAddress: _peer,
              displayName: 'Ada',
              kind: CallInviteKind.audio,
              status: CallSessionStatus.active,
              startedAtMillis: 10,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    // Teardown signals are re-sent, so the same hangup arrives more than once.
    for (int attempt = 0; attempt < 3; attempt += 1) {
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callEnd,
          sender: _peer,
          callId: 'call-repeat-end',
          content: 'audio',
        ),
        receivedAtMillis: 20 + attempt,
      );
    }

    expect(container.read(socialHubControllerProvider).activeCall, isNull);
    expect(
      (await timelineStore.load(_peer))
          .where((ChatMessage message) => message.text.contains('zakończył'))
          .toList(growable: false),
      hasLength(1),
    );
  });

  test('a stale hangup does not take down the next call', () async {
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            activeCall: const CallSession(
              id: 'call-current',
              peerAddress: _peer,
              displayName: 'Ada',
              kind: CallInviteKind.audio,
              status: CallSessionStatus.active,
              startedAtMillis: 10,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.callEnd,
            sender: _peer,
            callId: 'call-previous',
            content: 'audio',
          ),
          receivedAtMillis: 21,
        );

    expect(
      container.read(socialHubControllerProvider).activeCall?.id,
      'call-current',
    );
    expect(callMedia.closed, isFalse);
  });

  test(
    'a missed call leaves no system notification while the app is on screen',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
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
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  _peer: FriendProfile(
                    address: _peer,
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

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callInvite,
          sender: _peer,
          callId: 'call-open-app',
          content: 'audio',
        ),
        receivedAtMillis: 11,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callEnd,
          sender: _peer,
          callId: 'call-open-app',
          content: 'audio',
        ),
        receivedAtMillis: 12,
      );

      expect(
        notifications.activeNotifications,
        isEmpty,
        reason: 'the open app carries the whole call in its own UI',
      );
      expect(container.read(socialHubControllerProvider).activeCall, isNull);
    },
  );

  test(
    'simultaneous incoming glare can switch to the remote call and auto-accept it',
    () async {
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController()
            ..activeCallIdValue = 'call-900'
            ..activeKindValue = CallInviteKind.audio;
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-900',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 10,
              ),
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
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callInvite,
              sender: 'ada.ygg',
              callId: 'call-100',
              content: 'video',
            ),
            receivedAtMillis: 11,
          );
      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: 'ada.ygg',
              callId: 'call-100',
              content: 'video',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 12,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(callMedia.closed, isTrue);
      expect(callMedia.acceptedIncomingCallId, 'call-100');
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.id, 'call-100');
      expect(state.activeCall!.status, CallSessionStatus.active);
      expect(state.activeCall!.kind, CallInviteKind.video);
    },
  );

  test(
    'accepting before the offer arrives auto-answers once the offer is received',
    () async {
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-pending-offer',
                peerAddress: peerAddress,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 5,
                isIncoming: true,
              ),
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
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

      await container
          .read(socialHubControllerProvider.notifier)
          .acceptIncomingCall(peerAddress: peerAddress);
      expect(callMedia.acceptedIncomingCallId, isNull);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: peerAddress,
              callId: 'call-pending-offer',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 6,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(callMedia.acceptedIncomingCallId, 'call-pending-offer');
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.status, CallSessionStatus.active);
      expect(state.activeCall!.isIncoming, isFalse);
    },
  );

  test(
    'accepting without an offer asks the caller to resend the SDP offer',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-missing-offer',
                peerAddress: peerAddress,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 5,
                isIncoming: true,
              ),
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
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

      await container
          .read(socialHubControllerProvider.notifier)
          .acceptIncomingCall(peerAddress: peerAddress);

      expect(callMedia.acceptedIncomingCallId, isNull);
      expect(
        transport.sentSignals.any(
          (signal) =>
              signal.payload['type'] == 'call_offer_request' &&
              signal.payload['callId'] == 'call-missing-offer',
        ),
        isTrue,
      );

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: peerAddress,
              callId: 'call-missing-offer',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 6,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(callMedia.acceptedIncomingCallId, 'call-missing-offer');
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.status, CallSessionStatus.active);
    },
  );

  test('offer wait timeout hangs up and clears the pending call', () async {
    final MemorySignalTransport transport = MemorySignalTransport();
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController();
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        callOfferWaitTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 50),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            activeCall: const CallSession(
              id: 'call-expired-offer',
              peerAddress: peerAddress,
              displayName: 'Ada',
              kind: CallInviteKind.audio,
              status: CallSessionStatus.ringing,
              startedAtMillis: 5,
              isIncoming: true,
            ),
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                peerAddress: FriendProfile(
                  address: peerAddress,
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

    await container
        .read(socialHubControllerProvider.notifier)
        .acceptIncomingCall(peerAddress: peerAddress);
    expect(callMedia.acceptedIncomingCallId, isNull);

    await Future<void>.delayed(const Duration(milliseconds: 300));

    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.activeCall, isNull);
    expect(callMedia.closed, isTrue);
    expect(
      transport.sentSignals.any(
        (signal) =>
            signal.payload['type'] == 'hangup' &&
            signal.payload['callId'] == 'call-expired-offer',
      ),
      isTrue,
    );
  });

  test(
    'caller resends the stored offer when the callee asks for it again',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController();
      const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-resend',
                peerAddress: peerAddress,
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 5,
              ),
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  peerAddress: FriendProfile(
                    address: peerAddress,
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

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOfferRequest,
              sender: peerAddress,
              callId: 'call-resend',
              content: 'audio',
            ),
            receivedAtMillis: 6,
          );

      expect(callMedia.resendOfferCallIds, <String>['call-resend']);
      // The re-request must not disturb the outgoing session state.
      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.id, 'call-resend');
      expect(state.activeCall!.isIncoming, isFalse);
    },
  );

  test('callee ignores an offer request for a call it did not place', () async {
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController();
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            activeCall: const CallSession(
              id: 'call-incoming',
              peerAddress: peerAddress,
              displayName: 'Ada',
              kind: CallInviteKind.audio,
              status: CallSessionStatus.ringing,
              startedAtMillis: 5,
              isIncoming: true,
            ),
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                peerAddress: FriendProfile(
                  address: peerAddress,
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

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.callOfferRequest,
            sender: peerAddress,
            callId: 'call-incoming',
            content: 'audio',
          ),
          receivedAtMillis: 6,
        );

    expect(callMedia.resendOfferCallIds, isEmpty);
  });

  test(
    'remote answer applies WebRTC description to the active call session',
    () async {
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController()
            ..activeCallIdValue = 'call-answer'
            ..activeKindValue = CallInviteKind.audio;
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-answer',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 7,
              ),
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
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callAnswer,
              sender: 'ada.ygg',
              callId: 'call-answer',
              content: 'video',
              sessionDescription: <String, dynamic>{
                'type': 'answer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 8,
          );

      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(callMedia.remoteAnswerDescription, <String, dynamic>{
        'type': 'answer',
        'sdp': 'v=0',
      });
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.kind, CallInviteKind.video);
      expect(state.activeCall!.isIncoming, isFalse);
    },
  );

  test(
    'busy signal closes the current media session and clears the active call',
    () async {
      final _FakeCallMediaSessionController callMedia =
          _FakeCallMediaSessionController()
            ..activeCallIdValue = 'call-busy'
            ..activeKindValue = CallInviteKind.audio;
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-busy',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.ringing,
                startedAtMillis: 9,
              ),
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
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callBusy,
              sender: 'ada.ygg',
              callId: 'call-busy',
              content: 'audio',
            ),
            receivedAtMillis: 10,
          );

      expect(container.read(socialHubControllerProvider).activeCall, isNull);
      expect(callMedia.closed, isTrue);
    },
  );

  test('active call controls toggle mute, speaker, and camera state', () async {
    final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore();
    final _FakeCallMediaSessionController callMedia =
        _FakeCallMediaSessionController()
          ..activeKindValue = CallInviteKind.video
          ..activeCallIdValue = 'call-controls';
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        callMediaSessionControllerProvider.overrideWithValue(callMedia),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            activeCall: const CallSession(
              id: 'call-controls',
              peerAddress: 'ada.ygg',
              displayName: 'Ada',
              kind: CallInviteKind.video,
              status: CallSessionStatus.active,
              startedAtMillis: 9,
              isCameraEnabled: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.toggleActiveCallMute();
    await controller.toggleActiveCallSpeaker();
    await controller.toggleActiveCallCamera();

    final SocialHubState state = container.read(socialHubControllerProvider);
    final CallSession persisted = (await snapshotStore.load())!.activeCall!;
    expect(state.activeCall, isNotNull);
    expect(state.activeCall!.isMuted, isTrue);
    expect(state.activeCall!.isSpeakerOn, isTrue);
    expect(state.activeCall!.isCameraEnabled, isFalse);
    expect(callMedia.mutedValue, isTrue);
    expect(callMedia.speakerOnValue, isTrue);
    expect(callMedia.cameraEnabledValue, isFalse);
    expect(persisted.isMuted, isTrue);
    expect(persisted.isSpeakerOn, isTrue);
    expect(persisted.isCameraEnabled, isFalse);
  });

  test(
    'remote decline and end signals close the matching active call',
    () async {
      final ProviderContainer declineContainer = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-2',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.video,
                status: CallSessionStatus.active,
                startedAtMillis: 6,
              ),
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
        ],
      );
      addTearDown(declineContainer.dispose);

      await declineContainer
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callDecline,
              sender: 'ada.ygg',
              callId: 'call-2',
              content: 'video',
            ),
            receivedAtMillis: 8,
          );
      expect(
        declineContainer.read(socialHubControllerProvider).activeCall,
        isNull,
      );

      final ProviderContainer endContainer = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: const CallSession(
                id: 'call-3',
                peerAddress: 'ada.ygg',
                displayName: 'Ada',
                kind: CallInviteKind.audio,
                status: CallSessionStatus.active,
                startedAtMillis: 9,
              ),
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
        ],
      );
      addTearDown(endContainer.dispose);

      await endContainer
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callEnd,
              sender: 'ada.ygg',
              callId: 'call-3',
              content: 'audio',
            ),
            receivedAtMillis: 10,
          );
      expect(endContainer.read(socialHubControllerProvider).activeCall, isNull);
    },
  );

  test(
    'incoming chunked attachment assembles and acknowledges chunks',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-chunked-incoming-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final MemoryAttachmentTransferStore transferStore =
          MemoryAttachmentTransferStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          attachmentTransferStoreProvider.overrideWithValue(transferStore),
          signalTransportProvider.overrideWithValue(transport),
          supportDirectoryResolverProvider.overrideWithValue(
            () async => tempDir,
          ),
          socialHubSeedProvider.overrideWithValue(_seedWithAdaInvited()),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 1,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          messageId: 'file-1',
          content: '📎 raport.txt',
          messageType: ChatMessageType.file,
          fileName: 'raport.txt',
          mimeType: 'text/plain',
          attachmentSizeBytes: 4,
          attachmentTransferBytes: 4,
          chunkCount: 2,
          isPlaceholder: true,
        ),
        receivedAtMillis: 2,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.messageChunk,
          sender: 'ada.ygg',
          messageId: 'file-1',
          content: '📎 raport.txt',
          messageType: ChatMessageType.file,
          fileName: 'raport.txt',
          mimeType: 'text/plain',
          attachmentTransferBytes: 4,
          chunkCount: 2,
          chunkIndex: 0,
          chunkData: 'AQI=',
        ),
        receivedAtMillis: 3,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.messageChunk,
          sender: 'ada.ygg',
          messageId: 'file-1',
          content: '📎 raport.txt',
          messageType: ChatMessageType.file,
          fileName: 'raport.txt',
          mimeType: 'text/plain',
          attachmentTransferBytes: 4,
          chunkCount: 2,
          chunkIndex: 1,
          chunkData: 'AwQ=',
        ),
        receivedAtMillis: 4,
      );

      final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      expect(messages.last.fileName, 'raport.txt');
      expect(messages.last.attachmentBytes, isNull);
      expect(messages.last.attachmentPath, isNotNull);
      expect(
        await container
            .read(mediaVaultProvider)
            .read(messages.last.attachmentPath!),
        <int>[1, 2, 3, 4],
      );
      await _expectSealed(
        messages.last.attachmentPath!,
        <int>[1, 2, 3, 4],
        hidden: <String>['raport', 'ada.ygg', _b64Name('ada.ygg')],
      );
      expect(messages.last.deliveryState, ChatMessageDeliveryState.none);
      expect(await transferStore.loadIncoming('ada.ygg', 'file-1'), isNull);
      expect(
        transport.sentSignals.where(
          (signal) => signal.payload['type'] == 'message_chunk_ack',
        ),
        hasLength(2),
      );
    },
  );

  test(
    'incoming realtime transfer offer completes attachment payload',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-realtime-incoming-',
      );
      addTearDown(() async {
        try {
          await tempDir.delete(recursive: true);
        } on PathAccessException {
          // Windows can briefly keep the transferred file locked; the temp
          // directory is cleaned up by the OS anyway.
        }
      });
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final _FakeRealtimeAttachmentTransferSession session =
          _FakeRealtimeAttachmentTransferSession(
            incomingBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          supportDirectoryResolverProvider.overrideWithValue(
            () async => tempDir,
          ),
          realtimeAttachmentTransferFactoryProvider.overrideWithValue(
            ({required String transferId, required String remoteAddress}) =>
                session,
          ),
          socialHubSeedProvider.overrideWithValue(
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
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.transferOffer,
              sender: 'ada.ygg',
              messageId: 'file-2',
              content: '📎 duzy.bin',
              messageType: ChatMessageType.file,
              fileName: 'duzy.bin',
              mimeType: 'application/octet-stream',
              attachmentSizeBytes: 4,
              attachmentTransferBytes: 4,
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 10,
          );

      // The realtime transfer finishes asynchronously (file writes on a
      // background runner), so poll instead of relying on a fixed delay.
      List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      for (
        int attempt = 0;
        attempt < 100 &&
            (messages.isEmpty || messages.single.attachmentPath == null);
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        messages = await timelineStore.load('ada.ygg');
      }
      expect(session.acceptedDescription?['type'], 'offer');
      expect(messages.single.fileName, 'duzy.bin');
      expect(messages.single.attachmentBytes, isNull);
      expect(messages.single.attachmentPath, isNotNull);
      expect(
        await container
            .read(mediaVaultProvider)
            .read(messages.single.attachmentPath!),
        <int>[1, 2, 3, 4],
      );
      await _expectSealed(
        messages.single.attachmentPath!,
        <int>[1, 2, 3, 4],
        hidden: <String>['duzy', 'ada.ygg', _b64Name('ada.ygg')],
      );
      expect(messages.single.deliveryState, ChatMessageDeliveryState.none);
    },
  );

  test('message ack marks outgoing routable message as delivered', () async {
    final MemorySignalTransport transport = MemorySignalTransport();
    final MemoryMessageTimelineStore timelineStore =
        MemoryMessageTimelineStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        signalTransportProvider.overrideWithValue(transport),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
    );
    addTearDown(container.dispose);
    await transport.start();

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    const String peerAddress = '200:1111:2222:3333:4444:5555:6666:7777';
    await controller.sendLocalMessage(
      peerAddress: peerAddress,
      displayName: 'Ada',
      text: 'Hej',
      sentAtMillis: 10,
    );

    List<ChatMessage> messages = await timelineStore.load(peerAddress);
    expect(messages.single.deliveryState, ChatMessageDeliveryState.sent);

    await controller.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.ack,
        sender: peerAddress,
        messageId: 'outgoing-10-200:1111:2222:3333:4444:5555:6666:7777',
        content: 'message',
      ),
      receivedAtMillis: 11,
    );

    messages = await timelineStore.load(peerAddress);
    expect(messages.single.deliveryState, ChatMessageDeliveryState.delivered);
  });

  test('incoming routable message triggers a message ack reply', () async {
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
        signalTransportProvider.overrideWithValue(transport),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                  address: '200:1111:2222:3333:4444:5555:6666:7777',
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
    await transport.start();

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.message,
            sender: '200:1111:2222:3333:4444:5555:6666:7777',
            messageId: 'm-1',
            content: 'Hej',
          ),
          receivedAtMillis: 3,
        );
    await Future<void>.delayed(Duration.zero);

    expect(transport.sentSignals.last.payload, <String, dynamic>{
      'type': 'message_ack',
      'msgId': 'm-1',
    });
  });

  test(
    'message read signal marks the matching outgoing message as read',
    () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore(<String, List<ChatMessage>>{
            'ada.ygg': const <ChatMessage>[
              ChatMessage(
                id: 'm-1',
                sender: 'self',
                text: 'Hej',
                sentAtMillis: 1,
                direction: ChatMessageDirection.outgoing,
                deliveryState: ChatMessageDeliveryState.delivered,
              ),
            ],
          });
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(
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
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.messageRead,
              sender: 'ada.ygg',
              messageId: 'm-1',
            ),
            receivedAtMillis: 5,
          );

      final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      expect(messages.single.readAtMillis, 5);
    },
  );

  test('opening a conversation can clear unread state persistently', () async {
    final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore();
    final MemoryMessageTimelineStore timelineStore = MemoryMessageTimelineStore(
      <String, List<ChatMessage>>{
        '200:1111:2222:3333:4444:5555:6666:7777': const <ChatMessage>[
          ChatMessage(
            id: 'incoming-1',
            sender: '200:1111:2222:3333:4444:5555:6666:7777',
            text: 'Hej',
            sentAtMillis: 1,
            direction: ChatMessageDirection.incoming,
          ),
          ChatMessage(
            id: 'incoming-2',
            sender: '200:1111:2222:3333:4444:5555:6666:7777',
            text: 'Daj znac jak wejdziesz.',
            sentAtMillis: 2,
            direction: ChatMessageDirection.incoming,
          ),
        ],
      },
    );
    final MemorySignalTransport transport = MemorySignalTransport();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
        signalTransportProvider.overrideWithValue(transport),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 1,
              capturedAtMillis: 0,
            ),
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                '200:1111:2222:3333:4444:5555:6666:7777': FriendProfile(
                  address: '200:1111:2222:3333:4444:5555:6666:7777',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                  unreadCount: 3,
                ),
              },
            ),
            inbox: <InboxEntry>[],
            pendingSignalCount: 0,
            backgroundAlerts: <InboxEntry>[],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(socialHubControllerProvider.notifier)
        .markConversationRead('200:1111:2222:3333:4444:5555:6666:7777');

    final SocialHubState state = container.read(socialHubControllerProvider);
    final List<ChatMessage> messages = await timelineStore.load(
      '200:1111:2222:3333:4444:5555:6666:7777',
    );
    expect(state.acceptedFriends.single.unreadCount, 0);
    expect((await snapshotStore.load())!.acceptedFriends.single.unreadCount, 0);
    expect(transport.sentSignals.last.payload, <String, dynamic>{
      'type': 'message_read',
      'msgId': 'incoming-2',
    });
    expect(messages.last.readAtMillis, isNotNull);
  });

  test(
    'active conversation does not create unread drift for live messages',
    () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.foregroundFocused,
                generation: 1,
                capturedAtMillis: 0,
              ),
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  'ada.ygg': FriendProfile(
                    address: 'ada.ygg',
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                    unreadCount: 1,
                  ),
                },
              ),
              inbox: <InboxEntry>[],
              pendingSignalCount: 0,
              backgroundAlerts: <InboxEntry>[],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.enterConversation('ada.ygg');
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          displayName: 'Ada',
          content: 'Juz pisze w otwartym czacie.',
        ),
        receivedAtMillis: 5,
      );

      final SocialHubState state = container.read(socialHubControllerProvider);
      final List<ChatMessage> messages = await timelineStore.load('ada.ygg');
      expect(state.acceptedFriends.single.unreadCount, 0);
      expect(messages.single.text, 'Juz pisze w otwartym czacie.');
    },
  );

  test('presence decay marks stale peers offline and keeps when they were last '
      'open', () async {
    final MemorySocialSnapshotStore snapshotStore = MemorySocialSnapshotStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                  isOnline: true,
                  lastPresenceAtMillis: 10,
                  presence: PeerPresence.online,
                  presenceAtMillis: 10,
                  lastOpenedAtMillis: 10,
                  lastActivityLabel: '08:41',
                ),
              },
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(socialHubControllerProvider.notifier)
        .decayPresence(
          offlineAfter: const Duration(milliseconds: 20),
          foregroundFor: const Duration(milliseconds: 10),
          nowMillis: 40,
        );

    final FriendProfile friend = container
        .read(socialHubControllerProvider)
        .friends['ada.ygg']!;
    expect(friend.isOnline, isFalse);
    expect(friend.presence, PeerPresence.offline);
    expect(friend.lastOpenedAtMillis, 10);
    // The chat list keeps the time of the last message.
    expect(friend.lastActivityLabel, '08:41');
    final FriendProfile stored =
        (await snapshotStore.load())!.friends['ada.ygg']!;
    expect(stored.presence, PeerPresence.offline);
    expect(stored.lastOpenedAtMillis, 10);
  });

  test(
    'inbox entries can be dismissed individually and cleared in bulk',
    () async {
      final MemorySocialSnapshotStore snapshotStore =
          MemorySocialSnapshotStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(snapshotStore),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
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
        ],
      );
      addTearDown(container.dispose);

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          messageId: 'm-1',
          content: 'Pierwsza',
        ),
        receivedAtMillis: 1,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          messageId: 'm-2',
          content: 'Druga',
        ),
        receivedAtMillis: 2,
      );

      final SocialHubState seeded = container.read(socialHubControllerProvider);
      expect(seeded.inbox, hasLength(2));

      final String firstId = seeded.inbox.last.id;
      await controller.dismissInboxEntry(firstId);
      final SocialHubState afterDismiss = container.read(
        socialHubControllerProvider,
      );
      expect(afterDismiss.inbox, hasLength(1));
      expect(afterDismiss.inbox.single.id, isNot(firstId));

      await controller.clearInbox();
      final SocialHubState afterClear = container.read(
        socialHubControllerProvider,
      );
      expect(afterClear.inbox, isEmpty);
      expect((await snapshotStore.load())!.inbox, isEmpty);
    },
  );

  test(
    'an outgoing ringing call re-sends the invite until the ringing deadline',
    () async {
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
          signalTransportProvider.overrideWithValue(transport),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(
            const Duration(milliseconds: 400),
          ),
          callReRingIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 40),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  _peer: FriendProfile(
                    address: _peer,
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
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .sendCallInvite(peerAddress: _peer, kind: CallInviteKind.audio);

      int sentInvites() => transport.sentSignals
          .where((signal) => signal.payload['type'] == 'call_invite')
          .length;

      expect(sentInvites(), 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        sentInvites(),
        greaterThan(1),
        reason: 'the invite is re-sent while the call keeps ringing',
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        container.read(socialHubControllerProvider).activeCall,
        isNull,
        reason: 'the ringing deadline is the hard stop for re-ringing',
      );
      final int sentAfterTimeout = sentInvites();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        sentInvites(),
        sentAfterTimeout,
        reason: 're-ringing stops together with the ringing timeout',
      );
    },
  );

  test('a declined outgoing call stops re-sending the invite', () async {
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
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(
          _FakeCallMediaSessionController(),
        ),
        callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
        callReRingIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 40),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
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
    await transport.start();

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.sendCallInvite(
      peerAddress: _peer,
      kind: CallInviteKind.audio,
    );

    int sentInvites() => transport.sentSignals
        .where((signal) => signal.payload['type'] == 'call_invite')
        .length;

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sentInvites(), greaterThan(1));

    await controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.callDecline,
        sender: _peer,
        callId: container.read(socialHubControllerProvider).activeCall!.id,
        content: 'audio',
      ),
      receivedAtMillis: 12,
    );
    expect(container.read(socialHubControllerProvider).activeCall, isNull);

    final int sentAfterDecline = sentInvites();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      sentInvites(),
      sentAfterDecline,
      reason: 'a declined call must not keep re-ringing',
    );
  });

  test('an answered outgoing call stops re-sending the invite', () async {
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
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(
          _FakeCallMediaSessionController(),
        ),
        callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
        callReRingIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 40),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _peer: FriendProfile(
                  address: _peer,
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
    await transport.start();

    final SocialHubController controller = container.read(
      socialHubControllerProvider.notifier,
    );
    await controller.sendCallInvite(
      peerAddress: _peer,
      kind: CallInviteKind.audio,
    );

    int sentInvites() => transport.sentSignals
        .where((signal) => signal.payload['type'] == 'call_invite')
        .length;

    await controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.callAccept,
        sender: _peer,
        callId: container.read(socialHubControllerProvider).activeCall!.id,
        content: 'audio',
      ),
      receivedAtMillis: 12,
    );
    expect(
      container.read(socialHubControllerProvider).activeCall?.status,
      CallSessionStatus.active,
    );

    final int sentAfterAccept = sentInvites();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      sentInvites(),
      sentAfterAccept,
      reason: 'an answered call must not keep re-ringing',
    );
  });

  test(
    'an incoming call that rings out leaves a missed-call notification',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          signalTransportProvider.overrideWithValue(transport),
          runtimeSystemNotificationServiceProvider.overrideWithValue(
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(
            const Duration(milliseconds: 40),
          ),
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
                  _peer: FriendProfile(
                    address: _peer,
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
      await transport.start();

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callOffer,
              sender: _peer,
              callId: 'call-missed',
              content: 'audio',
              sessionDescription: <String, dynamic>{
                'type': 'offer',
                'sdp': 'v=0',
              },
            ),
            receivedAtMillis: 11,
          );

      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(
        container.read(socialHubControllerProvider).activeCall,
        isNull,
        reason: 'nobody answered, so the ringing session expires',
      );
      final List<RuntimeSystemNotification> callNotifications = notifications
          .activeNotifications
          .where(
            (RuntimeSystemNotification entry) =>
                entry.category == RuntimeSystemNotificationCategory.call,
          )
          .toList(growable: false);
      expect(callNotifications, hasLength(1));
      expect(callNotifications.single.title, contains('Nieodebrane'));
      expect(callNotifications.single.isRingingCall, isFalse);
      expect(callNotifications.single.slotKey, callNotificationSlotKey(_peer));
    },
  );

  test(
    'a call end without a ringing call leaves no missed-call notification',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
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
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: const <String, FriendProfile>{
                  _peer: FriendProfile(
                    address: _peer,
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

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.callEnd,
              sender: _peer,
              callId: 'call-never-rang',
              content: 'audio',
            ),
            receivedAtMillis: 12,
          );

      expect(
        notifications.activeNotifications.where(
          (RuntimeSystemNotification entry) =>
              entry.category == RuntimeSystemNotificationCategory.call,
        ),
        isEmpty,
        reason: 'a missed call needs an actual ringing session that ended',
      );
    },
  );

  test(
    'a replayed queued invite rings again without a missed-call notification',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
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
            notifications,
          ),
          callMediaSessionControllerProvider.overrideWithValue(
            _FakeCallMediaSessionController(),
          ),
          callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
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
                  _peer: FriendProfile(
                    address: _peer,
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

      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.callInvite,
          sender: _peer,
          callId: 'call-replayed',
          content: 'audio',
        ),
        receivedAtMillis: 11,
      );
      expect(
        container.read(socialHubControllerProvider).pendingSignalCount,
        1,
        reason: 'a background invite is queued, not applied',
      );

      await controller.setLifecycle(
        const LifecycleSnapshot(
          visibility: AppVisibilityState.foregroundFocused,
          generation: 2,
          capturedAtMillis: 1,
        ),
      );

      expect(
        container.read(socialHubControllerProvider).activeCall?.status,
        CallSessionStatus.ringing,
        reason: 'the replayed invite rings after the flush',
      );
      expect(
        notifications.activeNotifications.where(
          (RuntimeSystemNotification entry) =>
              entry.title.contains('Nieodebrane'),
        ),
        isEmpty,
        reason: 'a replay alone is not a missed call',
      );
    },
  );
}

/// Routable peer whose mesh route is dead: every send throws, exactly like the
/// native bridge does when there is no path to the peer.
const String _peer = '200:1111:2222:3333:4444:5555:6666:7777';

final class _UnreachableSignalTransport implements SignalTransport {
  int sendAttempts = 0;

  @override
  Stream<SignalTransportFrame> get frames =>
      const Stream<SignalTransportFrame>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    sendAttempts += 1;
    throw StateError('no route to $remoteAddress');
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

final class _FakeCallMediaSessionController extends CallMediaSessionController {
  String? startedOutgoingCallId;
  String? startedOutgoingRemoteAddress;
  String? acceptedIncomingCallId;
  String? acceptedRemoteAddress;
  Map<String, dynamic>? acceptedDescription;
  Map<String, dynamic>? remoteOfferDescription;
  Map<String, dynamic>? remoteAnswerDescription;
  final List<String> resendOfferCallIds = <String>[];
  final List<String> resendAnswerCallIds = <String>[];
  bool resendOfferResult = true;
  bool mutedValue = false;
  bool speakerOnValue = false;
  bool cameraEnabledValue = true;
  bool closed = false;
  String? activeCallIdValue;
  String? remoteAddressValue;
  CallInviteKind? activeKindValue;
  CallMediaStatusListener? _onStatusChanged;
  CallMediaErrorListener? _onError;

  @override
  String? get activeCallId => activeCallIdValue;

  @override
  CallInviteKind? get activeKind => activeKindValue;

  @override
  bool get hasLocalStream => activeCallIdValue != null;

  @override
  bool get hasLocalVideo => cameraEnabledValue;

  @override
  bool get hasRemoteStream => activeCallIdValue != null;

  @override
  bool get hasRemoteVideo => activeKindValue == CallInviteKind.video;

  @override
  RTCVideoRenderer? get localRenderer => null;

  @override
  RTCVideoRenderer? get remoteRenderer => null;

  @override
  String? get remoteAddress => remoteAddressValue;

  @override
  CallMediaStatusListener? get onStatusChanged => _onStatusChanged;

  @override
  set onStatusChanged(CallMediaStatusListener? value) {
    _onStatusChanged = value;
  }

  @override
  CallMediaErrorListener? get onError => _onError;

  @override
  set onError(CallMediaErrorListener? value) {
    _onError = value;
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    acceptedIncomingCallId = callId;
    acceptedRemoteAddress = remoteAddress;
    acceptedDescription = Map<String, dynamic>.from(remoteDescription);
    activeCallIdValue = callId;
    remoteAddressValue = remoteAddress;
    activeKindValue = kind;
    cameraEnabledValue = false;
    _onStatusChanged?.call(callId, CallMediaSessionLifecycle.active);
    notifyListeners();
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {
    remoteAnswerDescription = Map<String, dynamic>.from(description);
    if (activeCallIdValue != null) {
      _onStatusChanged?.call(
        activeCallIdValue!,
        CallMediaSessionLifecycle.active,
      );
    }
  }

  @override
  Future<bool> resendLocalOffer(String callId) async {
    resendOfferCallIds.add(callId);
    return resendOfferResult;
  }

  @override
  Future<bool> resendLocalAnswer(String callId) async {
    resendAnswerCallIds.add(callId);
    return true;
  }

  @override
  Future<void> close() async {
    closed = true;
    activeCallIdValue = null;
    remoteAddressValue = null;
    activeKindValue = null;
    notifyListeners();
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    activeKindValue = kind;
    remoteOfferDescription = Map<String, dynamic>.from(remoteDescription);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraEnabledValue = enabled;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    mutedValue = muted;
    notifyListeners();
  }

  @override
  Future<void> setSpeakerOn(bool enabled) async {
    speakerOnValue = enabled;
    notifyListeners();
  }

  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    startedOutgoingCallId = callId;
    startedOutgoingRemoteAddress = remoteAddress;
    activeCallIdValue = callId;
    remoteAddressValue = remoteAddress;
    activeKindValue = kind;
    cameraEnabledValue = kind == CallInviteKind.video;
    notifyListeners();
  }
}

final class _FakeRealtimeAttachmentTransferSession
    implements RealtimeAttachmentTransferSession {
  _FakeRealtimeAttachmentTransferSession({this.incomingBytes});

  final Uint8List? incomingBytes;
  Uint8List? sentBytes;
  Map<String, dynamic>? acceptedDescription;

  @override
  ValueChanged<double>? onProgress;

  @override
  ValueChanged<Uint8List>? onComplete;

  @override
  ValueChanged<Object>? onError;

  @override
  Future<void> acceptIncoming({
    required Map<String, dynamic> description,
    required int fileSize,
  }) async {
    acceptedDescription = Map<String, dynamic>.from(description);
    if (incomingBytes != null) {
      onComplete?.call(Uint8List.fromList(incomingBytes!));
    }
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> send({
    required Uint8List bytes,
    required String text,
    required ChatMessageType type,
    String? fileName,
    String? mimeType,
    int? attachmentSizeBytes,
    int? durationMs,
  }) async {
    sentBytes = Uint8List.fromList(bytes);
  }
}

/// Ada, invited from this device and not answered yet: her `friend_accept`
/// completes the friendship. (An accept nobody asked for does not.)
const Map<String, FriendProfile> _adaInvited = <String, FriendProfile>{
  'ada.ygg': FriendProfile(
    address: 'ada.ygg',
    displayName: 'Ada',
    status: FriendRelationshipStatus.pendingOutgoing,
  ),
};

SocialHubState _seedWithAdaInvited() => SocialHubState.empty().copyWith(
  book: FriendshipBook.restore(profiles: _adaInvited),
);

/// A vault over [dir] with the key of the default (memory) security
/// service a test container gets.
MediaVault _testVault(Directory dir) => MediaVault(
  masterKey: MemoryAppSecurityService(
    passwordIterations: 10,
  ).currentEncryptionKey,
  supportDirectory: () async => dir,
);

/// An address as a readable name segment (must never show on disk).
String _b64Name(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

/// [path] is an encrypted vault file: its name shows none of [hidden] and
/// its bytes do not hold [plain].
Future<void> _expectSealed(
  String path,
  List<int> plain, {
  List<String> hidden = const <String>[],
}) async {
  expect(isMediaVaultPath(path), isTrue, reason: path);
  final String name = path.toLowerCase();
  for (final String text in hidden) {
    expect(name, isNot(contains(text.toLowerCase())), reason: text);
  }
  final Uint8List onDisk = await File(path).readAsBytes();
  bool holdsPlain = false;
  for (int start = 0; start + plain.length <= onDisk.length; start++) {
    int matched = 0;
    while (matched < plain.length &&
        onDisk[start + matched] == plain[matched]) {
      matched++;
    }
    if (matched == plain.length) {
      holdsPlain = true;
      break;
    }
  }
  expect(holdsPlain, isFalse, reason: 'the file is stored encrypted');
}

/// The friend on the mesh the attachment tests send to.
const String _meshPeer = '200:1111:2222:3333:4444:5555:6666:7777';

/// A stored state where [address] is an accepted friend (sending to someone
/// on the mesh never makes them one).
SocialHubState _friendSnapshot(String address) =>
    SocialHubState.empty().copyWith(
      book: FriendshipBook.restore(
        profiles: <String, FriendProfile>{
          address: FriendProfile(
            address: address,
            status: FriendRelationshipStatus.accepted,
          ),
        },
      ),
    );
