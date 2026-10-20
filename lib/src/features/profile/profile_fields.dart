import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

/// Profile fields that have their own visibility (§9). The name is always
/// shown: without it nobody could be found or recognised.
enum ProfileField {
  status,
  bio,
  photo,
  cover,
  nationality,
  friendCount,
  followerCount,
}

/// Who sees a profile field (§9): "Publiczne / Wszyscy znajomi / Znajomi
/// i przyjaciele / Przyjaciele / Tylko ja".
enum FieldVisibility { public, all, mid, close, onlyMe }

Map<FieldVisibility, String> get kFieldVisibilityLabels =>
    <FieldVisibility, String>{
      FieldVisibility.public: t('Publiczne'),
      FieldVisibility.all: t('Wszyscy znajomi'),
      FieldVisibility.mid: t('Znajomi i przyjaciele'),
      FieldVisibility.close: t('Przyjaciele'),
      FieldVisibility.onlyMe: t('Tylko ja'),
    };

Map<ProfileField, String> get kProfileFieldLabels => <ProfileField, String>{
  ProfileField.status: t('Status'),
  ProfileField.bio: t('O mnie'),
  ProfileField.photo: t('Zdjęcie profilowe'),
  ProfileField.cover: t('Zdjęcie w tle'),
  ProfileField.nationality: t('Narodowość'),
  ProfileField.friendCount: t('Liczba znajomych'),
  ProfileField.followerCount: t('Liczba obserwujących'),
};

/// What a field shows when the user never chose: what earlier versions
/// did (the photo, status and bio were public), the new fields for
/// friends.
const Map<ProfileField, FieldVisibility> kDefaultFieldVisibility =
    <ProfileField, FieldVisibility>{
      ProfileField.status: FieldVisibility.public,
      ProfileField.bio: FieldVisibility.public,
      ProfileField.photo: FieldVisibility.public,
      ProfileField.cover: FieldVisibility.public,
      ProfileField.nationality: FieldVisibility.all,
      ProfileField.friendCount: FieldVisibility.all,
      ProfileField.followerCount: FieldVisibility.public,
    };

FieldVisibility? fieldVisibilityByName(Object? name) {
  for (final FieldVisibility v in FieldVisibility.values) {
    if (v.name == name) {
      return v;
    }
  }
  return null;
}

/// Who sees [field] of [profile].
FieldVisibility fieldVisibility(UserProfile profile, ProfileField field) =>
    fieldVisibilityByName(profile.visibility[field.name]) ??
    kDefaultFieldVisibility[field]!;

/// [visibility] with [field] set to [value] (the default is not stored).
Map<String, String> withFieldVisibility(
  Map<String, String> visibility,
  ProfileField field,
  FieldVisibility value,
) => <String, String>{
  for (final MapEntry<String, String> e in visibility.entries)
    if (e.key != field.name) e.key: e.value,
  if (value != kDefaultFieldVisibility[field]) field.name: value.name,
};

/// The audience whose key encrypts a field of [v] (`null`: never sent).
Audience? audienceOfVisibility(FieldVisibility v) => switch (v) {
  FieldVisibility.public => Audience.public,
  FieldVisibility.all => Audience.all,
  FieldVisibility.mid => Audience.mid,
  FieldVisibility.close => Audience.close,
  FieldVisibility.onlyMe => null,
};

/// Whether a friend of [level] (`null`: someone who is not a friend) may
/// see a field of [v].
bool fieldVisibleTo(FieldVisibility v, FriendLevel? level) {
  final Audience? audience = audienceOfVisibility(v);
  if (audience == null) {
    return false;
  }
  if (audience == Audience.public) {
    return true;
  }
  return level != null && audiencesFor(level).contains(audience);
}

// ---- nationality ----

/// At most this many nationalities on a profile.
const int kMaxNationalities = 3;

final RegExp _countryCode = RegExp(r'^[A-Z]{2}$');

/// Country codes typed by the user ("pl, ua" → `[PL, UA]`). Throws
/// [ArgumentError] with a message for the user when a code is not two
/// letters or there are too many.
List<String> parseNationalities(String input) {
  final List<String> codes = <String>[];
  for (final String raw in input.split(RegExp(r'[\s,;/]+'))) {
    final String code = raw.trim().toUpperCase();
    if (code.isEmpty) {
      continue;
    }
    if (!_countryCode.hasMatch(code)) {
      throw ArgumentError(
        t('„{code}” nie jest kodem kraju (dwie litery, np. PL).', {
          'code': raw.trim(),
        }),
      );
    }
    if (!codes.contains(code)) {
      codes.add(code);
    }
  }
  if (codes.length > kMaxNationalities) {
    throw ArgumentError(
      tn(
        kMaxNationalities,
        one: 'Najwyżej {n} narodowość.',
        few: 'Najwyżej {n} narodowości.',
        many: 'Najwyżej {n} narodowości.',
      ),
    );
  }
  return codes;
}

