import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';

/// Replies, reactions, edits, deletions for everyone and forwarding as
/// data: kept on disk, copied to other devices and the circle backup, and
/// read from the network.

ChatMessage _rich() => const ChatMessage(
  id: 'in-1',
  sender: 'ada',
  text: 'Jutro o 8?',
  sentAtMillis: 1000,
  direction: ChatMessageDirection.incoming,
  reply: ChatReply(messageId: 'out-0', sender: 'self', text: 'Kiedy?'),
  reactions: <String, String>{'self': '👍', 'bob': '❤️'},
  editedAtMillis: 2000,
  forwarded: true,
);

void main() {
  group('ChatReply', () {
    test('round-trips and refuses what is not a reply', () {
      const ChatReply reply = ChatReply(
        messageId: 'm1',
        sender: 'ada',
        text: 'Hej',
      );
      expect(ChatReply.fromJson(reply.toJson()), reply);
      expect(ChatReply.fromJson(null), isNull);
      expect(ChatReply.fromJson(<String, dynamic>{'id': ''}), isNull);
      expect(ChatReply.fromJson(<String, dynamic>{'id': 'x' * 300}), isNull);
      expect(
        ChatReply.fromJson(<String, dynamic>{'id': 'm1', 's': 3})?.sender,
        '',
      );
    });

    test('the quoted text is one short line', () {
      final String long = 'a\n${'b' * 400}';
      final String clipped = clipChatSnippet(long);
      expect(clipped, isNot(contains('\n')));
      expect(clipped.length, kMaxReplySnippetChars + 1);
      expect(clipped, endsWith('…'));
      expect(
        ChatReply.fromJson(<String, dynamic>{'id': 'm', 't': long})!.text,
        clipped,
      );
    });
  });

  group('extras', () {
    test('a plain message has none', () {
      expect(
        chatMessageExtrasToJson(
          const ChatMessage(
            id: 'x',
            sender: 'self',
            text: 'Hej',
            sentAtMillis: 1,
            direction: ChatMessageDirection.outgoing,
          ),
        ),
        isNull,
      );
    });

    test('round-trip, without what is not valid', () {
      final ChatMessage message = _rich().copyWith(
        pendingMedia: <String, dynamic>{'id': 'blob', 'src': 'ada'},
      );
      final Map<String, dynamic> json = chatMessageExtrasToJson(message)!;
      final ChatMessage back = chatMessageWithExtras(
        message.copyWith(
          reply: null,
          reactions: const <String, String>{},
          editedAtMillis: null,
          forwarded: false,
          pendingMedia: null,
        ),
        json,
      );
      expect(back.reply, message.reply);
      expect(back.reactions, message.reactions);
      expect(back.editedAtMillis, 2000);
      expect(back.isEdited, isTrue);
      expect(back.forwarded, isTrue);
      expect(back.pendingMedia?['id'], 'blob');

      final ChatMessage junk = chatMessageWithExtras(message, <String, dynamic>{
        'rx': <String, dynamic>{'a': '', 'b': 'x' * 40, 'c': 5, 'd': '🙂'},
      });
      expect(junk.reactions, <String, String>{'d': '🙂'});
    });

    test('deleting for everyone leaves no content behind', () {
      final ChatMessage deleted = _rich()
          .copyWith(
            type: ChatMessageType.image,
            attachmentPath: 'vault/photo',
            fileName: 'a.jpg',
          )
          .deletedAt(3000);
      expect(deleted.isDeleted, isTrue);
      expect(deleted.text, isEmpty);
      expect(deleted.hasAttachment, isFalse);
      expect(deleted.fileName, isNull);
      expect(deleted.reply, isNull);
      expect(deleted.reactions, isEmpty);
      expect(deleted.forwarded, isFalse);
      expect(chatMessageExtrasToJson(deleted), <String, dynamic>{'del': 3000});
    });
  });

  test('the conversation file keeps replies, reactions, edits and '
      'deletions', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zen-extras-');
    addTearDown(() => dir.delete(recursive: true));
    FileMessageTimelineStore open() => FileMessageTimelineStore(
      store: FileBinaryStore(
        dir,
        codec: BinaryCodec(compressor: const _PassThroughCompressor()),
      ),
    );
    const ChatMessage plain = ChatMessage(
      id: 'out-2',
      sender: 'self',
      text: 'Tak',
      sentAtMillis: 1500,
      direction: ChatMessageDirection.outgoing,
      deliveryState: ChatMessageDeliveryState.delivered,
    );
    await open().save('ada', <ChatMessage>[
      _rich(),
      plain.deletedAt(4000),
      plain.copyWith(id: 'out-3'),
    ]);

    final List<ChatMessage> back = await open().load('ada');
    expect(back, hasLength(3));
    expect(back[0].reply, _rich().reply);
    expect(back[0].reactions, _rich().reactions);
    expect(back[0].editedAtMillis, 2000);
    expect(back[0].forwarded, isTrue);
    expect(back[1].isDeleted, isTrue);
    expect(back[1].text, isEmpty);
    expect(back[2].reply, isNull);
    expect(back[2].reactions, isEmpty);
    expect(back[2].isEdited, isFalse);
  });

  test('copies to other devices and the circle backup carry the '
      'changes', () {
    final ChatMessage? back = chatMessageFromSync(chatMessageToSync(_rich()));
    expect(back, isNotNull);
    expect(back!.reply, _rich().reply);
    expect(back.reactions, _rich().reactions);
    expect(back.editedAtMillis, 2000);
    expect(back.forwarded, isTrue);

    final ChatMessage? deleted = chatMessageFromSync(
      chatMessageToSync(_rich().deletedAt(5000)),
    );
    expect(deleted!.isDeleted, isTrue);
    expect(deleted.text, isEmpty);
  });

  group('frames', () {
    test('a reaction, an edit and a deletion', () {
      final ZenSignal react = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'msg_react',
          'msgId': 'm1',
          'emoji': '😂',
          'groupId': 'g1',
        },
      )!;
      expect(react.type, ZenSignalType.messageReaction);
      expect(react.messageId, 'm1');
      expect(react.groupId, 'g1');
      expect(react.chatExtras?['emoji'], '😂');

      final ZenSignal takenBack = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{'type': 'msg_react', 'msgId': 'm1'},
      )!;
      expect(takenBack.chatExtras?['emoji'], '');

      final ZenSignal tooLong = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'msg_react',
          'msgId': 'm1',
          'emoji': 'x' * 40,
        },
      )!;
      expect(tooLong.chatExtras?['emoji'], '');

      final ZenSignal edit = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'msg_edit',
          'msgId': 'm1',
          'text': 'Poprawione',
          'at': 77,
        },
      )!;
      expect(edit.type, ZenSignalType.messageEdit);
      expect(edit.content, 'Poprawione');
      expect(edit.sentAtMillis, 77);

      final ZenSignal delete = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{'type': 'msg_delete', 'msgId': 'm1'},
      )!;
      expect(delete.type, ZenSignalType.messageDelete);

      expect(
        zenSignalFromTransportPayload(
          sender: 'ada',
          payload: <String, dynamic>{'type': 'msg_delete'},
        ),
        isNull,
      );
    });

    test('a reply and a forwarded message', () {
      final ZenSignal message = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'message',
          'msgId': 'm2',
          'text': 'Pewnie',
          're': <String, dynamic>{'id': 'm1', 's': 'self', 't': 'Idziesz?'},
          'fwd': true,
        },
      )!;
      final ChatReply? reply = ChatReply.fromJson(message.chatExtras?['re']);
      expect(reply?.messageId, 'm1');
      expect(reply?.text, 'Idziesz?');
      expect(message.chatExtras?['fwd'], isTrue);
    });

    test('a file in a group, inline or as blocks', () {
      final ZenSignal inline = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g1',
          'msgId': 'm3',
          'text': 'kot.jpg',
          'messageType': 'image',
          'fileName': '../kot.jpg',
          'mimeType': 'image/jpeg',
          'attachmentData': 'AAEC',
          'attachmentSizeBytes': 3,
        },
      )!;
      expect(inline.messageType, ChatMessageType.image);
      expect(inline.attachmentData, 'AAEC');
      expect(inline.fileName, isNot(contains('/')));
      expect(inline.attachmentSizeBytes, 3);

      final ZenSignal blocks = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g1',
          'msgId': 'm4',
          'messageType': 'video',
          'fileName': 'film.mp4',
          'media': <String, dynamic>{'id': 'abc', 'size': 900000},
        },
      )!;
      expect(blocks.messageType, ChatMessageType.video);
      expect(blocks.attachmentData, isNull);
      expect(blocks.content, isNotEmpty);
      expect((blocks.chatExtras?['media'] as Map?)?['id'], 'abc');

      final ZenSignal text = zenSignalFromTransportPayload(
        sender: 'ada',
        payload: <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g1',
          'msgId': 'm5',
          'text': 'Hej',
        },
      )!;
      expect(text.messageType, isNull);
    });

    test('changes are queued reliably and reach this account\'s other '
        'devices', () {
      for (final String type in <String>[
        'msg_react',
        'msg_edit',
        'msg_delete',
      ]) {
        expect(kReliablePayloadTypes, contains(type));
        expect(kMirroredTypes, contains(type));
      }
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
