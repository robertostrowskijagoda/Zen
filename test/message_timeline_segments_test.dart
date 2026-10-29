import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';

String _b64(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

/// The logical key of a conversation (its pieces and index are below it).
String _thread(String peer) => 'threads/${_b64(peer)}';

ChatMessage _m(int i, {int? at}) => ChatMessage(
  id: 'm$i',
  sender: i.isEven ? 'self' : _ada,
  text: 'wiadomość $i',
  sentAtMillis: at ?? 1000 + i * 1000,
  direction: i.isEven
      ? ChatMessageDirection.outgoing
      : ChatMessageDirection.incoming,
);

/// Everything stored about a message, to compare.
String _describe(ChatMessage m) => <Object?>[
  m.id,
  m.sender,
  m.text,
  m.sentAtMillis,
  m.direction.name,
  m.deliveryState.name,
  m.type.name,
  m.fileName,
  m.mimeType,
  m.attachmentSizeBytes,
  m.attachmentBytes?.join(','),
  m.attachmentPath,
  m.readAtMillis,
  m.durationMs,
  m.expiresAtMillis,
].join('|');

List<String> _all(List<ChatMessage> messages) =>
    messages.map(_describe).toList();

List<String> _ids(List<ChatMessage> messages) =>
    messages.map((ChatMessage m) => m.id).toList();

/// Messages with every field there is.
List<ChatMessage> _rich() => <ChatMessage>[
  _m(0),
  _m(1).copyWith(
    deliveryState: ChatMessageDeliveryState.delivered,
    readAtMillis: 77,
  ),
  ChatMessage(
    id: 'file-2',
    sender: 'self',
    text: '📎 raport.txt',
    sentAtMillis: 3500,
    direction: ChatMessageDirection.outgoing,
    type: ChatMessageType.file,
    fileName: 'raport.txt',
    mimeType: 'text/plain',
    attachmentSizeBytes: 3,
    attachmentBytes: Uint8List.fromList(<int>[1, 2, 3]),
    attachmentPath: r'C:\Zen\raport.txt',
  ),
  const ChatMessage(
    id: 'gif-3',
    sender: _ada,
    text: '🎞 GIF',
    sentAtMillis: 4500,
    direction: ChatMessageDirection.incoming,
    type: ChatMessageType.image,
    fileName: 'gif.gif',
    mimeType: 'image/gif',
  ),
  const ChatMessage(
    id: 'voice-4',
    sender: 'self',
    text: '🎤',
    sentAtMillis: 5500,
    direction: ChatMessageDirection.outgoing,
    type: ChatMessageType.voice,
    durationMs: 12345,
    expiresAtMillis: 999999,
  ),
  for (int i = 5; i < 11; i++) _m(i),
];

void main() {
  final String key = _thread(_ada);
  String seg(int n) => '$key/seg/$n';
  final String idx = '$key/idx';

  group('pieces', () {
    test('a new message writes only the last piece and the index', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 4,
      );
      for (int i = 0; i < 10; i++) {
        await store.append(_ada, _m(i));
      }
      // [m0..m3] [m4..m7] [m8 m9]
      disk.reset();
      await store.append(_ada, _m(10));
      expect(disk.writes, <String>[seg(2), idx]);
      expect(disk.reads, <String>[idx], reason: 'the rest is in memory');
      expect(disk.deletes, isEmpty);

      await store.append(_ada, _m(11));
      disk.reset();
      await store.append(_ada, _m(12));
      expect(disk.writes, <String>[seg(3), idx], reason: 'a new piece');

      final List<String> expected = <String>[
        for (int i = 0; i <= 12; i++) 'm$i',
      ];
      expect(_ids(await store.load(_ada)), expected);
      // What another isolate (or the next start) reads from disk.
      expect(
        _ids(
          await FileMessageTimelineStore.onDisk(
            disk,
            segmentSize: 4,
          ).load(_ada),
        ),
        expected,
      );
    });

    test('a changed message rewrites only the piece it is in', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 4,
      );
      for (int i = 0; i < 10; i++) {
        await store.append(_ada, _m(i));
      }
      final List<ChatMessage> next = List<ChatMessage>.of(
        await store.load(_ada),
      );
      next[5] = next[5].copyWith(
        deliveryState: ChatMessageDeliveryState.delivered,
        readAtMillis: 99,
      );
      disk.reset();
      await store.save(_ada, next);
      expect(disk.writes, <String>[seg(1), idx]);
      expect(disk.deletes, isEmpty);
      expect(_all(await store.load(_ada)), _all(next));
      expect(
        _all(
          await FileMessageTimelineStore.onDisk(
            disk,
            segmentSize: 4,
          ).load(_ada),
        ),
        _all(next),
      );

      // The same conversation saved again: nothing to write.
      disk.reset();
      await store.save(_ada, await store.load(_ada));
      expect(disk.writes, isEmpty);
      // Equal copies (not the same objects) count as unchanged too.
      await store.save(_ada, <ChatMessage>[
        for (final ChatMessage m in await store.load(_ada)) m.copyWith(),
      ]);
      expect(disk.writes, isEmpty);
    });

    test('a message older than the last goes in its place', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 4,
      );
      for (int i = 0; i < 10; i++) {
        await store.append(_ada, _m(i));
      }
      disk.reset();
      // Held by a relay: sent between m2 and m3.
      await store.append(_ada, _m(42, at: 3500));
      expect(disk.writes, <String>[seg(0), idx]);
      expect(_ids(await store.load(_ada)), <String>[
        'm0',
        'm1',
        'm2',
        'm42',
        'm3',
        'm4',
        'm5',
        'm6',
        'm7',
        'm8',
        'm9',
      ]);
    });

    test(
      'old messages removed: their pieces are rewritten or deleted',
      () async {
        final _CountingDisk disk = _CountingDisk();
        final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
          disk,
          segmentSize: 4,
        );
        for (int i = 0; i < 10; i++) {
          await store.append(_ada, _m(i));
        }
        final List<ChatMessage> thread = await store.load(_ada);
        disk.reset();
        // Retention: everything before m6 goes.
        await store.save(_ada, thread.sublist(6));
        expect(disk.writes, <String>[seg(1), idx]);
        expect(disk.deletes, <String>[seg(0)]);
        expect(disk.files.containsKey(seg(0)), isFalse);
        expect(_ids(await store.load(_ada)), <String>['m6', 'm7', 'm8', 'm9']);

        // A message deleted in the middle.
        final List<ChatMessage> now = List<ChatMessage>.of(
          await store.load(_ada),
        )..removeAt(2);
        disk.reset();
        await store.save(_ada, now);
        expect(disk.writes, <String>[seg(2), idx]);
        expect(
          _ids(
            await FileMessageTimelineStore.onDisk(
              disk,
              segmentSize: 4,
            ).load(_ada),
          ),
          <String>['m6', 'm7', 'm9'],
        );
      },
    );

    test('a message added at the end by a save joins the last piece', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 4,
      );
      for (int i = 0; i < 6; i++) {
        await store.append(_ada, _m(i));
      }
      disk.reset();
      // As the hub's upsert does: the list, plus one at the end.
      await store.save(_ada, <ChatMessage>[...await store.load(_ada), _m(6)]);
      expect(disk.writes, <String>[seg(1), idx]);
      await store.save(_ada, <ChatMessage>[
        ...await store.load(_ada),
        _m(7),
        _m(8),
      ]);
      expect(_ids(await store.load(_ada)), <String>[
        'm0',
        'm1',
        'm2',
        'm3',
        'm4',
        'm5',
        'm6',
        'm7',
        'm8',
      ]);
      expect(disk.files.containsKey(seg(2)), isTrue);
    });

    test('deleting a conversation deletes every piece of it', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 3,
      );
      for (int i = 0; i < 10; i++) {
        await store.append(_ada, _m(i));
      }
      await store.append('maks', _m(1));
      await store.save(_ada, const <ChatMessage>[]);
      expect(disk.files.keys.where((String k) => k.startsWith(key)), isEmpty);
      expect(await store.load(_ada), isEmpty);
      expect(await FileMessageTimelineStore.onDisk(disk).load(_ada), isEmpty);
      // Someone else's conversation is untouched.
      expect(_ids(await store.load('maks')), <String>['m1']);
      // And it starts again.
      await store.append(_ada, _m(20));
      expect(_ids(await store.load(_ada)), <String>['m20']);
    });

    test(
      'a long conversation with big inline files is cut by size too',
      () async {
        final _CountingDisk disk = _CountingDisk();
        final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
          disk,
          segmentBytes: 4096,
        );
        for (int i = 0; i < 6; i++) {
          await store.append(
            _ada,
            _m(i).copyWith(
              type: ChatMessageType.image,
              attachmentBytes: Uint8List(3000),
            ),
          );
        }
        expect(
          disk.files.keys.where((String k) => k.startsWith('$key/seg/')),
          hasLength(3),
        );
        disk.reset();
        await store.append(_ada, _m(6));
        expect(disk.writes, hasLength(2));
        expect(await store.load(_ada), hasLength(7));
      },
    );

    test('works like the old store, step after step', () async {
      final Random random = Random(7);
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 5,
      );
      final MemoryMessageTimelineStore reference = MemoryMessageTimelineStore();
      int counter = 0;
      int clock = 1000;
      for (int step = 0; step < 400; step++) {
        final List<ChatMessage> thread = await reference.load(_ada);
        final int roll = random.nextInt(100);
        if (roll < 45 || thread.isEmpty) {
          // A new message; now and then one held back by a relay.
          clock += 1000;
          final int at = random.nextInt(8) == 0
              ? clock - random.nextInt(20) * 1000
              : clock;
          final ChatMessage m = _m(counter++, at: at);
          await reference.append(_ada, m);
          await store.append(_ada, m);
        } else if (roll < 65) {
          // Delivered, read.
          final int i = random.nextInt(thread.length);
          final List<ChatMessage> next = List<ChatMessage>.of(
            await store.load(_ada),
          );
          next[i] = next[i].copyWith(
            deliveryState: ChatMessageDeliveryState
                .values[random.nextInt(ChatMessageDeliveryState.values.length)],
            readAtMillis: clock,
          );
          await reference.save(_ada, next);
          await store.save(_ada, next);
        } else if (roll < 75) {
          // A message deleted.
          final List<ChatMessage> next = List<ChatMessage>.of(
            await store.load(_ada),
          )..removeAt(random.nextInt(thread.length));
          await reference.save(_ada, next);
          await store.save(_ada, next);
        } else if (roll < 82) {
          // Retention: the oldest go.
          final List<ChatMessage> next = (await store.load(
            _ada,
          )).sublist(random.nextInt(thread.length ~/ 2 + 1));
          await reference.save(_ada, next);
          await store.save(_ada, next);
        } else if (roll < 90) {
          // An upsert: one more at the end, whatever its time.
          final ChatMessage m = _m(counter++, at: clock - 500);
          final List<ChatMessage> next = <ChatMessage>[
            ...await store.load(_ada),
            m,
          ];
          await reference.save(_ada, next);
          await store.save(_ada, next);
        } else if (roll < 92) {
          await reference.save(_ada, const <ChatMessage>[]);
          await store.save(_ada, const <ChatMessage>[]);
        } else if (roll < 95 && thread.length > 2) {
          // Reordered (the app never does this): written afresh.
          final List<ChatMessage> next = List<ChatMessage>.of(
            (await store.load(_ada)).reversed,
          );
          await reference.save(_ada, next);
          await store.save(_ada, next);
        } else {
          await store.save(_ada, await store.load(_ada));
        }
        final List<String> expected = _all(await reference.load(_ada));
        expect(_all(await store.load(_ada)), expected, reason: 'step $step');
        if (step % 25 == 0) {
          expect(
            _all(
              await FileMessageTimelineStore.onDisk(
                disk,
                segmentSize: 5,
              ).load(_ada),
            ),
            expected,
            reason: 'from disk, step $step',
          );
        }
      }
      // Pieces no longer used are gone from disk.
      final Set<String> live = disk.files.keys
          .where((String k) => k.startsWith('$key/seg/'))
          .toSet();
      final int messages = (await reference.load(_ada)).length;
      expect(live.length, lessThanOrEqualTo(messages));
    });
  });

  test('every field survives the trip to disk', () async {
    final _CountingDisk disk = _CountingDisk();
    final List<ChatMessage> rich = _rich();
    await FileMessageTimelineStore.onDisk(
      disk,
      segmentSize: 4,
    ).save(_ada, rich);
    expect(
      _all(
        await FileMessageTimelineStore.onDisk(disk, segmentSize: 4).load(_ada),
      ),
      _all(rich),
    );
  });

  group('when something is wrong on disk', () {
    test('a piece that is gone counts as empty', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 3,
      );
      for (int i = 0; i < 8; i++) {
        await store.append(_ada, _m(i));
      }
      disk.files.remove(seg(1));
      final FileMessageTimelineStore again = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 3,
      );
      expect(_ids(await again.load(_ada)), <String>[
        'm0',
        'm1',
        'm2',
        'm6',
        'm7',
      ]);
      await again.append(_ada, _m(8));
      expect(_ids(await again.load(_ada)).last, 'm8');
    });

    test('an index that cannot be read is rebuilt from its pieces: '
        'nothing lost, the conversation goes on', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
      );
      await store.append(_ada, _m(0));
      disk.files[idx] = Uint8List.fromList(<int>[1, 2, 3]);
      final FileMessageTimelineStore again = FileMessageTimelineStore.onDisk(
        disk,
      );
      expect(_ids(await again.load(_ada)), <String>['m0']);
      await again.append(_ada, _m(1));
      expect(_ids(await again.load(_ada)), <String>['m0', 'm1']);
      expect(
        _ids(await FileMessageTimelineStore.onDisk(disk).load(_ada)),
        <String>['m0', 'm1'],
      );
    });

    test('a store that is locked reads nothing and writes nothing', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
      );
      await store.append(_ada, _m(0));
      disk.failRead = (String _) => true;
      expect(await store.load(_ada), isEmpty);
      disk.reset();
      await expectLater(store.append(_ada, _m(1)), throwsA(anything));
      expect(disk.writes, isEmpty);
      disk.failRead = null;
      expect(_ids(await store.load(_ada)), <String>['m0']);
    });

    test('a piece that cannot be read is kept, never written over', () async {
      final _CountingDisk disk = _CountingDisk();
      final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 3,
      );
      for (int i = 0; i < 8; i++) {
        await store.append(_ada, _m(i));
      }
      final Uint8List damaged = Uint8List.fromList(<int>[255, 7]);
      disk.files[seg(0)] = damaged;
      final FileMessageTimelineStore again = FileMessageTimelineStore.onDisk(
        disk,
        segmentSize: 3,
      );
      final List<ChatMessage> shown = await again.load(_ada);
      expect(_ids(shown), <String>['m3', 'm4', 'm5', 'm6', 'm7']);
      await again.save(_ada, <ChatMessage>[
        for (final ChatMessage m in shown)
          m.copyWith(deliveryState: ChatMessageDeliveryState.delivered),
      ]);
      await again.append(_ada, _m(8));
      expect(disk.files[seg(0)], damaged);
      expect(
        _ids(
          await FileMessageTimelineStore.onDisk(
            disk,
            segmentSize: 3,
          ).load(_ada),
        ),
        <String>['m3', 'm4', 'm5', 'm6', 'm7', 'm8'],
      );
    });
  });

  test('only the conversations used last stay in memory', () async {
    final _CountingDisk disk = _CountingDisk();
    final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
      disk,
      cachedThreads: 1,
    );
    await store.append(_ada, _m(0));
    await store.append('maks', _m(1));
    disk.reset();
    expect(_ids(await store.load('maks')), <String>['m1']);
    expect(disk.reads, hasLength(1), reason: 'in memory: the index only');
    disk.reset();
    expect(_ids(await store.load(_ada)), <String>['m0']);
    expect(disk.reads, contains(seg(0)), reason: 'read again from disk');
    await store.append(_ada, _m(2));
    expect(_ids(await store.load(_ada)), <String>['m0', 'm2']);
    expect(_ids(await store.load('maks')), <String>['m1']);
  });

  test('the app and its background service (two stores, one disk) see '
      'each other\'s writes', () async {
    final _CountingDisk disk = _CountingDisk();
    final FileMessageTimelineStore app = FileMessageTimelineStore.onDisk(
      disk,
      segmentSize: 3,
    );
    final FileMessageTimelineStore service = FileMessageTimelineStore.onDisk(
      disk,
      segmentSize: 3,
    );
    await app.append(_ada, _m(0));
    expect(_ids(await app.load(_ada)), <String>['m0']);
    await service.append(_ada, _m(1));
    await service.append(_ada, _m(2));
    await service.append(_ada, _m(3));
    // The app's copy in memory is stale: it reads again, and adds to what
    // the service wrote instead of writing over it.
    await app.append(_ada, _m(4));
    final List<String> all = <String>['m0', 'm1', 'm2', 'm3', 'm4'];
    expect(_ids(await app.load(_ada)), all);
    expect(_ids(await service.load(_ada)), all);
    await service.save(_ada, const <ChatMessage>[]);
    expect(await app.load(_ada), isEmpty);
  });

  test('in the encrypted store, pieces and index have hidden names', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'zen-thread-pieces-',
    );
    addTearDown(() => root.delete(recursive: true));
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      passwordIterations: 10,
    );
    final EncryptedBinaryPayloadProtector protector =
        EncryptedBinaryPayloadProtector(security);
    final BinaryCodec codec = BinaryCodec(compressor: const _PassThrough());
    final List<ChatMessage> rich = _rich();

    List<String> onDisk() => <String>[
      for (final FileSystemEntity e in root.listSync(recursive: true))
        e.path.substring(root.path.length),
    ];

    final FileMessageTimelineStore store = FileMessageTimelineStore(
      store: FileBinaryStore(root, codec: codec, protector: protector),
      segmentSize: 4,
    );
    await store.save(_ada, rich);
    await store.append(_ada, _m(11));
    for (final String path in onDisk()) {
      expect(
        path.toLowerCase().contains(_b64(_ada).toLowerCase()),
        isFalse,
        reason: path,
      );
    }
    expect(
      _ids(
        await FileMessageTimelineStore(
          store: FileBinaryStore(root, codec: codec, protector: protector),
        ).load(_ada),
      ),
      <String>[..._ids(rich), 'm11'],
    );
  });
}

/// A disk in memory that tells what was read, written and deleted, and can
/// fail on purpose.
final class _CountingDisk implements LedgerDisk {
  final MemoryLedgerDisk _inner = MemoryLedgerDisk();
  final List<String> reads = <String>[];
  final List<String> writes = <String>[];
  final List<String> deletes = <String>[];
  bool Function(String key)? failRead;
  bool Function(String key)? failWrite;
  bool Function(String key)? failDelete;

  Map<String, Uint8List> get files => _inner.files;

  void reset() {
    reads.clear();
    writes.clear();
    deletes.clear();
  }

  @override
  Future<Uint8List?> read(String key) async {
    if (failRead?.call(key) ?? false) {
      throw StateError('Locked.');
    }
    reads.add(key);
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, Uint8List data) async {
    if (failWrite?.call(key) ?? false) {
      throw const FileSystemException('Disk full.');
    }
    writes.add(key);
    await _inner.write(key, data);
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete?.call(key) ?? false) {
      throw const FileSystemException('Busy.');
    }
    deletes.add(key);
    await _inner.delete(key);
  }
}

final class _PassThrough implements BinaryCompressor {
  const _PassThrough();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
