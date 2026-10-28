// Owner report R5-#8 (28.10.2026, after 1.14.0): after the update to 1.14 the app stayed on the logo until its data was wiped.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Found meanwhile by test/persistence_fuzz_test.dart: a damaged ledger file
// (an archive part, the keys, the identity) threw out of LedgerNode._start
// (the store reports a seal that no longer opens as
// SecretBoxAuthenticationError, which no loader caught), so posts, profiles
// and the account's devices stayed off for the session, and FollowLedger
// left the error unhandled (follows.dart, `_ready = _start()`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import '../support/damaged_files.dart';

void main() {
  test(
    'R5-#8: the app starts after an update on the data the old version left',
    () {},
    skip:
        'R5-#8 open: after the update to 1.14 the app stayed on the logo until its data was wiped. '
        'Upgrade fixtures: test/fixtures/upgrade (in progress). The damaged ledger files the '
        'fuzz test found are covered below.',
  );

  late Directory root;
  late FileBinaryStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-r5-08-');
    store = sealedStore(root);
    DamagedIdentityNotice.instance.clear();
  });

  tearDown(() async {
    DamagedIdentityNotice.instance.clear();
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer.
    }
  });

  Future<LedgerNode> node() async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await transport.start();
    final LedgerNode n = LedgerNode(
      transport: transport,
      disk: FileLedgerDisk(store),
      friendAddresses: () => const <String>[],
    );
    addTearDown(n.stop);
    return n;
  }

  test('R5-#8: a damaged archive part or key file is set aside and the '
      'ledger starts with the rest', () async {
    final LedgerNode first = await node();
    await first.start();
    await first.publish('post', <String, dynamic>{'text': 'Pierwszy'});
    await first.archive.flush();
    final String account = first.account;
    final List<String> damaged = <String>[
      for (final (String space, String writer, int _, bool _)
          in first.store.logs)
        LedgerArchive.logKeyOf(space, writer, 0),
      LedgerArchive.certificatesKeyOf(account),
      LedgerArchive.revocationsKey,
    ];
    await first.stop();
    for (final String key in damaged) {
      if (await store.read(key) != null) {
        await damageStored(store, key);
      }
    }

    final LedgerNode again = await node();
    await again.start();

    expect(again.isReady, isTrue);
    expect(again.account, account, reason: 'the same account goes on');
    final LogEntry post = await again.publish('post', <String, dynamic>{
      'text': 'Drugi',
    });
    expect(post.account, account);
    expect(setAsideUnder(root), isNotEmpty);
  });

  test('R5-#8: a damaged identity is never replaced by a new account; the '
      'ledger stays off with a notice and nothing is left unhandled', () async {
    final LedgerIdentity original = await LedgerIdentity.loadOrCreate(
      FileLedgerDisk(store),
    );
    final File file = await damageStored(store, LedgerIdentity.storageKey);
    final Uint8List damagedBytes = file.readAsBytesSync();
    final FileLedgerDisk disk = FileLedgerDisk(store);

    expect(await LedgerIdentity.exists(disk), isTrue);
    expect(await LedgerIdentity.read(disk), isNull);
    await expectLater(
      LedgerIdentity.loadOrCreate(disk),
      throwsA(isA<DamagedLedgerIdentityException>()),
    );

    final List<Object> unhandled = <Object>[];
    final Completer<void> done = Completer<void>();
    runZonedGuarded(
      () async {
        final LedgerNode n = await node();
        // Attached as the app does: its start in the background.
        FollowLedger.of(n);
        await expectLater(
          n.start(),
          throwsA(isA<DamagedLedgerIdentityException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        done.complete();
      },
      (Object error, StackTrace _) {
        unhandled.add(error);
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );
    await done.future;

    expect(unhandled, isEmpty);
    expect(DamagedIdentityNotice.instance.damaged, isTrue);
    // Kept as it was: the account key is in it and nowhere else.
    expect(file.readAsBytesSync(), damagedBytes);
    expect(original.account, isNotEmpty);
  });

  test('R5-#8: an identity whose account key still reads becomes a new '
      'device of the same account', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity original = await LedgerIdentity.loadOrCreate(disk);
    final Map<String, dynamic> json =
        jsonDecode(utf8.decode(disk.files[LedgerIdentity.storageKey]!))
            as Map<String, dynamic>;
    json['cert'] = 'damaged';
    await disk.write(
      LedgerIdentity.storageKey,
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );

    final LedgerIdentity recovered = await LedgerIdentity.loadOrCreate(disk);

    expect(recovered.account, original.account);
    expect(recovered.deviceKey.id, isNot(original.deviceKey.id));
  });
}
