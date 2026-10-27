import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_compact_mode.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/presentation/call_session_widgets.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Whether [session] is a call worth keeping on screen over other apps.
bool callWantsFloatingWindow(CallSession? session) =>
    session != null &&
    (session.status == CallSessionStatus.active ||
        session.status == CallSessionStatus.connecting ||
        (!session.isIncoming && session.status == CallSessionStatus.ringing));

/// Keeps [CallCompactMode] in step with the current call and, while the
/// call floats over other apps, shows only the small call view (the rest of
/// the app stays alive underneath, off screen).
class CallCompactLayer extends ConsumerStatefulWidget {
  const CallCompactLayer({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<CallCompactLayer> createState() => _CallCompactLayerState();
}

class _CallCompactLayerState extends ConsumerState<CallCompactLayer> {
  final CallCompactMode _mode = CallCompactMode.instance;

  @override
  void initState() {
    super.initState();
    _mode.onHangUp = _hangUp;
    _sync(ref.read(socialHubControllerProvider).activeCall);
  }

  @override
  void dispose() {
    if (_mode.onHangUp == _hangUp) {
      _mode.onHangUp = null;
    }
    super.dispose();
  }

  Future<void> _hangUp() async {
    final CallSession? session = ref
        .read(socialHubControllerProvider)
        .activeCall;
    if (session == null) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .endActiveCall(peerAddress: session.peerAddress);
  }

  void _sync(CallSession? session) {
    _mode.updateCall(
      running: callWantsFloatingWindow(session),
      video:
          session?.kind == CallInviteKind.video && !(session?.isGroup ?? false),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<CallSession?>(
      socialHubControllerProvider.select((SocialHubState s) => s.activeCall),
      (CallSession? previous, CallSession? next) => _sync(next),
    );
    final CallSession? session = ref.watch(
      socialHubControllerProvider.select((SocialHubState s) => s.activeCall),
    );
    return ValueListenableBuilder<bool>(
      valueListenable: _mode.active,
      builder: (BuildContext context, bool compact, Widget? child) {
        final bool show = compact && session != null;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Offstage(offstage: show, child: child),
            // Its own overlay: the app's (under the Navigator) is off
            // screen now, and tooltips need one.
            if (show) Overlay.wrap(child: CallCompactView(session: session)),
          ],
        );
      },
      child: widget.child,
    );
  }
}

/// The call, small: who, how long, the other side's video when there is
/// one. On a computer it also has buttons (mute, back to the full window,
/// hang up) and can be dragged; in Android's picture-in-picture the system
/// draws the buttons.
class CallCompactView extends ConsumerStatefulWidget {
  const CallCompactView({
    required this.session,
    this.interactive,
    this.now,
    super.key,
  });

  final CallSession session;

  /// Whether the view draws its own buttons; by default only on a
  /// computer (Android's picture-in-picture has the system's).
  final bool? interactive;

  /// The clock the call's length is read from; the system's by default.
  final DateTime Function()? now;

  @override
  ConsumerState<CallCompactView> createState() => _CallCompactViewState();
}

class _CallCompactViewState extends ConsumerState<CallCompactView> {
  Timer? _ticker;

  DateTime _now() => (widget.now ?? DateTime.now)();

