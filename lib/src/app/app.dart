import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_language_controller.dart';
import 'package:zen/src/app/i18n/zen_locales.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/logging/zen_log.dart';
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

class ZenRewriteApp extends ConsumerStatefulWidget {
  const ZenRewriteApp({super.key});

  @override
  ConsumerState<ZenRewriteApp> createState() => _ZenRewriteAppState();
}

class _ZenRewriteAppState extends ConsumerState<ZenRewriteApp>
    with WidgetsBindingObserver {
  /// Runs the services (A15); started by `RuntimeSignalBridge` once the
  /// security gate lets the app through. This widget forwards the return to
  /// the screen and flag changes.
  late final ZenCore _core;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _core = ref.read(zenCoreProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _core.resumed();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    // With no language chosen in Zen, it follows the system (on Android 13+
    // also the language picked for Zen in the system settings).
    unawaitedLogged(
      ref.read(zenLanguageControllerProvider.notifier).followSystem(locales),
      context: 'Following the system language failed',
    );
  }

  @override
  Widget build(BuildContext context) {
    // A feature switched on or off while the app runs starts or stops its
    // module.
    ref.listen<FeatureFlags>(
      featureFlagsProvider,
      (FeatureFlags? previous, FeatureFlags next) => _core.applyFlags(next),
    );
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final String languageCode = ref.watch(
      zenLanguageControllerProvider.select(
        (ZenLanguageState language) => language.code,
      ),
    );
    // Every text comes from t(), read while building: a new language
    // rebuilds every widget in place, so the state and the open screens
    // (the language screen itself) stay as they are.
    ref.listen<String>(
      zenLanguageControllerProvider.select(
        (ZenLanguageState language) => language.code,
      ),
      (String? previous, String next) {
        if (previous != next) {
          rebuildAllZenElements();
        }
      },
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zen',
      navigatorKey: zenRootNavigatorKey,
      theme: ZenTheme.light(settings.accentTheme, settings.palette),
      darkTheme: ZenTheme.dark(settings.accentTheme, settings.palette),
      themeMode: settings.themeMode.materialThemeMode,
      // Material's own texts (tooltips, pickers, text selection) and the
      // layout direction follow Zen's language.
      locale: zenLocaleOf(languageCode),
      supportedLocales: zenSupportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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

  static const Set<TargetPlatform> _desktops = <TargetPlatform>{
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  };

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !_desktops.contains(defaultTargetPlatform)) {
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
