import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

final NotifierProvider<CallSurfaceActiveController, bool>
callSurfaceActiveProvider = NotifierProvider<CallSurfaceActiveController, bool>(
  CallSurfaceActiveController.new,
);

class CallSurfaceActiveController extends Notifier<bool> {
  @override
  bool build() => false;

  void setActive(bool value) {
    if (!ref.mounted) {
      return;
    }
    state = value;
  }
}

class CallFloatingOverlay extends ConsumerWidget {
  const CallFloatingOverlay({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CallSession? activeCall = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.activeCall,
      ),
    );
    final bool isSurfaceActive = ref.watch(callSurfaceActiveProvider);

    final bool showFloatingChip =
        activeCall != null &&
        !isSurfaceActive &&
        (activeCall.status == CallSessionStatus.active ||
            activeCall.status == CallSessionStatus.connecting ||
            (!activeCall.isIncoming &&
                activeCall.status == CallSessionStatus.ringing));

    return Stack(
      children: <Widget>[
        child,
        if (showFloatingChip)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: _FloatingCallChip(session: activeCall),
              ),
            ),
          ),
      ],
    );
  }
}

class _FloatingCallChip extends ConsumerStatefulWidget {
  const _FloatingCallChip({required this.session});

  final CallSession session;

  @override
  ConsumerState<_FloatingCallChip> createState() => _FloatingCallChipState();
}

class _FloatingCallChipState extends ConsumerState<_FloatingCallChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formattedDuration() {
    if (widget.session.status == CallSessionStatus.ringing) {
      return widget.session.isIncoming
          ? t('Przychodzące...')
          : t('Dzwonienie...');
    }
    if (widget.session.status != CallSessionStatus.active) {
      return t('Łączenie...');
    }
    final int start = widget.session.startedAtMillis;
    if (start <= 0) {
      return '00:00';
    }
    final int elapsedSeconds =
        ((DateTime.now().millisecondsSinceEpoch - start) / 1000)
            .clamp(0, 86400)
            .toInt();
    final int minutes = elapsedSeconds ~/ 60;
    final int seconds = elapsedSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final CallSession session = widget.session;
    final bool active = session.status == CallSessionStatus.active;

    return Material(
      color: Colors.transparent,
      child: ZenFadeSlide(
        duration: const Duration(milliseconds: 380),
        offset: const Offset(0, -14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Color.alphaBlend(
              zen.success.withValues(alpha: 0.14),
              zen.surfaceRaised,
            ),
            shape: StadiumBorder(
              side: BorderSide(color: zen.success.withValues(alpha: 0.35)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('floating-call-chip'),
              customBorder: const StadiumBorder(),
              onTap: () {
                if (session.isGroup && session.groupId != null) {
                  unawaited(
                    openGroupCallSurface(
                      groupId: session.groupId!,
                      groupName: session.displayName,
                      initialVideo: session.kind == CallInviteKind.video,
                      fallbackNavigator: Navigator.maybeOf(
                        context,
                        rootNavigator: true,
                      ),
                    ),
                  );
                } else {
                  unawaited(
                    openCallSurface(
                      peerAddress: session.peerAddress,
                      title: session.displayName,
                      fallbackNavigator: Navigator.maybeOf(
                        context,
                        rootNavigator: true,
                      ),
                    ),
                  );
                }
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: zen.success.withValues(alpha: 0.18),
                      ),
                      child: Icon(
                        session.kind == CallInviteKind.video
                            ? Icons.videocam_rounded
                            : Icons.call_rounded,
                        size: 18,
                        color: zen.success,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            session.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              ZenPulsingDot(
                                color: zen.success,
                                active: true,
                                dimension: 10,
                                dotSize: 5,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _formattedDuration(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: zen.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const <FontFeature>[
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (active) ...<Widget>[
                      IconButton(
                        key: const Key('global-call-mute-button'),
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: Icon(
                          session.isMuted
                              ? Icons.mic_off_rounded
                              : Icons.mic_none_rounded,
                          color: session.isMuted
                              ? zen.danger
                              : zen.textSecondary,
                        ),
                        onPressed: () => runCallAction(
                          context,
                          ref
                              .read(socialHubControllerProvider.notifier)
                              .toggleActiveCallMute,
                        ),
                      ),
                      IconButton(
                        key: const Key('global-call-speaker-button'),
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: Icon(
                          session.isSpeakerOn
                              ? Icons.volume_up_rounded
                              : Icons.hearing_rounded,
                          color: session.isSpeakerOn
                              ? zen.accent
                              : zen.textSecondary,
                        ),
                        onPressed: () => runCallAction(
                          context,
                          ref
                              .read(socialHubControllerProvider.notifier)
                              .toggleActiveCallSpeaker,
                        ),
                      ),
                      IconButton(
                        key: const Key('global-call-camera-button'),
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: Icon(
                          session.isCameraEnabled
                              ? Icons.videocam_rounded
                              : Icons.videocam_off_rounded,
                          color: session.isCameraEnabled
                              ? zen.accent
                              : zen.textSecondary,
                        ),
                        onPressed: () => runCallAction(
                          context,
                          ref
                              .read(socialHubControllerProvider.notifier)
                              .toggleActiveCallCamera,
                        ),
                      ),
                    ],
                    IconButton(
                      key: const Key('global-call-end-button'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      style: IconButton.styleFrom(
                        backgroundColor: zen.danger,
                        foregroundColor: ZenColors.foregroundFor(zen.danger),
                        shape: const CircleBorder(),
                      ),
                      icon: const Icon(Icons.call_end_rounded),
                      onPressed: () => runCallAction(
                        context,
                        () => ref
                            .read(socialHubControllerProvider.notifier)
                            .endActiveCall(
                              peerAddress:
                                  (session.isGroup && session.groupId != null)
                                  ? session.groupId!
                                  : session.peerAddress,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
