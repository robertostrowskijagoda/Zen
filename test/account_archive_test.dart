import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_collect.dart';
import 'package:zen/src/features/account/account_backup_io.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/circle_backup.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);
const List<PasswordCost> _accepted = <PasswordCost>[_light];

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList(List<int>.generate(n, (int i) => (i * 31 + seed) % 251));

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// An account with something in every part.
final class _Source implements AccountArchiveSource {
  _Source({bool locked = false})
    : seed = locked ? null : Uint8List.fromList(List<int>.filled(32, 7));

  @override
  final String account = 'acc-1';

  @override
  final Uint8List? seed;

  @override
  final MemoryLedgerDisk disk = MemoryLedgerDisk();

  final Map<String, Uint8List> files = <String, Uint8List>{
    '/media/photo.jpg': _bytes(300 * 1024, 1),
    '/media/avatar.jpg': _bytes(2000, 2),
    '/media/cover.jpg': _bytes(3000, 3),
  };

  final Map<String, List<ChatMessage>> chats = <String, List<ChatMessage>>{
    '200::1': <ChatMessage>[
      const ChatMessage(
        id: 'm1',
        sender: '200::1',
        text: 'Cześć',
        sentAtMillis: 10,
        direction: ChatMessageDirection.incoming,
      ),
      const ChatMessage(
        id: 'm2',
        sender: 'me',
        text: '',
        sentAtMillis: 20,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.image,
        attachmentPath: '/media/photo.jpg',
      ),
      const ChatMessage(
        id: 'm3',
        sender: 'me',
        text: 'znika',
        sentAtMillis: 30,
        direction: ChatMessageDirection.outgoing,
        expiresAtMillis: 99,
      ),
    ],
    'group:g1': <ChatMessage>[
      ChatMessage(
        id: 'g1m1',
        sender: '200::2',
        text: '',
        sentAtMillis: 40,
        direction: ChatMessageDirection.incoming,
        type: ChatMessageType.voice,
        attachmentBytes: _bytes(500, 4),
      ),
    ],
  };

  Future<void> fill() async {
    await disk.write('chat/strangers', _json(<String, Object>{'x': 1}));
    await disk.write('pyramid/ledger', _json(<String, Object>{'p': 1}));
    for (final String k in kAccountRawKeys[AccountScope.meet]!) {
      await disk.write(k, _json(<String, Object>{'k': k}));
    }
    await disk.write('films/state', _json(<String, Object>{'f': 1}));
    await disk.write(
      LedgerArchive.indexKey,
      _json(<String, Object>{
        'v': 1,
        'logs': <Object>[
          <String, Object>{'s': 'feed/$account', 'w': 'dev', 'n': 2},
          <String, Object>{'s': 'own/$account', 'w': 'dev', 'n': 1},
          <String, Object>{'s': 'private/$account', 'w': 'dev', 'n': 1},
        ],
        'certs': <String>[
          LedgerArchive.certificatesKeyOf(
            account,
          ).substring(LedgerArchive.certificatesPrefix.length),
        ],
        'blobs': <String, Object>{
          'lists': <String>['0'],
        },
      }),
    );
    await disk.write(
      LedgerArchive.blobListKeyOf('0'),
      _json(<String, Object>{
        'v': 1,
        'm': <Object>[],
        'c': <String>['h1'],
      }),
    );
    await disk.write(accountLogKey('feed/$account', 'dev', 0), _json(<int>[1]));
    await disk.write(accountLogKey('own/$account', 'dev', 0), _json(<int>[2]));
    await disk.write(
      accountLogKey('private/$account', 'dev', 0),
      _json(<int>[3]),
    );
    await disk.write(DiskBlobChunkBackend.keyOf('h1'), _bytes(4000, 5));
    await disk.write(
      LedgerArchive.certificatesKeyOf(account),
      _json(<String, Object>{'v': 1, 'a': account, 'c': <Object>[]}),
    );
  }

