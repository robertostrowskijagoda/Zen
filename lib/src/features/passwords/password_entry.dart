import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/storage/format_version.dart';

/// Where the account's passwords are kept (its encrypted store, nowhere
/// else), the id its devices sync them under (account_state_sync_app.dart)
/// and the section that carries them in a copy of the account and in the
/// copy with friends (`CircleBackupSections.passwords`).
const String kPasswordVaultKey = 'passwords/vault';

/// The format of the stored vault this build writes.
const int kPasswordVaultFormat = 1;

/// Longest name of an entry ("Bank", "Poczta").
const int kMaxPasswordNameChars = 200;

/// Longest login.
const int kMaxPasswordLoginChars = 256;

/// Longest password (one made by the generator has at most 64 characters;
/// an imported one may be longer).
const int kMaxPasswordChars = 512;

/// Longest address (a web address or an app).
const int kMaxPasswordAddressChars = 1024;

/// Longest note.
const int kMaxPasswordNoteChars = 2000;

/// The most entries a vault keeps.
const int kMaxPasswordEntries = 2000;

/// Earlier versions kept per entry (to undo an edit or a wrong merge).
/// Versions that came from another device at the same time are kept on top
/// of these until the person picks one ([kMaxPasswordConcurrent]).
const int kMaxPasswordHistory = 5;

/// Versions of one entry from other devices kept on top of the history.
const int kMaxPasswordConcurrent = 4;

/// Deletion markers kept; past it the oldest go first.
const int kMaxPasswordDeletions = 2000;

/// Most bytes of the stored vault (JSON). It goes whole into the copy with
/// friends (at most 10 MB in all) and a copy of the account.
const int kMaxPasswordVaultBytes = 4 * 1024 * 1024;

/// Largest stored vault this build reads at all.
const int _maxReadBytes = 16 * 1024 * 1024;

/// The most versions read from a stored vault (anything past it is left
/// out: only a damaged or hostile store has that many).
const int _maxReadVersions =
    kMaxPasswordEntries * (kMaxPasswordHistory + kMaxPasswordConcurrent + 1) +
    kMaxPasswordDeletions;

/// Ids of entries and versions: lower-case letters and digits.
final RegExp _idPattern = RegExp(r'^[0-9a-z]{8,40}$');

/// Whether [id] is a well-formed id of an entry or a version.
bool isPasswordId(Object? id) => id is String && _idPattern.hasMatch(id);

String _clip(Object? value, int max) {
  if (value is! String) {
    return '';
  }
  return value.length > max ? value.substring(0, max) : value;
}

/// What a person types for one entry. Its [toString] shows no field: the
/// values are secrets and must never reach a log, a crash text or the
/// widget tree's debug output.
@immutable
final class PasswordFields {
  const PasswordFields({
    this.name = '',
    this.login = '',
    this.password = '',
    this.address = '',
    this.note = '',
  });

  /// What the entry is for ("Bank", "Poczta").
  final String name;
  final String login;
  final String password;

  /// A web address (`https://example.com/login`) or an Android app
  /// (`android-app://com.example.app`, also as other managers export it).
  final String address;
  final String note;

  /// Name, login and address without spaces around them. The password is
  /// kept exactly as typed: spaces may be part of it.
  PasswordFields trimmed() => PasswordFields(
    name: name.trim(),
    login: login.trim(),
    password: password,
    address: address.trim(),
    note: note.trimRight(),
  );

  /// Why these fields cannot be saved, or null when they can.
  PasswordFieldsProblem? get problem {
    if (name.length > kMaxPasswordNameChars ||
        login.length > kMaxPasswordLoginChars ||
        password.length > kMaxPasswordChars ||
        address.length > kMaxPasswordAddressChars ||
        note.length > kMaxPasswordNoteChars) {
      return PasswordFieldsProblem.tooLong;
    }
    if (name.trim().isEmpty && address.trim().isEmpty) {
      return PasswordFieldsProblem.noName;
    }
    if (password.isEmpty && note.trim().isEmpty) {
      return PasswordFieldsProblem.noPassword;
    }
    return null;
  }

  /// Whether every field is the same as in [other].
  bool sameAs(PasswordFields other) =>
      name == other.name &&
      login == other.login &&
      password == other.password &&
      address == other.address &&
      note == other.note;

  @override
  String toString() => 'PasswordFields(hidden)';
}

/// Why an entry's fields were refused.
enum PasswordFieldsProblem {
  /// A field is longer than its limit (a password is never cut short).
  tooLong,

