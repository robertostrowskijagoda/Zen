import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// A friend's private level (§8) for code that must not start the ledger
/// itself (the social hub): the running ledger sets [levelOf].
final class FriendLevelLookup {
  FriendLevel? Function(String address)? levelOf;

  /// The level of [address], or `null` while the ledger is not running.
  FriendLevel? of(String address) => levelOf?.call(address);
}

final Provider<FriendLevelLookup> friendLevelLookupProvider =
    Provider<FriendLevelLookup>((Ref ref) => FriendLevelLookup());

/// Whether an invitation to a new group from someone passes [from] (§8).
/// [isFriend]: they are an accepted friend; [level]: this person's level for
/// them (`null` when unknown: a friend then counts as "Znajomy").
bool groupInviteAllowed(
  GroupInviteFrom from, {
  required bool isFriend,
  FriendLevel? level,
}) {
  if (from == GroupInviteFrom.everyone) {
    return true;
  }
  if (!isFriend) {
    return false;
  }
  final FriendLevel l = level ?? FriendLevel.friend;
  return switch (from) {
    GroupInviteFrom.everyone || GroupInviteFrom.allFriends => true,
    GroupInviteFrom.friends => levelAtLeast(l, FriendLevel.friend),
    GroupInviteFrom.closeFriends => l == FriendLevel.close,
  };
}
