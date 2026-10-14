import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// Entry kind of a profile version in a `profile/<account>` space (§9).
/// The newest entry wins. Public: followers and, through reshares, friends
/// of friends see the name and the mesh address (to follow or write).
const String kProfileKind = 'profile';

const int kMaxProfileName = 60;
const int kMaxProfileStatus = 140;
const int kMaxProfileBio = 1000;
const int kMaxProfileAddress = 100;

@immutable
final class LedgerProfile {
  const LedgerProfile({
    required this.account,
    required this.name,
    required this.status,
    required this.bio,
    required this.address,
    required this.entryId,
    this.avatar,
    this.cover,
  });

  final String account;
  final String name;
  final String status;
  final String bio;

  /// Mesh address to follow or write to ('' if not shared).
  final String address;
  final String entryId;

  /// Profile photo (an encrypted blob whose key is in the profile).
  final MediaRef? avatar;

  /// The wide photo behind the profile header.
  final MediaRef? cover;
}

String _clip(Object? value, int max) {
  if (value is! String) {
    return '';
  }
  final String t = value.trim();
  return t.length > max ? t.substring(0, max) : t;
}

/// Body of a profile version (every field optional, clipped).
Map<String, dynamic> profileBody({
  String name = '',
  String status = '',
  String bio = '',
  String address = '',
  Map<String, dynamic>? avatar,
  Map<String, dynamic>? cover,
}) => <String, dynamic>{
  'name': _clip(name, kMaxProfileName),
  'status': _clip(status, kMaxProfileStatus),
  'bio': _clip(bio, kMaxProfileBio),
  'addr': _clip(address, kMaxProfileAddress),
  'avatar': ?avatar,
  'cover': ?cover,
};

/// The profile carried by a single profile [entry], or `null`.
LedgerProfile? profileFromEntry(LogEntry entry) {
  if (entry.kind != kProfileKind ||
      entry.space != accountSpace('profile', entry.account)) {
    return null;
  }
  return LedgerProfile(
    account: entry.account,
    name: _clip(entry.body['name'], kMaxProfileName),
    status: _clip(entry.body['status'], kMaxProfileStatus),
    bio: _clip(entry.body['bio'], kMaxProfileBio),
    address: _clip(entry.body['addr'], kMaxProfileAddress),
    entryId: entry.id,
    avatar: mediaRefFromJson(entry.body['avatar']),
    cover: mediaRefFromJson(entry.body['cover']),
  );
}

/// Newest profile entry of [account] held by [node].
LogEntry? latestProfileEntry(LedgerNode node, String account) {
  LogEntry? best;
  for (final LogEntry e in node.entriesOf(
    spaceKind: 'profile',
    ofAccount: account,
  )) {
    if (e.kind == kProfileKind && (best == null || e.hlc > best.hlc)) {
      best = e;
    }
  }
  return best;
}

LedgerProfile? latestProfile(LedgerNode node, String account) {
  final LogEntry? entry = latestProfileEntry(node, account);
  return entry == null ? null : profileFromEntry(entry);
}

/// Writes this account's profile if it differs from the newest version.
/// Returns true when a new version was written.
Future<bool> publishProfileIfChanged(
  LedgerNode node,
  Map<String, dynamic> body,
) async {
  await node.start();
  final LogEntry? current = latestProfileEntry(node, node.account);
  if (current != null && canonicalJson(current.body) == canonicalJson(body)) {
    return false;
  }
  final MediaRef? avatar = mediaRefFromJson(body['avatar']);
  final MediaRef? cover = mediaRefFromJson(body['cover']);
  await node.publish(
    kProfileKind,
    body,
    spaceKind: 'profile',
    blobs: <String>[?avatar?.id, ?cover?.id],
  );
  return true;
}

const String _avatarRefKey = 'ledger/avatar_ref';
const String _coverRefKey = 'ledger/cover_ref';

/// The media reference of the profile photo [bytes]: stored once and
/// reused while the photo stays the same (so the profile does not change
/// on every start). `null` for no photo.
Future<Map<String, dynamic>?> avatarRefFor(LedgerNode node, Uint8List? bytes) =>
    _imageRefFor(node, bytes, _avatarRefKey);

/// The same for the cover photo.
Future<Map<String, dynamic>?> coverRefFor(LedgerNode node, Uint8List? bytes) =>
    _imageRefFor(node, bytes, _coverRefKey);

Future<Map<String, dynamic>?> _imageRefFor(
  LedgerNode node,
  Uint8List? bytes,
  String key,
) async {
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  await node.start();
  final String hash = sha256Hex(bytes);
  final Uint8List? saved = await node.disk.read(key);
  if (saved != null) {
    try {
      final Object? json = jsonDecode(utf8.decode(saved));
      if (json is Map &&
          json['h'] == hash &&
          json['ref'] is Map<String, dynamic>) {
        final Map<String, dynamic> ref = json['ref'] as Map<String, dynamic>;
        final MediaRef? parsed = mediaRefFromJson(ref);
        if (parsed != null && node.blobs.isComplete(parsed.id)) {
          return ref;
        }
      }
    } on FormatException {
      // Stored again below.
    }
  }
  final Map<String, dynamic> ref = await storeMedia(node.blobs, bytes);
  await node.disk.write(
    key,
    Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'h': hash, 'ref': ref})),
    ),
  );
  return ref;
}
