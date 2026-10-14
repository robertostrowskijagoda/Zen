import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

const int _now = 1790000000000;

LedgerStore _store() => LedgerStore(clock: HlcClock(wallClock: () => _now));

Future<(LedgerAccountSetup, LedgerAuthor)> _account(LedgerStore store) async {
  final LedgerAccountSetup setup = await LedgerAccountSetup.create();
  return (
    setup,
    LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: store,
    ),
  );
}

void main() {
  group('codec', () {
    test('canonical JSON sorts keys and is stable', () {
      expect(
        canonicalJson(<String, dynamic>{
          'b': 1,
          'a': <dynamic>[true, null, 'ż'],
          'c': <String, dynamic>{'z': 0, 'y': -5},
        }),
        '{"a":[true,null,"ż"],"b":1,"c":{"y":-5,"z":0}}',
      );
    });

    test('doubles are refused (their text is not stable)', () {
      expect(
        () => canonicalJson(<String, dynamic>{'x': 1.5}),
        throwsArgumentError,
      );
    });
  });

  group('clock', () {
    test('never goes backwards, even with a frozen wall clock', () {
      final HlcClock clock = HlcClock(wallClock: () => _now);
      final Hlc a = clock.now();
      final Hlc b = clock.now();
      expect(b > a, isTrue);
      expect(Hlc.fromInt(b.toInt()), b);
    });

    test('a time too far in the future is refused', () {
      final HlcClock clock = HlcClock(wallClock: () => _now);
      expect(clock.observe(const Hlc(_now + 5 * 60000, 0)), isTrue);
      expect(clock.observe(const Hlc(_now + 60 * 60000, 0)), isFalse);
      expect(clock.last.millis, _now + 5 * 60000);
    });
  });

  group('entries', () {
    test('a written entry verifies; any change breaks it', () async {
      final LedgerStore a = _store();
      final (_, LedgerAuthor author) = await _account(a);
      final LogEntry entry = await author.append(
        accountSpace('feed', author.account),
        'post',
        <String, dynamic>{'text': 'Cześć'},
      );
      expect(await entry.verifySignature(), isTrue);

      final Map<String, dynamic> tampered = entry.toJson()
        ..['body'] = <String, dynamic>{'text': 'Podmienione'};
      final LedgerStore b = _store();
      expect((await b.ingestJson(tampered)).status, IngestStatus.rejected);
      expect((await b.ingestJson(entry.toJson())).status, IngestStatus.added);
    });

    test('entries arriving out of order wait for the gap', () async {
      final LedgerStore a = _store();
      final (_, LedgerAuthor author) = await _account(a);
      final String space = accountSpace('feed', author.account);
      final List<LogEntry> written = <LogEntry>[
        for (int i = 0; i < 3; i++)
          await author.append(space, 'post', <String, dynamic>{'n': i}),
      ];
      final LedgerStore b = _store();
      final List<LogEntry> seen = <LogEntry>[];
      b.added.listen(seen.add);
      expect((await b.ingest(written[2])).status, IngestStatus.pending);
      expect((await b.ingest(written[0])).status, IngestStatus.added);
      expect(b.headOf(space, author.writer), 1);
      expect((await b.ingest(written[1])).status, IngestStatus.added);
      expect(b.headOf(space, author.writer), 3);
      expect(seen.map((LogEntry e) => e.seq), <int>[1, 2, 3]);
      expect((await b.ingest(written[1])).status, IngestStatus.duplicate);
    });

    test('two different entries at one position freeze the log', () async {
      final LedgerStore a = _store();
      final (LedgerAccountSetup setup, LedgerAuthor author) = await _account(a);
      final String space = accountSpace('feed', author.account);
      final LogEntry first = await author.append(
        space,
        'post',
        <String, dynamic>{'text': 'A'},
      );
      final LogEntry other = await LogEntry.create(
        deviceKey: setup.deviceKey,
        certificate: setup.certificate,
        space: space,
        writer: author.writer,
        seq: 1,
        prev: '',
        hlc: const Hlc(_now, 9),
        kind: 'post',
        body: <String, dynamic>{'text': 'B'},
      );
      final LedgerStore b = _store();
      expect((await b.ingest(first)).status, IngestStatus.added);
      expect((await b.ingest(other)).status, IngestStatus.forked);
      expect(b.isForked(space, author.writer), isTrue);
      final LogEntry next = await author.append(
        space,
        'post',
        <String, dynamic>{},
      );
      expect((await b.ingest(next)).status, IngestStatus.rejected);
    });

    test(
      'only the owner may write in a space; unknown spaces are refused',
      () async {
        final LedgerStore store = _store();
        final (_, LedgerAuthor ada) = await _account(store);
        final (_, LedgerAuthor bob) = await _account(store);

        await expectLater(
          bob.append(
            accountSpace('feed', ada.account),
            'post',
            <String, dynamic>{},
          ),
          throwsStateError,
        );
        await expectLater(
          ada.append(kPowerSpace, 'ban', <String, dynamic>{}),
          throwsStateError,
        );
        await expectLater(
          ada.append('whatever/${ada.account}', 'post', <String, dynamic>{}),
          throwsStateError,
        );
        await ada.append(
          accountSpace('acts', ada.account),
          'like',
          <String, dynamic>{},
        );
      },
    );

    test('entries from the future are refused', () async {
      final LedgerStore a = _store();
      final (LedgerAccountSetup setup, LedgerAuthor author) = await _account(a);
      final LogEntry future = await LogEntry.create(
        deviceKey: setup.deviceKey,
        certificate: setup.certificate,
        space: accountSpace('feed', author.account),
        writer: author.writer,
        seq: 1,
        prev: '',
        hlc: const Hlc(_now + 24 * 3600 * 1000, 0),
        kind: 'post',
        body: <String, dynamic>{'text': 'Z 2099'},
      );
      expect((await _store().ingest(future)).status, IngestStatus.rejected);
    });

    test(
      'kinds and versions from a newer app are kept and passed on',
      () async {
        final LedgerStore a = _store();
        final (LedgerAccountSetup setup, LedgerAuthor author) = await _account(
          a,
        );
        final LogEntry newer = await LogEntry.create(
          deviceKey: setup.deviceKey,
          certificate: setup.certificate,
          space: accountSpace('feed', author.account),
          writer: author.writer,
          seq: 1,
          prev: '',
          hlc: const Hlc(_now, 0),
          kind: 'hologram',
          body: <String, dynamic>{
            'x': <int>[1, 2, 3],
          },
        );
        final Map<String, dynamic> json = newer.toJson();
        expect(LogEntry.fromJson(json)!.kind, 'hologram');
        final LedgerStore b = _store();
        expect((await b.ingestJson(json)).status, IngestStatus.added);
      },
    );

    test('an oversized entry cannot be written', () async {
      final LedgerStore a = _store();
      final (_, LedgerAuthor author) = await _account(a);
      await expectLater(
        author.append(
          accountSpace('feed', author.account),
          'post',
          <String, dynamic>{'text': 'x' * (kMaxEntryBytes + 1)},
        ),
        throwsArgumentError,
      );
    });

    test(
      'a reinstalled app starts a new log instead of forking the old one',
      () async {
        final LedgerStore store = _store();
        final (LedgerAccountSetup setup, LedgerAuthor before) = await _account(
          store,
        );
        final String space = accountSpace('feed', before.account);
        await before.append(space, 'post', <String, dynamic>{'n': 1});

        // Same keys restored from a backup, fresh installation: new log.
        final LedgerStore restored = _store();
        final LedgerAuthor after = LedgerAuthor(
          deviceKey: setup.deviceKey,
          certificate: setup.certificate,
          store: restored,
        );
        final LogEntry again = await after.append(
          space,
          'post',
          <String, dynamic>{'n': 2},
        );
        expect(after.writer, isNot(before.writer));
        expect((await store.ingest(again)).status, IngestStatus.added);
        expect(store.heads(space), hasLength(2));
      },
    );
  });

  group('lost devices', () {
    test('a cut-off device keeps its old entries, loses the rest', () async {
      final LedgerStore store = _store();
      final LedgerAccountSetup setup = await LedgerAccountSetup.create();
      final (LedgerKeyPair phoneKey, DeviceCertificate phoneCert) = await setup
          .addDevice(name: 'Telefon');
      final LedgerAuthor phone = LedgerAuthor(
        deviceKey: phoneKey,
        certificate: phoneCert,
        store: store,
      );
      final String space = accountSpace('feed', setup.accountKey.id);
      final List<LogEntry> written = <LogEntry>[
        for (int i = 0; i < 5; i++)
          await phone.append(space, 'post', <String, dynamic>{'n': i}),
      ];

      // The owner had seen 3 of them when the phone was stolen.
      final DeviceRevocation revocation = await DeviceRevocation.issue(
        account: setup.accountKey,
        device: phoneKey.id,
        cutoffs: <String, int>{phone.writer: 3},
        issued: 1,
      );
      expect(await store.applyRevocation(revocation), 2);
      expect(store.headOf(space, phone.writer), 3);

      // Another device learning about it refuses everything after.
      final LedgerStore other = _store();
      await other.applyRevocation(revocation);
      for (final LogEntry e in written) {
        final IngestStatus status = (await other.ingest(e)).status;
        expect(
          status,
          e.seq <= 3 ? IngestStatus.added : IngestStatus.rejected,
          reason: 'seq ${e.seq}',
        );
      }
      // A log the owner never saw (thief's new install) is refused whole.
      final LedgerAuthor thief = LedgerAuthor(
        deviceKey: phoneKey,
        certificate: phoneCert,
        store: _store(),
      );
      final LogEntry forged = await thief.append(
        space,
        'post',
        <String, dynamic>{},
      );
      expect((await other.ingest(forged)).status, IngestStatus.rejected);
    });

    test('a revocation must be signed by the account', () async {
      final LedgerAccountSetup ada = await LedgerAccountSetup.create();
      final LedgerAccountSetup eve = await LedgerAccountSetup.create();
      final DeviceRevocation fake = await DeviceRevocation.issue(
        account: eve.accountKey,
        device: ada.deviceKey.id,
        cutoffs: const <String, int>{},
        issued: 1,
      );
      final Map<String, dynamic> json = fake.toJson()
        ..['account'] = ada.accountKey.id;
      final LedgerStore store = _store();
      expect(await store.applyRevocation(DeviceRevocation.fromJson(json)!), -1);
    });
  });

  test('blocking an account drops and refuses its entries', () async {
    final LedgerStore a = _store();
    final (_, LedgerAuthor author) = await _account(a);
    final String space = accountSpace('feed', author.account);
    final LogEntry first = await author.append(
      space,
      'post',
      <String, dynamic>{},
    );
    final LogEntry second = await author.append(
      space,
      'post',
      <String, dynamic>{},
    );
    final LedgerStore b = _store();
    await b.ingest(first);
    b.blockAccount(author.account);
    expect(b.heads(space), isEmpty);
    expect((await b.ingest(second)).status, IngestStatus.rejected);
  });

  group('blobs', () {
    test(
      'a file is split into verified pieces and put back together',
      () async {
        final BlobStore store = BlobStore();
        final Uint8List bytes = Uint8List.fromList(
          List<int>.generate(kBlobChunkSize * 2 + 10, (int i) => i % 251),
        );
        final String id = await store.put(bytes, mime: 'image/jpeg');
        final BlobManifest manifest = store.manifest(id)!;
        expect(manifest.chunks, hasLength(3));
        expect(await store.read(id), bytes);
        expect(BlobManifest.fromJson(manifest.toJson())!.id, id);
      },
    );

    test('pieces nobody asked for are not stored', () async {
      final BlobStore source = BlobStore();
      final String id = await source.put(Uint8List.fromList(<int>[1, 2, 3]));
      final BlobStore target = BlobStore();
      final String hash = source.manifest(id)!.chunks.single;
      final Uint8List piece = (await source.chunk(hash))!;
      expect(await target.acceptChunk(hash, piece), isFalse);
      expect(target.acceptManifest(id, source.manifest(id)!.toJson()), isFalse);

      target.want(id);
      expect(target.acceptManifest(id, source.manifest(id)!.toJson()), isTrue);
      expect(
        await target.acceptChunk(hash, Uint8List.fromList(<int>[9, 9, 9])),
        isFalse,
      );
      expect(await target.acceptChunk(hash, piece), isTrue);
      expect(await target.read(id), <int>[1, 2, 3]);
    });

    test('a removed file is never taken again', () async {
      final BlobStore source = BlobStore();
      final String id = await source.put(Uint8List.fromList(<int>[4, 5, 6]));
      final BlobStore target = BlobStore()..want(id);
      await target.refuse(id);
      target.want(id);
      expect(target.acceptManifest(id, source.manifest(id)!.toJson()), isFalse);
    });
  });
}