  @override
  Map<String, dynamic> contacts() => <String, dynamic>{
    'v': 1,
    'friends': <Object>[
      <String, dynamic>{'a': '200::1', 'n': 'Ola'},
    ],
    'groups': <Object>[
      <String, dynamic>{'id': 'g1', 'name': 'Rodzina', 'm': <String>[]},
    ],
  };

  @override
  Map<String, String> levels() => <String, String>{'200::1': 'close'};

  @override
  List<String> conversationKeys() => chats.keys.toList();

  @override
  Future<List<ChatMessage>> messages(String key) async =>
      chats[key] ?? <ChatMessage>[];

  @override
  Map<String, dynamic> profile() => <String, dynamic>{'displayName': 'Ania'};

  @override
  String? get avatarPath => '/media/avatar.jpg';

  @override
  String? get coverPath => '/media/cover.jpg';

  @override
  Map<String, dynamic> settings() => <String, dynamic>{'look': 'calm'};

  @override
  Map<String, dynamic>? pyramid() => <String, dynamic>{'wallet': 5};

  @override
  Map<String, dynamic> dating() => <String, dynamic>{'n': 'Ania'};

  @override
  Future<Map<String, dynamic>?> household() async => <String, dynamic>{
    'flat': 'f1',
  };

  @override
  Future<Uint8List?> readState(String key) => disk.read(key);

  /// Every range asked for (a file is never read whole).
  final List<int> ranges = <int>[];

  @override
  Future<Uint8List?> readFileRange(String path, int start, int end) async {
    ranges.add(end - start);
    final Uint8List? f = files[path];
    return f == null ? null : Uint8List.sublistView(f, start, end);
  }

  @override
  Future<int?> fileSize(String path) async => files[path]?.length;
}

/// A device that takes copies, in memory.
final class _Sink implements AccountArchiveSink {
  _Sink({this.account, this.fresh = true});

  String? account;
  bool fresh;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final List<String> calls = <String>[];
  AccountArchive? applied;
  bool? appliedMerge;
  final Map<String, Uint8List> appliedFiles = <String, Uint8List>{};

  @override
  Future<String?> currentAccount() async => account;

  @override
  Future<bool> isFresh() async => fresh;

  @override
  Future<void> adoptAccount(AccountArchive archive) async {
    calls.add('adopt');
    account = archive.account;
  }

  @override
  Future<void> writeRaw(
    String key,
    Uint8List value, {
    required bool onlyIfAbsent,
  }) async {
    if (onlyIfAbsent && await disk.read(key) != null) {
      return;
    }
    await disk.write(key, value);
  }

  @override
  Future<AccountImportSummary> apply(
    AccountArchive archive,
    AccountArchiveBlob? Function(String id) file,
    void Function(int done, int total) progress, {
    required bool merge,
  }) async {
    calls.add('apply');
    applied = archive;
    appliedMerge = merge;
    for (final String id in archive.files.keys) {
      final AccountArchiveBlob? blob = file(id);
      if (blob != null) {
        appliedFiles[id] = await _all(blob);
      }
    }
    progress(1, 1);
    return AccountImportSummary(
      messages: archive.messageCount,
      files: appliedFiles.length,
      parts: archive.scope,
    );
  }

  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async {
    calls.add('stop');
    await whileStopped?.call();
    calls.add('restart');
  }
}

Future<Uint8List> _write(AccountArchiveBuild build, String password) async {
  final BytesBuilder out = BytesBuilder();
  await AccountBackupFile.write(
    archive: build.archive,
    blobs: build.blobs,
    password: password,
    cost: _light,
    out: (Uint8List bytes) async => out.add(bytes),
  );
  return out.takeBytes();
}

Future<({AccountArchive? archive, AccountBackupError? error})> _read(
  Uint8List file,
  String password, {
  Map<String, Uint8List>? into,
}) => AccountBackupFile.read(
  chunks: Stream<List<int>>.fromIterable(<List<int>>[
    // In odd pieces, as a file comes.
    for (int at = 0; at < file.length; at += 70001)
      file.sublist(at, (at + 70001).clamp(0, file.length)),
  ]),
  password: password,
  acceptedCosts: _accepted,
  file: (String id, int size) async => _Collect((Uint8List bytes) {
    into?[id] = bytes;
  }),
);

