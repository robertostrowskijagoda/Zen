import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// How long a friend's last message waits before the chats list names it.
const Duration kWaitingReplyAfter = Duration(days: 2);

/// Older than this, a message is not "waiting" any more, it is history.
const Duration kWaitingReplyUntil = Duration(days: 14);

/// The most friends the card names (and timelines it reads).
const int kWaitingReplyMax = 20;

/// A friend whose last message waits for an answer, since [sinceMillis].
typedef WaitingReply = ({FriendProfile friend, int sinceMillis});

/// The id in `AppSettings.seenTips` of a waiting message hidden with
/// "Ukryj": the friend and the message's time, so a newer message from
/// them is named again.
String waitingReplyTip(String address, int sinceMillis) =>
    'waiting:$address:$sinceMillis';

/// The friends whose last message (in their chat, not a group) came
/// between [kWaitingReplyAfter] and [kWaitingReplyUntil] ago and has no
/// answer: the conversation's last message is theirs. Muted chats and
/// those hidden with "Ukryj" are left out; at most [kWaitingReplyMax],
/// the longest waiting first. Reads only the timelines of friends whose
/// last activity is in that window.
Future<List<WaitingReply>> findWaitingReplies({
  required SocialHubState state,
  required AppSettings settings,
  required MessageTimelineStore timelines,
  required DateTime now,
}) async {
  if (!settings.waitingReplyReminder) {
    return const <WaitingReply>[];
  }
  final int at = now.millisecondsSinceEpoch;
  final List<(FriendProfile, int)> candidates =
      <(FriendProfile, int)>[
        for (final FriendProfile f in state.acceptedFriends)
          if (activityStampMillis(f.lastActivityLabel) case final int last
              when at - last >= kWaitingReplyAfter.inMilliseconds &&
                  at - last <= kWaitingReplyUntil.inMilliseconds &&
                  !state.isMuted(f.address, at))
            (f, last),
      ]..sort(
        ((FriendProfile, int) a, (FriendProfile, int) b) =>
            a.$2.compareTo(b.$2),
      );
  final List<WaitingReply> out = <WaitingReply>[];
  for (final (FriendProfile friend, int _) in candidates) {
    if (out.length >= kWaitingReplyMax) {
      break;
    }
    final List<ChatMessage> thread = await timelines.load(friend.address);
    ChatMessage? last;
    for (final ChatMessage m in thread) {
      if (m.direction != ChatMessageDirection.system &&
          (last == null || m.sentAtMillis >= last.sentAtMillis)) {
        last = m;
      }
    }
    if (last == null ||
        last.direction != ChatMessageDirection.incoming ||
        at - last.sentAtMillis < kWaitingReplyAfter.inMilliseconds ||
        at - last.sentAtMillis > kWaitingReplyUntil.inMilliseconds ||
        settings.seenTips.contains(
          waitingReplyTip(friend.address, last.sentAtMillis),
        )) {
      continue;
    }
    out.add((friend: friend, sinceMillis: last.sentAtMillis));
  }
  return out;
}

/// The clock of [waitingRepliesProvider] (replaced in tests).
final Provider<DateTime Function()> waitingRepliesClockProvider =
    Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// [findWaitingReplies] for this account, again whenever the friends'
/// last activity or the settings change.
final FutureProvider<List<WaitingReply>> waitingRepliesProvider =
    FutureProvider<List<WaitingReply>>((Ref ref) {
      // Again only when a friend's last activity or a mute changes, not
      // on every change of the hub (a presence, a typing sign).
      ref.watch(
        socialHubControllerProvider.select(
          (SocialHubState s) => <String>[
            for (final FriendProfile f in s.acceptedFriends)
              '${f.address}${f.lastActivityLabel}',
            for (final MapEntry<String, int> e in s.mutedUntil.entries)
              '${e.key}${e.value}',
          ].join('|'),
        ),
      );
      return findWaitingReplies(
        state: ref.read(socialHubControllerProvider),
        settings: ref.watch(appSettingsControllerProvider),
        timelines: ref.read(messageTimelineStoreProvider),
        now: ref.read(waitingRepliesClockProvider)(),
      );
    });
