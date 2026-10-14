import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/friend_display_name.dart';

final class FriendLifecycleReducer {
  const FriendLifecycleReducer();

  FriendProfile applyIncomingRequest({
    required String address,
    required String displayName,
    String? requestMessage,
    FriendProfile? current,
  }) {
    final FriendProfile base = current ?? FriendProfile(address: address);
    if (base.status == FriendRelationshipStatus.blocked) {
      return base;
    }

    // The name is theirs: what they call themselves now wins.
    final String name = sanitizePeerName(displayName);
    return base.copyWith(
      displayName: name.isEmpty ? base.displayName : name,
      requestMessage: requestMessage,
      status: FriendRelationshipStatus.pendingIncoming,
    );
  }

  /// An invitation sent from here. A code carries no name: theirs comes
  /// with their answer. [knownName] is the name they themselves use where
  /// they were met (an event, nearby, the neighbours), shown until then.
  /// [nickname] is what this user wants to call them.
  FriendProfile applyOutgoingRequest({
    required String address,
    String knownName = '',
    String nickname = '',
    String? requestMessage,
    FriendProfile? current,
  }) {
    final FriendProfile base = current ?? FriendProfile(address: address);
    if (base.status == FriendRelationshipStatus.blocked) {
      return base;
    }
    final String name = sanitizePeerName(knownName);
    final String cleanNickname = sanitizeFriendNickname(nickname);
    return base.copyWith(
      displayName: base.hasProfileName || name.isEmpty
          ? base.displayName
          : name,
      nickname: cleanNickname.isEmpty ? base.nickname : cleanNickname,
      requestMessage: requestMessage,
      status: FriendRelationshipStatus.pendingOutgoing,
    );
  }

  /// Whether a `friend_accept` from the peer behind [current] answers
  /// something this side asked for: an invitation sent from here, or a
  /// relationship that is already accepted (a repeated accept).
  static bool isSolicitedRemoteAccept(FriendProfile? current) {
    return current?.status == FriendRelationshipStatus.pendingOutgoing ||
        current?.status == FriendRelationshipStatus.accepted;
  }

  /// A `friend_accept` received from [address].
  ///
  /// Only an invitation this side sent (or an already accepted friendship)
  /// can be completed by the other side. Anything else is unsolicited: a
  /// stranger must not become a friend by merely claiming to accept, so the
  /// accept is downgraded to an incoming request the user still has to
  /// confirm. A request already waiting for the user stays exactly as it is,
  /// and a blocked peer stays blocked.
  FriendProfile applyRemoteAccepted({
    required String address,
    required FriendProfile? current,
    String? displayName,
  }) {
    if (current != null &&
        (current.status == FriendRelationshipStatus.blocked ||
            current.status == FriendRelationshipStatus.pendingIncoming)) {
      return current;
    }
    if (current != null && isSolicitedRemoteAccept(current)) {
      return applyAccepted(current: current, displayName: displayName);
    }
    return applyIncomingRequest(
      address: address,
      displayName: displayName?.trim() ?? '',
      current: current,
    );
  }

  FriendProfile applyAccepted({
    required FriendProfile current,
    String? displayName,
  }) {
    final String incoming = sanitizePeerName(displayName);
    return current.copyWith(
      displayName: incoming.isEmpty ? current.displayName : incoming,
      requestMessage: null,
      blockNote: null,
      status: FriendRelationshipStatus.accepted,
    );
  }

  FriendProfile applyRemoved({required FriendProfile current}) {
    return current.copyWith(
      requestMessage: null,
      blockNote: null,
      status: FriendRelationshipStatus.none,
    );
  }

  FriendProfile applyBlocked({required FriendProfile current, String? note}) {
    return current.copyWith(
      requestMessage: null,
      blockNote: note,
      status: FriendRelationshipStatus.blocked,
    );
  }
}
