import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';

/// Key-value bytes on disk (encrypted and checksummed by [FileBinaryStore]
/// in the app, in memory in tests).
abstract interface class LedgerDisk {
  Future<Uint8List?> read(String key);

  Future<void> write(String key, Uint8List data);

  Future<void> delete(String key);
}

final class MemoryLedgerDisk implements LedgerDisk {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => files[key];

  @override
  Future<void> write(String key, Uint8List data) async {
    files[key] = Uint8List.fromList(data);
  }

  @override
  Future<void> delete(String key) async {
    files.remove(key);
  }
}

final class FileLedgerDisk implements LedgerDisk {
  FileLedgerDisk(this.store);

  final FileBinaryStore store;

  @override
  Future<Uint8List?> read(String key) => store.read(key);

  @override
  Future<void> write(String key, Uint8List data) async {
    await store.write(key, data);
  }

  @override
  Future<void> delete(String key) => store.delete(key);
}

/// File pieces as separate files on a [LedgerDisk].
final class DiskBlobChunkBackend implements BlobChunkBackend {
  DiskBlobChunkBackend(this.disk);

  final LedgerDisk disk;
  final Set<String> _known = <String>{};

  static String keyOf(String hash) => 'ledger/chunk-$hash';

  void restore(Iterable<String> hashes) => _known.addAll(hashes);

  @override
  bool has(String hash) => _known.contains(hash);

  @override
  Iterable<String> get hashes => _known;

  @override
  Future<Uint8List?> read(String hash) async =>
      _known.contains(hash) ? disk.read(keyOf(hash)) : null;

  @override
  Future<void> write(String hash, Uint8List data) async {
    await disk.write(keyOf(hash), data);
    _known.add(hash);
  }

  @override
  Future<void> delete(String hash) async {
    _known.remove(hash);
    await disk.delete(keyOf(hash));
  }
}

/// Saves and restores logs, revocations, blocks and file manifests.
///
/// Logs are saved in segments of [segmentSize] entries, so adding one entry
/// rewrites one small file, not the whole history.
final class LedgerArchive {
  LedgerArchive({required this.disk, this.segmentSize = 200});

  static const String indexKey = 'ledger/index';
  static const int _version = 1;

  final LedgerDisk disk;
  final int segmentSize;

  LedgerStore? _store;
  BlobStore? _blobs;
  StreamSubscription<void>? _subscription;

  /// `space|writer` → entries already on disk.
  final Map<String, int> _saved = <String, int>{};
  Future<void> _tail = Future<void>.value();
  bool _flushQueued = false;

  /// While paused nothing is written: another process owns the files.
  bool _paused = false;

  static String _logKey(String space, String writer, int segment) =>
      'ledger/log-${sha256Hex(utf8.encode('$space|$writer')).substring(0, 32)}-$segment';

  /// Reads everything back into [store] and [blobs], then keeps saving
  /// changes as they happen.
  Future<void> open(LedgerStore store, BlobStore blobs) async {
    _store = store;
    _blobs = blobs;
    await _load(store, blobs);
    _subscription = store.changed.listen((_) => _scheduleFlush());
    blobs.onChanged = _scheduleFlush;
  }

