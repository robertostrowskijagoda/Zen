import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/presentation/call_compact_layer.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/calls/presentation/incoming_call_layer.dart';
import 'package:zen/src/features/meet/presentation/alarm_screen.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/runtime_lifecycle_bridge.dart';
import 'package:zen/src/features/runtime/runtime_route_bridge.dart';
import 'package:zen/src/features/runtime/runtime_signal_bridge.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/test_harness_server.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';

/// Navigator that owns every app route.
///
/// The call overlays live above it (in [MaterialApp.builder]) so a ringing
/// call is visible no matter which route is on top, which also means they
/// cannot reach a `Navigator` through their own context.
final GlobalKey<NavigatorState> zenRootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'zenRootNavigator',
);

class ZenRewriteApp extends ConsumerWidget {
  const ZenRewriteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zen',
      navigatorKey: zenRootNavigatorKey,
      theme: ZenTheme.light(settings.accentTheme),
      darkTheme: ZenTheme.dark(settings.accentTheme),
      themeMode: settings.themeMode.materialThemeMode,
      builder: (BuildContext context, Widget? child) {
        // Above the root Navigator and security gate on purpose: a pushed route
        // or the PIN lock screen must never hide an incoming call.
        // Outermost: while a call floats over other apps (Android
        // picture-in-picture, the small window on a computer) only the call
        // is drawn.
        return CallCompactLayer(
          child: IncomingCallLayer(
            child: AppSecurityGate(
              child: CallFloatingOverlay(
                // Around the whole navigator: on a computer every screen,
                // pushed ones and dialogs included, keeps the same phone-like
                // column (before, only the home screen did and pushed
                // screens stretched across the window).
                child: _DesktopViewportFrame(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      },
      home: const RuntimeDeepLinkBridge(
        child: RuntimeSystemNotificationsBridge(
          child: RuntimeLifecycleBridge(
            child: AndroidBackgroundRuntimeBridge(
              child: RuntimeSignalBridge(
                child: TestHarnessBridge(
                  child: AlarmWatcher(
                    child: RuntimeRouteBridge(child: AppShellScreen()),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopViewportFrame extends StatelessWidget {
  const _DesktopViewportFrame({required this.child});

  static const double _desktopContentMaxWidth = 430;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return child;
    }
    return ColoredBox(
      color: ZenColors.of(context).background,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (!constraints.maxWidth.isFinite ||
              constraints.maxWidth <= _desktopContentMaxWidth + 24) {
            return child;
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: _desktopContentMaxWidth,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ZenColors.of(context).background,
                  border: Border.symmetric(
                    vertical: BorderSide(color: ZenColors.of(context).outline),
                  ),
                ),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}
