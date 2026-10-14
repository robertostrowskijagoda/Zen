import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/chat_attachment_transport_codec.dart';

void main() {
  test('attachment transport codec round-trips inline bytes', () async {
    final ChatAttachmentTransportCodec codec = ChatAttachmentTransportCodec();
    final Uint8List payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

    final EncodedChatAttachment encoded = await codec.encode(payload);
    final Uint8List decoded = await codec.decode(
      base64Data: encoded.base64Data,
      encoding: encoded.encoding,
    );

    expect(decoded, <int>[1, 2, 3, 4, 5]);
  });

  test('attachment transport codec infers image types from metadata', () {
    final ChatAttachmentTransportCodec codec = ChatAttachmentTransportCodec();

    expect(
      codec.inferType(mimeType: 'image/png', fileName: 'foto.png'),
      ChatMessageType.image,
    );
    expect(
      codec.inferType(mimeType: 'audio/mp4', fileName: 'voice.m4a'),
      ChatMessageType.voice,
    );
    expect(
      codec.inferType(mimeType: 'video/mp4', fileName: 'clip.mp4'),
      ChatMessageType.video,
    );
    expect(codec.inferType(fileName: 'raport.txt'), ChatMessageType.file);
  });
}
