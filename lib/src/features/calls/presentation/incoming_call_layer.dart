import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/calls/presentation/call_action_runner.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

class IncomingCallLayer extends ConsumerWidget {
  const IncomingCallLayer({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CallSession? session = ref.watch(
      socialHubControllerProvider.select((SocialHubState state) {
        final CallSession? active = state.activeCall;
        if (active == null ||
            !active.isIncoming ||
            active.status != CallSessionStatus.ringing) {
          return null;
        }
        return active;
      }),
    );
    if (session == null) {
      return child;
    }
    return Stack(
      children: <Widget>[
        child,
        Positioned.fill(child: _IncomingCallOverlay(session: session)),
      ],
    );
  }
}

class _IncomingCallOverlay extends ConsumerStatefulWidget {
  const _IncomingCallOverlay({required this.session});

  final CallSession session;

  @override
  ConsumerState<_IncomingCallOverlay> createState() =>
      _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends ConsumerState<_IncomingCallOverlay> {
  @override
  void initState() {
    super.initState();
    // Only while the in-app overlay is up: show this activity over the
    // keyguard if the user locks the phone. Never dismiss the keyguard
    // here — that puts the PIN pad on the accept/decline buttons.
    unawaited(setRingingCallWindowActive(true));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref
              .read(socialHubControllerProvider.notifier)
              .markCallPopupPresented(
                widget.session.peerAddress,
                widget.session.id,
              ),
        );
      }
    });
  }

  @override
  void dispose() {
    unawaited(setRingingCallWindowActive(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CallSession session = widget.session;
    final ZenColors zen = ZenColors.of(context);
    final bool video = session.kind == CallInviteKind.video;
    // The ringing card: a raised panel of the theme, lit by its accent.
    final ZenLook look = ZenLook.of(context);
    final Color stage = zen.surfaceRaised;
    final Color onStage = zen.textPrimary;
    final Color onStageSoft = zen.textSecondary;
    final String kindLabel = video
        ? (session.isGroup
              ? t('Grupowe połączenie wideo')
              : t('Połączenie wideo'))
        : (session.isGroup
              ? t('Grupowe połączenie audio')
              : t('Połączenie audio'));

    Future<void> decline() => runCallAction(
      context,
      () => ref
          .read(socialHubControllerProvider.notifier)
          .declineIncomingCall(peerAddress: session.peerAddress),
    );

    void accept() {
      // Resolved up front: the overlay can be torn down by the accept itself.
      final NavigatorState? navigator = Navigator.maybeOf(
        context,
        rootNavigator: true,
      );
      unawaited(
        runCallAction(context, () async {
          await ref
              .read(socialHubControllerProvider.notifier)
              .acceptIncomingCall(peerAddress: session.peerAddress);
          if (session.isGroup && session.groupId != null) {
            unawaited(
              openGroupCallSurface(
                groupId: session.groupId!,
                groupName: session.displayName,
                initialVideo: session.kind == CallInviteKind.video,
                fallbackNavigator: navigator,
              ),
            );
          } else {
            unawaited(
              openCallSurface(
                peerAddress: session.peerAddress,
                title: session.displayName,
                fallbackNavigator: navigator,
              ),
            );
          }
        }),
      );
    }

    return Material(
      // A veil of the theme over the app below.
      color: zen.surfaceSunk.withValues(alpha: 0.82),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: ZenFadeSlide(
                  duration: const Duration(milliseconds: 380),
                  offset: const Offset(0, 20),
                  child: DecoratedBox(
                    key: const Key('incoming-call-overlay'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          Color.alphaBlend(
                            zen.accent.withValues(alpha: 0.30),
                            stage,
                          ),
                          Color.alphaBlend(
                            zen.accentSecondary.withValues(alpha: 0.10),
                            stage,
                          ),
                          stage,
                        ],
                        stops: const <double>[0, 0.55, 1],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: context.zenRadius(32),
                      border: Border.all(color: zen.outlineSoft),
                      boxShadow: look.tinted(
                        zen,
                        zen.accent,
                        radius: 40,
                        alpha: 0.25,
                        offset: const Offset(0, 12),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: zen.textPrimary.withValues(alpha: 0.08),
                              borderRadius: context.zenRadius(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  ZenPulsingDot(
                                    color: zen.success,
                                    active: true,
                                    dimension: 10,
                                    dotSize: 6,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      kindLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: onStageSoft,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 28),
                          ZenPulseRings(
                            color: zen.accent,
                            baseSize: 84,
                            ringCount: 2,
                            child: Container(
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: <Color>[
                                    zen.accent,
                                    Color.lerp(
                                      zen.accent,
                                      zen.accentSecondary,
                                      0.5,
                                    )!,
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: Icon(
                                video
                                    ? Icons.videocam_rounded
                                    : (session.isGroup
                                          ? Icons.groups_rounded
                                          : Icons.call_rounded),
                                size: 44,
                                color: zen.onAccent,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            session.displayName,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: zen.display(
                              color: onStage,
                              size: 26,
                              weight: FontWeight.w600,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            session.isGroup
                                ? (session.participantAddresses.isEmpty
                                      ? t(
                                          'Rozmowa grupowa - dołącz, kiedy '
                                          'chcesz',
                                        )
                                      : tn(
                                          session.participantAddresses.length,
                                          one:
                                              'W rozmowie: {n} os. - dołącz, '
                                              'kiedy chcesz',
                                          few:
                                              'W rozmowie: {n} os. - dołącz, '
                                              'kiedy chcesz',
                                          many:
                                              'W rozmowie: {n} os. - dołącz, '
                                              'kiedy chcesz',
                                        ))
                                : (video
                                      ? t('Zaproszenie do rozmowy wideo')
                                      : t('Zaproszenie do rozmowy głosowej')),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: onStageSoft,
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 32),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _RoundCallAction(
                                buttonKey: const Key(
                                  'incoming-call-decline-button',
                                ),
                                icon: Icons.call_end_rounded,
                                label: t('Odrzuć'),
                                color: zen.danger,
                                labelColor: onStageSoft,
                                onPressed: decline,
                              ),
                              _RoundCallAction(
                                buttonKey: const Key(
                                  'incoming-call-accept-button',
                                ),
                                icon: video && !session.isGroup
                                    ? Icons.videocam_rounded
                                    : Icons.call_rounded,
                                label: session.isGroup
                                    ? t('Dołącz')
                                    : t('Odbierz'),
                                color: zen.success,
                                labelColor: onStageSoft,
                                onPressed: accept,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A big round call button (accept / decline) with its label underneath.
class _RoundCallAction extends StatelessWidget {
  const _RoundCallAction({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.color,
    required this.labelColor,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final Color color;
  final Color labelColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: ZenLook.of(context).tinted(
              ZenColors.of(context),
              color,
              radius: 22,
              alpha: 0.45,
              offset: const Offset(0, 6),
            ),
          ),
          child: IconButton.filled(
            key: buttonKey,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: color,
              foregroundColor: ZenColors.foregroundFor(color),
              fixedSize: const Size(72, 72),
              minimumSize: const Size(72, 72),
              shape: const CircleBorder(),
            ),
            icon: Icon(icon, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(
            color: labelColor,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
