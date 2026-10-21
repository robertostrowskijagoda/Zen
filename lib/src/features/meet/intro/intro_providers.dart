import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/pyramid_gate_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
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

/// The pyramid for gates and first messages: only while it is switched on
/// and already started (it is never started for this).
PyramidService? gatePyramid(Ref ref) =>
    ref.read(featureFlagsProvider).isEnabled(ZenFeature.pyramid) &&
        ref.exists(pyramidServiceProvider)
    ? ref.read(pyramidServiceProvider)
    : null;

/// Introductions (gates), letters through friends, friend-list requests,
/// first messages for a price.
final Provider<IntroService> introServiceProvider = Provider<IntroService>((
  Ref ref,
) {
  final StrangerChatBook strangers = ref.read(strangerChatsProvider);
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
    wallet: PyramidGateWallet(() => gatePyramid(ref)),
    passes: strangers,
  );
  unawaitedLogged(intro.load(), context: 'Odczyt przedstawień');
  listenFrames(ref, intro.handle, 'Przedstawienia');
  // Friend requests due from answers that came while the app was away are
  // made once the friends are read; new friends get this person's gate
  // terms.
  ref.listen<int>(
    socialHubControllerProvider.select(
      (SocialHubState s) => acceptedFriendAddresses(s).length,
    ),
    (int? previous, int next) {
      if (next > 0) {
        unawaitedLogged(intro.settle(), context: 'Przedstawienia: zaproszenia');
        unawaitedLogged(intro.shareGates(), context: 'Bramy: warunki');
      }
    },
    fireImmediately: true,
  );
  ref.onDispose(intro.dispose);
  return intro;
});

/// The contact economy's minute (`ZenCore`'s minute, while the app runs):
/// gates and payments every 5 minutes; a member's first-message price kept
/// published (also after joining the pyramid).
void introMinute(Ref ref, int minute) {
  if (minute % 5 != 0) {
    return;
  }
  final IntroService intro = ref.read(introServiceProvider);
  unawaitedLogged(intro.tick(), context: 'Bramy: obowiązki');
  unawaitedLogged(
    syncMessagePrice(
      gatePyramid(ref),
      strangerPriceLevels(ref.read(strangerChatsProvider)),
    ),
    context: 'Cena pierwszej wiadomości',
  );
}
