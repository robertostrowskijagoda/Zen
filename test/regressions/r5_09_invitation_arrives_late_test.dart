// Owner report R5-#9 (28.10.2026, after 1.14.0): invitations arrived very late; the invitation should also show on the QR screen.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in relay_engine.dart (a first contact is tried every few seconds,
// firstContactRetrySchedule) and locked_receiver.dart (repeats acknowledged)
// in c12c1dce, and in the Go bridge (R5-F5); guarded by the tests below,
// test/invite_latency_test.dart, test/relay_engine_test.dart ("a friend
// request to someone away …") and, for the QR screen, test/widget_test.dart
// ("a request arriving while the code is on screen shows up there …").
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

import '../support/friends_world.dart';

/// Lets time pass the way the phones' timers do (the engine's tick every
/// 5 s while something is due soon, every 30 s otherwise) until [done].
/// Fails past [within].
Future<void> _until(
  FriendsWorld w,
  bool Function() done, {
  required Duration within,
  required String what,
}) async {
  final int start = w.now;
  while (!done()) {
    if (w.now - start > within.inMilliseconds) {
      fail('$what did not happen within $within\n${await w.describe()}');
    }
    final bool soon = w.phones.any(
      (FriendsPhone p) => p.online && !p.locked && p.engine.wantsFrequentTicks,
    );
    await w.advance(
      soon ? const Duration(seconds: 5) : const Duration(seconds: 30),
    );
  }
}

FriendRelationshipStatus? _statusOf(FriendsPhone on, FriendsPhone peer) =>
    on.state.friendByAddress(peer.address)?.status;

/// Ada and Bob, strangers with their names chosen. The mesh loses what is
/// sent to an address while its way is looked up (four seconds), as a
/// first contact on Yggdrasil does.
Future<FriendsWorld> _strangers() async {
  final FriendsWorld w = await FriendsWorld.create(<String>[
    'Ada',
    'Bob',
  ], allFriends: false);
  for (final FriendsPhone p in w.phones) {
    await p.container
        .read(userProfileControllerProvider.notifier)
        .updateProfile(displayName: p.name);
  }
  await w.settle();
  w.routeLookup = const Duration(seconds: 4);
  return w;
}

void main() {
  test(
    'R5-#9: an invitation shows at the invited person within seconds',
    () async {
      final FriendsWorld w = await _strangers();
      final FriendsPhone ada = w['Ada'];
      final FriendsPhone bob = w['Bob'];

      // Bob scans Ada's code. The first try is lost to the lookup; before,
      // the next one came only on the long backoff of a chat message.
      await bob.hub.sendFriendRequest(peerAddress: ada.address);
      await _until(
        w,
        () => _statusOf(ada, bob) == FriendRelationshipStatus.pendingIncoming,
        within: const Duration(seconds: 15),
        what: "Bob's invitation reaching Ada",
      );

      await ada.hub.acceptFriendRequest(peerAddress: bob.address);
      await _until(
        w,
        () => _statusOf(bob, ada) == FriendRelationshipStatus.accepted,
        within: const Duration(seconds: 15),
        what: "Ada's answer reaching Bob",
      );
    },
  );

  // Before, a first contact kept the long backoff of a chat message (3 s,
  // 10 s, 30 s, 2 min, 10 min, 30 min, …), though no mailbox can carry it:
  // someone back after a while heard of it many minutes later.
  for (final (Duration away, Duration within) in const <(Duration, Duration)>[
    (Duration(minutes: 10), Duration(minutes: 2)),
    (Duration(hours: 1), Duration(minutes: 5)),
  ]) {
    test(
      'R5-#9: an invitation to someone offline for ${away.inMinutes} min '
      'arrives within ${within.inMinutes} min of their coming back',
      () async {
        final FriendsWorld w = await _strangers();
        final FriendsPhone ada = w['Ada'];
        final FriendsPhone bob = w['Bob'];
        await w.setOnline(ada, false);

        await bob.hub.sendFriendRequest(peerAddress: ada.address);
        await w.advance(away);
        expect(_statusOf(ada, bob), isNull);
        await w.setOnline(ada, true);

        await _until(
          w,
          () => _statusOf(ada, bob) == FriendRelationshipStatus.pendingIncoming,
          within: within,
          what: "Bob's invitation reaching Ada after $away away",
        );
      },
    );
  }
}
