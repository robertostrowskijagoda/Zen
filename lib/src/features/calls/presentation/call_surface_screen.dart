import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/calls/presentation/call_compact_layer.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/calls/presentation/call_security_badge.dart';
import 'package:zen/src/features/calls/presentation/call_session_widgets.dart';
import 'package:zen/src/features/calls/presentation/screen_share_guard.dart';
import 'package:zen/src/features/calls/presentation/screen_source_picker.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

class CallSurfaceScreen extends ConsumerStatefulWidget {
  const CallSurfaceScreen({
    required this.peerAddress,
    required this.title,
    super.key,
    this.returnToConversation = false,
  });

  final String peerAddress;
  final String title;
  final bool returnToConversation;

  @override
  ConsumerState<CallSurfaceScreen> createState() => _CallSurfaceScreenState();
}

class _CallSurfaceScreenState extends ConsumerState<CallSurfaceScreen> {
  /// The control dock plays its entrance only on the first build.
  bool _controlsEntrancePlayed = false;

  bool _closeScheduled = false;

  /// Captured in [initState] so [dispose] can clear the flag without touching
  /// a `ref` whose element is already gone.
  CallSurfaceActiveController? _surfaceFlag;

  @override
  void initState() {
    super.initState();
    // The floating chip is the collapsed form of this screen; while the full
    // surface is up it would only cover the header with a duplicate.
    _surfaceFlag = ref.read(callSurfaceActiveProvider.notifier);
    _setSurfaceActive(_surfaceFlag, true);
  }

  @override
  void dispose() {
    _setSurfaceActive(_surfaceFlag, false);
    _surfaceFlag = null;
    super.dispose();
  }

