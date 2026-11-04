import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/waiting_replies.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// "Czekają na Twoją odpowiedź": which friends' last messages wait.
void main() {
  final DateTime now = DateTime(2026, 11, 5, 12);
  int daysAgo(num days) =>
      now.millisecondsSinceEpoch - (days * 24 * 3600 * 1000).round();
  const String ola = '200:1111:2222:3333:4444:5555:6666:7777';
  const String ada = '200:2222:2222:3333:4444:5555:6666:7777';
  const String ewa = '200:3333:2222:3333:4444:5555:6666:7777';
  const String iza = '200:4444:2222:3333:4444:5555:6666:7777';

  FriendProfile friend(String address, int lastMillis) => FriendProfile(
    address: address,
    displayName: address,
    status: FriendRelationshipStatus.accepted,
    lastActivityLabel: activityStamp(lastMillis),
  );

  ChatMessage msg(String id, int at, ChatMessageDirection d) => ChatMessage(
    id: id,
    sender: d == ChatMessageDirection.incoming ? 'them' : 'me',
    text: 'x',
    sentAtMillis: at,
    direction: d,
  );

  SocialHubState stateWith(
    List<FriendProfile> friends, {
    Map<String, int>? muted,
  }) => SocialHubState.empty().copyWith(
    book: FriendshipBook.restore(
      profiles: <String, FriendProfile>{
        for (final FriendProfile f in friends) f.address: f,
      },
    ),
    mutedUntil: muted,
  );

  test('a friend whose last message waits two days or more is named; an '
      'answered, a fresh, an old or a muted chat is not', () async {
    final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore(
      <String, List<ChatMessage>>{
        ola: <ChatMessage>[msg('o', daysAgo(3), ChatMessageDirection.incoming)],
        ada: <ChatMessage>[
          msg('a1', daysAgo(4), ChatMessageDirection.incoming),
          msg('a2', daysAgo(3), ChatMessageDirection.outgoing),
        ],
        ewa: <ChatMessage>[msg('e', daysAgo(1), ChatMessageDirection.incoming)],
        iza: <ChatMessage>[
          msg('i', daysAgo(20), ChatMessageDirection.incoming),
        ],
      },
    );
    final List<WaitingReply> waiting = await findWaitingReplies(
      state: stateWith(<FriendProfile>[
        friend(ola, daysAgo(3)),
        friend(ada, daysAgo(3)),
        friend(ewa, daysAgo(1)),
        friend(iza, daysAgo(20)),
      ]),
      settings: const AppSettings(),
      timelines: timelines,
      now: now,
    );
    expect(waiting.map((WaitingReply w) => w.friend.address), <String>[ola]);

    // Muted, hidden with "Ukryj", or switched off: nobody.
    expect(
      await findWaitingReplies(
        state: stateWith(
          <FriendProfile>[friend(ola, daysAgo(3))],
          muted: <String, int>{ola: kMutedForever},
        ),
        settings: const AppSettings(),
        timelines: timelines,
        now: now,
      ),
      isEmpty,
    );
    expect(
      await findWaitingReplies(
        state: stateWith(<FriendProfile>[friend(ola, daysAgo(3))]),
        settings: AppSettings(
          seenTips: <String>{waitingReplyTip(ola, daysAgo(3))},
        ),
        timelines: timelines,
        now: now,
      ),
      isEmpty,
    );
    expect(
      await findWaitingReplies(
        state: stateWith(<FriendProfile>[friend(ola, daysAgo(3))]),
        settings: const AppSettings(waitingReplyReminder: false),
        timelines: timelines,
        now: now,
      ),
      isEmpty,
    );
  });
}
