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
import 'package:zen/src/core/storage/format_version.dart';

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

/// Keeps the file of [key] on [disk] exactly as it is: a newer build wrote
/// it (see [FileBinaryStore.holdNewer]; another disk only reports it).
void holdNewerOn(LedgerDisk disk, String key) {
  if (disk is FileLedgerDisk) {
    disk.store.holdNewer(key);
  } else {
    ZenFormatGuard.instance.noteNewer(key);
  }
}

/// Sets the file of [key] on [disk] aside ([FileBinaryStore.quarantine]; on
/// another disk it is forgotten): it is damaged, and that part of the
/// ledger starts afresh instead of failing on it at every start.
Future<void> setAsideOn(LedgerDisk disk, String key) async {
  if (disk is FileLedgerDisk) {
    await disk.store.quarantine(key);
  } else {
    logZenWarning('A ledger file is damaged; it starts afresh.');
    await disk.delete(key);
  }
}

/// Whether something (readable or not) is stored under [key] on [disk],
/// without opening it where the disk can tell ([FileBinaryStore.exists]).
Future<bool> existsOn(LedgerDisk disk, String key) async {
  if (disk is FileLedgerDisk) {
    return disk.store.exists(key);
  }
  try {
    return await disk.read(key) != null;
  } on Object {
    return true;
  }
}

/// The bytes of [key] on [disk], or null when there are none, when a newer
/// build wrote them (held, see [holdNewerOn]) or when the file is damaged
/// ([isDamagedStoredFile]): it is then set aside ([setAsideOn]) and the
/// caller starts that part afresh. A locked store or a failing disk still
/// throws.
Future<Uint8List?> readOrSetAsideOn(LedgerDisk disk, String key) async {
  try {
    return await disk.read(key);
  } on NewerFormatException {
    holdNewerOn(disk, key);
    return null;
  } on FormatException catch (error) {
    logZenWarning('A ledger file is damaged: ${error.message}');
    await setAsideOn(disk, key);
    return null;
  }
}

