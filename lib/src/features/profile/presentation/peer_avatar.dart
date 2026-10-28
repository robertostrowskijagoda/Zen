import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/presentation/mini_profile.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The photo at [path] (a friend's, encrypted in the vault and decrypted
/// in memory, or the user's own file), or `null` to fall back to the
/// initial.
ImageProvider? peerAvatarImage(String? path) {
  if (path == null || path.isEmpty) {
    return null;
  }
  final File file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  return isMediaVaultPath(path) ? VaultFileImage(path) : FileImage(file);
}

/// A friend's avatar with their own photo, when they shared one.
class PeerAvatar extends ConsumerWidget {
  const PeerAvatar({
    super.key,
    required this.address,
    required this.name,
    this.size = 44,
    this.presence,
    this.showStatus = true,
  });

  final String address;
  final String name;
  final double size;

  /// What the presence dot shows; `null`: what the state shows for
  /// [address] ([FriendProfile.shownPresence] of an accepted friend,
  /// nothing for anyone else).
  final PeerPresence? presence;

  /// The presence dot (never when the presence is [PeerPresence.hidden]).
  final bool showStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? path = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.peerProfileOf(address)?.avatarPath,
      ),
    );
    final PeerPresence shown =
        presence ??
        (showStatus
            ? ref.watch(
                socialHubControllerProvider.select((SocialHubState state) {
                  final FriendProfile? friend = state.friendByAddress(address);
                  return friend?.status == FriendRelationshipStatus.accepted
                      ? friend!.shownPresence
                      : PeerPresence.hidden;
                }),
              )
            : PeerPresence.hidden);
    return ZenBlobAvatar(
      name: name,
      size: size,
      online: shown == PeerPresence.online,
      away: shown == PeerPresence.background,
      unknown: shown == PeerPresence.unknown,
      showStatus: showStatus && shown != PeerPresence.hidden,
      image: peerAvatarImage(path),
    );
  }
}

/// What someone shows about themselves: the mini-profile, with
/// "Profil", "Wiadomość" or "Dodaj", and "Obserwuj".
Future<void> showPeerProfileSheet(BuildContext context, String address) =>
    showMiniProfile(context, address);
