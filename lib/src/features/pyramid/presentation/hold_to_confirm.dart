import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// How long [HoldToConfirmButton] must be held.
const Duration kHoldToConfirm = Duration(seconds: 2);

/// A button that acts only when held down for [hold]: it fills while held
/// and empties when let go too soon. For what cannot be undone by a tap
/// in passing (lowering the emission limit applies at once).
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    required this.label,
    required this.onConfirmed,
    this.hold = kHoldToConfirm,
    this.tone,
    super.key,
  });

  final String label;
  final VoidCallback onConfirmed;
  final Duration hold;

  /// The fill colour (the danger colour by default).
  final Color? tone;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: widget.hold,
  )..addStatusListener(_onStatus);
  bool _done = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_done) {
      _done = true;
      widget.onConfirmed();
    }
  }

  void _down() {
    if (!_done) {
      unawaited(_fill.forward());
    }
  }

  void _up() {
    if (!_done && _fill.value < 1) {
      unawaited(
        _fill.animateBack(0, duration: const Duration(milliseconds: 250)),
      );
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color tone = widget.tone ?? zen.danger;
    final ShapeBorder shape = look.panelShape(zen, radius: 16, tone: tone);
    return Semantics(
      button: true,
      label: widget.label,
      hint: t('Przytrzymaj, aby potwierdzić'),
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedBuilder(
          animation: _fill,
          builder: (BuildContext context, Widget? _) => ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: Container(
              key: const Key('hold-to-confirm'),
              constraints: const BoxConstraints(minHeight: 52),
              decoration: look.panel(zen, radius: 16, tone: tone),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _fill.value,
                      child: ColoredBox(color: tone.withValues(alpha: 0.45)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.touch_app_rounded, color: tone, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.label,
                            softWrap: true,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            key: const Key('hold-to-confirm-progress'),
                            value: _fill.value,
                            strokeWidth: 3,
                            color: tone,
                            backgroundColor: zen.surfaceSunk,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Czy na pewno?": [body] and a button held for [kHoldToConfirm] labelled
/// [action]; true only once it was held to the end.
Future<bool> confirmByHolding(
  BuildContext context, {
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const Key('hold-confirm-dialog'),
        title: Text(t('Czy na pewno?')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SelectableText(body),
              const SizedBox(height: 16),
              HoldToConfirmButton(
                label: action,
                onConfirmed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 6),
              ZenInfo(
                icon: Icons.timer_outlined,
                text: t('Przytrzymaj przycisk przez 2 sekundy.'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
        ],
      ),
    ) ??
    false;
