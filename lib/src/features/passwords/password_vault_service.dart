import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_match.dart';
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// How long a copied password or login stays on the clipboard.
const Duration kPasswordClipboardTtl = Duration(seconds: 30);

/// Why the vault refused something.
enum PasswordVaultError {
  /// Zen is locked: nothing of the vault is read or written.
  locked,

  /// The stored vault was written by a newer Zen: kept as it is, read-only
  /// until Zen is updated.
  newerFormat,

  /// The stored vault does not read (damaged): kept as it is, read-only,
  /// never written over and never taken for an empty one.
  damaged,

  /// No such entry (deleted meanwhile, maybe on another device).
  notFound,

  /// The fields cannot be saved ([PasswordFields.problem]).
  invalid,

  /// [kMaxPasswordEntries] entries, or [kMaxPasswordVaultBytes].
  full,
}

/// The vault refused something ([error]); its text names no field.
final class PasswordVaultException implements Exception {
  const PasswordVaultException(this.error, [this.problem]);

  final PasswordVaultError error;

  /// For [PasswordVaultError.invalid]: what is wrong.
  final PasswordFieldsProblem? problem;

  @override
  String toString() => 'PasswordVaultException(${error.name})';
}

/// What an import did: rows read, entries made, rows left out and why.
@immutable
final class PasswordImportReport {
  const PasswordImportReport({
    this.layout,
    this.error,
    this.read = 0,
    this.imported = 0,
    this.skipped = const <PasswordImportSkip, int>{},
    this.damaged = const <PasswordCsvDamage>[],
  });

  /// Whose export the file was (null when it was not taken at all).
  final PasswordCsvLayout? layout;

  /// Why the whole file was not taken.
  final PasswordCsvError? error;

  /// Rows read after the header.
  final int read;

  /// New entries made.
  final int imported;

  /// Rows left out, by reason.
  final Map<PasswordImportSkip, int> skipped;

  /// Where the file's damaged rows are ([PasswordCsvParse.damaged]).
  final List<PasswordCsvDamage> damaged;

  int get skippedCount => skipped.values.fold(0, (int a, int b) => a + b);

  @override
  String toString() =>
      'PasswordImportReport(${layout?.name ?? error?.name}, read $read, '
      'imported $imported, skipped $skippedCount)';
}

