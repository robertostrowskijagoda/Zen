import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

/// The newest Zen version an accepted friend named in a ping or pong, when
/// it is newer than this build; `null` otherwise (A17).
///
/// Self-reported by friends: only a hint for the user, never a reason to
/// trust or to skip a check.
String? newestFriendVersion(SocialHubState hub) => newestVersionAbove(<String>[
  for (final MapEntry<String, String> e in hub.peerAppVersions.entries)
    if (hub.friends[e.key]?.status == FriendRelationshipStatus.accepted)
      e.value,
]);

final Provider<String?> friendsNewerVersionProvider = Provider<String?>(
  (Ref ref) =>
      ref.watch(socialHubControllerProvider.select(newestFriendVersion)),
);

/// "Znajomi mają nowszą wersję Zen (1.11.0)": a quiet tile that leads to
/// "Aktualizacje i Podaj dalej". Nothing shows while no friend is ahead.
class FriendsNewerVersionBanner extends ConsumerWidget {
  const FriendsNewerVersionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? version = ref.watch(friendsNewerVersionProvider);
    if (version == null) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final BorderRadius radius = BorderRadius.circular(18);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: zen.accent.withValues(alpha: 0.09),
        borderRadius: radius,
        child: InkWell(
          key: const Key('friends-newer-version-banner'),
          borderRadius: radius,
          onTap: () => unawaited(UpdatesScreen.open(context)),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.new_releases_outlined, color: zen.accent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t('Znajomi mają nowszą wersję Zen ({version})', {
                          'version': version,
                        }),
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t('Zobacz, jak zaktualizować'),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: zen.textSecondary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
