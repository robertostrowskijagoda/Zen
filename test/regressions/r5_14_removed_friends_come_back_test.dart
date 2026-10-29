// Owner report R5-#14 (28.10.2026, after 1.14.0): removed friends come back.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed by remembering removals (de3b36c1) and by the friendship book, the
// one place that admits, removes and merges friends (friendship_book.dart,
// 651159e9); guarded by the test below, test/friend_removal_test.dart,
// test/friendship_book_test.dart and test/friendship_book_guard_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import '../support/friends_world.dart';

FriendRelationshipStatus? _statusOf(FriendsPhone on, FriendsPhone peer) =>
    on.state.friendByAddress(peer.address)?.status;

void main() {
  test('R5-#14: a removed friend stays removed whatever their device '
      'sends', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // B's phone is off when A removes them: it never hears of it and goes
    // on as a friend.
    await w.setOnline(b, false);
    await a.hub.removeFriend(peerAddress: b.address);
    await w.settle();
    expect(_statusOf(a, b), isNull);
    await w.setOnline(b, true);

    // Everything a friend's device sends: a message, its profile, a ping
    // and its old acceptance sent again.
    await w.send(b, a, 'Hej, jesteś?');
    await b.hub.shareOwnProfileWith(a.address);
    final SignalTransport link = b.container.read(signalTransportProvider);
    await link.send(
      remoteAddress: a.address,
      payload: const <String, dynamic>{'type': 'ping', 'presence': 'online'},
    );
    await link.send(
      remoteAddress: a.address,
      payload: const <String, dynamic>{
        'type': 'friend_accept',
        'senderName': 'B',
      },
    );
    await w.deliver();
    // A's app comes back to the screen: what it kept is replayed.
    await a.hub.setLifecycle(
      LifecycleSnapshot(
        visibility: AppVisibilityState.foregroundFocused,
        generation: 1000,
        capturedAtMillis: w.now,
      ),
    );
    await w.deliver();

    expect(_statusOf(a, b), isNull, reason: 'not even as an invitation');
    expect(await a.textsFrom(b), isEmpty);

    // Only a new invitation brings them back, as an invitation.
    await b.hub.sendFriendRequest(peerAddress: a.address);
    await w.deliver();
    expect(_statusOf(a, b), FriendRelationshipStatus.pendingIncoming);
  });
}
