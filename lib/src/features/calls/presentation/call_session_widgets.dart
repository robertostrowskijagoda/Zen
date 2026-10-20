import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

class CallStateChips extends StatelessWidget {
  const CallStateChips({required this.session, super.key});

  final CallSession session;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        CallStateChip(
          icon: session.isMuted
              ? Icons.mic_off_rounded
              : Icons.mic_none_rounded,
          label: session.isMuted ? t('Wyciszony') : t('Mikrofon'),
        ),
        CallStateChip(
          icon: session.isSpeakerOn
              ? Icons.volume_up_rounded
              : Icons.hearing_rounded,
          label: session.isSpeakerOn ? t('Głośnik') : t('Słuchawka'),
        ),
        if (session.kind == CallInviteKind.video)
          CallStateChip(
            icon: session.isCameraEnabled
                ? Icons.videocam_outlined
                : Icons.videocam_off_outlined,
            label: session.isCameraEnabled ? t('Kamera') : t('Kamera wył.'),
          ),
      ],
    );
  }
}

class CallActionBar extends StatelessWidget {
  const CallActionBar({
    required this.session,
    super.key,
    this.leadingActions = const <Widget>[],
    this.keyPrefix = 'call',
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
  final List<Widget> leadingActions;
  final String keyPrefix;
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
    final ZenColors zen = ZenColors.of(context);
    final bool incomingRinging =
        session.status == CallSessionStatus.ringing && session.isIncoming;
    final bool active = session.status == CallSessionStatus.active;

    return Wrap(
      spacing: 14,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        ...leadingActions,
        if (incomingRinging)
          _CallPrimaryButton(
            buttonKey: Key('$keyPrefix-decline-button'),
            icon: Icons.call_end_rounded,
            label: t('Odrzuć'),
            color: zen.danger,
            labelColor: zen.textSecondary,
            onPressed: onDecline,
          ),
        if (incomingRinging)
          _CallPrimaryButton(
            buttonKey: Key('$keyPrefix-accept-button'),
            icon: Icons.call_rounded,
            label: t('Odbierz'),
            color: zen.success,
            labelColor: zen.textSecondary,
            onPressed: onAccept,
          ),
        if (active)
          _CallRoundButton(
            buttonKey: Key('$keyPrefix-mute-button'),
            zen: zen,
            active: session.isMuted,
            icon: session.isMuted
                ? Icons.mic_off_rounded
                : Icons.mic_none_rounded,
            tooltip: session.isMuted ? t('Włącz mikrofon') : t('Wycisz'),
            onPressed: onToggleMute,
          ),
        if (active)
          _CallRoundButton(
            buttonKey: Key('$keyPrefix-speaker-button'),
            zen: zen,
            active: session.isSpeakerOn,
            icon: session.isSpeakerOn
                ? Icons.volume_up_rounded
                : Icons.hearing_rounded,
            tooltip: session.isSpeakerOn ? t('Głośnik') : t('Słuchawka'),
            onPressed: onToggleSpeaker,
          ),
        if (active)
          _CallRoundButton(
            buttonKey: Key('$keyPrefix-camera-button'),
            zen: zen,
            active: session.isCameraEnabled,
            icon: session.isCameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            tooltip: session.isCameraEnabled
                ? t('Wyłącz kamerę')
                : t('Włącz kamerę'),
            onPressed: onToggleCamera,
          ),
        if (active && session.isCameraEnabled && onSwitchCamera != null)
          _CallRoundButton(
            buttonKey: Key('$keyPrefix-flip-camera-button'),
            zen: zen,
            active: false,
            icon: Icons.cameraswitch_rounded,
            tooltip: t('Zmień kamerę'),
            onPressed: onSwitchCamera,
          ),
        if (active && onOpenDevices != null)
          _CallRoundButton(
            buttonKey: Key('$keyPrefix-devices-button'),
            zen: zen,
            active: false,
            icon: Icons.devices_rounded,
            tooltip: t('Urządzenia'),
            onPressed: () async => onOpenDevices!.call(),
          ),
        if (!incomingRinging)
          _CallPrimaryButton(
            buttonKey: Key('$keyPrefix-end-button'),
            icon: Icons.call_end_rounded,
            label: session.status == CallSessionStatus.active
                ? t('Zakończ')
                : t('Anuluj'),
            color: zen.danger,
            labelColor: zen.textSecondary,
            onPressed: onEnd,
          ),
      ],
    );
  }
}

