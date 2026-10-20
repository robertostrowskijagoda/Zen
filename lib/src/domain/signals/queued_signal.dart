import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';

@immutable
final class QueuedSignal {
  const QueuedSignal({
    required this.id,
    required this.signal,
    required this.receivedAtMillis,
  });

  final String id;
  final ZenSignal signal;
  final int receivedAtMillis;

  void writeTo(BinaryWriter writer) {
    writer
      ..writeString(id)
      ..writeUint8(signal.type.index)
      ..writeString(signal.sender)
      ..writeNullableString(signal.messageId)
      ..writeNullableString(signal.routeKey)
      ..writeNullableString(signal.displayName)
      ..writeNullableString(signal.content)
      ..writeNullableString(signal.callId)
      ..writeNullableString(signal.messageType?.name)
      ..writeNullableString(signal.attachmentData)
      ..writeNullableString(signal.attachmentEncoding)
      ..writeNullableString(signal.fileName)
      ..writeNullableString(signal.mimeType)
      ..writeNullableUint32(signal.attachmentSizeBytes)
      ..writeNullableInt64(signal.durationMs)
      ..writeBool(signal.isPlaceholder)
      ..writeNullableUint32(signal.attachmentTransferBytes)
      ..writeNullableUint32(signal.chunkIndex)
      ..writeNullableUint32(signal.chunkCount)
      ..writeNullableString(signal.chunkData)
      ..writeNullableString(
        signal.sessionDescription == null
            ? null
            : jsonEncode(signal.sessionDescription),
      )
      // Everything newer travels as one JSON blob, so adding a field never
      // needs another layout change.
      ..writeNullableString(_encodeExtras(signal))
      ..writeInt64(receivedAtMillis);
  }

  static QueuedSignal readFrom(BinaryReader reader) {
    final String id = reader.readString();
    final ZenSignal base = ZenSignal(
      type: ZenSignalType.values[reader.readUint8()],
      sender: reader.readString(),
      messageId: reader.readNullableString(),
      routeKey: reader.readNullableString(),
      displayName: reader.readNullableString(),
      content: reader.readNullableString(),
      callId: reader.readNullableString(),
      messageType: _parseMessageType(reader.readNullableString()),
      attachmentData: reader.readNullableString(),
      attachmentEncoding: reader.readNullableString(),
      fileName: reader.readNullableString(),
      mimeType: reader.readNullableString(),
      attachmentSizeBytes: reader.readNullableUint32(),
      durationMs: reader.readNullableInt64(),
      isPlaceholder: reader.readBool(),
      attachmentTransferBytes: reader.readNullableUint32(),
      chunkIndex: reader.readNullableUint32(),
      chunkCount: reader.readNullableUint32(),
      chunkData: reader.readNullableString(),
      sessionDescription: _readNullableJsonMap(reader.readNullableString()),
    );
    final Map<String, dynamic>? extras = _readNullableJsonMap(
      reader.readNullableString(),
    );
    return QueuedSignal(
      id: id,
      signal: extras == null ? base : _withExtras(base, extras),
      receivedAtMillis: reader.readInt64(),
    );
  }
}

String? _encodeExtras(ZenSignal signal) {
  final Map<String, dynamic> extras = <String, dynamic>{
    'groupId': ?signal.groupId,
    'groupName': ?signal.groupName,
    'memberAddresses': ?signal.memberAddresses,
    'avatarPreset': ?signal.avatarPreset,
    'bio': ?signal.bio,
    if (signal.isTyping) 'isTyping': true,
    'sentAtMillis': ?signal.sentAtMillis,
    'inviteId': ?signal.inviteId,
    'cameraOn': ?signal.cameraOn,
    'ttl': ?signal.disappearSeconds,
  };
  return extras.isEmpty ? null : jsonEncode(extras);
}

ZenSignal _withExtras(ZenSignal base, Map<String, dynamic> extras) {
  final Object? members = extras['memberAddresses'];
  return ZenSignal(
    type: base.type,
    sender: base.sender,
    callId: base.callId,
    messageId: base.messageId,
    routeKey: base.routeKey,
    displayName: base.displayName,
    content: base.content,
    messageType: base.messageType,
    attachmentData: base.attachmentData,
    attachmentEncoding: base.attachmentEncoding,
    fileName: base.fileName,
    mimeType: base.mimeType,
    attachmentSizeBytes: base.attachmentSizeBytes,
    durationMs: base.durationMs,
    isPlaceholder: base.isPlaceholder,
    attachmentTransferBytes: base.attachmentTransferBytes,
    chunkIndex: base.chunkIndex,
    chunkCount: base.chunkCount,
    chunkData: base.chunkData,
    sessionDescription: base.sessionDescription,
    groupId: extras['groupId'] as String?,
    groupName: extras['groupName'] as String?,
    memberAddresses: members is List
        ? members.map((Object? e) => e.toString()).toList(growable: false)
        : null,
    avatarPreset: extras['avatarPreset'] as String?,
    bio: extras['bio'] as String?,
    isTyping: extras['isTyping'] == true,
    sentAtMillis: (extras['sentAtMillis'] as num?)?.toInt(),
    inviteId: extras['inviteId'] as String?,
    cameraOn: extras['cameraOn'] as bool?,
    disappearSeconds: (extras['ttl'] as num?)?.toInt(),
  );
}

ChatMessageType? _parseMessageType(String? raw) {
  return switch (raw) {
    'text' => ChatMessageType.text,
    'image' => ChatMessageType.image,
    'file' => ChatMessageType.file,
    'voice' => ChatMessageType.voice,
    'video' => ChatMessageType.video,
    _ => null,
  };
}

Map<String, dynamic>? _readNullableJsonMap(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map<dynamic, dynamic>) {
    return null;
  }
  return decoded.map<String, dynamic>((dynamic key, dynamic value) {
    return MapEntry<String, dynamic>(key.toString(), value);
  });
}
