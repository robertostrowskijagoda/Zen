import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/desktop_window_bridge.dart';

void main() {
  test('desktop tray coordinator hides to tray by default on close', () async {
    final _FakeDesktopWindowShellApi api = _FakeDesktopWindowShellApi();
    final DesktopTrayCoordinator coordinator = DesktopTrayCoordinator(api: api);

    final bool initialized = await coordinator.initialize('icon.ico');

    expect(initialized, isTrue);
    expect(api.ensureReadyCount, 1);
    expect(api.applyRecommendedWindowGeometryCount, 1);
    expect(api.trayTitle, 'Zen');
    expect(api.trayIconPath, 'icon.ico');
    expect(api.preventClose, isTrue);
    expect(api.registeredHandler, isNotNull);

    await coordinator.handleWindowClose();

    expect(api.hideCount, 1);
    expect(api.closeCount, 0);
  });

  test(
    'desktop tray coordinator exits cleanly when closeToTray is false',
    () async {
      final _FakeDesktopWindowShellApi api = _FakeDesktopWindowShellApi();
      final DesktopTrayCoordinator coordinator = DesktopTrayCoordinator(
        api: api,
        closeToTray: false,
      );

      final bool initialized = await coordinator.initialize('icon.ico');

      expect(initialized, isTrue);
      expect(api.ensureReadyCount, 1);
      expect(api.applyRecommendedWindowGeometryCount, 1);
      expect(api.trayTitle, 'Zen');
      expect(api.trayIconPath, 'icon.ico');
      expect(api.preventClose, isFalse);
      expect(api.registeredHandler, isNotNull);

      await coordinator.handleWindowClose();

      expect(api.hideCount, 0);
      expect(api.closeCount, 1);
    },
  );

  test('desktop tray coordinator restores window and handles exit', () async {
    final _FakeDesktopWindowShellApi api = _FakeDesktopWindowShellApi();
    final DesktopTrayCoordinator coordinator = DesktopTrayCoordinator(api: api);

    await coordinator.handleTrayEvent(DesktopTrayEvent.click);
    await coordinator.handleTrayEvent(DesktopTrayEvent.rightClick);
    await coordinator.exitApp();

    expect(api.showCount, 1);
    expect(api.focusCount, 1);
    expect(api.popUpContextMenuCount, 1);
    expect(api.preventClose, isFalse);
    expect(api.closeCount, 1);
  });

  test(
    'desktop tray coordinator falls back to exiting app when tray init fails',
    () async {
      final _FailingTrayDesktopWindowShellApi api =
          _FailingTrayDesktopWindowShellApi();
      final DesktopTrayCoordinator coordinator = DesktopTrayCoordinator(
        api: api,
        closeToTray: true,
      );

      final bool initialized = await coordinator.initialize('icon.ico');

      expect(initialized, isFalse);
      expect(coordinator.isTrayInitialized, isFalse);
      expect(api.preventClose, isFalse);

      await coordinator.handleWindowClose();

      expect(api.hideCount, 0);
      expect(api.closeCount, 1);
    },
  );
}

final class _FakeDesktopWindowShellApi implements DesktopWindowShellApi {
  int ensureReadyCount = 0;
  int applyRecommendedWindowGeometryCount = 0;
  bool preventClose = false;
  int showCount = 0;
  int focusCount = 0;
  int hideCount = 0;
  int closeCount = 0;
  int popUpContextMenuCount = 0;
  String? trayTitle;
  String? trayIconPath;
  Future<void> Function(DesktopTrayEvent event)? registeredHandler;

  @override
  Future<void> ensureReady() async {
    ensureReadyCount += 1;
  }

  @override
  Future<void> applyRecommendedWindowGeometry() async {
    applyRecommendedWindowGeometryCount += 1;
  }

  @override
  Future<void> setPreventClose(bool value) async {
    preventClose = value;
  }

  @override
  Future<bool> isPreventClose() async => preventClose;

  @override
  Future<void> show() async {
    showCount += 1;
  }

  @override
  Future<void> focus() async {
    focusCount += 1;
  }

  @override
  Future<void> hide() async {
    hideCount += 1;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }

  @override
  Future<void> initTray({
    required String title,
    required String iconPath,
  }) async {
    trayTitle = title;
    trayIconPath = iconPath;
  }

  @override
  Future<void> setTrayContextMenu({
    required Future<void> Function() onShowWindow,
    required Future<void> Function() onExitApp,
  }) async {}

  @override
  void registerTrayEventHandler(
    Future<void> Function(DesktopTrayEvent event) handler,
  ) {
    registeredHandler = handler;
  }

  @override
  Future<void> popUpTrayContextMenu() async {
    popUpContextMenuCount += 1;
  }

  @override
  Future<void> destroyTray() async {}
}

final class _FailingTrayDesktopWindowShellApi
    extends _FakeDesktopWindowShellApi {
  @override
  Future<void> initTray({
    required String title,
    required String iconPath,
  }) async {
    throw Exception('Tray init failed');
  }
}
