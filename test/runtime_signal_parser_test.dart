import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/domain/messages/chat_media_size.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

void main() {
  test('parses friend request payloads into ZenSignal', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{
        'type': 'friend_request',
        'senderName': 'Ada',
        'message': 'Mam paczke linkow.',
      },
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.friendRequest);
    expect(signal.displayName, 'Ada');
    expect(signal.content, 'Mam paczke linkow.');
  });

  test('parses message payloads into ZenSignal', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{
        'type': 'message',
        'msgId': 'm-1',
        'text': 'Wchodze za minute.',
      },
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.message);
    expect(signal.messageId, 'm-1');
    expect(signal.content, 'Wchodze za minute.');
  });

  test('parses inline attachment metadata from message payloads', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{
        'type': 'message',
        'msgId': 'm-2',
        'text': '📎 raport.txt',
        'messageType': 'file',
        'fileName': 'raport.txt',
        'mimeType': 'text/plain',
        'attachmentSizeBytes': 128,
        'attachmentData': 'SGVq',
      },
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.message);
    expect(signal.messageType, ChatMessageType.file);
    expect(signal.fileName, 'raport.txt');
    expect(signal.mimeType, 'text/plain');
    expect(signal.attachmentSizeBytes, 128);
    expect(signal.attachmentData, 'SGVq');
  });

  test('parses GIF and media metadata from message payloads', () {
    final ZenSignal? gifSignal = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'message',
        'msgId': 'gif-1',
        'messageType': 'image',
        'text': '🎞 GIF',
        'attachmentData': 'R0lG',
        'mimeType': 'image/gif',
        'fileName': 'gif.gif',
      },
    );
    final ZenSignal? voiceSignal = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'message',
        'msgId': 'voice-1',
        'text': '🎤 Wiadomość głosowa',
        'messageType': 'voice',
        'mimeType': 'audio/mp4',
        'fileName': 'voice.m4a',
        'durationMs': 4200,
        'attachmentData': 'SGVq',
      },
    );

    expect(gifSignal?.attachmentData, 'R0lG');
    expect(gifSignal?.messageType, ChatMessageType.image);
    expect(voiceSignal?.messageType, ChatMessageType.voice);
    expect(voiceSignal?.durationMs, 4200);
  });

  test('parses placeholder and chunk attachment payloads', () {
    final ZenSignal? placeholder = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'message_placeholder',
        'msgId': 'file-1',
        'text': '📎 raport.txt',
        'messageType': 'file',
        'fileName': 'raport.txt',
        'mimeType': 'text/plain',
        'attachmentSizeBytes': 200000,
        'attachmentTransferBytes': 200000,
        'chunkCount': 4,
      },
    );
    final ZenSignal? chunk = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'message_chunk',
        'msgId': 'file-1',
        'text': '📎 raport.txt',
        'messageType': 'file',
        'chunkIndex': 2,
        'chunkCount': 4,
        'chunkData': 'aGVq',
        'attachmentTransferBytes': 200000,
      },
    );
    final ZenSignal? ack = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'message_chunk_ack',
        'msgId': 'file-1',
        'chunkIndex': 2,
      },
    );

    expect(placeholder, isNotNull);
    expect(placeholder!.isPlaceholder, isTrue);
    expect(placeholder.chunkCount, 4);
    expect(placeholder.attachmentTransferBytes, 200000);
    expect(chunk, isNotNull);
    expect(chunk!.type, ZenSignalType.messageChunk);
    expect(chunk.chunkIndex, 2);
    expect(chunk.chunkData, 'aGVq');
    expect(ack, isNotNull);
    expect(ack!.type, ZenSignalType.messageChunkAck);
    expect(ack.chunkIndex, 2);
  });

  group('the size of a picture', () {
    const String sender = '200:1111:2222:3333:4444:5555:6666:7777';

    Map<String, dynamic>? extrasOf(Map<String, dynamic> payload) =>
        zenSignalFromTransportPayload(
          sender: sender,
          payload: payload,
        )?.chatExtras;

    test('a message, a group message, a placeholder and a chunk carry it', () {
      const Map<String, dynamic> size = <String, dynamic>{
        kMediaWidthKey: 480,
        kMediaHeightKey: 270,
      };
      for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'message',
          'msgId': 'm-1',
          'attachmentData': 'R0lG',
          ...size,
        },
        <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g',
          'msgId': 'm-2',
          'messageType': 'image',
          ...size,
        },
        <String, dynamic>{
          'type': 'message_placeholder',
          'msgId': 'm-3',
          'chunkCount': 2,
          ...size,
        },
        <String, dynamic>{
          'type': 'message_chunk',
          'msgId': 'm-3',
          'chunkIndex': 0,
          'chunkCount': 2,
          'chunkData': 'AA==',
          ...size,
        },
      ]) {
        expect(extrasOf(payload)?[kMediaSizeKey], <String, dynamic>{
          'w': 480,
          'h': 270,
        }, reason: payload['type'] as String);
      }
    });

    test('a size that is no size is dropped whole, never clamped', () {
      for (final (Object?, Object?) bad in <(Object?, Object?)>[
        (0, 270),
        (480, -1),
        (kMaxChatMediaSide + 1, 270),
        (480, 1e300),
        ('480', 270),
        (480, null),
        (<int>[480], 270),
        (double.infinity, 270),
      ]) {
        final Map<String, dynamic>? extras = extrasOf(<String, dynamic>{
          'type': 'message_placeholder',
          'msgId': 'm-4',
          kMediaWidthKey: bad.$1,
          kMediaHeightKey: bad.$2,
        });
        expect(extras?[kMediaSizeKey], isNull, reason: '$bad');
      }
      // A number with a fraction counts as its whole pixels.
      expect(
        extrasOf(<String, dynamic>{
          'type': 'message',
          'msgId': 'm-5',
          'text': 'x',
          kMediaWidthKey: 480.7,
          kMediaHeightKey: 270,
        })?[kMediaSizeKey],
        <String, dynamic>{'w': 480, 'h': 270},
      );
    });
  });

  test('parses realtime transfer offer and answer payloads', () {
    final ZenSignal? offer = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'transfer_offer',
        'transferId': 'file-2',
        'text': '📎 duzy.bin',
        'messageType': 'file',
        'fileName': 'duzy.bin',
        'mimeType': 'application/octet-stream',
        'attachmentSizeBytes': 4096,
        'durationMs': 9100,
        'fileSize': 4096,
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      },
    );
    final ZenSignal? answer = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'transfer_answer',
        'transferId': 'file-2',
        'description': <String, dynamic>{'type': 'answer', 'sdp': 'v=0'},
      },
    );

    expect(offer?.type, ZenSignalType.transferOffer);
    expect(offer?.messageId, 'file-2');
    expect(offer?.fileName, 'duzy.bin');
    expect(offer?.durationMs, 9100);
    expect(offer?.attachmentTransferBytes, 4096);
    expect(offer?.sessionDescription?['type'], 'offer');
    expect(answer?.type, ZenSignalType.transferAnswer);
    expect(answer?.sessionDescription?['type'], 'answer');
  });

  test('parses WebRTC call signaling payloads', () {
    final ZenSignal? offer = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'offer',
        'callId': 'call-1',
        'kind': 'video',
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      },
    );
    final ZenSignal? ringing = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'ringing',
        'callId': 'call-1',
        'kind': 'video',
      },
    );
    final ZenSignal? answer = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'answer',
        'callId': 'call-1',
        'kind': 'video',
        'description': <String, dynamic>{'type': 'answer', 'sdp': 'v=0'},
      },
    );
    final ZenSignal? busy = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'busy',
        'callId': 'call-1',
        'kind': 'audio',
      },
    );
    final ZenSignal? hangup = zenSignalFromTransportPayload(
      sender: 'ada.ygg',
      payload: const <String, dynamic>{
        'type': 'hangup',
        'callId': 'call-1',
        'kind': 'video',
      },
    );

    expect(offer?.type, ZenSignalType.callOffer);
    expect(offer?.sessionDescription?['type'], 'offer');
    expect(ringing?.type, ZenSignalType.callRinging);
    expect(answer?.type, ZenSignalType.callAnswer);
    expect(answer?.sessionDescription?['type'], 'answer');
    expect(busy?.type, ZenSignalType.callBusy);
    expect(hangup?.type, ZenSignalType.callEnd);
  });

  test('parses message ack payloads into ack ZenSignal', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{'type': 'message_ack', 'msgId': 'm-1'},
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.ack);
    expect(signal.messageId, 'm-1');
    expect(signal.content, 'message');
  });

  test('parses message read payloads into read-receipt ZenSignal', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{'type': 'message_read', 'msgId': 'm-1'},
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.messageRead);
    expect(signal.messageId, 'm-1');
  });

  test('parses friend reject and cancel payloads into ZenSignal', () {
    final ZenSignal? rejected = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{'type': 'friend_reject'},
    );
    final ZenSignal? cancelled = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{'type': 'friend_cancel'},
    );

    expect(rejected?.type, ZenSignalType.friendReject);
    expect(cancelled?.type, ZenSignalType.friendCancel);
  });

  test('ignores unsupported payload types', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{'type': 'pong'},
    );

    expect(signal, isNull);
  });

  test('parses call decline payloads into ZenSignal', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{
        'type': 'call_decline',
        'callId': 'call-1',
        'kind': 'audio',
      },
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.callDecline);
    expect(signal.callId, 'call-1');
  });

  test('parses call offer request payloads into ZenSignal', () {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{
        'type': 'call_offer_request',
        'callId': 'call-9',
        'kind': 'video',
      },
    );

    expect(signal, isNotNull);
    expect(signal!.type, ZenSignalType.callOfferRequest);
    expect(signal.callId, 'call-9');
    expect(signal.content, 'video');
  });
  group('pinned by mutation testing', () {
    const String ola = '200:1111:2222:3333:4444:5555:6666:7777';
    ZenSignal? parse(Map<String, dynamic> payload) =>
        zenSignalFromTransportPayload(sender: ola, payload: payload);

    test('a group signal without its group, or a group call without its '
        'call, is dropped', () {
      for (final String type in <String>[
        'group_invite',
        'group_invite_ack',
        'group_message',
      ]) {
        expect(parse(<String, dynamic>{'type': type}), isNull, reason: type);
        expect(
          parse(<String, dynamic>{
            'type': type,
            'groupId': 'g',
            'msgId': 'm',
            'text': 'x',
          }),
          isNotNull,
          reason: type,
        );
      }
      for (final Map<String, dynamic> call in <Map<String, dynamic>>[
        <String, dynamic>{'type': 'group_call_join', 'groupId': 'g'},
        <String, dynamic>{'type': 'group_call_join', 'callId': 'c'},
      ]) {
        expect(parse(call), isNull, reason: '$call');
      }
      expect(
        parse(<String, dynamic>{
          'type': 'group_call_join',
          'groupId': 'g',
          'callId': 'c',
        })?.type,
        ZenSignalType.groupCallJoin,
      );
    });

    test('an invitation answer says joined only when it says so', () {
      for (final (Object? joined, String? content) in <(Object?, String?)>[
        (true, kGroupJoinedAck),
        (false, null),
        ('true', null),
        (null, null),
      ]) {
        expect(
          parse(<String, dynamic>{
            'type': 'group_invite_ack',
            'groupId': 'g',
            'joined': joined,
          })!.content,
          content,
          reason: '$joined',
        );
      }
    });

    test("an invitation's members: trimmed, no empty or overlong address", () {
      final ZenSignal invite = parse(<String, dynamic>{
        'type': 'group_invite',
        'groupId': 'g',
        'memberAddresses': <Object?>[
          ' $ola ',
          '',
          '   ',
          'x' * (kMaxSignalIdChars + 1),
          'y' * kMaxSignalIdChars,
          7,
        ],
      })!;
      expect(invite.memberAddresses, <String>[ola, 'y' * kMaxSignalIdChars]);
    });

    test('forwarded only when marked so', () {
      Map<String, dynamic>? extras(Object? fwd) => parse(<String, dynamic>{
        'type': 'message',
        'msgId': 'm',
        'text': 'x',
        'fwd': fwd,
      })!.chatExtras;
      expect(extras(true)?['fwd'], isTrue);
      expect(extras(false)?['fwd'], isNull);
      expect(extras('true')?['fwd'], isNull);
    });

    test('typing reads a yes or a no in any case, anything else as typing', () {
      bool? typing(Object? value) => parse(<String, dynamic>{
        'type': 'typing',
        'isTyping': value,
      })!.isTyping;
      expect(typing(false), isFalse);
      expect(typing('False'), isFalse);
      expect(typing('TRUE'), isTrue);
      expect(typing('nie'), isTrue);
      expect(typing(null), isTrue);
    });

    test('a long name is cut whole: at the limit, without half an emoji', () {
      String? name(String given) => parse(<String, dynamic>{
        'type': 'friend_request',
        'senderName': given,
      })!.displayName;
      final String plain = 'a' * (kMaxSignalSenderNameChars + 10);
      expect(name(plain), 'a' * kMaxSignalSenderNameChars);
      // An emoji (two UTF-16 units) across the limit is left out whole.
      final String across = '${'b' * (kMaxSignalSenderNameChars - 1)}😀zzz';
      expect(name(across), 'b' * (kMaxSignalSenderNameChars - 1));
    });
  });

  group('JSON text from the wire', () {
    // The frames arrive as JSON text: numbers Dart reads as infinity
    // (1e400) or as no exact integer (1e300), nesting and repeated keys
    // can all be in it, and none of it may throw or reach a store.
    ZenSignal? fromText(String text) => zenSignalFromTransportPayload(
      sender: '200::1',
      payload: jsonDecode(text) as Map<String, dynamic>,
    );

    /// [signal] as the queue keeps it: written whole, or it throws.
    void queueable(ZenSignal signal) => QueuedSignal(
      id: 'q',
      signal: signal,
      receivedAtMillis: 1,
    ).writeTo(BinaryWriter());

    const List<String> badNumbers = <String>[
      '1e400',
      '-1e400',
      '1e300',
      '-1e300',
      '99999999999999999999999',
      '9007199254740993',
      // The smallest 64-bit integer: its own `abs`.
      '-9223372036854775808',
    ];

    test('a number no reader can use is absent: it never throws', () {
      // Every number the parser reads, in the frames that carry it.
      const List<String> frames = <String>[
        '{"type":"message","msgId":"m","text":"a","attachmentSizeBytes":#,'
            '"durationMs":#,"ttl":#,"createdAt":#}',
        '{"type":"message_placeholder","msgId":"m","attachmentSizeBytes":#,'
            '"durationMs":#,"attachmentTransferBytes":#,"chunkCount":#,'
            '"chunkIndex":#}',
        '{"type":"message_chunk","msgId":"m","chunkIndex":#,"chunkCount":#,'
            '"attachmentSizeBytes":#,"durationMs":#,'
            '"attachmentTransferBytes":#}',
        '{"type":"message_chunk_ack","msgId":"m","chunkIndex":#}',
        '{"type":"transfer_offer","transferId":"t","fileSize":#,'
            '"attachmentSizeBytes":#,"durationMs":#}',
        '{"type":"group_message","groupId":"g","msgId":"m","text":"a",'
            '"timestamp":#,"ttl":#,"attachmentSizeBytes":#,"durationMs":#}',
        '{"type":"msg_edit","msgId":"m","text":"a","at":#}',
        '{"type":"msg_delete","msgId":"m","at":#}',
        '{"type":"disappear_timer","seconds":#,"at":#}',
        '{"type":"profile_update","name":"a","v":#}',
      ];
      for (final String frame in frames) {
        for (final String bad in badNumbers) {
          final String text = frame.replaceAll('#', bad);
          final ZenSignal? signal = fromText(text);
          expect(signal, isNotNull, reason: text);
          for (final int? n in <int?>[
            signal!.attachmentSizeBytes,
            signal.durationMs,
            signal.attachmentTransferBytes,
            signal.chunkCount,
            signal.chunkIndex,
            signal.sentAtMillis,
            signal.disappearSeconds,
          ]) {
            expect(
              n == null || n == 0 || n.abs() <= kMaxSignalNumber,
              isTrue,
              reason: text,
            );
          }
          expect(signal.durationMs, isNull, reason: text);
          expect(signal.sentAtMillis, isNull, reason: text);
          queueable(signal);
        }
      }
      // A number it can use still reads, as an integer.
      expect(
        fromText(
          '{"type":"message","text":"a","durationMs":1500.0}',
        )!.durationMs,
        1500,
      );
      expect(
        fromText(
          '{"type":"msg_edit","msgId":"m","at":$kMaxSignalNumber}',
        )!.sentAtMillis,
        kMaxSignalNumber,
      );
    });

    test('a number deep inside (a reply, a poll, a position, a call\'s '
        'description, a mini-profile) neither throws nor reaches a store', () {
      for (final String bad in badNumbers) {
        final List<String> frames = <String>[
          '{"type":"message","msgId":"m","text":"a",'
              '"re":{"id":"x","s":$bad,"t":$bad},'
              '"men":[{"d":"200::2","a":$bad,"n":$bad}],'
              '"poll":{"q":"?","o":["a","b"],"d":$bad,"c":$bad},'
              '"loc":{"la":1,"lo":1,"ac":$bad,"at":$bad,"un":$bad},'
              '"mp":{"n":"Ola","av":{"id":"b","k":"K","n":"N","ms":$bad},'
              '"x":$bad}}',
          '{"type":"message","msgId":"m","text":"a",'
              '"loc":{"la":1,"lo":1,"at":9223372036854775807,"un":5}}',
          '{"type":"offer","callId":"c","description":{"type":"offer",'
              '"sdp":"v=0","exchange":$bad,"e2ee":{"v":$bad,"epoch":$bad}}}',
          '{"type":"group_message","groupId":"g","msgId":"m","text":"a",'
              '"messageType":"image","media":{"id":"blk","k":"K","n":$bad,'
              '"ms":$bad,"x":$bad}}',
        ];
        for (final String text in frames) {
          final ZenSignal? signal = fromText(text);
          expect(signal, isNotNull, reason: text);
          queueable(signal!);
          // Whatever it keeps, JSON can write again.
          jsonEncode(<String, Object?>{
            'cx': signal.chatExtras,
            'mp': signal.miniProfile,
            'sd': signal.sessionDescription,
          });
        }
      }
      final ZenSignal offer = fromText(
        '{"type":"offer","callId":"c","description":{"type":"offer",'
        '"sdp":"v=0","exchange":1e400}}',
      )!;
      expect(offer.sessionDescription, <String, dynamic>{
        'type': 'offer',
        'sdp': 'v=0',
      });
    });

    test('a group file\'s reference keeps only its known fields', () {
      final ZenSignal signal = fromText(
        '{"type":"group_message","groupId":"g","msgId":"m","text":"a",'
        '"messageType":"image","media":{"id":"blk","k":"K","n":"N",'
        '"mime":"image/jpeg","ms":1200,"h":1e400,"x":{"y":[1,2]},'
        '"src":"200::9"}}',
      )!;
      expect(signal.chatExtras!['media'], <String, dynamic>{
        'id': 'blk',
        'k': 'K',
        'n': 'N',
        'mime': 'image/jpeg',
        'ms': 1200,
        'src': '200::9',
      });
      // Wrong types are left out; without an id there is no reference.
      expect(
        fromText(
          '{"type":"group_message","groupId":"g","msgId":"m","text":"a",'
          '"messageType":"image","media":{"id":"blk","k":7,"n":true,'
          '"mime":["x"],"ms":-5}}',
        )!.chatExtras!['media'],
        <String, dynamic>{'id': 'blk'},
      );
      expect(
        fromText(
          '{"type":"group_message","groupId":"g","msgId":"m","text":"a",'
          '"messageType":"image","media":{"h":"abc","n":1e400}}',
        )!.chatExtras?['media'],
        isNull,
      );
      // A mini-profile keeps its name and photo only, and still marks the
      // message when nothing in it is usable.
      expect(
        fromText(
          '{"type":"message","msgId":"m","text":"a","mp":{"n":" Ola ",'
          '"av":{"id":"b","k":"K","n":"N","z":1},"q":1e400}}',
        )!.miniProfile,
        <String, dynamic>{
          'n': 'Ola',
          'av': <String, dynamic>{'id': 'b', 'k': 'K', 'n': 'N'},
        },
      );
      expect(
        fromText(
          '{"type":"message","msgId":"m","text":"a","mp":{"q":1}}',
        )!.miniProfile,
        isEmpty,
      );
    });

    test('deep nesting is cut, not followed', () {
      final String deep = '${'[' * 400}1${']' * 400}';
      final ZenSignal? signal = fromText(
        '{"type":"offer","callId":"c","description":{"type":"offer",'
        '"sdp":"v=0","x":$deep},"re":$deep}',
      );
      expect(signal, isNotNull);
      expect(signal!.sessionDescription!['sdp'], 'v=0');
      queueable(signal);
      int depth(Object? v) => switch (v) {
        final Map<dynamic, dynamic> m =>
          1 + m.values.map(depth).fold(0, (int a, int b) => a > b ? a : b),
        final List<dynamic> l =>
          1 + l.map(depth).fold(0, (int a, int b) => a > b ? a : b),
        _ => 0,
      };
      expect(depth(signal.sessionDescription), lessThanOrEqualTo(17));
    });

    test('a repeated key counts once, as JSON reads it (the last)', () {
      final ZenSignal signal = fromText(
        '{"type":"msg_react","msgId":"a","emoji":"x","msgId":"b",'
        '"groupId":"g","author":"200::2","author":"200::3"}',
      )!;
      expect(signal.messageId, 'b');
      expect(signal.chatExtras![kChangeAuthorKey], '200::3');
    });
  });

  group('the author of the message a change means', () {
    ZenSignal parse(Map<String, dynamic> payload) =>
        zenSignalFromTransportPayload(sender: '200::1', payload: payload)!;

    test('a reaction and a deletion carry it, normalised', () {
      final ZenSignal react = parse(<String, dynamic>{
        'type': 'msg_react',
        'groupId': 'g',
        'msgId': 'm',
        'emoji': '👍',
        kChangeAuthorKey: ' 200:0:0:0:0:0:0:B0B ',
      });
      final String bob = PeerShareCodec.normalizeAddress('200::b0b');
      expect(react.chatExtras, <String, dynamic>{
        'emoji': '👍',
        kChangeAuthorKey: bob,
      });
      final ZenSignal delete = parse(<String, dynamic>{
        'type': 'msg_delete',
        'groupId': 'g',
        'msgId': 'm',
        kChangeAuthorKey: '200::b0b',
      });
      expect(delete.chatExtras, <String, dynamic>{kChangeAuthorKey: bob});
    });

    test('a signal from Zen 1.16.4 (without it) reads as before', () {
      final ZenSignal react = parse(<String, dynamic>{
        'type': 'msg_react',
        'groupId': 'g',
        'msgId': 'm',
        'emoji': '👍',
      });
      expect(react.chatExtras, <String, dynamic>{'emoji': '👍'});
      final ZenSignal delete = parse(<String, dynamic>{
        'type': 'msg_delete',
        'groupId': 'g',
        'msgId': 'm',
        'at': 5,
      });
      expect(delete.chatExtras, isNull);
      expect(delete.sentAtMillis, 5);
    });

    test('one that names nobody is absent; a huge one drops the signal', () {
      for (final Object? author in <Object?>['', '  ', 'self', 'SELF', 7]) {
        expect(
          parse(<String, dynamic>{
            'type': 'msg_delete',
            'groupId': 'g',
            'msgId': 'm',
            kChangeAuthorKey: author,
          }).chatExtras,
          isNull,
          reason: '$author',
        );
      }
      expect(
        zenSignalFromTransportPayload(
          sender: '200::1',
          payload: <String, dynamic>{
            'type': 'msg_react',
            'groupId': 'g',
            'msgId': 'm',
            'emoji': '👍',
            kChangeAuthorKey: 'a' * (kMaxSignalIdChars + 1),
          },
        ),
        isNull,
      );
      // An edit is its author's own: it takes none.
      expect(
        parse(<String, dynamic>{
          'type': 'msg_edit',
          'msgId': 'm',
          'text': 'b',
          kChangeAuthorKey: '200::b0b',
        }).chatExtras,
        isNull,
      );
    });
  });
}
