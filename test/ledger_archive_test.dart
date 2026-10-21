import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

const int _now = 1790000000000;

final class _Device {
  _Device(this.disk, {int segmentSize = 3})
    : archive = LedgerArchive(disk: disk, segmentSize: segmentSize);

  final MemoryLedgerDisk disk;
  final LedgerArchive archive;
  final LedgerStore store = LedgerStore(clock: HlcClock(wallClock: () => _now));
  late final BlobStore blobs = BlobStore(backend: DiskBlobChunkBackend(disk));

  Future<_Device> open() async {
    await archive.open(store, blobs);
    return this;
  }
}

void main() {
  test('logs, files, cut-offs and blocks survive a restart', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final _Device first = await _Device(disk).open();
    final LedgerAccountSetup setup = await LedgerAccountSetup.create();
    final LedgerAuthor author = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: first.store,
    );
    final String space = accountSpace('feed', author.account);
    for (int i = 0; i < 8; i++) {
      await author.append(space, 'post', <String, dynamic>{'n': i});
    }
    final Uint8List photo = Uint8List.fromList(
      List<int>.generate(kBlobChunkSize + 5, (int i) => i % 199),
    );
    final String blobId = await first.blobs.put(photo, mime: 'image/jpeg');

    final LedgerAccountSetup other = await LedgerAccountSetup.create();
    first.store.blockAccount(other.accountKey.id);
    await first.archive.flush();

    final _Device second = await _Device(disk).open();
    expect(second.store.headOf(space, author.writer), 8);
    expect(second.store.entries(space).map((LogEntry e) => e.body['n']), <int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
    ]);
    expect(await second.blobs.read(blobId), photo);
    expect(second.store.blockedAccounts, contains(other.accountKey.id));

    // Keeps writing to the same log after the restart.
    final LedgerAuthor again = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: second.store,
      writer: author.writer,
    );
    await again.append(space, 'post', <String, dynamic>{'n': 8});

    // A cut-off is saved too, and the dropped entries stay dropped.
    await second.store.applyRevocation(
      await DeviceRevocation.issue(
        account: setup.accountKey,
        device: setup.deviceKey.id,
        cutoffs: <String, int>{author.writer: 4},
        issued: 1,
      ),
    );
    await second.archive.flush();

    final _Device third = await _Device(disk).open();
    expect(third.store.headOf(space, author.writer), 4);
    expect(
      third.store.directory.allowsEntry(
        account: setup.accountKey.id,
        device: setup.deviceKey.id,
        writer: author.writer,
        seq: 5,
      ),
      isFalse,
    );
  });

  test('saving happens by itself after changes', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final _Device device = await _Device(disk).open();
    final LedgerAccountSetup setup = await LedgerAccountSetup.create();
    final LedgerAuthor author = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: device.store,
    );
    await author.append(
      accountSpace('feed', author.account),
      'post',
      <String, dynamic>{'text': 'auto'},
    );
    // Let the scheduled save run.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await device.archive.flush();
    expect(disk.files.containsKey(LedgerArchive.indexKey), isTrue);
    // Entries are saved without the device certificate, which is kept once
    // on its own.
    final String segment = disk.files.keys.firstWhere(
      (String k) => k.startsWith('ledger/log-'),
    );
    expect(utf8.decode(disk.files[segment]!), isNot(contains('dev_cert')));
    expect(
      utf8.decode(disk.files[LedgerArchive.certificatesKey]!),
      contains(setup.certificate.signature),
    );

    final _Device reopened = await _Device(disk).open();
    expect(
      reopened.store.entries(accountSpace('feed', author.account)),
      hasLength(1),
    );
  });

  test('a damaged file restores what it can', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final _Device device = await _Device(disk).open();
    final LedgerAccountSetup setup = await LedgerAccountSetup.create();
    final LedgerAuthor author = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: device.store,
    );
    final String space = accountSpace('feed', author.account);
    for (int i = 0; i < 7; i++) {
      await author.append(space, 'post', <String, dynamic>{'n': i});
    }
    await device.archive.flush();

    // Corrupt the second segment (entries 4-6).
    final String segment = disk.files.keys.firstWhere(
      (String k) => k.startsWith('ledger/log-') && k.endsWith('-1'),
    );
    disk.files[segment] = Uint8List.fromList(utf8.encode('[{"zepsute":1}]'));

    final _Device reopened = await _Device(disk).open();
    expect(reopened.store.headOf(space, author.writer), 3);
  });
}
