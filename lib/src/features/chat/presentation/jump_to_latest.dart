import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Puts a round "down to the newest message" button over the bottom-right
/// corner of a conversation's list ([child]), above the composer.
///
/// The button shows once the list is scrolled further than a screen from the
/// newest message, and while messages that came in meanwhile wait below
/// (then with their count on it). It goes away at the newest message.
class JumpToLatest extends StatefulWidget {
  const JumpToLatest({
    super.key,
    required this.controller,
    required this.reversed,
    required this.incomingCount,
    required this.child,
  });

  /// The list's controller.
  final ScrollController controller;

  /// The newest message is at offset 0 (the group chat).
  final bool reversed;

  /// How many messages from others the conversation holds: a rise of it
  /// while the list is away from the newest message is counted as new ones.
  final int incomingCount;

  final Widget child;

  /// Within this many pixels of the newest message the list counts as being
  /// at it: what comes in is followed, not counted.
  static const double _nearLatest = 48;

  /// A jump further than this many screens does not scroll there.
  static const double _animatedScreens = 8;

  /// Whether the list is at its newest message (or has not been laid out).
  static bool isNearLatest(
    ScrollController controller, {
    bool reversed = false,
  }) {
    final double? distance = _distanceFromLatest(controller, reversed);
    return distance == null || distance <= _nearLatest;
  }

  static double? _distanceFromLatest(
    ScrollController controller,
    bool reversed,
  ) {
    if (!controller.hasClients) {
      return null;
    }
    final ScrollPosition position = controller.position;
    if (!position.hasContentDimensions) {
      return null;
    }
    return reversed
        ? position.pixels - position.minScrollExtent
        : position.maxScrollExtent - position.pixels;
  }

  @override
  State<JumpToLatest> createState() => _JumpToLatestState();
}

class _JumpToLatestState extends State<JumpToLatest> {
  bool _away = false;
  int _missed = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(JumpToLatest oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    final int added = widget.incomingCount - oldWidget.incomingCount;
    if (added > 0 &&
        !JumpToLatest.isNearLatest(
          widget.controller,
          reversed: widget.reversed,
        )) {
      _missed += added;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) {
      return;
    }
    final double? distance = JumpToLatest._distanceFromLatest(
      widget.controller,
      widget.reversed,
    );
    final bool away =
        distance != null &&
        distance > widget.controller.position.viewportDimension;
    int missed = _missed;
    if (distance == null || distance <= JumpToLatest._nearLatest) {
      missed = 0;
    }
    if (away == _away && missed == _missed) {
      return;
    }
    void apply() {
      if (mounted) {
        setState(() {
          _away = away;
          _missed = missed;
        });
      }
    }

    // A change of the list's size is reported while it is laid out.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _refresh());
    } else {
      apply();
    }
  }

  Future<void> _jump() async {
    final ScrollController controller = widget.controller;
    if (!controller.hasClients) {
      return;
    }
    final ScrollPosition position = controller.position;
    final double target = widget.reversed
        ? position.minScrollExtent
        : position.maxScrollExtent;
    final double distance = (target - position.pixels).abs();
    if (!ZenMotion.allowedIn(context) ||
        distance > position.viewportDimension * JumpToLatest._animatedScreens) {
      position.jumpTo(target);
      return;
    }
    await controller.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    // A list that is built as it goes may have grown on the way.
    if (mounted &&
        controller.hasClients &&
        !JumpToLatest.isNearLatest(controller, reversed: widget.reversed)) {
      final ScrollPosition end = controller.position;
      end.jumpTo(widget.reversed ? end.minScrollExtent : end.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool visible = _away || _missed > 0;
    final Duration fade = ZenMotion.allowedIn(context)
        ? const Duration(milliseconds: 160)
        : Duration.zero;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (ScrollMetricsNotification notification) {
              if (notification.depth == 0 &&
                  notification.metrics.axis == Axis.vertical) {
                _refresh();
              }
              return false;
            },
            child: widget.child,
          ),
        ),
        PositionedDirectional(
          end: 12,
          bottom: 12,
          child: AnimatedSwitcher(
            duration: fade,
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: animation, child: child),
                ),
            child: visible
                ? Tooltip(
                    key: const Key('jump-to-latest'),
                    message: t('Przewiń na sam dół'),
                    // Said once, with the count, by the button's own node.
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      excludeSemantics: true,
                      label: _missed > 0
                          ? tn(
                              _missed,
                              one: 'Przewiń na sam dół: {n} nowa wiadomość',
                              few: 'Przewiń na sam dół: {n} nowe wiadomości',
                              many: 'Przewiń na sam dół: {n} nowych wiadomości',
                            )
                          : t('Przewiń na sam dół'),
                      onTap: _jump,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          Material(
                            color: zen.surfaceRaised,
                            elevation: 3,
                            shape: CircleBorder(
                              side: BorderSide(color: zen.outline),
                            ),
                            child: InkResponse(
                              key: const Key('jump-to-latest-button'),
                              onTap: _jump,
                              containedInkWell: true,
                              highlightShape: BoxShape.circle,
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: zen.accent,
                                  size: 26,
                                ),
                              ),
                            ),
                          ),
                          if (_missed > 0)
                            PositionedDirectional(
                              top: -8,
                              end: -6,
                              child: IgnorePointer(
                                child: ZenCountBadge(
                                  _missed,
                                  key: const Key('jump-to-latest-badge'),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: Key('jump-to-latest-hidden')),
          ),
        ),
      ],
    );
  }
}
