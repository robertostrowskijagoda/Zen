import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/waiting_replies_card.dart';
import 'package:zen/src/features/chat/waiting_replies.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// "Czekają na Twoją odpowiedź" on the chats list: each waiting chat can be
// hidden on its own (until a newer message comes), or all at once.
void main() {
  final DateTime now = DateTime(2026, 11, 5, 12);
  int daysAgo(int days) =>
      now.subtract(Duration(days: days)).millisecondsSinceEpoch;
  const String ola = '200:1111:2222:3333:4444:5555:6666:7777';
  const String ada = '200:2222:2222:3333:4444:5555:6666:7777';

  FriendProfile friend(String address, String name, int last) => FriendProfile(
    address: address,
    displayName: name,
    status: FriendRelationshipStatus.accepted,
    lastActivityLabel: activityStamp(last),
  );

  ChatMessage waiting(String id, int at) => ChatMessage(
    id: id,
    sender: 'them',
    text: 'Hej?',
    sentAtMillis: at,
    direction: ChatMessageDirection.incoming,
  );

  testWidgets('the cross hides one waiting chat, the others stay; with one '
      'left there is no "Ukryj wszystkie"', (WidgetTester tester) async {
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(store),
          appSettingsInitialStateProvider.overrideWithValue(
            const AppSettings(),
          ),
          appSettingsHydrationEnabledProvider.overrideWithValue(false),
          waitingRepliesClockProvider.overrideWithValue(() => now),
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              ola: <ChatMessage>[waiting('o', daysAgo(3))],
              ada: <ChatMessage>[waiting('a', daysAgo(4))],
            }),
          ),
          runtimeSystemNotificationServiceProvider.overrideWithValue(
            MemoryRuntimeSystemNotificationService(),
          ),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  ola: friend(ola, 'Ola', daysAgo(3)),
                  ada: friend(ada, 'Ada', daysAgo(4)),
                },
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ZenTheme.light(),
          home: const Scaffold(body: WaitingRepliesCard()),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byKey(const Key('waiting-reply-$ola')), findsOneWidget);
    expect(find.byKey(const Key('waiting-reply-$ada')), findsOneWidget);
    expect(find.text('Ukryj wszystkie'), findsOneWidget);

    await tester.tap(find.byKey(const Key('waiting-reply-hide-$ola')));
    for (int i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.byKey(const Key('waiting-reply-$ola')), findsNothing);
    expect(find.byKey(const Key('waiting-reply-$ada')), findsOneWidget);
    expect(find.byKey(const Key('waiting-replies-hide')), findsNothing);
    final AppSettings saved = (await store.load())!;
    expect(saved.seenTips, <String>{waitingReplyTip(ola, daysAgo(3))});
  });
}