/// The account's passwords ("Hasła"): entries of a name, a login, a
/// password, an address (a web page or an app) and a note, the same on
/// every device of the account.
///
/// Kept only in the account's encrypted store ([kPasswordVaultKey]) as a
/// map of versions: every add, edit, restore or deletion writes a new
/// version and never changes one, so the account's sync, which merges a
/// stored map key by key, takes edits made on two devices at once from
/// both. The entry shows the newer one by time; the other stays in its
/// history, marked as written elsewhere at the same time, until the person
/// takes it back or edits the entry ([PasswordEntry.conflict]). A deletion
/// removes the versions it saw and leaves a marker; a version it did not
/// see (written meanwhile on another device) keeps the entry
/// ([PasswordEntry.keptOverDeletion]). Each entry keeps its last
/// [kMaxPasswordHistory] versions, so a mistaken edit can be undone.
///
/// While Zen is locked nothing of it is read, written or held in memory
/// ([forget]); every call then fails with [PasswordVaultError.locked] and
/// [entries] is empty. Every disk access goes through one queue, the
/// sync's included ([syncState], [takeSyncState]), so an edit never
/// writes over what another device's change just wrote.
final class PasswordVaultService extends ChangeNotifier {
  PasswordVaultService({
    required this.disk,
    int Function()? now,
    Random? random,
    bool Function()? isLocked,
    Future<bool> Function(String text)? copy,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure(),
       _isLocked = isLocked ?? (() => false),
       _copy =
           copy ??
           ((String text) => copyWithExpiry(text, ttl: kPasswordClipboardTtl));

  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;
  final bool Function() _isLocked;
  final Future<bool> Function(String text) _copy;

  PasswordVaultDoc _doc = const PasswordVaultDoc();
  List<PasswordEntry> _entries = const <PasswordEntry>[];
  bool _loaded = false;
  Future<void> _queue = Future<void>.value();

  /// Fires after a change made on this device (not after a change taken
  /// from another device, nor a load): the copy with friends and the sync
  /// look then.
  Listenable get edits => _edits;
  final _Edits _edits = _Edits();

  /// Whether the stored vault was read (since the last [forget]).
  bool get loaded => _loaded;

  /// Whether the stored vault is in a newer build's format (read-only).
  bool get newerFormat => _doc.newer && !_damaged;

  /// Whether the stored vault does not read (read-only, kept as it is).
  bool get damaged => _damaged;
  bool _damaged = false;

  /// The entries, sorted by name; empty while locked or not loaded.
  List<PasswordEntry> get entries =>
      _isLocked() ? const <PasswordEntry>[] : _entries;

  /// The entry [id], if there is one.
  PasswordEntry? entry(String id) {
    for (final PasswordEntry e in entries) {
      if (e.id == id) {
        return e;
      }
    }
    return null;
  }

  /// The entries whose name, login or address holds [query], compared as
  /// the chats' search compares ([foldForSearch]: ignoring case and
  /// accents, so "zolw" finds "Żółw"); all of them for an empty query.
  /// Passwords and notes are never searched.
  List<PasswordEntry> search(String query) {
    final String q = foldForSearch(query.trim());
    if (q.isEmpty) {
      return entries;
    }
    return <PasswordEntry>[
      for (final PasswordEntry e in entries)
        if (foldForSearch(e.name).contains(q) ||
            foldForSearch(e.login).contains(q) ||
            foldForSearch(e.address).contains(q))
          e,
    ];
  }

  /// How many entries [removeDuplicates] would remove.
  int get duplicateCount => _removableDuplicates(entries).length;

  /// The entries the autofill may offer in the app [packageName] (signed
  /// with [appCertificates]) or on the page [webDomain]
  /// ([matchPasswordEntries]).
  List<PasswordMatch> matchesFor({
    String? packageName,
    String? webDomain,
    String? webScheme,
    Iterable<String> appCertificates = const <String>[],
  }) => matchPasswordEntries(
    entries,
    packageName: packageName,
    webDomain: webDomain,
    webScheme: webScheme,
    appCertificates: appCertificates,
  );

  /// Drops everything read from the vault from memory (Zen locked).
  void forget() {
    if (!_loaded && _entries.isEmpty) {
      return;
    }
    _doc = const PasswordVaultDoc();
    _entries = const <PasswordEntry>[];
    _loaded = false;
    notifyListeners();
  }

  /// Reads the stored vault again.
  Future<void> load() => _serial(() async {
    _ensureOpen();
    await _read();
  });

  /// A new entry of [fields].
  Future<PasswordEntry> add(PasswordFields fields) => _serial(() async {
    await _ready();
    final PasswordFields clean = _checked(fields);
    if (_entries.length >= kMaxPasswordEntries) {
      throw const PasswordVaultException(PasswordVaultError.full);
    }
    final String id = _newId();
    final int at = _now();
    final Map<String, Map<String, Object?>> raw = _withVersion(
      _doc.raw,
      PasswordVersion(
        key: _newId(),
        entryId: id,
        atMillis: at,
        createdAtMillis: at,
        parents: const <String>[],
        fields: clean,
      ),
    );
    await _save(raw, growing: true);
    return entry(id)!;
  });

  /// Saves [fields] as the entry [id]'s new version; its earlier one goes
  /// into its history. Unchanged fields change nothing, unless the entry
  /// waits for the person ([PasswordEntry.conflict],
  /// [PasswordEntry.keptOverDeletion]): saved as they are, they settle it
  /// ("Zostaw obecną", "Zostaw"), on every device.
  Future<PasswordEntry> edit(String id, PasswordFields fields) =>
      _serial(() async {
        await _ready();
        final PasswordEntry current = _existing(id);
        final PasswordFields clean = _checked(fields);
        if (clean.sameAs(current.fields) &&
            !current.conflict &&
            !current.keptOverDeletion) {
          return current;
        }
        await _save(_newVersionOf(current, clean), growing: true);
        return entry(id)!;
      });

  /// Takes the entry [id]'s earlier version [versionKey] back (as a new
  /// version: what it replaces stays in the history).
  Future<PasswordEntry> restorePrevious(String id, String versionKey) =>
      _serial(() async {
        await _ready();
        final PasswordEntry current = _existing(id);
        final PasswordVersion? old = _doc.versions[versionKey];
        if (old == null || old.entryId != id || old.deleted) {
          throw const PasswordVaultException(PasswordVaultError.notFound);
        }
        await _save(_newVersionOf(current, old.fields), growing: true);
        return entry(id)!;
      });

  /// Forgets the entry [id]'s earlier versions (its old passwords, and
  /// those written elsewhere it waits on), on every device. A marker names
  /// them ([PasswordVersion.forgotten]): a copy or a device that was away
  /// and still holds them never brings them back ([_pruned] drops what a
  /// marker saw). Earlier markers of the entry are folded into it.
  Future<PasswordEntry> clearHistory(String id) => _serial(() async {
    await _ready();
    _existing(id);
    final PasswordEntryShape shape = _shapeOf(id);
    final PasswordVersion current = shape.current!;
    final List<PasswordVersion> dropped = <PasswordVersion>[
      ...shape.earlier,
      ...shape.concurrent,
    ];
    final List<PasswordVersion> markers = <PasswordVersion>[
      ...shape.settledMarkers,
      ...shape.pendingDeletions,
    ];
    if (dropped.isEmpty && markers.isEmpty) {
      return entry(id)!;
    }
    final Map<String, Map<String, Object?>> raw =
        <String, Map<String, Object?>>{..._doc.raw};
    for (final PasswordVersion v in <PasswordVersion>[...dropped, ...markers]) {
      raw.remove(v.key);
    }
    final PasswordVersion marker = _forgottenMarker(current, dropped, markers);
    raw[marker.key] = marker.toJson();
    await _save(raw);
    return entry(id)!;
  });

  /// Deletes the entry [id] on every device, with its history. False when
  /// there is no such entry.
  Future<bool> delete(String id) async => await deleteMany(<String>[id]) == 1;

  /// Deletes the entries [ids] on every device, with their history, in one
  /// save. Returns how many there were to delete.
  Future<int> deleteMany(Iterable<String> ids) => _serial(() async {
    await _ready();
    final Set<String> gone = <String>{
      for (final String id in ids)
        if (entry(id) != null) id,
    };
    if (gone.isEmpty) {
      return 0;
    }
    await _save(_withDeletions(_doc.raw, gone));
    return gone.length;
  });

  /// Removes the entries that are exact copies of another one (every field
  /// the same: an export imported twice, on two devices before they
  /// synced), on every device. Of each group the entry with the longest
  /// history stays (then the oldest); a copy is removed only when it has
  /// no history and nothing that waits on the person, so no password goes
  /// with it. Returns how many were removed.
  Future<int> removeDuplicates() => _serial(() async {
    await _ready();
    final Set<String> gone = _removableDuplicates(_entries);
    if (gone.isEmpty) {
      return 0;
    }
    await _save(_withDeletions(_doc.raw, gone));
    return gone.length;
  });

  /// Puts the entry [id]'s password on the clipboard, cleared after
  /// [kPasswordClipboardTtl] (and when Zen locks): only ever through
  /// [copyWithExpiry]. False when it did not get there.
  Future<bool> copyPassword(String id) async {
    final PasswordEntry? e = entry(id);
    if (e == null || e.password.isEmpty) {
      return false;
    }
    return _copy(e.password);
  }

  /// Puts the entry [id]'s login on the clipboard, the same way.
  Future<bool> copyLogin(String id) async {
    final PasswordEntry? e = entry(id);
    if (e == null || e.login.isEmpty) {
      return false;
    }
    return _copy(e.login);
  }

  /// Puts the earlier password [versionKey] of the entry [id] (one of its
  /// [PasswordEntry.history]) on the clipboard, the same way.
  Future<bool> copyPreviousPassword(String id, String versionKey) async {
    for (final PasswordHistoryItem h
        in entry(id)?.history ?? const <PasswordHistoryItem>[]) {
      if (h.versionKey == versionKey && h.password.isNotEmpty) {
        return _copy(h.password);
      }
    }
    return false;
  }

  /// Takes the passwords of an export ([bytes] of a CSV file: Chrome, Edge,
  /// Firefox, Bitwarden, KeePass, KeePassXC or any file whose header names
  /// its columns). Each row becomes a new entry, unless one with the same
  /// name or address, login and password is there already. Nothing of the
  /// file is kept or logged; [bytes] are overwritten with zeros once read.
  Future<PasswordImportReport> importCsv(Uint8List bytes) {
    final PasswordCsvParse parse;
    try {
      parse = parsePasswordCsv(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    return importRows(parse);
  }

  /// Takes the rows of [parse] ([importCsv]).
  Future<PasswordImportReport> importRows(PasswordCsvParse parse) =>
      _serial(() async {
        if (parse.error != null) {
          return PasswordImportReport(error: parse.error);
        }
        await _ready();
        final Map<PasswordImportSkip, int> skipped = <PasswordImportSkip, int>{
          ...parse.skipped,
        };
        void skip(PasswordImportSkip why) =>
            skipped[why] = (skipped[why] ?? 0) + 1;
        String same(PasswordFields f) => jsonEncode(<String>[
          (f.address.isNotEmpty ? f.address : f.name).toLowerCase(),
          f.login,
          f.password,
        ]);
        final Set<String> have = <String>{
          for (final PasswordEntry e in _entries) same(e.fields),
        };
        Map<String, Map<String, Object?>> raw = <String, Map<String, Object?>>{
          ..._doc.raw,
        };
        final List<String> added = <String>[];
        final int at = _now();
        for (final PasswordCsvRow row in parse.rows) {
          if (!have.add(same(row.fields))) {
            skip(PasswordImportSkip.duplicate);
            continue;
          }
          if (_entries.length + added.length >= kMaxPasswordEntries) {
            skip(PasswordImportSkip.full);
            continue;
          }
          final PasswordVersion v = PasswordVersion(
            key: _newId(),
            entryId: _newId(),
            atMillis: at,
            createdAtMillis: at,
            parents: const <String>[],
            fields: row.fields,
          );
          raw[v.key] = v.toJson();
          added.add(v.key);
        }
        int over = _overBytes(raw);
        if (over > 0) {
          // The oldest history goes first; rows that still do not fit stay
          // out, the last ones first.
          raw = _trimmed(raw, over, dropMarkers: false);
          over = _overBytes(raw);
          int gone = 0;
          while (gone < over && added.isNotEmpty) {
            final String key = added.removeLast();
            gone += utf8
                .encode(jsonEncode(<String, Object?>{key: raw.remove(key)}))
                .length;
            skip(PasswordImportSkip.full);
          }
        }
        final int imported = added.length;
        if (imported > 0) {
          await _save(raw, growing: true);
        }
        return PasswordImportReport(
          layout: parse.layout,
          read: parse.read,
          imported: imported,
          skipped: skipped,
          damaged: parse.damaged,
        );
      });

  // ---- for the account's sync and its copies ----

  /// The stored vault as the account's sync reads it: null while locked,
  /// when it does not read, or when a newer build wrote it (nothing is
  /// sent or removed then); an empty map when there is none yet.
  Future<Map<String, Object?>?> syncState() => _serial(() async {
    if (_isLocked()) {
      return null;
    }
    final Uint8List? bytes = await disk.read(kPasswordVaultKey);
    if (bytes == null) {
      return <String, Object?>{};
    }
    final Object? json = _decode(bytes);
    final PasswordVaultDoc? doc = PasswordVaultDoc.fromJson(json);
    if (doc == null || doc.newer) {
      return null;
    }
    return Map<String, Object?>.from(json! as Map);
  });

  /// Writes [state] (the account's sync merged another device's change
  /// in) and reads it back. Throws while locked: the sync tries again.
  /// What no longer counts (versions a deletion or a cleared history saw,
  /// history past its length) is settled on the way, as a save here
  /// settles it: an old password that comes back from a device that was
  /// away is not written into the store again. An entry that is an exact
  /// copy of another one, both never edited (the same export imported on
  /// two devices before they synced), is folded into the one every device
  /// keeps ([_withoutCopies]). Versions this build does not read stay as
  /// they are. What this adds itself goes to the other devices as a change
  /// of this one; every device adds the same.
  Future<void> takeSyncState(Map<String, Object?> state) => _serial(() async {
    _ensureOpen();
    Map<String, Object?> next = state;
    bool added = false;
    final PasswordVaultDoc? doc = PasswordVaultDoc.fromJson(state);
    if (doc != null && !doc.newer && state['e'] is Map) {
      final Map<String, Map<String, Object?>> settled = _pruned(
        _withoutCopies(doc.raw),
      );
      added = settled.keys.any((String k) => !doc.raw.containsKey(k));
      next = PasswordVaultDoc(
        raw: settled,
        foreign: doc.foreign,
        carried: doc.carried,
      ).toJson();
    }
    await disk.write(
      kPasswordVaultKey,
      Uint8List.fromList(utf8.encode(jsonEncode(next))),
    );
    await _read();
    if (added) {
      _edits.changed();
    }
  });

  /// The stored vault for a copy of the account or the copy with friends
  /// ([passwordVaultSectionOf]); null when there is nothing in it. Throws
  /// while locked, so a copy is never made without it.
  Future<Map<String, Object?>?> exportForCopy() => _serial(() async {
    _ensureOpen();
    return passwordVaultSectionOf(await disk.read(kPasswordVaultKey));
  });

  /// Takes the vault of a copy ([section]: a backup file, another device's
  /// copy, the copy with friends) in with what is here: versions missing
  /// here are added, nothing here is removed, a deletion here stays. Returns
  /// how many versions came in.
  Future<int> mergeCopy(Object? section) => _serial(() async {
    await _ready();
    final PasswordVaultDoc? copy = PasswordVaultDoc.fromJson(section);
    if (copy == null || copy.newer) {
      logZenWarning(
        'The passwords of a copy were not taken '
        '(${copy == null ? 'damaged' : 'newer format'}).',
      );
      return 0;
    }
    final Map<String, Map<String, Object?>> raw = _pruned(
      _withoutCopies(<String, Map<String, Object?>>{...copy.raw, ..._doc.raw}),
    );
    final Map<String, Map<String, Object?>> foreign =
        <String, Map<String, Object?>>{...copy.foreign, ..._doc.foreign};
    // What a deletion here saw, or what is older than the history kept,
    // does not come back; markers made here on the way are not counted.
    final int added =
        raw.keys
            .where(
              (String k) => copy.raw.containsKey(k) && !_doc.raw.containsKey(k),
            )
            .length +
        foreign.length -
        _doc.foreign.length;
    if (added > 0) {
      await _save(raw, foreign: foreign);
    }
    return added;
  });

  // ---- inside ----

  Future<T> _serial<T>(Future<T> Function() work) {
    final Future<T> result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _ensureOpen() {
    if (_isLocked()) {
      throw const PasswordVaultException(PasswordVaultError.locked);
    }
  }

  /// Open, read, and not a newer build's vault.
  Future<void> _ready() async {
    _ensureOpen();
    if (!_loaded) {
      await _read();
    }
    if (_damaged) {
      throw const PasswordVaultException(PasswordVaultError.damaged);
    }
    if (_doc.newer) {
      throw const PasswordVaultException(PasswordVaultError.newerFormat);
    }
  }

  Object? _decode(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      // Never the error's text: it quotes the stored bytes.
      return null;
    }
  }

  Future<void> _read() async {
    final Uint8List? bytes = await disk.read(kPasswordVaultKey);
    PasswordVaultDoc doc = const PasswordVaultDoc();
    bool damaged = false;
    if (bytes != null) {
      final PasswordVaultDoc? read = PasswordVaultDoc.fromBytes(bytes);
      if (read == null) {
        // Damaged: read-only and never saved over. Not taken for an empty
        // vault either: the sync would then delete every password on the
        // account's other devices. It sends nothing from here meanwhile.
        logZenWarning('The stored passwords do not read; left as they are.');
        damaged = true;
        doc = const PasswordVaultDoc(newer: true);
      } else {
        doc = read;
        if (doc.newer) {
          ZenFormatGuard.instance.noteNewer(kPasswordVaultKey);
        }
      }
    }
    if (_isLocked()) {
      // Locked while reading: nothing of it stays.
      forget();
      throw const PasswordVaultException(PasswordVaultError.locked);
    }
    _doc = doc;
    _damaged = damaged;
    _entries = passwordEntriesOf(doc.versions.values);
    _loaded = true;
    notifyListeners();
  }

  PasswordFields _checked(PasswordFields fields) {
    final PasswordFields clean = fields.trimmed();
    final PasswordFieldsProblem? problem = clean.problem;
    if (problem != null) {
      throw PasswordVaultException(PasswordVaultError.invalid, problem);
    }
    return clean;
  }

  PasswordEntry _existing(String id) {
    final PasswordEntry? e = entry(id);
    if (e == null) {
      throw const PasswordVaultException(PasswordVaultError.notFound);
    }
    return e;
  }

  /// How the entry [id]'s versions stand in the store now.
  PasswordEntryShape _shapeOf(String id) =>
      passwordEntryShapes(<PasswordVersion>[
        for (final PasswordVersion v in _doc.versions.values)
          if (v.entryId == id) v,
      ])[id]!;

  /// The versions with a new one of [current] holding [fields]: it is made
  /// from the entry's current version and everything that waits on the
  /// person (versions written elsewhere, a deletion it was kept over), so
  /// an edit settles a conflict ([PasswordEntryShape.parentsOfNext]).
  Map<String, Map<String, Object?>> _newVersionOf(
    PasswordEntry current,
    PasswordFields fields,
  ) {
    int newest = 0;
    for (final PasswordVersion v in _doc.versions.values) {
      if (v.entryId == current.id && v.atMillis > newest) {
        newest = v.atMillis;
      }
    }
    return _withVersion(
      _doc.raw,
      PasswordVersion(
        key: _newId(),
        entryId: current.id,
        // Always after what it replaces, even within one millisecond.
        atMillis: max(_now(), newest + 1),
        createdAtMillis: current.createdAtMillis,
        // For builds before 1.17.0, which tell what an edit built on by it.
        baseMillis: newest,
        parents: _shapeOf(current.id).parentsOfNext,
        fields: fields,
      ),
    );
  }

  Map<String, Map<String, Object?>> _withVersion(
    Map<String, Map<String, Object?>> raw,
    PasswordVersion v,
  ) => <String, Map<String, Object?>>{...raw, v.key: v.toJson()};

  String _newId() {
    const String digits = '0123456789abcdefghijklmnopqrstuvwxyz';
    return String.fromCharCodes(<int>[
      for (int i = 0; i < 20; i++)
        digits.codeUnitAt(_random.nextInt(digits.length)),
    ]);
  }

  /// The versions [raw] reads as (those this build understands).
  Map<String, PasswordVersion> _versionsOf(
    Map<String, Map<String, Object?>> raw,
  ) => <String, PasswordVersion>{
    for (final MapEntry<String, Map<String, Object?>> e in raw.entries)
      if (PasswordVersion.fromJson(e.key, e.value) case final PasswordVersion v)
        e.key: v,
  };

  /// [raw] with deletion markers of the entries [ids]: each names every
  /// version of its entry here (earlier markers of the entry are folded
  /// into it), and is later than all of them.
  Map<String, Map<String, Object?>> _withDeletions(
    Map<String, Map<String, Object?>> raw,
    Set<String> ids,
  ) {
    final Map<String, Set<String>> seen = <String, Set<String>>{};
    final Map<String, int> at = <String, int>{};
    final int now = _now();
    final Map<String, Map<String, Object?>> out =
        <String, Map<String, Object?>>{};
    for (final MapEntry<String, Map<String, Object?>> e in raw.entries) {
      final PasswordVersion? v = PasswordVersion.fromJson(e.key, e.value);
      if (v == null || !ids.contains(v.entryId)) {
        out[e.key] = e.value;
        continue;
      }
      (seen[v.entryId] ??= <String>{}).addAll(
        v.deleted ? v.seen : <String>[v.key],
      );
      at[v.entryId] = max(at[v.entryId] ?? now, v.atMillis + 1);
    }
    for (final MapEntry<String, Set<String>> e in seen.entries) {
      final PasswordVersion marker = PasswordVersion(
        key: _newId(),
        entryId: e.key,
        atMillis: at[e.key]!,
        deleted: true,
        parents: const <String>[],
        seen: e.value.take(kMaxPasswordSeen).toList(),
      );
      out[marker.key] = marker.toJson();
    }
    return out;
  }

  /// The marker of the entry of [current] that names [dropped] and every
  /// version [markers] named, as forgotten ([PasswordVersion.forgotten]).
  /// Its key and what it names follow from those alone, so every device
  /// that settles the same versions writes the same marker.
  PasswordVersion _forgottenMarker(
    PasswordVersion current,
    List<PasswordVersion> dropped,
    List<PasswordVersion> markers,
  ) {
    final List<String> seen = <String>{
      for (final PasswordVersion m in markers) ...m.seen,
      for (final PasswordVersion v in dropped) v.key,
    }.toList()..sort();
    // Not after the current version's base, nor after anything it names:
    // a build before 1.17.0 then takes it for a deletion it has seen.
    int at = current.baseMillis;
    for (final PasswordVersion v in <PasswordVersion>[...dropped, ...markers]) {
      at = min(at, v.atMillis);
    }
    final List<String> named = seen.take(kMaxPasswordSeen).toList();
    return PasswordVersion(
      key: _derivedKey('forgotten', current.entryId, named),
      entryId: current.entryId,
      atMillis: max(0, at),
      deleted: true,
      forgotten: true,
      parents: const <String>[],
      seen: named,
    );
  }

  /// [raw] with what no longer counts settled. Per entry: versions a marker
  /// saw are dropped; its history past [kMaxPasswordHistory] (and the
  /// versions in [forget]) and the markers it settled are folded into one
  /// marker of forgotten versions ([_forgottenMarker]), so none of them
  /// comes back from an older copy or a device that was away. A version
  /// the current one was not made from, and a deletion it was not made
  /// knowing, are never dropped here. A deleted entry keeps its markers.
  Map<String, Map<String, Object?>> _pruned(
    Map<String, Map<String, Object?>> raw, {
    Set<String> forget = const <String>{},
  }) {
    final Map<String, PasswordVersion> versions = _versionsOf(raw);
    final Set<String> keep = <String>{};
    final List<PasswordVersion> made = <PasswordVersion>[];
    for (final PasswordEntryShape s in passwordEntryShapes(
      versions.values,
    ).values) {
      final PasswordVersion? current = s.current;
      if (current == null) {
        keep.addAll(s.settledMarkers.map((PasswordVersion m) => m.key));
        continue;
      }
      final List<PasswordVersion> dropped = <PasswordVersion>[];
      int kept = 0;
      for (final PasswordVersion v in s.earlier) {
        if (kept < kMaxPasswordHistory && !forget.contains(v.key)) {
          keep.add(v.key);
          kept++;
        } else {
          dropped.add(v);
        }
      }
      keep
        ..add(current.key)
        ..addAll(s.concurrent.map((PasswordVersion v) => v.key))
        ..addAll(s.pendingDeletions.map((PasswordVersion d) => d.key));
      final List<PasswordVersion> settled = s.settledMarkers;
      if (dropped.isEmpty &&
          (settled.isEmpty ||
              (settled.length == 1 && settled.single.forgotten))) {
        keep.addAll(settled.map((PasswordVersion m) => m.key));
        continue;
      }
      made.add(_forgottenMarker(current, dropped, settled));
    }
    return <String, Map<String, Object?>>{
      for (final MapEntry<String, Map<String, Object?>> e in raw.entries)
        if (keep.contains(e.key)) e.key: e.value,
      for (final PasswordVersion m in made) m.key: m.toJson(),
    };
  }

  /// [raw] with every entry that is an exact copy of another one, both
  /// never edited and with no marker (the same export imported on two
  /// devices before they synced), deleted: of each group the entry with
  /// the lowest id stays. The deletion's key and contents follow from the
  /// copy alone, so every device that sees the same copies writes the
  /// same deletion.
  Map<String, Map<String, Object?>> _withoutCopies(
    Map<String, Map<String, Object?>> raw,
  ) {
    final Map<String, List<PasswordVersion>> groups =
        <String, List<PasswordVersion>>{};
    for (final PasswordEntryShape s in passwordEntryShapes(
      _versionsOf(raw).values,
    ).values) {
      final PasswordVersion? v = s.current;
      if (v == null ||
          s.earlier.isNotEmpty ||
          s.concurrent.isNotEmpty ||
          s.pendingDeletions.isNotEmpty ||
          s.settledMarkers.isNotEmpty) {
        continue;
      }
      groups.putIfAbsent(_sameKey(v.fields), () => <PasswordVersion>[]).add(v);
    }
    final Map<String, Map<String, Object?>> out =
        <String, Map<String, Object?>>{...raw};
    for (final List<PasswordVersion> group in groups.values) {
      if (group.length < 2) {
        continue;
      }
      group.sort(
        (PasswordVersion a, PasswordVersion b) =>
            a.entryId.compareTo(b.entryId),
      );
      for (final PasswordVersion copy in group.skip(1)) {
        final PasswordVersion marker = PasswordVersion(
          key: _derivedKey('copy', copy.entryId, <String>[copy.key]),
          entryId: copy.entryId,
          atMillis: copy.atMillis + 1,
          deleted: true,
          parents: const <String>[],
          seen: <String>[copy.key],
        );
        out[marker.key] = marker.toJson();
      }
    }
    return out;
  }

  int _bytesOf(Map<String, Map<String, Object?>> raw) => utf8
      .encode(
        jsonEncode(
          PasswordVaultDoc(
            raw: raw,
            foreign: _doc.foreign,
            carried: _doc.carried,
          ).toJson(),
        ),
      )
      .length;

  int _overBytes(Map<String, Map<String, Object?>> raw) =>
      _bytesOf(raw) - kMaxPasswordVaultBytes;

  /// [raw] with the oldest earlier versions (never an entry's current one,
  /// nor one written elsewhere it was not made from) forgotten until about
  /// [over] bytes are gone; with [dropMarkers], then the oldest markers of
  /// deleted entries too, while it is still too large.
  Map<String, Map<String, Object?>> _trimmed(
    Map<String, Map<String, Object?>> raw,
    int over, {
    bool dropMarkers = true,
  }) {
    final Map<String, PasswordEntryShape> shapes = passwordEntryShapes(
      _versionsOf(raw).values,
    );
    final List<PasswordVersion> old =
        <PasswordVersion>[
          for (final PasswordEntryShape s in shapes.values)
            if (s.current != null) ...s.earlier.take(kMaxPasswordHistory),
        ]..sort(
          (PasswordVersion a, PasswordVersion b) =>
              a.atMillis.compareTo(b.atMillis),
        );
    final Set<String> forget = <String>{};
    int gone = 0;
    for (final PasswordVersion v in old) {
      if (gone >= over) {
        break;
      }
      forget.add(v.key);
      gone += utf8
          .encode(jsonEncode(<String, Object?>{v.key: raw[v.key]}))
          .length;
    }
    final Map<String, Map<String, Object?>> out = _pruned(raw, forget: forget);
    if (!dropMarkers) {
      return out;
    }
    final List<PasswordVersion> markers =
        <PasswordVersion>[
          for (final PasswordEntryShape s in shapes.values)
            if (s.current == null) ...s.settledMarkers,
        ]..sort(
          (PasswordVersion a, PasswordVersion b) =>
              a.atMillis.compareTo(b.atMillis),
        );
    int still = _overBytes(out);
    for (final PasswordVersion m in markers) {
      if (still <= 0) {
        break;
      }
      final Map<String, Object?>? removed = out.remove(m.key);
      if (removed != null) {
        still -= utf8
            .encode(jsonEncode(<String, Object?>{m.key: removed}))
            .length;
      }
    }
    return out;
  }

  /// Settles [raw] ([_pruned]), checks its size ([growing]: refused when
  /// it does not fit even with the oldest history gone) and writes it, with
  /// the versions of a kind this build does not read ([foreign], those
  /// stored here unless given).
  Future<void> _save(
    Map<String, Map<String, Object?>> raw, {
    bool growing = false,
    Map<String, Map<String, Object?>>? foreign,
  }) async {
    Map<String, Map<String, Object?>> next = _pruned(raw);
    final int over = _overBytes(next);
    if (over > 0) {
      next = _trimmed(next, over, dropMarkers: !growing);
      if (growing && _overBytes(next) > 0) {
        throw const PasswordVaultException(PasswordVaultError.full);
      }
    }
    final PasswordVaultDoc doc = PasswordVaultDoc(
      raw: next,
      versions: _versionsOf(next),
      foreign: foreign ?? _doc.foreign,
      carried: _doc.carried,
    );
    _ensureOpen();
    await disk.write(
      kPasswordVaultKey,
      Uint8List.fromList(utf8.encode(jsonEncode(doc.toJson()))),
    );
    _doc = doc;
    _entries = passwordEntriesOf(doc.versions.values);
    notifyListeners();
    _edits.changed();
  }
}

/// What two entries with every field the same have in common.
String _sameKey(PasswordFields f) =>
    jsonEncode(<String>[f.name, f.login, f.password, f.address, f.note]);

/// A version key that follows from [kind], [entryId] and [parts] alone
/// (24 hex digits; random keys have 20 letters and digits).
String _derivedKey(String kind, String entryId, List<String> parts) => sha256
    .convert(utf8.encode('$kind\n$entryId\n${parts.join(',')}'))
    .toString()
    .substring(0, 24);

/// The ids of the entries of [entries] that [PasswordVaultService.
/// removeDuplicates] removes.
Set<String> _removableDuplicates(List<PasswordEntry> entries) {
  final Map<String, List<PasswordEntry>> groups =
      <String, List<PasswordEntry>>{};
  for (final PasswordEntry e in entries) {
    groups.putIfAbsent(_sameKey(e.fields), () => <PasswordEntry>[]).add(e);
  }
  final Set<String> out = <String>{};
  for (final List<PasswordEntry> group in groups.values) {
    if (group.length < 2) {
      continue;
    }
    group.sort((PasswordEntry a, PasswordEntry b) {
      final int byHistory = b.history.length.compareTo(a.history.length);
      if (byHistory != 0) {
        return byHistory;
      }
      final int byAge = a.createdAtMillis.compareTo(b.createdAtMillis);
      return byAge != 0 ? byAge : a.id.compareTo(b.id);
    });
    for (final PasswordEntry e in group.skip(1)) {
      if (e.history.isEmpty && !e.conflict && !e.keptOverDeletion) {
        out.add(e.id);
      }
    }
  }
  return out;
}

final class _Edits extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// This account's passwords. Each account (a hidden one too) has its own:
/// the store under it is the open account's. While Zen is locked the
/// vault holds nothing in memory.
final Provider<PasswordVaultService> passwordVaultServiceProvider =
    Provider<PasswordVaultService>((Ref ref) {
      final AppSecurityService security = ref.read(appSecurityServiceProvider);
      final PasswordVaultService service = PasswordVaultService(
        disk: ref.read(ledgerDiskProvider),
        isLocked: () => security.isLocked,
      );
      void onSecurity() {
        if (security.isLocked) {
          service.forget();
        }
      }

      security.addListener(onSecurity);
      ref.onDispose(() {
        security.removeListener(onSecurity);
        service.dispose();
      });
      return service;
    });
