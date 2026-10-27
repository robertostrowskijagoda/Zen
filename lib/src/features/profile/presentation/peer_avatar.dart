import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
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
    this.online = false,
    this.away = false,
    this.showStatus = true,
  });

  final String address;
  final String name;
  final double size;
  final bool online;
  final bool away;

  /// The presence dot (not when the friend does not show it).
  final bool showStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? path = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.peerProfileOf(address)?.avatarPath,
      ),
    );
    return ZenBlobAvatar(
      name: name,
      size: size,
      online: online,
      away: away,
      showStatus: showStatus,
      image: peerAvatarImage(path),
    );
  }
}

/// What someone shows about themselves: the mini-profile, with
/// "Profil", "Wiadomość" or "Dodaj", and "Obserwuj".
Future<void> showPeerProfileSheet(BuildContext context, String address) =>
    showMiniProfile(context, address);
