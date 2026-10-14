import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';

String _b64(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

/// Whether [path] shows the friend's address (file names are folded to
/// lower case on Windows).
bool _showsAda(String path) =>
    path.toLowerCase().contains(_b64(_ada).toLowerCase());

const ChatMessage _hello = ChatMessage(
  id: 'm-1',
  sender: _ada,
  text: 'Hej',
  sentAtMillis: 1,
  direction: ChatMessageDirection.incoming,
);

void main() {
  late Directory root;
  late MemoryAppSecurityService security;
  late EncryptedBinaryPayloadProtector protector;
  final BinaryCodec codec = BinaryCodec(compressor: const _PassThrough());

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-hidden-names-');
    security = MemoryAppSecurityService(passwordIterations: 10);
    protector = EncryptedBinaryPayloadProtector(security);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  /// Every path under the store, files and folders.
  List<String> onDisk() => <String>[
    for (final FileSystemEntity e in root.listSync(recursive: true))
      e.path.substring(root.path.length),
  ];

  FileBinaryStore current() =>
      FileBinaryStore(root, codec: codec, protector: protector);

  void expectNoAddressOnDisk() {
    for (final String path in onDisk()) {
      expect(_showsAda(path), isFalse, reason: path);
      expect(path.toLowerCase(), isNot(contains('%3a')));
    }
  }

  test('a thread is stored under a keyed hash, not under the '
      'address', () async {
    final FileMessageTimelineStore threads = FileMessageTimelineStore(
      store: current(),
    );
    await threads.save(_ada, const <ChatMessage>[_hello]);

    expectNoAddressOnDisk();
    final String hidden =
        '${Platform.pathSeparator}$kHiddenNamesFolder${Platform.pathSeparator}';
    expect(onDisk().where((String p) => p.contains(hidden)), isNotEmpty);
    expect((await threads.load(_ada)).single.text, 'Hej');

    // Another data key (another install) gives other names.
    final MemoryAppSecurityService other = MemoryAppSecurityService(
      passwordIterations: 10,
      encryptionKey: Uint8List.fromList(List<int>.filled(32, 9)),
    );
    final FileBinaryStore otherStore = FileBinaryStore(
      root,
      codec: codec,
      protector: EncryptedBinaryPayloadProtector(other),
    );
    expect(
      await FileMessageTimelineStore(store: otherStore).load(_ada),
      isEmpty,
    );
  });

  test(
    'unfinished transfers are listed by folder, under hidden names',
    () async {
      final FileAttachmentTransferStore transfers = FileAttachmentTransferStore(
        store: current(),
      );
      await transfers.saveIncoming(
        IncomingAttachmentTransfer(
          peerAddress: _ada,
          messageId: 'incoming-1-$_ada',
          text: 'Plik',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          transferBytes: 2,
          chunkCount: 1,
          receivedChunks: <int, Uint8List>{
            0: Uint8List.fromList(<int>[1, 2]),
          },
        ),
      );
      await transfers.saveOutgoing(
        OutgoingAttachmentTransfer(
          peerAddress: _ada,
          messageId: 'outgoing-1-$_ada',
          text: 'Plik',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          attachmentBytes: Uint8List.fromList(<int>[3]),
        ),
      );

      expectNoAddressOnDisk();
      expect(await transfers.countIncoming(_ada), 1);
      expect(await transfers.countIncoming('200::1'), 0);
      expect(
        (await transfers.loadIncoming(
          _ada,
          'incoming-1-$_ada',
        ))!.assembleBytes(),
        <int>[1, 2],
      );
      final List<OutgoingAttachmentTransfer> outgoing = await transfers
          .loadAllOutgoing();
      expect(outgoing.single.messageId, 'outgoing-1-$_ada');
      expect(
        await transfers.deleteStaleIncoming(
          olderThanMillis: DateTime.now().millisecondsSinceEpoch + 60000,
        ),
        1,
      );
      expect(await transfers.countIncoming(_ada), 0);
    },
  );

  test('a locked store neither reads nor writes hidden keys', () async {
    final MemoryAppSecurityService locked = MemoryAppSecurityService(
      passwordIterations: 10,
      hasPassword: true,
      locked: true,
    );
    final FileBinaryStore store = FileBinaryStore(
      root,
      codec: codec,
      protector: EncryptedBinaryPayloadProtector(locked),
    );
    await expectLater(store.read('threads/${_b64(_ada)}'), throwsStateError);
    await expectLater(
      store.write('threads/${_b64(_ada)}', Uint8List.fromList(<int>[1])),
      throwsStateError,
    );
    expect(onDisk(), isEmpty);
  });

  test('a sealed file copied over another key does not open there', () async {
    final FileBinaryStore store = current();
    final Uint8List hub = Uint8List.fromList(<int>[1, 1, 1]);
    final File hubFile = await store.write('social/hub', hub);
    final File queueFile = await store.write(
      'signals/pending',
      Uint8List.fromList(<int>[2, 2, 2]),
    );

    await hubFile.copy(queueFile.path);

    await expectLater(store.read('signals/pending'), throwsA(anything));
    expect(await store.read('social/hub'), hub);
  });

  test('plaintext and files sealed without their key are never taken: '
      'they read as missing', () async {
    // Planted in plain form (no key needed to write it).
    await FileBinaryStore(
      root,
      codec: codec,
    ).write('pyramid/ring-ok', Uint8List.fromList(<int>[8, 9]));
    expect(await current().read('pyramid/ring-ok'), isNull);

    // Sealed the older way, without the storage key.
    final File hub = await current().write(
      'social/hub',
      Uint8List.fromList(<int>[1]),
    );
    final Uint8List key = (await security.currentEncryptionKey())!;
    await hub.writeAsBytes(<int>[
      ...utf8.encode('ZENENC1'),
      ...await encryptSecurityBytes(
        await codec.encode(Uint8List.fromList(<int>[5, 6, 7])),
        key,
      ),
    ]);
    final File backup = File('${hub.path}.bak');
    if (backup.existsSync()) {
      backup.deleteSync();
    }
    expect(await current().read('social/hub'), isNull);

    // Written again, it opens.
    await current().write('social/hub', Uint8List.fromList(<int>[4]));
    expect(await current().read('social/hub'), Uint8List.fromList(<int>[4]));
  });
}

final class _PassThrough implements BinaryCompressor {
  const _PassThrough();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
