import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/calls/presentation/call_compact_layer.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/calls/presentation/call_session_widgets.dart';
import 'package:zen/src/features/calls/presentation/screen_source_picker.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The group call "room": one tile per person in the call, the controls
/// underneath. People join and leave while it runs; nobody has to be there
/// from the start.
class GroupCallScreen extends ConsumerStatefulWidget {
  const GroupCallScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    this.initialVideo = false,
  });

  final String groupId;
  final String groupName;
  final bool initialVideo;

  @override
  ConsumerState<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends ConsumerState<GroupCallScreen> {
  Timer? _ticker;
  bool _controlsEntrancePlayed = false;
  bool _closeScheduled = false;
  CallSurfaceActiveController? _surfaceFlag;

  @override
  void initState() {
    super.initState();
    _surfaceFlag = ref.read(callSurfaceActiveProvider.notifier);
    _setSurfaceActive(_surfaceFlag, true);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _scheduleAutoClose() {
    if (_closeScheduled) {
      return;
    }
    _closeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    _setSurfaceActive(_surfaceFlag, false);
    _surfaceFlag = null;
    _ticker?.cancel();
    super.dispose();
  }

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
        logZenError(
          'Updating call surface active flag failed',
          error,
          stackTrace,
        );
      }
    });
  }

  static String _formatDuration(int seconds) {
    final int minutes = seconds ~/ 60;
    final int rest = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  }

  String _nameFor(
    String address,
    Map<String, FriendProfile> friends,
    GroupProfile? group,
  ) {
    final FriendProfile? friend = friends[address];
    if (friend != null && friend.displayLabel.trim().isNotEmpty) {
      return friend.displayLabel;
    }
    for (final MapEntry<String, String> entry
        in group?.memberNames.entries ?? const <MapEntry<String, String>>[]) {
      if (entry.key.toUpperCase() == address.toUpperCase() &&
          entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return 'Uczestnik';
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final GroupProfile? group = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.groupById(widget.groupId),
      ),
    );
    final CallSession? activeCall = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.activeCall,
      ),
    );
    final Map<String, FriendProfile> friends = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.friends,
      ),
    );
    final String myName = ref.watch(
      userProfileControllerProvider.select((p) => p.displayName),
    );
    final GroupCallMedia media = ref.watch(groupCallMediaProvider);

    if (activeCall == null ||
        !activeCall.isGroup ||
        activeCall.groupId != widget.groupId) {
      _scheduleAutoClose();
      return Scaffold(
        backgroundColor: zen.background,
        body: const SafeArea(child: SizedBox.shrink()),
      );
    }

    return ListenableBuilder(
      listenable: media,
      builder: (BuildContext context, _) {
        final Map<String, GroupCallPeerView> peers = media.peers;
        final List<String> participants = activeCall.participantAddresses;
        final int elapsed =
            ((DateTime.now().millisecondsSinceEpoch -
                        activeCall.startedAtMillis) ~/
                    1000)
                .clamp(0, 1 << 30);
        final RTCVideoRenderer? localRenderer = media.localRenderer;
        return Scaffold(
          backgroundColor: zen.background,
          body: DecoratedBox(
            decoration: BoxDecoration(gradient: callStageGradient(zen)),
            child: SafeArea(
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          key: const Key('group-call-minimize'),
                          tooltip: 'Minimalizuj',
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 28,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'Połączenie grupowe',
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
                                group?.name ?? widget.groupName,
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                participants.isEmpty
                                    ? 'Czekasz, aż ktoś dołączy'
                                    : 'W rozmowie: ${participants.length + 1} os.',
                                key: const Key('group-call-headcount'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        CallFloatOverAppsButton(color: zen.textPrimary),
                        const SizedBox(width: 4),
                        _StatusPill(label: _formatDuration(elapsed)),
                      ],
                    ),
                  ),
                  if (media.isRecording || media.recordingPeers.isNotEmpty)
                    Container(
                      key: const Key('group-call-recording-banner'),
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: zen.danger.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: zen.danger.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.fiber_manual_record,
                            size: 14,
                            color: zen.danger,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              <String>[
                                if (media.isRecording) 'Nagrywasz tę rozmowę',
                                for (final String a in media.recordingPeers)
                                  '${_nameFor(a, friends, group)} nagrywa',
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
                        ],
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                              final int count = 1 + participants.length;
                              final int columns = constraints.maxWidth > 700
                                  ? (count > 4 ? 3 : 2)
                                  : (count > 2 ? 2 : 1);
                              final int rows = (count / columns).ceil();
                              final double tileHeight =
                                  (constraints.maxHeight - (rows - 1) * 10) /
                                  rows;
                              final double tileWidth =
                                  (constraints.maxWidth - (columns - 1) * 10) /
                                  columns;
                              final double ratio = tileHeight <= 0
                                  ? 1
                                  : (tileWidth / tileHeight).clamp(0.6, 1.8);
                              return GridView.count(
                                crossAxisCount: columns,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: ratio,
                                children: <Widget>[
                                  _ParticipantTile(
                                    key: const Key('group-call-tile-self'),
                                    name: myName.trim().isEmpty
                                        ? 'Ty'
                                        : '${myName.trim()} (Ty)',
                                    isSelf: true,
                                    isMuted: activeCall.isMuted,
                                    renderer:
                                        activeCall.isCameraEnabled ||
                                            media.isScreenSharing
                                        ? localRenderer
                                        : null,
                                    sharingScreen: media.isScreenSharing,
                                  ),
                                  for (final String address in participants)
                                    _ParticipantTile(
                                      key: Key('group-call-tile-$address'),
                                      name: _nameFor(address, friends, group),
                                      isSelf: false,
                                      isMuted: false,
                                      state:
                                          peers[address]?.state ??
                                          GroupCallLegState.connecting,
                                      renderer:
                                          peers[address]?.hasVideo ?? false
                                          ? peers[address]?.renderer
                                          : null,
                                      sharingScreen:
                                          peers[address]?.sharingScreen ??
                                          false,
                                    ),
                                ],
                              );
                            },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: DecoratedBox(
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        child: _buildControls(zen, media, activeCall),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Recording is announced to everyone first; the file goes into the
  /// encrypted store by itself, also when the call ends while recording.
  Future<void> _toggleRecording(GroupCallMedia media, String label) async {
    if (!media.isRecording) {
      final Directory temp = await getTemporaryDirectory();
      await media.startRecording(
        '${temp.path}/zen_rec_${DateTime.now().millisecondsSinceEpoch}'
        '.${media.recordingExtension}',
        label: label,
      );
      return;
    }
    final String? path = await media.stopRecording();
    if (path != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Nagranie zapisane (zaszyfrowane).')),
      );
    }
  }

  Future<void> _toggleScreenShare(GroupCallMedia media) async {
    if (media.isScreenSharing) {
      await media.stopScreenShare();
      return;
    }
    final List<ScreenShareSource> sources = await media.listScreenSources();
    String? sourceId;
    if (sources.isNotEmpty) {
      if (!mounted) {
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
    await media.startScreenShare(sourceId: sourceId);
  }

  Widget _buildControls(ZenColors zen, GroupCallMedia media, CallSession call) {
    final bool animateEntrance = !_controlsEntrancePlayed;
    _controlsEntrancePlayed = true;
    final SocialHubController controller = ref.read(
      socialHubControllerProvider.notifier,
    );
    ButtonStyle toggleStyle(bool on, {Color? onColor}) => IconButton.styleFrom(
      backgroundColor: on
          ? (onColor ?? zen.accent).withValues(alpha: 0.18)
          : zen.surfaceRaised,
      foregroundColor: on ? (onColor ?? zen.accent) : zen.textPrimary,
      minimumSize: const Size(50, 50),
      fixedSize: const Size(50, 50),
      iconSize: 24,
      shape: CircleBorder(
        side: BorderSide(
          color: on
              ? (onColor ?? zen.accent).withValues(alpha: 0.4)
              : zen.outlineSoft,
        ),
      ),
    );
    final Widget controls = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        IconButton.filledTonal(
          key: const Key('group-call-mute'),
          tooltip: call.isMuted ? 'Włącz mikrofon' : 'Wycisz mikrofon',
          style: toggleStyle(call.isMuted, onColor: zen.danger),
          icon: Icon(call.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded),
          onPressed: () =>
              runCallAction(context, controller.toggleActiveCallMute),
        ),
        IconButton.filledTonal(
          key: const Key('group-call-camera'),
          tooltip: call.isCameraEnabled ? 'Wyłącz kamerę' : 'Włącz kamerę',
          style: toggleStyle(call.isCameraEnabled),
          icon: Icon(
            call.isCameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
          ),
          onPressed: () =>
              runCallAction(context, controller.toggleActiveCallCamera),
        ),
        if (call.isCameraEnabled)
          IconButton.filledTonal(
            tooltip: 'Przełącz kamerę',
            style: toggleStyle(false),
            icon: const Icon(Icons.flip_camera_ios_rounded),
            onPressed: () => runCallAction(context, media.switchCamera),
          ),
        IconButton.filledTonal(
          key: const Key('group-call-screen-share'),
          tooltip: media.isScreenSharing
              ? 'Zatrzymaj udostępnianie'
              : 'Udostępnij ekran',
          style: toggleStyle(media.isScreenSharing),
          icon: Icon(
            media.isScreenSharing
                ? Icons.stop_screen_share_rounded
                : Icons.screen_share_outlined,
          ),
          onPressed: () =>
              runCallAction(context, () => _toggleScreenShare(media)),
        ),
        if (media.canRecord)
          IconButton.filledTonal(
            key: const Key('group-call-record'),
            tooltip: media.isRecording ? 'Zatrzymaj nagrywanie' : 'Nagrywaj',
            style: toggleStyle(media.isRecording, onColor: zen.danger),
            icon: Icon(
              media.isRecording
                  ? Icons.stop_rounded
                  : Icons.fiber_manual_record,
              color: zen.danger,
            ),
            onPressed: () => runCallAction(
              context,
              () => _toggleRecording(
                media,
                ref
                        .read(socialHubControllerProvider)
                        .groupById(widget.groupId)
                        ?.name ??
                    widget.groupName,
              ),
            ),
          ),
        IconButton.filledTonal(
          key: const Key('group-call-speaker'),
          tooltip: call.isSpeakerOn ? 'Głośnik' : 'Słuchawka',
          style: toggleStyle(call.isSpeakerOn),
          icon: Icon(
            call.isSpeakerOn ? Icons.volume_up_rounded : Icons.hearing_rounded,
          ),
          onPressed: () =>
              runCallAction(context, controller.toggleActiveCallSpeaker),
        ),
        IconButton.filled(
          key: const Key('group-call-leave'),
          tooltip: 'Opuść połączenie',
          style: IconButton.styleFrom(
            backgroundColor: zen.danger,
            foregroundColor: ZenColors.foregroundFor(zen.danger),
            fixedSize: const Size(58, 58),
            minimumSize: const Size(58, 58),
            shape: const CircleBorder(),
          ),
          icon: const Icon(Icons.call_end_rounded, size: 26),
          onPressed: () {
            unawaited(
              runCallAction(
                context,
                () => controller.endActiveCall(peerAddress: widget.groupId),
              ),
            );
            Navigator.of(context).maybePop();
          },
        ),
      ],
    );
    if (!animateEntrance) {
      return controls;
    }
    return ZenFadeSlide(
      duration: const Duration(milliseconds: 320),
      offset: const Offset(0, 10),
      child: controls,
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: zen.success.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: zen.success.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ZenPulsingDot(color: zen.success, dimension: 8, dotSize: 4),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: zen.success,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    super.key,
    required this.name,
    required this.isSelf,
    required this.isMuted,
    this.state = GroupCallLegState.connected,
    this.renderer,
    this.sharingScreen = false,
  });

  final String name;
  final bool isSelf;
  final bool isMuted;
  final GroupCallLegState state;
  final RTCVideoRenderer? renderer;

  /// Shows "udostępnia ekran" on the tile (§13.1): everyone sees who shares.
  final bool sharingScreen;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final RTCVideoRenderer? video = renderer;
    final bool renderVideo =
        video != null && video.textureId != null && video.srcObject != null;
    final String? stateLabel = switch (state) {
      GroupCallLegState.connected => null,
      GroupCallLegState.connecting => 'Łączenie…',
      GroupCallLegState.failed => 'Ponowne łączenie…',
    };
    final Color tone = zenTone(zen, (name.hashCode & 0x7FFFFFFF) % 8);
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              Color.alphaBlend(
                tone.withValues(alpha: 0.16),
                const Color(0xFF14141E),
              ),
              const Color(0xFF101017),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isSelf
                ? zen.accent.withValues(alpha: 0.4)
                : zen.outlineStrong.withValues(alpha: 0.35),
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            if (sharingScreen)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  key: const Key('group-call-sharing-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: zen.accent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isSelf ? 'Udostępniasz ekran' : 'Udostępnia ekran',
                    style: TextStyle(
                      color: zen.onAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            if (renderVideo)
              Positioned.fill(
                child: RTCVideoView(
                  video,
                  mirror: isSelf,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: <Color>[
                          tone,
                          Color.lerp(tone, zen.accentSecondary, 0.4)!,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Text(
                      name.isNotEmpty
                          ? name.characters.first.toUpperCase()
                          : '?',
                      style: zen.display(
                        color: ZenColors.foregroundFor(tone),
                        size: 26,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (stateLabel != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      stateLabel,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            Positioned(
              left: 8,
              bottom: 8,
              right: 8,
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (isSelf && isMuted)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: zen.danger,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.mic_off_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
