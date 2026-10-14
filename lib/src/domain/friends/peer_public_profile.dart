import 'package:flutter/foundation.dart';

/// What a peer shows about itself (its own name, status, bio and photo), as
/// last received from it. Separate from `FriendProfile`, which is what *this*
/// user decided about the peer (nickname, relationship, retention).
@immutable
final class PeerPublicProfile {
  const PeerPublicProfile({
    required this.address,
    required this.version,
    this.name = '',
    this.status = '',
    this.bio = '',
    this.avatarPath,
  });

  factory PeerPublicProfile.fromJson(Map<String, dynamic> json) {
    return PeerPublicProfile(
      address: json['address'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      bio: json['bio'] as String? ?? '',
      avatarPath: json['avatarPath'] as String?,
    );
  }

  final String address;

  /// The peer's own profile timestamp; older updates are ignored.
  final int version;
  final String name;
  final String status;
  final String bio;

  /// Local copy of the peer's photo (a sanitized thumbnail).
  final String? avatarPath;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'address': address,
    'version': version,
    if (name.isNotEmpty) 'name': name,
    if (status.isNotEmpty) 'status': status,
    if (bio.isNotEmpty) 'bio': bio,
    'avatarPath': ?avatarPath,
  };
}
