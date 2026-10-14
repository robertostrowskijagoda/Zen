import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';

/// A group call this device knows is running, whether or not the user is in
/// it. Kept only in memory: every participant announces itself periodically,
/// so the picture rebuilds itself within one heartbeat after a restart.
@immutable
final class OngoingGroupCall {
  const OngoingGroupCall({
    required this.groupId,
    required this.callId,
    required this.kind,
    required this.startedAtMillis,
    this.participants = const <String, int>{},
    this.departed = const <String>{},
    this.cameraOn = const <String>{},
  });

  final String groupId;
  final String callId;
  final CallInviteKind kind;
  final int startedAtMillis;

  /// Remote participants by address, with when each was last heard from.
  final Map<String, int> participants;

  /// People who left (or went silent). Only their own signal brings them
  /// back; someone else's stale participant list must not.
  final Set<String> departed;

  /// Participants whose camera is on.
  final Set<String> cameraOn;

  bool get isEmpty => participants.isEmpty;

  List<String> get participantAddresses {
    final List<String> sorted = participants.keys.toList()..sort();
    return sorted;
  }

  OngoingGroupCall copyWith({
    CallInviteKind? kind,
    Map<String, int>? participants,
    Set<String>? departed,
    Set<String>? cameraOn,
  }) {
    return OngoingGroupCall(
      groupId: groupId,
      callId: callId,
      kind: kind ?? this.kind,
      startedAtMillis: startedAtMillis,
      participants: participants ?? this.participants,
      departed: departed ?? this.departed,
      cameraOn: cameraOn ?? this.cameraOn,
    );
  }
}
