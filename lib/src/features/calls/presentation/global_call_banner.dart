import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/presentation/call_session_widgets.dart';

class GlobalCallBanner extends StatelessWidget {
  const GlobalCallBanner({
    required this.session,
    required this.onOpenConversation,
    super.key,
    this.onOpenCallSurface,
    this.onAccept,
    this.onDecline,
    this.onEnd,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.onToggleCamera,
  });

  final CallSession session;
  final VoidCallback onOpenConversation;
  final VoidCallback? onOpenCallSurface;
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
        session.isIncoming && session.status == CallSessionStatus.ringing;
    final bool active = session.status == CallSessionStatus.active;
    final Widget callIcon = DecoratedBox(
      decoration: BoxDecoration(
        color: incomingRinging
            ? zen.warning.withValues(alpha: 0.14)
            : zen.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
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
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: zen.panelGradient(
          tone: incomingRinging ? zen.warning : zen.accent,
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: incomingRinging
              ? zen.warning.withValues(alpha: 0.6)
              : zen.accent.withValues(alpha: 0.4),
        ),
        boxShadow: zen.elevationShadow(
          elevation: 8,
          ambientColor: incomingRinging ? zen.warning : zen.accent,
          ambientAlpha: 0.16,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (active)
                  callIcon
                else
                  ZenPulseRings(
                    color: incomingRinging ? zen.warning : zen.accent,
                    baseSize: 44,
                    child: callIcon,
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      if (session.status == CallSessionStatus.ringing ||
                          session.status == CallSessionStatus.connecting)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                _subtitle,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 5,
                                bottom: 3,
                              ),
                              child: ZenAnimatedDots(
                                color: incomingRinging
                                    ? zen.warning
                                    : zen.accent,
                                size: 3,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          _subtitle,
                          style: TextStyle(
                            color: zen.textSecondary,
                            height: 1.4,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (active) ...<Widget>[
              const SizedBox(height: 12),
              CallStateChips(session: session),
            ],
            const SizedBox(height: 14),
            CallActionBar(
              session: session,
              keyPrefix: 'global-call',
              leadingActions: <Widget>[
                FilledButton.tonalIcon(
                  key: const Key('global-call-open-button'),
                  onPressed: onOpenConversation,
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: Text(t('Otwórz czat')),
                ),
                if (onOpenCallSurface != null)
                  FilledButton.tonalIcon(
                    key: const Key('global-call-surface-button'),
                    onPressed: onOpenCallSurface,
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
    );
  }

  String get _title {
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

  String get _subtitle => switch (session.status) {
    CallSessionStatus.ringing when session.isIncoming => t(
      '{name} czeka na odebranie w dowolnej zakładce.',
      {'name': session.displayName},
    ),
    CallSessionStatus.ringing => t('Czekasz, aż {name} odbierze połączenie.', {
      'name': session.displayName,
    }),
    CallSessionStatus.connecting => t(
      'Nawiązywanie bezpiecznego połączenia...',
    ),
    CallSessionStatus.active => t(
      'Aktywna sesja z {name} jest pod ręką w całej aplikacji.',
      {'name': session.displayName},
    ),
  };
}
