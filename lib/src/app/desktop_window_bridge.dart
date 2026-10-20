import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/single_instance_guard.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/calls/call_compact_mode.dart';

typedef DesktopTrayIconLoader = Future<String?> Function();

enum DesktopTrayEvent { click, rightClick }

abstract class DesktopWindowShellApi {
  Future<void> ensureReady();

  Future<void> applyRecommendedWindowGeometry();

  Future<void> setPreventClose(bool value);

  Future<bool> isPreventClose();

  Future<void> show();

  Future<void> focus();

  Future<void> hide();

  Future<void> close();

  Future<void> initTray({required String title, required String iconPath});

  Future<void> setTrayContextMenu({
    required Future<void> Function() onShowWindow,
    required Future<void> Function() onExitApp,
  });

  void registerTrayEventHandler(
    Future<void> Function(DesktopTrayEvent event) handler,
  );

  Future<void> popUpTrayContextMenu();

  Future<void> destroyTray();
}

final class DesktopTrayCoordinator {
  DesktopTrayCoordinator({
    required DesktopWindowShellApi api,
    this.closeToTray = true,
  }) : _api = api;

  final DesktopWindowShellApi _api;
  final bool closeToTray;
  String? _cachedIconPath;
  bool _trayInitialized = false;

  bool get isTrayInitialized => _trayInitialized;

  Future<bool> initialize(String iconPath) async {
    _cachedIconPath = iconPath;
    logZenMessage(
      'DesktopTrayCoordinator.initialize: iconPath="$iconPath", closeToTray=$closeToTray',
    );
    await _api.ensureReady();
    await _api.applyRecommendedWindowGeometry();
    await _api.show();
    await _api.focus();
    final bool ok = await _tryInitTray();
    if (closeToTray && ok) {
      await _api.setPreventClose(true);
    } else {
      await _api.setPreventClose(false);
    }
    if (iconPath.isEmpty) {
      logZenMessage('DesktopTrayCoordinator.initialize: iconPath is empty!');
      return false;
    }
    return ok;
  }

  Future<bool> _tryInitTray() async {
    final String? iconPath = _cachedIconPath;
    if (iconPath == null || iconPath.isEmpty || _trayInitialized) {
      return _trayInitialized;
    }
    try {
      logZenMessage('DesktopTrayCoordinator.initialize: calling initTray');
      await _api.initTray(title: 'Zen', iconPath: iconPath);
      logZenMessage('DesktopTrayCoordinator.initialize: setting context menu');
      await _api.setTrayContextMenu(
        onShowWindow: showWindow,
        onExitApp: exitApp,
      );
      _api.registerTrayEventHandler(handleTrayEvent);
      if (closeToTray) {
        await _api.setPreventClose(true);
      } else {
        await _api.setPreventClose(false);
      }
      _trayInitialized = true;
      logZenMessage(
        'DesktopTrayCoordinator.initialize: completed successfully, closeToTray=$closeToTray',
      );
      return true;
    } catch (error, stackTrace) {
      logZenError('Desktop tray init failed', error, stackTrace);
      await _api.setPreventClose(false);
      return false;
    }
  }

  Future<void> handleWindowClose() async {
    if (closeToTray && _trayInitialized) {
      await _api.hide();
    } else {
      await _api.close();
    }
  }

  Future<void> handleTrayEvent(DesktopTrayEvent event) {
    switch (event) {
      case DesktopTrayEvent.click:
        return showWindow();
      case DesktopTrayEvent.rightClick:
        return _api.popUpTrayContextMenu();
    }
  }

  Future<void> showWindow() async {
    await _api.show();
    await _api.focus();
    if (!_trayInitialized) {
      unawaitedLogged(
        _tryInitTray(),
        context: 'Desktop tray retry on showWindow failed',
      );
    }
  }

  Future<void> exitApp() async {
    await _api.setPreventClose(false);
    await _api.close();
  }

  Future<void> dispose() => _api.destroyTray();
}

class DesktopWindowBridge extends StatefulWidget {
  const DesktopWindowBridge({
    required this.child,
    this.api,
    this.iconLoader = loadDesktopTrayIcon,
    super.key,
  });

  final Widget child;
  final DesktopWindowShellApi? api;
  final DesktopTrayIconLoader iconLoader;

  @override
  State<DesktopWindowBridge> createState() => _DesktopWindowBridgeState();
}

