import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/storage/format_version.dart';

const int _now = 1790000000000;

LedgerStore _store() => LedgerStore(clock: HlcClock(wallClock: () => _now));

/// Logs that can start at their writer's checkpoint instead of entry 1:
/// what lets holders drop old history later without older builds seeing a
/// broken log.
void main() {
  late LedgerStore a;
  late LedgerAuthor author;
  late String space;
  late List<LogEntry> log;

  setUp(() async {
    a = _store();
    final LedgerAccountSetup setup = await LedgerAccountSetup.create();
    author = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: a,
    );
    space = accountSpace('feed', author.account);
    log = <LogEntry>[
      for (int i = 0; i < 3; i++)
        await author.append(space, 'post', <String, dynamic>{'n': i}),
      await author.checkpoint(space),
      await author.append(space, 'post', <String, dynamic>{'n': 3}),
    ];
  });

  test('a receiver takes a log that starts at a checkpoint', () async {
    final LedgerStore b = _store();
    expect((await b.ingest(log[3])).status, IngestStatus.added);
    expect((await b.ingest(log[4])).status, IngestStatus.added);
    expect(b.headOf(space, author.writer), 5);
    expect(b.baseOf(space, author.writer).base, 3);
    // What came before the checkpoint is not taken any more.
    expect((await b.ingest(log[1])).status, IngestStatus.duplicate);
    expect(b.isForked(space, author.writer), isFalse);
  });

  test('an entry that is no checkpoint still waits for its gap', () async {
    final LedgerStore b = _store();
    expect((await b.ingest(log[4])).status, IngestStatus.pending);
    expect(b.headOf(space, author.writer), 0);
  });

  test('a log behind a checkpoint moves to it when told to', () async {
    final LedgerStore b = _store();
    await b.ingest(log[0]);
    expect((await b.ingest(log[3])).status, IngestStatus.pending);
    expect(b.adoptCheckpoint(space, author.writer), isTrue);
    expect(b.headOf(space, author.writer), 4);
    expect((await b.ingest(log[4])).status, IngestStatus.added);
    expect(b.entries(space).map((LogEntry e) => e.seq), <int>[4, 5]);
  });

  test('a holder drops what came before a checkpoint and hands on the rest '
      'from there', () async {
    expect(a.pruneBefore(space, author.writer, 2), 0, reason: 'no checkpoint');
    expect(a.pruneBefore(space, author.writer, 4), 3);
    expect(
      a.entriesAfter(space, author.writer, 0).map((LogEntry e) => e.seq),
      <int>[4, 5],
    );
    // The author writes on from there.
    final LogEntry next = await author.append(space, 'post', <String, dynamic>{
      'n': 4,
    });
    expect(next.seq, 6);
    expect((await a.ingest(log[0])).status, IngestStatus.duplicate);
  });

  test('the archive keeps where a cut log starts', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerArchive archive = LedgerArchive(disk: disk, segmentSize: 2);
    await archive.open(a, BlobStore(backend: DiskBlobChunkBackend(disk)));
    a.pruneBefore(space, author.writer, 4);
    await archive.flush();
    final LedgerStore again = _store();
    final LedgerArchive reopened = LedgerArchive(disk: disk, segmentSize: 2);
    await reopened.open(again, BlobStore(backend: DiskBlobChunkBackend(disk)));
    expect(again.headOf(space, author.writer), 5);
    expect(again.baseOf(space, author.writer).base, 3);
    expect(reopened.incompleteLogs, isEmpty);
    expect(reopened.lostOwnLog(author.writer), isFalse);
    // Segment 0 (entries 1-2) went with the cut.
    expect(
      disk.files.keys.where(
        (String k) => k.startsWith('ledger/log-') && k.endsWith('-0'),
      ),
      isEmpty,
    );
  });

  test('one certificate file per account, the file lists in shards', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerArchive archive = LedgerArchive(disk: disk);
    final BlobStore blobs = BlobStore(backend: DiskBlobChunkBackend(disk));
    await archive.open(a, blobs);
    await blobs.put(Uint8List.fromList(List<int>.filled(100, 1)));
    await archive.flush();
    expect(
      disk.files.keys.where(
        (String k) => k.startsWith(LedgerArchive.certificatesPrefix),
      ),
      <String>[LedgerArchive.certificatesKeyOf(author.account)],
    );
    expect(
      disk.files.keys.where(
        (String k) => k.startsWith(LedgerArchive.blobListPrefix),
      ),
      isNotEmpty,
    );
    final Map<String, dynamic> index =
        jsonDecode(utf8.decode(disk.files[LedgerArchive.indexKey]!))
            as Map<String, dynamic>;
    expect(index.containsKey('blobs'), isTrue);
    expect((index['blobs'] as Map<String, dynamic>).containsKey('m'), isFalse);
  });

  test(
    'a newer build\'s index is kept as it is and nothing is written',
    () async {
      addTearDown(ZenFormatGuard.instance.reset);
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final Uint8List newer = Uint8List.fromList(
        utf8.encode(jsonEncode(<String, Object>{'v': 99, 'logs': <Object>[]})),
      );
      disk.files[LedgerArchive.indexKey] = newer;
      final LedgerStore b = _store();
      final LedgerArchive archive = LedgerArchive(disk: disk);
      await archive.open(b, BlobStore(backend: DiskBlobChunkBackend(disk)));
      expect(archive.heldNewer, isTrue);
      expect(archive.lostOwnLog(author.writer), isFalse);
      await b.ingest(log[0]);
      await archive.flush();
      expect(disk.files[LedgerArchive.indexKey], newer);
      expect(disk.files.length, 1);
      expect(ZenFormatGuard.instance.newerAreas, contains('ledger'));
    },
  );

  test('a log that came back short asks for a new writer', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerArchive archive = LedgerArchive(disk: disk, segmentSize: 2);
    await archive.open(a, BlobStore(backend: DiskBlobChunkBackend(disk)));
    await archive.flush();
    final String damaged = disk.files.keys.firstWhere(
      (String k) => k.startsWith('ledger/log-') && k.endsWith('-1'),
    );
    disk.files[damaged] = Uint8List.fromList(utf8.encode('nope'));
    final LedgerArchive reopened = LedgerArchive(disk: disk, segmentSize: 2);
    await reopened.open(
      _store(),
      BlobStore(backend: DiskBlobChunkBackend(disk)),
    );
    expect(reopened.incompleteLogs, isNotEmpty);
    expect(reopened.lostOwnLog(author.writer), isTrue);
    expect(reopened.lostOwnLog('0' * 32), isFalse);

    final LedgerArchive fresh = LedgerArchive(disk: MemoryLedgerDisk());
    await fresh.open(
      _store(),
      BlobStore(backend: DiskBlobChunkBackend(MemoryLedgerDisk())),
    );
    expect(fresh.indexMissing, isTrue);
  });
}
