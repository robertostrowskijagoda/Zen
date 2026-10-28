import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The controller of a conversation's list. While the list is at its
/// newest message it stays there, in the same frame, whatever changes its
/// size: the keyboard opening, a message coming in or going out, a picture
/// in one being decoded, a list built lazily measuring its bubbles. Once
/// the user scrolls away (further than [JumpToLatest]'s margin) it keeps
/// its place; scrolling back down, the jump-to-latest button or
/// [showLatest] (one's own message sent) makes it follow again.
///
/// Away from it, a bubble on screen is kept where it is when bubbles before
/// it change: a message coming in below it in a [reversed] list (the newest
/// message at offset 0, the group chat), a picture above it decoded. A
/// reversed list must keep its bubbles by key (`findChildIndexCallback`)
/// for that, or each would take the place of the next one.
class ChatScrollController extends ScrollController {
  ChatScrollController({this.reversed = false});

  final bool reversed;

  bool _following = true;

  /// The list is kept at its newest message.
  bool get followsLatest => _following;

  /// Shows the newest message and stays with it: at once where the list
  /// is laid out, and again after the frame being built (which may add the
  /// message).
  void showLatest() {
    _following = true;
    _jumpToLatest();
    SchedulerBinding.instance.addPostFrameCallback((_) => _jumpToLatest());
  }

  void _jumpToLatest() {
    if (!_following ||
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
      return;
    }
    for (final ScrollPosition position in positions) {
      if (position.hasContentDimensions) {
        final double latest = reversed
            ? position.minScrollExtent
            : position.maxScrollExtent;
        if (position.pixels != latest) {
          position.jumpTo(latest);
        }
      }
    }
  }

  /// The list moved (the user, a jump, an animation): it follows the
  /// newest message when it ended up at it.
  void _moved(ScrollPosition position) {
    if (!position.hasContentDimensions) {
      return;
    }
    final double distance = reversed
        ? position.pixels - position.minScrollExtent
        : position.maxScrollExtent - position.pixels;
    _following = distance <= JumpToLatest._nearLatest;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ChatScrollPosition(
      this,
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _ChatScrollPosition extends ScrollPositionWithSingleContext {
  _ChatScrollPosition(
    this.owner, {
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final ChatScrollController owner;

  /// Away from the newest message: a bubble on screen and where it stood in
  /// the list after the last frame. A message coming in below it (a
  /// reversed list) or a bubble before it growing moves it; the list moves
  /// with it, in the same frame, so what is read stays where it is.
  RenderBox? _anchor;
  double _anchorOffset = 0;
  bool _anchorPending = false;

  bool get _userScrolling => activity?.isScrolling ?? false;

  double _latest(double min, double max) => owner.reversed ? min : max;

  /// Puts the list at [latest] while it follows the newest message and the
  /// user is not scrolling it; `false` when the layout has to run again.
  bool _keepLatest(double latest) {
    if (!owner._following || _userScrolling) {
      return true;
    }
    if (nearEqual(pixels, latest, Tolerance.defaultTolerance.distance)) {
      return true;
    }
    correctPixels(latest);
    return false;
  }

  /// Moves the list by as much as [_anchor] moved in it; `false` when the
  /// layout has to run again.
  bool _keepPlace() {
    final RenderBox? anchor = _anchor;
    if (anchor == null || owner._following || _userScrolling) {
      return true;
    }
    final Object? data = anchor.parentData;
    final double? offset =
        anchor.attached && data is SliverMultiBoxAdaptorParentData
        ? data.layoutOffset
        : null;
    if (offset == null) {
      _anchor = null;
      return true;
    }
    final double moved = offset - _anchorOffset;
    _anchorOffset = offset;
    if (nearEqual(moved, 0, Tolerance.defaultTolerance.distance)) {
      return true;
    }
    correctPixels(
      (pixels + moved).clamp(minScrollExtent, maxScrollExtent).toDouble(),
    );
    return false;
  }

  /// After this frame: the bubble on screen nearest the list's leading
  /// edge becomes [_anchor].
  void _scheduleAnchor() {
    if (_anchorPending) {
      return;
    }
    _anchorPending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _anchorPending = false;
      _pickAnchor();
    });
  }

  void _pickAnchor() {
    _anchor = null;
    if (owner._following) {
      return;
    }
    final RenderObject? root = context.notificationContext?.findRenderObject();
    final RenderSliverMultiBoxAdaptor? list = root == null
        ? null
        : _listIn(root);
    if (list == null || !list.attached) {
      return;
    }
    final SliverConstraints constraints = list.constraints;
    final double start = constraints.scrollOffset;
    final double end = start + constraints.remainingPaintExtent;
    double nearest = double.infinity;
    for (
      RenderBox? child = list.firstChild;
      child != null;
      child = list.childAfter(child)
    ) {
      final double? offset =
          (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset;
      if (offset == null || !child.hasSize) {
        continue;
      }
      final bool onScreen = offset + child.size.height > start && offset < end;
      if (onScreen && (offset - start).abs() < nearest) {
        nearest = (offset - start).abs();
        _anchor = child;
        _anchorOffset = offset;
      }
    }
  }

  /// The list of bubbles under [object]: the first one, the others are
  /// inside it.
  static RenderSliverMultiBoxAdaptor? _listIn(RenderObject object) {
    if (object is RenderSliverMultiBoxAdaptor) {
      return object;
    }
    RenderSliverMultiBoxAdaptor? found;
    object.visitChildren((RenderObject child) {
      found ??= _listIn(child);
    });
    return found;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // The first layout: a conversation opens at its newest message.
    final bool first = !haveDimensions;
    if (!super.applyContentDimensions(minScrollExtent, maxScrollExtent)) {
      return false;
    }
    if (first) {
      return _keepLatest(_latest(minScrollExtent, maxScrollExtent));
    }
    if (!_keepPlace()) {
      return false;
    }
    _scheduleAnchor();
    return true;
  }

  @override
  void correctBy(double correction) {
    // The list moved its bubbles and the offset together (it measured some
    // it had only estimated): nothing the reader would see.
    _anchorOffset += correction;
    super.correctBy(correction);
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    if (owner._following && !_userScrolling) {
      return _keepLatest(
        _latest(newPosition.minScrollExtent, newPosition.maxScrollExtent),
      );
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }

  @override
  void notifyListeners() {
    owner._moved(this);
    super.notifyListeners();
  }
}

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
