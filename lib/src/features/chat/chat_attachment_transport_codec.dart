import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/runtime/zstd_frame_guard.dart';
import 'package:zstandard/zstandard.dart';

const int kInlineAttachmentTransportMaxBytes = 1024 * 1024;
const int _compressionThresholdBytes = 1024;
const int _compressionLevel = 4;

final Provider<ChatAttachmentTransportCodec>
chatAttachmentTransportCodecProvider = Provider<ChatAttachmentTransportCodec>((
  Ref ref,
) {
  return ChatAttachmentTransportCodec();
});

final class EncodedChatAttachment {
  const EncodedChatAttachment({required this.base64Data, this.encoding});

  final String base64Data;
  final String? encoding;
}

final class ChatAttachmentTransportCodec {
  ChatAttachmentTransportCodec({Zstandard? zstandard})
    : _zstandard = zstandard ?? Zstandard();

  final Zstandard _zstandard;

  Future<EncodedChatAttachment> encode(
    Uint8List bytes, {
    ChatMessageType? type,
    String? mimeType,
    String? fileName,
  }) async {
    Uint8List transportBytes = bytes;
    String? encoding;

    if (!_shouldSkipCompression(
          type: type,
          mimeType: mimeType,
          fileName: fileName,
        ) &&
        bytes.length >= _compressionThresholdBytes) {
      final Uint8List? compressed = await _zstandard.compress(
        bytes,
        _compressionLevel,
      );
      if (compressed != null &&
          compressed.isNotEmpty &&
          compressed.length + 32 < bytes.length) {
        transportBytes = compressed;
        encoding = 'zstd';
      }
    }

    if (transportBytes.length > kInlineAttachmentTransportMaxBytes) {
      throw const FormatException(
        'Załącznik jest za duży do wysłania inline. Chunking przyjdzie w kolejnym kroku.',
      );
    }

    return EncodedChatAttachment(
      base64Data: base64Encode(transportBytes),
      encoding: encoding,
    );
  }

  Future<Uint8List> decode({
    required String base64Data,
    String? encoding,
  }) async {
    final Uint8List transportBytes = Uint8List.fromList(
      base64Decode(base64Data),
    );
    if (encoding == null || encoding.isEmpty) {
      return transportBytes;
    }
    if (encoding != 'zstd') {
      throw FormatException(
        t('Nieobsługiwane kodowanie załącznika: {encoding}', {
          'encoding': encoding,
        }),
      );
    }
    // A peer controls these bytes: a few kilobytes of crafted zstd could
    // otherwise expand to gigabytes. No real attachment is larger than what
    // this app can store (see [kMaxIncomingAttachmentBytes]).
    final Uint8List decoded;
    try {
      decoded = await boundedZstdDecompress(
        transportBytes,
        maxBytes: kMaxIncomingAttachmentBytes,
        decompress: _zstandard.decompress,
      );
    } on FormatException {
      throw FormatException(t('Nie udało się rozpakować załącznika.'));
    }
    if (decoded.isEmpty) {
      throw FormatException(t('Nie udało się rozpakować załącznika.'));
    }
    return decoded;
  }

  ChatMessageType inferType({String? mimeType, String? fileName}) {
    final String normalizedMime = mimeType?.toLowerCase() ?? '';
    final String normalizedName = fileName?.toLowerCase() ?? '';
    if (normalizedMime.startsWith('image/') ||
        normalizedName.endsWith('.png') ||
        normalizedName.endsWith('.jpg') ||
        normalizedName.endsWith('.jpeg') ||
        normalizedName.endsWith('.webp') ||
        normalizedName.endsWith('.gif') ||
        normalizedName.endsWith('.bmp')) {
      return ChatMessageType.image;
    }
    if (normalizedMime.startsWith('audio/') ||
        normalizedName.endsWith('.m4a') ||
        normalizedName.endsWith('.aac') ||
        normalizedName.endsWith('.mp3') ||
        normalizedName.endsWith('.ogg') ||
        normalizedName.endsWith('.opus') ||
        normalizedName.endsWith('.wav')) {
      return ChatMessageType.voice;
    }
    if (normalizedMime.startsWith('video/') ||
        normalizedName.endsWith('.mp4') ||
        normalizedName.endsWith('.mov') ||
        normalizedName.endsWith('.m4v') ||
        normalizedName.endsWith('.webm') ||
        normalizedName.endsWith('.mkv') ||
        normalizedName.endsWith('.avi') ||
        normalizedName.endsWith('.3gp')) {
      return ChatMessageType.video;
    }
    return ChatMessageType.file;
  }

  bool _shouldSkipCompression({
    ChatMessageType? type,
    String? mimeType,
    String? fileName,
  }) {
    final ChatMessageType resolvedType =
        type ?? inferType(mimeType: mimeType, fileName: fileName);
    // Compressed already (a GIF, a JPEG, a film, a voice message): zstd
    // would only spend the phone's time.
    return resolvedType == ChatMessageType.image ||
        resolvedType == ChatMessageType.voice ||
        resolvedType == ChatMessageType.video;
  }
}
