import 'package:flutter/foundation.dart';

/// Most members one group may list. Every group message goes to each member
/// separately, so a real group never comes near this; the cap only stops a
/// peer from stuffing a group (and the snapshot) with endless addresses.
const int kMaxGroupMemberCount = 256;

@immutable
final class GroupProfile {
  const GroupProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.avatarPreset = 'group_default',
    required this.createdById,
    required this.createdAtMillis,
    required this.memberAddresses,
    this.lastMessagePreview,
    this.lastActivityLabel,
    this.unreadCount = 0,
    this.pendingInviteAddresses = const <String>[],
    this.isInvitePending = false,
    this.memberNames = const <String, String>{},
    this.pendingInviteIds = const <String, String>{},
    this.receivedInviteIds = const <String>[],
  });

  factory GroupProfile.fromJson(Map<String, dynamic> json) {
    return GroupProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] as String?) ?? '',
      avatarPreset: (json['avatarPreset'] as String?) ?? 'group_default',
      createdById: (json['createdById'] as String?) ?? '',
      createdAtMillis: (json['createdAtMillis'] as num?)?.toInt() ?? 0,
      memberAddresses:
          (json['memberAddresses'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[],
      lastMessagePreview: json['lastMessagePreview'] as String?,
      lastActivityLabel: json['lastActivityLabel'] as String?,
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      pendingInviteAddresses:
          (json['pendingInviteAddresses'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[],
      isInvitePending: json['isInvitePending'] == true,
      memberNames: <String, String>{
        if (json['memberNames'] is Map)
          for (final MapEntry<dynamic, dynamic> e
              in (json['memberNames'] as Map).entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
      },
      pendingInviteIds: <String, String>{
        if (json['pendingInviteIds'] is Map)
          for (final MapEntry<dynamic, dynamic> e
              in (json['pendingInviteIds'] as Map).entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
      },
      receivedInviteIds:
          (json['receivedInviteIds'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[],
    );
  }

  final String id;
  final String name;
  final String description;
  final String avatarPreset;
  final String createdById;
  final int createdAtMillis;
  final List<String> memberAddresses;
  final String? lastMessagePreview;
  final String? lastActivityLabel;
  final int unreadCount;

  /// Members this device invited that have not confirmed receiving the invite.
  ///
  /// The invite travels as plain datagrams over the mesh; a peer that was
  /// offline at the time never saw it. Everyone listed here gets the invite
  /// again the next time they show up, until they answer with
  /// `group_invite_ack` (or leave).
  final List<String> pendingInviteAddresses;

  /// True on the invitee's side until the local user joins the group.
  final bool isInvitePending;

  /// Names members call themselves (from their messages and invites), by
  /// address. Lets the chat label people who are not your friends instead of
  /// showing all of them as "Uczestnik".
  final Map<String, String> memberNames;

  /// Inviter side: the invitation id sent to each member still in
  /// [pendingInviteAddresses]. Re-sends carry the same id.
  final Map<String, String> pendingInviteIds;

  /// Invitee side: ids of the invitations this group arrived with. Declining
  /// or leaving remembers them, so only a *new* invitation brings it back.
  final List<String> receivedInviteIds;

  int get memberCount => memberAddresses.length;

  bool hasMember(String address) => memberAddresses.contains(address);

  GroupProfile copyWith({
    String? id,
    String? name,
    String? description,
    String? avatarPreset,
    String? createdById,
    int? createdAtMillis,
    List<String>? memberAddresses,
    String? lastMessagePreview,
    String? lastActivityLabel,
    int? unreadCount,
    List<String>? pendingInviteAddresses,
    bool? isInvitePending,
    Map<String, String>? memberNames,
    Map<String, String>? pendingInviteIds,
    List<String>? receivedInviteIds,
  }) {
    return GroupProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      avatarPreset: avatarPreset ?? this.avatarPreset,
      createdById: createdById ?? this.createdById,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      memberAddresses: memberAddresses ?? this.memberAddresses,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastActivityLabel: lastActivityLabel ?? this.lastActivityLabel,
      unreadCount: unreadCount ?? this.unreadCount,
      pendingInviteAddresses:
          pendingInviteAddresses ?? this.pendingInviteAddresses,
      isInvitePending: isInvitePending ?? this.isInvitePending,
      memberNames: memberNames ?? this.memberNames,
      pendingInviteIds: pendingInviteIds ?? this.pendingInviteIds,
      receivedInviteIds: receivedInviteIds ?? this.receivedInviteIds,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'avatarPreset': avatarPreset,
    'createdById': createdById,
    'createdAtMillis': createdAtMillis,
    'memberAddresses': memberAddresses,
    if (lastMessagePreview != null) 'lastMessagePreview': lastMessagePreview,
    if (lastActivityLabel != null) 'lastActivityLabel': lastActivityLabel,
    'unreadCount': unreadCount,
    if (pendingInviteAddresses.isNotEmpty)
      'pendingInviteAddresses': pendingInviteAddresses,
    if (isInvitePending) 'isInvitePending': true,
    if (memberNames.isNotEmpty) 'memberNames': memberNames,
    if (pendingInviteIds.isNotEmpty) 'pendingInviteIds': pendingInviteIds,
    if (receivedInviteIds.isNotEmpty) 'receivedInviteIds': receivedInviteIds,
  };
}
