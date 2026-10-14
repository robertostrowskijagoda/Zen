import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_lifecycle_reducer.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';

void main() {
  const FriendLifecycleReducer reducer = FriendLifecycleReducer();

  test('incoming request creates a pending incoming profile', () {
    final FriendProfile profile = reducer.applyIncomingRequest(
      address: 'peer-a',
      displayName: 'Ada',
      requestMessage: 'Hej!',
    );

    expect(profile.address, 'peer-a');
    expect(profile.displayName, 'Ada');
    expect(profile.requestMessage, 'Hej!');
    expect(profile.status, FriendRelationshipStatus.pendingIncoming);
  });

  test('remote accept brings their own name; the nickname stays', () {
    final FriendProfile accepted = reducer.applyAccepted(
      current: const FriendProfile(
        address: '200:1111:2222:3333:4444:5555:6666:7777',
        nickname: 'Ania z pracy',
        status: FriendRelationshipStatus.pendingOutgoing,
      ),
      displayName: 'Anna Nowak',
    );

    expect(accepted.displayName, 'Anna Nowak');
    expect(accepted.nickname, 'Ania z pracy');
    expect(accepted.status, FriendRelationshipStatus.accepted);
  });

  test('accept keeps the name they told with their request', () {
    final FriendProfile accepted = reducer.applyAccepted(
      current: const FriendProfile(
        address: 'peer-a',
        displayName: 'Ada',
        status: FriendRelationshipStatus.pendingIncoming,
      ),
    );

    expect(accepted.displayName, 'Ada');
    expect(accepted.requestMessage, isNull);
    expect(accepted.status, FriendRelationshipStatus.accepted);
  });

  test('their newest name wins over the one known before', () {
    final FriendProfile profile = reducer.applyIncomingRequest(
      address: 'peer-a',
      displayName: 'Ada Kowalska',
      current: const FriendProfile(address: 'peer-a', displayName: 'Ada'),
    );
    expect(profile.displayName, 'Ada Kowalska');
  });

  test('a name cannot carry new lines or direction tricks', () {
    final FriendProfile profile = reducer.applyIncomingRequest(
      address: 'peer-a',
      displayName: 'Ada\u202E\nMama\u200B ${'x' * 80}',
    );
    expect(profile.displayName, isNot(contains('\n')));
    expect(profile.displayName, isNot(contains('\u202E')));
    expect(profile.displayName, isNot(contains('\u200B')));
    expect(profile.displayName.length, lessThanOrEqualTo(60));
    expect(profile.displayName, startsWith('Ada Mama'));
  });

  test('an invitation sent from here carries only the nickname', () {
    final FriendProfile profile = reducer.applyOutgoingRequest(
      address: 'peer-a',
      nickname: '  Kasia\nz pracy ',
    );
    expect(profile.displayName, isEmpty);
    expect(profile.displayLabel, 'Kontakt Zen');
    expect(profile.nickname, 'Kasia z pracy');
    expect(profile.status, FriendRelationshipStatus.pendingOutgoing);
  });

  test(
    'remote removal clears relationship but keeps identity for local cleanup',
    () {
      final FriendProfile removed = reducer.applyRemoved(
        current: const FriendProfile(
          address: 'peer-a',
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
        ),
      );

      expect(removed.displayName, 'Ada');
      expect(removed.status, FriendRelationshipStatus.none);
      expect(removed.requestMessage, isNull);
    },
  );

  test('blocked users stay blocked when a new request arrives', () {
    final FriendProfile blocked = reducer.applyIncomingRequest(
      address: 'peer-a',
      displayName: 'Ada',
      requestMessage: 'Jeszcze raz',
      current: const FriendProfile(
        address: 'peer-a',
        displayName: 'Ada',
        status: FriendRelationshipStatus.blocked,
        blockNote: 'Spam',
      ),
    );

    expect(blocked.status, FriendRelationshipStatus.blocked);
    expect(blocked.blockNote, 'Spam');
  });

  group('a friend_accept from the other side', () {
    test('completes an invitation sent from here', () {
      final FriendProfile accepted = reducer.applyRemoteAccepted(
        address: 'peer-a',
        current: const FriendProfile(
          address: 'peer-a',
          nickname: 'Ania z pracy',
          status: FriendRelationshipStatus.pendingOutgoing,
        ),
        displayName: 'Ada',
      );

      expect(accepted.status, FriendRelationshipStatus.accepted);
      // Their own name comes with it; the nickname stays.
      expect(accepted.displayName, 'Ada');
      expect(accepted.nickname, 'Ania z pracy');
    });

    test('from a stranger is only a request the user still has to accept', () {
      expect(FriendLifecycleReducer.isSolicitedRemoteAccept(null), isFalse);
      final FriendProfile result = reducer.applyRemoteAccepted(
        address: 'peer-x',
        current: null,
        displayName: 'Mama',
      );

      expect(result.status, FriendRelationshipStatus.pendingIncoming);
      expect(result.address, 'peer-x');
    });

    test('leaves a request already waiting for the user as it is', () {
      const FriendProfile waiting = FriendProfile(
        address: 'peer-a',
        displayName: 'Ada',
        requestMessage: 'Hej!',
        status: FriendRelationshipStatus.pendingIncoming,
      );
      final FriendProfile result = reducer.applyRemoteAccepted(
        address: 'peer-a',
        current: waiting,
        displayName: 'Ktoś inny',
      );

      expect(result.status, FriendRelationshipStatus.pendingIncoming);
      expect(result.requestMessage, 'Hej!');
      expect(result.displayName, 'Ada');
    });

    test('never unblocks anyone', () {
      final FriendProfile result = reducer.applyRemoteAccepted(
        address: 'peer-a',
        current: const FriendProfile(
          address: 'peer-a',
          status: FriendRelationshipStatus.blocked,
        ),
      );

      expect(result.status, FriendRelationshipStatus.blocked);
    });

    test('is idempotent for a friendship already accepted', () {
      expect(
        FriendLifecycleReducer.isSolicitedRemoteAccept(
          const FriendProfile(
            address: 'peer-a',
            status: FriendRelationshipStatus.accepted,
          ),
        ),
        isTrue,
      );
    });
  });
}
