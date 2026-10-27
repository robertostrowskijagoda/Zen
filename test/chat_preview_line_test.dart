import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

SocialHubState _seedWithAda() => SocialHubState.empty().copyWith(
  friends: const <String, FriendProfile>{
    'ada.ygg': FriendProfile(
      address: 'ada.ygg',
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    ),
  },
);

void main() {
  group('chatPreviewLine', () {
    test('a GIF gives the neutral label, with a caption or without', () {
      expect(
        chatPreviewLine(
          'kot tańczy',
          type: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        '🎞 GIF',
      );
      expect(
        chatPreviewLine(
          'gif.gif',
          type: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        '🎞 GIF',
      );
      expect(
        chatPreviewLine('', type: ChatMessageType.image, mimeType: 'IMAGE/GIF'),
        '🎞 GIF',
      );
      expect(
        chatPreviewLine(
          'podpis',
          type: ChatMessageType.image,
          fileName: 'Smiech.GIF',
        ),
        '🎞 GIF',
      );
    });

    test('plain text and other attachments keep their text', () {
      expect(chatPreviewLine('Hej!', type: ChatMessageType.text), 'Hej!');
      expect(chatPreviewLine('Hej!'), 'Hej!');
      expect(
        chatPreviewLine(
          'zdjecie.jpg',
          type: ChatMessageType.image,
          fileName: 'zdjecie.jpg',
          mimeType: 'image/jpeg',
        ),
        'zdjecie.jpg',
      );
      expect(
        chatPreviewLine(
          'gif.gif',
          type: ChatMessageType.file,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        'gif.gif',
      );
      expect(
        chatPreviewLine('Hej gif.gif', type: ChatMessageType.text),
        'Hej gif.gif',
      );
    });
  });

  group('conversation preview of a GIF', () {
    test('an incoming GIF with a caption shows "GIF"', () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(_seedWithAda()),
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
          displayName: 'Ada',
          content: 'kot tańczy',
          messageType: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        receivedAtMillis: 1,
      );
      expect(
        container
            .read(socialHubControllerProvider)
            .friends['ada.ygg']!
            .lastMessagePreview,
        '🎞 GIF',
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
      expect(
        container
            .read(socialHubControllerProvider)
            .friends['ada.ygg']!
            .lastMessagePreview,
        'Hej, już jestem.',
      );
    });

    test('an incoming GIF without a caption shows "GIF"', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(_seedWithAda()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.message,
              sender: 'ada.ygg',
              displayName: 'Ada',
              messageType: ChatMessageType.image,
              fileName: 'klawiatura-1.gif',
              mimeType: 'image/gif',
            ),
            receivedAtMillis: 1,
          );
      expect(
        container
            .read(socialHubControllerProvider)
            .friends['ada.ygg']!
            .lastMessagePreview,
        '🎞 GIF',
      );
    });

    test('the preview rebuilt from the thread shows "GIF" too', () async {
      final int nowMillis = DateTime.now().millisecondsSinceEpoch;
      for (final String caption in <String>['kot tańczy', 'gif.gif']) {
        final MemoryMessageTimelineStore timelineStore =
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              'ada.ygg': <ChatMessage>[
                ChatMessage(
                  id: 'old-text',
                  sender: 'ada.ygg',
                  text: 'Hej!',
                  sentAtMillis: nowMillis - 1000,
                  direction: ChatMessageDirection.incoming,
                ),
                ChatMessage(
                  id: 'last-gif',
                  sender: 'ada.ygg',
                  text: caption,
                  sentAtMillis: nowMillis,
                  direction: ChatMessageDirection.incoming,
                  type: ChatMessageType.image,
                  fileName: 'gif.gif',
                  mimeType: 'image/gif',
                ),
              ],
            });
        final ProviderContainer container = ProviderContainer(
          overrides: [
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(timelineStore),
            socialHubSeedProvider.overrideWithValue(_seedWithAda()),
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
        expect(
          container
              .read(socialHubControllerProvider)
              .friends['ada.ygg']!
              .lastMessagePreview,
          '🎞 GIF',
        );
      }
    });
  });
}
