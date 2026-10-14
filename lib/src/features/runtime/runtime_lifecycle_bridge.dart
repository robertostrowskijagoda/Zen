import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

final Provider<bool> runtimeLifecycleBindingEnabledProvider = Provider<bool>((
  Ref ref,
) {
  return true;
});

class RuntimeLifecycleBridge extends ConsumerStatefulWidget {
  const RuntimeLifecycleBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RuntimeLifecycleBridge> createState() {
    return _RuntimeLifecycleBridgeState();
  }
}

final class _RuntimeLifecycleBridgeState
    extends ConsumerState<RuntimeLifecycleBridge>
    with WidgetsBindingObserver {
  bool _isObserving = false;
  AppVisibilityState? _lastPublishedVisibility;
  late final AppSecurityService _security;
  bool _awaitingUnlockFocus = false;
  bool _viewHasFocus = true;

  @override
  void initState() {
    super.initState();
    _security = ref.read(appSecurityServiceProvider);
    _security.addListener(_handleSecurityChanged);
    if (!ref.read(runtimeLifecycleBindingEnabledProvider)) {
      return;
    }
    _isObserving = true;
    WidgetsBinding.instance.addObserver(this);
    final AppLifecycleState? initialState =
        WidgetsBinding.instance.lifecycleState;
    if (initialState != null) {
      Future<void>.microtask(() => _publishLifecycle(initialState));
    }
  }

  @override
  void dispose() {
    _security.removeListener(_handleSecurityChanged);
    if (_isObserving) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _publishLifecycle(state);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || !ref.read(runtimeLifecycleBindingEnabledProvider)) {
      return;
    }
    if (event.viewId != View.of(context).viewId) {
      return;
    }
    final LifecycleSnapshot current = ref
        .read(socialHubControllerProvider)
        .lifecycle;
    if (current.isBackgroundLike) {
      return;
    }
    switch (event.state) {
      case ViewFocusState.focused:
        _viewHasFocus = true;
        _promoteToFocusedVisibility();
        return;
      case ViewFocusState.unfocused:
        _viewHasFocus = false;
        _awaitingUnlockFocus = false;
        _publishVisibility(AppVisibilityState.foreground);
        return;
    }
  }

  void _handleSecurityChanged() {
    if (!mounted || !_awaitingUnlockFocus || !_viewHasFocus) {
      return;
    }
    if (!_canPublishFocusedVisibility()) {
      return;
    }
    _promoteToFocusedVisibility();
  }

  void _publishLifecycle(AppLifecycleState state) {
    if (!mounted || !ref.read(runtimeLifecycleBindingEnabledProvider)) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        _awaitingUnlockFocus = !_canPublishFocusedVisibility();
        if (_awaitingUnlockFocus) {
          _publishVisibility(AppVisibilityState.foreground);
        } else {
          _promoteToFocusedVisibility();
        }
        return;
      case AppLifecycleState.detached:
        _awaitingUnlockFocus = false;
        _publishVisibility(AppVisibilityState.detached);
        return;
      case AppLifecycleState.hidden:
        _awaitingUnlockFocus = false;
        _publishVisibility(AppVisibilityState.hidden);
        return;
      case AppLifecycleState.inactive:
        _awaitingUnlockFocus = false;
        _publishVisibility(AppVisibilityState.foreground);
        return;
      case AppLifecycleState.paused:
        _awaitingUnlockFocus = false;
        _publishVisibility(AppVisibilityState.background);
        return;
    }
  }

  bool _canPublishFocusedVisibility() {
    if (!_security.isReady) {
      return false;
    }
    if (_security.encryptionEnabled &&
        _security.hasPassword &&
        _security.isLocked) {
      return false;
    }
    return true;
  }

  void _promoteToFocusedVisibility() {
    if (!_viewHasFocus) {
      _awaitingUnlockFocus = false;
      _publishVisibility(AppVisibilityState.foreground);
      return;
    }
    if (!_canPublishFocusedVisibility()) {
      _awaitingUnlockFocus = true;
      _publishVisibility(AppVisibilityState.foreground);
      return;
    }
    _awaitingUnlockFocus = false;
    _publishVisibility(AppVisibilityState.foregroundFocused);
  }

  void _publishVisibility(AppVisibilityState visibility) {
    final LifecycleSnapshot current = ref
        .read(socialHubControllerProvider)
        .lifecycle;
    if (_lastPublishedVisibility == visibility &&
        current.visibility == visibility) {
      return;
    }
    _lastPublishedVisibility = visibility;
    unawaited(
      ref
          .read(socialHubControllerProvider.notifier)
          .setLifecycle(
            LifecycleSnapshot(
              visibility: visibility,
              generation: current.generation + 1,
              capturedAtMillis: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
