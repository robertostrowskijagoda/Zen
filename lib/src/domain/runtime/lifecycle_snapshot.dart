import 'package:flutter/foundation.dart';

enum AppVisibilityState {
  detached,
  background,
  hidden,
  foreground,
  foregroundFocused,
}

@immutable
final class LifecycleSnapshot {
  const LifecycleSnapshot({
    required this.visibility,
    required this.generation,
    required this.capturedAtMillis,
  });

  final AppVisibilityState visibility;
  final int generation;
  final int capturedAtMillis;

  bool get isInteractive =>
      visibility == AppVisibilityState.foreground ||
      visibility == AppVisibilityState.foregroundFocused;

  bool get isFocused => visibility == AppVisibilityState.foregroundFocused;

  bool get isBackgroundLike =>
      visibility == AppVisibilityState.detached ||
      visibility == AppVisibilityState.background ||
      visibility == AppVisibilityState.hidden;
}
