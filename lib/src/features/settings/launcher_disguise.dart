import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Android: switches the launcher entry between Zen's own icon and name and
/// a neutral "Notatki" one (§14.2, "Kamuflaż ikony"). Native side:
/// `ZenSystemBridge` flips two activity-aliases so that exactly one launcher
/// entry is enabled.
class LauncherDisguise {
  const LauncherDisguise({
    MethodChannel channel = const MethodChannel('zen/system'),
    bool? supported,
  }) : _channel = channel,
       _supported = supported;

  final MethodChannel _channel;
  final bool? _supported;

  /// Only Android has launcher aliases.
  bool get supported => _supported ?? (!kIsWeb && Platform.isAndroid);

  /// Shows the neutral icon and name ([enabled]) or Zen's own. Returns `true`
  /// once the phone took the change; `false` where unsupported or on failure.
  Future<bool> set({required bool enabled}) async {
    if (!supported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('setDisguise', <String, Object>{
            'enabled': enabled,
          }) ??
          false;
    } on Object catch (error) {
      logZenWarning('Kamuflaż ikony: $error');
      return false;
    }
  }
}

final Provider<LauncherDisguise> launcherDisguiseProvider =
    Provider<LauncherDisguise>((Ref ref) => const LauncherDisguise());
