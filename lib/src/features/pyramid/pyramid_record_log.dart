import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/storage/format_version.dart';

/// Entries in one segment of the record log.
const int kPyrLogSegmentEntries = 256;

/// A segment takes no more entries past this many bytes (a merge snapshot
/// is one big record).
const int kPyrLogSegmentBytes = 256 * 1024;

/// The pyramid's records on disk as an append-only log, so a new record
/// costs a write of one segment instead of all of them (every write is
/// sealed with AES-GCM on the UI isolate):
///
/// * `<prefix>/<n>` — a segment: entries one per line (JSON), up to
///   [segmentEntries] of them (fewer when they are big);
/// * `<prefix>/idx` — the index: the first segment's number, how many there
///   are, and how many entries the full ones hold.
///
/// [append] reads the index and the last segment from disk (another
/// isolate may have added to it) and writes the last segment back with the
/// new entries, then new segments and the index when there are more. A
/// record that changes (more signatures) is appended again: the last entry
/// of an id is the one that counts when the log is read.
///
/// [rewrite] writes all entries afresh under new numbers (compaction):
/// segments, then the index, then the old segments are deleted. Until the
/// index is written the old segments are what counts; the index names what
/// is still to be deleted until it is gone.
final class PyramidRecordLog {
  PyramidRecordLog(
    this.disk, {
    this.prefix = 'pyramid/records',
    this.segmentEntries = kPyrLogSegmentEntries,
    this.segmentBytes = kPyrLogSegmentBytes,
  }) : assert(segmentEntries > 0),
       assert(segmentBytes > 0);

  final LedgerDisk disk;
  final String prefix;

  final int segmentEntries;
  final int segmentBytes;

  int _entries = 0;

  /// Entries in the log as last read or written here.
  int get entryCount => _entries;

  String get indexKey => '$prefix/idx';

  String segmentKey(int n) => '$prefix/$n';

  /// Every entry in order, or `null` when there is no log yet. Throws when
  /// a part cannot be read.
  Future<List<Object?>?> readAll() async {
    final _LogIndex? index;
    try {
      index = _LogIndex.decode(await disk.read(indexKey));
    } on NewerFormatException {
      // A newer build's log: kept as it is (every write fails on it too).
      holdNewerOn(disk, indexKey);
      rethrow;
    }
    if (index == null) {
      _entries = 0;
      return null;
    }
    final List<Object?> entries = <Object?>[];
    for (int n = index.base; n < index.base + index.count; n++) {
      final Uint8List? raw = await disk.read(segmentKey(n));
      if (raw != null) {
        entries.addAll(_decodeLines(raw));
      }
    }
    _entries = entries.length;
    if (index.hasLeftovers) {
      // A rewrite was cut short after its index: what it replaced goes now.
      await _deleteLeftovers(index);
    }
    return entries;
  }

  /// Adds [entries] at the end (starting the log when there is none).
  Future<void> append(List<Object?> entries) async {
    if (entries.isEmpty) {
      return;
    }
    final _LogIndex? index = _LogIndex.decode(await disk.read(indexKey));
    final int base = index?.base ?? 0;
    int count = index?.count ?? 0;
    int closed = index?.closed ?? 0;
    final BytesBuilder current = BytesBuilder(copy: false);
    int lines = 0;
    int id;
    if (count == 0) {
      id = base;
      count = 1;
    } else {
      id = base + count - 1;
      final Uint8List? raw = await disk.read(segmentKey(id));
      if (raw != null && raw.isNotEmpty) {
        current.add(raw);
        lines = _countLines(raw);
      }
    }
    bool changed = false;
    for (final Object? entry in entries) {
      final Uint8List line = utf8.encode(jsonEncode(entry));
      if (lines > 0 &&
          (lines >= segmentEntries || current.length >= segmentBytes)) {
        if (changed) {
          await disk.write(segmentKey(id), current.takeBytes());
        } else {
          current.clear();
        }
        closed += lines;
        lines = 0;
        id++;
        count++;
      }
      if (lines > 0) {
        current.addByte(0x0A);
      }
      current.add(line);
      lines++;
      changed = true;
    }
    await disk.write(segmentKey(id), current.takeBytes());
    if (index == null || count != index.count) {
      await disk.write(
        indexKey,
        _LogIndex(base: base, count: count, closed: closed).encode(),
      );
    }
    _entries = closed + lines;
  }

