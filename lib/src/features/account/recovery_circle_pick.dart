import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Most people who keep recovery pieces.
const int kMaxRecoveryHelpers = 6;

/// Who keeps the recovery pieces (§6.3, §7): the mailbox circle and the
/// other friends, "Przyjaciel" first, then "Znajomy", then weak
/// acquaintances; within a level mailboxes come before the rest, in their
/// order. At most [max] people, each once.
List<String> pickRecoveryHelpers({
  required Iterable<String> mailboxes,
  required Iterable<String> friends,
  required FriendLevel Function(String address) levelOf,
  int max = kMaxRecoveryHelpers,
}) {
  final Set<String> seen = <String>{};
  final List<String> all = <String>[
    for (final String a in <String>[...mailboxes, ...friends])
      if (a.isNotEmpty && seen.add(PeerShareCodec.normalizeAddress(a))) a,
  ];
  return closestFirst(all, levelOf).take(max).toList();
}
