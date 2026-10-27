import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/shell/shell_location.dart';

/// Where a [ScrollMemory] puts its list back to. A new object asks again.
final class ScrollRestore {
  ScrollRestore(this.offset);

  final double offset;
}

/// Reports how far the main list of its child is scrolled, and puts it back
/// to [restore] once there is that much to scroll (a list that fills in
/// later is followed for a moment). The main list is the outermost vertical
/// one; a page without a list reports nothing.
class ScrollMemory extends StatefulWidget {
  const ScrollMemory({
    required this.onScrolled,
    required this.child,
    this.restore,
    super.key,
  });

  final ValueChanged<double> onScrolled;
  final ScrollRestore? restore;
  final Widget child;

  @override
  State<ScrollMemory> createState() => _ScrollMemoryState();
}

class _ScrollMemoryState extends State<ScrollMemory> {
  /// Frames spent waiting for the list to grow to the remembered offset.
  static const int _maxFrames = 60;

  /// Changes with every restore and with the user's own scrolling, which
  /// ends the restore.
  int _generation = 0;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    final ScrollRestore? restore = widget.restore;
    if (restore != null) {
      _start(restore.offset);
    }
  }

  @override
  void didUpdateWidget(ScrollMemory oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ScrollRestore? restore = widget.restore;
    if (restore != null && !identical(restore, oldWidget.restore)) {
      _start(restore.offset);
    }
  }

  @override
  void dispose() {
    _generation += 1;
    super.dispose();
  }

  void _start(double offset) {
    if (offset <= 0) {
      return;
    }
    _generation += 1;
    _step(offset, _generation, 0);
  }

  void _step(double offset, int generation, int frame) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) {
        return;
      }
      final ScrollPosition? position = _mainPosition();
      if (position != null && position.hasContentDimensions) {
        final double target = math.min(offset, position.maxScrollExtent);
        if ((position.pixels - target).abs() > 1) {
          _restoring = true;
          try {
            position.jumpTo(target);
          } finally {
            _restoring = false;
          }
        }
        if (target >= offset - 1) {
          return;
        }
      }
      if (frame < _maxFrames) {
        _step(offset, generation, frame + 1);
        SchedulerBinding.instance.scheduleFrame();
      }
    });
  }

  /// The outermost list under this widget, when it is a vertical one.
  ScrollPosition? _mainPosition() {
    ScrollPosition? found;
    bool done = false;
    void visit(Element element) {
      if (done) {
        return;
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        done = true;
        final ScrollableState scrollable = element.state as ScrollableState;
        if (axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical) {
          found = scrollable.position;
        }
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return found;
  }

  bool _onNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (_restoring) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // The user took over: the remembered place no longer matters.
      _generation += 1;
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      widget.onScrolled(notification.metrics.pixels);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}

/// Marks the page of its route as a place the app can open again after it
/// was closed ([ShellPlace]), and remembers how far it is scrolled.
class RememberedPlace extends ConsumerStatefulWidget {
  const RememberedPlace({required this.place, required this.child, super.key});

  final ShellPlace place;
  final Widget child;

  @override
  ConsumerState<RememberedPlace> createState() => _RememberedPlaceState();
}

class _RememberedPlaceState extends ConsumerState<RememberedPlace> {
  ModalRoute<dynamic>? _route;
  ScrollRestore? _restore;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) {
      return;
    }
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null) {
      return;
    }
    _route = route;
    final PlaceMemory? memory = ref
        .read(shellLocationProvider)
        .openPlace(route, widget.place);
    if (memory != null && memory.scroll > 0) {
      _restore = ScrollRestore(memory.scroll);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScrollMemory(
      restore: _restore,
      onScrolled: (double offset) {
        final ModalRoute<dynamic>? route = _route;
        if (route != null) {
          ref.read(shellLocationProvider).placeScrolled(route, offset);
        }
      },
      child: widget.child,
    );
  }
}

/// Remembers where a conversation is scrolled to, as a message and the
/// distance from the edge of the screen to it, and scrolls back there.
///
/// A conversation's list is built lazily with bubbles of every height, so a
/// pixel offset would land elsewhere once a message came or went; the
/// message does not. The bubbles are found by their keys ([bubbleKeys]);
/// a conversation that is at its latest message remembers just that.
final class ChatScrollMemory {
  ChatScrollMemory({
    required this.location,
    required this.place,
    required this.scroll,
    required this.bubbleKeys,
    this.reversed = false,
  }) {
    scroll.addListener(_onScroll);
  }

  final ShellLocationController location;
  final ShellPlace place;
  final ScrollController scroll;

  /// The list's bubbles, by message id (the screen's own keys).
  final Map<String, GlobalKey> bubbleKeys;

  /// The newest message is at offset 0 (the group chat).
  final bool reversed;

  static const Duration _captureDelay = Duration(milliseconds: 250);

  /// Frames given to find the message in a list that builds lazily.
  static const int _maxSeeks = 10;

  ModalRoute<dynamic>? _route;
  ChatAnchor? _pending;
  Timer? _timer;
  bool _seeking = false;
  bool _disposed = false;