/// The dark-first backdrop of every call screen: deep background with a
/// soft accent glow from the top.
LinearGradient callStageGradient(ZenColors zen) {
  return LinearGradient(
    colors: <Color>[
      Color.alphaBlend(zen.accent.withValues(alpha: 0.20), zen.background),
      Color.alphaBlend(
        zen.accentSecondary.withValues(alpha: 0.06),
        zen.background,
      ),
      Color.alphaBlend(zen.surfaceSunk.withValues(alpha: 0.6), zen.background),
    ],
    stops: const <double>[0, 0.45, 1],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

/// A big round accept / decline / hang-up button with its label below.
class _CallPrimaryButton extends StatelessWidget {
  const _CallPrimaryButton({
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
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: color.withValues(alpha: 0.40),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: IconButton.filled(
            key: buttonKey,
            onPressed: onPressed == null ? null : () => onPressed!.call(),
            style: IconButton.styleFrom(
              backgroundColor: color,
              foregroundColor: ZenColors.foregroundFor(color),
              disabledBackgroundColor: color.withValues(alpha: 0.35),
              fixedSize: const Size(60, 60),
              minimumSize: const Size(60, 60),
              shape: const CircleBorder(),
            ),
            icon: Icon(icon, size: 28),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          style: TextStyle(
            color: labelColor,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _CallRoundButton extends StatelessWidget {
  const _CallRoundButton({
    required this.buttonKey,
    required this.zen,
    required this.active,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final ZenColors zen;
  final bool active;
  final IconData icon;
  final String tooltip;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 52,
        height: 52,
        child: IconButton(
          key: buttonKey,
          onPressed: onPressed == null ? null : () => onPressed!.call(),
          style: IconButton.styleFrom(
            backgroundColor: active ? zen.textPrimary : zen.surfaceRaised,
            foregroundColor: active ? zen.background : zen.textPrimary,
            side: BorderSide(color: active ? zen.textPrimary : zen.outlineSoft),
            shape: const CircleBorder(),
          ),
          icon: Icon(icon, size: 24),
        ),
      ),
    );
  }
}

Future<void> showCallDevicePicker({
  required BuildContext context,
  required CallMediaSessionController callMedia,
  Future<void> Function(Future<void> Function() action)? runAction,
}) async {
  final List<CallMediaDevice> devices = await callMedia.listMediaDevices();
  if (!context.mounted) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      final double bottomInset = MediaQuery.viewPaddingOf(sheetContext).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset + 12),
        child: CallDevicePickerSheet(
          devices: devices,
          onSelected: (CallMediaDevice device) {
            Navigator.of(sheetContext).pop();
            Future<void> select() => callMedia.selectMediaDevice(device);
            if (runAction != null) {
              runAction(select);
            } else {
              select();
            }
          },
        ),
      );
    },
  );
}

class CallDevicePickerSheet extends StatelessWidget {
  const CallDevicePickerSheet({
    required this.devices,
    required this.onSelected,
    super.key,
  });

  final List<CallMediaDevice> devices;
  final ValueChanged<CallMediaDevice> onSelected;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Text(
          t(
            'Brak wykrytych urządzeń. Włącz kamerę lub mikrofon i spróbuj '
            'ponownie.',
          ),
        ),
      );
    }
    final List<CallMediaDevice> cameras = devices
        .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
        .toList();
    final List<CallMediaDevice> mics = devices
        .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.microphone)
        .toList();
    final List<CallMediaDevice> speakers = devices
        .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.speaker)
        .toList();
    final double screenHeight = MediaQuery.sizeOf(context).height;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: screenHeight > 0 ? screenHeight * 0.7 : double.infinity,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: <Widget>[
            if (cameras.isNotEmpty) ...<Widget>[
              ZenSection(t('Kamera'), top: 4),
              ...cameras.map(
                (CallMediaDevice device) => ListTile(
                  leading: const Icon(Icons.videocam_outlined),
                  title: Text(device.label),
                  onTap: () => onSelected(device),
                ),
              ),
            ],
            if (mics.isNotEmpty) ...<Widget>[
              ZenSection(t('Mikrofon'), top: 12),
              ...mics.map(
                (CallMediaDevice device) => ListTile(
                  leading: const Icon(Icons.mic_none_rounded),
                  title: Text(device.label),
                  onTap: () => onSelected(device),
                ),
              ),
            ],
            if (speakers.isNotEmpty) ...<Widget>[
              ZenSection(t('Głośnik / słuchawka'), top: 12),
              ...speakers.map(
                (CallMediaDevice device) => ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: Text(device.label),
                  onTap: () => onSelected(device),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class CallStateChip extends StatelessWidget {
  const CallStateChip({required this.icon, required this.label, super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: zen.surfaceRaised.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: zen.accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