/// Country codes from someone else's profile (anything odd is dropped).
List<String> cleanNationalities(Object? raw) {
  if (raw is! List) {
    return const <String>[];
  }
  final List<String> codes = <String>[];
  // Odd items are skipped first; the limit counts valid codes only.
  for (final Object? c in raw.take(64)) {
    if (c is String && _countryCode.hasMatch(c) && !codes.contains(c)) {
      codes.add(c);
      if (codes.length == kMaxNationalities) {
        break;
      }
    }
  }
  return codes;
}

/// The flag of country [code] (regional indicator letters).
String flagOf(String code) => _countryCode.hasMatch(code)
    ? String.fromCharCodes(<int>[
        for (final int c in code.codeUnits) 0x1F1E6 + c - 0x41,
      ])
    : '';

/// "🇵🇱 PL".
String nationalityLabel(String code) => '${flagOf(code)} $code'.trim();

// ---- the profile in the ledger: a public entry and sealed parts ----

/// Entry kinds of the sealed parts of a profile, one per audience: the
/// fields only friends of that level may read (§9). The public `profile`
/// entry carries the public ones. Older versions ignore these kinds.
const Map<Audience, String> kProfilePartKinds = <Audience, String>{
  Audience.all: 'profile_all',
  Audience.mid: 'profile_mid',
  Audience.close: 'profile_close',
};

/// Body keys of the fields.
const Map<ProfileField, String> kProfileFieldKeys = <ProfileField, String>{
  ProfileField.status: 'status',
  ProfileField.bio: 'bio',
  ProfileField.photo: 'avatar',
  ProfileField.cover: 'cover',
  ProfileField.nationality: 'nat',
  ProfileField.friendCount: 'nf',
  ProfileField.followerCount: 'nfw',
};

/// What the user's own profile says, split by who may read it: the body of
/// the public entry under [Audience.public], the sealed parts under the
/// other audiences (an audience with nothing to say maps to `{}`).
/// [avatar] and [cover] are media references (see [avatarRefFor]).
Map<Audience, Map<String, dynamic>> profileParts(
  UserProfile me, {
  required String address,
  Map<String, dynamic>? avatar,
  Map<String, dynamic>? cover,
  int? friendCount,
  int? followerCount,
}) {
  final Map<ProfileField, Object?> values = <ProfileField, Object?>{
    ProfileField.status: me.customStatus.trim(),
    ProfileField.bio: me.bio.trim(),
    ProfileField.photo: avatar,
    ProfileField.cover: cover,
    ProfileField.nationality: me.nationalities.isEmpty
        ? null
        : List<String>.of(me.nationalities),
    ProfileField.friendCount: friendCount,
    ProfileField.followerCount: followerCount,
  };
  final Map<Audience, Map<String, dynamic>> parts =
      <Audience, Map<String, dynamic>>{
        for (final Audience a in kProfilePartKinds.keys) a: <String, dynamic>{},
      };
  final Map<String, dynamic> extra = <String, dynamic>{};
  String publicText(ProfileField f) {
    final Object? v = values[f];
    return fieldVisibility(me, f) == FieldVisibility.public && v is String
        ? v
        : '';
  }

  Map<String, dynamic>? publicRef(ProfileField f) {
    final Object? v = values[f];
    return fieldVisibility(me, f) == FieldVisibility.public &&
            v is Map<String, dynamic>
        ? v
        : null;
  }

  for (final ProfileField f in ProfileField.values) {
    final Object? v = values[f];
    if (v == null || (v is String && v.isEmpty)) {
      continue;
    }
    final Audience? a = audienceOfVisibility(fieldVisibility(me, f));
    if (a == null) {
      continue;
    }
    if (a == Audience.public) {
      if (f == ProfileField.nationality ||
          f == ProfileField.friendCount ||
          f == ProfileField.followerCount) {
        extra[kProfileFieldKeys[f]!] = v;
      }
      continue;
    }
    parts[a]![kProfileFieldKeys[f]!] = _clipField(f, v);
  }
  return <Audience, Map<String, dynamic>>{
    Audience.public: <String, dynamic>{
      ...profileBody(
        name: me.displayName,
        status: publicText(ProfileField.status),
        bio: publicText(ProfileField.bio),
        address: address,
        avatar: publicRef(ProfileField.photo),
        cover: publicRef(ProfileField.cover),
      ),
      ...extra,
    },
    ...parts,
  };
}

Object? _clipField(ProfileField f, Object? v) {
  if (v is! String) {
    return v;
  }
  final int max = f == ProfileField.status ? kMaxProfileStatus : kMaxProfileBio;
  return v.length > max ? v.substring(0, max) : v;
}

String _partHashKey(String kind) => 'ledger/profile_part/$kind';