/// A file of a copy, whole (tests only).
Future<Uint8List> _all(AccountArchiveBlob blob) async {
  final BytesBuilder out = BytesBuilder(copy: false);
  await for (final Uint8List part in blob.chunks()) {
    out.add(part);
  }
  return out.takeBytes();
}

/// Collects a file as its pieces come (and the size of each piece).
final class _Collect implements AccountFileWriter {
  _Collect(this.done);

  final void Function(Uint8List bytes) done;
  final BytesBuilder _out = BytesBuilder(copy: false);
  final List<int> pieces = <int>[];

  @override
  Future<void> add(Uint8List chunk) async {
    pieces.add(chunk.length);
    _out.add(Uint8List.fromList(chunk));
  }

  @override
  Future<void> close() async => done(_out.takeBytes());
}

void main() {
  group('collecting a copy', () {
    test(
      'every part of the account goes in when everything is chosen',
      () async {
        final _Source source = _Source();
        await source.fill();
        final AccountArchiveBuild build = await buildAccountArchive(
          source,
          kAllAccountScopes,
          at: 1,
        );
        final AccountArchive a = build.archive;
        expect(a.account, 'acc-1');
        expect(a.seed, source.seed);
        for (final String section in <String>[
          CircleBackupSections.contacts,
          CircleBackupSections.levels,
          CircleBackupSections.profile,
          CircleBackupSections.settings,
          CircleBackupSections.pyramid,
          CircleBackupSections.dating,
          CircleBackupSections.household,
        ]) {
          expect(a.sections, contains(section), reason: section);
        }
        // Conversations with their files; disappearing messages never.
        expect(a.chats.keys, containsAll(<String>['200::1', 'group:g1']));
        expect(
          a.chats['200::1']!.map((Map<String, dynamic> m) => m['id']),
          <String>['m1', 'm2'],
        );
        final String photo = a.chats['200::1']![1]['af'] as String;
        expect(build.blobs[photo]!.size, 300 * 1024);
        expect(a.chats['group:g1']!.single['af'], isA<String>());
        final Map<String, dynamic> profile =
            a.sections[CircleBackupSections.profile]! as Map<String, dynamic>;
        expect(profile[kAccountAvatarFile], isA<String>());
        expect(profile[kAccountCoverFile], isA<String>());
        // Stored states of chats, pyramid, meetings, films; the whole log.
        expect(
          a.raw.keys,
          containsAll(<String>[
            'chat/strangers',
            'pyramid/ledger',
            ...kAccountRawKeys[AccountScope.meet]!,
            'films/state',
            LedgerArchive.indexKey,
            LedgerArchive.certificatesKeyOf('acc-1'),
            LedgerArchive.blobListKeyOf('0'),
            accountLogKey('feed/acc-1', 'dev', 0),
            accountLogKey('own/acc-1', 'dev', 0),
            accountLogKey('private/acc-1', 'dev', 0),
            DiskBlobChunkBackend.keyOf('h1'),
          ]),
        );
        for (final String id in a.raw.values) {
          expect(a.files, contains(id));
        }
      },
    );

    test('each part alone brings only itself', () async {
      final _Source source = _Source();
      await source.fill();
      Future<AccountArchive> only(AccountScope s) async =>
          (await buildAccountArchive(source, <AccountScope>{s}, at: 1)).archive;

      final AccountArchive keys = await only(AccountScope.keys);
      expect(keys.seed, isNotNull);
      expect(keys.sections, isEmpty);
      expect(keys.chats, isEmpty);
      expect(keys.raw, isEmpty);

      final AccountArchive contacts = await only(AccountScope.contacts);
      expect(contacts.seed, isNull);
      expect(contacts.sections.keys, <String>[
        CircleBackupSections.contacts,
        CircleBackupSections.levels,
      ]);

      final AccountArchive chats = await only(AccountScope.chats);
      expect(chats.chats, isNotEmpty);
      expect(
        chats.chats.values.expand((List<Map<String, dynamic>> m) => m),
        everyElement(isNot(contains('af'))),
        reason: 'files only with "Załączniki i media"',
      );
      expect(chats.raw.keys, contains('chat/strangers'));
      expect(chats.raw.keys, isNot(contains('pyramid/ledger')));

      final AccountArchive profile = await only(AccountScope.profile);
      expect(profile.sections.keys, <String>[CircleBackupSections.profile]);
      // The log, without the own devices' chats and contacts, and without
      // the pieces of files (no media).
      expect(profile.raw.keys, contains(accountLogKey('feed/acc-1', 'dev', 0)));
      expect(
        profile.raw.keys,
        isNot(contains(accountLogKey('own/acc-1', 'dev', 0))),
      );
      expect(
        profile.raw.keys,
        isNot(contains(accountLogKey('private/acc-1', 'dev', 0))),
      );
      expect(
        profile.raw.keys,
        isNot(contains(DiskBlobChunkBackend.keyOf('h1'))),
      );

      expect((await only(AccountScope.settings)).sections.keys, <String>[
        CircleBackupSections.settings,
      ]);
      final AccountArchive pyramid = await only(AccountScope.pyramid);
      expect(pyramid.sections.keys, <String>[CircleBackupSections.pyramid]);
      expect(pyramid.raw.keys, <String>['pyramid/ledger']);
      expect((await only(AccountScope.dating)).sections.keys, <String>[
        CircleBackupSections.dating,
      ]);
      expect((await only(AccountScope.neighbors)).sections.keys, <String>[
        CircleBackupSections.household,
      ]);
      expect(
        (await only(AccountScope.meet)).raw.keys,
        kAccountRawKeys[AccountScope.meet],
      );
      final AccountArchive films = await only(AccountScope.films);
      expect(films.raw.keys, contains('films/state'));
      expect(films.raw.keys, contains(LedgerArchive.indexKey));
    });

    test('the estimate measures without reading the files', () async {
      final _Source source = _Source();
      await source.fill();
      final AccountArchiveBuild real = await buildAccountArchive(
        source,
        kAllAccountScopes,
        at: 1,
      );
      final AccountArchiveBuild measured = await buildAccountArchive(
        source,
        kAllAccountScopes,
        measureOnly: true,
        at: 1,
      );
      expect(measured.archive.totalBytes, real.archive.totalBytes);
      await expectLater(
        buildAccountArchive(_Source(locked: true), kAllAccountScopes),
        throwsStateError,
        reason: 'a copy with the key needs the key unlocked',
      );
      final AccountArchiveBuild estimate = await buildAccountArchive(
        _Source(locked: true),
        kAllAccountScopes,
        measureOnly: true,
      );
      expect(estimate.archive.totalBytes, greaterThan(300 * 1024));
    });
  });

  group('backup file', () {
    late AccountArchiveBuild build;

    setUp(() async {
      final _Source source = _Source();
      await source.fill();
      build = await buildAccountArchive(source, kAllAccountScopes, at: 5);
    });

    test('round trip: the manifest and every file come back', () async {
      final Uint8List file = await _write(build, 'dobre hasło 1');
      expect(ascii.decode(file.sublist(0, 8)), kAccountBackupMagic);
      final Map<String, Uint8List> got = <String, Uint8List>{};
      final ({AccountArchive? archive, AccountBackupError? error}) r =
          await _read(file, 'dobre hasło 1', into: got);
      expect(r.error, isNull);
      expect(r.archive!.account, 'acc-1');
      expect(r.archive!.seed, build.archive.seed);
      expect(r.archive!.scope, kAllAccountScopes);
      expect(r.archive!.chats.keys, build.archive.chats.keys);
      expect(got.keys.toSet(), build.archive.files.keys.toSet());
      for (final MapEntry<String, Uint8List> e in got.entries) {
        expect(e.value, await _all(build.blobs[e.key]!));
      }
    });

    test('a wrong password is told apart from a damaged file', () async {
      final Uint8List file = await _write(build, 'dobre hasło 1');
      expect(
        (await _read(file, 'złe hasło')).error,
        AccountBackupError.password,
      );
      final Uint8List cut = file.sublist(0, file.length - 40);
      expect(
        (await _read(cut, 'dobre hasło 1')).error,
        AccountBackupError.format,
      );
      final Uint8List changed = Uint8List.fromList(file);
      changed[changed.length - 100] ^= 1;
      expect(
        (await _read(changed, 'dobre hasło 1')).error,
        AccountBackupError.format,
      );
      expect(
        (await _read(
          Uint8List.fromList(utf8.encode('to nie kopia')),
          'x',
        )).error,
        AccountBackupError.format,
      );
    });

    test('a copy from a newer Zen says so instead of "damaged"', () async {
      final Uint8List file = await _write(build, 'dobre hasło 1');
      // `ZENACCT2`: a newer layout.
      final Uint8List newer = Uint8List.fromList(file)..[7] = 0x32;
      expect(
        (await _read(newer, 'dobre hasło 1')).error,
        AccountBackupError.newer,
      );
      // A password cost this build does not know (only a newer one picks
      // it): never tried, reported as newer.
      final Uint8List costlier = Uint8List.fromList(file)..[12] = 99;
      expect(
        (await _read(costlier, 'dobre hasło 1')).error,
        AccountBackupError.newer,
      );
    });

    test('a large copy is written in parts and read back from any of '
        'them', () async {
      final Directory dir = Directory.systemTemp.createTempSync('zen-bk-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String first = '${dir.path}/kopia.$kAccountBackupExtension';
      final List<String> paths = await writeAccountBackup(
        build: build,
        password: 'dobre hasło 1',
        first: first,
        partBytes: 100 * 1024,
        cost: _light,
        remember: false,
      );
      expect(paths.length, greaterThan(2));
      expect(paths.first, first);
      expect(paths[1], '$first.2');
      expect(await accountBackupParts(paths[1]), paths);

      final ({AccountArchive? archive, AccountBackupError? error}) r =
          await AccountBackupFile.read(
            chunks: readAccountBackupParts(await accountBackupParts(first)),
            password: 'dobre hasło 1',
            acceptedCosts: _accepted,
            file: (String id, int size) async => _Collect((_) {}),
          );
      expect(r.error, isNull);
      expect(r.archive!.files, build.archive.files);

      // Without its last part the copy does not open.
      File(paths.last).deleteSync();
      final ({AccountArchive? archive, AccountBackupError? error}) short =
          await AccountBackupFile.read(
            chunks: readAccountBackupParts(await accountBackupParts(first)),
            password: 'dobre hasło 1',
            acceptedCosts: _accepted,
            file: (String id, int size) async => _Collect((_) {}),
          );
      expect(short.error, AccountBackupError.format);

      // A new copy under the same name in one part: the old parts go, or
      // they would be read after it.
      final List<String> again = await writeAccountBackup(
        build: build,
        password: 'dobre hasło 1',
        first: first,
        cost: _light,
        remember: false,
      );
      expect(again, <String>[first]);
      expect(await accountBackupParts(first), <String>[first]);
      expect(File('$first.2').existsSync(), isFalse);
    });
  });

  group('taking a copy in', () {
    late AccountArchiveBuild build;
    late Directory dir;
    late List<String> paths;

    setUp(() async {
      final _Source source = _Source();
      await source.fill();
      build = await buildAccountArchive(source, kAllAccountScopes, at: 5);
      dir = Directory.systemTemp.createTempSync('zen-in-');
      paths = await writeAccountBackup(
        build: build,
        password: 'dobre hasło 1',
        first: '${dir.path}/k.$kAccountBackupExtension',
        cost: _light,
        remember: false,
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<AccountBackupRestore> restore(
      AccountArchiveImporter importer, {
      String password = 'dobre hasło 1',
    }) => restoreAccountBackup(
      paths: paths,
      password: password,
      importer: importer,
      acceptedCosts: _accepted,
    );

    test('a new device becomes the account, then takes the rest in', () async {
      final _Sink sink = _Sink(account: 'fresh-1');
      final AccountArchiveImporter importer = AccountArchiveImporter(
        sink: sink,
        staging: AccountImportStaging(sink.disk),
      );
      final AccountBackupRestore r = await restore(importer);
      expect(r.error, isNull);
      expect(r.outcome, AccountImportOutcome.restarting);
      expect(sink.calls, <String>['stop', 'adopt', 'restart']);
      // The stored states and the whole log, as they were.
      for (final MapEntry<String, String> e in build.archive.raw.entries) {
        expect(
          await sink.disk.read(e.key),
          await _all(build.blobs[e.value]!),
          reason: e.key,
        );
      }
      // After the restart: the rest, then nothing waits any more.
      final AccountImportSummary? summary = await importer.resume();
      expect(summary, isNotNull);
      expect(sink.appliedMerge, isFalse);
      expect(sink.applied!.seed, isNull, reason: 'the key is not kept twice');
      expect(sink.appliedFiles.keys.toSet(), build.archive.files.keys.toSet());
      expect(summary!.messages, build.archive.messageCount);
      expect(await importer.resume(), isNull);
      expect(
        sink.disk.files.keys.where(
          (String k) => k.startsWith('account/import'),
        ),
        isEmpty,
      );
    });

    test('the same account merges: what is here stays, the log is not '
        'replaced', () async {
      final _Sink sink = _Sink(account: 'acc-1', fresh: false);
      await sink.disk.write('films/state', _json(<String, Object>{'mine': 1}));
      await sink.disk.write(LedgerArchive.indexKey, _json(<String, Object>{}));
      final AccountArchiveImporter importer = AccountArchiveImporter(
        sink: sink,
        staging: AccountImportStaging(sink.disk),
      );
      final AccountBackupRestore r = await restore(importer);
      expect(r.outcome, AccountImportOutcome.done);
      expect(sink.calls, <String>['apply', 'stop', 'restart']);
      expect(sink.appliedMerge, isTrue);
      expect(
        jsonDecode(utf8.decode((await sink.disk.read('films/state'))!)),
        <String, Object>{'mine': 1},
      );
      expect(await sink.disk.read('pyramid/ledger'), isNotNull);
      expect(
        jsonDecode(
          utf8.decode((await sink.disk.read(LedgerArchive.indexKey))!),
        ),
        <String, Object>{},
      );
      final AccountImportSummary? shown = await importer.staging.takeSummary();
      expect(shown!.messages, build.archive.messageCount);
      expect(await importer.staging.takeSummary(), isNull);
    });

    test('another account is refused on a device with its own data, before '
        'its files are read', () async {
      final _Sink sink = _Sink(account: 'other', fresh: false);
      final AccountArchiveImporter importer = AccountArchiveImporter(
        sink: sink,
        staging: AccountImportStaging(sink.disk),
      );
      final AccountBackupRestore r = await restore(importer);
      expect(r.outcome, AccountImportOutcome.otherAccount);
      expect(sink.calls, isEmpty);
      expect(sink.disk.files, isEmpty);
    });

    test('a wrong password changes nothing', () async {
      final _Sink sink = _Sink(account: 'fresh-1');
      final AccountArchiveImporter importer = AccountArchiveImporter(
        sink: sink,
        staging: AccountImportStaging(sink.disk),
      );
      final AccountBackupRestore r = await restore(importer, password: 'złe');
      expect(r.error, AccountBackupError.password);
      expect(sink.calls, isEmpty);
      expect(sink.disk.files, isEmpty);
    });

    test('a copy without the key is refused for another account', () async {
      final _Sink sink = _Sink(account: 'fresh-1');
      final AccountArchiveImporter importer = AccountArchiveImporter(
        sink: sink,
        staging: AccountImportStaging(sink.disk),
      );
      expect(
        await importer.take(build.archive.withoutSeed()),
        AccountImportOutcome.noKey,
      );
      expect(sink.calls, isEmpty);
    });
  });

  group('staging', () {
    test('files wait block by block and are checked whole', () async {
      final AccountImportStaging staging = AccountImportStaging(
        MemoryLedgerDisk(),
      );
      final Uint8List big = _bytes(kAccountCopyBlockBytes * 2 + 17, 9);
      final String id = accountBlobId(big);
      expect(accountBlockCount(big.length), 3);
      expect(accountBlockCount(0), 1);
      await staging.putBlock(
        id,
        0,
        Uint8List.sublistView(big, 0, kAccountCopyBlockBytes),
      );
      expect(await staging.hasBlock(id, 0), isTrue);
      expect(await staging.read(id, big.length), isNull);
      await staging.put(id, big);
      expect(await staging.read(id, big.length), big);
      await staging.putBlock(id, 2, Uint8List.fromList(<int>[1, 2, 3]));
      expect(await staging.read(id, big.length), isNull, reason: 'damaged');
      final Uint8List empty = Uint8List(0);
      await staging.put(accountBlobId(empty), empty);
      expect(await staging.read(accountBlobId(empty), 0), empty);
    });
  });

  test('a large file goes through in pieces: memory stays bounded', () async {
    final _Source source = _Source();
    // 5 MB: twenty times a piece, five frames.
    source.files['/media/film.mp4'] = _bytes(5 * 1024 * 1024 + 123, 7);
    source.chats['200::1']!.add(
      const ChatMessage(
        id: 'film',
        sender: 'me',
        text: '',
        sentAtMillis: 50,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.video,
        attachmentPath: '/media/film.mp4',
      ),
    );
    final AccountArchiveBuild build = await buildAccountArchive(
      source,
      kAllAccountScopes,
      at: 1,
    );
    expect(source.ranges, isNotEmpty);
    expect(source.ranges, everyElement(lessThanOrEqualTo(kAccountStreamChunk)));
    source.ranges.clear();

    // Written: every out() call at most one frame and its tag.
    final List<int> written = <int>[];
    final BytesBuilder file = BytesBuilder(copy: false);
    await AccountBackupFile.write(
      archive: build.archive,
      blobs: build.blobs,
      password: 'dobre hasło 1',
      cost: _light,
      out: (Uint8List bytes) async {
        written.add(bytes.length);
        file.add(bytes);
      },
    );
    expect(
      written,
      everyElement(lessThanOrEqualTo(kAccountBackupFrameBytes + 16)),
    );
    expect(source.ranges, everyElement(lessThanOrEqualTo(kAccountStreamChunk)));

    // Read: the film comes to its writer piece by piece.
    final Uint8List bytes = file.takeBytes();
    final Map<String, _Collect> writers = <String, _Collect>{};
    final ({AccountArchive? archive, AccountBackupError? error}) r =
        await AccountBackupFile.read(
          chunks: Stream<List<int>>.fromIterable(<List<int>>[
            for (int at = 0; at < bytes.length; at += 300000)
              Uint8List.sublistView(
                bytes,
                at,
                (at + 300000).clamp(0, bytes.length),
              ),
          ]),
          password: 'dobre hasło 1',
          acceptedCosts: _accepted,
          file: (String id, int size) async =>
              writers[id] = _Collect((Uint8List _) {}),
        );
    expect(r.error, isNull);
    final String film =
        r.archive!.chats['200::1']!.firstWhere(
              (Map<String, dynamic> m) => m['id'] == 'film',
            )['af']
            as String;
    expect(writers[film]!.pieces.length, greaterThan(10));
    expect(
      writers[film]!.pieces,
      everyElement(lessThanOrEqualTo(kAccountStreamChunk)),
    );

    // Staged block by block, read back as a blob range by range.
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final AccountImportStaging staging = AccountImportStaging(disk);
    final AccountFileWriter w = staging.writer(film);
    await for (final Uint8List part in build.blobs[film]!.chunks()) {
      await w.add(part);
    }
    await w.close();
    expect(
      disk.files.values.map((Uint8List b) => b.length),
      everyElement(lessThanOrEqualTo(kAccountCopyBlockBytes)),
    );
    final int size = build.archive.files[film]!;
    expect(await staging.has(film, size), isTrue);
    expect(await accountBlobIdOf(staging.blob(film, size)), film);
  });
}
