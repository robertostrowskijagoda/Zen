import 'package:flutter/foundation.dart';

@immutable
final class UserProfile {
  const UserProfile({
    this.displayName = 'Ja',
    this.avatarPreset = 'zen_avatar_1',
    this.avatarPath,
    this.coverPath,
    this.customStatus = 'Dostępny w sieci Yggdrasil',
    this.bio = 'Użytkownik bezpiecznej sieci Zen.',
    this.updatedAtMillis = 0,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      displayName: (json['displayName'] as String?)?.trim().isNotEmpty == true
          ? (json['displayName'] as String).trim()
          : 'Ja',
      avatarPreset: (json['avatarPreset'] as String?)?.trim().isNotEmpty == true
          ? (json['avatarPreset'] as String).trim()
          : 'zen_avatar_1',
      avatarPath: json['avatarPath'] as String?,
      coverPath: json['coverPath'] as String?,
      customStatus:
          (json['customStatus'] as String?) ?? 'Dostępny w sieci Yggdrasil',
      bio: (json['bio'] as String?) ?? 'Użytkownik bezpiecznej sieci Zen.',
      updatedAtMillis: (json['updatedAtMillis'] as num?)?.toInt() ?? 0,
    );
  }

  final String displayName;
  final String avatarPreset;
  final String? avatarPath;

  /// The wide photo behind the profile header (§9).
  final String? coverPath;
  final String customStatus;
  final String bio;
  final int updatedAtMillis;

  UserProfile copyWith({
    String? displayName,
    String? avatarPreset,
    String? avatarPath,
    bool clearAvatarPath = false,
    String? coverPath,
    bool clearCoverPath = false,
    String? customStatus,
    String? bio,
    int? updatedAtMillis,
  }) {
    return UserProfile(
      displayName: displayName ?? this.displayName,
      avatarPreset: avatarPreset ?? this.avatarPreset,
      avatarPath: clearAvatarPath ? null : (avatarPath ?? this.avatarPath),
      coverPath: clearCoverPath ? null : (coverPath ?? this.coverPath),
      customStatus: customStatus ?? this.customStatus,
      bio: bio ?? this.bio,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'displayName': displayName,
    'avatarPreset': avatarPreset,
    if (avatarPath != null) 'avatarPath': avatarPath,
    if (coverPath != null) 'coverPath': coverPath,
    'customStatus': customStatus,
    'bio': bio,
    'updatedAtMillis': updatedAtMillis,
  };
}
