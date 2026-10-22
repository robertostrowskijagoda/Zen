import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Starts `ZenCore` and tells it whether the user can see and use the app
/// (on screen and unlocked): presence pings run only then
/// ([RuntimeSignalModule]).
///
/// It sits under the security gate, so it mounts only once the app is
/// unlocked (and set up): until then no service starts and nothing is sent.
/// Locking the app again unmounts it, which stops the core.
class RuntimeSignalBridge extends ConsumerStatefulWidget {
  const RuntimeSignalBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RuntimeSignalBridge> createState() =>
      _RuntimeSignalBridgeState();
}

final class _RuntimeSignalBridgeState
    extends ConsumerState<RuntimeSignalBridge> {
  bool? _lastInteractive;
  late final ZenCore _core;
  late final AppSecurityService _security;

  @override
  void initState() {
    super.initState();
    _core = ref.read(zenCoreProvider);
    _security = ref.read(appSecurityServiceProvider);
    // Followed here, not only in build: once the app is hidden or paused
    // Flutter draws no frames, so a rebuild would come only on the way back
    // and friends would never hear "away" (nor would the pings stop).
    ref.listenManual<bool>(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.lifecycle.isInteractive,
      ),
      (bool? previous, bool next) => _sync(lifecycleInteractive: next),
    );
    _security.addListener(_onSecurityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaitedLogged(_core.start(), context: 'ZenCore startup failed');
      }
    });
  }

  @override
  void dispose() {
    _security.removeListener(_onSecurityChanged);
    unawaitedLogged(_core.stop(), context: 'Stopping ZenCore failed');
    super.dispose();
  }

  void _onSecurityChanged() {
    if (!mounted) {
      return;
    }
    _sync(
      lifecycleInteractive: ref
          .read(socialHubControllerProvider)
          .lifecycle
          .isInteractive,
    );
  }

  /// Tells the core when the user starts or stops seeing the app.
  void _sync({required bool lifecycleInteractive}) {
    final bool isInteractive =
        lifecycleInteractive &&
        !isSecurityBlockingUi(ref.read(appSecurityServiceProvider));
    if (_lastInteractive != isInteractive) {
      _lastInteractive = isInteractive;
      _core.setInteractive(isInteractive);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    final bool lifecycleInteractive = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.lifecycle.isInteractive,
      ),
    );
    return ListenableBuilder(
      listenable: security,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        _sync(lifecycleInteractive: lifecycleInteractive);
        return child!;
      },
    );
  }
}
