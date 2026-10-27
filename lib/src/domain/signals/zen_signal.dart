import 'package:flutter/foundation.dart';

import 'package:zen/src/domain/messages/chat_message.dart';

enum ZenSignalType {
  ack,
  messageRead,
  message,
  friendRequest,
  friendAccept,
  friendRemove,
  transferCancel,
  transferOffer,
  transferAnswer,
  deepLink,
  callInvite,
  callOffer,
  callAnswer,
  callRinging,
  callAccept,
  callDecline,
  callBusy,
  callEnd,
  presence,
  unknown,
  friendReject,
  friendCancel,
  messageChunk,
  messageChunkAck,
  callOfferRequest,
  groupMessage,
  groupInvite,
  groupUpdate,
  groupLeave,
  groupCallInvite,
  typing,
  // Appended: the index is persisted in the signal queue.
  groupInviteAck,
  groupCallJoin,
  groupCallLeave,
  groupCallState,
  groupCallOffer,
  groupCallAnswer,
  groupCallDecline,
  profileUpdate,
  disappearTimer,
  // Reactions, edits and deletions of chat messages (`msg_react`,
  // `msg_edit`, `msg_delete`).
  messageReaction,
  messageEdit,
  messageDelete,
}

enum SignalPriority {
  criticalAck,
  friendLifecycle,
  messaging,
  transfer,
  background,
}

@immutable
final class ZenSignal {
  const ZenSignal({
    required this.type,
    required this.sender,
    this.callId,
    this.messageId,
    this.routeKey,
    this.displayName,
    this.content,
    this.messageType,
    this.attachmentData,
    this.attachmentEncoding,
    this.fileName,
    this.mimeType,
    this.attachmentSizeBytes,
    this.durationMs,
    this.isPlaceholder = false,
    this.attachmentTransferBytes,
    this.chunkIndex,
    this.chunkCount,
    this.chunkData,
    this.sessionDescription,
    this.groupId,
    this.groupName,
    this.memberAddresses,
    this.avatarPreset,
    this.bio,
    this.isTyping = false,
    this.sentAtMillis,
    this.inviteId,
    this.cameraOn,
    this.disappearSeconds,
    this.miniProfile,
    this.chatExtras,
  });

  final ZenSignalType type;
  final String sender;
  final String? callId;
  final String? messageId;
  final String? routeKey;
  final String? displayName;
  final String? content;
  final ChatMessageType? messageType;
  final String? attachmentData;
  final String? attachmentEncoding;
  final String? fileName;
  final String? mimeType;
  final int? attachmentSizeBytes;
  final int? durationMs;
  final bool isPlaceholder;
  final int? attachmentTransferBytes;
  final int? chunkIndex;
  final int? chunkCount;
  final String? chunkData;
  final Map<String, dynamic>? sessionDescription;
  final String? groupId;
  final String? groupName;
  final List<String>? memberAddresses;
  final String? avatarPreset;
  final String? bio;
  final bool isTyping;

  /// When the sender says it sent this (its own clock). Relayed mail can
  /// arrive hours later; this keeps it in its real place in the conversation.
  final int? sentAtMillis;

  /// Nonce of one explicit group invitation. Re-sends of the same invitation
  /// carry the same id, so a declined (or left) group only comes back when
  /// someone really invites again.
  final String? inviteId;

  /// Group calls: whether the sender's camera is on.
  final bool? cameraOn;

  /// Disappearing messages: the sender's timer for this
  /// conversation, in seconds (0 = off). Carried by messages and by the
  /// `disappear_timer` signal.
  final int? disappearSeconds;

  /// A message to someone who is not a friend: the sender's mini-profile
  /// (`{n: name, av: photo}`), so the person written to sees who it is.
  final Map<String, dynamic>? miniProfile;

  /// What a chat message or a change to one carries besides the basics:
  /// `re` (the message replied to), `fwd` (forwarded), `media` (a file as
  /// content-addressed blocks), `emoji` (a reaction).
  final Map<String, dynamic>? chatExtras;

  ZenSignal withSender(String sender) {
    if (sender == this.sender) {
      return this;
    }
    return _copy(sender: sender);
  }

  /// This signal carrying [chatExtras] instead.
  ZenSignal withChatExtras(Map<String, dynamic>? chatExtras) =>
      _copy(chatExtras: chatExtras);

  ZenSignal _copy({String? sender, Object? chatExtras = _unset}) {
    return ZenSignal(
      type: type,
      sender: sender ?? this.sender,
      callId: callId,
      messageId: messageId,
      routeKey: routeKey,
      displayName: displayName,
      content: content,
      messageType: messageType,
      attachmentData: attachmentData,
      attachmentEncoding: attachmentEncoding,
      fileName: fileName,
      mimeType: mimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: durationMs,
      isPlaceholder: isPlaceholder,
      attachmentTransferBytes: attachmentTransferBytes,
      chunkIndex: chunkIndex,
      chunkCount: chunkCount,
      chunkData: chunkData,
      sessionDescription: sessionDescription,
      groupId: groupId,
      groupName: groupName,
      memberAddresses: memberAddresses,
      avatarPreset: avatarPreset,
      bio: bio,
      isTyping: isTyping,
      sentAtMillis: sentAtMillis,
      inviteId: inviteId,
      cameraOn: cameraOn,
      disappearSeconds: disappearSeconds,
      miniProfile: miniProfile,
      chatExtras: identical(chatExtras, _unset)
          ? this.chatExtras
          : chatExtras as Map<String, dynamic>?,
    );
  }
}

const Object _unset = Object();
