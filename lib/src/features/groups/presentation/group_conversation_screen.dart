import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/chat_attachment_picker.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/chat/presentation/disappearing_timer_dialog.dart';
import 'package:zen/src/features/chat/presentation/jump_to_latest.dart';
import 'package:zen/src/features/chat/presentation/message_delivery_badge.dart';
import 'package:zen/src/features/chat/presentation/message_extras.dart';
import 'package:zen/src/features/groups/group_board.dart';
import 'package:zen/src/features/groups/group_board_providers.dart';
import 'package:zen/src/features/groups/presentation/group_board_view.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/settings/presentation/notification_privacy_choice.dart';
import 'package:zen/src/features/shell/composer_drafts.dart';
import 'package:zen/src/features/shell/presentation/remembered_place.dart';
import 'package:zen/src/features/shell/shell_location.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/presentation/mention_field.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

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
    this.initialMessageId,
  });

  final String groupId;
  final String groupName;

  /// The message to show first (a mention's notification was tapped).
  final String? initialMessageId;

  @override
  ConsumerState<GroupConversationScreen> createState() =>
      _GroupConversationScreenState();
}

class _GroupConversationScreenState
    extends ConsumerState<GroupConversationScreen> {
  /// Only the first viewport-worth of bubbles gets a staggered entrance —
  /// scrolling and stream updates must not replay the tween.
  static const int _entranceStaggerLimit = 10;

  /// The field: "@" in it offers the group's members to mention.
  final MentionTextController _composerController = MentionTextController();

  /// The message to scroll to once the chat is loaded
  /// ([GroupConversationScreen.initialMessageId]).
  late String? _pendingJump = widget.initialMessageId;

  /// Keeps the chat at the newest message while it is there.
  final ChatScrollController _scrollController = ChatScrollController(
    reversed: true,
  );

  /// The newest message the chat was built with.
  String? _newestShownId;
  final Map<String, GlobalKey> _bubbleKeys = <String, GlobalKey>{};

  /// Where the chat was scrolled to when the app was closed.
  late final ChatScrollMemory _scrollMemory = ChatScrollMemory(
    location: ref.read(shellLocationProvider),
    place: ShellPlace.groupChat(widget.groupId),
    scroll: _scrollController,
    bubbleKeys: _bubbleKeys,
    reversed: true,
  );
  bool _scrollMemoryUsed = false;
  bool _messageEntrancePlayed = false;

  /// "Tablica" tab (posts pinned to the group) instead of the chat.
  bool _boardTab = false;
  late final SocialHubController _socialHub;

  /// What is written and not sent yet is kept as the group's draft.
  late final ComposerDrafts _drafts;
  late final String _draftId = ComposerDrafts.groupChat(widget.groupId);

  /// The message the next one replies to (shown over the composer).
  ChatReply? _replyTo;

  /// A file is being picked or handed over.
  bool _attaching = false;

  /// A message just jumped to from a reply: outlined for a moment.
  String? _highlightId;
  Timer? _highlightTimer;

  GlobalKey _bubbleKey(String id) => _bubbleKeys.putIfAbsent(id, GlobalKey.new);

  /// Who [who] is in this group (`self`, a member's address).
  String _nameOf(String who) {
    if (who == 'self') {
      return t('Ty');
    }
    final SocialHubState hub = ref.read(socialHubControllerProvider);
    return hub.displayNameOf(
      who,
      selfNamed: hub.groupById(widget.groupId)?.memberNames[who],
      fallback: t('Uczestnik'),
    );
  }

  /// Scrolls to the message [id] a reply quotes and outlines it briefly.
  Future<void> _jumpToMessage(String id, List<ChatMessage> messages) async {
    final int index = messages.indexWhere((ChatMessage m) => m.id == id);
    if (index < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Tej wiadomości nie ma już w rozmowie.'))),
      );
      return;
    }
    BuildContext? target = _bubbleKeys[id]?.currentContext;
    if (target == null && _scrollController.hasClients) {
      // The list is reversed: the newest message is at offset 0.
      final int fromEnd = messages.length - 1 - index;
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent *
            fromEnd /
            (messages.length > 1 ? messages.length - 1 : 1),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      await WidgetsBinding.instance.endOfFrame;
      target = _bubbleKeys[id]?.currentContext;
    }
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
      );
    }
    if (!mounted) {
      return;
    }
    setState(() => _highlightId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _highlightId = null);
      }
    });
  }

  /// Picks a photo, film, file, GIF or voice message and sends it to the
  /// group (with the reply being written, if any).
  Future<void> _attach() async {
    if (_attaching || !_canWrite) {
      return;
    }
    final ChatAttachmentSource? source = await pickChatAttachmentSource(
      context,
      gifEnabled: ref.read(gifSearchEnabledProvider),
    );
    if (source == null || !mounted) {
      return;
    }
    setState(() => _attaching = true);
    try {
      final PickedChatAttachment? picked = await pickChatAttachment(
        context,
        ref,
        source,
      );
      if (picked == null || !mounted) {
        return;
      }
      final ChatReply? replyTo = _replyTo;
      setState(() => _replyTo = null);
      await _socialHub.sendGroupAttachment(
        groupId: widget.groupId,
        bytes: picked.bytes,
        attachmentPath: picked.path,
        fileName: picked.fileName,
        mimeType: picked.mimeType,
        type: picked.type,
        durationMs: picked.durationMs,
        replyTo: replyTo,
      );
    } on FormatException catch (error) {
      _showSnack(error.message);
    } on StateError catch (error) {
      _showSnack(error.message);
    } on Object catch (error) {
      _showSnack(
        t('Nie udało się wysłać pliku: {error}', <String, Object?>{
          'error': error,
        }),
      );
    } finally {
      if (mounted) {
        setState(() => _attaching = false);
      }
    }
  }

  /// Files dropped on the chat or pasted: photos as fresh JPEGs, GIFs
  /// animated, films, files (see media_transfer.dart).
  Future<void> _sendTransferred(List<TransferItem> items) => sendTransferItems(
    context,
    items,
    send: (OutgoingAttachment attachment) async {
      try {
        await _socialHub.sendGroupAttachment(
          groupId: widget.groupId,
          bytes: attachment.bytes,
          attachmentPath: attachment.path,
          fileName: attachment.fileName,
          mimeType: attachment.mimeType,
          type: attachment.chatType,
        );
      } on FormatException catch (error) {
        _showSnack(error.message);
      } on StateError catch (error) {
        _showSnack(error.message);
      }
    },
  );

  /// Puts a photo on the group's board, with what is written in the
  /// composer as its caption. The photo is kept once as blocks the members
  /// fetch; only its reference goes out with the post.
  Future<void> _attachBoardPhoto() async {
    if (_attaching || !_canWrite) {
      return;
    }
    final ChatMediaBlocks? blocks = ref
        .read(chatMediaBlocksHolderProvider)
        .blocks;
    if (blocks == null) {
      _showSnack(t('Zdjęcia na tablicy będą dostępne, gdy sieć się uruchomi.'));
      return;
    }
    final String caption = _composerController.text.trim();
    if (caption.length > kMaxBoardPostChars) {
      _showSnack(t('Podpis zdjęcia jest za długi.'));
      return;
    }
    setState(() => _attaching = true);
    try {
      final PickedChatAttachment? picked = await pickChatAttachment(
        context,
        ref,
        ChatAttachmentSource.gallery,
      );
      if (picked == null || !mounted) {
        return;
      }
      final Uint8List? bytes = picked.bytes;
      if (picked.type != ChatMessageType.image ||
          bytes == null ||
          bytes.isEmpty) {
        _showSnack(t('Na tablicę można dodać tylko zdjęcie.'));
        return;
      }
      if (bytes.length > kMaxBoardPhotoBytes) {
        _showSnack(t('To zdjęcie jest za duże.'));
        return;
      }
      final Map<String, dynamic> media = await blocks.store(
        bytes,
        mime: picked.mimeType ?? 'image/jpeg',
      );
      final GroupBoardPost? post = await ref
          .read(groupBoardServiceProvider)
          .publish(widget.groupId, caption, media: media);
      if (post != null && mounted) {
        _composerController.clear();
      }
    } on FormatException catch (error) {
      _showSnack(error.message);
    } on Object catch (error) {
      _showSnack(
        t('Nie udało się dodać zdjęcia: {error}', <String, Object?>{
          'error': error,
        }),
      );
    } finally {
      if (mounted) {
        setState(() => _attaching = false);
      }
    }
  }

  void _showSnack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  void initState() {
    super.initState();
    _socialHub = ref.read(socialHubControllerProvider.notifier);
    _drafts = ref.read(composerDraftsProvider);
    _composerController.addListener(_keepDraft);
    _restoreDraft();
    // Opening the chat reads it: clears the unread badge and keeps new
    // messages for this group from notifying while it is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_socialHub.enterGroupConversation(widget.groupId));
        // Files whose blocks did not arrive yet are asked for again.
        unawaited(_socialHub.retryPendingGroupMedia(widget.groupId));
      }
    });
  }

  /// What was written here and not sent, before the screen or the app was
  /// closed, is back in the field, its mentions too (unless something was
  /// typed meanwhile).
  void _restoreDraft() {
    void fill() {
      final ComposerDraft? draft = _drafts[_draftId];
      if (!mounted || draft == null || _composerController.text.isNotEmpty) {
        return;
      }
      _composerController.setStoredText(draft.text, draft.mentions);
    }

    if (_drafts.isLoaded) {
      fill();
    } else {
      unawaited(_drafts.load().then((_) => fill()));
    }
  }

  void _keepDraft() {
    final ({String text, List<Mention> mentions}) stored = _composerController
        .storedText();
    _drafts.put(
      _draftId,
      ComposerDraft(text: stored.text, mentions: stored.mentions),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollMemory.attach(context);
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _socialHub.leaveGroupConversation(widget.groupId);
    _composerController.removeListener(_keepDraft);
    _composerController.dispose();
    _scrollMemory.dispose();
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
        scrollable: true,
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

  /// Who a message may mention: the group's members, nobody else.
  List<MentionCandidate> _mentionCandidates() {
    final GroupProfile? group = ref
        .read(socialHubControllerProvider)
        .groupById(widget.groupId);
    if (group == null) {
      return const <MentionCandidate>[];
    }
    return groupMentionCandidates(
      group,
      selfAddress: ref.read(runtimeNodeSnapshotProvider).localAddress,
      nameOf: _nameOf,
    );
  }

  Future<void> _sendMessage() async {
    final String text = _composerController.text.trim();
    if (text.isEmpty || !_canWrite) {
      return;
    }
    // The chat keeps mentions as tokens; the board takes the text as it is.
    final ({String text, List<Mention> mentions}) stored = _composerController
        .storedText();
    if (_boardTab && text.length > kMaxBoardPostChars) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tn(
              kMaxBoardPostChars,
              one: 'Post jest za długi (maks. {n} znak).',
              few: 'Post jest za długi (maks. {n} znaki).',
              many: 'Post jest za długi (maks. {n} znaków).',
            ),
          ),
        ),
      );
      return;
    }
    _composerController.clear();
    try {
      if (_boardTab) {
        // A post on the group's board, not a chat message.
        await ref.read(groupBoardServiceProvider).publish(widget.groupId, text);
        if (mounted) {
          unawaited(ref.read(zenSoundEffectsProvider).play(ZenSound.posted));
        }
        return;
      }
      final ChatReply? replyTo = _replyTo;
      if (replyTo != null) {
        setState(() => _replyTo = null);
      }
      // Down to the newest message, where this one is about to appear.
      _scrollController.showLatest();
      await ref
          .read(socialHubControllerProvider.notifier)
          .sendGroupMessage(
            groupId: widget.groupId,
            text: stored.text,
            replyTo: replyTo,
            mentions: stored.mentions,
          );
      if (mounted) {
        unawaited(ref.read(zenSoundEffectsProvider).play(ZenSound.messageSent));
      }
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
    final ChatComposerMetrics composer = ChatComposerMetrics.of(context);
    final GroupProfile? group = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.groupById(widget.groupId),
      ),
    );
    // Built again when a friend or a friend's profile (their name) changes.
    ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => (state.friends, state.peerProfiles),
      ),
    );
    final SocialHubState people = ref.read(socialHubControllerProvider);
    // Messages the person reported are hidden behind a line.
    final HiddenByMe hiddenByMe = ref.watch(hiddenByMeProvider);
    final AsyncValue<List<ChatMessage>> messagesAsync = ref.watch(
      groupMessagesProvider(widget.groupId),
    );

    final int incomingCount =
        messagesAsync.asData?.value
            .where((ChatMessage m) => !m.isOutgoing && !m.isSystem)
            .length ??
        0;

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
    final List<String> memberAddresses =
        group?.memberAddresses ?? const <String>[];
    final Map<String, String> memberNames =
        group?.memberNames ?? const <String, String>{};

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
                } else if (action == 'notifications') {
                  unawaited(
                    showConversationNotificationPrivacyDialog(
                      context,
                      conversationKey: 'group:${widget.groupId}',
                    ),
                  );
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
                  key: const Key('group-notification-privacy-menu'),
                  value: 'notifications',
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.notifications_none_rounded, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          t('Treść powiadomień'),
                          overflow: TextOverflow.ellipsis,
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
      // Files dropped on the chat, and pictures or files pasted with Ctrl+V
      // on a computer, are sent (media_transfer.dart).
      body: MediaDropArea(
        enabled: _canWrite && !_boardTab,
        onItems: _sendTransferred,
        child: Column(
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
            if (isMember)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: SegmentedButton<bool>(
                  key: const Key('group-tabs'),
                  showSelectedIcon: false,
                  segments: <ButtonSegment<bool>>[
                    ButtonSegment<bool>(
                      value: false,
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: Text(t('Czat')),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: const Icon(Icons.push_pin_outlined, size: 18),
                      label: Text(t('Tablica')),
                    ),
                  ],
                  selected: <bool>{_boardTab},
                  onSelectionChanged: (Set<bool> value) =>
                      setState(() => _boardTab = value.first),
                ),
              ),
            // Message List
            Expanded(
              child: _boardTab && isMember
                  ? GroupBoardView(
                      key: Key('group-board-${widget.groupId}'),
                      board: ref.watch(groupBoardServiceProvider),
                      groupId: widget.groupId,
                      canPost: isMember,
                      blocks: ref.read(chatMediaBlocksHolderProvider).blocks,
                      sourcesOf: (GroupBoardPost p) => <String>[
                        p.author,
                        ...memberAddresses,
                      ],
                      nameOf: (GroupBoardPost p) => people.displayNameOf(
                        p.author,
                        selfNamed: memberNames[p.author] ?? p.authorName,
                        fallback: t('Uczestnik'),
                      ),
                    )
                  : JumpToLatest(
                      controller: _scrollController,
                      reversed: true,
                      incomingCount: incomingCount,
                      child: messagesAsync.when(
                        // Each message reloads the chat: the list stays (and
                        // keeps its place) until the new one is read,
                        // instead of a spinner for a frame and a new list.
                        skipLoadingOnReload: true,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (Object err, _) => Center(
                          child: Text(
                            t('Błąd ładowania: {error}', {'error': err}),
                          ),
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
                                      ? t(
                                          'Napisz pierwszą wiadomość do uczestników grupy.',
                                        )
                                      : t('Tu pojawią się wiadomości grupy.'),
                                ),
                              ),
                            );
                          }

                          final Map<String, ChatMessage> byId =
                              <String, ChatMessage>{
                                for (final ChatMessage m in messages) m.id: m,
                              };
                          final Map<String, int> indexOfId = <String, int>{
                            for (final (int i, ChatMessage m)
                                in messages.indexed)
                              m.id: i,
                          };
                          final Map<Key, String> idOfBubble = <Key, String>{
                            for (final MapEntry<String, GlobalKey> e
                                in _bubbleKeys.entries)
                              e.value: e.key,
                          };
                          // One's own new message is shown, also from
                          // further up.
                          final String newest = messages.last.id;
                          if (_newestShownId != null &&
                              newest != _newestShownId &&
                              messages.last.isOutgoing) {
                            _scrollController.showLatest();
                          }
                          _newestShownId = newest;
                          final String? jump = _pendingJump;
                          if (jump != null) {
                            // Opened from a mention's notification: at the
                            // message that mentioned this person.
                            _pendingJump = null;
                            _scrollMemoryUsed = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                unawaited(_jumpToMessage(jump, messages));
                              }
                            });
                          }
                          if (!_scrollMemoryUsed) {
                            _scrollMemoryUsed = true;
                            if (_scrollMemory.hasAnchor) {
                              // The chat was closed with the app: back at the
                              // message it was scrolled to.
                              final List<String> ids = <String>[
                                for (final ChatMessage m in messages) m.id,
                              ];
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  _scrollMemory.restore(ids);
                                }
                              });
                            }
                          }
                          // Reversed, so the chat opens at the newest message and new
                          // ones appear without the user having to scroll down.
                          return ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                            itemCount: messages.length,
                            // Each row by its message (its key: the id, or
                            // the bubble's own): one coming in below does
                            // not move those read further up.
                            findChildIndexCallback: (Key key) {
                              final String? id = key is ValueKey<String>
                                  ? key.value
                                  : idOfBubble[key];
                              final int? index = indexOfId[id];
                              return index == null
                                  ? null
                                  : messages.length - 1 - index;
                            },
                            itemBuilder: (BuildContext context, int reversedIndex) {
                              final int index =
                                  messages.length - 1 - reversedIndex;
                              final ChatMessage msg = messages[index];
                              if (msg.isSystem) {
                                return Padding(
                                  key: ValueKey<String>(msg.id),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: zen.surfaceRaised.withValues(
                                          alpha: 0.85,
                                        ),
                                        borderRadius: context.zenRadius(16),
                                        border: Border.all(
                                          color: zen.outlineSoft,
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 5,
                                        ),
                                        child: Text(
                                          chatMessageText(msg),
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
                              final bool isSelf =
                                  msg.isOutgoing || msg.sender == 'self';
                              if (!isSelf && hiddenByMe.hides(id: msg.id)) {
                                return HiddenContentPlaceholder(
                                  key: Key('group-hidden-${msg.id}'),
                                  byMe: true,
                                  compact: true,
                                  onShow: () =>
                                      showHiddenAnyway(ref, id: msg.id),
                                );
                              }
                              final String senderName = isSelf
                                  ? t('Ty')
                                  : people.displayNameOf(
                                      msg.sender,
                                      selfNamed: memberNames[msg.sender],
                                      fallback: t('Uczestnik'),
                                    );

                              final Color senderTone = zenTone(
                                zen,
                                (msg.sender.hashCode & 0x7FFFFFFF) % 8,
                              );
                              // The look's own bubbles, or the gradient ones.
                              final ZenLook look = ZenLook.of(context);
                              final BoxDecoration? themed = look.bubble(
                                zen,
                                outgoing: isSelf,
                              );
                              // Files keep their own colours: only text sits on
                              // the gradient.
                              final bool onGradient =
                                  isSelf &&
                                  themed == null &&
                                  msg.type == ChatMessageType.text;
                              final String key = 'group:${widget.groupId}';
                              final List<ChatMenuItem> actions = isMember
                                  ? chatMessageActions(
                                      context,
                                      ref,
                                      message: msg,
                                      conversationKey: key,
                                      onReply: () => setState(
                                        () =>
                                            _replyTo = _socialHub.replyTo(msg),
                                      ),
                                    )
                                  : const <ChatMenuItem>[];
                              final ChatReply? reply = msg.isDeleted
                                  ? null
                                  : msg.reply;
                              final ChatMessage? replyOriginal = reply == null
                                  ? null
                                  : byId[reply.messageId];
                              final Widget bubble = Align(
                                alignment: isSelf
                                    ? AlignmentDirectional.centerEnd
                                    : AlignmentDirectional.centerStart,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        (MediaQuery.of(context).size.width *
                                                0.78)
                                            .clamp(160.0, 440.0),
                                  ),
                                  decoration:
                                      themed ??
                                      (onGradient
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
                                              borderRadius: look.bubbleRadius(
                                                outgoing: true,
                                              ),
                                              boxShadow: ZenLook.of(context)
                                                  .tinted(
                                                    zen,
                                                    zen.accent,
                                                    radius: 12,
                                                    alpha: 0.18,
                                                    offset: const Offset(0, 4),
                                                  ),
                                            )
                                          : BoxDecoration(
                                              color: zen.surfaceRaised,
                                              borderRadius: look.bubbleRadius(
                                                outgoing: false,
                                              ),
                                              border: Border.all(
                                                color: zen.outlineSoft,
                                              ),
                                            )),
                                  foregroundDecoration: _highlightId == msg.id
                                      ? BoxDecoration(
                                          borderRadius: look.bubbleRadius(
                                            outgoing: isSelf,
                                          ),
                                          border: Border.all(
                                            color: zen.accent,
                                            width: 2,
                                          ),
                                        )
                                      : null,
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    9,
                                    14,
                                    10,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      if (!isSelf)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 3,
                                          ),
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
                                      if (msg.forwarded && !msg.isDeleted)
                                        ChatForwardedMarker(
                                          onAccent: onGradient,
                                        ),
                                      if (reply != null)
                                        ChatReplyQuote(
                                          reply: reply,
                                          original: replyOriginal,
                                          senderLabel: _nameOf(
                                            replyOriginal == null
                                                ? reply.sender
                                                : (replyOriginal.isOutgoing
                                                      ? 'self'
                                                      : replyOriginal.sender),
                                          ),
                                          onTap: () => unawaited(
                                            _jumpToMessage(
                                              reply.messageId,
                                              messages,
                                            ),
                                          ),
                                          onAccent: onGradient,
                                        ),
                                      if (msg.isDeleted)
                                        Text(
                                          deletedMessageLabel(),
                                          key: Key('deleted-message-${msg.id}'),
                                          style: TextStyle(
                                            color: onGradient
                                                ? zen.onAccent
                                                : zen.textMuted,
                                            fontSize: 14,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        )
                                      else if (msg.type != ChatMessageType.text)
                                        GestureDetector(
                                          onLongPressStart:
                                              (LongPressStartDetails d) =>
                                                  unawaited(
                                                    showChatContextMenu(
                                                      context,
                                                      d.globalPosition,
                                                      actions,
                                                    ),
                                                  ),
                                          child: ChatAttachmentBody(
                                            message: msg,
                                          ),
                                        )
                                      else
                                        CopyableText(
                                          msg.text,
                                          mentions: msg.mentions,
                                          mentionColor: onGradient
                                              ? zen.onAccent
                                              : null,
                                          actions: actions,
                                          style: TextStyle(
                                            color: onGradient
                                                ? zen.onAccent
                                                : zen.textPrimary,
                                            fontSize: 15,
                                            height: 1.4,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          // What others wrote can be reported.
                                          onReport: isSelf
                                              ? null
                                              : () => unawaited(
                                                  reportContent(
                                                    context,
                                                    ref,
                                                    authorAddress: msg.sender,
                                                    text: msg.plainText,
                                                    header: t(
                                                      'Wiadomość w grupie {group} — {name}',
                                                      {
                                                        'group':
                                                            widget.groupName,
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
                                                            key:
                                                                'group:${widget.groupId}',
                                                            messageId: msg.id,
                                                          );
                                                    },
                                                  ),
                                                ),
                                        ),
                                      if (!msg.isDeleted &&
                                          msg.reactions.isNotEmpty)
                                        ChatReactionsBar(
                                          reactions: msg.reactions,
                                          nameOf: _nameOf,
                                          onToggle: (String emoji) => unawaited(
                                            _socialHub.reactToMessage(
                                              conversationKey: key,
                                              messageId: msg.id,
                                              emoji: emoji,
                                            ),
                                          ),
                                        ),
                                      if (msg.isEdited && !msg.isDeleted)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: Text(
                                            editedMarker(),
                                            style: TextStyle(
                                              color: onGradient
                                                  ? zen.onAccent.withValues(
                                                      alpha: 0.72,
                                                    )
                                                  : zen.textMuted,
                                              fontSize: 11,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ),
                                      // How far it got, over all members.
                                      if (msg.isOutgoing)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: MessageDeliveryBadge(
                                            message: msg,
                                            conversationKey:
                                                'group:${widget.groupId}',
                                            isGroup: true,
                                            onAccent: onGradient,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                              // Stagger from the newest bubble up — those are the ones
                              // visible when the conversation opens.
                              final int fromEnd = messages.length - 1 - index;
                              if (animateEntrance &&
                                  fromEnd < _entranceStaggerLimit) {
                                return ZenFadeSlide(
                                  key: ValueKey<String>(msg.id),
                                  duration: const Duration(milliseconds: 300),
                                  delay: Duration(milliseconds: 30 * fromEnd),
                                  offset: Offset(isSelf ? 10 : -10, 6),
                                  child: KeyedSubtree(
                                    key: _bubbleKey(msg.id),
                                    child: bubble,
                                  ),
                                );
                              }
                              return KeyedSubtree(
                                key: _bubbleKey(msg.id),
                                child: bubble,
                              );
                            },
                          );
                        },
                      ),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_replyTo != null && !_boardTab)
                        ChatReplyComposerBar(
                          reply: _replyTo!,
                          senderLabel: _nameOf(_replyTo!.sender),
                          onCancel: () => setState(() => _replyTo = null),
                        ),
                      if (!_boardTab)
                        MentionSuggestions(
                          controller: _composerController,
                          candidates: _mentionCandidates,
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: zen.surfaceRaised,
                            borderRadius: context.zenRadius(26),
                            border: Border.all(color: zen.outlineSoft),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 4,
                                ),
                                child: composer.slot(
                                  width: kChatComposerRowHeight,
                                  child: IconButton(
                                    style: _composerButtonFrame,
                                    key: Key(
                                      _boardTab
                                          ? 'group-board-photo-button'
                                          : 'group-chat-attach-button',
                                    ),
                                    tooltip: _boardTab
                                        ? t('Dodaj zdjęcie')
                                        : t('Załącznik'),
                                    onPressed: _attaching
                                        ? null
                                        : (_boardTab
                                              ? _attachBoardPhoto
                                              : _attach),
                                    icon: _attaching
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : Icon(
                                            Icons.add_circle_outline_rounded,
                                            color: zen.accent,
                                          ),
                                  ),
                                ),
                              ),
                              Expanded(
                                // Exactly the buttons' height, the middle of
                                // the letters on their centre line
                                // (ChatComposerMetrics).
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: composer.rowHeight,
                                  ),
                                  child: Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Padding(
                                      padding: composer.fieldShift,
                                      child: TextField(
                                        key: const Key(
                                          'group-chat-composer-field',
                                        ),
                                        controller: _composerController,
                                        enableIMEPersonalizedLearning: false,
                                        textCapitalization:
                                            TextCapitalization.sentences,
                                        strutStyle: composer.strut,
                                        style: composer.textStyle(
                                          zen.textPrimary,
                                        ),
                                        decoration: InputDecoration(
                                          hint: composer.hint(
                                            _boardTab
                                                ? t(
                                                    'Napisz post na tablicę grupy...',
                                                  )
                                                : t(
                                                    'Napisz wiadomość do grupy...',
                                                  ),
                                            zen.textMuted,
                                            maxLines: 1,
                                          ),
                                          filled: false,
                                          isDense: true,
                                          // Not the theme's compact density:
                                          // the padding is the metrics' own.
                                          visualDensity: VisualDensity.standard,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding: composer
                                              .fieldPadding(),
                                        ),
                                        onSubmitted: (_) => _sendMessage(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              composer.sendSlot(
                                IconButton.filled(
                                  key: const Key('group-chat-send-button'),
                                  style: IconButton.styleFrom(
                                    backgroundColor: zen.accent,
                                    foregroundColor: zen.onAccent,
                                    shape: const CircleBorder(),
                                  ).merge(_composerButtonFrame),
                                  icon: const Icon(
                                    Icons.send_rounded,
                                    size: 20,
                                  ),
                                  onPressed: _sendMessage,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The composer's buttons: a circle of [kChatComposerSendSize] in a full
/// tap target, whatever the theme's density; centred in their places of
/// the row (ChatComposerMetrics).
const ButtonStyle _composerButtonFrame = ButtonStyle(
  fixedSize: WidgetStatePropertyAll<Size>(Size.square(kChatComposerSendSize)),
  minimumSize: WidgetStatePropertyAll<Size>(Size.square(kChatComposerSendSize)),
  padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
  tapTargetSize: MaterialTapTargetSize.padded,
  visualDensity: VisualDensity.standard,
);

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
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 12, 8),
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
