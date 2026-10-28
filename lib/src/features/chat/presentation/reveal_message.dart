import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Frames given to find a message in a list that builds lazily.
const int _maxSeeks = 12;

/// Scrolls a conversation's list to the message [id] and shows it about
/// at [alignment] (0 the top of the list, 1 its bottom). [ids] is the
/// conversation, oldest first; [bubbleKeys] the keys the screen gives its
/// bubbles. A message far away is not built yet: the list jumps to about
/// where it is (from the bubbles that are built and their size), lets it
/// be built and tries again, a few times. `false` when it was not found.
/// It stops as soon as [stillWanted] says another message is wanted now.
Future<bool> revealChatMessage({
  required ScrollController controller,
  required Map<String, GlobalKey> bubbleKeys,
  required List<String> ids,
  required String id,
  bool reversed = false,
  double alignment = 0.3,
  Duration duration = const Duration(milliseconds: 250),
  bool Function()? stillWanted,
}) async {
  bool wanted() => stillWanted?.call() ?? true;
  final int index = ids.indexOf(id);
  if (index < 0) {
    return false;
  }
  Map<String, int>? positions;
  for (int attempt = 0; attempt < _maxSeeks; attempt++) {
    if (!wanted()) {
      return false;
    }
    final BuildContext? target = bubbleKeys[id]?.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        alignment: alignment,
        duration: duration,
      );
      return true;
    }
    if (!controller.hasClients) {
      return false;
    }
    final ScrollPosition position = controller.position;
    positions ??= <String, int>{for (int i = 0; i < ids.length; i++) ids[i]: i};
    final double to = _estimate(
      position,
      bubbleKeys,
      positions,
      ids.length,
      index,
      reversed,
    );
    if ((to - position.pixels).abs() < 1 && attempt > 0) {
      // Nowhere further to go: the list ends there.
      break;
    }
    position.jumpTo(to);
    await WidgetsBinding.instance.endOfFrame;
  }
  final BuildContext? target = bubbleKeys[id]?.currentContext;
  if (wanted() && target != null && target.mounted) {
    await Scrollable.ensureVisible(
      target,
      alignment: alignment,
      duration: duration,
    );
    return true;
  }
  return false;
}

/// About where message [index] is: from the nearest bubble that is built,
/// by the size of the bubbles around (the share of the list when none is).
double _estimate(
  ScrollPosition position,
  Map<String, GlobalKey> bubbleKeys,
  Map<String, int> positions,
  int count,
  int index,
  bool reversed,
) {
  int? nearest;
  double nearestReveal = 0;
  double total = 0;
  int built = 0;
  for (final MapEntry<String, GlobalKey> e in bubbleKeys.entries) {
    final BuildContext? context = e.value.currentContext;
    final RenderObject? object = context?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      continue;
    }
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
      object,
    );
    if (viewport == null) {
      continue;
    }
    final int? i = positions[e.key];
    if (i == null) {
      continue;
    }
    built += 1;
    total += object.size.height;
    if (nearest == null || (i - index).abs() < (nearest - index).abs()) {
      nearest = i;
      nearestReveal = viewport.getOffsetToReveal(object, 0).offset;
    }
  }
  final double target;
  if (nearest == null || built == 0) {
    final double fraction = count < 2
        ? 0
        : (reversed ? count - 1 - index : index) / (count - 1);
    target = position.maxScrollExtent * fraction;
  } else {
    // Newer messages are further from the start of a reversed list.
    final double step = (total / built + 6) * (index - nearest);
    target = nearestReveal + (reversed ? -step : step);
  }
  return target.clamp(position.minScrollExtent, position.maxScrollExtent);
}
