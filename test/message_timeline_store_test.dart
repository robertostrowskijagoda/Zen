import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
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

    test(
      'a group file\'s reference is stored with its known fields only: '
      'a number JSON cannot write (1e400) does not lose the message',
      () async {
        final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
          MemoryLedgerDisk(),
        );
        ChatMessage photo(String id, String media) => ChatMessage(
          id: id,
          sender: '200::2',
          text: 'zdjecie',
          sentAtMillis: 1,
          direction: ChatMessageDirection.incoming,
          type: ChatMessageType.image,
          pendingMedia: <String, dynamic>{
            ...jsonDecode(media) as Map<String, dynamic>,
            'src': '200::2',
          },
        );
        await store.append('group:g', photo('m1', '{"h":"abc","n":1e400}'));
        await store.append(
          'group:g',
          photo('m2', '{"id":"blk","k":"K","n":-1e400,"ms":1e400,"x":[1e400]}'),
        );
        final List<ChatMessage> kept = await FileMessageTimelineStore.onDisk(
          store.disk,
        ).load('group:g');
        expect(kept.map((ChatMessage m) => m.id), <String>['m1', 'm2']);
        // Without an id nothing could fetch it: no reference is kept.
        expect(kept.first.pendingMedia, isNull);
        expect(kept.last.pendingMedia, <String, dynamic>{
          'id': 'blk',
          'k': 'K',
          'src': '200::2',
        });
      },
    );
  });

  test('chatMediaRefFromJson keeps the known fields of their own type', () {
    expect(chatMediaRefFromJson(null), isNull);
    expect(chatMediaRefFromJson(<String, dynamic>{'k': 'K'}), isNull);
    expect(chatMediaRefFromJson(<String, dynamic>{'id': ''}), isNull);
    expect(chatMediaRefFromJson(<String, dynamic>{'id': 'x' * 257}), isNull);
    expect(
      chatMediaRefFromJson(<String, dynamic>{
        'id': 'blk',
        'k': 'K',
        'n': 'N',
        'mime': 'video/mp4',
        'ms': 1500,
        'src': '200::2',
        'extra': 'x',
      }),
      <String, dynamic>{
        'id': 'blk',
        'k': 'K',
        'n': 'N',
        'mime': 'video/mp4',
        'ms': 1500,
        'src': '200::2',
      },
    );
    expect(
      chatMediaRefFromJson(<String, dynamic>{
        'id': 'blk',
        'k': 'K' * 129,
        'n': 12,
        'mime': null,
        'ms': 24 * 3600 * 1000,
        'src': <String>['200::2'],
      }),
      <String, dynamic>{'id': 'blk'},
    );
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