  /// Writing provider state inside `initState`/`dispose` would rebuild the
  /// listeners mid-frame, so the flip is deferred to the end of the frame.
  static void _setSurfaceActive(
    CallSurfaceActiveController? controller,
    bool value,
  ) {
    if (controller == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        controller.setActive(value);
      } catch (error, stackTrace) {
        logZenError('Updating the call surface flag failed', error, stackTrace);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final CallSession? session = ref.watch(
      socialHubControllerProvider.select((SocialHubState state) {
        final CallSession? active = state.activeCall;
        if (active != null &&
            PeerShareCodec.addressesEqual(
              active.peerAddress,
              widget.peerAddress,
            )) {
          return active;
        }
        return null;
      }),
    );
    final CallMediaSessionController callMedia = ref.read(
      callMediaSessionControllerProvider,
    );

    if (session == null) {
      // The call this surface was opened for is over - or was already gone
      // when the surface opened: close it instead of leaving anything behind
      // once the call ends. On the last route `maybePop` no-ops and the blank
      // scaffold simply stays.
      _scheduleAutoClose();
      return Scaffold(
        key: const Key('call-surface-screen'),
        backgroundColor: zen.background,
        body: const SafeArea(child: SizedBox.shrink()),
      );
    }
    final CallSession liveSession = session;

    return Scaffold(
      key: const Key('call-surface-screen'),
      backgroundColor: zen.background,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: callStageGradient(zen)),
        child: SafeArea(
          child: ListenableBuilder(
            listenable: callMedia,
            builder: (BuildContext context, Widget? child) {
              final CallSession session = liveSession;
              final bool ownsMedia = callMedia.activeCallId == session.id;
              final bool showRemoteVideo =
                  ownsMedia &&
                  callMedia.hasRemoteVideo &&
                  callMedia.remoteRenderer != null &&
                  (callMedia.remoteRenderer!.srcObject != null);
              final bool showLocalPreview =
                  ownsMedia &&
                  callMedia.hasLocalVideo &&
                  callMedia.localRenderer != null &&
                  (callMedia.localRenderer!.srcObject != null);
              final RTCVideoRenderer? remoteScreen = ownsMedia
                  ? callMedia.remoteScreenRenderer
                  : null;
              final bool animateEntrance = !_controlsEntrancePlayed;
              _controlsEntrancePlayed = true;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // Top header
                  _SurfaceTopBar(
                    title: widget.title,
                    session: session,
                    zen: zen,
                    returnToConversation: widget.returnToConversation,
                    onChatPressed: () => _openChat(context),
                  ),
                  if (ownsMedia)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Center(
                        child: CallSecurityBadge(
                          security: callMedia.mediaSecurity,
                        ),
                      ),
                    ),
                  // Center media/audio stage
                  Expanded(
                    child: _CallMediaStage(
                      session: session,
                      zen: zen,
                      remoteRenderer: showRemoteVideo
                          ? callMedia.remoteRenderer
                          : null,
                      localRenderer: showLocalPreview
                          ? callMedia.localRenderer
                          : null,
                      screenRenderer: remoteScreen?.srcObject != null
                          ? remoteScreen
                          : null,
                    ),
                  ),
                  if (ownsMedia && session.status == CallSessionStatus.active)
                    _ScreenShareStrip(
                      zen: zen,
                      peerName: widget.title,
                      sharing: callMedia.isScreenSharing,
                      remoteSharing: callMedia.remoteScreenSharing,
                      recording: callMedia.isRecording,
                      remoteRecording: callMedia.remoteRecording,
                      onLeave: () => runCallAction(
                        context,
                        () => ref
                            .read(socialHubControllerProvider.notifier)
                            .endActiveCall(peerAddress: widget.peerAddress),
                      ),
                      onToggle: () => runCallAction(
                        context,
                        () => _toggleScreenShare(context, callMedia),
                      ),
                      onToggleRecording: callMedia.canRecord
                          ? () => runCallAction(
                              context,
                              () => _toggleRecording(context, callMedia),
                            )
                          : null,
                    ),
                  // Bottom floating control dock
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: _FloatingCallDock(
                      session: session,
                      zen: zen,
                      animateEntrance: animateEntrance,
                      onAccept: session.isIncoming
                          ? () => runCallAction(
                              context,
                              () => ref
                                  .read(socialHubControllerProvider.notifier)
                                  .acceptIncomingCall(
                                    peerAddress: widget.peerAddress,
                                  ),
                            )
                          : null,
                      onDecline: session.isIncoming
                          ? () => runCallAction(
                              context,
                              () => ref
                                  .read(socialHubControllerProvider.notifier)
                                  .declineIncomingCall(
                                    peerAddress: widget.peerAddress,
                                  ),
                            )
                          : null,
                      onEnd:
                          !session.isIncoming ||
                              session.status == CallSessionStatus.active ||
                              session.status == CallSessionStatus.connecting
                          ? () => runCallAction(
                              context,
                              () => ref
                                  .read(socialHubControllerProvider.notifier)
                                  .endActiveCall(
                                    peerAddress: widget.peerAddress,
                                  ),
                            )
                          : null,
                      onToggleMute: session.status == CallSessionStatus.active
                          ? () => runCallAction(
                              context,
                              ref
                                  .read(socialHubControllerProvider.notifier)
                                  .toggleActiveCallMute,
                            )
                          : null,
                      onToggleSpeaker:
                          session.status == CallSessionStatus.active
                          ? () => runCallAction(
                              context,
                              ref
                                  .read(socialHubControllerProvider.notifier)
                                  .toggleActiveCallSpeaker,
                            )
                          : null,
                      onToggleCamera: session.status == CallSessionStatus.active
                          ? () => runCallAction(
                              context,
                              ref
                                  .read(socialHubControllerProvider.notifier)
                                  .toggleActiveCallCamera,
                            )
                          : null,
                      onSwitchCamera: session.status == CallSessionStatus.active
                          ? () => runCallAction(
                              context,
                              () => callMedia.switchCamera(),
                            )
                          : null,
                      onOpenDevices: session.status == CallSessionStatus.active
                          ? () {
                              _openDevicePicker(context, callMedia);
                            }
                          : null,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Records into a temporary file, then moves it into the app's encrypted
  /// storage: the recording never lies around in plain form.
  Future<void> _toggleRecording(
    BuildContext context,
    CallMediaSessionController callMedia,
  ) async {
    if (!callMedia.isRecording) {
      final Directory temp = await mediaTemporaryDirectory();
      await callMedia.startRecording(
        '${temp.path}/zen_rec_${DateTime.now().millisecondsSinceEpoch}'
        '.${callMedia.recordingExtension}',
        label: widget.title,
      );
      return;
    }
    // The file goes into the encrypted store by itself (also when the
    // call simply ends while recording).
    final String? path = await callMedia.stopRecording();
    if (path != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t('Nagranie zapisane (zaszyfrowane).'))),
      );
    }
  }

  Future<void> _toggleScreenShare(
    BuildContext context,
    CallMediaSessionController callMedia,
  ) async {
    if (callMedia.isScreenSharing) {
      await callMedia.stopScreenShare();
      return;
    }
    if (!await confirmScreenShareStart(context)) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    final List<ScreenShareSource> sources = await callMedia.listScreenSources();
    String? sourceId;
    if (sources.isNotEmpty) {
      if (!context.mounted) {
        return;
      }
      final ScreenShareSource? picked = await showScreenSourcePicker(
        context,
        sources,
      );
      if (picked == null) {
        return;
      }
      sourceId = picked.id;
    }
    await callMedia.startScreenShare(sourceId: sourceId);
  }

  void _openChat(BuildContext context) {
    if (widget.returnToConversation) {
      Navigator.of(context).pop();
      return;
    }
    _setSurfaceActive(_surfaceFlag, false);
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => ConversationScreen(
              peerAddress: widget.peerAddress,
              title: widget.title,
            ),
          ),
        )
        .then((_) {
          if (mounted) {
            _setSurfaceActive(_surfaceFlag, true);
          }
        });
  }

