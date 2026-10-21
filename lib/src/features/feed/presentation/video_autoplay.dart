import 'package:flutter/foundation.dart';

/// Decides which video in the feed plays: the topmost one that is
/// mostly on screen and has not finished yet. One at a time — when it ends,
/// the next visible one starts, so videos of a post play one after another.
final class VideoAutoplay extends ChangeNotifier {
  VideoAutoplay._();

  static final VideoAutoplay instance = VideoAutoplay._();

  final Map<Object, ({double visible, double top, bool finished})> _entries =
      <Object, ({double visible, double top, bool finished})>{};
  Object? _active;

  Object? get active => _active;

  /// [visible] is the shown fraction (0..1), [top] the position on screen.
  void report(Object id, {required double visible, required double top}) {
    final ({double visible, double top, bool finished})? old = _entries[id];
    // Scrolled away: it may play again when it comes back.
    final bool finished = (old?.finished ?? false) && visible > 0.1;
    _entries[id] = (visible: visible, top: top, finished: finished);
    _pick();
  }

  void finished(Object id) {
    final ({double visible, double top, bool finished})? e = _entries[id];
    if (e != null) {
      _entries[id] = (visible: e.visible, top: e.top, finished: true);
      _pick();
    }
  }

  void remove(Object id) {
    _entries.remove(id);
    _pick();
  }

  void _pick() {
    Object? best;
    double bestTop = double.infinity;
    _entries.forEach((
      Object id,
      ({double visible, double top, bool finished}) e,
    ) {
      if (e.visible >= 0.6 && !e.finished && e.top < bestTop) {
        best = id;
        bestTop = e.top;
      }
    });
    if (!identical(best, _active)) {
      _active = best;
      notifyListeners();
    }
  }
}
