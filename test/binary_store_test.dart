import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  group('BinaryCodec', () {
    test('compresses and restores binary payloads with zstd level 4', () async {
      final RecordingCompressor compressor = RecordingCompressor();
      final BinaryCodec codec = BinaryCodec(compressor: compressor);
      final Uint8List payload = Uint8List.fromList(
        List<int>.generate(8192, (int index) => index % 8),
      );

      final Uint8List encoded = await codec.encode(payload);
      final Uint8List decoded = await codec.decode(encoded);

      expect(decoded, payload);
      expect(compressor.lastLevel, kZenBinaryCompressionLevel);
      expect(encoded.length, lessThan(payload.length));
    });

    test('rejects invalid binary headers', () async {
      final BinaryCodec codec = BinaryCodec();

      await expectLater(
        () => codec.decode(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        throwsFormatException,
      );
    });

    test('detects payload corruption with a checksum', () async {
      final BinaryCodec codec = BinaryCodec(compressor: RecordingCompressor());
      final Uint8List encoded = await codec.encode(
        Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );

      encoded[encoded.length - 1] ^= 0x01;

      await expectLater(() => codec.decode(encoded), throwsFormatException);
    });

    test(
      'rejects payloads above the configured limit before encoding',
      () async {
        final BinaryCodec codec = BinaryCodec(
          compressor: RecordingCompressor(),
          maxPayloadBytes: 8,
        );

        await expectLater(
          () => codec.encode(Uint8List.fromList(List<int>.filled(9, 7))),
          throwsFormatException,
        );
      },
    );

    test('an envelope of another version does not open', () async {
      final BinaryCodec codec = BinaryCodec(compressor: RecordingCompressor());
      final Uint8List encoded = await codec.encode(
        Uint8List.fromList(<int>[9, 8, 7, 6]),
      );
      encoded[4] = 1;

      await expectLater(() => codec.decode(encoded), throwsFormatException);
    });
  });

  group('FileBinaryStore', () {
    late Directory tempDirectory;
    late FileBinaryStore store;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'zen_rewrite_store',
      );
      store = FileBinaryStore(
        tempDirectory,
        codec: BinaryCodec(compressor: RecordingCompressor()),
      );
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test('writes and reads namespaced payloads', () async {
      final Uint8List payload = Uint8List.fromList(
        List<int>.generate(2048, (int index) => 65 + (index % 3)),
      );

      final File file = await store.write('state/app-shell', payload);
      final Uint8List? loaded = await store.read('state/app-shell');

      expect(
        file.path,
        endsWith('state${Platform.pathSeparator}app-shell.zenbin'),
      );
      expect(loaded, payload);
      expect(await file.readAsBytes(), isNot(equals(payload)));
    });

    test(
      'keeps store keys safe without rejecting valid peer identifiers',
      () async {
        final Uint8List payload = Uint8List.fromList(<int>[1, 2, 3]);

        final File file = await store.write(
          'threads/200:1111:2222:3333:4444:5555:6666:7777',
          payload,
        );

        expect(file.path, contains('%3a'));
        expect(
          await store.read('threads/200:1111:2222:3333:4444:5555:6666:7777'),
          payload,
        );
      },
    );

    test('a truncated payload falls back to the previous copy', () async {
      final Uint8List first = Uint8List.fromList(
        List<int>.generate(512, (int index) => index % 251),
      );
      final Uint8List second = Uint8List.fromList(
        List<int>.generate(512, (int index) => (index * 7) % 251),
      );

      await store.write('social/hub', first);
      final File file = await store.write('social/hub', second);
      expect(await store.read('social/hub'), second);

      // What a process killed mid-write used to leave behind. Reporting
      // "nothing stored" here is what empties the app and then saves that.
      await file.writeAsBytes(
        (await file.readAsBytes()).sublist(0, 8),
        flush: true,
      );

      expect(
        await store.read('social/hub'),
        first,
        reason: 'the last good copy has to survive a torn write',
      );
    });

    test('deleting a key clears its backup too', () async {
      await store.write('social/hub', Uint8List.fromList(<int>[1, 2, 3]));
      final File file = await store.write(
        'social/hub',
        Uint8List.fromList(<int>[4, 5, 6]),
      );
      expect(await File('${file.path}.bak').exists(), isTrue);

      await store.delete('social/hub');

      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.bak').exists(), isFalse);
      expect(await store.read('social/hub'), isNull);
    });

    test('rejects traversal-style keys', () async {
      await expectLater(
        store.write('../escape', Uint8List.fromList(<int>[1])),
        throwsFormatException,
      );
    });

    test('can encrypt stored payloads behind the security lock', () async {
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        passwordIterations: 10,
      );
      await security.setPassword('sekret12');
      await security.applySettings(const AppSettings(encryptionEnabled: true));
      store = FileBinaryStore(
        tempDirectory,
        codec: BinaryCodec(compressor: RecordingCompressor()),
        protector: EncryptedBinaryPayloadProtector(security),
      );
      final Uint8List payload = Uint8List.fromList(
        List<int>.generate(1024, (int index) => index % 255),
      );

      final File file = await store.write('secure/thread', payload);
      final Uint8List bytesOnDisk = Uint8List.fromList(
        await file.readAsBytes(),
      );

      // `ZENENC2`: sealed and bound to where it is stored.
      expect(
        bytesOnDisk.take(7),
        orderedEquals(<int>[90, 69, 78, 69, 78, 67, 50]),
      );
      expect(await store.read('secure/thread'), payload);

      security.lock();
      await expectLater(() => store.read('secure/thread'), throwsStateError);
    });
  });
}

final class RecordingCompressor implements BinaryCompressor {
  final Map<int, Uint8List> _payloads = <int, Uint8List>{};
  int _nextId = 1;
  int? lastLevel;

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async {
    lastLevel = level;
    final int id = _nextId++;
    _payloads[id] = payload;
    final ByteData data = ByteData(4)..setUint32(0, id, Endian.little);
    return data.buffer.asUint8List();
  }

  @override
  Future<Uint8List?> decompress(Uint8List payload) async {
    if (payload.length != 4) {
      return null;
    }
    final int id = ByteData.sublistView(payload).getUint32(0, Endian.little);
    return _payloads[id];
  }
}
