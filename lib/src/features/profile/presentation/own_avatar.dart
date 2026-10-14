import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// Your own avatar: your photo, or the first letter of your name — a round
/// frame like everyone else's (no stock icon inside a circle).
class OwnAvatar extends ConsumerWidget {
  const OwnAvatar({this.size = 44, this.path, this.usePath = false, super.key});

  final double size;

  /// A photo not saved yet (the profile editor's preview).
  final String? path;

  /// Use [path] even when it is null (the photo was just removed).
  final bool usePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final UserProfile me = ref.watch(userProfileControllerProvider);
    return ZenBlobAvatar(
      name: me.displayName,
      size: size,
      showStatus: false,
      image: peerAvatarImage(usePath ? path : me.avatarPath),
    );
  }
}
