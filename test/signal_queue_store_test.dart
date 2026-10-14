import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';

void main() {
  group('FileSignalQueueStore', () {
    test('round-trips queued signals in binary form', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-queue-store-test-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileSignalQueueStore store = FileSignalQueueStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );

      const List<QueuedSignal> entries = <QueuedSignal>[
        QueuedSignal(
          id: 'entry-1',
          signal: ZenSignal(
            type: ZenSignalType.friendAccept,
            sender: 'ada.ygg',
            displayName: 'Ada',
            content: 'Juz jestesmy polaczeni.',
          ),
          receivedAtMillis: 101,
        ),
        QueuedSignal(
          id: 'entry-2',
          signal: ZenSignal(
            type: ZenSignalType.message,
            sender: 'maks.ygg',
            routeKey: 'transfer-9',
            messageType: ChatMessageType.voice,
            fileName: 'voice.m4a',
            mimeType: 'audio/mp4',
            durationMs: 8400,
            attachmentSizeBytes: 12000,
            attachmentData: 'SGVq',
            attachmentEncoding: 'zstd',
            chunkIndex: 1,
            chunkCount: 2,
            chunkData: 'aGVq',
            attachmentTransferBytes: 12000,
          ),
          receivedAtMillis: 202,
        ),
      ];

      await store.save(entries);
      final List<QueuedSignal> restored = await store.load();

      expect(restored, hasLength(2));
      expect(restored.first.id, 'entry-1');
      expect(restored.first.signal.displayName, 'Ada');
      expect(restored.first.signal.content, 'Juz jestesmy polaczeni.');
      expect(restored.last.signal.routeKey, 'transfer-9');
      expect(restored.last.signal.messageType, ChatMessageType.voice);
      expect(restored.last.signal.durationMs, 8400);
      expect(restored.last.signal.attachmentEncoding, 'zstd');
      expect(restored.last.signal.chunkCount, 2);
    });

    test(
      'keeps group fields: a queued invite must not lose its group',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'zen-queue-store-group-',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final FileSignalQueueStore store = FileSignalQueueStore(
          store: FileBinaryStore(
            tempDir,
            codec: BinaryCodec(compressor: const _PassThroughCompressor()),
          ),
        );

        await store.save(const <QueuedSignal>[
          QueuedSignal(
            id: 'invite-1',
            signal: ZenSignal(
              type: ZenSignalType.groupInvite,
              sender: 'ada.ygg',
              groupId: 'group-7',
              groupName: 'Wyprawa',
              memberAddresses: <String>['ada.ygg', 'bob.ygg'],
              avatarPreset: 'hike',
              inviteId: 'inv-42',
              sentAtMillis: 1234,
            ),
            receivedAtMillis: 99,
          ),
          QueuedSignal(
            id: 'typing-1',
            signal: ZenSignal(
              type: ZenSignalType.typing,
              sender: 'bob.ygg',
              isTyping: true,
            ),
            receivedAtMillis: 100,
          ),
        ]);
        final List<QueuedSignal> restored = await store.load();

        final ZenSignal invite = restored.first.signal;
        expect(invite.groupId, 'group-7');
        expect(invite.groupName, 'Wyprawa');
        expect(invite.memberAddresses, <String>['ada.ygg', 'bob.ygg']);
        expect(invite.avatarPreset, 'hike');
        expect(invite.inviteId, 'inv-42');
        expect(invite.sentAtMillis, 1234);
        expect(restored.first.receivedAtMillis, 99);
        expect(restored.last.signal.isTyping, isTrue);
        expect(restored.last.signal.groupId, isNull);
      },
    );

    test('a queue of another layout reads as empty', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-queue-store-v2-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final FileBinaryStore binary = FileBinaryStore(
        tempDir,
        codec: BinaryCodec(compressor: const _PassThroughCompressor()),
      );
      final BinaryWriter writer = BinaryWriter();
      for (final int byte in <int>[0x5A, 0x53, 0x51, 0x02]) {
        writer.writeUint8(byte);
      }
      writer.writeUint32(1);
      const QueuedSignal(
        id: 'old-1',
        signal: ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          content: 'hej',
        ),
        receivedAtMillis: 7,
      ).writeTo(writer);
      await binary.write('signals/pending', writer.toBytes());

      expect(await FileSignalQueueStore(store: binary).load(), isEmpty);
    });

    test('clearing entries removes persisted queue file', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-queue-store-clear-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileSignalQueueStore queueStore = FileSignalQueueStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );

      await queueStore.save(const <QueuedSignal>[
        QueuedSignal(
          id: 'entry-1',
          signal: ZenSignal(
            type: ZenSignalType.friendRequest,
            sender: 'kuba.ygg',
          ),
          receivedAtMillis: 1,
        ),
      ]);
      await queueStore.save(const <QueuedSignal>[]);

      expect(await queueStore.load(), isEmpty);
      expect(
        tempDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((File file) => file.path.endsWith('.zenbin')),
        isEmpty,
      );
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