  /// Pops the surface after the frame; the session is already gone, so there
  /// is nothing left to show here.
  Future<void> _openDevicePicker(
    BuildContext context,
    CallMediaSessionController callMedia,
  ) async {
    await showCallDevicePicker(
      context: context,
      callMedia: callMedia,
      runAction: (Future<void> Function() action) =>
          runCallAction(context, action),
    );
  }

  void _scheduleAutoClose() {
    if (_closeScheduled) {
      return;
    }
    _closeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }
}

class _SurfaceTopBar extends StatelessWidget {
  const _SurfaceTopBar({
    required this.title,
    required this.session,
    required this.zen,
    required this.returnToConversation,
    required this.onChatPressed,
  });

  final String title;
  final CallSession session;
  final ZenColors zen;
  final bool returnToConversation;
  final VoidCallback onChatPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 28,
              color: zen.textPrimary,
            ),
            tooltip: t('Zwiń'),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  returnToConversation ? t('Rozmowa w toku') : t('Rozmowa'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: zen.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          CallFloatOverAppsButton(color: zen.textPrimary),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: FilledButton.tonalIcon(
              key: const Key('call-surface-top-chat-button'),
              style: FilledButton.styleFrom(
                backgroundColor: zen.surfaceRaised,
                foregroundColor: zen.textPrimary,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                  side: BorderSide(color: zen.outlineSoft),
                ),
              ),
              onPressed: onChatPressed,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
              label: Text(
                t('Czat'),
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmbientAudioStage extends StatelessWidget {
  const _AmbientAudioStage({required this.session, required this.zen});

  final CallSession session;
  final ZenColors zen;

  @override
  Widget build(BuildContext context) {
    final bool active = session.status == CallSessionStatus.active;
    final Color accent = active
        ? zen.success
        : session.isIncoming
        ? zen.warning
        : zen.accent;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ZenPulseRings(
              color: accent.withValues(alpha: 0.6),
              baseSize: 168,
              ringCount: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: <Color>[
                      zen.accent,
                      Color.lerp(zen.accent, zen.accentSecondary, 0.5)!,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: zen.accent.withValues(alpha: 0.35),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: SizedBox.square(
                  dimension: 104,
                  child: Center(
                    child: Text(
                      session.displayName.isNotEmpty
                          ? session.displayName.characters.first.toUpperCase()
                          : '?',
                      style: zen.display(
                        color: zen.onAccent,
                        size: 42,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              session.displayName,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: zen.display(
                color: zen.textPrimary,
                size: 28,
                weight: FontWeight.w600,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _titleFor(session),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
            const SizedBox(height: 4),
            _StageSubtitle(session: session, zen: zen, accent: accent),
            const SizedBox(height: 16),
            CallStateChips(session: session),
          ],
        ),
      ),
    );
  }
}

class _StageSubtitle extends StatelessWidget {
  const _StageSubtitle({
    required this.session,
    required this.zen,
    required this.accent,
  });

  final CallSession session;
  final ZenColors zen;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      color: zen.textMuted,
      fontSize: 13,
      height: 1.4,
    );
    final bool waiting =
        (session.status == CallSessionStatus.ringing && !session.isIncoming) ||
        session.status == CallSessionStatus.connecting;
    if (!waiting) {
      return Text(
        _subtitleFor(session),
        textAlign: TextAlign.center,
        style: style,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            _subtitleFor(session),
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(top: 7),
          child: ZenAnimatedDots(color: accent, size: 3),
        ),
      ],
    );
  }
}

class _FloatingCallDock extends StatelessWidget {
  const _FloatingCallDock({
    required this.session,
    required this.zen,
    this.animateEntrance = false,
    this.onAccept,
    this.onDecline,
    this.onEnd,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleCamera,
    this.onSwitchCamera,
    this.onOpenDevices,
  });

  final CallSession session;
  final ZenColors zen;

  /// Plays the fade-slide entrance for the control row — only on the
  /// first build of the call surface.
  final bool animateEntrance;
  final Future<void> Function()? onAccept;
  final Future<void> Function()? onDecline;
  final Future<void> Function()? onEnd;
  final Future<void> Function()? onToggleMute;
  final Future<void> Function()? onToggleSpeaker;
  final Future<void> Function()? onToggleCamera;
  final Future<void> Function()? onSwitchCamera;
  final VoidCallback? onOpenDevices;

  @override
  Widget build(BuildContext context) {
    final Widget actionBar = CallActionBar(
      session: session,
      onAccept: onAccept,
      onDecline: onDecline,
      onEnd: onEnd,
      onToggleMute: onToggleMute,
      onToggleSpeaker: onToggleSpeaker,
      onToggleCamera: onToggleCamera,
      onSwitchCamera: onSwitchCamera,
      onOpenDevices: onOpenDevices,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: zen.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: zen.outlineSoft),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: animateEntrance
            ? ZenFadeSlide(
                duration: const Duration(milliseconds: 320),
                offset: const Offset(0, 10),
                child: actionBar,
              )
            : actionBar,
      ),
    );
  }
}

