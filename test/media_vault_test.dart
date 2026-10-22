import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/media/media_vault.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (int i) => (i * 7 + seed) % 256));

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => (i * 31) % 251));

void main() {
  late Directory support;
  late Directory temporary;
  Uint8List? masterKey;

  MediaVault vault() => MediaVault(
    masterKey: () async => masterKey,
    supportDirectory: () async => support,
    temporaryDirectory: () async => temporary,
  );

  setUp(() async {
    support = await Directory.systemTemp.createTemp('zen-vault-');
    temporary = await Directory.systemTemp.createTemp('zen-vault-tmp-');
    masterKey = _key(1);
  });

  tearDown(() async {
    for (final Directory dir in <Directory>[support, temporary]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  test('files round-trip, of any size, under random names', () async {
    for (final int length in <int>[0, 1, 65536, 65537, 200000, 300000]) {
      final Uint8List plain = _bytes(length);
      final String path = await vault().put(plain);
      expect(isMediaVaultPath(path), isTrue);
      expect(path, startsWith('${support.path}${Platform.pathSeparator}vault'));
      expect(
        RegExp(r'[0-9a-f]{32}\.zmedia$').hasMatch(path),
        isTrue,
        reason: path,
      );
      expect(await vault().read(path), plain, reason: '$length bytes');
      expect(await vault().length(path), length);
    }
  });

  test('what is on disk is not the plain content', () async {
    final Uint8List plain = Uint8List.fromList(List<int>.filled(4096, 0x41));
    final String path = await vault().put(plain);
    final Uint8List onDisk = await File(path).readAsBytes();
    int longestRun = 0;
    int run = 0;
    for (final int byte in onDisk) {
      run = byte == 0x41 ? run + 1 : 0;
      longestRun = run > longestRun ? run : longestRun;
    }
    expect(longestRun, lessThan(8));
  });

  test('a part opens without the rest', () async {
    final Uint8List plain = _bytes(200000);
    final String path = await vault().put(plain);
    for (final (int start, int end) in <(int, int)>[
      (0, 10),
      (65530, 65546),
      (65536, 131072),
      (131000, 200000),
      (199999, 200000),
      (5, 5),
    ]) {
      expect(
        await vault().readRange(path, start, end),
        Uint8List.sublistView(plain, start, end),
        reason: '$start-$end',
      );
    }
    await expectLater(vault().readRange(path, 0, 200001), throwsRangeError);
  });

  test(
    'a file swapped, cut or opened with another key does not open',
    () async {
      final String first = await vault().put(_bytes(70000));
      final String second = await vault().put(_bytes(70000));
      // Swapped: the segments are bound to the file's own name.
      await File(first).copy(second);
      await expectLater(vault().read(second), throwsA(anything));
      // Cut short.
      final Uint8List whole = await File(first).readAsBytes();
      await File(first).writeAsBytes(whole.sublist(0, whole.length - 100));
      await expectLater(vault().read(first), throwsA(anything));
      // Another install's key.
      final String third = await vault().put(_bytes(10));
      masterKey = _key(2);
      await expectLater(vault().read(third), throwsA(anything));
    },
  );

  test('a locked vault neither stores nor opens', () async {
    final String path = await vault().put(_bytes(10));
    masterKey = null;
    await expectLater(vault().put(_bytes(10)), throwsStateError);
    await expectLater(vault().read(path), throwsStateError);
    await expectLater(vault().readRange(path, 0, 5), throwsStateError);
  });

  test('a player gets a short-lived plain copy with a random name', () async {
    final Uint8List plain = _bytes(1000);
    final String path = await vault().put(plain);
    final File copy = await vault().openTemporary(path, extension: '.m4a');
    expect(copy.path, startsWith(temporary.path));
    expect(copy.path, endsWith('.m4a'));
    expect(await copy.readAsBytes(), plain);
    // Odd extensions are dropped.
    final File other = await vault().openTemporary(path, extension: '../x');
    expect(other.path, isNot(contains('..')));
  });

  test(
    'only vault files are deleted; plain files are read as they are',
    () async {
      final File own = File('${support.path}${Platform.pathSeparator}own.bin')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      expect(await vault().read(own.path), <int>[1, 2, 3]);
      expect(await vault().length(own.path), 3);
      expect(await vault().readRange(own.path, 1, 3), <int>[2, 3]);
      await vault().delete(own.path);
      expect(own.existsSync(), isTrue);

      final String path = await vault().put(_bytes(5));
      await vault().delete(path);
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('a recording moves into the vault and its plain file goes', () async {
    final File recording = File(
      '${temporary.path}${Platform.pathSeparator}rec.m4a',
    )..writeAsBytesSync(_bytes(3000));
    final String path = await vault().putFile(recording);
    expect(recording.existsSync(), isFalse);
    expect(await vault().read(path), _bytes(3000));
  });

  test(
    'a big file goes in and out piece by piece, whatever its size',
    () async {
      for (final int length in <int>[0, 65536, 65537, 300001]) {
        final File source = File(
          '${temporary.path}${Platform.pathSeparator}src-$length.wav',
        )..writeAsBytesSync(_bytes(length));
        final String path = await vault().putFile(source, deleteSource: false);
        expect(source.existsSync(), isTrue, reason: '$length');
        expect(await vault().length(path), length);
        expect(await vault().read(path), _bytes(length), reason: '$length');
        expect(
          await vault().readRange(path, length ~/ 2, length),
          Uint8List.sublistView(_bytes(length), length ~/ 2, length),
        );
        final File out = File(
          '${temporary.path}${Platform.pathSeparator}out-$length.wav',
        );
        await vault().decryptToFile(path, out);
        expect(out.readAsBytesSync(), _bytes(length), reason: '$length');
      }
    },
  );

  test('a locked vault leaves the plain file and no half file', () async {
    final File source = File(
      '${temporary.path}${Platform.pathSeparator}locked.wav',
    )..writeAsBytesSync(_bytes(100000));
    masterKey = null;
    await expectLater(vault().putFile(source), throwsStateError);
    expect(source.existsSync(), isTrue);
    final Directory folder = Directory(
      '${support.path}${Platform.pathSeparator}$kMediaVaultFolder',
    );
    expect(folder.existsSync() ? folder.listSync() : <Object>[], isEmpty);
  });

  test('a damaged file is not written out in plain form', () async {
    final String path = await vault().put(_bytes(200000));
    final Uint8List sealed = await File(path).readAsBytes();
    sealed[sealed.length - 10] ^= 0xFF;
    await File(path).writeAsBytes(sealed);
    final File out = File('${temporary.path}${Platform.pathSeparator}bad.m4a');
    await expectLater(vault().decryptToFile(path, out), throwsA(anything));
    expect(out.existsSync(), isFalse);
  });

  test('an index keeps a name that finds the file again', () async {
    final String path = await vault().put(_bytes(10));
    final String name = MediaVault.fileNameOf(path);
    expect(name, isNot(contains(Platform.pathSeparator)));
    expect(await vault().pathOf(name), path);
    await expectLater(vault().pathOf('../x.zmedia'), throwsFormatException);
  });

  test(
    'an outgoing transfer reads its chunks from an encrypted file',
    () async {
      final Uint8List plain = _bytes(kAttachmentChunkSizeBytes * 2 + 100);
      final String path = await vault().put(plain);
      final OutgoingAttachmentTransfer transfer = OutgoingAttachmentTransfer(
        peerAddress: '200::1',
        messageId: 'm-1',
        text: 'Nagranie',
        sentAtMillis: 1,
        type: ChatMessageType.voice,
        attachmentPath: path,
        attachmentSizeBytes: plain.length,
      );
      expect(transfer.chunkCount, 3);
      final BytesBuilder joined = BytesBuilder();
      for (int index = 0; index < transfer.chunkCount; index++) {
        joined.add(await transfer.chunkAt(index, vault: vault()));
      }
      expect(joined.takeBytes(), plain);
    },
  );
}
