import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Turns the window's capture protection on and off:
/// Android `FLAG_SECURE` (no screenshots or recording, blank in the recent
/// apps), Windows `WDA_EXCLUDEFROMCAPTURE` (left out of screenshots,
/// recordings and screen sharing), macOS `NSWindow.sharingType = .none`
/// (the same, for the capture APIs that honour it). Linux has no such
/// switch. Counted, so nested screens work.
///
/// On Android the whole window stays protected while the setting is on
/// ([acquireWholeWindow]): the recent-apps preview is taken from
/// whatever screen is open when the app is left — the chat list with its
/// previews too. On a computer it stays with the protected screens (which
/// include the chat list, so in practice while it is open).
final class SecureWindow {
  SecureWindow._();

  static const MethodChannel _channel = MethodChannel('zen/secure_window');
  static int _holders = 0;
  static int _wholeWindowHolders = 0;

  /// What the window was told last; `null` until the first time (the
  /// native side may start protected, see `ZenSecurityBridge.kt`).
  static bool? _applied;

  /// For tests: what the window was last told.
  @visibleForTesting
  static bool lastApplied = false;

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isMacOS);

  /// Where the setting covers the whole window, not only the protected
  /// screens.
  static bool get _coversWholeWindow =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void acquire() {
    _holders++;
    _sync();
  }

  static void release() {
    if (_holders == 0) {
      return;
    }
    _holders--;
    _sync();
  }

  /// The screen protection setting, for the whole window where the
  /// platform needs that (see [SecureAppWindow]). Counted like [acquire].
  static void acquireWholeWindow() {
    _wholeWindowHolders++;
    _sync();
  }

  static void releaseWholeWindow() {
    if (_wholeWindowHolders == 0) {
      return;
    }
    _wholeWindowHolders--;
    _sync();
  }

  static void _sync() {
    final bool secure =
        _holders > 0 || (_wholeWindowHolders > 0 && _coversWholeWindow);
    if (secure == _applied) {
      return;
    }
    _applied = secure;
    _apply(secure);
  }

  static void _apply(bool secure) {
    lastApplied = secure;
    if (!_supported) {
      return;
    }
    _channel
        .invokeMethod<bool>('setSecure', <String, Object>{'secure': secure})
        .catchError((Object error) {
          logZenWarning('Ochrona ekranu: $error');
          return false;
        });
  }
}

/// While shown, nobody can screenshot or record [child] (when the setting
/// is on, which it is by default). On Android the whole window is
/// protected anyway then ([SecureAppWindow]); this is for computers.
class SecureScreen extends ConsumerStatefulWidget {
  const SecureScreen({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends ConsumerState<SecureScreen> {
  bool _held = false;

  void _sync(bool want) {
    if (want && !_held) {
      SecureWindow.acquire();
      _held = true;
    } else if (!want && _held) {
      SecureWindow.release();
      _held = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync(ref.read(appSettingsControllerProvider).secureScreens);
  }

  @override
  void dispose() {
    _sync(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appSettingsControllerProvider.select((AppSettings s) => s.secureScreens),
      (bool? previous, bool next) => _sync(next),
    );
    return widget.child;
  }
}

/// Once, around the whole app: the screen protection setting for the whole
/// window where the platform needs it (Android, see [SecureWindow]).
class SecureAppWindow extends ConsumerStatefulWidget {
  const SecureAppWindow({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<SecureAppWindow> createState() => _SecureAppWindowState();
}

class _SecureAppWindowState extends ConsumerState<SecureAppWindow> {
  bool _held = false;

  void _sync(bool want) {
    if (want && !_held) {
      SecureWindow.acquireWholeWindow();
      _held = true;
    } else if (!want && _held) {
      SecureWindow.releaseWholeWindow();
      _held = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync(ref.read(appSettingsControllerProvider).secureScreens);
  }

  @override
  void dispose() {
    _sync(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      appSettingsControllerProvider.select((AppSettings s) => s.secureScreens),
      (bool? previous, bool next) => _sync(next),
    );
    return widget.child;
  }
}
