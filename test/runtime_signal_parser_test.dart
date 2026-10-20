import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';

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
}
