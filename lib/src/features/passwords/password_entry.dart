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
/// Versions written on another device that the current one was not made
/// from are kept on top of these, all of them, until the person picks one.
const int kMaxPasswordHistory = 5;

/// The most version keys one marker names ([PasswordVersion.seen]): an
/// entry edited more often than this forgets its oldest versions for good.
const int kMaxPasswordSeen = 10000;

/// Most bytes of the stored vault (JSON). It goes whole into the copy with
/// friends (at most 10 MB in all) and a copy of the account. Deletion
/// markers stay as long as it has room for them: past it the oldest go
/// first, after the oldest history.
const int kMaxPasswordVaultBytes = 4 * 1024 * 1024;

/// Largest stored vault this build reads at all.
const int _maxReadBytes = 16 * 1024 * 1024;

/// The most versions read from a stored vault (anything past it is left
/// out: only a damaged or hostile store has that many).
const int _maxReadVersions = 200000;

/// The most parents a version names.
const int _maxParents = 64;

/// The most versions of one entry whose ancestry is worked out; older ones
/// count as its history (only a damaged or hostile store has that many).
const int _maxGraph = 200;

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
/// key) never mixes two edits and never drops one. Each names the versions
/// it was made from ([parents]): a version that is not an ancestor of the
/// entry's current one was written elsewhere and is shown as such until
/// the person settles it, whatever the clocks of the devices said. A
/// deletion is a version too ([deleted]), naming the versions it removed
/// ([seen]); so is the marker of forgotten versions ([forgotten]).
@immutable
final class PasswordVersion {
  const PasswordVersion({
    required this.key,
    required this.entryId,
    required this.atMillis,
    this.createdAtMillis = 0,
    this.baseMillis = 0,
    this.parents,
    this.fields = const PasswordFields(),
    this.deleted = false,
    this.forgotten = false,
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
  /// was written. Builds before 1.17.0 told by it alone which versions an
  /// edit built on (those no newer than it); this build still writes it for
  /// them, and reads it so for a version without [parents].
  final int baseMillis;

  /// The versions this one was made from: the entry's current version, and
  /// those it settles (versions written elsewhere meanwhile, a deletion it
  /// keeps the entry over). Null for a version written before 1.17.0 (see
  /// [baseMillis]); empty for a new entry's first version and for a marker.
  final List<String>? parents;
  final PasswordFields fields;

  /// A deletion marker: the entry is gone, unless a version it did not see
  /// (made on another device meanwhile) is still there.
  final bool deleted;

  /// A marker of versions forgotten on purpose (history past its length, a
  /// cleared history, a deletion the person kept the entry over): never the
  /// entry's deletion. Builds before 1.17.0 read it as a deletion that saw
  /// only those versions, which leaves the entry as it is.
  final bool forgotten;

  /// For a marker: the versions it removed.
  final List<String> seen;

  /// Whether the marker was written by a build that names [parents] (it
  /// stands for the entry's deletion until a version names it).
  bool get _knowsParents => parents != null;

  Map<String, Object?> toJson() => deleted
      ? <String, Object?>{
          'i': entryId,
          'a': atMillis,
          'd': 1,
          if (forgotten) 'h': 1,
          's': seen,
          if (parents != null) 'b': parents,
        }
      : <String, Object?>{
          'i': entryId,
          'a': atMillis,
          'c': createdAtMillis,
          'pa': baseMillis,
          if (parents != null) 'b': parents,
          if (fields.name.isNotEmpty) 'n': fields.name,
          if (fields.login.isNotEmpty) 'l': fields.login,
          if (fields.password.isNotEmpty) 'p': fields.password,
          if (fields.address.isNotEmpty) 'u': fields.address,
          if (fields.note.isNotEmpty) 'o': fields.note,
        };

  /// The version [key] as stored, or null when it is not one this build
  /// reads: typed fields only, each cut to its limit; unknown fields are
  /// ignored here and kept in the store as they are. A kind of version this
  /// build does not know (`d` other than 1) is not read either; the store
  /// keeps it as it is ([PasswordVaultDoc.foreign]).
  static PasswordVersion? fromJson(String key, Object? json) {
    if (!isPasswordId(key) ||
        json is! Map ||
        !isPasswordId(json['i']) ||
        json['a'] is! int ||
        (json.containsKey('d') && json['d'] != 1)) {
      return null;
    }
    final int at = json['a'] as int;
    final Object? b = json['b'];
    final List<String>? parents = b is List
        ? <String>[
            for (final Object? p in b.take(_maxParents))
              if (isPasswordId(p)) p! as String,
          ]
        : null;
    if (json['d'] == 1) {
      final Object? seen = json['s'];
      return PasswordVersion(
        key: key,
        entryId: json['i'] as String,
        atMillis: at,
        deleted: true,
        forgotten: json['h'] == 1,
        parents: parents,
        seen: <String>[
          if (seen is List)
            for (final Object? s in seen.take(kMaxPasswordSeen))
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
      parents: parents,
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

  /// Written on another device, and the current version was not made from
  /// it (however much earlier or later it was written): the newer one is
  /// shown, this one waits here, never forgotten, until the person takes it
  /// back or edits the entry.
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
  /// every [conflict]ing one).
  final List<PasswordHistoryItem> history;

  /// Another device changed the entry and the current version was not made
  /// from that change: its version is in [history] marked
  /// [PasswordHistoryItem.concurrent].
  final bool conflict;

  /// Another device deleted the entry, and the current version was not
  /// made knowing it (it had not seen the deletion): the entry stays, the
  /// person decides. An edit, or saving it unchanged, settles it.
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

int _newestFirst(PasswordVersion a, PasswordVersion b) =>
    a.isNewerThan(b) ? -1 : (b.isNewerThan(a) ? 1 : 0);

/// How the stored versions of one entry stand. Only the vault reads this;
/// the screens see the [PasswordEntry] made of it.
@immutable
final class PasswordEntryShape {
  const PasswordEntryShape({
    required this.entryId,
    required this.current,
    this.earlier = const <PasswordVersion>[],
    this.concurrent = const <PasswordVersion>[],
    this.pendingDeletions = const <PasswordVersion>[],
    this.settledMarkers = const <PasswordVersion>[],
  });

  final String entryId;

  /// The version shown, or null when the entry is deleted.
  final PasswordVersion? current;

  /// The ancestors of [current] still stored, nearest first: the
  /// [kMaxPasswordHistory] first are its history, the rest is forgotten
  /// at the next save.
  final List<PasswordVersion> earlier;

  /// Versions [current] was not made from (written on another device):
  /// never forgotten until the person settles them, newest first.
  final List<PasswordVersion> concurrent;

  /// Deletions [current] was not made knowing ([PasswordEntry.keptOverDeletion]).
  final List<PasswordVersion> pendingDeletions;

  /// Every other marker of the entry (for a deleted entry, all of them):
  /// forgotten versions, deletions already settled.
  final List<PasswordVersion> settledMarkers;

  /// What an edit of the entry is made from: its current version and every
  /// version or deletion it settles.
  List<String> get parentsOfNext => <String>[
    if (current != null) current!.key,
    for (final PasswordVersion v in concurrent) v.key,
    for (final PasswordVersion d in pendingDeletions) d.key,
  ];

  @override
  String toString() => 'PasswordEntryShape($entryId)';
}

/// The ancestors of [from] among [nodes], each with how many steps away it
/// is. A version that names its [PasswordVersion.parents] was made from
/// those; one written before 1.17.0 from every version (and marker) no
/// newer than its [PasswordVersion.baseMillis], as those builds read it.
Map<String, int> _ancestorsOf(
  PasswordVersion from,
  Map<String, PasswordVersion> nodes,
) {
  final Map<String, int> depth = <String, int>{};
  final List<PasswordVersion> queue = <PasswordVersion>[from];
  for (int i = 0; i < queue.length; i++) {
    final PasswordVersion v = queue[i];
    if (v.deleted) {
      continue;
    }
    final int next = (depth[v.key] ?? 0) + 1;
    final Iterable<String> parents =
        v.parents ??
        <String>[
          for (final PasswordVersion p in nodes.values)
            if (p.key != v.key && p.atMillis <= v.baseMillis) p.key,
        ];
    for (final String key in parents) {
      final PasswordVersion? p = nodes[key];
      if (p == null || key == from.key || depth.containsKey(key)) {
        continue;
      }
      depth[key] = next;
      queue.add(p);
    }
  }
  return depth;
}

/// The shape of every entry [versions] hold, by entry id.
///
/// Per entry: the versions no marker saw are alive; of them, those that no
/// other alive version was made from are its heads, and the newest head is
/// current (every device picks the same). The other alive versions are its
/// history when current was made from them, and versions written elsewhere
/// ([PasswordEntryShape.concurrent]) when it was not, however the clocks of
/// the devices compare. An entry with no alive version is deleted.
Map<String, PasswordEntryShape> passwordEntryShapes(
  Iterable<PasswordVersion> versions,
) {
  final Map<String, List<PasswordVersion>> lives =
      <String, List<PasswordVersion>>{};
  final Map<String, List<PasswordVersion>> markers =
      <String, List<PasswordVersion>>{};
  for (final PasswordVersion v in versions) {
    (v.deleted ? markers : lives)
        .putIfAbsent(v.entryId, () => <PasswordVersion>[])
        .add(v);
  }
  final Map<String, PasswordEntryShape> out = <String, PasswordEntryShape>{};
  for (final MapEntry<String, List<PasswordVersion>> m in markers.entries) {
    if (!lives.containsKey(m.key)) {
      out[m.key] = PasswordEntryShape(
        entryId: m.key,
        current: null,
        settledMarkers: m.value,
      );
    }
  }
  for (final MapEntry<String, List<PasswordVersion>> e in lives.entries) {
    final List<PasswordVersion> gone =
        markers[e.key] ?? const <PasswordVersion>[];
    final Set<String> seen = <String>{
      for (final PasswordVersion d in gone) ...d.seen,
    };
    final List<PasswordVersion> alive = <PasswordVersion>[
      for (final PasswordVersion v in e.value)
        if (!seen.contains(v.key)) v,
    ]..sort(_newestFirst);
    if (alive.isEmpty) {
      out[e.key] = PasswordEntryShape(
        entryId: e.key,
        current: null,
        settledMarkers: gone,
      );
      continue;
    }
    // Only a damaged or hostile store has more: the oldest past it are
    // taken for history.
    final List<PasswordVersion> graph = alive.take(_maxGraph).toList();
    final Map<String, PasswordVersion> nodes = <String, PasswordVersion>{
      for (final PasswordVersion v in graph) v.key: v,
      for (final PasswordVersion d in gone) d.key: d,
    };
    final Map<String, Map<String, int>> ancestors = <String, Map<String, int>>{
      for (final PasswordVersion v in graph) v.key: _ancestorsOf(v, nodes),
    };
    final Set<String> madeFrom = <String>{
      for (final Map<String, int> a in ancestors.values) ...a.keys,
    };
    final PasswordVersion current = graph.firstWhere(
      (PasswordVersion v) => !madeFrom.contains(v.key),
      // Each made from another (only a damaged store): the newest.
      orElse: () => graph.first,
    );
    final Map<String, int> known = ancestors[current.key]!;
    final List<PasswordVersion> earlier =
        <PasswordVersion>[
          for (final PasswordVersion v in graph)
            if (known.containsKey(v.key)) v,
        ]..sort((PasswordVersion a, PasswordVersion b) {
          final int byDepth = known[a.key]!.compareTo(known[b.key]!);
          return byDepth != 0 ? byDepth : _newestFirst(a, b);
        });
    earlier.addAll(alive.skip(_maxGraph));
    final List<PasswordVersion> concurrent = <PasswordVersion>[
      for (final PasswordVersion v in graph)
        if (v.key != current.key && !known.containsKey(v.key)) v,
    ];
    final List<PasswordVersion> pending = <PasswordVersion>[];
    final List<PasswordVersion> settled = <PasswordVersion>[];
    for (final PasswordVersion d in gone) {
      final bool isSettled =
          d.forgotten ||
          known.containsKey(d.key) ||
          // A deletion written before 1.17.0 counts as those builds read
          // it: settled when current is no older than it.
          (!d._knowsParents && d.atMillis <= current.baseMillis);
      (isSettled ? settled : pending).add(d);
    }
    out[e.key] = PasswordEntryShape(
      entryId: e.key,
      current: current,
      earlier: earlier,
      concurrent: concurrent,
      pendingDeletions: pending,
      settledMarkers: settled,
    );
  }
  return out;
}

/// The entry [shape] shows, or null when it is deleted.
PasswordEntry? passwordEntryOf(PasswordEntryShape shape) {
  final PasswordVersion? current = shape.current;
  if (current == null) {
    return null;
  }
  PasswordHistoryItem item(PasswordVersion v, {required bool concurrent}) =>
      PasswordHistoryItem(
        versionKey: v.key,
        fields: v.fields,
        changedAtMillis: v.atMillis,
        concurrent: concurrent,
      );
  final List<PasswordHistoryItem> history =
      <PasswordHistoryItem>[
        for (final PasswordVersion v in shape.concurrent)
          item(v, concurrent: true),
        for (final PasswordVersion v in shape.earlier.take(kMaxPasswordHistory))
          item(v, concurrent: false),
      ]..sort(
        (PasswordHistoryItem a, PasswordHistoryItem b) =>
            b.changedAtMillis.compareTo(a.changedAtMillis),
      );
  int created = current.createdAtMillis;
  for (final PasswordVersion v in <PasswordVersion>[
    ...shape.earlier,
    ...shape.concurrent,
  ]) {
    if (v.createdAtMillis > 0 && v.createdAtMillis < created) {
      created = v.createdAtMillis;
    }
  }
  return PasswordEntry(
    id: shape.entryId,
    versionKey: current.key,
    fields: current.fields,
    createdAtMillis: created,
    changedAtMillis: current.atMillis,
    history: history,
    conflict: shape.concurrent.isNotEmpty,
    keptOverDeletion: shape.pendingDeletions.isNotEmpty,
  );
}

/// The entries [versions] make ([passwordEntryShapes]); entries whose
/// every version a deletion saw are gone. Sorted by name (then login), as
/// the list shows them.
List<PasswordEntry> passwordEntriesOf(Iterable<PasswordVersion> versions) =>
    <PasswordEntry>[
      for (final PasswordEntryShape s in passwordEntryShapes(versions).values)
        if (passwordEntryOf(s) case final PasswordEntry e) e,
    ]..sort(comparePasswordEntries);

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
/// newer build added are written back untouched), those of a kind this
/// build does not read, and its other fields.
@immutable
final class PasswordVaultDoc {
  const PasswordVaultDoc({
    this.raw = const <String, Map<String, Object?>>{},
    this.versions = const <String, PasswordVersion>{},
    this.foreign = const <String, Map<String, Object?>>{},
    this.carried = const <String, Object?>{},
    this.newer = false,
  });

  /// Version key → the version as stored.
  final Map<String, Map<String, Object?>> raw;

  /// Version key → the version as this build reads it.
  final Map<String, PasswordVersion> versions;

  /// Version key → a stored version this build does not read (a kind a
  /// newer build added): written back as it is, never dropped, so a newer
  /// device's data comes through a round trip here whole.
  final Map<String, Map<String, Object?>> foreign;

  /// Top-level fields a newer build added.
  final Map<String, Object?> carried;

  /// Written in a format newer than this build reads: kept as it is,
  /// never written over.
  final bool newer;

  bool get isEmpty => raw.isEmpty && foreign.isEmpty;

  /// The stored form: `{v, e: {version key: version}}`.
  Map<String, Object?> toJson() => withCarriedFields(<String, Object?>{
    kFormatVersionKey: kPasswordVaultFormat,
    if (raw.isNotEmpty || foreign.isNotEmpty)
      'e': <String, Object?>{...foreign, ...raw},
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
    final Map<String, Map<String, Object?>> foreign =
        <String, Map<String, Object?>>{};
    final Object? e = json['e'];
    if (e is Map) {
      for (final MapEntry<dynamic, dynamic> v in e.entries) {
        if (versions.length + foreign.length >= _maxReadVersions) {
          break;
        }
        final Object? key = v.key;
        final Object? value = v.value;
        if (key is! String || !isPasswordId(key) || value is! Map) {
          continue;
        }
        final PasswordVersion? version = PasswordVersion.fromJson(key, value);
        if (version == null) {
          foreign[key] = Map<String, Object?>.from(value);
          continue;
        }
        versions[key] = version;
        raw[key] = Map<String, Object?>.from(value);
      }
    }
    return PasswordVaultDoc(
      raw: raw,
      versions: versions,
      foreign: foreign,
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