  /// Neither a name nor an address.
  noName,

  /// Neither a password nor a note.
  noPassword,
}

/// One stored version of an entry: every edit adds one, never changes an
/// earlier one, so the account's sync (which merges a stored map key by
/// key) never mixes two edits and never drops one. A deletion is a version
/// too ([deleted]), naming the versions it removed ([seen]).
@immutable
final class PasswordVersion {
  const PasswordVersion({
    required this.key,
    required this.entryId,
    required this.atMillis,
    this.createdAtMillis = 0,
    this.baseMillis = 0,
    this.fields = const PasswordFields(),
    this.deleted = false,
    this.seen = const <String>[],
  });

  /// The version's own id (its key in the stored map).
  final String key;
  final String entryId;

  /// When it was written on its device.
  final int atMillis;

  /// When the entry was first made (carried from version to version).
  final int createdAtMillis;

  /// The time of the newest version of the entry its device knew when it
  /// was written: a version newer than this that it did not build on was
  /// written elsewhere at the same time.
  final int baseMillis;
  final PasswordFields fields;

  /// A deletion marker: the entry is gone, unless a version it did not see
  /// (made on another device meanwhile) is still there.
  final bool deleted;

  /// For a deletion: the versions it removed.
  final List<String> seen;

  Map<String, Object?> toJson() => deleted
      ? <String, Object?>{'i': entryId, 'a': atMillis, 'd': 1, 's': seen}
      : <String, Object?>{
          'i': entryId,
          'a': atMillis,
          'c': createdAtMillis,
          'pa': baseMillis,
          if (fields.name.isNotEmpty) 'n': fields.name,
          if (fields.login.isNotEmpty) 'l': fields.login,
          if (fields.password.isNotEmpty) 'p': fields.password,
          if (fields.address.isNotEmpty) 'u': fields.address,
          if (fields.note.isNotEmpty) 'o': fields.note,
        };

  /// The version [key] as stored, or null when it is not one: typed fields
  /// only, each cut to its limit; unknown fields are ignored here and kept
  /// in the store as they are.
  static PasswordVersion? fromJson(String key, Object? json) {
    if (!isPasswordId(key) ||
        json is! Map ||
        !isPasswordId(json['i']) ||
        json['a'] is! int) {
      return null;
    }
    final int at = json['a'] as int;
    if (json['d'] == 1) {
      final Object? seen = json['s'];
      return PasswordVersion(
        key: key,
        entryId: json['i'] as String,
        atMillis: at,
        deleted: true,
        seen: <String>[
          if (seen is List)
            for (final Object? s in seen.take(256))
              if (isPasswordId(s)) s! as String,
        ],
      );
    }
    final Object? created = json['c'];
    final Object? base = json['pa'];
    return PasswordVersion(
      key: key,
      entryId: json['i'] as String,
      atMillis: at,
      createdAtMillis: created is int ? created : at,
      baseMillis: base is int ? base : 0,
      fields: PasswordFields(
        name: _clip(json['n'], kMaxPasswordNameChars),
        login: _clip(json['l'], kMaxPasswordLoginChars),
        password: _clip(json['p'], kMaxPasswordChars),
        address: _clip(json['u'], kMaxPasswordAddressChars),
        note: _clip(json['o'], kMaxPasswordNoteChars),
      ),
    );
  }

  /// Whether this version is newer than [other] (by time, then by key, so
  /// every device picks the same one).
  bool isNewerThan(PasswordVersion other) => atMillis != other.atMillis
      ? atMillis > other.atMillis
      : key.compareTo(other.key) > 0;

  @override
  String toString() => 'PasswordVersion($key)';
}

/// An earlier version of an entry: what it was, and when.
@immutable
final class PasswordHistoryItem {
  const PasswordHistoryItem({
    required this.versionKey,
    required this.fields,
    required this.changedAtMillis,
    this.concurrent = false,
  });

  /// Pass to `PasswordVaultService.restorePrevious` to take it back.
  final String versionKey;
  final PasswordFields fields;
  final int changedAtMillis;

  /// Written on another device at about the same time as the current one
  /// and not seen there: the newer one won, this one waits here until the
  /// person takes it back or edits the entry.
  final bool concurrent;

  String get password => fields.password;

  @override
  String toString() => 'PasswordHistoryItem($versionKey)';
}

