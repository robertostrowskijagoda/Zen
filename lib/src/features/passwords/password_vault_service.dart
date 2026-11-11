import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

  /// The entries whose name, login or address holds [query] (ignoring
  /// case); all of them for an empty query. Passwords and notes are never
  /// searched.
  List<PasswordEntry> search(String query) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return entries;
    }
    return <PasswordEntry>[
      for (final PasswordEntry e in entries)
        if (e.name.toLowerCase().contains(q) ||
            e.login.toLowerCase().contains(q) ||
            e.address.toLowerCase().contains(q))
          e,
    ];
  }

  /// The entries the autofill may offer in the app [packageName] or on the
  /// page [webDomain] ([matchPasswordEntries]).
  List<PasswordMatch> matchesFor({
    String? packageName,
    String? webDomain,
    String? webScheme,
  }) => matchPasswordEntries(
    entries,
    packageName: packageName,
    webDomain: webDomain,
    webScheme: webScheme,
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
        fields: clean,
      ),
    );
    await _save(raw, growing: true);
    return entry(id)!;
  });

  /// Saves [fields] as the entry [id]'s new version; its earlier one goes
  /// into its history. Unchanged fields change nothing.
  Future<PasswordEntry> edit(String id, PasswordFields fields) =>
      _serial(() async {
        await _ready();
        final PasswordEntry current = _existing(id);
        final PasswordFields clean = _checked(fields);
        if (clean.sameAs(current.fields) && !current.conflict) {
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

  /// Forgets the entry [id]'s earlier versions (its old passwords), on
  /// every device. A marker names them (a deletion marker that saw only
  /// them, so the entry stays): a copy or a device that was away and still
  /// holds them never brings them back ([_pruned] drops what a marker
  /// saw). Earlier markers of the entry are folded into it.
  Future<PasswordEntry> clearHistory(String id) => _serial(() async {
    await _ready();
    final PasswordEntry current = _existing(id);
    final PasswordVersion now = _doc.versions[current.versionKey]!;
    final Set<String> seen = <String>{};
    final Map<String, Map<String, Object?>> raw =
        <String, Map<String, Object?>>{};
    for (final MapEntry<String, Map<String, Object?>> e in _doc.raw.entries) {
      final PasswordVersion? v = _doc.versions[e.key];
      if (v == null || v.entryId != id || e.key == current.versionKey) {
        raw[e.key] = e.value;
      } else if (v.deleted) {
        // Folded into the new marker (it keeps what they saw).
        seen.addAll(v.seen);
      } else {
        seen.add(v.key);
      }
    }
    if (seen.isEmpty) {
      return current;
    }
    final PasswordVersion marker = PasswordVersion(
      key: _newId(),
      entryId: id,
      // Not after the current version's base: the entry is not shown as
      // kept over a deletion ([PasswordEntry.keptOverDeletion]).
      atMillis: now.baseMillis,
      deleted: true,
      seen: seen.take(256).toList(),
    );
    raw[marker.key] = marker.toJson();
    await _save(raw);
    return entry(id)!;
  });

  /// Deletes the entry [id] on every device, with its history. False when
  /// there is no such entry.
  Future<bool> delete(String id) => _serial(() async {
    await _ready();
    if (entry(id) == null) {
      return false;
    }
    final Set<String> seen = <String>{};
    int at = _now();
    final Map<String, Map<String, Object?>> raw =
        <String, Map<String, Object?>>{};
    for (final MapEntry<String, Map<String, Object?>> e in _doc.raw.entries) {
      final PasswordVersion v = _doc.versions[e.key]!;
      if (v.entryId != id) {
        raw[e.key] = e.value;
        continue;
      }
      // Earlier markers of the entry are folded into the new one.
      seen.addAll(v.deleted ? v.seen : <String>[v.key]);
      at = max(at, v.atMillis + 1);
    }
    final PasswordVersion marker = PasswordVersion(
      key: _newId(),
      entryId: id,
      atMillis: at,
      deleted: true,
      seen: seen.take(256).toList(),
    );
    raw[marker.key] = marker.toJson();
    await _save(raw);
    return true;
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
            fields: row.fields,
          );
          raw[v.key] = v.toJson();
          added.add(v.key);
        }
        int over = _overBytes(raw);
        if (over > 0) {
          // The oldest history goes first; rows that still do not fit stay
          // out, the last ones first.
          raw = _trimmed(raw, over);
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
  /// history past its length) is dropped on the way, as a save here drops
  /// it: an old password that comes back from a device that was away is
  /// not written into the store again. Versions this build does not read
  /// stay as they are.
  Future<void> takeSyncState(Map<String, Object?> state) => _serial(() async {
    _ensureOpen();
    Map<String, Object?> next = state;
    final PasswordVaultDoc? doc = PasswordVaultDoc.fromJson(state);
    final Object? e = state['e'];
    if (doc != null && !doc.newer && e is Map) {
      final Set<String> keep = _pruned(doc.raw).keys.toSet();
      final Map<Object?, Object?> kept = <Object?, Object?>{
        for (final MapEntry<Object?, Object?> v in e.entries)
          if (!doc.raw.containsKey(v.key) || keep.contains(v.key))
            v.key: v.value,
      };
      next = <String, Object?>{...state, 'e': kept};
      if (kept.isEmpty) {
        next.remove('e');
      }
    }
    await disk.write(
      kPasswordVaultKey,
      Uint8List.fromList(utf8.encode(jsonEncode(next))),
    );
    await _read();
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
      <String, Map<String, Object?>>{...copy.raw, ..._doc.raw},
    );
    // What a deletion here saw, or what is older than the history kept,
    // does not come back.
    final int added = raw.keys
        .where((String k) => !_doc.raw.containsKey(k))
        .length;
    if (added > 0) {
      await _save(raw);
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

  /// The versions with a new one of [current] holding [fields]: it builds
  /// on every version of the entry here (a conflict is settled by it).
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
        baseMillis: newest,
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

  /// [raw] without what no longer counts: versions a deletion saw; per
  /// entry, beyond its current version, versions written elsewhere at the
  /// same time ([kMaxPasswordConcurrent]) and its last
  /// [kMaxPasswordHistory] others; the oldest deletion markers past
  /// [kMaxPasswordDeletions].
  Map<String, Map<String, Object?>> _pruned(
    Map<String, Map<String, Object?>> raw,
  ) {
    final Map<String, PasswordVersion> versions = _versionsOf(raw);
    final Set<String> keep = <String>{};
    for (final PasswordEntry e in passwordEntriesOf(versions.values)) {
      keep
        ..add(e.versionKey)
        ..addAll(e.history.map((PasswordHistoryItem h) => h.versionKey));
    }
    final List<PasswordVersion> markers =
        versions.values.where((PasswordVersion v) => v.deleted).toList()..sort(
          (PasswordVersion a, PasswordVersion b) => a.isNewerThan(b) ? -1 : 1,
        );
    keep.addAll(
      markers.take(kMaxPasswordDeletions).map((PasswordVersion v) => v.key),
    );
    return <String, Map<String, Object?>>{
      for (final MapEntry<String, Map<String, Object?>> e in raw.entries)
        if (keep.contains(e.key)) e.key: e.value,
    };
  }

  int _bytesOf(Map<String, Map<String, Object?>> raw) => utf8
      .encode(
        jsonEncode(PasswordVaultDoc(raw: raw, carried: _doc.carried).toJson()),
      )
      .length;

  int _overBytes(Map<String, Map<String, Object?>> raw) =>
      _bytesOf(raw) - kMaxPasswordVaultBytes;

  /// [raw] with the oldest earlier versions (never an entry's current one,
  /// nor one written elsewhere at the same time) dropped until about
  /// [over] bytes are gone.
  Map<String, Map<String, Object?>> _trimmed(
    Map<String, Map<String, Object?>> raw,
    int over,
  ) {
    final Map<String, PasswordVersion> versions = _versionsOf(raw);
    final List<PasswordHistoryItem> old =
        <PasswordHistoryItem>[
          for (final PasswordEntry e in passwordEntriesOf(versions.values))
            for (final PasswordHistoryItem h in e.history)
              if (!h.concurrent) h,
        ]..sort(
          (PasswordHistoryItem a, PasswordHistoryItem b) =>
              a.changedAtMillis.compareTo(b.changedAtMillis),
        );
    final Map<String, Map<String, Object?>> out =
        <String, Map<String, Object?>>{...raw};
    int gone = 0;
    for (final PasswordHistoryItem h in old) {
      if (gone >= over) {
        break;
      }
      final Map<String, Object?>? v = out.remove(h.versionKey);
      if (v != null) {
        gone += utf8
            .encode(jsonEncode(<String, Object?>{h.versionKey: v}))
            .length;
      }
    }
    return out;
  }

  /// Prunes [raw], checks its size ([growing]: refused when it does not
  /// fit even with the oldest history gone) and writes it.
  Future<void> _save(
    Map<String, Map<String, Object?>> raw, {
    bool growing = false,
  }) async {
    Map<String, Map<String, Object?>> next = _pruned(raw);
    final int over = _overBytes(next);
    if (over > 0) {
      next = _trimmed(next, over);
      if (growing && _overBytes(next) > 0) {
        throw const PasswordVaultException(PasswordVaultError.full);
      }
    }
    final PasswordVaultDoc doc = PasswordVaultDoc(
      raw: next,
      versions: _versionsOf(next),
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
