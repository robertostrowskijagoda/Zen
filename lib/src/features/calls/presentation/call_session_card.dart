import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/presentation/call_session_widgets.dart';

class CallSessionCard extends StatelessWidget {
  const CallSessionCard({
    required this.session,
    super.key,
    this.onOpenSurface,
    this.onAccept,
    this.onDecline,
    this.onEnd,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleCamera,
  });

  final CallSession session;
  final VoidCallback? onOpenSurface;
  final Future<void> Function()? onAccept;
  final Future<void> Function()? onDecline;
  final Future<void> Function()? onEnd;
  final Future<void> Function()? onToggleMute;
  final Future<void> Function()? onToggleSpeaker;
  final Future<void> Function()? onToggleCamera;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool incomingRinging =
        session.status == CallSessionStatus.ringing && session.isIncoming;
    final bool active = session.status == CallSessionStatus.active;
    final bool video = session.kind == CallInviteKind.video;
    final String title = switch (session.status) {
      CallSessionStatus.ringing when session.isIncoming =>
        video
            ? t('Przychodząca rozmowa wideo')
            : t('Przychodząca rozmowa audio'),
      CallSessionStatus.ringing =>
        video ? t('Dzwonienie (wideo)...') : t('Dzwonienie (audio)...'),
      CallSessionStatus.connecting => t('Łączenie...'),
      CallSessionStatus.active =>
        video ? t('Rozmowa wideo trwa') : t('Rozmowa audio trwa'),
    };
    final String body = switch (session.status) {
      CallSessionStatus.ringing when session.isIncoming => t(
        '{name} czeka na odbiór.',
        {'name': session.displayName},
      ),
      CallSessionStatus.ringing => t(
        'Czekasz, aż {name} odbierze połączenie.',
        {'name': session.displayName},
      ),
      CallSessionStatus.connecting => t(
        'Nawiązywanie bezpiecznego połączenia...',
      ),
      CallSessionStatus.active => t('Sesja z {name} jest już aktywna.', {
        'name': session.displayName,
      }),
    };

    return ZenFadeSlide(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: zen.panelGradient(
              tone: incomingRinging ? zen.warning : zen.accent,
              alpha: 0.09,
            ),
            borderRadius: context.zenRadius(22),
            border: Border.all(
              color: incomingRinging
                  ? zen.warning.withValues(alpha: 0.6)
                  : zen.accent.withValues(alpha: 0.35),
            ),
            boxShadow: zen.elevationShadow(
              elevation: 6,
              ambientColor: incomingRinging ? zen.warning : zen.accent,
              ambientAlpha: 0.14,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: incomingRinging
                        ? zen.warning.withValues(alpha: 0.14)
                        : zen.surfaceMuted,
                    borderRadius: context.zenRadius(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      session.kind == CallInviteKind.video
                          ? Icons.videocam_outlined
                          : Icons.call_outlined,
                      color: incomingRinging ? zen.warning : zen.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: zen.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                      if (active) ...<Widget>[
                        const SizedBox(height: 10),
                        CallStateChips(session: session),
                      ],
                      const SizedBox(height: 12),
                      CallActionBar(
                        session: session,
                        leadingActions: onOpenSurface == null
                            ? const <Widget>[]
                            : <Widget>[
                                FilledButton.tonalIcon(
                                  key: const Key('call-surface-button'),
                                  onPressed: onOpenSurface,
                                  icon: const Icon(Icons.fullscreen_rounded),
                                  label: Text(t('Pełny ekran')),
                                ),
                              ],
                        onAccept: onAccept,
                        onDecline: onDecline,
                        onEnd: onEnd,
                        onToggleMute: onToggleMute,
                        onToggleSpeaker: onToggleSpeaker,
                        onToggleCamera: onToggleCamera,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
