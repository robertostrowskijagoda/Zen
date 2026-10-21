import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';

enum ChatMessageDirection { incoming, outgoing, system }

enum ChatMessageDeliveryState { none, sending, sent, delivered, failed }

enum ChatMessageType { text, image, file, voice, video }

const Object _chatMessageUnset = Object();

@immutable
final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.sentAtMillis,
    required this.direction,
    this.type = ChatMessageType.text,
    this.attachmentBytes,
    this.attachmentPath,
    this.fileName,
    this.mimeType,
    this.attachmentSizeBytes,
    this.durationMs,
    this.deliveryState = ChatMessageDeliveryState.none,
    this.readAtMillis,
    this.expiresAtMillis,
  });

  final String id;
  final String sender;
  final String text;
  final int sentAtMillis;
  final ChatMessageDirection direction;
  final ChatMessageType type;
  final Uint8List? attachmentBytes;
  final String? attachmentPath;
  final String? fileName;
  final String? mimeType;
  final int? attachmentSizeBytes;
  final int? durationMs;
  final ChatMessageDeliveryState deliveryState;
  final int? readAtMillis;

  /// When a disappearing message is deleted; `null` for
  /// messages that stay.
  final int? expiresAtMillis;

  bool get disappears => expiresAtMillis != null;

  bool isExpiredAt(int nowMillis) {
    final int? at = expiresAtMillis;
    return at != null && nowMillis >= at;
  }

  bool get isOutgoing => direction == ChatMessageDirection.outgoing;

  bool get isSystem => direction == ChatMessageDirection.system;

  bool get isRead => readAtMillis != null;

  bool get hasAttachment =>
      (attachmentBytes != null && attachmentBytes!.isNotEmpty) ||
      (attachmentPath?.trim().isNotEmpty ?? false);

  bool get isImageAttachment => type == ChatMessageType.image && hasAttachment;

  bool get isFileAttachment => type == ChatMessageType.file && hasAttachment;

  bool get isVoiceAttachment => type == ChatMessageType.voice;

  bool get isVideoAttachment => type == ChatMessageType.video;

  bool get isGif =>
      (mimeType?.toLowerCase() == 'image/gif') ||
      (fileName?.toLowerCase().endsWith('.gif') ?? false) ||
      (attachmentPath?.toLowerCase().endsWith('.gif') ?? false);

  ChatMessage copyWith({
    String? id,
    String? sender,
    String? text,
    int? sentAtMillis,
    ChatMessageDirection? direction,
    ChatMessageType? type,
    Object? attachmentBytes = _chatMessageUnset,
    Object? attachmentPath = _chatMessageUnset,
    Object? fileName = _chatMessageUnset,
    Object? mimeType = _chatMessageUnset,
    Object? attachmentSizeBytes = _chatMessageUnset,
    Object? durationMs = _chatMessageUnset,
    Object? readAtMillis = _chatMessageUnset,
    Object? expiresAtMillis = _chatMessageUnset,
    ChatMessageDeliveryState? deliveryState,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      sender: sender ?? this.sender,
      text: text ?? this.text,
      sentAtMillis: sentAtMillis ?? this.sentAtMillis,
      direction: direction ?? this.direction,
      type: type ?? this.type,
      attachmentBytes: identical(attachmentBytes, _chatMessageUnset)
          ? this.attachmentBytes
          : castCopyWithValue<Uint8List>(
              attachmentBytes,
              fieldName: 'attachmentBytes',
            ),
      attachmentPath: identical(attachmentPath, _chatMessageUnset)
          ? this.attachmentPath
          : castCopyWithValue<String>(
              attachmentPath,
              fieldName: 'attachmentPath',
            ),
      fileName: identical(fileName, _chatMessageUnset)
          ? this.fileName
          : castCopyWithValue<String>(fileName, fieldName: 'fileName'),
      mimeType: identical(mimeType, _chatMessageUnset)
          ? this.mimeType
          : castCopyWithValue<String>(mimeType, fieldName: 'mimeType'),
      attachmentSizeBytes: identical(attachmentSizeBytes, _chatMessageUnset)
          ? this.attachmentSizeBytes
          : castCopyWithValue<int>(
              attachmentSizeBytes,
              fieldName: 'attachmentSizeBytes',
            ),
      durationMs: identical(durationMs, _chatMessageUnset)
          ? this.durationMs
          : castCopyWithValue<int>(durationMs, fieldName: 'durationMs'),
      readAtMillis: identical(readAtMillis, _chatMessageUnset)
          ? this.readAtMillis
          : castCopyWithValue<int>(readAtMillis, fieldName: 'readAtMillis'),
      expiresAtMillis: identical(expiresAtMillis, _chatMessageUnset)
          ? this.expiresAtMillis
          : castCopyWithValue<int>(
              expiresAtMillis,
              fieldName: 'expiresAtMillis',
            ),
      deliveryState: deliveryState ?? this.deliveryState,
    );
  }
}

String chatMessageLabelForType(
  ChatMessageType type, {
  String? fileName,
  String? mimeType,
}) {
  return switch (type) {
    ChatMessageType.text => '',
    ChatMessageType.image =>
      (mimeType?.toLowerCase() == 'image/gif' ||
              (fileName?.toLowerCase().endsWith('.gif') ?? false))
          ? '🎞 GIF'
          : t('📷 Zdjęcie'),
    ChatMessageType.file => fileName == null ? t('📎 Plik') : '📎 $fileName',
    ChatMessageType.voice => t('🎤 Wiadomość głosowa'),
    ChatMessageType.video => t('🎬 Wideo'),
  };
}

String formatAttachmentSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