/// One entry of the vault as the screens and the autofill see it: its
/// current version, its earlier ones and whether two devices changed it at
/// once. Its [toString] shows only its id.
@immutable
final class PasswordEntry {
  const PasswordEntry({
    required this.id,
    required this.versionKey,
    required this.fields,
    required this.createdAtMillis,
    required this.changedAtMillis,
    this.history = const <PasswordHistoryItem>[],
    this.conflict = false,
    this.keptOverDeletion = false,
  });

  final String id;

  /// The current version (the one an edit builds on).
  final String versionKey;
  final PasswordFields fields;
  final int createdAtMillis;
  final int changedAtMillis;

  /// Earlier versions, newest first (at most [kMaxPasswordHistory], plus
  /// the [conflict]ing ones).
  final List<PasswordHistoryItem> history;

  /// Another device changed the entry at the same time: its version is in
  /// [history] marked [PasswordHistoryItem.concurrent].
  final bool conflict;

  /// Another device deleted the entry while this version was being written
  /// (it had not seen it): the entry stays, the person decides.
  final bool keptOverDeletion;

  String get name => fields.name;
  String get login => fields.login;
  String get password => fields.password;
  String get address => fields.address;
  String get note => fields.note;

  /// The name, or the address when it has none.
  String get title => name.isNotEmpty ? name : address;

  @override
  String toString() => 'PasswordEntry($id)';
}

/// The entries [versions] make: per entry the newest version that no
/// deletion saw; entries whose every version a deletion saw are gone.
/// Sorted by name (then login), as the list shows them.
List<PasswordEntry> passwordEntriesOf(Iterable<PasswordVersion> versions) {
  final Map<String, List<PasswordVersion>> lives =
      <String, List<PasswordVersion>>{};
  final Map<String, List<PasswordVersion>> deletions =
      <String, List<PasswordVersion>>{};
  for (final PasswordVersion v in versions) {
    (v.deleted ? deletions : lives)
        .putIfAbsent(v.entryId, () => <PasswordVersion>[])
        .add(v);
  }
  final List<PasswordEntry> out = <PasswordEntry>[];
  for (final MapEntry<String, List<PasswordVersion>> e in lives.entries) {
    final List<PasswordVersion> gone =
        deletions[e.key] ?? const <PasswordVersion>[];
    final Set<String> seen = <String>{
      for (final PasswordVersion d in gone) ...d.seen,
    };
    final List<PasswordVersion> alive =
        <PasswordVersion>[
          for (final PasswordVersion v in e.value)
            if (!seen.contains(v.key)) v,
        ]..sort(
          (PasswordVersion a, PasswordVersion b) => a.isNewerThan(b) ? -1 : 1,
        );
    if (alive.isEmpty) {
      continue;
    }
    final PasswordVersion current = alive.first;
    final List<PasswordHistoryItem> concurrent = <PasswordHistoryItem>[];
    final List<PasswordHistoryItem> earlier = <PasswordHistoryItem>[];
    for (final PasswordVersion v in alive.skip(1)) {
      final PasswordHistoryItem item = PasswordHistoryItem(
        versionKey: v.key,
        fields: v.fields,
        changedAtMillis: v.atMillis,
        concurrent: v.atMillis > current.baseMillis,
      );
      if (item.concurrent) {
        if (concurrent.length < kMaxPasswordConcurrent) {
          concurrent.add(item);
        }
      } else if (earlier.length < kMaxPasswordHistory) {
        earlier.add(item);
      }
    }
    final List<PasswordHistoryItem> history =
        <PasswordHistoryItem>[...concurrent, ...earlier]..sort(
          (PasswordHistoryItem a, PasswordHistoryItem b) =>
              b.changedAtMillis.compareTo(a.changedAtMillis),
        );
    int created = current.createdAtMillis;
    for (final PasswordVersion v in alive) {
      if (v.createdAtMillis > 0 && v.createdAtMillis < created) {
        created = v.createdAtMillis;
      }
    }
    out.add(
      PasswordEntry(
        id: e.key,
        versionKey: current.key,
        fields: current.fields,
        createdAtMillis: created,
        changedAtMillis: current.atMillis,
        history: history,
        conflict: concurrent.isNotEmpty,
        keptOverDeletion: gone.any(
          (PasswordVersion d) => d.atMillis > current.baseMillis,
        ),
      ),
    );
  }
  out.sort(comparePasswordEntries);
  return out;
}

