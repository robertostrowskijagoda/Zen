import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// The chats and the friends list go by the latest conversation, like any
// messenger; those never written to come after, online first.
void main() {
  FriendProfile friend(
    String address,
    String name, {
    int? lastMessageAt,
    int unread = 0,
    PeerPresence presence = PeerPresence.offline,
  }) => FriendProfile(
    address: address,
    displayName: name,
    status: FriendRelationshipStatus.accepted,
    unreadCount: unread,
    presence: presence,
    lastActivityLabel: lastMessageAt == null
        ? ''
        : activityStamp(lastMessageAt),
  );

  test('friends: the latest message first, then the online ones, then by '
      'name', () {
    final SocialHubState state = SocialHubState.empty().copyWith(
      book: FriendshipBook.restore(
        profiles: <String, FriendProfile>{
          for (final FriendProfile f in <FriendProfile>[
            friend('200::1', 'Ala', lastMessageAt: 1000),
            // Unread, but older than Ala's conversation.
            friend('200::2', 'Bartek', lastMessageAt: 500, unread: 3),
            friend('200::3', 'Celina', lastMessageAt: 3000),
            friend('200::4', 'Darek', presence: PeerPresence.online),
            friend('200::5', 'Ewa'),
          ])
            f.address: f,
        },
      ),
    );
    expect(
      state.acceptedFriends.map((FriendProfile f) => f.displayName),
      <String>['Celina', 'Ala', 'Bartek', 'Darek', 'Ewa'],
    );
  });

  test('groups: the latest message first', () {
    GroupProfile group(String id, String name, int? at) => GroupProfile(
      id: id,
      name: name,
      createdById: 'self',
      createdAtMillis: 0,
      memberAddresses: const <String>['200::1'],
      lastActivityLabel: at == null ? null : activityStamp(at),
    );
    final SocialHubState state = SocialHubState.empty().copyWith(
      groups: <String, GroupProfile>{
        for (final GroupProfile g in <GroupProfile>[
          group('a', 'Alfa', 100),
          group('b', 'Beta', null),
          group('c', 'Gamma', 900),
        ])
          g.id: g,
      },
    );
    expect(state.groupList.map((GroupProfile g) => g.name), <String>[
      'Gamma',
      'Alfa',
      'Beta',
    ]);
  });
}
