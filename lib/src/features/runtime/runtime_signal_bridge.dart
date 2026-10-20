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

  @override
  void initState() {
    super.initState();
    _core = ref.read(zenCoreProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaitedLogged(_core.start(), context: 'ZenCore startup failed');
      }
    });
  }

  @override
  void dispose() {
    unawaitedLogged(_core.stop(), context: 'Stopping ZenCore failed');
    super.dispose();
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
        final bool isInteractive =
            lifecycleInteractive && !isSecurityBlockingUi(security);
        if (_lastInteractive != isInteractive) {
          _lastInteractive = isInteractive;
          _core.setInteractive(isInteractive);
        }
        return child!;
      },
    );
  }
}
