import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/core/storage/binary_store.dart';

import 'support/damaged_files.dart';

/// A save killed at any moment, or two isolates saving the same file at
/// once (the Android app and its background service share one process),
/// never leave a key empty or half-written: a read always finds the old or
/// the new complete payload, and a damaged file never pushes the last good
/// copy out.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-crash-');
  });

  tearDown(() async {
    FileBinaryStore.debugWriteStep = null;
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer.
    }
  });

  Uint8List payload(String text) => Uint8List.fromList(utf8.encode(text));
  String? text(Uint8List? bytes) => bytes == null ? null : utf8.decode(bytes);

  /// Saves [value] under [key] in a store that dies at [step]: what the
  /// files hold afterwards is what a process killed there leaves.
  Future<void> killedAt(
    String step,
    String key,
    String value, {
    void Function(File file)? before,
  }) async {
    FileBinaryStore.debugWriteStep = (String at, File file) {
      if (at == step) {
        before?.call(file);
        throw const _Killed();
      }
    };
    try {
      await sealedStore(root).write(key, payload(value));
      fail('the save was not stopped at "$step"');
    } on _Killed {
      // The process is gone.
    } finally {
      FileBinaryStore.debugWriteStep = null;
    }
  }

  for (final String step in FileBinaryStore.writeSteps) {
    test(
      'killed at "$step": the old or the new payload, never nothing',
      () async {
        await sealedStore(root).write('social/hub', payload('one'));
        await sealedStore(root).write('social/hub', payload('two'));
        await killedAt(step, 'social/hub', 'three');

        // A new process.
        final FileBinaryStore store = sealedStore(root);
        expect(<String>[
          'two',
          'three',
        ], contains(text(await store.read('social/hub'))));
        await store.write('social/hub', payload('four'));
        expect(text(await sealedStore(root).read('social/hub')), 'four');
      },
    );
  }

  test('the new file cut short at every byte while it is written: always '
      'the old payload', () async {
    await sealedStore(root).write('settings/app', payload('{"v":1,"a":1}'));
    final int length = (await File(
      (await sealedStore(
        root,
      ).write('settings/app', payload('{"v":1,"a":1}'))).path,
    ).length());
    for (int cut = 0; cut < length; cut++) {
      await killedAt(
        FileBinaryStore.writeSteps.first,
        'settings/app',
        '{"v":1,"a":2}',
        before: (File temporary) {
          final Uint8List bytes = temporary.readAsBytesSync();
          temporary.writeAsBytesSync(bytes.sublist(0, cut));
        },
      );
      expect(
        text(await sealedStore(root).read('settings/app')),
        '{"v":1,"a":1}',
        reason: 'cut at $cut of $length',
      );
    }
  });

  test('the file damaged at every byte: the backup reads, and the next save '
      'keeps it instead of the damaged file', () async {
    final FileBinaryStore first = sealedStore(root);
    await first.write('ledger/identity', payload('account one'));
    final File file = await first.write(
      'ledger/identity',
      payload('account two'),
    );
    final Uint8List good = file.readAsBytesSync();
    for (int at = 0; at < good.length; at++) {
      final Uint8List damaged = Uint8List.fromList(good);
      damaged[at] ^= 0x40;
      file.writeAsBytesSync(damaged);
      expect(
        text(await sealedStore(root).read('ledger/identity')),
        'account one',
        reason: 'byte $at changed',
      );
    }
    // The next save in that process: the damaged file is set aside, the
    // good backup stays the backup.
    final FileBinaryStore store = sealedStore(root);
    expect(text(await store.read('ledger/identity')), 'account one');
    final File saved = await store.write(
      'ledger/identity',
      payload('account one, device two'),
    );
    saved.writeAsBytesSync(const <int>[1, 2, 3]);
    expect(
      text(await sealedStore(root).read('ledger/identity')),
      'account one',
    );
  });

  test('a small file keeps two earlier generations', () async {
    final FileBinaryStore store = sealedStore(root);
    await store.write('ledger/keys', payload('k1'));
    await store.write('ledger/keys', payload('k2'));
    final File file = await store.write('ledger/keys', payload('k3'));
    file.writeAsBytesSync(const <int>[0]);
    File('${file.path}.bak').writeAsBytesSync(const <int>[0]);
    expect(text(await sealedStore(root).read('ledger/keys')), 'k1');
  });

  test(
    'two stores of one isolate saving at once leave every copy whole',
    () async {
      final List<FileBinaryStore> stores = <FileBinaryStore>[
        _plainStore(root),
        _plainStore(root),
      ];
      await Future.wait(<Future<void>>[
        for (int i = 0; i < 40; i++)
          stores[i % 2].write('relay/state', payload('state $i')),
      ]);
      await _expectWholeCopies(
        root,
        _plainStore(root),
        'relay/state',
        'state ',
      );
    },
  );

  test('two isolates saving the same file at once (the app and its '
      'service) leave every copy whole', () async {
    final String path = root.path;
    Future<void> writer(String who) => Isolate.run(() async {
      final FileBinaryStore store = _plainStore(Directory(path));
      for (int i = 0; i < 60; i++) {
        await store.write(
          'social/hub',
          Uint8List.fromList(utf8.encode('$who $i ${'x' * (i * 37)}')),
        );
      }
    });
    await Future.wait(<Future<void>>[writer('app'), writer('service')]);
    await _expectWholeCopies(root, _plainStore(root), 'social/hub', '');
    expect(
      root
          .listSync(recursive: true)
          .where((FileSystemEntity e) => e.path.endsWith('.lock')),
      isEmpty,
      reason: 'every lock given back',
    );
  });

  test('a lock nobody holds any more never holds a save up; another '
      "isolate's lock is waited for", () async {
    final FileBinaryStore store = _plainStore(root);
    final File file = await store.write('relay/state', payload('one'));
    final File lock = File('${file.path}.lock');
    final File kept = File('${file.path}.kept');
    // The folder put back from a copy taken while this isolate saved (a
    // device killed then starts from it; a release Windows refused leaves
    // the same): the lock in it is this isolate's own.
    FileBinaryStore.debugWriteStep = (String step, File temporary) {
      if (step == FileBinaryStore.writeSteps.first) {
        lock.copySync(kept.path);
      }
    };
    await store.write('relay/state', payload('two'));
    FileBinaryStore.debugWriteStep = null;
    kept.renameSync(lock.path);
    Future<Duration> timedSave(String value) async {
      final Stopwatch took = Stopwatch()..start();
      await _plainStore(root).write('relay/state', payload(value));
      return took.elapsed;
    }

    expect(await timedSave('three'), lessThan(const Duration(seconds: 2)));
    // Of a process that is gone.
    lock.writeAsStringSync('1 gone');
    expect(await timedSave('four'), lessThan(const Duration(seconds: 2)));
    // Made, but its owner died before it wrote its name.
    lock.writeAsStringSync('');
    lock.setLastModifiedSync(
      DateTime.now().subtract(const Duration(seconds: 5)),
    );
    expect(await timedSave('five'), lessThan(const Duration(seconds: 2)));
    expect(lock.existsSync(), isFalse);

    // Another isolate of this process saving now (the app and its
    // service): the save waits until it is done.
    lock.writeAsStringSync('$pid service');
    bool saved = false;
    final Future<void> save = _plainStore(
      root,
    ).write('relay/state', payload('six')).then((_) => saved = true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(saved, isFalse);
    lock.deleteSync();
    await save;
    expect(text(await _plainStore(root).read('relay/state')), 'six');
  });

  test('plain files saved by two isolates at once are always one whole '
      'save (the update check, the language, the background kits)', () async {
    final String path = '${root.path}${Platform.pathSeparator}update.json';
    Future<void> writer(String who) => Isolate.run(() async {
      for (int i = 0; i < 80; i++) {
        await writeFileAtomically(
          File(path),
          utf8.encode(jsonEncode(<String, Object>{'who': who, 'pad': 'x' * i})),
        );
      }
    });
    final Future<void> both = Future.wait(<Future<void>>[
      writer('app'),
      writer('service'),
    ]);
    // Read while they write: never half a document.
    bool writing = true;
    final Future<void> reads = () async {
      while (writing) {
        try {
          final String content = File(path).readAsStringSync();
          expect(jsonDecode(content), isA<Map<String, dynamic>>());
        } on FileSystemException {
          // Not there yet, or being moved (Windows).
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }();
    await both;
    writing = false;
    await reads;
    expect(
      jsonDecode(File(path).readAsStringSync()),
      isA<Map<String, dynamic>>(),
    );
    expect(
      root.listSync().where((FileSystemEntity e) => e.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}

/// [key] reads, and every copy of it on disk (the file and each earlier
/// generation) is whole: a payload that was saved, starting with
/// [prefix]. The stores here are not sealed, so each copy opens alone.
Future<void> _expectWholeCopies(
  Directory root,
  FileBinaryStore store,
  String key,
  String prefix,
) async {
  final Uint8List? current = await store.read(key);
  expect(current, isNotNull);
  expect(utf8.decode(current!), startsWith(prefix));
  final BinaryCodec codec = BinaryCodec(compressor: const _PassThrough());
  final List<File> copies = <File>[
    for (final FileSystemEntity e in root.listSync(recursive: true))
      if (e is File && RegExp(r'\.zenbin(\.bak2?)?$').hasMatch(e.path)) e,
  ];
  expect(copies, isNotEmpty);
  for (final File copy in copies) {
    final Uint8List read = await codec.decode(copy.readAsBytesSync());
    expect(utf8.decode(read), startsWith(prefix), reason: copy.path);
  }
  expect(
    root
        .listSync(recursive: true)
        .where((FileSystemEntity e) => e.path.contains('.damaged-')),
    isEmpty,
  );
}

FileBinaryStore _plainStore(Directory root) =>
    FileBinaryStore(root, codec: BinaryCodec(compressor: const _PassThrough()));

final class _PassThrough implements BinaryCompressor {
  const _PassThrough();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}

final class _Killed implements Exception {
  const _Killed();
}
