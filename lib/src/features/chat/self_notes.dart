import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';

/// Where the notes are kept (in the encrypted store), and the key the
/// account's devices sync them under (account_state_sync_app.dart).
const String kSelfNotesKey = 'notes/self';

/// The longest note.
const int kMaxSelfNoteChars = 4000;

/// The most notes kept; past it the oldest deleted ones go first, then
/// the oldest notes.
const int kMaxSelfNotes = 2000;

/// One note to oneself.
@immutable
final class SelfNote {
  const SelfNote({
    required this.id,
    required this.text,
    required this.atMillis,
    this.deleted = false,
  });

  final String id;
  final String text;

  /// When it was written (or deleted: a deletion is newer than the note).
  final int atMillis;

  /// Deleted on one of the devices: kept as a marker, so syncing does not
  /// bring it back from another.
  final bool deleted;

  Map<String, Object?> toJson() => <String, Object?>{
    't': text,
    'a': atMillis,
    if (deleted) 'd': true,
  };

  static SelfNote? fromJson(String id, Object? json) {
    if (json is! Map || json['a'] is! int) {
      return null;
    }
    final Object? text = json['t'];
    return SelfNote(
      id: id,
      text: text is String ? text : '',
      atMillis: json['a'] as int,
      deleted: json['d'] == true,
    );
  }
}

/// "Notatki dla siebie": a chat with oneself, the same on every device of
/// the account. Stored as one map, note id → note, so the account's sync
/// (which merges a stored state key by key) takes notes written on two
/// devices at once from both; a deletion is a marker with a newer time.
final class SelfNotesService extends ChangeNotifier {
  SelfNotesService({required this.disk, int Function()? now, Random? random})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
      _random = random ?? Random.secure();

  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;

  Map<String, SelfNote> _notes = <String, SelfNote>{};
  bool _loaded = false;

  /// The notes, oldest first, without the deleted ones.
  List<SelfNote> get notes =>
      _notes.values.where((SelfNote n) => !n.deleted).toList()
        ..sort((SelfNote a, SelfNote b) => a.atMillis.compareTo(b.atMillis));

  /// Reads the stored notes again (after a sync wrote them).
  Future<void> load() async {
    Map<String, SelfNote> read = <String, SelfNote>{};
    try {
      final Uint8List? raw = await disk.read(kSelfNotesKey);
      if (raw != null) {
        final Object? json = jsonDecode(utf8.decode(raw));
        if (json is Map) {
          read = <String, SelfNote>{
            for (final MapEntry<dynamic, dynamic> e in json.entries)
              if (e.key is String)
                if (SelfNote.fromJson(e.key as String, e.value)
                    case final SelfNote note)
                  note.id: note,
          };
        }
      }
    } on Object catch (error) {
      // The kind of error only: its text can quote what was being read.
      logZenWarning('Reading the notes failed: ${error.runtimeType}');
    }
    _notes = read;
    _loaded = true;
    notifyListeners();
  }

  /// Writes [text] as a new note; returns it (null for an empty text).
  Future<SelfNote?> add(String text) async {
    final String clean = text.trim();
    if (clean.isEmpty) {
      return null;
    }
    await _ensureLoaded();
    final SelfNote note = SelfNote(
      id: '${_now().toRadixString(36)}-${_random.nextInt(1 << 30).toRadixString(36)}',
      text: clean.length > kMaxSelfNoteChars
          ? clean.substring(0, kMaxSelfNoteChars)
          : clean,
      atMillis: _now(),
    );
    _notes = <String, SelfNote>{..._notes, note.id: note};
    await _save();
    return note;
  }

  /// Deletes the note [id] on every device.
  Future<void> delete(String id) async {
    await _ensureLoaded();
    if (!_notes.containsKey(id)) {
      return;
    }
    _notes = <String, SelfNote>{
      ..._notes,
      id: SelfNote(id: id, text: '', atMillis: _now(), deleted: true),
    };
    await _save();
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      await load();
    }
  }

  Future<void> _save() async {
    if (_notes.length > kMaxSelfNotes) {
      final List<SelfNote> order = _notes.values.toList()
        ..sort((SelfNote a, SelfNote b) {
          if (a.deleted != b.deleted) {
            return a.deleted ? -1 : 1;
          }
          return a.atMillis.compareTo(b.atMillis);
        });
      for (final SelfNote n in order.take(_notes.length - kMaxSelfNotes)) {
        _notes.remove(n.id);
      }
    }
    await disk.write(
      kSelfNotesKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            for (final SelfNote n in _notes.values) n.id: n.toJson(),
          }),
        ),
      ),
    );
    notifyListeners();
  }
}

/// This account's notes.
final Provider<SelfNotesService> selfNotesServiceProvider =
    Provider<SelfNotesService>((Ref ref) {
      final SelfNotesService service = SelfNotesService(
        disk: ref.read(ledgerDiskProvider),
      );
      ref.onDispose(service.dispose);
      return service;
    });
