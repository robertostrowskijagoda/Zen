import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/features/feed/presentation/rich_post_body.dart';
import 'package:zen/src/features/media/media_vault.dart';
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
  });

  final String address;
  final String name;
  final double size;
  final bool online;

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
      image: peerAvatarImage(path),
    );
  }
}

/// What a friend shows about themselves: photo, their own name, status and
/// bio - plus the nickname the user gave them, when it differs.
Future<void> showPeerProfileSheet(BuildContext context, String address) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => _PeerProfileSheet(address: address),
  );
}

class _PeerProfileSheet extends ConsumerWidget {
  const _PeerProfileSheet({required this.address});

  final String address;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState state = watchSocialPeople(ref);
    final FriendProfile? friend = state.friendByAddress(address);
    final PeerPublicProfile? peer = state.peerProfileOf(address);
    final String shownName = friend == null
        ? (peer?.name.trim().isNotEmpty == true ? peer!.name.trim() : 'Kontakt')
        : state.nameFor(friend);
    final String ownName = peer?.name.trim() ?? '';
    return SafeArea(
      child: Padding(
        key: const Key('peer-profile-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[zen.accent, zen.accentSecondary],
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      Theme.of(context).bottomSheetTheme.backgroundColor ??
                      zen.surfaceRaised,
                ),
                child: ZenBlobAvatar(
                  name: shownName,
                  size: 104,
                  showStatus: false,
                  image: peerAvatarImage(peer?.avatarPath),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              shownName,
              textAlign: TextAlign.center,
              style: zen.display(
                color: zen.textPrimary,
                size: 22,
                weight: FontWeight.w800,
              ),
            ),
            if (ownName.isNotEmpty && ownName != shownName) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Przedstawia się jako: $ownName',
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textSecondary, fontSize: 13),
              ),
            ],
            if (peer?.status.isNotEmpty ?? false) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: zen.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: zen.accent.withValues(alpha: 0.22)),
                ),
                child: Text(
                  peer!.status,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (peer?.bio.isNotEmpty ?? false) ...<Widget>[
              const SizedBox(height: 14),
              RichPostBody(
                source: peer!.bio,
                mediaCount: 0,
                mediaBuilder: (BuildContext context, int i) =>
                    const SizedBox.shrink(),
                fontSize: 14,
              ),
            ],
            if (peer == null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'Ta osoba nie udostępniła jeszcze swojego profilu.',
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textMuted, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
