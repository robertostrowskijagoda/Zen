// Owner report R5-#10 (28.10.2026, after 1.14.0): "połączenie z Kontakt Zen jest gotowe" instead of the friend\'s name.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in social_hub_controller_helpers.dart / _messages.dart (the name
// the answer brings wins over the placeholder) and social_event_text.dart
// (c12c1dce); guarded by the test below, test/invite_latency_test.dart,
// test/social_event_text_test.dart and test/widget_test.dart ("the note
// that a friendship is ready names the friend").
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  test('R5-#10: the notice of a new friend names them, never '
      '"Kontakt Zen"', () async {
    final MemoryMessageTimelineStore timeline = MemoryMessageTimelineStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timeline),
        // An invitation sent by scanning a code: Ada's name is not known
        // yet, so the list shows the placeholder for her.
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  status: FriendRelationshipStatus.pendingOutgoing,
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

    // Her answer names her.
    await hub.receiveSignal(
      const ZenSignal(
        type: ZenSignalType.friendAccept,
        sender: 'ada.ygg',
        displayName: 'Ada',
      ),
      receivedAtMillis: 42,
    );

    final List<String> shown = <String>[
      for (final ChatMessage m in await timeline.load('ada.ygg'))
        chatMessageText(m),
    ];
    // Before: the friend's placeholder won over the name in the answer.
    expect(shown, <String>['Połączenie z Ada jest gotowe.']);
    expect(shown.join('\n'), isNot(contains('Kontakt Zen')));
    expect(
      container
          .read(socialHubControllerProvider)
          .friendByAddress('ada.ygg')
          ?.displayLabel,
      'Ada',
    );
  });
}
