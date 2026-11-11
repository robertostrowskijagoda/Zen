import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_replicator.dart';
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
  late LedgerAccountSetup setup;

  setUp(() async {
    a = _store();
    setup = await LedgerAccountSetup.create();
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

  // A checkpoint that says which entries after it carry the log's state
  // (from 1.16.5): every holder may drop what came before, once those are
  // held; never on anyone's word but the writer's, never back.
  group('a checkpoint that carries the state', () {
    late List<LogEntry> start;

    LedgerDraft post(int n) => (
      kind: 'post',
      body: <String, dynamic>{'n': n},
      blobs: const <String>[],
    );

    setUp(() async {
      // Entries 6 (the checkpoint, n: 2), 7 and 8.
      start = await author.rebase(space, <LedgerDraft>[post(10), post(11)]);
    });

    Future<LedgerStore> holding(Iterable<LogEntry> entries) async {
      final LedgerStore b = _store();
      for (final LogEntry e in entries) {
        await b.ingest(e);
      }
      return b;
    }

    test('a holder may drop what came before it only once everything it '
        'carries is held', () async {
      expect(rebaseCountOf(start.first), 2);
      expect(rebaseCountOf(log[3]), isNull, reason: 'says nothing');
      final LedgerStore b = await holding(<LogEntry>[...log, start.first]);
      expect(b.readyRebase(space, author.writer), isNull);
      await b.ingest(start[1]);
      expect(b.readyRebase(space, author.writer), isNull);
      await b.ingest(start[2]);
      expect(b.readyRebase(space, author.writer), 6);
      expect(b.pruneBefore(space, author.writer, 6), 5);
      expect(b.entries(space).map((LogEntry e) => e.seq), <int>[6, 7, 8]);
      expect(b.readyRebase(space, author.writer), isNull, reason: 'done');
    });

    test('a holder behind moves to it only with everything it carries: a '
        'peer handing on the checkpoint alone cannot make it give up what '
        'it holds', () async {
      final LedgerStore b = await holding(<LogEntry>[log[0]]);
      expect((await b.ingest(start.first)).status, IngestStatus.pending);
      expect(b.adoptCheckpoint(space, author.writer), isFalse);
      expect(b.entries(space).map((LogEntry e) => e.seq), <int>[1]);
      await b.ingest(start[1]);
      expect(b.entries(space).map((LogEntry e) => e.seq), <int>[1]);
      // The last carried entry comes: the log moves on its own.
      await b.ingest(start[2]);
      expect(b.entries(space).map((LogEntry e) => e.seq), <int>[6, 7, 8]);
      expect(b.baseOf(space, author.writer).base, 5);
    });

    test('a forged, altered, foreign or replayed checkpoint drops '
        'nothing', () async {
      final LedgerStore b = await holding(<LogEntry>[...log, ...start]);
      b.pruneBefore(space, author.writer, 6);
      // Altered: its count no longer matches its signature.
      final Map<String, dynamic> altered = start.first.toCertifiedJson()
        ..['seq'] = 9
        ..['prev'] = start.last.id
        ..['body'] = <String, dynamic>{'n': 0};
      expect((await b.ingestJson(altered)).status, IngestStatus.rejected);
      // Forged by another account into this one's space and log.
      final LedgerAccountSetup other = await LedgerAccountSetup.create();
      final LogEntry forged = await LogEntry.create(
        deviceKey: other.deviceKey,
        certificate: other.certificate,
        space: space,
        writer: author.writer,
        seq: 9,
        prev: start.last.id,
        hlc: a.clock.now(),
        kind: kLedgerCheckpointKind,
        body: <String, dynamic>{'n': 0},
      );
      expect((await b.ingest(forged)).status, IngestStatus.rejected);
      // Replayed: an older checkpoint and this one again.
      expect((await b.ingest(log[3])).status, IngestStatus.duplicate);
      expect((await b.ingest(start.first)).status, IngestStatus.duplicate);
      expect(b.entries(space).map((LogEntry e) => e.seq), <int>[6, 7, 8]);
      expect(b.baseOf(space, author.writer).base, 5);
      // Another device of the account starting its own log over cuts only
      // that log.
      final (LedgerKeyPair key, DeviceCertificate cert) = await setup
          .addDevice();
      final LedgerAuthor sibling = LedgerAuthor(
        deviceKey: key,
        certificate: cert,
        store: b,
      );
      await sibling.append(space, 'post', <String, dynamic>{'n': 0});
      await sibling.rebase(space, <LedgerDraft>[]);
      expect(b.readyRebase(space, sibling.writer), 2);
      expect(b.readyRebase(space, author.writer), isNull);
      expect(
        b.entries(space).where((LogEntry e) => e.writer == author.writer),
        hasLength(3),
      );
    });

    test('a run joins the log in one go, or not at all', () async {
      int changes = 0;
      final LedgerStore b = await holding(<LogEntry>[...log, ...start]);
      final StreamSubscription<void> sub = b.changed.listen((_) => changes++);
      addTearDown(sub.cancel);
      final LedgerAuthor writer = LedgerAuthor(
        deviceKey: setup.deviceKey,
        certificate: setup.certificate,
        store: b,
        writer: author.writer,
      );
      final List<LogEntry> run = await writer.appendRun(space, <LedgerDraft>[
        post(20),
        post(21),
        post(22),
      ]);
      expect(run.map((LogEntry e) => e.seq), <int>[9, 10, 11]);
      expect(changes, 1);
      // A run that does not follow what is held takes nothing.
      final LogEntry stray = await LogEntry.create(
        deviceKey: setup.deviceKey,
        certificate: setup.certificate,
        space: space,
        writer: author.writer,
        seq: 13,
        prev: run.last.id,
        hlc: b.clock.now(),
        kind: 'post',
        body: const <String, dynamic>{},
      );
      expect(await b.ingestRun(<LogEntry>[stray]), isFalse);
      expect(b.headOf(space, author.writer), 11);
    });

    test('a holder by the rules before 1.16.5 (it never drops anything) '
        'keeps serving the whole log, and one behind follows a cut copy '
        'to the checkpoint', () async {
      final LedgerStore old = await holding(<LogEntry>[...log, ...start]);
      final LedgerStore cut = await holding(<LogEntry>[...log, ...start]);
      cut.pruneBefore(space, author.writer, 6);
      final LedgerStore behind = await holding(<LogEntry>[log[0], log[1]]);
      final LedgerStore fresh = _store();
      final Map<String, LedgerReplicator> net = <String, LedgerReplicator>{};
      void wire(String name, LedgerStore store) {
        net[name] = LedgerReplicator(
          store: store,
          blobs: BlobStore(backend: DiskBlobChunkBackend(MemoryLedgerDisk())),
          send: (String peer, Map<String, dynamic> message) {
            final Map<String, dynamic> copy =
                jsonDecode(jsonEncode(message)) as Map<String, dynamic>;
            scheduleMicrotask(() => net[peer]?.handle(name, copy));
          },
          peers: () => const <String>[],
        )..subscribe(space);
      }

      wire('old', old);
      wire('cut', cut);
      wire('behind', behind);
      wire('fresh', fresh);
      Future<void> sync(String a, String b) async {
        for (int i = 0; i < 4; i++) {
          net[a]!.syncWith(b);
          net[b]!.syncWith(a);
          for (int j = 0; j < 40; j++) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }

      await sync('fresh', 'old');
      expect(fresh.entries(space).map((LogEntry e) => e.seq), <int>[
        for (int s = 1; s <= 8; s++) s,
      ]);
      await sync('behind', 'cut');
      expect(behind.entries(space).map((LogEntry e) => e.seq), <int>[6, 7, 8]);
      expect(behind.isForked(space, author.writer), isFalse);
      // The old holder and the cut one agree on where the log is.
      expect(
        old.headOf(space, author.writer),
        cut.headOf(space, author.writer),
      );
    });
  });
}
