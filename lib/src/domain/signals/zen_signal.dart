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
    this.gifUrl,
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
  final String? gifUrl;
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

  /// Disappearing messages (§14.1 point 10): the sender's timer for this
  /// conversation, in seconds (0 = off). Carried by messages and by the
  /// `disappear_timer` signal.
  final int? disappearSeconds;

  ZenSignal withSender(String sender) {
    if (sender == this.sender) {
      return this;
    }
    return ZenSignal(
      type: type,
      sender: sender,
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
      gifUrl: gifUrl,
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
    );
  }
}
