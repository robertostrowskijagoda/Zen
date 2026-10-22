import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Most people who keep recovery pieces.
const int kMaxRecoveryHelpers = 6;

/// Who keeps the recovery pieces unless the person picks otherwise: the
/// mailbox circle and the other friends, "Przyjaciel" first, then
/// "Znajomy"; within a level mailboxes come before the rest, in their
/// order. Weak acquaintances only with [includeWeak] (and then last): a
/// piece of the account key is not for someone barely known. At most
/// [max] people, each once.
List<String> pickRecoveryHelpers({
  required Iterable<String> mailboxes,
  required Iterable<String> friends,
  required FriendLevel Function(String address) levelOf,
  int max = kMaxRecoveryHelpers,
  bool includeWeak = false,
}) {
  final Set<String> seen = <String>{};
  final List<String> all = <String>[
    for (final String a in <String>[...mailboxes, ...friends])
      if (a.isNotEmpty &&
          seen.add(PeerShareCodec.normalizeAddress(a)) &&
          (includeWeak || levelOf(a) != FriendLevel.weak))
        a,
  ];
  return closestFirst(all, levelOf).take(max).toList();
}

/// Everyone who can be picked for the circle, closest first (weak
/// acquaintances last), each once.
List<String> recoveryHelperCandidates({
  required Iterable<String> friends,
  required FriendLevel Function(String address) levelOf,
}) {
  final Set<String> seen = <String>{};
  return closestFirst(<String>[
    for (final String a in friends)
      if (a.isNotEmpty && seen.add(PeerShareCodec.normalizeAddress(a))) a,
  ], levelOf);
}

/// Whether [picked] can become the circle: at least [minimum] people (the
/// number a recovery without the password needs), at most
/// [kMaxRecoveryHelpers]. Returns `null` when it can, else what is wrong.
RecoveryCircleProblem? checkRecoveryCircle(
  Iterable<String> picked, {
  required int minimum,
}) {
  final int n = picked.toSet().length;
  if (n < minimum) {
    return RecoveryCircleProblem.tooFew;
  }
  if (n > kMaxRecoveryHelpers) {
    return RecoveryCircleProblem.tooMany;
  }
  return null;
}

enum RecoveryCircleProblem { tooFew, tooMany }
