import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';

// The graph on the whole screen: the app's bars go, the system bars on a
// phone too (immersive), the window fills the screen on a computer; all
// of it comes back on the way out.

/// What the system shows around the app while the graph is full screen.
abstract interface class FullScreenChrome {
  /// Hides the system bars (phone) or makes the window full screen
  /// (computer).
  Future<void> enter();

  /// Brings back what [enter] hid.
  Future<void> exit();
}

/// The real [FullScreenChrome]: immersive mode on phones, a full-screen
/// window on computers. Never throws (a platform without it just keeps
/// its bars).
final class PlatformFullScreenChrome implements FullScreenChrome {
  const PlatformFullScreenChrome();

  static bool get _desktop =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  Future<void> enter() async {
    try {
      if (_desktop) {
        await windowManager.setFullScreen(true);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    } on Object catch (error) {
      logZenWarning('Graf: pełny ekran: $error');
    }
  }

  @override
  Future<void> exit() async {
    try {
      if (_desktop) {
        await windowManager.setFullScreen(false);
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    } on Object catch (error) {
      logZenWarning('Graf: koniec pełnego ekranu: $error');
    }
  }
}

final Provider<FullScreenChrome> graphFullScreenChromeProvider =
    Provider<FullScreenChrome>((Ref ref) => const PlatformFullScreenChrome());

/// How the graph is looked at: kept when it goes full screen and back.
@immutable
final class GraphView {
  const GraphView({
    this.mode = GraphMode.friends,
    this.filters = const GraphFilters(),
    this.goal = RouteGoal.shortest,
    this.selected,
    this.timeMonths = 0,
    this.focus = const <String>{},
    this.focusName = '',
  });

  final GraphMode mode;
  final GraphFilters filters;
  final RouteGoal goal;
  final String? selected;
  final int timeMonths;

  /// People lit in the "Ścieżka" mode: the trusted friends this person and
  /// a dating match [focusName] both know ("Bezpieczna randka").
  final Set<String> focus;
  final String focusName;
}

/// The overlay controls of the full-screen graph hide after this long
/// without a touch, a click or the mouse moving.
const Duration kGraphChromeHideAfter = Duration(seconds: 3);
