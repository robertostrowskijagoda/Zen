import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/meet/meet_service.dart';

/// Sets this person's private level for [address] (§8) and sends that
/// friend again what the level lets them see (the friend list, the status).
Future<void> setFriendLevel({
  required LedgerNode node,
  required MeetService meet,
  required String address,
  required FriendLevel level,
}) async {
  await node.setLevel(address, level);
  await meet.levelChanged(address);
}