  bool get _interactive =>
      widget.interactive ??
      (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS));

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _status(CallSession s) {
    if (s.status == CallSessionStatus.ringing) {
      return t('Dzwonienie…');
    }
    if (s.status != CallSessionStatus.active || s.startedAtMillis <= 0) {
      return t('Łączenie…');
    }
    final int seconds =
        ((_now().millisecondsSinceEpoch - s.startedAtMillis) ~/ 1000).clamp(
          0,
          86400,
        );
    final String mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final String ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final CallSession s = widget.session;
    final CallMediaSessionController media = ref.watch(
      callMediaSessionControllerProvider,
    );
    final Widget body = ListenableBuilder(
      listenable: media,
      builder: (BuildContext context, Widget? _) {
        final RTCVideoRenderer? remote =
            !s.isGroup &&
                media.activeCallId == s.id &&
                media.hasRemoteVideo &&
                media.remoteRenderer?.srcObject != null
            ? media.remoteRenderer
            : null;
        // Over the remote video the type stays white on a shadow
        // (see ZenFixed); otherwise it follows the theme.
        final TextStyle status = TextStyle(
          color: remote != null ? ZenFixed.onPhoto : zen.textSecondary,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          shadows: remote != null
              ? const <Shadow>[Shadow(blurRadius: 4)]
              : null,
        );
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(gradient: callStageGradient(zen)),
            ),
            if (remote != null)
              RTCVideoView(
                remote,
                key: const Key('call-compact-video'),
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              Center(
                child: _Who(session: s, zen: zen, buttons: _interactive),
              ),
            Positioned(
              left: 8,
              top: 6,
              right: 8,
              // Over the video: the name gives way, the time always shows.
              child: remote != null
                  ? Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            s.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: status,
                          ),
                        ),
                        Text(
                          ' · ${_status(s)}',
                          key: const Key('call-compact-status'),
                          maxLines: 1,
                          style: status,
                        ),
                      ],
                    )
                  : Text(
                      _status(s),
                      key: const Key('call-compact-status'),
                      textAlign: TextAlign.center,
                      // Longer translations of "connecting" wrap.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: status,
                    ),
            ),
            if (_interactive)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: _DesktopButtons(session: s, zen: zen),
              ),
          ],
        );
      },
    );
    return Material(
      key: const Key('call-compact-view'),
      color: zen.background,
      // On a computer the window has no title bar now: drag it by the call.
      child: _interactive ? DragToMoveArea(child: body) : body,
    );
  }
}

class _Who extends StatelessWidget {
  const _Who({required this.session, required this.zen, required this.buttons});

  final CallSession session;
  final ZenColors zen;

  /// Whether the view's own buttons sit under it (room is kept for them).
  final bool buttons;

  @override
  Widget build(BuildContext context) {
    final String name = session.displayName.trim();
    final Widget avatar = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
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
      ),
      child: session.isGroup
          ? Icon(Icons.groups_rounded, color: zen.onAccent)
          : Text(
              name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: zen.display(
                color: zen.onAccent,
                size: 20,
                weight: FontWeight.w600,
              ),
            ),
    );
    final TextStyle style = TextStyle(
      color: zen.textPrimary,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // Android's picture-in-picture can be ~108 dp wide: the name goes
        // under the picture, on one line, instead of beside it.
        final bool narrow = box.maxWidth < 160;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            narrow ? 6 : 12,
            22,
            narrow ? 6 : 12,
            buttons ? 52 : 8,
          ),
          child: narrow
              ? Column(
                  key: const Key('call-compact-who-narrow'),
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: FittedBox(fit: BoxFit.scaleDown, child: avatar),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      name.isEmpty ? t('Rozmowa') : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: style,
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    avatar,
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        name.isEmpty ? t('Rozmowa') : name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _DesktopButtons extends ConsumerWidget {
  const _DesktopButtons({required this.session, required this.zen});

  final CallSession session;
  final ZenColors zen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (session.status == CallSessionStatus.active)
          IconButton.filledTonal(
            key: const Key('call-compact-mute'),
            tooltip: session.isMuted ? t('Włącz mikrofon') : t('Wycisz'),
            onPressed: () => unawaited(hub.toggleActiveCallMute()),
            icon: Icon(
              session.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            ),
          ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          key: const Key('call-compact-expand'),
          tooltip: t('Wróć do pełnego okna'),
          onPressed: () => unawaited(CallCompactMode.instance.exitDesktop()),
          icon: const Icon(Icons.open_in_full_rounded),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          key: const Key('call-compact-hang-up'),
          tooltip: t('Rozłącz'),
          style: IconButton.styleFrom(
            backgroundColor: zen.danger,
            foregroundColor: ZenColors.foregroundFor(zen.danger),
          ),
          onPressed: () =>
              unawaited(hub.endActiveCall(peerAddress: session.peerAddress)),
          icon: const Icon(Icons.call_end_rounded),
        ),
      ],
    );
  }
}

/// "Mini okno" for the call screens on computers: the call keeps floating
/// over other windows while you work.
class CallFloatOverAppsButton extends StatelessWidget {
  const CallFloatOverAppsButton({required this.color, super.key});

  final Color color;

  static bool get available =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      CallCompactMode.instance.desktopWindowReady;

  @override
  Widget build(BuildContext context) {
    if (!available) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('call-float-over-apps'),
      tooltip: t('Mini okno nad innymi aplikacjami'),
      onPressed: () => unawaited(CallCompactMode.instance.enterDesktop()),
      icon: Icon(Icons.picture_in_picture_alt_rounded, color: color),
    );
  }
}
