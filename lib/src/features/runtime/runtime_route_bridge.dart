import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

class RuntimeRouteBridge extends ConsumerStatefulWidget {
  const RuntimeRouteBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RuntimeRouteBridge> createState() => _RuntimeRouteBridgeState();
}

final class _RuntimeRouteBridgeState extends ConsumerState<RuntimeRouteBridge> {
  String? _scheduledIntentId;
  String? _handledIntentId;

  @override
  Widget build(BuildContext context) {
    final RuntimeRouteIntent? pendingLaunchIntent = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.pendingLaunchIntent,
      ),
    );
    if (pendingLaunchIntent != null &&
        pendingLaunchIntent.id != _scheduledIntentId &&
        pendingLaunchIntent.id != _handledIntentId) {
      _scheduledIntentId = pendingLaunchIntent.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handlePendingIntent(pendingLaunchIntent);
      });
    }
    return widget.child;
  }

  Future<void> _handlePendingIntent(RuntimeRouteIntent intent) async {
    if (!mounted) {
      return;
    }
    final SocialHubController socialHub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final String handledId = intent.id;
    await socialHub.clearPendingLaunchIntent();
    if (!mounted) {
      return;
    }
    switch (intent.target) {
      case RuntimeRouteTarget.inbox:
        // Inbox entries live at the top of the single chats list, so there
        // is nothing to navigate to — the entries are already visible.
        break;
      case RuntimeRouteTarget.conversation:
        final String peerAddress = intent.peerAddress!;
        final SocialHubState socialState = ref.read(
          socialHubControllerProvider,
        );
        // The title in a route is whatever the link said - `zen://` links
        // can come from any web page or app. Only the app's own name for the
        // peer is shown; someone it does not know gets their share code
        // (the screen marks them as a stranger), never a name a link chose.
        final String title =
            socialState.friendByAddress(peerAddress)?.displayLabel ??
            PeerShareCodec.displayNameForAddress(peerAddress);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                ConversationScreen(peerAddress: peerAddress, title: title),
          ),
        );
        break;
      case RuntimeRouteTarget.call:
        final String peerAddress = intent.peerAddress!;
        final CallSession? session = ref
            .read(socialHubControllerProvider)
            .activeCall;
        final bool matchesCall =
            session != null &&
            PeerShareCodec.addressesEqual(session.peerAddress, peerAddress);
        if (!matchesCall) {
          // The call is gone (missed, cancelled, or already torn down), so
          // there is nothing to open.
          break;
        }
        final bool ringingIncoming =
            session.isIncoming && session.status == CallSessionStatus.ringing;
        if (ringingIncoming &&
            (!intent.autoAcceptCall || !intent.answersCall(session.id))) {
          // Not answered from the card, or answered for another call from
          // the same person (STAN S17): the overlay asks.
          // `IncomingCallLayer` already covers every route with the
          // accept/decline overlay; pushing under it would only leave a stray
          // surface behind once the user decides.
          break;
        }
        // The session's own label, never one a link supplied.
        final String title = session.displayName;
        if (ringingIncoming) {
          // The user already answered on the system notification; the app was
          // only brought up because answering needs the microphone and a
          // renderer. Perform the accept here instead of asking a second time
          // in the in-app overlay.
          await runCallAction(
            context,
            () => socialHub.acceptIncomingCall(peerAddress: peerAddress),
          );
          if (!mounted) {
            return;
          }
        } else if (session.status == CallSessionStatus.connecting) {
          // Accept already started from the lock-screen tap; just show the
          // surface instead of running the handshake a second time.
        }
        if (session.isGroup && session.groupId != null) {
          await openGroupCallSurface(
            groupId: session.groupId!,
            groupName: title,
            initialVideo: session.kind == CallInviteKind.video,
          );
        } else {
          await openCallSurface(peerAddress: peerAddress, title: title);
        }
        break;
      case RuntimeRouteTarget.addFriend:
        await showAddFriendSheet(context, initialTargetInput: intent.rawInput);
        break;
      case RuntimeRouteTarget.groupConversation:
        final String groupId = intent.groupId ?? intent.peerAddress!;
        final SocialHubState socialState = ref.read(
          socialHubControllerProvider,
        );
        final GroupProfile? group = socialState.groups[groupId];
        final String title = group != null && group.name.trim().isNotEmpty
            ? group.name
            : t('Grupa');
        if (group == null || group.isInvitePending) {
          // A group this device has since left or declined, or an invitation
          // not answered yet: that one waits in the inbox at the top of the
          // chats list, and tapping its notification is not consent to join.
          break;
        }
        if (!mounted) {
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                GroupConversationScreen(groupId: groupId, groupName: title),
          ),
        );
        break;
      case RuntimeRouteTarget.flatDoor:
        // A door sticker's link: the neighbours section, then the knock
        // (asked first: the link can come from anywhere).
        final FlatDoorCode? code = FlatDoorCode.parse(intent.rawInput ?? '');
        if (code == null) {
          break;
        }
        unawaited(NeighborsScreen.open(context));
        await knockOnFlatDoor(
          context,
          ref.read(neighborsServiceProvider),
          code,
          ask: true,
        );
        break;
    }
    _handledIntentId = handledId;
    _scheduledIntentId = null;
  }
}
