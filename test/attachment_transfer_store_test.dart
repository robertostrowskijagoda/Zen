import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';

void main() {
  test(
    'file attachment transfer store round-trips outgoing and incoming records',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-transfer-store-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileAttachmentTransferStore store = FileAttachmentTransferStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );

      await store.saveOutgoing(
        OutgoingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'file-1',
          text: '📎 raport.txt',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          fileName: 'raport.txt',
          mimeType: 'text/plain',
          attachmentSizeBytes: 5,
          attachmentBytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
          durationMs: 3210,
          placeholderSent: true,
          ackedChunkIndexes: const <int>[0],
        ),
      );
      await store.saveIncoming(
        IncomingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'file-2',
          text: '📷 Zdjęcie',
          sentAtMillis: 2,
          type: ChatMessageType.image,
          fileName: 'foto.png',
          mimeType: 'image/png',
          attachmentSizeBytes: 4,
          durationMs: 4567,
          transferBytes: 4,
          chunkCount: 2,
          receivedChunks: <int, Uint8List>{
            0: Uint8List.fromList(<int>[1, 2]),
            1: Uint8List.fromList(<int>[3, 4]),
          },
        ),
      );

      final OutgoingAttachmentTransfer? outgoing = await store.loadOutgoing(
        'ada.ygg',
        'file-1',
      );
      final IncomingAttachmentTransfer? incoming = await store.loadIncoming(
        'ada.ygg',
        'file-2',
      );
      final List<OutgoingAttachmentTransfer> allOutgoing = await store
          .loadAllOutgoing();

      expect(outgoing, isNotNull);
      expect(outgoing!.chunkCount, 1);
      expect(outgoing.attachmentBytes, <int>[1, 2, 3, 4, 5]);
      expect(outgoing.durationMs, 3210);
      expect(outgoing.placeholderSent, isTrue);
      expect(incoming, isNotNull);
      expect(incoming!.isComplete, isTrue);
      expect(incoming.assembleBytes(), <int>[1, 2, 3, 4]);
      expect(incoming.durationMs, 4567);
      expect(allOutgoing, hasLength(1));
      expect(allOutgoing.single.messageId, 'file-1');
    },
  );

  test(
    'file attachment transfer store keeps outgoing file path payloads',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-transfer-store-path-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File payload = File(
        '${tempDir.path}${Platform.pathSeparator}payload.bin',
      );
      await payload.writeAsBytes(<int>[1, 2, 3, 4, 5, 6], flush: true);

      final FileAttachmentTransferStore store = FileAttachmentTransferStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );

      await store.saveOutgoing(
        OutgoingAttachmentTransfer(
          peerAddress: 'ada.ygg',
          messageId: 'file-path-1',
          text: '📎 payload.bin',
          sentAtMillis: 1,
          type: ChatMessageType.file,
          fileName: 'payload.bin',
          mimeType: 'application/octet-stream',
          attachmentSizeBytes: 6,
          attachmentPath: payload.path,
        ),
      );

      final OutgoingAttachmentTransfer? outgoing = await store.loadOutgoing(
        'ada.ygg',
        'file-path-1',
      );

      expect(outgoing, isNotNull);
      expect(outgoing!.attachmentBytes, isNull);
      expect(outgoing.attachmentPath, payload.path);
      expect(await outgoing.chunkAt(0), <int>[1, 2, 3, 4, 5, 6]);
    },
  );
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
