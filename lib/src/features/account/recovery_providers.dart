import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Keys of accepted friends (normalised addresses).
Set<String> _acceptedFriends(SocialHubState state) => <String>{
  for (final FriendProfile f in state.friends.values)
    if (f.status == FriendRelationshipStatus.accepted)
      PeerShareCodec.normalizeAddress(f.address),
};

/// The recovery service (§6.3), running with the ledger; `null` while the
/// ledger is off (tests, previews).
final Provider<RecoveryService?> recoveryServiceProvider =
    Provider<RecoveryService?>((Ref ref) {
      if (!ref.watch(ledgerNodeEnabledProvider)) {
        return null;
      }
      final RecoveryService service = RecoveryService(
        transport: ref.read(meshTransportProvider),
        disk: ref.read(ledgerDiskProvider),
        isFriend: (String address) => _acceptedFriends(
          ref.read(socialHubControllerProvider),
        ).contains(PeerShareCodec.normalizeAddress(address)),
      );
      unawaitedLogged(
        service.start(),
        context: 'Start odzyskiwania konta nie udał się',
      );
      ref.onDispose(() {
        unawaitedLogged(service.stop(), context: 'Zatrzymanie odzyskiwania');
      });
      return service;
    });
