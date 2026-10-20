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

/// Most entries kept per device log in a space kind this build does not
/// know (written by a newer Zen): enough to hand them on, not a way to fill
/// the disk.
const int kMaxUnknownSpaceEntries = 1000;

/// Most spaces of unknown kinds one device keeps to hand on to friends: the
/// per-log cap above times this is the most disk friends can make it use.
const int kMaxUnknownSpaces = 256;

/// A space kind a newer build may add: short, lower-case.
final RegExp _spaceKindPattern = RegExp(r'^[a-z][a-z0-9_]{0,23}$');

/// Only devices of [owner] may write, and only [maxEntries] per device log.
///
/// For `<kind>/<account>` spaces of a kind this build does not know (§1.6:
/// an older version keeps what it does not understand). The entries are
/// still signed by the owner's devices and checked like any other.
final class UnknownAccountSpacePolicy implements SpacePolicy {
  const UnknownAccountSpacePolicy(
    this.owner, {
    this.maxEntries = kMaxUnknownSpaceEntries,
  });

  final String owner;
  final int maxEntries;

  @override
  bool allows(LogEntry entry) =>
      entry.account == owner && entry.seq <= maxEntries;
}

/// Whether [space] is of a kind this build knows (and so may serve it by
/// its own rules). Spaces kept only for forward compatibility are not.
bool isKnownSpace(String space) {
  if (space == kPowerSpace) {
    return true;
  }
  final int slash = space.indexOf('/');
  return slash > 0 && kAccountSpaceKinds.contains(space.substring(0, slash));
}

/// Space name for [kind] owned by [account].
String accountSpace(String kind, String account) {
  assert(kAccountSpaceKinds.contains(kind));
  return '$kind/$account';
}

/// The shared log of the (future) governing structure.
const String kPowerSpace = 'power';

/// The policy for [space], or `null` for a space that is refused.
///
/// A `<kind>/<account>` space of a kind this build does not know is kept
/// for its owner, with a cap ([UnknownAccountSpacePolicy]); anything else
/// unknown (no owner, a malformed kind) is refused. Whether entries of such
/// a space arrive at all is still up to the replicator: it only takes
/// spaces it subscribes to.
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
  if (owner.isEmpty || owner.contains('/')) {
    return null;
  }
  if (kAccountSpaceKinds.contains(kind)) {
    return AccountSpacePolicy(owner);
  }
  if (!_spaceKindPattern.hasMatch(kind)) {
    return null;
  }
  return UnknownAccountSpacePolicy(owner);
}
