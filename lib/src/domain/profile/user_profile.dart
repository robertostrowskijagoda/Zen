import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

@immutable
final class UserProfile {
  /// A missing [displayName], [customStatus] or [bio] reads as the default
  /// text in the current language.
  const UserProfile({
    String? displayName,
    this.avatarPreset = 'zen_avatar_1',
    this.avatarPath,
    this.coverPath,
    String? customStatus,
    String? bio,
    this.updatedAtMillis = 0,
  }) : _displayName = displayName,
       _customStatus = customStatus,
       _bio = bio;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      displayName: (json['displayName'] as String?)?.trim().isNotEmpty == true
          ? (json['displayName'] as String).trim()
          : null,
      avatarPreset: (json['avatarPreset'] as String?)?.trim().isNotEmpty == true
          ? (json['avatarPreset'] as String).trim()
          : 'zen_avatar_1',
      avatarPath: json['avatarPath'] as String?,
      coverPath: json['coverPath'] as String?,
      customStatus: json['customStatus'] as String?,
      bio: json['bio'] as String?,
      updatedAtMillis: (json['updatedAtMillis'] as num?)?.toInt() ?? 0,
    );
  }

  final String? _displayName;
  String get displayName => _displayName ?? t('Ja');
  final String avatarPreset;
  final String? avatarPath;

  /// The wide photo behind the profile header (§9).
  final String? coverPath;
  final String? _customStatus;
  String get customStatus => _customStatus ?? t('Dostępny w sieci Yggdrasil');
  final String? _bio;
  String get bio => _bio ?? t('Użytkownik bezpiecznej sieci Zen.');
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
      displayName: displayName ?? _displayName,
      avatarPreset: avatarPreset ?? this.avatarPreset,
      avatarPath: clearAvatarPath ? null : (avatarPath ?? this.avatarPath),
      coverPath: clearCoverPath ? null : (coverPath ?? this.coverPath),
      customStatus: customStatus ?? _customStatus,
      bio: bio ?? _bio,
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
