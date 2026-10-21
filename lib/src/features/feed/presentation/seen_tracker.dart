import 'dart:async';

import 'package:flutter/widgets.dart';

/// How much of an item from [top] (its height [height]) lies within a
/// viewport [viewportHeight] high (from 0 down): 0 to 1.
double visibleShare({
  required double top,
  required double height,
  required double viewportHeight,
}) {
  if (height <= 0) {
    return 0;
  }
  final double from = top < 0 ? 0 : top;
  final double to = top + height > viewportHeight
      ? viewportHeight
      : top + height;
  return to <= from ? 0 : (to - from) / height;
}

/// Calls [onSeen] once, when [child] has really been on the screen: at
/// least [kSeenShare] of it inside its scroll view for [kSeenDwell] in a
/// row, its page showing (not a hidden tab, not covered by another route)
/// and the app in front. Building a card is not reading it.
///
/// It works only after a scroll (once a frame, while it lasts) and on a
/// timer, never on idle frames.
class SeenTracker extends StatefulWidget {
  const SeenTracker({
    required this.onSeen,
    required this.child,
    this.enabled = true,
    super.key,
  });

  final VoidCallback onSeen;
  final Widget child;

  /// Off: nothing is counted (already read, or one's own).
  final bool enabled;

  @override
  State<SeenTracker> createState() => _SeenTrackerState();
}

/// The share of a card that has to be visible…
const double kSeenShare = 0.5;

/// …and for how long.
const Duration kSeenDwell = Duration(seconds: 1);

class _SeenTrackerState extends State<SeenTracker> {
  ScrollPosition? _position;
  Timer? _timer;
  bool _done = false;
  bool _active = true;

  /// A check waits for the end of the frame (sizes are final then).
  bool _scheduled = false;

  /// A scroll moved the card and its frame has not come yet: where it is
  /// is not known until then.
  bool _moved = false;

  /// The second ran out while [_moved]: the check after the frame decides.
  bool _due = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not a hidden tab of the shell, nor a page under another route.
    _active = TickerMode.valuesOf(context).enabled && Visibility.of(context);
    final ScrollPosition? position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_later);
      _position = position;
      position?.addListener(_later);
    }
    _later();
  }

  @override
  void didUpdateWidget(SeenTracker old) {
    super.didUpdateWidget(old);
    _later();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _position?.removeListener(_later);
    super.dispose();
  }

  /// Once laid out (a scroll moves the card in the next frame).
  void _later() {
    if (_done || !widget.enabled) {
      _timer?.cancel();
      _timer = null;
      _due = false;
      return;
    }
    _moved = true;
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _moved = false;
      _check();
    });
  }

  bool _visible() {
    if (!mounted || !_active) {
      return false;
    }
    final AppLifecycleState? life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) {
      return false;
    }
    final RenderObject? box = context.findRenderObject();
    final RenderObject? view = Scrollable.maybeOf(
      context,
    )?.context.findRenderObject();
    if (box is! RenderBox ||
        view is! RenderBox ||
        !box.attached ||
        !view.attached ||
        !box.hasSize ||
        !view.hasSize) {
      return false;
    }
    final double top = box.localToGlobal(Offset.zero, ancestor: view).dy;
    return visibleShare(
          top: top,
          height: box.size.height,
          viewportHeight: view.size.height,
        ) >=
        kSeenShare;
  }

  void _check() {
    if (_done || !widget.enabled) {
      return;
    }
    if (!_visible()) {
      _timer?.cancel();
      _timer = null;
      _due = false;
      return;
    }
    if (_due) {
      _seen();
      return;
    }
    _timer ??= Timer(kSeenDwell, () {
      _timer = null;
      if (_moved) {
        // The layout is from before the scroll.
        _due = true;
      } else if (!_done && widget.enabled && _visible()) {
        _seen();
      }
    });
  }

  void _seen() {
    _done = true;
    _due = false;
    _position?.removeListener(_later);
    widget.onSeen();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