class _DesktopWindowBridgeState extends State<DesktopWindowBridge>
    with WindowListener {
  DesktopTrayCoordinator? _coordinator;

  bool get _enabled =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    if (!_enabled) {
      return;
    }
    // A second launch hands its request over to this instance instead of
    // starting a rival process; bring the window back for the user.
    ZenSingleInstance.setActivationHandler(_handleActivationRequest);
    try {
      windowManager.addListener(this);
    } catch (error, stackTrace) {
      logZenError(
        'Desktop window listener registration failed',
        error,
        stackTrace,
      );
    }
    unawaitedLogged(
      _initialize(),
      context: 'Desktop window bridge initialization failed',
    );
  }

  @override
  void dispose() {
    if (_enabled) {
      ZenSingleInstance.setActivationHandler(null);
      try {
        windowManager.removeListener(this);
      } catch (error, stackTrace) {
        logZenError(
          'Desktop window listener removal failed',
          error,
          stackTrace,
        );
      }
    }
    final DesktopTrayCoordinator? coordinator = _coordinator;
    if (coordinator != null) {
      unawaitedLogged(
        coordinator.dispose(),
        context: 'Desktop tray disposal failed',
      );
    }
    super.dispose();
  }

  @override
  void onWindowMinimize() {
    // During a call the window does not disappear: it turns into a small
    // window that stays on top of other apps.
    final CallCompactMode call = CallCompactMode.instance;
    if (call.callRunning && !call.active.value) {
      unawaitedLogged(
        call.enterDesktop(),
        context: 'Floating call window on minimize failed',
      );
    }
  }

  @override
  Future<void> onWindowClose() async {
    final CallCompactMode call = CallCompactMode.instance;
    if (call.callRunning) {
      // Closing during a call would hide it in the tray; keep it floating.
      if (!call.active.value) {
        await call.enterDesktop();
      }
      return;
    }
    final DesktopTrayCoordinator? coordinator = _coordinator;
    if (coordinator != null &&
        coordinator.closeToTray &&
        coordinator.isTrayInitialized) {
      await coordinator.handleWindowClose();
      return;
    }
    try {
      await ZenSingleInstance.release();
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  Future<void> _handleActivationRequest() async {
    if (CallCompactMode.instance.active.value) {
      await CallCompactMode.instance.exitDesktop();
    }
    try {
      await windowManager.setSkipTaskbar(false);
      try {
        await windowManager.restore();
      } catch (_) {}
      await windowManager.show();
      await windowManager.focus();
    } catch (error, stackTrace) {
      logZenError('Raising the window on activation failed', error, stackTrace);
    }
    final DesktopTrayCoordinator? coordinator = _coordinator;
    if (coordinator != null) {
      await coordinator.showWindow();
    }
  }

  Future<void> _initialize() async {
    final DesktopTrayCoordinator coordinator = DesktopTrayCoordinator(
      api: widget.api ?? _PlatformDesktopWindowShellApi(),
      closeToTray: true,
    );
    _coordinator = coordinator;
    if (widget.api == null) {
      CallCompactMode.instance
        ..desktopMinimumSize = _PlatformDesktopWindowShellApi.minimumWindowSize
        ..desktopWindowReady = true;
    }
    try {
      final String iconPath = await widget.iconLoader() ?? '';
      logZenMessage(
        '_DesktopWindowBridgeState._initialize: iconPath="$iconPath"',
      );
      final bool initialized = await coordinator.initialize(iconPath);
      logZenMessage(
        '_DesktopWindowBridgeState._initialize: initialized=$initialized',
      );
      if (!mounted) {
        await coordinator.dispose();
        _coordinator = null;
        return;
      }
    } catch (error, stackTrace) {
      logZenError('Desktop tray init error', error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<String?> loadDesktopTrayIcon() async {
  if (kIsWeb ||
      (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
    return null;
  }
  if (!Platform.isWindows) {
    // Linux and macOS: system_tray takes the asset key and finds the file
    // itself (data/flutter_assets on Linux, the app bundle on macOS). A PNG:
    // not every Linux panel reads .ico files.
    return 'assets/branding/tray_icon.png';
  }
  try {
    final String executableDirectory = File(
      Platform.resolvedExecutable,
    ).parent.path;
    final File directIcon = File(
      '$executableDirectory${Platform.pathSeparator}tray_icon.ico',
    );
    if (await directIcon.exists()) {
      return directIcon.path;
    }
    const String assetPath = 'assets/branding/tray_icon.ico';
    final File bundledAssetIcon = File(
      '$executableDirectory${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}$assetPath',
    );
    if (await bundledAssetIcon.exists()) {
      return bundledAssetIcon.path;
    }
    debugPrint('[ZEN] Desktop tray icon missing');
    return null;
  } catch (error) {
    debugPrint('[ZEN] Desktop tray icon load error: $error');
    return null;
  }
}

final class _PlatformDesktopWindowShellApi implements DesktopWindowShellApi {
  static const Size _preferredWindowSize = Size(430, 880);
  static const Size minimumWindowSize = Size(390, 720);

  final SystemTray _tray = SystemTray();

  @override
  Future<void> ensureReady() async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow();
    // Several test profiles side by side: tell the windows apart.
    final String? profile = ZenInstance.profile;
    if (profile != null) {
      await windowManager.setTitle('Zen — $profile');
    }
  }

  @override
  Future<void> applyRecommendedWindowGeometry() async {
    await windowManager.setMinimumSize(minimumWindowSize);
    await windowManager.setSize(_preferredWindowSize);
    await windowManager.center();
  }

  @override
  Future<void> setPreventClose(bool value) =>
      windowManager.setPreventClose(value);

  @override
  Future<bool> isPreventClose() => windowManager.isPreventClose();

  @override
  Future<void> show() async {
    await windowManager.setSkipTaskbar(false);
    try {
      await windowManager.restore();
    } catch (_) {}
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> hide() async {
    if (Platform.isLinux) {
      // A tray icon is not guaranteed on Linux (GNOME shows none without
      // the AppIndicator extension): keep the window in the taskbar.
      await windowManager.minimize();
      return;
    }
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  @override
  Future<void> close() async {
    try {
      await ZenSingleInstance.release();
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  @override
  Future<void> initTray({
    required String title,
    required String iconPath,
  }) async {
    logZenMessage(
      '_PlatformDesktopWindowShellApi.initTray: title="$title", iconPath="$iconPath"',
    );
    if (Platform.isWindows) {
      final String fullPath = File(iconPath).isAbsolute
          ? iconPath
          : '${File(Platform.resolvedExecutable).parent.path}\\$iconPath';
      final String normalized = fullPath.replaceAll('/', '\\');
      logZenMessage(
        '_PlatformDesktopWindowShellApi.initTray: fullPath="$fullPath", normalized="$normalized"',
      );
      const MethodChannel channel = MethodChannel('flutter/system_tray/tray');
      bool value = false;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          value =
              await channel
                  .invokeMethod<bool>('InitSystemTray', <String, dynamic>{
                    'tray_id': 'zen-tray',
                    'title': title,
                    'iconpath': normalized,
                    'tooltip': title,
                    'is_template': false,
                  }) ??
              false;
          if (value) {
            break;
          }
        } catch (error) {
          if (attempt == 2) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      logZenMessage(
        '_PlatformDesktopWindowShellApi.initTray: InitSystemTray result=$value',
      );
      if (!value) {
        throw StateError('InitSystemTray returned false');
      }
      return;
    }
    // Linux and macOS: the icon alone (a title would be drawn beside it in
    // the panel or the menu bar). A tray the desktop refuses is an error,
    // so closing the window does not hide Zen where nothing brings it back.
    final bool shown = await _tray.initSystemTray(
      iconPath: iconPath,
      toolTip: title,
    );
    if (!shown) {
      throw StateError('initSystemTray returned false');
    }
  }

  @override
  Future<void> setTrayContextMenu({
    required Future<void> Function() onShowWindow,
    required Future<void> Function() onExitApp,
  }) async {
    final Menu menu = Menu();
    await menu.buildFrom(<MenuItemBase>[
      MenuItemLabel(
        label: t('Pokaż okno'),
        onClicked: (_) {
          unawaitedLogged(
            onShowWindow(),
            context: 'Desktop tray show-window action failed',
          );
        },
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: t('Zamknij'),
        onClicked: (_) {
          unawaitedLogged(
            onExitApp(),
            context: 'Desktop tray exit action failed',
          );
        },
      ),
    ]);
    await _tray.setContextMenu(menu);
  }

  @override
  void registerTrayEventHandler(
    Future<void> Function(DesktopTrayEvent event) handler,
  ) {
    _tray.registerSystemTrayEventHandler((String eventName) {
      if (eventName == kSystemTrayEventClick) {
        unawaitedLogged(
          handler(DesktopTrayEvent.click),
          context: 'Desktop tray click handler failed',
        );
      } else if (eventName == kSystemTrayEventRightClick) {
        unawaitedLogged(
          handler(DesktopTrayEvent.rightClick),
          context: 'Desktop tray right-click handler failed',
        );
      }
    });
  }

  @override
  Future<void> popUpTrayContextMenu() => _tray.popUpContextMenu();

  @override
  Future<void> destroyTray() => _tray.destroy();
}
