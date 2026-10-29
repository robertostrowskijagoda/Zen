// Owner report R5-#11 (28.10.2026, after 1.14.0): a notification without sender or content despite the setting; after opening the app removed contacts came back.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in locked_receiver.dart / notification_privacy.dart (no bare notice
// for events, questions, intents or a removed friend's frames; mail names
// its sender) in de3b36c1, and removals kept by the friendship book
// (friendship_book.dart, 651159e9; see R5-#14); guarded by the tests below
// and test/friend_removal_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

import '../support/friends_world.dart';

/// What [from] sends [to] as it is, past the app's own sending code (as an
/// older Zen sends it).
Future<void> _sendRaw(
  FriendsPhone from,
  FriendsPhone to,
  Map<String, dynamic> payload,
) => from.transport.send(remoteAddress: to.address, payload: payload);

void main() {
  test(
    'R5-#11: a message notice names the sender and says what came, as set',
    () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      // At the default level: who wrote and what.
      await w.lock(a);
      final int before = a.notices.posted.length;
      List<RuntimeSystemNotification> told() =>
          a.notices.posted.skip(before).toList();

      // A friend's event filling up, a question, a meeting intent: before,
      // each rang a bare "Nowe powiadomienie" with no sender and no text.
      for (final Map<String, dynamic> frame in <Map<String, dynamic>>[
        <String, dynamic>{'type': 'event', 'id': 'ev1', 'title': 'Grill'},
        <String, dynamic>{'type': 'event', 'id': 'ev1', 'title': 'Grill'},
        <String, dynamic>{'type': 'ask', 'id': 'q1'},
        <String, dynamic>{'type': 'intent', 'id': 'i1'},
      ]) {
        await _sendRaw(b, a, frame);
      }
      await w.deliver();
      expect(told(), isEmpty);

      // A message as Zen 1.12.1 sends it, with no name in it.
      await _sendRaw(b, a, <String, dynamic>{
        'type': 'message',
        'msgId': 'old-1',
        'text': 'Hej, o 18?',
      });
      await w.deliver();
      expect(told(), hasLength(1));
      expect(told().single.category, RuntimeSystemNotificationCategory.message);
      expect(told().single.title, 'B');
      expect(told().single.body, 'Hej, o 18?');
    },
  );

  test('R5-#11: after opening the app removed friends stay removed, and '
      'what they sent meanwhile rings nothing', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // B is away: the removal reaches them only later, so meanwhile they
    // still write as a friend, and A's phone is locked.
    await w.setOnline(b, false);
    await a.hub.removeFriend(peerAddress: b.address);
    await w.lock(a);
    await w.setOnline(b, true);
    await w.send(b, a, 'Hej, jesteś?');
    await b.hub.shareOwnProfileWith(a.address);
    await _sendRaw(b, a, const <String, dynamic>{
      'type': 'friend_accept',
      'senderName': 'B',
    });
    await w.deliver();
    expect(a.messageNotices, isEmpty);

    await w.unlock(a);
    await w.deliver();
    await a.hub.setLifecycle(
      LifecycleSnapshot(
        visibility: AppVisibilityState.foregroundFocused,
        generation: 1000,
        capturedAtMillis: w.now,
      ),
    );
    await w.settle();

    expect(a.state.friendByAddress(b.address)?.status, isNull);
    expect(
      a.state.friends.values.where(
        (FriendProfile f) => f.status == FriendRelationshipStatus.accepted,
      ),
      isEmpty,
    );
    expect(await a.textsFrom(b), isEmpty);
    expect(a.messageNotices, isEmpty);
  });
}
