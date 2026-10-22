import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/media/media_vault.dart';

Uint8List _bytes(int length) {
  final Uint8List out = Uint8List(length);
  for (int i = 0; i < length; i++) {
    out[i] = (i * 31) % 251;
  }
  return out;
}

void main() {
  late Directory root;
  late Directory support;
  late Directory temporary;
  Uint8List? masterKey;

  MediaVault vault() => MediaVault(
    masterKey: () async => masterKey,
    supportDirectory: () async => support,
    temporaryDirectory: () async => temporary,
  );

  // The app's real store: it refuses one entry above 20 MiB.
  LedgerDisk fileDisk() => FileLedgerDisk(
    FileBinaryStore(
      Directory('${root.path}${Platform.pathSeparator}data'),
      codec: BinaryCodec(compressor: const _PassThroughCompressor()),
    ),
  );

  File plain(String name, Uint8List bytes) =>
      File('${temporary.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  List<FileSystemEntity> vaultFiles() {
    final Directory folder = Directory(
      '${support.path}${Platform.pathSeparator}$kMediaVaultFolder',
    );
    return folder.existsSync() ? folder.listSync() : const <FileSystemEntity>[];
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-recordings-');
    support = Directory('${root.path}${Platform.pathSeparator}support')
      ..createSync();
    temporary = Directory('${root.path}${Platform.pathSeparator}tmp')
      ..createSync();
    masterKey = Uint8List.fromList(List<int>.generate(32, (int i) => i + 9));
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('a recording above the store limit is kept whole, encrypted', () async {
    final LedgerDisk disk = fileDisk();
    final int size = BinaryCodec.defaultMaxPayloadBytes + 1024 * 1024 + 123;
    final Uint8List recording = _bytes(size);
    // The store itself takes no entry this big: the recording must not
    // go there in one piece.
    await expectLater(
      disk.write('recordings/too-big', recording),
      throwsFormatException,
    );
    final File source = plain('zen_rec_1.wav', recording);
    final CallRecordingKeeper keeper = CallRecordingKeeper(
      CallRecordingStore(disk, vault()),
    );
    addTearDown(keeper.dispose);

    final CallRecordingOutcome outcome = await keeper.keep(
      path: source.path,
      mime: 'audio/wav',
      label: 'Przychodnia',
      millis: 5,
    );

    expect(outcome, CallRecordingOutcome.saved);
    expect(source.existsSync(), isFalse);
    expect(keeper.unsaved, isEmpty);
    // Read back through a fresh disk and vault, as after a restart.
    final CallRecordingStore again = CallRecordingStore(fileDisk(), vault());
    final CallRecording rec = (await again.list()).single;
    expect(rec.peer, 'Przychodnia');
    expect(rec.bytes, size);
    expect(rec.extension, 'wav');
    final File out = File('${root.path}${Platform.pathSeparator}out.wav');
    await again.exportTo(rec, out);
    expect(await out.length(), size);
    expect(await out.readAsBytes(), recording);
    // What lies in the vault is not the recording.
    final File sealed = File(await again.pathOf(rec));
    expect(sealed.lengthSync(), greaterThan(size));
    final RandomAccessFile head = sealed.openSync();
    try {
      expect(
        head.readSync(4096),
        isNot(Uint8List.sublistView(recording, 0, 4096)),
      );
    } finally {
      head.closeSync();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'a recording that cannot be stored stays and can be tried again',
    () async {
      final LedgerDisk disk = fileDisk();
      final Uint8List recording = _bytes(200000);
      final File source = plain('zen_rec_2.m4a', recording);
      final CallRecordingKeeper keeper = CallRecordingKeeper(
        CallRecordingStore(disk, vault()),
      );
      addTearDown(keeper.dispose);
      int changes = 0;
      keeper.addListener(() => changes++);

      // Locked: no data key, so nothing can be encrypted.
      masterKey = null;
      expect(
        await keeper.keep(
          path: source.path,
          mime: 'audio/mp4',
          label: 'Ola',
          millis: 7,
        ),
        CallRecordingOutcome.failed,
      );
      expect(source.readAsBytesSync(), recording);
      expect(keeper.unsaved.single.path, source.path);
      expect(changes, 1);
      expect(await CallRecordingStore(disk, vault()).list(), isEmpty);
      expect(vaultFiles(), isEmpty);
      // Still failing: listed once.
      expect(await keeper.retry(), isFalse);
      expect(keeper.unsaved, hasLength(1));

      masterKey = Uint8List.fromList(List<int>.generate(32, (int i) => i + 9));
      expect(await keeper.retry(), isTrue);
      expect(keeper.unsaved, isEmpty);
      expect(changes, 2);
      expect(source.existsSync(), isFalse);
      final CallRecording rec = (await CallRecordingStore(
        disk,
        vault(),
      ).list()).single;
      expect(rec.peer, 'Ola');
      expect(rec.millis, 7);
      expect(rec.isAudioOnly, isTrue);
    },
  );

  test(
    'a failed index write leaves the plain file and no vault file',
    () async {
      final File source = plain('zen_rec_3.wav', _bytes(5000));
      final CallRecordingStore store = CallRecordingStore(
        _BrokenDisk(),
        vault(),
      );
      await expectLater(
        keepCallRecording(
          store,
          path: source.path,
          mime: 'audio/wav',
          label: 'x',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(source.existsSync(), isTrue);
      expect(vaultFiles(), isEmpty);
    },
  );

  test('giving up deletes the plain files', () async {
    final File source = plain('zen_rec_4.wav', _bytes(10));
    final CallRecordingKeeper keeper = CallRecordingKeeper(
      CallRecordingStore(MemoryLedgerDisk(), vault()),
    );
    addTearDown(keeper.dispose);
    masterKey = null;
    await keeper.keep(path: source.path, mime: 'audio/wav', label: 'x');
    expect(keeper.unsaved, hasLength(1));
    await keeper.discard();
    expect(keeper.unsaved, isEmpty);
    expect(source.existsSync(), isFalse);
  });

  test('nothing recorded: nothing kept, an empty file goes', () async {
    final CallRecordingKeeper keeper = CallRecordingKeeper(
      CallRecordingStore(MemoryLedgerDisk(), vault()),
    );
    addTearDown(keeper.dispose);
    expect(
      await keeper.keep(
        path: '${temporary.path}${Platform.pathSeparator}missing.wav',
        mime: 'audio/wav',
        label: 'x',
      ),
      CallRecordingOutcome.empty,
    );
    final File empty = plain('zen_rec_5.wav', Uint8List(0));
    expect(
      await keeper.keep(path: empty.path, mime: 'audio/wav', label: 'x'),
      CallRecordingOutcome.empty,
    );
    expect(empty.existsSync(), isFalse);
    expect(keeper.unsaved, isEmpty);
  });

  test('recordings are listed newest first, played and deleted', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final CallRecordingStore store = CallRecordingStore(disk, vault());
    expect(await store.list(), isEmpty);

    await store.addFile(
      peer: 'Ada',
      source: plain('a.mp4', Uint8List.fromList(<int>[1, 2, 3])),
      millis: 1000,
    );
    final CallRecording second = await store.addFile(
      peer: 'Bob',
      source: plain('b.wav', Uint8List.fromList(<int>[4, 5])),
      millis: 2000,
      mime: 'audio/wav',
    );
    final List<CallRecording> all = await store.list();
    expect(all.map((CallRecording r) => r.peer), <String>['Bob', 'Ada']);
    expect(all.first.bytes, 2);
    // The index holds the vault file's name, not a path.
    expect(second.file, isNot(contains(Platform.pathSeparator)));
    expect(isMediaVaultPath(second.file), isTrue);

    final File copy = await store.openTemporary(second);
    expect(copy.path, startsWith(temporary.path));
    expect(copy.path, endsWith('.wav'));
    expect(copy.readAsBytesSync(), <int>[4, 5]);
    await copy.delete();

    final String sealed = await store.pathOf(second);
    await store.delete(second.id);
    expect((await store.list()).single.peer, 'Ada');
    expect(File(sealed).existsSync(), isFalse);
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}

/// A disk whose writes fail (full, or gone).
final class _BrokenDisk implements LedgerDisk {
  @override
  Future<Uint8List?> read(String key) async => null;

  @override
  Future<void> write(String key, Uint8List data) async {
    throw const FileSystemException('No space left on device');
  }

  @override
  Future<void> delete(String key) async {}
}
