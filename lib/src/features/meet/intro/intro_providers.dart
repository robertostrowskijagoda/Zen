import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// [IntroFriending] over the app's friends list: the normal friend request
/// (the same one the "add friend" code sends), or accepting theirs.
final class AppIntroFriending implements IntroFriending {
  AppIntroFriending(this.ref);

  final Ref ref;

  @override
  bool isBlocked(String address) =>
      ref.read(socialHubControllerProvider).friendByAddress(address)?.status ==
      FriendRelationshipStatus.blocked;

  @override
  Future<void> befriend(
    String address, {
    required String name,
    required String note,
  }) async {
    final FriendRelationshipStatus status =
        ref
            .read(socialHubControllerProvider)
            .friendByAddress(address)
            ?.status ??
        FriendRelationshipStatus.none;
    final SocialHubController social = ref.read(
      socialHubControllerProvider.notifier,
    );
    final String own = ref.read(userProfileControllerProvider).displayName;
    final String? me = own.trim().isEmpty ? null : own.trim();
    if (status == FriendRelationshipStatus.pendingIncoming) {
      await social.acceptFriendRequest(
        peerAddress: address,
        senderDisplayName: me,
      );
    } else if (status == FriendRelationshipStatus.none) {
      // Two requests that cross become a friendship by themselves.
      await social.sendFriendRequest(
        peerAddress: address,
        knownName: name,
        senderDisplayName: me,
        message: note,
      );
    }
  }
}

/// Introductions, letters through a friend and friend-list requests
/// (§24.1).
final Provider<IntroService> introServiceProvider = Provider<IntroService>((
  Ref ref,
) {
  final IntroService intro = IntroService(
    host: MeetEventHost(
      AppMeetHost(ref),
      address: () => ref.read(runtimeNodeSnapshotProvider).localAddress,
      name: () => ref.read(userProfileControllerProvider).displayName,
    ),
    disk: ref.read(ledgerDiskProvider),
    // Read when needed, so the inbox alone does not start the statuses.
    meet: () => ref.read(meetServiceProvider),
    friending: AppIntroFriending(ref),
  );
  unawaitedLogged(intro.load(), context: 'Odczyt przedstawień');
  listenFrames(ref, intro.handle, 'Przedstawienia');
  // Friend requests due from answers that came while the app was away are
  // made once the friends are read.
  ref.listen<int>(
    socialHubControllerProvider.select(
      (SocialHubState s) => acceptedFriendAddresses(s).length,
    ),
    (int? previous, int next) {
      if (next > 0) {
        unawaitedLogged(intro.settle(), context: 'Przedstawienia: zaproszenia');
      }
    },
    fireImmediately: true,
  );
  ref.onDispose(intro.dispose);
  return intro;
});
