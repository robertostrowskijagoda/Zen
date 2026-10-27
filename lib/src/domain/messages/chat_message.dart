import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';

enum ChatMessageDirection { incoming, outgoing, system }

enum ChatMessageDeliveryState { none, sending, sent, delivered, failed }

enum ChatMessageType { text, image, file, voice, video }

const Object _chatMessageUnset = Object();

/// Longest piece of the original's text a reply carries (shown while the
/// original is not at hand).
const int kMaxReplySnippetChars = 200;

/// How long after sending one's own message can still be edited.
const Duration kChatEditWindow = Duration(hours: 24);

/// Most different people's reactions kept on one message.
const int kMaxReactionsPerMessage = 256;

/// The longest reaction taken (one emoji, maybe with modifiers).
const int kMaxReactionChars = 16;

/// What a reply quotes.
@immutable
final class ChatReply {
  const ChatReply({required this.messageId, this.sender = '', this.text = ''});

  /// Id of the message replied to (in the same conversation).
  final String messageId;

  /// Who wrote it (`self`, an address), for the quote.
  final String sender;

  /// The start of its text; empty for a message that disappears (the quote
  /// then shows only while the original is still there).
  final String text;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': messageId,
    if (sender.isNotEmpty) 's': sender,
    if (text.isNotEmpty) 't': text,
  };

  static ChatReply? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? sender = json['s'];
    final Object? text = json['t'];
    if (id is! String || id.isEmpty || id.length > 256) {
      return null;
    }
    return ChatReply(
      messageId: id,
      sender: sender is String && sender.length <= 256 ? sender : '',
      text: text is String ? clipChatSnippet(text) : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatReply &&
      other.messageId == messageId &&
      other.sender == sender &&
      other.text == text;

  @override
  int get hashCode => Object.hash(messageId, sender, text);
}

/// [text] cut to [kMaxReplySnippetChars] (never inside a surrogate pair),
/// on one line.
String clipChatSnippet(String text) {
  final String line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (line.length <= kMaxReplySnippetChars) {
    return line;
  }
  int end = kMaxReplySnippetChars;
  final int last = line.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    end -= 1;
  }
  return '${line.substring(0, end)}…';
}

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
    this.reply,
    this.reactions = const <String, String>{},
    this.editedAtMillis,
    this.deletedAtMillis,
    this.forwarded = false,
    this.pendingMedia,
    this.attachmentUnavailable = false,
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

  /// The message this one answers.
  final ChatReply? reply;

  /// Reactions: who (`self` or an address) → emoji, one per person.
  final Map<String, String> reactions;

  /// When its author last edited it (the earlier text is not kept).
  final int? editedAtMillis;

  /// When its author (or a group's creator) deleted it for everyone: the
  /// content is gone, a note stays in its place.
  final int? deletedAtMillis;

  /// Passed on from another conversation.
  final bool forwarded;

  /// A file a group member shared as content-addressed blocks
  /// (`chat_media_blocks.dart`): its reference until it is downloaded.
  final Map<String, dynamic>? pendingMedia;

  /// A file message whose file will not come: nobody this device can ask
  /// still has it (a recovered conversation, a file the account's other
  /// device lost). Not the same as a file still on its way.
  final bool attachmentUnavailable;

  bool get isEdited => editedAtMillis != null;

  bool get isDeleted => deletedAtMillis != null;

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
    Object? reply = _chatMessageUnset,
    Map<String, String>? reactions,
    Object? editedAtMillis = _chatMessageUnset,
    Object? deletedAtMillis = _chatMessageUnset,
    bool? forwarded,
    Object? pendingMedia = _chatMessageUnset,
    bool? attachmentUnavailable,
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
      reply: identical(reply, _chatMessageUnset)
          ? this.reply
          : castCopyWithValue<ChatReply>(reply, fieldName: 'reply'),
      reactions: reactions ?? this.reactions,
      editedAtMillis: identical(editedAtMillis, _chatMessageUnset)
          ? this.editedAtMillis
          : castCopyWithValue<int>(editedAtMillis, fieldName: 'editedAtMillis'),
      deletedAtMillis: identical(deletedAtMillis, _chatMessageUnset)
          ? this.deletedAtMillis
          : castCopyWithValue<int>(
              deletedAtMillis,
              fieldName: 'deletedAtMillis',
            ),
      forwarded: forwarded ?? this.forwarded,
      pendingMedia: identical(pendingMedia, _chatMessageUnset)
          ? this.pendingMedia
          : castCopyWithValue<Map<String, dynamic>>(
              pendingMedia,
              fieldName: 'pendingMedia',
            ),
      attachmentUnavailable:
          attachmentUnavailable ?? this.attachmentUnavailable,
    );
  }

  /// [this] deleted for everyone at [atMillis]: no text, no file, no
  /// quote and no reactions left.
  ChatMessage deletedAt(int atMillis) => ChatMessage(
    id: id,
    sender: sender,
    text: '',
    sentAtMillis: sentAtMillis,
    direction: direction,
    deliveryState: deliveryState,
    readAtMillis: readAtMillis,
    expiresAtMillis: expiresAtMillis,
    deletedAtMillis: atMillis,
  );
}

