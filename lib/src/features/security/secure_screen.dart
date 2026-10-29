import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Zen never keeps its window out of screenshots, recordings, screen
/// sharing or the recent-apps preview: people may capture anything they
/// see. Versions before 1.15.1 could (Android `FLAG_SECURE`, Windows
/// `WDA_EXCLUDEFROMCAPTURE`, macOS `sharingType = .none`), and Android
/// remembers it across starts (`ZenSecurityBridge.kt`), so the window is
/// told once at every start to allow captures ([SecureAppWindow]).
final class SecureWindow {
  SecureWindow._();

  static const MethodChannel _channel = MethodChannel('zen/secure_window');

  /// For tests: what the window was last told (`true`: protected).
  @visibleForTesting
  static bool lastApplied = false;

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isMacOS);

  /// Lifts any capture protection an older version left on the window.
  static void allowCapture() {
    lastApplied = false;
    if (!_supported) {
      return;
    }
    _channel
        .invokeMethod<bool>('setSecure', <String, Object>{'secure': false})
        .catchError((Object error) {
          logZenWarning('Ochrona ekranu: $error');
          return false;
        });
  }
}

/// Marks a screen with private content (conversations, keys, the wallet).
/// It no longer blocks captures (see [SecureWindow]); it only shows [child].
class SecureScreen extends StatelessWidget {
  const SecureScreen({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Once, around the whole app: lifts the capture protection an older
/// version may have left on the window ([SecureWindow.allowCapture]).
class SecureAppWindow extends StatefulWidget {
  const SecureAppWindow({required this.child, super.key});

  final Widget child;

  @override
  State<SecureAppWindow> createState() => _SecureAppWindowState();
}

class _SecureAppWindowState extends State<SecureAppWindow> {
  @override
  void initState() {
    super.initState();
    SecureWindow.allowCapture();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
