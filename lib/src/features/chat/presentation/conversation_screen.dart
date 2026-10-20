import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/utils/mark_of_the_web.dart';
import 'package:zen/src/core/utils/safe_file_name.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/calls/presentation/call_surface_screen.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/chat/presentation/disappearing_timer_dialog.dart';
import 'package:zen/src/features/chat/remote_media_guard.dart';
import 'package:zen/src/features/chat/voice_message_recorder.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/presentation/friend_nickname_prompt.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

part 'conversation_screen_widgets.dart';
part 'conversation_screen_media.dart';

final conversationMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, String peerAddress) async {
      ref.watch(messageTimelineRevisionProvider);
      return ref.watch(messageTimelineStoreProvider).load(peerAddress);
    });

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.peerAddress,
    required this.title,
  });

  final String peerAddress;
  final String title;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  /// Only the first viewport-worth of bubbles gets a staggered entrance —
  /// scrolling and stream updates must not replay the tween.
  static const int _entranceStaggerLimit = 10;

  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final SocialHubController _socialHubController;
  VoiceMessageRecorder? _voiceRecorder;
  Timer? _recordingTicker;
  DateTime? _recordingStartedAt;
  Duration _recordingElapsed = Duration.zero;
  bool _isRecordingVoice = false;
  bool _isRecordingBusy = false;
  bool _messageEntrancePlayed = false;
  int _lastRenderedMessageCount = -1;
  DateTime? _lastTypingSentAt;

  @override
  void initState() {
    super.initState();
    _socialHubController = ref.read(socialHubControllerProvider.notifier);
    _composerController.addListener(_onComposerChanged);
    Future<void>.microtask(() {
      _socialHubController.enterConversation(widget.peerAddress);
    });
  }

  void _onComposerChanged() {
    final String text = _composerController.text.trim();
    if (text.isNotEmpty) {
      final DateTime now = DateTime.now();
      if (_lastTypingSentAt == null ||
          now.difference(_lastTypingSentAt!).inMilliseconds > 2200) {
        _lastTypingSentAt = now;
        _socialHubController.sendTypingState(
          peerAddress: widget.peerAddress,
          isTyping: true,
        );
      }
    } else if (_lastTypingSentAt != null) {
      _lastTypingSentAt = null;
      _socialHubController.sendTypingState(
        peerAddress: widget.peerAddress,
        isTyping: false,
      );
    }
  }

  @override
  void dispose() {
    _composerController.removeListener(_onComposerChanged);
    if (_lastTypingSentAt != null) {
      _socialHubController.sendTypingState(
        peerAddress: widget.peerAddress,
        isTyping: false,
      );
    }
    _socialHubController.leaveConversation(widget.peerAddress);
    _recordingTicker?.cancel();
    final VoiceMessageRecorder? voiceRecorder = _voiceRecorder;
    _voiceRecorder = null;
    if (voiceRecorder != null) {
      unawaited(voiceRecorder.cancel());
    }
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final FriendProfile? friend = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.friendByAddress(widget.peerAddress),
      ),
    );
    final String peerOwnName = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) =>
            state.peerProfileOf(widget.peerAddress)?.name.trim() ?? '',
      ),
    );
    // Nobody the app knows: the title comes from whoever opened the screen
    // (for a link that is the share code, see `RuntimeRouteBridge`) and the
    // subtitle marks them as a stranger.
    final String conversationTitle = friend == null
        ? widget.title
        : (peerOwnName.isEmpty ? friend.displayLabel : peerOwnName);
    final String conversationSubtitle = _conversationSubtitle(
      friend: friend,
      peerAddress: widget.peerAddress,
    );
    final AsyncValue<List<ChatMessage>> messages = ref.watch(
      conversationMessagesProvider(widget.peerAddress),
    );
    final CallSession? activeCall = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.activeCall,
      ),
    );
    final bool isCallActive =
        activeCall != null && activeCall.status == CallSessionStatus.active;
    final bool hasAnyActiveCall = activeCall != null;
    // Messages the person reported are hidden behind a line (§21.4).
    final HiddenByMe hiddenByMe = ref.watch(hiddenByMeProvider);
    final bool hasMessages = messages.asData?.value.isNotEmpty ?? false;
    final int messageCount = messages.asData?.value.length ?? 0;
    final int disappearSeconds = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) =>
            state.disappearSecondsFor(friend?.address ?? widget.peerAddress),
      ),
    );
    final bool canInviteToCall =
        friend?.status == FriendRelationshipStatus.accepted &&
        isRoutablePeerAddress(widget.peerAddress) &&
        !hasAnyActiveCall;
    final List<PopupMenuEntry<_ConversationMenuAction>> menuItems =
        _conversationMenuItems(
          friend: friend,
          hasMessages: hasMessages,
          messageCount: messageCount,
          disappearSeconds: disappearSeconds,
        );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          key: const Key('conversation-open-profile'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => showPeerProfileSheet(context, widget.peerAddress),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(
              children: <Widget>[
                PeerAvatar(
                  address: widget.peerAddress,
                  name: conversationTitle,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        conversationTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (friend?.isTyping == true)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              t('pisze...'),
                              style: TextStyle(
                                color: zen.accent,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 6),
                            ZenAnimatedDots(color: zen.accent, size: 3),
                          ],
                        )
                      else
                        Row(
                          children: <Widget>[
                            ZenStatusDot(on: friend?.isOnline == true, size: 6),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                <String>[
                                  // The nickname the user gave goes under
                                  // their own name.
                                  if (friend?.hasNickname == true)
                                    friend!.nickname.trim(),
                                  conversationSubtitle.isNotEmpty
                                      ? conversationSubtitle
                                      : (friend?.isOnline == true
                                            ? t('online')
                                            : t('offline')),
                                ].join(' · '),
                                key: const Key('conversation-subtitle'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: friend?.isOnline == true
                                      ? zen.success
                                      : zen.textSecondary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          if (activeCall != null &&
              activeCall.status == CallSessionStatus.active)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                key: const Key('conversation-return-to-call-button'),
                style: FilledButton.styleFrom(
                  backgroundColor: zen.success.withValues(alpha: 0.15),
                  foregroundColor: zen.success,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                    side: BorderSide(color: zen.success.withValues(alpha: 0.5)),
                  ),
                ),
                onPressed: () => _returnToCall(context, activeCall),
                icon: ZenPulsingDot(
                  color: zen.success,
                  active: true,
                  dimension: 8,
                  dotSize: 4,
                ),
                label: Text(
                  t('Wróć do rozmowy'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            )
          else ...<Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  key: const Key('conversation-audio-button'),
                  tooltip: t('Rozmowa audio'),
                  onPressed: canInviteToCall
                      ? () => _inviteToCall(CallInviteKind.audio)
                      : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: zen.accent.withValues(alpha: 0.12),
                    foregroundColor: zen.accent,
                    disabledBackgroundColor: zen.surfaceMuted,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.call_rounded, size: 20),
                ),
                const SizedBox(width: 16),
                IconButton(
                  key: const Key('conversation-video-button'),
                  tooltip: t('Rozmowa wideo'),
                  onPressed: canInviteToCall
                      ? () => _inviteToCall(CallInviteKind.video)
                      : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: zen.accent.withValues(alpha: 0.12),
                    foregroundColor: zen.accent,
                    disabledBackgroundColor: zen.surfaceMuted,
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.videocam_rounded, size: 20),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ],
          PopupMenuButton<_ConversationMenuAction>(
            key: const Key('conversation-menu-button'),
            position: PopupMenuPosition.under,
            onSelected: (_ConversationMenuAction action) async {
              switch (action) {
                case _ConversationMenuAction.acceptRequest:
                  if (friend != null) {
                    await _acceptFriend();
                  }
                  return;
                case _ConversationMenuAction.rejectRequest:
                  final bool rejected = await _handleConversationAction(
                    () => _socialHubController.rejectFriendRequest(
                      peerAddress: widget.peerAddress,
                    ),
                    failurePrefix: t('Nie udało się odrzucić'),
                  );
                  if (rejected) {
                    _popBackToFriends();
                  }
                  return;
                case _ConversationMenuAction.cancelRequest:
                  final bool cancelled = await _handleConversationAction(
                    () => _socialHubController.cancelOutgoingRequest(
                      peerAddress: widget.peerAddress,
                    ),
                    failurePrefix: t('Nie udało się anulować'),
                  );
                  if (cancelled) {
                    _popBackToFriends();
                  }
                  return;
                case _ConversationMenuAction.setNickname:
                  if (friend != null) {
                    await _showNicknameDialog(
                      context: context,
                      controller: _socialHubController,
                      friend: friend,
                    );
                  }
                  return;
                case _ConversationMenuAction.retentionSettings:
                  if (friend != null) {
                    await _showRetentionSettingsDialog(
                      context: context,
                      controller: _socialHubController,
                      friend: friend,
                    );
                  }
                  return;
                case _ConversationMenuAction.disappearingMessages:
                  final int? seconds = await showDisappearingTimerDialog(
                    context,
                    current: disappearSeconds,
                  );
                  if (seconds != null) {
                    await _handleConversationAction(
                      () => _socialHubController.setDisappearingTimer(
                        friend?.address ?? widget.peerAddress,
                        seconds,
                      ),
                      failurePrefix: t(
                        'Nie udało się zmienić znikających wiadomości',
                      ),
                    );
                  }
                  return;
                case _ConversationMenuAction.blockFriend:
                  await _handleConversationAction(
                    () => _socialHubController.blockFriend(
                      peerAddress: widget.peerAddress,
                    ),
                    failurePrefix: t('Nie udało się zablokować'),
                  );
                  return;
                case _ConversationMenuAction.removeFriend:
                  final bool removed = await _handleConversationAction(
                    () => _socialHubController.removeFriend(
                      peerAddress: widget.peerAddress,
                    ),
                    failurePrefix: t('Nie udało się usunąć znajomego'),
                  );
                  if (removed) {
                    _popBackToFriends();
                  }
                  return;
                case _ConversationMenuAction.unblockFriend:
                  await _handleConversationAction(
                    () => _socialHubController.unblockFriend(
                      peerAddress: widget.peerAddress,
                    ),
                    failurePrefix: t('Nie udało się odblokować'),
                  );
                  return;
                case _ConversationMenuAction.clearHistory:
                  await _confirmClearHistory();
                  return;
                case _ConversationMenuAction.reportPerson:
                  if (context.mounted) {
                    await reportContent(
                      context,
                      ref,
                      authorAddress: widget.peerAddress,
                      header: t('Zgłoszenie osoby — {name}', {
                        'name': conversationTitle,
                      }),
                      hashContent: false,
                    );
                  }
                  return;
              }
            },
            itemBuilder: (BuildContext context) => menuItems,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (isCallActive)
              Material(
                color: zen.surfaceSunk,
                child: InkWell(
                  key: const Key('conversation-return-to-call-banner'),
                  onTap: () => _returnToCall(context, activeCall),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: zen.success.withValues(alpha: 0.12),
                      border: Border(
                        bottom: BorderSide(
                          color: zen.success.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        ZenPulsingDot(
                          color: zen.success,
                          active: true,
                          dimension: 10,
                          dotSize: 5,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            t('Aktywna rozmowa: {name}', {
                              'name': activeCall.displayName,
                            }),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Text(
                          t('Wróć do rozmowy'),
                          style: TextStyle(
                            color: zen.success,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 12,
                          color: zen.success,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: messages.when(
                data: (List<ChatMessage> thread) {
                  _scheduleScrollToBottom(thread.length);
                  final bool animateEntrance =
                      !_messageEntrancePlayed && thread.isNotEmpty;
                  if (thread.isNotEmpty) {
                    _messageEntrancePlayed = true;
                  }
                  return thread.isEmpty && friend?.isTyping != true
                      ? ListView(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                          children: <Widget>[
                            ZenEmpty(
                              icon: Icons.forum_outlined,
                              title: t('Brak wiadomości'),
                              text: t(
                                'Zacznij rozmowę bez czekania na '
                                'synchronizację tła.',
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                          itemBuilder: (BuildContext context, int index) {
                            if (index == thread.length) {
                              return _TypingBubble(
                                key: const Key('conversation-typing-bubble'),
                                name: friend?.displayLabel ?? t('Kontakt'),
                              );
                            }
                            final ChatMessage message = thread[index];
                            final bool startsNewDay =
                                index == 0 ||
                                !_isSameDay(
                                  thread[index - 1].sentAtMillis,
                                  message.sentAtMillis,
                                );
                            // Stagger from the newest bubble up — those are
                            // the ones visible when the conversation opens.
                            final int fromEnd = thread.length - 1 - index;
                            return Column(
                              children: <Widget>[
                                if (startsNewDay)
                                  _DaySeparator(
                                    key: Key(
                                      'day-separator-${message.sentAtMillis}',
                                    ),
                                    millis: message.sentAtMillis,
                                  ),
                                if (hiddenByMe.hides(id: message.id))
                                  HiddenContentPlaceholder(
                                    key: Key(
                                      'conversation-hidden-${message.id}',
                                    ),
                                    byMe: true,
                                    compact: true,
                                    onShow: () =>
                                        showHiddenAnyway(ref, id: message.id),
                                  )
                                else
                                  _MessageBubble(
                                    message: message,
                                    entranceDelay:
                                        animateEntrance &&
                                            fromEnd < _entranceStaggerLimit
                                        ? Duration(milliseconds: 30 * fromEnd)
                                        : null,
                                    onReport: () => unawaited(
                                      reportContent(
                                        context,
                                        ref,
                                        authorAddress: widget.peerAddress,
                                        text: message.text,
                                        header: t('Wiadomość od {name}', {
                                          'name': conversationTitle,
                                        }),
                                        contentId: message.id,
                                        deleteLocal: () async {
                                          await ref
                                              .read(
                                                socialHubControllerProvider
                                                    .notifier,
                                              )
                                              .deleteMessageLocally(
                                                key: widget.peerAddress,
                                                messageId: message.id,
                                              );
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                          separatorBuilder: (BuildContext context, int index) {
                            return const SizedBox(height: 6);
                          },
                          itemCount:
                              thread.length +
                              (friend?.isTyping == true ? 1 : 0),
                        );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object error, StackTrace stackTrace) {
                  return Center(
                    child: Text(
                      t('Nie udało się wczytać rozmowy.'),
                      style: TextStyle(color: zen.warning),
                    ),
                  );
                },
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: zen.surface,
                border: Border(top: BorderSide(color: zen.outlineSoft)),
              ),
              child: _buildComposer(friend),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendMessage() async {
    final String text = _composerController.text.trim();
    if (text.isEmpty) {
      return;
    }
    _lastTypingSentAt = null;
    final String displayName =
        ref
            .read(socialHubControllerProvider)
            .friendByAddress(widget.peerAddress)
            ?.displayLabel ??
        widget.title;
    _composerController.clear();
    try {
      await _socialHubController.sendLocalMessage(
        peerAddress: widget.peerAddress,
        displayName: displayName,
        text: text,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Nie udało się wysłać wiadomości.'))),
      );
    }
  }

  Future<void> _pickAndSendAttachment() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
    );
    final PlatformFile? picked = result == null || result.files.isEmpty
        ? null
        : result.files.first;
    if (picked == null) {
      return;
    }

    final Uint8List? bytes = picked.bytes;
    final String? attachmentPath = picked.path?.trim().isNotEmpty == true
        ? picked.path!.trim()
        : null;
    if (((bytes == null || bytes.isEmpty) && attachmentPath == null) ||
        !mounted) {
      return;
    }

    final String fileName = picked.name.trim().isNotEmpty
        ? picked.name.trim()
        : 'zalacznik-${DateTime.now().millisecondsSinceEpoch}';
    final Uint8List? headerBytes = bytes != null && bytes.isNotEmpty
        ? Uint8List.sublistView(bytes, 0, bytes.length > 16 ? 16 : bytes.length)
        : await _readAttachmentHeader(attachmentPath);
    final String? mimeType = lookupMimeType(
      picked.name,
      headerBytes: headerBytes,
    );
    final String displayName =
        ref
            .read(socialHubControllerProvider)
            .friendByAddress(widget.peerAddress)
            ?.displayLabel ??
        widget.title;

    try {
      await _socialHubController.sendLocalAttachment(
        peerAddress: widget.peerAddress,
        displayName: displayName,
        bytes: bytes,
        attachmentPath: attachmentPath,
        fileName: fileName,
        mimeType: mimeType,
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<Uint8List?> _readAttachmentHeader(String? path) async {
    if (path == null || path.isEmpty) {
      return null;
    }
    final File file = File(path);
    if (!await file.exists()) {
      return null;
    }
    final RandomAccessFile handle = await file.open(mode: FileMode.read);
    try {
      return Uint8List.fromList(await handle.read(16));
    } finally {
      await handle.close();
    }
  }

  Future<void> _confirmClearHistory() async {
    final preview = await _socialHubController.previewConversationHistory(
      peerAddress: widget.peerAddress,
    );
    if (!mounted || !preview.hasEntries) {
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(t('Wyczyść historię')),
          content: Text(
            tn(
              preview.messageCount,
              one:
                  'Usuniesz {n} wpis z tej rozmowy.\n'
                  'Załączniki w historii: {size}.',
              few:
                  'Usuniesz {n} wpisy z tej rozmowy.\n'
                  'Załączniki w historii: {size}.',
              many:
                  'Usuniesz {n} wpisów z tej rozmowy.\n'
                  'Załączniki w historii: {size}.',
              args: <String, Object?>{
                'size': formatAttachmentSize(preview.attachmentBytes),
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('clear-history-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Usuń')),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _socialHubController.clearConversationHistory(
      peerAddress: widget.peerAddress,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tn(
            preview.messageCount,
            one: 'Usunięto {n} wpis z tej rozmowy.',
            few: 'Usunięto {n} wpisy z tej rozmowy.',
            many: 'Usunięto {n} wpisów z tej rozmowy.',
          ),
        ),
      ),
    );
  }

  Future<void> _inviteToCall(CallInviteKind kind) async {
    final bool ok = await _runCallAction(() {
      return _socialHubController.sendCallInvite(
        peerAddress: widget.peerAddress,
        kind: kind,
      );
    });
    if (ok && mounted) {
      _openCallSurface();
    }
  }

  /// They keep the name from their profile; a nickname can be added later.
  Future<void> _acceptFriend() async {
    final UserProfile profile = ref.read(userProfileControllerProvider);
    final String localAddress = ref
        .read(appShellControllerProvider)
        .localAddress;
    final String? senderDisplayName =
        PeerShareCodec.buildLocalProfile(
          address: localAddress,
          displayName: profile.displayName,
        )?.displayName ??
        (profile.displayName.isNotEmpty ? profile.displayName : null);

    await _handleConversationAction(
      () => _socialHubController.acceptFriendRequest(
        peerAddress: widget.peerAddress,
        senderDisplayName: senderDisplayName,
      ),
      failurePrefix: t('Nie udało się zaakceptować'),
    );
  }

  Future<bool> _handleConversationAction(
    Future<void> Function() action, {
    required String failurePrefix,
  }) async {
    try {
      await action();
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      _showActionError(context, '$failurePrefix: $error');
      return false;
    }
  }

  void _popBackToFriends() {
    if (!mounted) {
      return;
    }
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  Future<bool> _runCallAction(Future<void> Function() action) async {
    return runCallAction(context, action);
  }

  void _updateUi(VoidCallback mutation) {
    if (!mounted) {
      return;
    }
    setState(mutation);
  }

  void _returnToCall(BuildContext context, CallSession session) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      unawaited(_openCallSurface());
    }
  }

  Future<void> _openCallSurface() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => CallSurfaceScreen(
          peerAddress: widget.peerAddress,
          title: widget.title,
          returnToConversation: true,
        ),
      ),
    );
  }

  void _scheduleScrollToBottom(int messageCount) {
    if (_lastRenderedMessageCount == messageCount) {
      return;
    }
    _lastRenderedMessageCount = messageCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }
}
