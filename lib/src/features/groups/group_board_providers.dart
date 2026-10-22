import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/groups/group_board_service.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// [GroupBoardHost] over the app's groups (the social hub's state).
final class AppGroupBoardHost implements GroupBoardHost {
  AppGroupBoardHost(this.ref);

  final Ref ref;

  @override
  String ownAddress() => ref.read(runtimeNodeSnapshotProvider).localAddress;

  @override
  String ownName() => ref.read(userProfileControllerProvider).publicName;

  @override
  List<String>? membersOf(String groupId) {
    final GroupProfile? group = ref
        .read(socialHubControllerProvider)
        .groupById(groupId);
    if (group == null || group.isInvitePending) {
      return null;
    }
    final String own = ownAddress();
    return <String>[
      for (final String m in normalizedGroupMembers(<String>[
        ...group.memberAddresses,
        group.createdById,
      ]))
        if (own.isEmpty || !PeerShareCodec.addressesEqual(m, own)) m,
    ];
  }

  @override
  bool isAdmin(String groupId, String address) {
    final GroupProfile? group = ref
        .read(socialHubControllerProvider)
        .groupById(groupId);
    return group != null &&
        group.createdById.isNotEmpty &&
        PeerShareCodec.addressesEqual(group.createdById, address);
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) => ref
      .read(signalTransportProvider)
      .send(remoteAddress: to, payload: payload);
}

/// The boards of this person's groups.
final Provider<GroupBoardService> groupBoardServiceProvider =
    Provider<GroupBoardService>((Ref ref) {
      final GroupBoardService board = GroupBoardService(
        host: AppGroupBoardHost(ref),
        disk: ref.read(ledgerDiskProvider),
      );
      // Who is in which group is known once the groups are read (also in
      // the Android background service, which runs the same modules).
      final Future<void> groupsRead = ref
          .read(socialHubControllerProvider.notifier)
          .whenHydrated;
      listenFrames(ref, (SignalTransportFrame frame) async {
        await groupsRead;
        return board.handle(frame);
      }, 'Tablica grupy');
      ref.onDispose(board.dispose);
      return board;
    });