/// The list's order: by title ignoring case, then login, then id.
int comparePasswordEntries(PasswordEntry a, PasswordEntry b) {
  final int byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  if (byTitle != 0) {
    return byTitle;
  }
  final int byLogin = a.login.toLowerCase().compareTo(b.login.toLowerCase());
  return byLogin != 0 ? byLogin : a.id.compareTo(b.id);
}

/// A stored vault read back: its versions (by key, as stored, so fields a
/// newer build added are written back untouched) and its other fields.
@immutable
final class PasswordVaultDoc {
  const PasswordVaultDoc({
    this.raw = const <String, Map<String, Object?>>{},
    this.versions = const <String, PasswordVersion>{},
    this.carried = const <String, Object?>{},
    this.newer = false,
  });

  /// Version key → the version as stored.
  final Map<String, Map<String, Object?>> raw;

  /// Version key → the version as this build reads it.
  final Map<String, PasswordVersion> versions;

  /// Top-level fields a newer build added.
  final Map<String, Object?> carried;

  /// Written in a format newer than this build reads: kept as it is,
  /// never written over.
  final bool newer;

  bool get isEmpty => raw.isEmpty;

  /// The stored form: `{v, e: {version key: version}}`.
  Map<String, Object?> toJson() => withCarriedFields(<String, Object?>{
    kFormatVersionKey: kPasswordVaultFormat,
    if (raw.isNotEmpty) 'e': raw,
  }, carried);

  /// [json] as a vault; null when it is not one (damaged). Versions that do
  /// not read are left out.
  static PasswordVaultDoc? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    if (json.isEmpty) {
      // Nothing synced yet: an empty vault.
      return const PasswordVaultDoc();
    }
    switch (formatAgeOf(
      json[kFormatVersionKey],
      current: kPasswordVaultFormat,
    )) {
      case FormatAge.newer:
        return const PasswordVaultDoc(newer: true);
      case FormatAge.invalid:
        return null;
      case FormatAge.readable:
        break;
    }
    final Map<String, Map<String, Object?>> raw =
        <String, Map<String, Object?>>{};
    final Map<String, PasswordVersion> versions = <String, PasswordVersion>{};
    final Object? e = json['e'];
    if (e is Map) {
      for (final MapEntry<dynamic, dynamic> v in e.entries) {
        if (versions.length >= _maxReadVersions) {
          break;
        }
        final Object? key = v.key;
        if (key is! String) {
          continue;
        }
        final PasswordVersion? version = PasswordVersion.fromJson(key, v.value);
        if (version == null) {
          continue;
        }
        versions[key] = version;
        raw[key] = Map<String, Object?>.from(v.value as Map);
      }
    }
    return PasswordVaultDoc(
      raw: raw,
      versions: versions,
      // `z` is the padding of the copy with friends, never kept.
      carried: unknownFields(json, const <String, Object?>{
        'e': null,
        'z': null,
      }),
    );
  }

  /// The stored bytes [bytes] as a vault; null when they are not one.
  static PasswordVaultDoc? fromBytes(Uint8List bytes) {
    if (bytes.length > _maxReadBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      return null;
    }
  }
}

/// The vault stored as [bytes] as a section of a copy of the account (its
/// stored JSON), or null when there is nothing in it or it does not read.
Map<String, Object?>? passwordVaultSectionOf(Uint8List? bytes) {
  if (bytes == null || bytes.length > _maxReadBytes) {
    return null;
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (json is! Map) {
    return null;
  }
  final PasswordVaultDoc? doc = PasswordVaultDoc.fromJson(json);
  if (doc == null || (!doc.newer && doc.isEmpty)) {
    return null;
  }
  // A newer build's vault goes as it is (a newer build restores it).
  return Map<String, Object?>.from(json);
}

/// Bytes the vault's section is padded to a multiple of in the copy with
/// friends: the holders see the size of each sealed piece, and the padding
/// keeps that from telling how many passwords there are.
const int kPasswordSectionPadBytes = 16 * 1024;

/// [section] padded with spaces (`z`, ignored by readers) to a multiple of
/// [kPasswordSectionPadBytes] once encoded.
Map<String, Object?> padPasswordSection(Map<String, Object?> section) {
  final Map<String, Object?> bare = <String, Object?>{...section}..remove('z');
  final int length = utf8
      .encode(jsonEncode(<String, Object?>{...bare, 'z': ''}))
      .length;
  final int target =
      ((length + kPasswordSectionPadBytes - 1) ~/ kPasswordSectionPadBytes) *
      kPasswordSectionPadBytes;
  return <String, Object?>{...bare, 'z': ' ' * (target - length)};
}