class _CallMediaStage extends StatefulWidget {
  const _CallMediaStage({
    required this.session,
    required this.zen,
    this.remoteRenderer,
    this.localRenderer,
    this.screenRenderer,
  });

  final CallSession session;
  final ZenColors zen;
  final RTCVideoRenderer? remoteRenderer;
  final RTCVideoRenderer? localRenderer;

  /// The other side's shared screen: shown large, both cameras small.
  final RTCVideoRenderer? screenRenderer;

  @override
  State<_CallMediaStage> createState() => _CallMediaStageState();
}

class _CallMediaStageState extends State<_CallMediaStage> {
  bool _swapViews = false;

  @override
  Widget build(BuildContext context) {
    final RTCVideoRenderer? remote =
        widget.remoteRenderer != null &&
            widget.remoteRenderer!.textureId != null &&
            widget.remoteRenderer!.srcObject != null
        ? widget.remoteRenderer
        : null;
    final RTCVideoRenderer? local =
        widget.localRenderer != null &&
            widget.localRenderer!.textureId != null &&
            widget.localRenderer!.srcObject != null
        ? widget.localRenderer
        : null;

    final RTCVideoRenderer? screen =
        widget.screenRenderer != null &&
            widget.screenRenderer!.textureId != null &&
            widget.screenRenderer!.srcObject != null
        ? widget.screenRenderer
        : null;
    if (screen != null) {
      return _ScreenShareStage(screen: screen, remote: remote, local: local);
    }

    if (remote == null && local == null) {
      return _AmbientAudioStage(session: widget.session, zen: widget.zen);
    }

    final bool hasRemote = remote != null;
    final RTCVideoRenderer? primary = hasRemote
        ? (_swapViews ? (local ?? remote) : remote)
        : null;
    final RTCVideoRenderer? secondary = hasRemote
        ? (_swapViews ? remote : local)
        : local;

    final bool hasPip =
        secondary != null &&
        secondary.textureId != null &&
        (hasRemote
            ? (primary != null && !identical(primary, secondary))
            : true);

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: primary != null
              ? DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.black),
                  child: RTCVideoView(
                    primary,
                    mirror: identical(primary, local),
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    placeholderBuilder: (BuildContext context) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t('Oczekiwanie na wideo...'),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : _AmbientAudioStage(session: widget.session, zen: widget.zen),
        ),
        if (hasPip)
          Positioned(
            right: 16,
            top: 16,
            child: GestureDetector(
              onTap: hasRemote && local != null
                  ? () {
                      setState(() {
                        _swapViews = !_swapViews;
                      });
                    }
                  : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: 104,
                  height: 148,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.3),
                        width: 1.5,
                      ),
                      color: Colors.black,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: RTCVideoView(
                      secondary,
                      mirror: identical(secondary, local),
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The other side's screen fills the stage, uncropped; the cameras that are
/// on sit small in the corner.
class _ScreenShareStage extends StatelessWidget {
  const _ScreenShareStage({required this.screen, this.remote, this.local});

  final RTCVideoRenderer screen;
  final RTCVideoRenderer? remote;
  final RTCVideoRenderer? local;

  @override
  Widget build(BuildContext context) {
    Widget thumb(RTCVideoRenderer renderer, {required bool mirror}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 96,
          height: 128,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
                width: 1.5,
              ),
              color: Colors.black,
            ),
            child: RTCVideoView(
              renderer,
              mirror: mirror,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
      ),
    );
    final RTCVideoRenderer? remoteCamera = remote;
    final RTCVideoRenderer? localCamera = local;
    return Stack(
      key: const Key('call-remote-screen-stage'),
      children: <Widget>[
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Colors.black),
            child: RTCVideoView(
              screen,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (remoteCamera != null) thumb(remoteCamera, mirror: false),
              if (localCamera != null) thumb(localCamera, mirror: true),
            ],
          ),
        ),
      ],
    );
  }
}