  Future<void> _load(LedgerStore store, BlobStore blobs) async {
    final Uint8List? raw = await disk.read(indexKey);
    if (raw == null) {
      return;
    }
    final Object? index;
    try {
      index = jsonDecode(utf8.decode(raw));
    } on FormatException {
      logZenWarning('Indeks dziennika jest uszkodzony; zaczynam od zera.');
      return;
    }
    if (index is! Map || index['v'] != _version) {
      return;
    }
    for (final Object? json
        in (index['rev'] as List<dynamic>? ?? <dynamic>[])) {
      final DeviceRevocation? r = DeviceRevocation.fromJson(json);
      if (r != null) {
        await store.directory.addRevocation(r);
      }
    }
    for (final Object? a
        in (index['blocked'] as List<dynamic>? ?? <dynamic>[])) {
      if (a is String) {
        store.blockedAccounts.add(a);
      }
    }
    for (final Object? log
        in (index['logs'] as List<dynamic>? ?? <dynamic>[])) {
      if (log is! Map ||
          log['s'] is! String ||
          log['w'] is! String ||
          log['n'] is! int) {
        continue;
      }
      final String space = log['s'] as String;
      final String writer = log['w'] as String;
      final int count = log['n'] as int;
      int restored = 0;
      segments:
      for (int seg = 0; seg * segmentSize < count; seg++) {
        final Uint8List? data = await disk.read(_logKey(space, writer, seg));
        if (data == null) {
          break;
        }
        final Object? list;
        try {
          list = jsonDecode(utf8.decode(data));
        } on FormatException {
          break;
        }
        if (list is! List) {
          break;
        }
        for (final Object? json in list) {
          final LogEntry? entry = LogEntry.fromJson(json);
          if (entry == null || !store.restore(entry)) {
            break segments;
          }
          restored++;
        }
      }
      if (log['f'] == true) {
        store.restoreForked(space, writer);
      }
      _saved['$space|$writer'] = restored;
      if (restored < count) {
        logZenWarning(
          'Dziennik $space odtworzony częściowo ($restored z $count); '
          'reszta dotrze od innych.',
        );
      }
    }
    final Object? b = index['blobs'];
    if (b is Map) {
      final BlobChunkBackend backend = blobs.backend;
      if (backend is DiskBlobChunkBackend) {
        backend.restore(<String>[
          for (final Object? h
              in (b['chunks'] as List<dynamic>? ?? <dynamic>[]))
            if (h is String) h,
        ]);
      }
      blobs.restore(
        manifests: <BlobManifest>[
          for (final Object? m
              in (b['manifests'] as List<dynamic>? ?? <dynamic>[]))
            ?BlobManifest.fromJson(m),
        ],
        refused: <String>[
          for (final Object? r
              in (b['refused'] as List<dynamic>? ?? <dynamic>[]))
            if (r is String) r,
        ],
        wanted: <String>[
          for (final Object? w
              in (b['wanted'] as List<dynamic>? ?? <dynamic>[]))
            if (w is String) w,
        ],
      );
    }
  }

  void _scheduleFlush() {
    if (_flushQueued || _paused) {
      return;
    }
    _flushQueued = true;
    scheduleMicrotask(() {
      _flushQueued = false;
      unawaitedLogged(flush(), context: 'Zapis dziennika nie udał się');
    });
  }

