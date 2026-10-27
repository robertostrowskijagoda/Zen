import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/update_service.dart';

/// The newest Zen version an accepted friend named in a ping or pong, when
/// it is newer than this build; `null` otherwise.
///
/// Self-reported by friends: only a hint for the user (and a reason to look
/// at GitHub now), never a reason to trust or to skip a check.
String? newestFriendVersion(SocialHubState hub) => newestVersionAbove(<String>[
  for (final MapEntry<String, String> e in hub.peerAppVersions.entries)
    if (hub.friends[e.key]?.status == FriendRelationshipStatus.accepted)
      e.value,
]);

final Provider<String?> friendsNewerVersionProvider = Provider<String?>(
  (Ref ref) =>
      ref.watch(socialHubControllerProvider.select(newestFriendVersion)),
);

/// The newest maintainer-signed release newer than this build, when the
/// signatures verified here (passed on by friends, but not taken on their
/// word); `null` otherwise.
final Provider<String?> signedNewerVersionProvider = Provider<String?>((
  Ref ref,
) {
  final UpdateService? service = ref.watch(updateServiceProvider);
  if (service == null) {
    return null;
  }
  void changed() => ref.invalidateSelf();
  service.addListener(changed);
  ref.onDispose(() => service.removeListener(changed));
  return service.signedNewerVersion;
});
