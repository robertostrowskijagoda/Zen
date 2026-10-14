part of 'social_hub_controller.dart';

/// Profiles travelling between friends.
///
/// Each side sends `profile_update` (name, status, bio and a small photo
/// thumbnail) when a friendship starts and whenever the user edits their
/// profile. It goes through the reliable transport, so a friend who is
/// offline gets it from their mailbox relays later. Receivers keep only the
/// newest version; the friend goes by its name everywhere (a nickname the
/// user chose stays under it).
mixin _SocialHubProfileMixin on _SocialHubControllerBase {
  @override
  void _watchOwnProfile() {
    ref.listen<UserProfile>(userProfileControllerProvider, (
      UserProfile? previous,
      UserProfile next,
    ) {
      if (next.updatedAtMillis <= 0 ||
          next.updatedAtMillis == previous?.updatedAtMillis) {
        return;
      }
      unawaitedLogged(
        _enqueueStateWork(_broadcastOwnProfileIfChanged),
        context: 'Sharing the updated profile failed',
      );
    });
  }

  /// Sends the profile to every friend once per version.
  @override
  Future<void> _broadcastOwnProfileIfChanged() async {
    final UserProfile profile = ref.read(userProfileControllerProvider);
    if (profile.updatedAtMillis <= 0 ||
        profile.updatedAtMillis <= state.profileSentVersion) {
      return;
    }
    final Map<String, dynamic> payload = await buildProfilePayload(profile);
    for (final FriendProfile friend in state.acceptedFriends) {
      await _sendProfilePayload(friend.address, payload);
    }
    state = state.copyWith(profileSentVersion: profile.updatedAtMillis);
    await _persistState();
  }

  @override
  Future<void> _sendOwnProfileTo(String peerAddress) async {
    final UserProfile profile = ref.read(userProfileControllerProvider);
    if (profile.updatedAtMillis <= 0) {
      // Never edited: nothing but the placeholder name to share.
      return;
    }
    await _sendProfilePayload(peerAddress, await buildProfilePayload(profile));
  }

  Future<void> _sendProfilePayload(
    String peerAddress,
    Map<String, dynamic> payload,
  ) async {
    if (!isRoutablePeerAddress(peerAddress)) {
      return;
    }
    try {
      await ref
          .read(signalTransportProvider)
          .send(remoteAddress: peerAddress, payload: payload);
    } catch (error, stackTrace) {
      logZenError(
        'Sending the profile to $peerAddress failed',
        error,
        stackTrace,
      );
    }
  }

  @override
  Future<void> _handleProfileUpdate(ZenSignal signal) async {
    final String address = PeerShareCodec.normalizeAddress(signal.sender);
    final int version = signal.sentAtMillis ?? 0;
    final PeerPublicProfile? current = state.peerProfiles[address];
    if (version <= 0 || (current != null && version <= current.version)) {
      // An older copy: nothing new, but the friend still goes by the name
      // of the newest profile.
      final FriendProfile? friend = state.friendByAddress(address);
      final String known = current?.name.trim() ?? '';
      if (friend != null && known.isNotEmpty && friend.displayName != known) {
        final Map<String, FriendProfile> friends =
            Map<String, FriendProfile>.from(state.friends);
        _putFriend(friends, friend.copyWith(displayName: known));
        state = state.copyWith(friends: friends);
        await _persistState();
      }
      return;
    }
    String? avatarPath = current?.avatarPath;
    final String? rawAvatar = signal.attachmentData;
    if (rawAvatar == null) {
      // They removed their photo.
      await _deletePeerAvatar(avatarPath);
      avatarPath = null;
    } else {
      final Uint8List? decoded = decodeAvatarField(rawAvatar);
      final Uint8List? clean = decoded == null
          ? null
          : await compute(sanitizeIncomingAvatar, decoded);
      if (clean != null) {
        final String? stored = await _storePeerAvatar(clean);
        if (stored != null) {
          await _deletePeerAvatar(avatarPath);
          avatarPath = stored;
        }
      }
    }
    if (!ref.mounted) {
      return;
    }
    final String name = sanitizePeerName(signal.displayName);
    // Their name is theirs: a friend shows up under the name from their
    // newest profile (the nickname this user gave them stays as it is).
    final FriendProfile? friend = state.friendByAddress(address);
    Map<String, FriendProfile>? friends;
    if (friend != null && name.isNotEmpty && friend.displayName != name) {
      friends = Map<String, FriendProfile>.from(state.friends);
      _putFriend(friends, friend.copyWith(displayName: name));
    }
    state = state.copyWith(
      friends: friends,
      peerProfiles: <String, PeerPublicProfile>{
        ...state.peerProfiles,
        address: PeerPublicProfile(
          address: address,
          version: version,
          name: name,
          status: _clip(signal.content, 120),
          bio: _clip(signal.bio, 400),
          avatarPath: avatarPath,
        ),
      },
    );
    await _persistState();
  }

  String _clip(String? value, int max) {
    final String trimmed = value?.trim() ?? '';
    return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
  }

  /// Keeps a friend's photo in the vault: encrypted, under a random name
  /// (a new photo is a new file, so no image cache keeps the old one).
  Future<String?> _storePeerAvatar(Uint8List bytes) async {
    try {
      return await _mediaVault.put(bytes);
    } catch (error, stackTrace) {
      logZenError('Saving a friend photo failed', error, stackTrace);
      return null;
    }
  }

  Future<void> _deletePeerAvatar(String? path) async {
    if (path == null || !isMediaVaultPath(path)) {
      return;
    }
    try {
      await _mediaVault.delete(path);
    } catch (error) {
      logZenWarning('Removing an old friend photo failed: $error');
    }
  }
}