  /// Writes whatever changed. Calls are serialized.
  Future<void> flush() {
    final Future<void> next = _tail.then((_) => _flushNow());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _flushNow() async {
    final LedgerStore? store = _store;
    final BlobStore? blobs = _blobs;
    if (store == null || blobs == null) {
      return;
    }
    final List<Map<String, dynamic>> logs = <Map<String, dynamic>>[];
    final Set<String> present = <String>{};
    for (final (String space, String writer, int count, bool forked)
        in store.logs.toList()) {
      final String key = '$space|$writer';
      present.add(key);
      final int saved = _saved[key] ?? 0;
      if (saved != count) {
        // Rewrite from the first segment that changed.
        final int from = (saved < count ? saved : count) ~/ segmentSize;
        final int lastSegment = count == 0 ? -1 : (count - 1) ~/ segmentSize;
        for (int seg = from; seg <= lastSegment; seg++) {
          final List<LogEntry> slice = store.entriesAfter(
            space,
            writer,
            seg * segmentSize,
            limit: segmentSize,
          );
          await disk.write(
            _logKey(space, writer, seg),
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<Map<String, dynamic>>[
                  for (final LogEntry e in slice) e.toJson(),
                ]),
              ),
            ),
          );
        }
        // Segments past the end (entries were cut off).
        final int oldLast = saved == 0 ? -1 : (saved - 1) ~/ segmentSize;
        for (int seg = lastSegment + 1; seg <= oldLast; seg++) {
          await disk.delete(_logKey(space, writer, seg));
        }
        _saved[key] = count;
      }
      logs.add(<String, dynamic>{
        's': space,
        'w': writer,
        'n': count,
        if (forked) 'f': true,
      });
    }
    // Logs that disappeared (blocked accounts).
    for (final String key in _saved.keys.toList()) {
      if (present.contains(key)) {
        continue;
      }
      final int bar = key.indexOf('|');
      final String space = key.substring(0, bar);
      final String writer = key.substring(bar + 1);
      final int saved = _saved.remove(key)!;
      for (int seg = 0; seg * segmentSize < saved; seg++) {
        await disk.delete(_logKey(space, writer, seg));
      }
    }
    final Map<String, dynamic> index = <String, dynamic>{
      'v': _version,
      'logs': logs,
      'rev': <Map<String, dynamic>>[
        for (final DeviceRevocation r in store.directory.revocations)
          r.toJson(),
      ],
      'blocked': store.blockedAccounts.toList(),
      'blobs': <String, dynamic>{
        'manifests': <Map<String, dynamic>>[
          for (final BlobManifest m in blobs.manifests) m.toJson(),
        ],
        'refused': blobs.refused.toList(),
        'wanted': blobs.wanted.toList(),
        'chunks': blobs.backend.hashes.toList(),
      },
    };
    await disk.write(
      indexKey,
      Uint8List.fromList(utf8.encode(jsonEncode(index))),
    );
  }

  /// Saves what is pending, then stops writing until [catchUp].
  Future<void> pause() async {
    await flush();
    _paused = true;
  }

  /// Reads what another process added to the files while this one was
  /// paused — new entries of every log (checked and announced like any
  /// received entry), files and their pieces, revocations — then writes
  /// again.
  Future<void> catchUp() async {
    final LedgerStore? store = _store;
    final BlobStore? blobs = _blobs;
    if (store == null || blobs == null) {
      _paused = false;
      return;
    }
    try {
      final Uint8List? raw = await disk.read(indexKey);
      final Object? index = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (index is Map && index['v'] == _version) {
        for (final Object? json
            in (index['rev'] as List<dynamic>? ?? <dynamic>[])) {
          final DeviceRevocation? r = DeviceRevocation.fromJson(json);
          if (r != null) {
            await store.applyRevocation(r);
          }
        }
        for (final Object? log
            in (index['logs'] as List<dynamic>? ?? <dynamic>[])) {
          if (log is! Map ||
              log['s'] is! String ||
              log['w'] is! String ||
              log['n'] is! int) {
            continue;
          }
          final String space = log['s'] as String;
          final String writer = log['w'] as String;
          final int count = log['n'] as int;
          final int have = store.heads(space)[writer] ?? 0;
          if (count <= have) {
            continue;
          }
          for (
            int seg = have ~/ segmentSize;
            seg * segmentSize < count;
            seg++
          ) {
            final Uint8List? data = await disk.read(
              _logKey(space, writer, seg),
            );
            if (data == null) {
              break;
            }
            final Object? list = jsonDecode(utf8.decode(data));
            if (list is! List) {
              break;
            }
            for (final Object? json in list) {
              final LogEntry? entry = LogEntry.fromJson(json);
              if (entry != null && entry.seq > have) {
                await store.ingest(entry);
              }
            }
          }
          // What is on disk now; the next save rewrites from what we hold.
          final int held = store.heads(space)[writer] ?? 0;
          _saved['$space|$writer'] = held < count ? held : count;
        }
        final Object? b = index['blobs'];
        if (b is Map) {
          final BlobChunkBackend backend = blobs.backend;
          if (backend is DiskBlobChunkBackend) {
            backend.restore(<String>[
              for (final Object? h
                  in (b['chunks'] as List<dynamic>? ?? <dynamic>[]))
                if (h is String) h,
            ]);
          }
          blobs.restore(
            manifests: <BlobManifest>[
              for (final Object? m
                  in (b['manifests'] as List<dynamic>? ?? <dynamic>[]))
                ?BlobManifest.fromJson(m),
            ],
            refused: <String>[
              for (final Object? r
                  in (b['refused'] as List<dynamic>? ?? <dynamic>[]))
                if (r is String) r,
            ],
            wanted: const <String>[],
          );
          for (final String id in blobs.wanted.toList()) {
            if (blobs.isComplete(id)) {
              blobs.markDone(id);
            }
          }
        }
      }
    } on FormatException {
      logZenWarning('Indeks dziennika nieczytelny; zostaje stan z pamięci.');
    } finally {
      _paused = false;
    }
    _scheduleFlush();
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await flush();
  }
}