  /// Call from `didChangeDependencies`: ties the conversation to its route.
  void attach(BuildContext context) {
    if (_route != null) {
      return;
    }
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null) {
      return;
    }
    _route = route;
    _pending = location.openPlace(route, place)?.anchor;
  }

  /// A place was remembered and not yet scrolled to.
  bool get hasAnchor => _pending != null;

  /// Scrolls to the remembered message ([ids]: the conversation, oldest
  /// first). `false` when there is nothing remembered or the message is gone:
  /// the conversation then stays at its latest message.
  bool restore(List<String> ids) {
    final ChatAnchor? anchor = _pending;
    _pending = null;
    if (anchor == null || !scroll.hasClients) {
      return false;
    }
    final int index = ids.indexOf(anchor.messageId);
    if (index < 0) {
      return false;
    }
    _seeking = true;
    _seek(anchor, ids, index, 0, settle: false);
    return true;
  }

  /// [settle]: the bubble was already put in place once; the list may have
  /// measured more of itself since, so it is put there again.
  void _seek(
    ChatAnchor anchor,
    List<String> ids,
    int index,
    int attempt, {
    required bool settle,
  }) {
    if (_disposed || !scroll.hasClients) {
      _seeking = false;
      return;
    }
    final ScrollPosition position = scroll.position;
    final _Bubble? target = _bubble(anchor.messageId);
    if (target != null) {
      position.jumpTo(
        (target.reveal - anchor.offset).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      if (settle) {
        _seeking = false;
      } else {
        _later(() => _seek(anchor, ids, index, attempt, settle: true));
      }
      return;
    }
    if (attempt >= _maxSeeks) {
      _seeking = false;
      return;
    }
    position.jumpTo(_estimate(position, ids, index));
    _later(() => _seek(anchor, ids, index, attempt + 1, settle: false));
  }

  void _later(VoidCallback step) {
    SchedulerBinding.instance.addPostFrameCallback((_) => step());
    SchedulerBinding.instance.scheduleFrame();
  }

  /// About where message [index] is: from the nearest bubble that is built,
  /// by the size of the bubbles around.
  double _estimate(ScrollPosition position, List<String> ids, int index) {
    int? nearest;
    double nearestReveal = 0;
    double total = 0;
    int built = 0;
    for (int i = 0; i < ids.length; i++) {
      final _Bubble? bubble = _bubble(ids[i]);
      if (bubble == null) {
        continue;
      }
      built += 1;
      total += bubble.extent;
      if (nearest == null || (i - index).abs() < (nearest - index).abs()) {
        nearest = i;
        nearestReveal = bubble.reveal;
      }
    }
    final double target;
    if (nearest == null || built == 0) {
      final double fraction = ids.length < 2
          ? 0
          : (reversed ? ids.length - 1 - index : index) / (ids.length - 1);
      target = position.maxScrollExtent * fraction;
    } else {
      // Newer messages are further from the start of a reversed list.
      final double step = (total / built) * (index - nearest);
      target = nearestReveal + (reversed ? -step : step);
    }
    return target.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  _Bubble? _bubble(String id) {
    final BuildContext? context = bubbleKeys[id]?.currentContext;
    final RenderObject? object = context?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
      object,
    );
    if (viewport == null) {
      return null;
    }
    return _Bubble(
      viewport.getOffsetToReveal(object, 0).offset,
      object.size.height,
    );
  }

  void _onScroll() {
    // A remembered place not yet scrolled to must not be overwritten.
    if (_seeking || _disposed || _pending != null) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(_captureDelay, _capture);
  }

  void _capture() {
    _timer = null;
    final ModalRoute<dynamic>? route = _route;
    if (_disposed ||
        _seeking ||
        _pending != null ||
        route == null ||
        !scroll.hasClients) {
      return;
    }
    final ScrollPosition position = scroll.position;
    if (!position.hasContentDimensions) {
      return;
    }
    // At the latest message: remembered as that, so that messages that came
    // meanwhile are not skipped.
    final bool atLatest = reversed
        ? position.pixels <= position.minScrollExtent + 8
        : position.pixels >= position.maxScrollExtent - 8;
    if (atLatest) {
      location.chatAnchored(route, null);
      return;
    }
    String? bestId;
    double bestGap = double.infinity;
    for (final MapEntry<String, GlobalKey> entry in bubbleKeys.entries) {
      final _Bubble? bubble = _bubble(entry.key);
      if (bubble == null) {
        continue;
      }
      final double gap = bubble.reveal - position.pixels;
      final bool visible =
          gap + bubble.extent > 0 && gap < position.viewportDimension;
      if (visible && gap < bestGap) {
        bestId = entry.key;
        bestGap = gap;
      }
    }
    if (bestId != null) {
      location.chatAnchored(route, ChatAnchor(bestId, bestGap));
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    scroll.removeListener(_onScroll);
  }
}

final class _Bubble {
  const _Bubble(this.reveal, this.extent);

  /// The scroll offset that puts the bubble's leading edge at the leading
  /// edge of the list.
  final double reveal;
  final double extent;
}
