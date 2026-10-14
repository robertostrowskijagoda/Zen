import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';

enum CallSessionStatus { ringing, active, connecting }

@immutable
final class CallSession {
  const CallSession({
    required this.id,
    required this.peerAddress,
    required this.displayName,
    required this.kind,
    required this.status,
    required this.startedAtMillis,
    this.isIncoming = false,
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.isCameraEnabled = false,
    this.isGroup = false,
    this.groupId,
    this.participantAddresses = const <String>[],
    this.acceptToken,
  });

  final String id;
  final String peerAddress;
  final String displayName;
  final CallInviteKind kind;
  final CallSessionStatus status;
  final int startedAtMillis;
  final bool isIncoming;
  final bool isMuted;
  final bool isSpeakerOn;
  final bool isCameraEnabled;
  final bool isGroup;
  final String? groupId;
  final List<String> participantAddresses;

  /// Secret of an incoming ringing call: the route that answers it from the
  /// native call card must carry it, so that no link from outside the app
  /// can pick the call up. Local only, never sent to the peer.
  final String? acceptToken;

  String get kindLabel => kind == CallInviteKind.video ? 'wideo' : 'audio';

  CallSession copyWith({
    String? id,
    String? peerAddress,
    String? displayName,
    CallInviteKind? kind,
    CallSessionStatus? status,
    int? startedAtMillis,
    bool? isIncoming,
    bool? isMuted,
    bool? isSpeakerOn,
    bool? isCameraEnabled,
    bool? isGroup,
    String? groupId,
    List<String>? participantAddresses,
    String? acceptToken,
  }) {
    return CallSession(
      id: id ?? this.id,
      peerAddress: peerAddress ?? this.peerAddress,
      displayName: displayName ?? this.displayName,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      startedAtMillis: startedAtMillis ?? this.startedAtMillis,
      isIncoming: isIncoming ?? this.isIncoming,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      isCameraEnabled: isCameraEnabled ?? this.isCameraEnabled,
      isGroup: isGroup ?? this.isGroup,
      groupId: groupId ?? this.groupId,
      participantAddresses: participantAddresses ?? this.participantAddresses,
      acceptToken: acceptToken ?? this.acceptToken,
    );
  }
}
