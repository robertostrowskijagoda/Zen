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

/// A space this device keeps within limits of its own: how many device logs
/// and how many bytes it holds, besides who may write ([allows]). The
/// [LedgerStore] also bounds the bytes of all such spaces of one [owner]
/// and of all of them together.
abstract interface class BoundedSpacePolicy implements SpacePolicy {
  /// The account whose devices write here.
  String get owner;

  /// Most device logs (writers) kept in the space.
  int get maxWriters;

  /// Most bytes of entries kept in the space.
  int get maxBytes;
}

/// Most entries kept per device log in a space kind this build does not
/// know (written by a newer Zen): enough to hand them on, not a way to fill
/// the disk.
const int kMaxUnknownSpaceEntries = 1000;

/// Most device logs kept in one space of an unknown kind: an account may
/// certify any number of devices, each with any number of logs.
const int kMaxUnknownSpaceWriters = 8;

/// Most bytes kept in one space of an unknown kind.
const int kMaxUnknownSpaceBytes = 4 << 20;

/// Most bytes kept for one owner over all its spaces of unknown kinds.
const int kMaxUnknownOwnerBytes = 8 << 20;

/// Most bytes kept for all spaces of unknown kinds together: the most disk
/// friends can make this device use for them.
const int kMaxUnknownBytes = 64 << 20;

/// Most spaces of unknown kinds one device keeps to hand on to friends.
const int kMaxUnknownSpaces = 256;

/// A space kind a newer build may add: short, lower-case.
final RegExp _spaceKindPattern = RegExp(r'^[a-z][a-z0-9_]{0,23}$');

/// Only devices of [owner] may write, only [maxEntries] per device log, at
/// most [maxWriters] logs and [maxBytes] in all.
///
/// For `<kind>/<account>` spaces of a kind this build does not know (it keeps
/// what it does not understand for a newer build). The entries are still
/// signed by the owner's devices and checked like any other.
final class UnknownAccountSpacePolicy implements BoundedSpacePolicy {
  const UnknownAccountSpacePolicy(
    this.owner, {
    this.maxEntries = kMaxUnknownSpaceEntries,
    this.maxWriters = kMaxUnknownSpaceWriters,
    this.maxBytes = kMaxUnknownSpaceBytes,
  });

  @override
  final String owner;
  final int maxEntries;
  @override
  final int maxWriters;
  @override
  final int maxBytes;

  @override
  bool allows(LogEntry entry) =>
      entry.account == owner && entry.seq <= maxEntries;
}

/// Whether [space] is of a kind this build knows (and so may serve it by
/// its own rules). Spaces kept only for a newer build are not.
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