/// Whether the JSON document [json] read from [key] on [disk] names (in
/// `v`) a format above [current]; the file is then held ([holdNewerOn])
/// and the caller reads it as missing.
bool heldAsNewerOn(
  LedgerDisk disk,
  String key,
  Object? json, {
  required int current,
}) {
  if (jsonFormatAge(json, current: current) != FormatAge.newer) {
    return false;
  }
  holdNewerOn(disk, key);
  return true;
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

  /// A damaged piece is set aside and forgotten: it is fetched again.
  @override
  Future<Uint8List?> read(String hash) async {
    if (!_known.contains(hash)) {
      return null;
    }
    final Uint8List? data = await readOrSetAsideOn(disk, keyOf(hash));
    if (data == null) {
      _known.remove(hash);
    }
    return data;
  }

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

/// Saves and restores logs, device certificates, revocations, blocks and
/// file manifests.
///
/// The files (format 1, from 1.12.0):
///
/// * [indexKey]: which logs are held (and from where: a log cut at its
///   writer's checkpoint starts after `b`), blocks, which
///   certificate files and file lists exist, and the small per-file marks
///   (refused, wanted, who a file was fetched for);
/// * one certificate file per account ([certificatesKeyOf]), rewritten only
///   when a certificate of that account is added;
/// * the device revocations ([revocationsKey]), rewritten only when they
///   change (each is about 8 KB; [AccountDirectory] bounds how many);
/// * sixteen file lists ([blobListKeyOf], by the first hex digit of an id),
///   each rewritten only when it changed;
/// * the log segments ([logKeyOf]) of [segmentSize] entries, so adding one
///   entry rewrites one small file, not the whole history; entries are
///   saved without their device's certificate.
///
/// No file grows with everything at once, so none comes near the store's
/// size limit while there is room on the device.
final class LedgerArchive {
  LedgerArchive({required this.disk, this.segmentSize = 200});

  static const String indexKey = 'ledger/index';

  /// The device revocations kept ([AccountDirectory.revocations]).
  static const String revocationsKey = 'ledger/revocations';

  /// Start of the name of every certificate file ([certificatesKeyOf]).
  static const String certificatesPrefix = 'ledger/certs-';

  /// Start of the name of every file list ([blobListKeyOf]).
  static const String blobListPrefix = 'ledger/blobs-';

  /// The format of the index, the certificate files and the file lists.
  static const int formatVersion = 1;

  static const String _shards = '0123456789abcdef';

  /// The file with the certificates of [account]'s devices.
  static String certificatesKeyOf(String account) =>
      '$certificatesPrefix${_nameHash(account)}';

  /// The list of the files (manifests) and pieces whose ids start with
  /// [shard] (one hex digit).
  static String blobListKeyOf(String shard) => '$blobListPrefix$shard';

  /// Segment [segment] (entries `segment * size + 1` on) of the log of
  /// [writer] in [space].
  static String logKeyOf(String space, String writer, int segment) =>
      'ledger/log-${_nameHash('$space|$writer')}-$segment';

  static String _nameHash(String value) =>
      sha256Hex(utf8.encode(value)).substring(0, 32);

  static String _shardOf(String id) {
    final String first = id.isEmpty ? '0' : id[0].toLowerCase();
    return _shards.contains(first) ? first : '0';
  }

  final LedgerDisk disk;
  final int segmentSize;

  LedgerStore? _store;
  BlobStore? _blobs;
  StreamSubscription<void>? _subscription;

  /// `space|writer` → entries already on disk (the last sequence number).
  final Map<String, int> _saved = <String, int>{};

  /// `space|writer` → where the log on disk starts (see
  /// [LedgerStore.baseOf]).
  final Map<String, int> _savedBase = <String, int>{};

  /// Account → what its certificate file on disk holds ([_certPrint]).
  final Map<String, String> _savedCertificates = <String, String>{};

  /// Account → [AccountDirectory.revisionOf] when it was last compared.
  final Map<String, int> _checkedCertificates = <String, int>{};

  /// [AccountDirectory.revision] when the certificates were last compared.
  int? _checkedDirectory;

  /// [AccountDirectory.revocationRevision] of the revocations on disk.
  int? _savedRevocations;

  /// Shard → the file list on disk, as written.
  final Map<String, String> _savedBlobLists = <String, String>{};

  Future<void> _tail = Future<void>.value();
  bool _flushQueued = false;

  /// While paused nothing is written: another process owns the files.
  bool _paused = false;

  /// A newer build wrote the index: nothing here is written over.
  bool _heldNewer = false;

  /// Logs (`space|writer`) that could not be read back whole at [open].
  final Set<String> incompleteLogs = <String>{};

  /// Whether there was an index at [open] that could not be read (damaged
  /// or written by a newer build): nothing was restored.
  bool indexUnreadable = false;

  /// Whether there was no index at all at [open].
  bool indexMissing = false;

  /// Whether a newer build wrote the index: the archive is kept as it is
  /// and nothing is saved until this build is updated.
  bool get heldNewer => _heldNewer;

  /// Whether this device's own log [writer] may have lost entries others
  /// already hold: its index was unreadable or missing, or one of its logs
  /// came back short. Writing on under [writer] would then number new
  /// entries like the lost ones (a fork everyone refuses), so the device
  /// starts a new log instead.
  bool lostOwnLog(String writer) =>
      !_heldNewer &&
      (indexUnreadable ||
          indexMissing ||
          incompleteLogs.any((String log) => log.endsWith('|$writer')));

  /// Reads everything back into [store] and [blobs], then keeps saving
  /// changes as they happen.
  Future<void> open(LedgerStore store, BlobStore blobs) async {
    _store = store;
    _blobs = blobs;
    await _load(store, blobs);
    _subscription = store.changed.listen((_) => _scheduleFlush());
    blobs.onChanged = _scheduleFlush;
  }

  /// The index on disk; `index` null when there is none ([unreadable]
  /// false) or it cannot be read (true). A newer build's index holds the
  /// whole archive ([heldNewer]).
  Future<({Map<dynamic, dynamic>? index, bool unreadable})> _readIndex() async {
    final Uint8List? raw;
    try {
      raw = await disk.read(indexKey);
    } on NewerFormatException {
      _holdNewer();
      return (index: null, unreadable: true);
    } on FormatException {
      // Neither the index nor its backup reads: set aside, and the logs
      // come back from friends and own devices.
      logZenWarning('The ledger index is damaged; starting from scratch.');
      await setAsideOn(disk, indexKey);
      return (index: null, unreadable: true);
    }
    if (raw == null) {
      return (index: null, unreadable: false);
    }
    final Object? index;
    try {
      index = jsonDecode(utf8.decode(raw));
    } on FormatException {
      logZenWarning('The ledger index is damaged; starting from scratch.');
      return (index: null, unreadable: true);
    }
    if (heldAsNewerOn(disk, indexKey, index, current: formatVersion)) {
      _holdNewer();
      return (index: null, unreadable: true);
    }
    if (index is! Map || !isReadableFormat(index, current: formatVersion)) {
      logZenWarning('The ledger index is unreadable; starting from scratch.');
      return (index: null, unreadable: true);
    }
    return (index: index, unreadable: false);
  }

  void _holdNewer() {
    _heldNewer = true;
    _paused = true;
    holdNewerOn(disk, indexKey);
  }

  /// One of the archive's JSON files (a certificate file, a file list):
  /// null when it is missing or cannot be read; a newer build's file is
  /// held as it is.
  Future<(Map<dynamic, dynamic>, String)?> _readFile(String key) async {
    try {
      final Uint8List? raw = await readOrSetAsideOn(disk, key);
      if (raw == null) {
        return null;
      }
      final String text = utf8.decode(raw);
      final Object? json = jsonDecode(text);
      if (heldAsNewerOn(disk, key, json, current: formatVersion) ||
          json is! Map ||
          !isReadableFormat(json, current: formatVersion)) {
        return null;
      }
      return (json, text);
    } on FormatException {
      return null;
    }
  }

  /// A fingerprint of what a certificate file holds.
  static String _certPrint(Iterable<DeviceCertificate> certs) {
    final List<String> parts = <String>[
      for (final DeviceCertificate c in certs)
        '${c.device}:${c.signature.hashCode}',
    ]..sort();
    return parts.join(',');
  }

  /// Puts back the certificates the index names (checked when they first
  /// came): the entries are checked with them.
  Future<void> _loadCertificates(
    LedgerStore store,
    Map<dynamic, dynamic> index,
  ) async {
    for (final Object? name in _list(index['certs'])) {
      if (name is! String || name.length != 32) {
        continue;
      }
      final (Map<dynamic, dynamic>, String)? file = await _readFile(
        '$certificatesPrefix$name',
      );
      if (file == null) {
        logZenWarning(
          'Device certificates unreadable; they will come from others.',
        );
        continue;
      }
      final List<DeviceCertificate> certs = <DeviceCertificate>[
        for (final Object? json in _list(file.$1['c']))
          ?DeviceCertificate.fromJson(json),
      ];
      for (final DeviceCertificate cert in certs) {
        store.directory.trustCertificate(cert);
      }
      final Object? account = file.$1['a'];
      if (account is String && certificatesKeyOf(account).endsWith(name)) {
        _savedCertificates[account] = _certPrint(certs);
      }
    }
  }

  /// The file lists the index names: manifests and pieces, and the lists
  /// as read (by shard).
  Future<(List<BlobManifest>, List<String>, Map<String, String>)>
  _readBlobLists(Map<dynamic, dynamic> blobs) async {
    final List<BlobManifest> manifests = <BlobManifest>[];
    final List<String> chunks = <String>[];
    final Map<String, String> read = <String, String>{};
    for (final Object? shard in _list(blobs['lists'])) {
      if (shard is! String || shard.length != 1 || !_shards.contains(shard)) {
        continue;
      }
      final (Map<dynamic, dynamic>, String)? file = await _readFile(
        blobListKeyOf(shard),
      );
      if (file == null) {
        continue;
      }
      read[shard] = file.$2;
      manifests.addAll(<BlobManifest>[
        for (final Object? m in _list(file.$1['m'])) ?BlobManifest.fromJson(m),
      ]);
      chunks.addAll(<String>[
        for (final Object? h in _list(file.$1['c']))
          if (h is String) h,
      ]);
    }
    return (manifests, chunks, read);
  }

  Future<void> _load(LedgerStore store, BlobStore blobs) async {
    final ({Map<dynamic, dynamic>? index, bool unreadable}) read =
        await _readIndex();
    final Map<dynamic, dynamic>? index = read.index;
    indexUnreadable = read.unreadable;
    indexMissing = index == null && !read.unreadable;
    if (index == null) {
      return;
    }
    await _loadCertificates(store, index);
    // Checked when they first came (and kept within the limits).
    for (final DeviceRevocation r in await _readRevocations()) {
      store.directory.trustRevocation(r);
    }
    _savedRevocations = store.directory.revocationRevision;
    for (final Object? a in _list(index['blocked'])) {
      if (a is String) {
        store.blockedAccounts.add(a);
      }
    }
    for (final Object? log in _list(index['logs'])) {
      if (log is! Map ||
          log['s'] is! String ||
          log['w'] is! String ||
          log['n'] is! int) {
        continue;
      }
      final String space = log['s'] as String;
      final String writer = log['w'] as String;
      final int count = log['n'] as int;
      final Object? b = log['b'];
      final Object? bi = log['bi'];
      final int base = b is int && b > 0 && b <= count && bi is String ? b : 0;
      if (base > 0) {
        store.restoreBase(space, writer, base, bi as String);
      }
      int restored = base;
      segments:
      for (int seg = base ~/ segmentSize; seg * segmentSize < count; seg++) {
        final List<dynamic>? list = await _readSegment(space, writer, seg);
        if (list == null) {
          break;
        }
        for (final Object? json in list) {
          final LogEntry? entry = LogEntry.fromJson(json);
          if (entry != null && entry.seq <= restored) {
            continue;
          }
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
      _savedBase['$space|$writer'] = base;
      if (restored < count) {
        incompleteLogs.add('$space|$writer');
        logZenWarning(
          'Ledger $space partly restored (${restored - base} of '
          '${count - base}); the rest will come from others.',
        );
      }
    }
    final Object? b = index['blobs'];
    if (b is Map) {
      final (List<BlobManifest>, List<String>, Map<String, String>) lists =
          await _readBlobLists(b);
      _savedBlobLists.addAll(lists.$3);
      final BlobChunkBackend backend = blobs.backend;
      if (backend is DiskBlobChunkBackend) {
        backend.restore(lists.$2);
      }
      blobs.restore(
        manifests: lists.$1,
        refused: <String>[
          for (final Object? r in _list(b['refused']))
            if (r is String) r,
        ],
        wanted: <String>[
          for (final Object? w in _list(b['wanted']))
            if (w is String) w,
        ],
        fetchedFor: _stringMap(b['for']),
        droppedFor: _stringMap(b['dropped']),
      );
    }
  }

  /// The entries of one segment as stored; null when it is missing or
  /// damaged (a newer build's segment is held by the store).
  Future<List<dynamic>?> _readSegment(
    String space,
    String writer,
    int segment,
  ) async {
    try {
      final Uint8List? data = await readOrSetAsideOn(
        disk,
        logKeyOf(space, writer, segment),
      );
      if (data == null) {
        return null;
      }
      final Object? list = jsonDecode(utf8.decode(data));
      return list is List ? list : null;
    } on FormatException {
      return null;
    }
  }

  /// The revocations on disk (none when the file is missing or damaged).
  Future<List<DeviceRevocation>> _readRevocations() async {
    final Uint8List? raw = await readOrSetAsideOn(disk, revocationsKey);
    if (raw == null) {
      return const <DeviceRevocation>[];
    }
    try {
      return <DeviceRevocation>[
        for (final Object? json in _list(jsonDecode(utf8.decode(raw))))
          ?DeviceRevocation.fromJson(json),
      ];
    } on FormatException {
      return const <DeviceRevocation>[];
    }
  }

  void _scheduleFlush() {
    if (_flushQueued || _paused) {
      return;
    }
    _flushQueued = true;
    scheduleMicrotask(() {
      _flushQueued = false;
      unawaitedLogged(flush(), context: 'Saving the ledger failed');
    });
  }

  /// Writes whatever changed. Calls are serialized.
  Future<void> flush() {
    final Future<void> next = _tail.then((_) => _flushNow());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  static Uint8List _jsonBytes(Object json) =>
      Uint8List.fromList(utf8.encode(jsonEncode(json)));

  Future<void> _flushNow() async {
    final LedgerStore? store = _store;
    final BlobStore? blobs = _blobs;
    if (store == null || blobs == null || _heldNewer) {
      return;
    }
    // First the certificates: an entry on disk always finds its own.
    await _flushCertificates(store.directory);
    final List<Map<String, dynamic>> logs = <Map<String, dynamic>>[];
    final Set<String> present = <String>{};
    for (final (String space, String writer, int count, bool forked)
        in store.logs.toList()) {
      final String key = '$space|$writer';
      present.add(key);
      final ({int base, String baseId}) start = store.baseOf(space, writer);
      await _flushLog(store, space, writer, count, start.base);
      logs.add(<String, dynamic>{
        's': space,
        'w': writer,
        'n': count,
        if (start.base > 0) 'b': start.base,
        if (start.base > 0) 'bi': start.baseId,
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
      final int base = _savedBase.remove(key) ?? 0;
      for (int seg = base ~/ segmentSize; seg * segmentSize < saved; seg++) {
        await disk.delete(logKeyOf(space, writer, seg));
      }
    }
    final List<String> lists = await _flushBlobLists(blobs);
    final int revocations = store.directory.revocationRevision;
    if (_savedRevocations != revocations) {
      await disk.write(
        revocationsKey,
        _jsonBytes(<Map<String, dynamic>>[
          for (final DeviceRevocation r in store.directory.revocations)
            r.toJson(),
        ]),
      );
      _savedRevocations = revocations;
    }
    await disk.write(
      indexKey,
      _jsonBytes(<String, dynamic>{
        'v': formatVersion,
        'logs': logs,
        'blocked': store.blockedAccounts.toList(),
        'certs': <String>[
          for (final String account in _savedCertificates.keys)
            _nameHash(account),
        ],
        'blobs': <String, dynamic>{
          'lists': lists,
          'refused': blobs.refused.toList(),
          'wanted': blobs.wanted.toList(),
          'for': blobs.fetchedFor,
          'dropped': blobs.droppedFor,
        },
      }),
    );
  }

  /// Rewrites the certificate files of the accounts whose certificates
  /// changed.
  Future<void> _flushCertificates(AccountDirectory directory) async {
    if (_checkedDirectory == directory.revision) {
      return;
    }
    for (final String account in directory.accounts.toList()) {
      final int revision = directory.revisionOf(account);
      if (_checkedCertificates[account] == revision) {
        continue;
      }
      final List<DeviceCertificate> certs = directory
          .devicesOf(account)
          .toList();
      final String print = _certPrint(certs);
      if (_savedCertificates[account] != print) {
        await disk.write(
          certificatesKeyOf(account),
          _jsonBytes(<String, dynamic>{
            'v': formatVersion,
            'a': account,
            'c': <Map<String, dynamic>>[
              for (final DeviceCertificate c in certs) c.toJson(),
            ],
          }),
        );
        _savedCertificates[account] = print;
      }
      _checkedCertificates[account] = revision;
    }
    _checkedDirectory = directory.revision;
  }

  /// Writes the segments of one log that changed since the last save.
  Future<void> _flushLog(
    LedgerStore store,
    String space,
    String writer,
    int count,
    int base,
  ) async {
    final String key = '$space|$writer';
    final int saved = _saved[key] ?? 0;
    final int savedBase = _savedBase[key] ?? 0;
    if (saved == count && savedBase == base) {
      return;
    }
    final int firstSegment = base ~/ segmentSize;
    // Segments wholly before where the log now starts (cut at its writer's
    // checkpoint) go; the one it starts in is written again.
    for (
      int seg = savedBase ~/ segmentSize;
      seg < firstSegment && seg * segmentSize < saved;
      seg++
    ) {
      await disk.delete(logKeyOf(space, writer, seg));
    }
    int from = (saved < count ? saved : count) ~/ segmentSize;
    if (savedBase != base || from < firstSegment) {
      from = firstSegment;
    }
    final int lastSegment = count == 0 ? -1 : (count - 1) ~/ segmentSize;
    for (int seg = from; seg <= lastSegment; seg++) {
      final int after = seg * segmentSize < base ? base : seg * segmentSize;
      final List<LogEntry> slice = store.entriesAfter(
        space,
        writer,
        after,
        limit: (seg + 1) * segmentSize - after,
      );
      await disk.write(
        logKeyOf(space, writer, seg),
        _jsonBytes(<Map<String, dynamic>>[
          for (final LogEntry e in slice) e.toJson(),
        ]),
      );
    }
    // Segments past the end (entries were cut off).
    final int oldLast = saved == 0 ? -1 : (saved - 1) ~/ segmentSize;
    for (int seg = lastSegment + 1; seg <= oldLast; seg++) {
      await disk.delete(logKeyOf(space, writer, seg));
    }
    _saved[key] = count;
    _savedBase[key] = base;
  }

  /// Rewrites the file lists that changed; returns the shards that have
  /// one.
  Future<List<String>> _flushBlobLists(BlobStore blobs) async {
    final Map<String, List<Map<String, dynamic>>> manifests =
        <String, List<Map<String, dynamic>>>{};
    final Map<String, List<String>> chunks = <String, List<String>>{};
    for (final BlobManifest m in blobs.manifests) {
      (manifests[_shardOf(m.id)] ??= <Map<String, dynamic>>[]).add(m.toJson());
    }
    for (final String h in blobs.backend.hashes) {
      (chunks[_shardOf(h)] ??= <String>[]).add(h);
    }
    final List<String> lists = <String>[];
    for (int i = 0; i < _shards.length; i++) {
      final String shard = _shards[i];
      final List<Map<String, dynamic>> m =
          manifests[shard] ?? const <Map<String, dynamic>>[];
      final List<String> c = chunks[shard] ?? const <String>[];
      if (m.isEmpty && c.isEmpty) {
        if (_savedBlobLists.remove(shard) != null) {
          await disk.delete(blobListKeyOf(shard));
        }
        continue;
      }
      lists.add(shard);
      final String text = jsonEncode(<String, dynamic>{
        'v': formatVersion,
        'm': m,
        'c': c,
      });
      if (_savedBlobLists[shard] != text) {
        await disk.write(
          blobListKeyOf(shard),
          Uint8List.fromList(utf8.encode(text)),
        );
        _savedBlobLists[shard] = text;
      }
    }
    return lists;
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
      _paused = _heldNewer;
      return;
    }
    try {
      final Map<dynamic, dynamic>? index = (await _readIndex()).index;
      if (index != null) {
        await _loadCertificates(store, index);
        for (final DeviceRevocation r in await _readRevocations()) {
          if (!store.directory.knowsRevocation(r)) {
            await store.applyRevocation(r);
          }
        }
        for (final Object? log in _list(index['logs'])) {
          if (log is! Map ||
              log['s'] is! String ||
              log['w'] is! String ||
              log['n'] is! int) {
            continue;
          }
          final String space = log['s'] as String;
          final String writer = log['w'] as String;
          final int count = log['n'] as int;
          final int base = log['b'] is int ? log['b'] as int : 0;
          final int have = store.headOf(space, writer);
          if (count <= have) {
            continue;
          }
          final int from = have > base ? have : base;
          for (
            int seg = from ~/ segmentSize;
            seg * segmentSize < count;
            seg++
          ) {
            final List<dynamic>? list = await _readSegment(space, writer, seg);
            if (list == null) {
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
          final int held = store.headOf(space, writer);
          _saved['$space|$writer'] = held < count ? held : count;
          _savedBase['$space|$writer'] = base;
        }
        final Object? b = index['blobs'];
        if (b is Map) {
          final (List<BlobManifest>, List<String>, Map<String, String>) lists =
              await _readBlobLists(b);
          _savedBlobLists
            ..clear()
            ..addAll(lists.$3);
          final BlobChunkBackend backend = blobs.backend;
          if (backend is DiskBlobChunkBackend) {
            backend.restore(lists.$2);
          }
          blobs.restore(
            manifests: lists.$1,
            refused: <String>[
              for (final Object? r in _list(b['refused']))
                if (r is String) r,
            ],
            wanted: const <String>[],
            fetchedFor: _stringMap(b['for']),
            droppedFor: _stringMap(b['dropped']),
          );
          for (final String id in blobs.wanted.toList()) {
            if (blobs.isComplete(id)) {
              blobs.markDone(id);
            }
          }
        }
      }
    } on FormatException {
      logZenWarning(
        'The ledger index is unreadable; keeping the state in memory.',
      );
    } finally {
      _paused = _heldNewer;
    }
    _scheduleFlush();
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await flush();
  }

  /// The archive's files on [disk] for an account backup: the index with
  /// only the logs whose space [keepSpace] admits, their segments, the
  /// certificate files and the file lists, and — [withPieces] — the file
  /// pieces (without them the lists name no pieces). Written back as they
  /// are (in this order: the index last), they open like the original.
  static Future<Map<String, Uint8List>> exportFiles(
    LedgerDisk disk, {
    required bool Function(String space) keepSpace,
    required bool withPieces,
    int segmentSize = 200,
  }) async {
    final Map<String, Uint8List> out = <String, Uint8List>{};
    // A damaged file is left out of the backup (the rest still goes).
    Future<Uint8List?> read(String key) async {
      try {
        return await disk.read(key);
      } on FormatException catch (error) {
        if (!isDamagedStoredFile(error)) {
          rethrow;
        }
        return null;
      }
    }

    final Uint8List? rawIndex = await read(indexKey);
    if (rawIndex == null) {
      return out;
    }
    final Object? index;
    try {
      index = jsonDecode(utf8.decode(rawIndex));
    } on FormatException {
      return out;
    }
    if (index is! Map || !isReadableFormat(index, current: formatVersion)) {
      return out;
    }
    final Uint8List? revocations = await read(revocationsKey);
    if (revocations != null) {
      out[revocationsKey] = revocations;
    }
    for (final Object? name in _list(index['certs'])) {
      if (name is! String) {
        continue;
      }
      final String key = '$certificatesPrefix$name';
      final Uint8List? data = await read(key);
      if (data != null) {
        out[key] = data;
      }
    }
    final List<Map<String, dynamic>> logs = <Map<String, dynamic>>[];
    for (final Object? log in _list(index['logs'])) {
      if (log is! Map ||
          log['s'] is! String ||
          log['w'] is! String ||
          log['n'] is! int ||
          !keepSpace(log['s'] as String)) {
        continue;
      }
      logs.add(Map<String, dynamic>.from(log));
      final String space = log['s'] as String;
      final String writer = log['w'] as String;
      final int count = log['n'] as int;
      final int base = log['b'] is int ? log['b'] as int : 0;
      for (int seg = base ~/ segmentSize; seg * segmentSize < count; seg++) {
        final String key = logKeyOf(space, writer, seg);
        final Uint8List? data = await read(key);
        if (data != null) {
          out[key] = data;
        }
      }
    }
    final Map<String, dynamic> filtered = Map<String, dynamic>.from(index)
      ..['logs'] = logs;
    final Object? blobs = index['blobs'];
    if (blobs is Map) {
      for (final Object? shard in _list(blobs['lists'])) {
        if (shard is! String) {
          continue;
        }
        final String key = blobListKeyOf(shard);
        final Uint8List? data = await read(key);
        if (data == null) {
          continue;
        }
        final Object? list;
        try {
          list = jsonDecode(utf8.decode(data));
        } on FormatException {
          continue;
        }
        if (list is! Map) {
          continue;
        }
        if (!withPieces) {
          out[key] = _jsonBytes(<String, dynamic>{
            ...Map<String, dynamic>.from(list),
            'c': const <String>[],
          });
          continue;
        }
        out[key] = data;
        for (final Object? h in _list(list['c'])) {
          if (h is! String) {
            continue;
          }
          final String chunkKey = DiskBlobChunkBackend.keyOf(h);
          final Uint8List? chunk = await read(chunkKey);
          if (chunk != null) {
            out[chunkKey] = chunk;
          }
        }
      }
    }
    out[indexKey] = _jsonBytes(filtered);
    return out;
  }
}

/// [json] when it is a list, else an empty one.
List<Object?> _list(Object? json) =>
    json is List ? json.cast<Object?>() : const <Object?>[];

/// The string-to-string pairs of [json] (anything else is left out).
Map<String, String> _stringMap(Object? json) {
  final Map<String, String> out = <String, String>{};
  if (json is Map) {
    json.forEach((Object? key, Object? value) {
      if (key is String && value is String) {
        out[key] = value;
      }
    });
  }
  return out;
}
