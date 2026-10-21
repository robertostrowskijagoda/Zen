import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';
import 'package:zen/src/features/profile/profile_fields.dart';

/// Edge of the avatar thumbnail that travels to friends, in pixels.
const int kProfileAvatarSize = 160;

/// Largest avatar accepted from a peer, in bytes (decoded).
const int kMaxIncomingAvatarBytes = 64 * 1024;

/// Largest image dimensions a peer's avatar may declare: anything bigger is
/// a decompression bomb, not a thumbnail.
const int _maxIncomingAvatarDimension = 2048;

/// The `profile_update` payload for [profile]: what friends see about you.
///
/// It goes to every friend alike, so a field reaches it only when all
/// friends may see it ("Publiczne" or "Wszyscy znajomi"); friends of a
/// higher level read the other fields from the sealed parts of the profile
/// in the ledger (`profile_fields.dart`). The avatar goes as a small JPEG
/// thumbnail, never the original photo.
Future<Map<String, dynamic>> buildProfilePayload(UserProfile profile) async {
  bool shared(ProfileField field) =>
      fieldVisibleTo(fieldVisibility(profile, field), FriendLevel.weak);
  String? avatar;
  if (shared(ProfileField.photo)) {
    try {
      final Uint8List? bytes = await readOwnProfileImage(
        profile.avatarPath,
        maxBytes: AvatarSanitizer.maxAvatarFileSize,
      );
      if (bytes != null) {
        final Uint8List? thumbnail = await compute(makeAvatarThumbnail, bytes);
        if (thumbnail != null) {
          avatar = base64Encode(thumbnail);
        }
      }
    } catch (error, stackTrace) {
      logZenError('Preparing the profile photo failed', error, stackTrace);
    }
  }
  return <String, dynamic>{
    'type': 'profile_update',
    'v': profile.updatedAtMillis,
    'name': profile.displayName.trim(),
    'status': shared(ProfileField.status) ? profile.customStatus.trim() : '',
    'bio': shared(ProfileField.bio) ? profile.bio.trim() : '',
    'avatar': ?avatar,
  };
}

/// A square [kProfileAvatarSize] JPEG of [bytes], or `null` when it is not
/// an image this app is willing to handle. Runs in an isolate.
Uint8List? makeAvatarThumbnail(Uint8List bytes) {
  if (!AvatarSanitizer.isValidImageBytes(bytes) ||
      AvatarSanitizer.hasDangerousHeader(bytes)) {
    return null;
  }
  final img.Decoder? decoder = img.findDecoderForData(bytes);
  if (decoder == null) {
    return null;
  }
  final img.DecodeInfo? info = decoder.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width > 8192 ||
      info.height > 8192) {
    return null;
  }
  final img.Image? decoded = decoder.decode(bytes, frame: 0);
  if (decoded == null) {
    return null;
  }
  final img.Image square = img.copyResizeCropSquare(
    decoded,
    size: kProfileAvatarSize,
  );
  return img.encodeJpg(square, quality: 78);
}

/// Checks a peer's avatar and re-encodes it, so whatever odd bytes came in
/// never reach the disk or the image decoder of the UI. Runs in an isolate.
Uint8List? sanitizeIncomingAvatar(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > kMaxIncomingAvatarBytes) {
    return null;
  }
  if (!AvatarSanitizer.isValidImageBytes(bytes) ||
      AvatarSanitizer.hasDangerousHeader(bytes)) {
    return null;
  }
  // The header is read by hand first: the image library's own JPEG header
  // reading already sets memory aside for whatever size it claims.
  if (!photoSizeAllowed(
    bytes,
    maxSide: _maxIncomingAvatarDimension,
    maxPixels: _maxIncomingAvatarDimension * _maxIncomingAvatarDimension,
  )) {
    return null;
  }
  final img.Decoder? decoder = img.findDecoderForData(bytes);
  final img.DecodeInfo? info = decoder?.startDecode(bytes);
  if (decoder == null ||
      info == null ||
      info.width > _maxIncomingAvatarDimension ||
      info.height > _maxIncomingAvatarDimension) {
    return null;
  }
  final img.Image? decoded = decoder.decode(bytes, frame: 0);
  if (decoded == null) {
    return null;
  }
  return img.encodeJpg(
    img.copyResizeCropSquare(decoded, size: kProfileAvatarSize),
    quality: 78,
  );
}

/// Decodes the base64 avatar of a `profile_update`; `null` for garbage.
Uint8List? decodeAvatarField(String? raw) {
  if (raw == null || raw.isEmpty || raw.length > kMaxIncomingAvatarBytes * 2) {
    return null;
  }
  try {
    return base64Decode(raw);
  } on FormatException {
    return null;
  }
}

@visibleForTesting
const int maxIncomingAvatarDimensionForTesting = _maxIncomingAvatarDimension;