  /// Replaces the whole log with [entries].
  Future<void> rewrite(List<Object?> entries) async {
    final _LogIndex? old = _LogIndex.decode(await disk.read(indexKey));
    final int base = old == null ? 0 : old.base + old.count;
    final BytesBuilder current = BytesBuilder(copy: false);
    int id = base;
    int lines = 0;
    int closed = 0;
    for (final Object? entry in entries) {
      final Uint8List line = utf8.encode(jsonEncode(entry));
      if (lines > 0 &&
          (lines >= segmentEntries || current.length >= segmentBytes)) {
        await disk.write(segmentKey(id), current.takeBytes());
        closed += lines;
        lines = 0;
        id++;
      }
      if (lines > 0) {
        current.addByte(0x0A);
      }
      current.add(line);
      lines++;
    }
    int count = id - base;
    if (lines > 0) {
      await disk.write(segmentKey(id), current.takeBytes());
      count++;
    }
    // The old segments (and any an earlier rewrite left) are named in the
    // index until they are deleted.
    final _LogIndex fresh = old != null && (old.count > 0 || old.gcFrom != null)
        ? _LogIndex(
            base: base,
            count: count,
            closed: closed,
            gcFrom: old.gcFrom ?? old.base,
            gcTo: old.base + old.count,
          )
        : _LogIndex(base: base, count: count, closed: closed);
    await disk.write(indexKey, fresh.encode());
    _entries = entries.length;
    if (fresh.hasLeftovers && await _deleteLeftovers(fresh)) {
      try {
        await disk.write(
          indexKey,
          _LogIndex(base: base, count: count, closed: closed).encode(),
        );
      } on Object {
        // The index still names what was deleted: deleted again next time.
      }
    }
  }

  /// Deletes what [index] names as replaced; whether all of it went.
  Future<bool> _deleteLeftovers(_LogIndex index) async {
    bool clean = true;
    final int? from = index.gcFrom;
    final int? to = index.gcTo;
    if (from != null && to != null) {
      for (int n = from; n < to; n++) {
        try {
          await disk.delete(segmentKey(n));
        } on Object {
          clean = false;
        }
      }
    }
    return clean;
  }

  static int _countLines(Uint8List raw) {
    if (raw.isEmpty) {
      return 0;
    }
    int lines = 1;
    for (final int byte in raw) {
      if (byte == 0x0A) {
        lines++;
      }
    }
    return lines;
  }

  static List<Object?> _decodeLines(Uint8List raw) => <Object?>[
    for (final String line in utf8.decode(raw).split('\n'))
      if (line.isNotEmpty) jsonDecode(line),
  ];
}

/// Where the log's segments are.
final class _LogIndex {
  const _LogIndex({
    required this.base,
    required this.count,
    required this.closed,
    this.gcFrom,
    this.gcTo,
  });

  /// The first segment's number.
  final int base;

  /// How many segments there are.
  final int count;

  /// Entries in all segments but the last.
  final int closed;

  /// Segments a rewrite replaced, still to be deleted: `[gcFrom, gcTo)`.
  final int? gcFrom;
  final int? gcTo;

  bool get hasLeftovers => gcFrom != null && gcTo != null;

  Uint8List encode() {
    final int? from = gcFrom;
    final int? to = gcTo;
    return utf8.encode(
      jsonEncode(<String, Object>{
        'v': 1,
        'b': base,
        'n': count,
        'c': closed,
        if (from != null && to != null) 'gc': <int>[from, to],
      }),
    );
  }

  /// `null` when there is no index; throws [FormatException] when it is
  /// not one this version can read.
  static _LogIndex? decode(Uint8List? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final Object? json = jsonDecode(utf8.decode(raw));
    if (jsonFormatAge(json, current: 1) == FormatAge.newer) {
      throw NewerFormatException(
        'pyramid record index',
        found: (json as Map)['v'],
        supported: 1,
      );
    }
    if (json is! Map || json['v'] != 1) {
      throw const FormatException('Unknown pyramid record index.');
    }
    final Object? base = json['b'];
    final Object? count = json['n'];
    final Object? closed = json['c'];
    if (base is! int ||
        count is! int ||
        closed is! int ||
        base < 0 ||
        count < 0) {
      throw const FormatException('Damaged pyramid record index.');
    }
    final Object? gc = json['gc'];
    final List<int>? range =
        gc is List && gc.length == 2 && gc[0] is int && gc[1] is int
        ? <int>[gc[0] as int, gc[1] as int]
        : null;
    return _LogIndex(
      base: base,
      count: count,
      closed: closed,
      gcFrom: range?[0],
      gcTo: range?[1],
    );
  }
}
