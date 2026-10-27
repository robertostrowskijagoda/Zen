import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

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
  void initState() {
    super.initState();
    // Followed here, not with `ref.watch` in build: this bridge lives in the
    // app's first screen, and a watch pauses while another screen covers it.
    // The app is often left on a chat, and a tapped notification then did
    // nothing until the person went back - and opened its chat only then.
    ref.listenManual<RuntimeRouteIntent?>(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.pendingLaunchIntent,
      ),
      (RuntimeRouteIntent? previous, RuntimeRouteIntent? next) =>
          _schedule(next),
      fireImmediately: true,
    );
  }

  void _schedule(RuntimeRouteIntent? intent) {
    if (intent == null ||
        intent.id == _scheduledIntentId ||
        intent.id == _handledIntentId) {
      return;
    }
    _scheduledIntentId = intent.id;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _handlePendingIntent(intent);
      })
      // Nothing else may be drawing (the screen on top did not change).
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => widget.child;

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
        // Inbox entries live at the top of the chats list, and so do the
        // conversations with something new. The locked service's notices
        // ("Nowa wiadomość") all come here: whatever screen the app was
        // left on, it may say nothing of what came.
        _showChats();
        break;
      case RuntimeRouteTarget.conversation:
        final ({String address, String title}) chat =
            runtimeRouteConversationOf(
              intent.peerAddress!,
              ref.read(socialHubControllerProvider),
            );
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => ConversationScreen(
              peerAddress: chat.address,
              title: chat.title,
            ),
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
          // The call is gone (missed, cancelled, or already torn down): the
          // chats list, where the conversation tells what happened.
          _showChats();
          break;
        }
        final bool ringingIncoming =
            session.isIncoming && session.status == CallSessionStatus.ringing;
        if (ringingIncoming &&
            (!intent.autoAcceptCall || !intent.answersCall(session.id))) {
          // Not answered from the card, or answered for another call from
          // the same person: the overlay asks.
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
          _showChats();
          break;
        }
        if (!mounted) {
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => GroupConversationScreen(
              groupId: groupId,
              groupName: title,
              // A mention's notification: at the message.
              initialMessageId: intent.messageId,
            ),
          ),
        );
        break;
      case RuntimeRouteTarget.feed:
        // The pyramid's posts' notification: the Tablica on that filter;
        // a new post's notification: the Tablica at that post. Whatever
        // screen the app was left on would otherwise cover it.
        Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
        openFeed(FeedFilter.parse(intent.rawInput), postId: intent.postId);
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
      case RuntimeRouteTarget.flatKnocks:
        // "Ktoś puka do drzwi": the knocks wait at the top of Sąsiedzi.
        unawaited(NeighborsScreen.open(context));
        break;
      case RuntimeRouteTarget.updates:
        // "Jest nowa wersja Zen": where "Aktualizuj" is.
        unawaited(UpdatesScreen.open(context));
        break;
    }
    _handledIntentId = handledId;
    _scheduledIntentId = null;
  }

  /// Back to the chats list from wherever the app was left (screens opened
  /// over it, another tab of the rail).
  void _showChats() {
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
    openShellTab('chats');
  }
}

/// The conversation a route to [peerAddress] opens: the friend's own entry
/// when the address is one of theirs (the chat is kept under it, so another
/// spelling of the address would open an empty chat), with the app's own
/// name for them. The title in a route is whatever the link said - `zen://`
/// links can come from any web page or app - so it is never shown; someone
/// the app does not know gets their share code (the screen marks them as a
/// stranger).
@visibleForTesting
({String address, String title}) runtimeRouteConversationOf(
  String peerAddress,
  SocialHubState state,
) {
  final FriendProfile? friend = state.friendByAddress(peerAddress);
  return (
    address: friend?.address ?? PeerShareCodec.normalizeAddress(peerAddress),
    title:
        friend?.displayLabel ??
        PeerShareCodec.displayNameForAddress(peerAddress),
  );
}
