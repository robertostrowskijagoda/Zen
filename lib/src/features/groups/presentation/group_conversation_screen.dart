import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/chat/presentation/disappearing_timer_dialog.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

final groupMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, String groupId) async {
      ref.watch(messageTimelineRevisionProvider);
      return ref.watch(messageTimelineStoreProvider).load('group:$groupId');
    });

class GroupConversationScreen extends ConsumerStatefulWidget {
  const GroupConversationScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  final String groupId;
  final String groupName;

  @override
  ConsumerState<GroupConversationScreen> createState() =>
      _GroupConversationScreenState();
}

class _GroupConversationScreenState
    extends ConsumerState<GroupConversationScreen> {
  /// Only the first viewport-worth of bubbles gets a staggered entrance —
  /// scrolling and stream updates must not replay the tween.
  static const int _entranceStaggerLimit = 10;

  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _messageEntrancePlayed = false;
  late final SocialHubController _socialHub;

  @override
  void initState() {
    super.initState();
    _socialHub = ref.read(socialHubControllerProvider.notifier);
    // Opening the chat reads it: clears the unread badge and keeps new
    // messages for this group from notifying while it is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_socialHub.enterGroupConversation(widget.groupId));
      }
    });
  }

  @override
  void dispose() {
    _socialHub.leaveGroupConversation(widget.groupId);
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _canWrite {
    final GroupProfile? group = ref
        .read(socialHubControllerProvider)
        .groupById(widget.groupId);
    return group != null && !group.isInvitePending;
  }

  Future<void> _join(GroupProfile group) async {
    await _socialHub.acceptGroupInvite(
      groupId: group.id,
      groupName: group.name,
      senderAddress: group.createdById,
    );
    if (mounted) {
      await _socialHub.enterGroupConversation(group.id);
    }
  }

  Future<void> _decline(GroupProfile group) async {
    InboxEntry? invite;
    for (final InboxEntry e in ref.read(socialHubControllerProvider).inbox) {
      if (e.type == InboxEntryType.groupInvite &&
          (e.routeKey?.contains(group.id) ?? false)) {
        invite = e;
        break;
      }
    }
    await _socialHub.rejectGroupInvite(
      groupId: group.id,
      inboxEntryId: invite?.id ?? '',
      senderAddress: group.createdById,
    );
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _confirmLeave() async {
    final ZenColors zen = ZenColors.of(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(t('Opuścić grupę?')),
        content: Text(
          t(
            'Przestaniesz dostawać wiadomości z tej grupy, a pozostali '
            'zobaczą, że wyszedłeś.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('group-leave-confirm'),
            style: FilledButton.styleFrom(backgroundColor: zen.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t('Opuść')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _socialHub.leaveGroup(groupId: widget.groupId);
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _sendMessage() async {
    final String text = _composerController.text.trim();
    if (text.isEmpty || !_canWrite) {
      return;
    }
    _composerController.clear();
    try {
      await ref
          .read(socialHubControllerProvider.notifier)
          .sendGroupMessage(groupId: widget.groupId, text: text);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Błąd wysyłania wiadomości: {error}', {'error': error}),
            ),
          ),
        );
      }
    }
  }

  Future<void> _startGroupCall(bool video) async {
    final bool started = await runCallAction(
      context,
      () => ref
          .read(socialHubControllerProvider.notifier)
          .startGroupCall(
            groupId: widget.groupId,
            kind: video ? CallInviteKind.video : CallInviteKind.audio,
          ),
    );
    if (!started || !mounted) {
      return;
    }
    await openGroupCallSurface(
      groupId: widget.groupId,
      groupName: widget.groupName,
      initialVideo: video,
    );
  }

  Future<void> _joinRunningCall() async {
    final bool joined = await runCallAction(
      context,
      () => ref
          .read(socialHubControllerProvider.notifier)
          .joinGroupCall(groupId: widget.groupId),
    );
    if (!joined || !mounted) {
      return;
    }
    await openGroupCallSurface(
      groupId: widget.groupId,
      groupName: widget.groupName,
    );
  }

  void _showAddMemberDialog(GroupProfile group) {
    final List<FriendProfile> acceptedFriends = ref
        .read(socialHubControllerProvider)
        .acceptedFriends
        .where((FriendProfile f) => !groupHasMember(group, f.address))
        .toList();

    if (acceptedFriends.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Wszyscy Twoi znajomi są już w tej grupie.'))),
      );
      return;
    }

    // Captured before the dialog closes: the builder context is defunct by the
    // time the await below resolves.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(t('Dodaj znajomego do grupy')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: acceptedFriends.length,
              itemBuilder: (BuildContext context, int index) {
                final FriendProfile friend = acceptedFriends[index];
                return ListTile(
                  title: Text(friend.displayLabel),
                  trailing: const Icon(Icons.person_add_rounded),
                  onTap: () async {
                    Navigator.of(dialogContext).pop();
                    await ref
                        .read(socialHubControllerProvider.notifier)
                        .addMemberToGroup(
                          groupId: widget.groupId,
                          memberAddress: friend.address,
                        );
                    if (mounted) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            t('Dodano {name} do grupy.', {
                              'name': friend.displayLabel,
                            }),
                          ),
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t('Anuluj')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickDisappearingTimer() async {
    final String key = 'group:${widget.groupId}';
    final int? seconds = await showDisappearingTimerDialog(
      context,
      current: ref.read(socialHubControllerProvider).disappearSecondsFor(key),
    );
    if (seconds == null || !mounted) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .setDisappearingTimer(key, seconds);
  }

  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final GroupProfile? group = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.groupById(widget.groupId),
      ),
    );
    final Map<String, FriendProfile> friends = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.friends,
      ),
    );
    // Messages the person reported are hidden behind a line (§21.4).
    final HiddenByMe hiddenByMe = ref.watch(hiddenByMeProvider);
    final AsyncValue<List<ChatMessage>> messagesAsync = ref.watch(
      groupMessagesProvider(widget.groupId),
    );

    final OngoingGroupCall? runningCall = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.groupCalls[widget.groupId],
      ),
    );
    final CallSession? activeCall = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.activeCall,
      ),
    );
    final bool inThisCall =
        activeCall != null &&
        activeCall.isGroup &&
        activeCall.groupId == widget.groupId &&
        activeCall.status != CallSessionStatus.ringing;
    final String name = group?.name ?? widget.groupName;
    final int memberCount = group?.memberCount ?? 1;
    final bool isPending = group?.isInvitePending ?? false;
    final bool isMember = group != null && !isPending;

    return Scaffold(
      backgroundColor: zen.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            const ZenIconBadge(icon: Icons.groups_rounded, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tn(
                      memberCount,
                      one: '{n} uczestnik',
                      few: '{n} uczestników',
                      many: '{n} uczestników',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: t('Połączenie audio'),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: zen.accent.withValues(alpha: 0.12),
                    foregroundColor: zen.accent,
                    disabledBackgroundColor: zen.surfaceMuted,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.call_rounded, size: 20),
                  onPressed: isMember ? () => _startGroupCall(false) : null,
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: t('Połączenie wideo'),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: zen.accent.withValues(alpha: 0.12),
                    foregroundColor: zen.accent,
                    disabledBackgroundColor: zen.surfaceMuted,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.videocam_rounded, size: 20),
                  onPressed: isMember ? () => _startGroupCall(true) : null,
                ),
              ],
            ),
          ),
          if (isMember)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (String action) {
                if (action == 'add_member') {
                  _showAddMemberDialog(group);
                } else if (action == 'leave') {
                  unawaited(_confirmLeave());
                } else if (action == 'disappear') {
                  unawaited(_pickDisappearingTimer());
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'add_member',
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.person_add_rounded, size: 18),
                      const SizedBox(width: 8),
                      Text(t('Dodaj członka')),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  key: const Key('group-disappearing-menu'),
                  value: 'disappear',
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.timer_outlined, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          t('Znikające wiadomości: {label}', {
                            'label': disappearLabel(
                              ref
                                  .read(socialHubControllerProvider)
                                  .disappearSecondsFor(
                                    'group:${widget.groupId}',
                                  ),
                            ),
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'leave',
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.logout_rounded, size: 18, color: zen.danger),
                      const SizedBox(width: 8),
                      Text(
                        t('Opuść grupę'),
                        style: TextStyle(color: zen.danger),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (isPending)
            _PendingInviteBanner(
              group: group!,
              onJoin: () => _join(group),
              onDecline: () => _decline(group),
            ),
          if (isMember && (inThisCall || (runningCall?.isEmpty == false)))
            _RunningCallBanner(
              inCall: inThisCall,
              headcount: inThisCall
                  ? activeCall.participantAddresses.length + 1
                  : runningCall!.participants.length,
              onTap: inThisCall
                  ? () => openGroupCallSurface(
                      groupId: widget.groupId,
                      groupName: name,
                    )
                  : _joinRunningCall,
            ),
          // Message List
          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object err, _) => Center(
                child: Text(t('Błąd ładowania: {error}', {'error': err})),
              ),
              data: (List<ChatMessage> messages) {
                final bool animateEntrance =
                    !_messageEntrancePlayed && messages.isNotEmpty;
                if (messages.isNotEmpty) {
                  _messageEntrancePlayed = true;
                }
                if (messages.isEmpty) {
                  return Center(
                    child: SingleChildScrollView(
                      child: ZenEmpty(
                        icon: Icons.forum_outlined,
                        title: t('Brak wiadomości w tej grupie'),
                        text: isMember
                            ? t('Napisz pierwszą wiadomość do uczestników grupy.')
                            : t('Tu pojawią się wiadomości grupy.'),
                      ),
                    ),
                  );
                }

                // Reversed, so the chat opens at the newest message and new
                // ones appear without the user having to scroll down.
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  itemCount: messages.length,
                  itemBuilder: (BuildContext context, int reversedIndex) {
                    final int index = messages.length - 1 - reversedIndex;
                    final ChatMessage msg = messages[index];
                    if (msg.isSystem) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: zen.surfaceRaised.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: zen.outlineSoft),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              child: Text(
                                msg.text,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    final bool isSelf = msg.isOutgoing || msg.sender == 'self';
                    if (!isSelf && hiddenByMe.hides(id: msg.id)) {
                      return HiddenContentPlaceholder(
                        key: Key('group-hidden-${msg.id}'),
                        byMe: true,
                        compact: true,
                        onShow: () => showHiddenAnyway(ref, id: msg.id),
                      );
                    }
                    final String senderName = isSelf
                        ? t('Ty')
                        : friends[msg.sender]?.displayLabel ??
                              ref
                                  .read(socialHubControllerProvider)
                                  .friendByAddress(msg.sender)
                                  ?.displayLabel ??
                              group?.memberNames[msg.sender] ??
                              t('Uczestnik');

                    final Color senderTone = zenTone(
                      zen,
                      (msg.sender.hashCode & 0x7FFFFFFF) % 8,
                    );
                    final Widget bubble = Align(
                      alignment: isSelf
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        constraints: BoxConstraints(
                          maxWidth: (MediaQuery.of(context).size.width * 0.78)
                              .clamp(160.0, 440.0),
                        ),
                        decoration: isSelf
                            ? BoxDecoration(
                                gradient: LinearGradient(
                                  colors: <Color>[
                                    zen.accent,
                                    Color.lerp(
                                      zen.accent,
                                      zen.accentSecondary,
                                      0.35,
                                    )!,
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: ZenRadii.dropEnd,
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: zen.accent.withValues(alpha: 0.18),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              )
                            : BoxDecoration(
                                color: zen.surfaceRaised,
                                borderRadius: ZenRadii.drop,
                                border: Border.all(color: zen.outlineSoft),
                              ),
                        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            if (!isSelf)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  senderName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: senderTone,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            CopyableText(
                              msg.text,
                              style: TextStyle(
                                color: isSelf ? zen.onAccent : zen.textPrimary,
                                fontSize: 15,
                                height: 1.4,
                                fontWeight: FontWeight.w500,
                              ),
                              // §21.4: what others wrote can be reported.
                              onReport: isSelf
                                  ? null
                                  : () => unawaited(
                                      reportContent(
                                        context,
                                        ref,
                                        authorAddress: msg.sender,
                                        text: msg.text,
                                        header: t(
                                          'Wiadomość w grupie {group} — {name}',
                                          {
                                            'group': widget.groupName,
                                            'name': senderName,
                                          },
                                        ),
                                        contentId: msg.id,
                                        deleteLocal: () async {
                                          await ref
                                              .read(
                                                socialHubControllerProvider
                                                    .notifier,
                                              )
                                              .deleteMessageLocally(
                                                key: 'group:${widget.groupId}',
                                                messageId: msg.id,
                                              );
                                        },
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    );
                    // Stagger from the newest bubble up — those are the ones
                    // visible when the conversation opens.
                    final int fromEnd = messages.length - 1 - index;
                    if (animateEntrance && fromEnd < _entranceStaggerLimit) {
                      return ZenFadeSlide(
                        duration: const Duration(milliseconds: 300),
                        delay: Duration(milliseconds: 30 * fromEnd),
                        offset: Offset(isSelf ? 10 : -10, 6),
                        child: bubble,
                      );
                    }
                    return bubble;
                  },
                );
              },
            ),
          ),
          // Composer Bar
          if (!isMember)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Text(
                  group == null
                      ? t('Nie jesteś już w tej grupie.')
                      : t('Dołącz do grupy, żeby pisać.'),
                  key: const Key('group-chat-readonly-note'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: zen.textSecondary),
                ),
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                color: zen.surface,
                border: Border(top: BorderSide(color: zen.outlineSoft)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: zen.surfaceRaised,
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: zen.outlineSoft),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            key: const Key('group-chat-composer-field'),
                            controller: _composerController,
                            enableIMEPersonalizedLearning: false,
                            textCapitalization: TextCapitalization.sentences,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 15,
                              height: 1.35,
                            ),
                            decoration: InputDecoration(
                              hintText: t('Napisz wiadomość do grupy...'),
                              hintStyle: TextStyle(
                                color: zen.textMuted,
                                fontSize: 14.5,
                              ),
                              filled: false,
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.fromLTRB(
                                18,
                                13,
                                8,
                                13,
                              ),
                            ),
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 4, 4, 4),
                          child: IconButton.filled(
                            key: const Key('group-chat-send-button'),
                            style: IconButton.styleFrom(
                              backgroundColor: zen.accent,
                              foregroundColor: zen.onAccent,
                              minimumSize: const Size(40, 40),
                              fixedSize: const Size(40, 40),
                              padding: EdgeInsets.zero,
                              shape: const CircleBorder(),
                            ),
                            icon: const Icon(Icons.send_rounded, size: 20),
                            onPressed: _sendMessage,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PendingInviteBanner extends StatelessWidget {
  const _PendingInviteBanner({
    required this.group,
    required this.onJoin,
    required this.onDecline,
  });

  final GroupProfile group;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      key: const Key('group-invite-banner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(zen.accent.withValues(alpha: 0.16), zen.surface),
            zen.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(bottom: BorderSide(color: zen.outlineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.mail_outline_rounded, color: zen.accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('Zaproszenie do grupy'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: zen.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t(
              'Możesz przejrzeć rozmowę. Pisać i dzwonić możesz po dołączeniu.',
            ),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: const Key('group-invite-decline'),
                  onPressed: onDecline,
                  child: Text(t('Odrzuć')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  key: const Key('group-invite-join'),
                  onPressed: onJoin,
                  child: Text(t('Dołącz')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "A call is running in this group" - with a way in (or back).
class _RunningCallBanner extends StatelessWidget {
  const _RunningCallBanner({
    required this.inCall,
    required this.headcount,
    required this.onTap,
  });

  final bool inCall;
  final int headcount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Material(
      key: const Key('group-running-call-banner'),
      color: Color.alphaBlend(zen.success.withValues(alpha: 0.12), zen.surface),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: <Widget>[
              ZenPulsingDot(color: zen.success, dimension: 10, dotSize: 5),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  inCall
                      ? t('Jesteś w połączeniu grupowym')
                      : t('Trwa połączenie grupowe · {count} os.', {
                          'count': headcount,
                        }),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('group-running-call-action'),
                style: FilledButton.styleFrom(
                  backgroundColor: zen.success,
                  foregroundColor: ZenColors.foregroundFor(zen.success),
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: onTap,
                icon: Icon(
                  inCall ? Icons.open_in_full_rounded : Icons.call_rounded,
                  size: 18,
                ),
                label: Text(inCall ? t('Wróć') : t('Dołącz')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