String _titleFor(CallSession session) {
  final bool video = session.kind == CallInviteKind.video;
  return switch (session.status) {
    CallSessionStatus.ringing when session.isIncoming =>
      video
          ? t('Połączenie przychodzące wideo')
          : t('Połączenie przychodzące audio'),
    CallSessionStatus.ringing =>
      video ? t('Dzwonienie (wideo)...') : t('Dzwonienie (audio)...'),
    CallSessionStatus.connecting => t('Łączenie...'),
    CallSessionStatus.active =>
      video ? t('Rozmowa wideo trwa') : t('Rozmowa audio trwa'),
  };
}

String _subtitleFor(CallSession session) => switch (session.status) {
  CallSessionStatus.ringing when session.isIncoming => t(
    '{name} dzwoni do Ciebie',
    {'name': session.displayName},
  ),
  CallSessionStatus.ringing => t('Oczekiwanie na odebranie przez {name}', {
    'name': session.displayName,
  }),
  CallSessionStatus.connecting => t('Nawiązywanie bezpiecznego połączenia...'),
  CallSessionStatus.active => t('Połączenie P2P szyfrowane end-to-end'),
};

/// "Udostępnij ekran" and who is sharing: everyone sees it.
class _ScreenShareStrip extends StatelessWidget {
  const _ScreenShareStrip({
    required this.zen,
    required this.peerName,
    required this.sharing,
    required this.remoteSharing,
    required this.recording,
    required this.remoteRecording,
    required this.onLeave,
    required this.onToggle,
    this.onToggleRecording,
  });

  final ZenColors zen;
  final String peerName;
  final bool sharing;
  final bool remoteSharing;
  final bool recording;
  final bool remoteRecording;
  final VoidCallback onLeave;
  final VoidCallback onToggle;
  final VoidCallback? onToggleRecording;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (recording || remoteRecording)
            Container(
              key: const Key('call-recording-banner'),
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: zen.danger.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: zen.danger.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.fiber_manual_record, size: 14, color: zen.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      <String>[
                        if (recording) t('Nagrywasz tę rozmowę'),
                        if (remoteRecording)
                          t('{name} nagrywa', {'name': peerName}),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.danger,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('call-recording-leave'),
                    style: TextButton.styleFrom(
                      foregroundColor: zen.danger,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onLeave,
                    child: Text(t('Opuść rozmowę')),
                  ),
                ],
              ),
            ),
          if (sharing) ScreenShareReminderBanner(zen: zen),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: sharing || remoteSharing
                ? Container(
                    key: ValueKey<bool>(sharing),
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: zen.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.screen_share_rounded,
                          size: 18,
                          color: zen.accent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            sharing
                                ? t('Udostępniasz ekran')
                                : t('{name} udostępnia ekran', {
                                    'name': peerName,
                                  }),
                            key: const Key('call-screen-share-label'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              FilledButton.tonalIcon(
                key: const Key('call-screen-share-button'),
                onPressed: onToggle,
                icon: Icon(
                  sharing
                      ? Icons.stop_screen_share_rounded
                      : Icons.screen_share_outlined,
                ),
                label: Text(sharing ? t('Zatrzymaj') : t('Udostępnij ekran')),
              ),
              if (onToggleRecording != null)
                IconButton.filledTonal(
                  key: const Key('call-record-button'),
                  tooltip: recording
                      ? t('Zatrzymaj nagrywanie')
                      : t('Nagrywaj'),
                  onPressed: onToggleRecording,
                  icon: Icon(
                    recording ? Icons.stop_rounded : Icons.fiber_manual_record,
                    color: zen.danger,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
