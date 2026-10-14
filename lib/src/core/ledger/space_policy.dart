import 'package:zen/src/core/ledger/log_entry.dart';

/// Who may write into a space.
///
/// Every space name says whose it is: `feed/<account>` belongs to that
/// account, so only its devices can write there. New kinds of spaces (the
/// power log, ordered currency spaces…) add a policy here instead of a new
/// storage system.
abstract interface class SpacePolicy {
  bool allows(LogEntry entry);
}

/// Only devices of [owner] may write.
final class AccountSpacePolicy implements SpacePolicy {
  const AccountSpacePolicy(this.owner);

  final String owner;

  @override
  bool allows(LogEntry entry) => entry.account == owner;
}

/// Nobody may write (yet). Used for the power log until a valid pyramid
/// exists.
final class ClosedSpacePolicy implements SpacePolicy {
  const ClosedSpacePolicy();

  @override
  bool allows(LogEntry entry) => false;
}

/// Space prefixes owned by one account.
const Set<String> kAccountSpaceKinds = <String>{
  // Public and friends-only posts, reshares, profile fields.
  'feed',
  // Reactions this account made (likes, comments, follows).
  'acts',
  // Only this account's own devices can read it (settings, sync).
  'private',
  // Profile fields (name, photo, bio…), each with its own audience.
  'profile',
  // Never leaves the account's own devices (chat copies and history).
  'own',
};

/// Space name for [kind] owned by [account].
String accountSpace(String kind, String account) {
  assert(kAccountSpaceKinds.contains(kind));
  return '$kind/$account';
}

/// The shared log of the (future) governing structure.
const String kPowerSpace = 'power';

/// The policy for [space], or `null` for a space this build does not know
/// (refused: accepting unknown spaces would let anyone fill our storage).
SpacePolicy? defaultSpacePolicy(String space) {
  if (space == kPowerSpace) {
    return const ClosedSpacePolicy();
  }
  final int slash = space.indexOf('/');
  if (slash <= 0) {
    return null;
  }
  final String kind = space.substring(0, slash);
  final String owner = space.substring(slash + 1);
  if (!kAccountSpaceKinds.contains(kind) || owner.isEmpty) {
    return null;
  }
  return AccountSpacePolicy(owner);
}