/// What [m] has beyond the basic fields (reply, reactions, edit, deletion,
/// forwarding, a file still to fetch, a file that will not come), for
/// storage and copies; `null` when there is nothing.
Map<String, dynamic>? chatMessageExtrasToJson(ChatMessage m) {
  final Map<String, dynamic> out = <String, dynamic>{
    if (m.reply != null) 're': m.reply!.toJson(),
    if (m.reactions.isNotEmpty) 'rx': m.reactions,
    'ed': ?m.editedAtMillis,
    'del': ?m.deletedAtMillis,
    if (m.forwarded) 'fwd': true,
    'pm': ?m.pendingMedia,
    if (m.attachmentUnavailable) 'nf': true,
  };
  return out.isEmpty ? null : out;
}

/// [m] with the extras [json] describes (see [chatMessageExtrasToJson]).
ChatMessage chatMessageWithExtras(ChatMessage m, Object? json) {
  if (json is! Map) {
    return m;
  }
  final Object? rx = json['rx'];
  final Object? edited = json['ed'];
  final Object? deleted = json['del'];
  final Object? pending = json['pm'];
  return m.copyWith(
    reply: ChatReply.fromJson(json['re']),
    reactions: <String, String>{
      if (rx is Map)
        for (final MapEntry<dynamic, dynamic> e in rx.entries.take(
          kMaxReactionsPerMessage,
        ))
          if (e.key is String &&
              e.value is String &&
              (e.value as String).isNotEmpty &&
              (e.value as String).length <= kMaxReactionChars)
            e.key as String: e.value as String,
    },
    editedAtMillis: edited is int ? edited : null,
    deletedAtMillis: deleted is int ? deleted : null,
    forwarded: json['fwd'] == true,
    pendingMedia: pending is Map ? Map<String, dynamic>.from(pending) : null,
    attachmentUnavailable: json['nf'] == true,
  );
}

/// [m] as it comes back from a copy without its file: a file message is
/// marked as one whose file will not come from there (see
/// [ChatMessage.attachmentUnavailable]); anything else — and a group file
/// still to be fetched from its members — stays as it is.
ChatMessage chatMessageWithoutFile(ChatMessage m) =>
    m.type == ChatMessageType.text ||
        m.isDeleted ||
        m.hasAttachment ||
        m.pendingMedia != null
    ? m
    : m.copyWith(attachmentUnavailable: true);

bool _isGifMedia(String? fileName, String? mimeType) =>
    mimeType?.toLowerCase() == 'image/gif' ||
    (fileName?.toLowerCase().endsWith('.gif') ?? false);

/// The line a conversation preview, a notification or an inbox entry shows
/// for a message whose text is [text]: a message with an attachment (photo,
/// GIF, video, voice message, file) shows only the label of its [type] -
/// never the sender's caption or the file name (a plain file's label
/// carries its name); a text message keeps [text].
String chatPreviewLine(
  String text, {
  ChatMessageType? type,
  String? fileName,
  String? mimeType,
}) {
  if (type == null || type == ChatMessageType.text) {
    return text;
  }
  return chatMessageLabelForType(type, fileName: fileName, mimeType: mimeType);
}

String chatMessageLabelForType(
  ChatMessageType type, {
  String? fileName,
  String? mimeType,
}) {
  return switch (type) {
    ChatMessageType.text => '',
    ChatMessageType.image =>
      _isGifMedia(fileName, mimeType) ? '🎞 GIF' : t('📷 Zdjęcie'),
    ChatMessageType.file =>
      (fileName?.trim().isEmpty ?? true) ? t('📎 Plik') : '📎 $fileName',
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