/// Writes the user's profile into the ledger: the public entry and one
/// sealed part per audience that has (or had) something in it. Returns
/// true when anything new was written.
///
/// [readImage] returns the plain bytes of the photo and cover files (they
/// are kept encrypted on the device, see `own_profile_images.dart`).
Future<bool> publishOwnProfile(
  LedgerNode node, {
  required UserProfile me,
  required String address,
  required Future<Uint8List?> Function(String? path) readImage,
  int? friendCount,
  int? followerCount,
}) async {
  await node.start();
  final Uint8List? photo =
      fieldVisibility(me, ProfileField.photo) == FieldVisibility.onlyMe
      ? null
      : await readImage(me.avatarPath);
  final Uint8List? coverBytes =
      fieldVisibility(me, ProfileField.cover) == FieldVisibility.onlyMe
      ? null
      : await readImage(me.coverPath);
  final Map<Audience, Map<String, dynamic>> parts = profileParts(
    me,
    address: address,
    avatar: await avatarRefFor(node, photo),
    cover: await coverRefFor(node, coverBytes),
    friendCount: friendCount,
    followerCount: followerCount,
  );
  bool changed = await publishProfileIfChanged(node, parts[Audience.public]!);
  for (final MapEntry<Audience, String> p in kProfilePartKinds.entries) {
    final Map<String, dynamic> body = parts[p.key]!;
    final LogEntry? previous = _latestOfKind(node, node.account, p.value);
    if (previous == null && body.isEmpty) {
      continue;
    }
    final String hash = sha256Hex(utf8.encode(canonicalJson(body)));
    if (previous != null) {
      final Map<String, dynamic>? open = node.bodyOf(previous);
      if (open != null) {
        if (canonicalJson(open) == canonicalJson(body)) {
          continue;
        }
      } else {
        // Not opened yet: what this device wrote last time.
        final Uint8List? saved = await node.disk.read(_partHashKey(p.value));
        if (saved != null && utf8.decode(saved) == '${previous.id}|$hash') {
          continue;
        }
      }
    }
    final LogEntry written = await node.publish(
      p.value,
      await node.seal(p.key, body),
      spaceKind: 'profile',
      blobs: <String>[
        ?mediaRefFromJson(body['avatar'])?.id,
        ?mediaRefFromJson(body['cover'])?.id,
      ],
    );
    await node.disk.write(
      _partHashKey(p.value),
      Uint8List.fromList(utf8.encode('${written.id}|$hash')),
    );
    changed = true;
  }
  return changed;
}

LogEntry? _latestOfKind(LedgerNode node, String account, String kind) {
  LogEntry? best;
  for (final LogEntry e in node.entriesOf(
    spaceKind: 'profile',
    ofAccount: account,
  )) {
    if (e.kind == kind && (best == null || e.hlc > best.hlc)) {
      best = e;
    }
  }
  return best;
}

/// Someone's profile as this device may read it: the public entry plus the
/// sealed parts it has keys for.
@immutable
final class ProfileView {
  const ProfileView({
    required this.account,
    required this.name,
    this.status = '',
    this.bio = '',
    this.address = '',
    this.avatar,
    this.cover,
    this.nationalities = const <String>[],
    this.friendCount,
    this.followerCount,
  });

  final String account;
  final String name;
  final String status;
  final String bio;
  final String address;
  final MediaRef? avatar;
  final MediaRef? cover;
  final List<String> nationalities;

  /// `null` when the person does not show it (to this device).
  final int? friendCount;
  final int? followerCount;
}

int? _count(Object? v) => v is int && v >= 0 && v < 100000000 ? v : null;

String _text(Object? v, int max) {
  if (v is! String) {
    return '';
  }
  final String s = v.trim();
  return s.length > max ? s.substring(0, max) : s;
}

/// The newest profile of [account] held by [node], or `null` when there is
/// none yet.
ProfileView? readProfile(LedgerNode node, String account) {
  final LedgerProfile? base = latestProfile(node, account);
  final LogEntry? publicEntry = latestProfileEntry(node, account);
  final Map<String, dynamic> fields = <String, dynamic>{
    if (publicEntry != null) ...publicEntry.body,
  };
  bool any = base != null;
  for (final String kind in kProfilePartKinds.values) {
    final LogEntry? e = _latestOfKind(node, account, kind);
    final Map<String, dynamic>? body = e == null ? null : node.bodyOf(e);
    if (body == null) {
      continue;
    }
    any = true;
    for (final MapEntry<String, dynamic> f in body.entries) {
      if (f.value != null && f.value != '') {
        fields[f.key] = f.value;
      }
    }
  }
  if (!any) {
    return null;
  }
  return ProfileView(
    account: account,
    name: base?.name ?? '',
    status: _text(fields['status'], kMaxProfileStatus),
    bio: _text(fields['bio'], kMaxProfileBio),
    address: base?.address ?? '',
    avatar: mediaRefFromJson(fields['avatar']),
    cover: mediaRefFromJson(fields['cover']),
    nationalities: cleanNationalities(fields['nat']),
    friendCount: _count(fields['nf']),
    followerCount: _count(fields['nfw']),
  );
}
