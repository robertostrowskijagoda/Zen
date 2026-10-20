import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';

void main() {
  group('FileMessageTimelineStore', () {
    test('round-trips per-peer message threads', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-timeline-store-test-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileMessageTimelineStore store = FileMessageTimelineStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );

      await store.save('ada.ygg', <ChatMessage>[
        ChatMessage(
          id: 'incoming-1',
          sender: 'ada.ygg',
          text: 'Hej!',
          sentAtMillis: 1,
          direction: ChatMessageDirection.incoming,
        ),
        ChatMessage(
          id: 'outgoing-2',
          sender: 'self',
          text: 'Jestem.',
          sentAtMillis: 2,
          direction: ChatMessageDirection.outgoing,
          deliveryState: ChatMessageDeliveryState.delivered,
          readAtMillis: 20,
        ),
        ChatMessage(
          id: 'system-3',
          sender: 'system',
          text: 'Połączenie jest gotowe.',
          sentAtMillis: 3,
          direction: ChatMessageDirection.system,
        ),
        ChatMessage(
          id: 'file-4',
          sender: 'self',
          text: '📎 raport.txt',
          sentAtMillis: 4,
          direction: ChatMessageDirection.outgoing,
          type: ChatMessageType.file,
          fileName: 'raport.txt',
          mimeType: 'text/plain',
          attachmentSizeBytes: 3,
          attachmentBytes: Uint8List.fromList(<int>[1, 2, 3]),
          attachmentPath: r'C:\Zen\raport.txt',
        ),
        const ChatMessage(
          id: 'gif-5',
          sender: 'ada.ygg',
          text: '🎞 GIF',
          sentAtMillis: 5,
          direction: ChatMessageDirection.incoming,
          type: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        const ChatMessage(
          id: 'voice-6',
          sender: 'self',
          text: '🎤 Wiadomość głosowa',
          sentAtMillis: 6,
          direction: ChatMessageDirection.outgoing,
          type: ChatMessageType.voice,
          fileName: 'voice.m4a',
          mimeType: 'audio/mp4',
          durationMs: 12345,
        ),
      ]);

      final List<ChatMessage> restored = await store.load('ada.ygg');
      expect(restored, hasLength(6));
      expect(restored.first.text, 'Hej!');
      expect(restored[1].direction, ChatMessageDirection.outgoing);
      expect(restored[1].deliveryState, ChatMessageDeliveryState.delivered);
      expect(restored[1].readAtMillis, 20);
      expect(restored[2].direction, ChatMessageDirection.system);
      expect(restored[3].type, ChatMessageType.file);
      expect(restored[3].fileName, 'raport.txt');
      expect(restored[3].attachmentBytes, <int>[1, 2, 3]);
      expect(restored[3].attachmentPath, r'C:\Zen\raport.txt');
      expect(restored[4].isGif, isTrue);
      expect(restored[5].type, ChatMessageType.voice);
      expect(restored[5].durationMs, 12345);
    });

    test('append keeps prior messages intact', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-timeline-store-append-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileMessageTimelineStore store = FileMessageTimelineStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );

      await store.append(
        'maks.ygg',
        const ChatMessage(
          id: 'first',
          sender: 'maks.ygg',
          text: 'Pierwsza wiadomość',
          sentAtMillis: 1,
          direction: ChatMessageDirection.incoming,
        ),
      );
      await store.append(
        'maks.ygg',
        const ChatMessage(
          id: 'second',
          sender: 'self',
          text: 'Odpowiedz',
          sentAtMillis: 2,
          direction: ChatMessageDirection.outgoing,
        ),
      );

      final List<ChatMessage> restored = await store.load('maks.ygg');
      expect(restored.map((ChatMessage message) => message.id), <String>[
        'first',
        'second',
      ]);
    });

    test('recovers gracefully from corrupted timeline file', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-timeline-store-corrupt-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileBinaryStore binaryStore = FileBinaryStore(
        tempDir,
        codec: BinaryCodec(compressor: const _PassThroughCompressor()),
      );
      final FileMessageTimelineStore store = FileMessageTimelineStore(
        store: binaryStore,
      );

      // Write truncated/malformed bytes
      await binaryStore.write(
        'timelines/corrupted_peer',
        Uint8List.fromList(<int>[3, 0, 0]),
      );

      final List<ChatMessage> restored = await store.load('corrupted_peer');
      expect(restored, isEmpty);
    });
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
