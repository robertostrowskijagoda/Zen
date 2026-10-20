import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';

/// Account → how many friends you have in common with it (§9), from the
/// friend lists friends share with this phone ("N wspólnych znajomych"
/// under the name of someone who is not your friend).
int Function(String account) mutualFriendsLookup(
  WidgetRef ref,
  LedgerNode node,
) {
  final MeetService meet = ref.read(meetServiceProvider);
  return (String account) => mutualFriendCount(
    node,
    account,
    (String address) => meet.mutualFriends(address).length,
  );
}
