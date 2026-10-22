import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Enums stored (on disk or on the wire) by their index, with the order
/// they had in 1.12.0. A value may be added at the end; one in the middle,
/// a removal or a rename changes what every file written before means —
/// "delivered" read back as something else. Never edit a list here.
const Map<String, List<String>> _pinned = <String, List<String>>{
  'AppVisibilityState': <String>[
    'detached',
    'background',
    'hidden',
    'foreground',
    'foregroundFocused',
  ],
  'FriendRelationshipStatus': <String>[
    'none',
    'pendingIncoming',
    'pendingOutgoing',
    'accepted',
    'blocked',
  ],
  'InboxEntryType': <String>[
    'friendRequest',
    'friendAccepted',
    'friendRemoved',
    'transferCancelled',
    'message',
    'callInvite',
    'friendRejected',
    'friendCancelled',
    'groupInvite',
  ],
  'CallInviteKind': <String>['audio', 'video'],
  'CallSessionStatus': <String>['ringing', 'active', 'connecting'],
  'RuntimeRouteTarget': <String>[
    'inbox',
    'conversation',
    'call',
    'addFriend',
    'groupConversation',
    'flatDoor',
    'feed',
    'flatKnocks',
  ],
  'ChatMessageDirection': <String>['incoming', 'outgoing', 'system'],
  'ChatMessageDeliveryState': <String>[
    'none',
    'sending',
    'sent',
    'delivered',
    'failed',
  ],
  'ChatMessageType': <String>['text', 'image', 'file', 'voice', 'video'],
  'ZenSignalType': <String>[
    'ack',
    'messageRead',
    'message',
    'friendRequest',
    'friendAccept',
    'friendRemove',
    'transferCancel',
    'transferOffer',
    'transferAnswer',
    'deepLink',
    'callInvite',
    'callOffer',
    'callAnswer',
    'callRinging',
    'callAccept',
    'callDecline',
    'callBusy',
    'callEnd',
    'presence',
    'unknown',
    'friendReject',
    'friendCancel',
    'messageChunk',
    'messageChunkAck',
    'callOfferRequest',
    'groupMessage',
    'groupInvite',
    'groupUpdate',
    'groupLeave',
    'groupCallInvite',
    'typing',
    'groupInviteAck',
    'groupCallJoin',
    'groupCallLeave',
    'groupCallState',
    'groupCallOffer',
    'groupCallAnswer',
    'groupCallDecline',
    'profileUpdate',
    'disappearTimer',
    'messageReaction',
    'messageEdit',
    'messageDelete',
  ],
};

List<String> _names(List<Enum> values) => <String>[
  for (final Enum value in values) value.name,
];

void main() {
  final Map<String, List<Enum>> now = <String, List<Enum>>{
    'AppVisibilityState': AppVisibilityState.values,
    'FriendRelationshipStatus': FriendRelationshipStatus.values,
    'InboxEntryType': InboxEntryType.values,
    'CallInviteKind': CallInviteKind.values,
    'CallSessionStatus': CallSessionStatus.values,
    'RuntimeRouteTarget': RuntimeRouteTarget.values,
    'ChatMessageDirection': ChatMessageDirection.values,
    'ChatMessageDeliveryState': ChatMessageDeliveryState.values,
    'ChatMessageType': ChatMessageType.values,
    'ZenSignalType': ZenSignalType.values,
  };

  for (final MapEntry<String, List<String>> e in _pinned.entries) {
    test('${e.key} keeps the order it is stored in', () {
      final List<String> names = _names(now[e.key]!);
      expect(
        names.take(e.value.length).toList(),
        e.value,
        reason: '${e.key} is stored by index: add new values at the end only',
      );
    });
  }
}
