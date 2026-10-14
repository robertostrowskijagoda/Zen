import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Turns the window's capture protection on and off (§14.1, point 6):
/// Android `FLAG_SECURE` (no screenshots or recording, blank in the recent
/// apps), Windows `WDA_EXCLUDEFROMCAPTURE` (left out of screenshots,
/// recordings and screen sharing). Counted, so nested screens work.
final class SecureWindow {
  SecureWindow._();

  static const MethodChannel _channel = MethodChannel('zen/secure_window');
  static int _holders = 0;

  /// For tests: what the window was last told.
  @visibleForTesting
  static bool lastApplied = false;

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  static void acquire() {
    _holders++;
    if (_holders == 1) {
      _apply(true);
    }
  }

  static void release() {
    if (_holders == 0) {
      return;
    }
    _holders--;
    if (_holders == 0) {
      _apply(false);
    }
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
/// is on, which it is by default).
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
