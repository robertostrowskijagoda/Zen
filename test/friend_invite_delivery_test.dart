import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/friends_world.dart';

/// An invitation to become friends travels directly only (the other side
/// is no friend yet, so no mailbox carries it): it arrives while both
/// devices are online at the same time, and is given up after two weeks.
/// The person who invited sees where it is: on its way, arrived, or not
/// arrived - with a way to send it again, and it goes again by itself once
/// the other side is heard from.

Future<FriendsWorld> _strangers() =>
    FriendsWorld.create(<String>['A', 'B'], allFriends: false);

Future<void> _invite(FriendsPhone from, FriendsPhone to) =>
    from.hub.sendFriendRequest(
      peerAddress: to.address,
      knownName: to.name,
      senderDisplayName: from.name,
    );

OutgoingInviteStatus? _statusAt(FriendsPhone p, FriendsPhone to) =>
    p.state.outgoingInviteTo(to.address)?.status;

bool _requestQueued(RelayState s) => s.outbox.values.any(
  (RelayOutboxEntry e) => e.payload['type'] == 'friend_request',
);

void main() {
  test('an invitation to someone who never comes online in two weeks is '
      'said not to have arrived, instead of waiting for an answer for '
      'ever', () async {
    final FriendsWorld w = await _strangers();
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.setOnline(b, false);
    await _invite(a, b);
    await w.deliver();
    await w.advance(const Duration(days: 15), step: const Duration(hours: 1));

    expect(_requestQueued(await a.relayStore.load()), isFalse);
    final FriendProfile? invited = a.state.friendByAddress(b.address);
    expect(invited?.status, FriendRelationshipStatus.pendingOutgoing);
    expect(
      invited?.lastMessagePreview,
      'Nie dotarło — oboje musicie być w sieci w tym samym czasie.',
    );
  });

  test('on its way while the other side is offline, then arrived once it '
      'comes online', () async {
    final FriendsWorld w = await _strangers();
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.setOnline(b, false);
    await _invite(a, b);
    await w.deliver();
    expect(_statusAt(a, b), OutgoingInviteStatus.onItsWay);
    await w.advance(const Duration(hours: 3));
    expect(_statusAt(a, b), OutgoingInviteStatus.onItsWay);

    await w.setOnline(b, true);
    await w.until(
      () async => _statusAt(a, b) == OutgoingInviteStatus.delivered,
      within: const Duration(minutes: 30),
      reason: 'the invitation arriving',
    );
    expect(
      b.state.friendByAddress(a.address)?.status,
      FriendRelationshipStatus.pendingIncoming,
    );
    expect(
      a.state.friendByAddress(b.address)?.lastMessagePreview,
      'Zaproszenie dotarło, czeka na odpowiedź.',
    );
    // Its answer ends the waiting.
    await b.hub.acceptFriendRequest(
      peerAddress: a.address,
      senderDisplayName: b.name,
    );
    await w.deliver();
    expect(
      a.state.friendByAddress(b.address)?.status,
      FriendRelationshipStatus.accepted,
    );
  });

  test('one that did not arrive is sent again from the menu, and arrives '
      'when both are online', () async {
    final FriendsWorld w = await _strangers();
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.setOnline(b, false);
    await _invite(a, b);
    await w.advance(const Duration(days: 15), step: const Duration(hours: 1));
    expect(_statusAt(a, b), OutgoingInviteStatus.lost);

    await w.setOnline(b, true);
    await a.hub.resendFriendRequest(peerAddress: b.address);
    expect(_statusAt(a, b), OutgoingInviteStatus.onItsWay);
    await w.until(
      () async => _statusAt(a, b) == OutgoingInviteStatus.delivered,
      reason: 'the invitation sent again arriving',
    );
    expect(
      b.state.friendByAddress(a.address)?.status,
      FriendRelationshipStatus.pendingIncoming,
    );
  });

  test('one that did not arrive goes again by itself once the other side '
      'is heard from', () async {
    final FriendsWorld w = await _strangers();
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.setOnline(b, false);
    await _invite(a, b);
    await w.advance(const Duration(days: 15), step: const Duration(hours: 1));
    expect(_statusAt(a, b), OutgoingInviteStatus.lost);

    await w.setOnline(b, true);
    // Anything from them (here: their typing, as a stray word).
    await a.hub.receiveSignal(
      ZenSignal(type: ZenSignalType.typing, sender: b.address),
      receivedAtMillis: w.now,
    );
    await w.until(
      () async => _statusAt(a, b) == OutgoingInviteStatus.delivered,
      reason: 'the invitation going again by itself',
    );
  });
}
