import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// A button that only counts once it has been held for [duration]: a ring
/// fills while the finger, the mouse button or Enter / Space is down, and
/// letting go early empties it again. For things that cannot be undone and
/// must not happen by accident.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    required this.idleLabel,
    required this.holdingLabel,
    required this.onConfirmed,
    this.duration = const Duration(seconds: 10),
    this.enabled = true,
    this.autofocus = false,
    this.color,
    super.key,
  });

  /// What the button says while nobody holds it.
  final String idleLabel;

  /// What it says while held, with the whole seconds still to hold.
  final String Function(int secondsLeft) holdingLabel;

  /// Called once, when the hold has lasted [duration].
  final VoidCallback onConfirmed;

  final Duration duration;

  final bool enabled;

  /// Takes the keyboard focus at once, so Enter / Space can hold it.
  final bool autofocus;

  /// The ring and the icon; the danger colour by default.
  final Color? color;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addListener(_onTick);

  bool _done = false;
  bool _holding = false;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(HoldToConfirmButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _release();
    }
  }

  // Confirms on the frame the ring is full: the controller only reports
  // `completed` one frame after the whole duration has passed.
  void _onTick() {
    if (_progress.value >= 1 && !_done) {
      _done = true;
      widget.onConfirmed();
    }
  }

  void _press() {
    if (!widget.enabled || _done || _holding) {
      return;
    }
    _holding = true;
    _progress.forward(from: 0);
  }

  void _release() {
    _holding = false;
    if (_done) {
      return;
    }
    _progress.stop();
    _progress.animateBack(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      _press();
    } else if (event is KeyUpEvent) {
      _release();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color color = widget.enabled
        ? widget.color ?? zen.danger
        : zen.textMuted;
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      onFocusChange: (bool focused) {
        if (!focused) {
          _release();
        }
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _press(),
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: Semantics(
          button: true,
          enabled: widget.enabled,
          label: widget.idleLabel,
          excludeSemantics: true,
          child: AnimatedBuilder(
            animation: _progress,
            builder: (BuildContext context, Widget? child) {
              final double value = _progress.value;
              final bool holding = value > 0;
              final int secondsLeft =
                  ((1 - value) *
                          widget.duration.inMilliseconds /
                          Duration.millisecondsPerSecond)
                      .ceil();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox.square(
                    dimension: 84,
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            key: const Key('hold-to-confirm-progress'),
                            value: value,
                            strokeWidth: 6,
                            color: color,
                            backgroundColor: color.withValues(alpha: 0.14),
                          ),
                        ),
                        Icon(
                          Icons.delete_forever_rounded,
                          size: 34,
                          color: color,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    holding
                        ? widget.holdingLabel(secondsLeft)
                        : widget.idleLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
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
}
