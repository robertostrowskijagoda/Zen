import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// What the phone says about itself. A rooted or modified
/// phone lets other apps read Zen's memory and files, so the person is
/// warned; nothing is blocked — it is their phone.
@immutable
final class DeviceIntegrity {
  const DeviceIntegrity({
    this.rooted = false,
    this.reasons = const <String>[],
    this.debuggable = false,
  });

  static const DeviceIntegrity clean = DeviceIntegrity();

  final bool rooted;
  final List<String> reasons;

  /// A debug build of Zen (development only).
  final bool debuggable;

  bool get hasWarning => rooted;

  static DeviceIntegrity fromMap(Map<Object?, Object?> map) {
    final Object? reasons = map['reasons'];
    return DeviceIntegrity(
      rooted: map['rooted'] == true,
      reasons: reasons is List
          ? reasons.whereType<String>().toList(growable: false)
          : const <String>[],
      debuggable: map['debuggable'] == true,
    );
  }

  /// The reasons in words.
  List<String> describe() => <String>[
    for (final String reason in reasons)
      switch (reason) {
        'su' => t('Znaleziono program su (uprawnienia roota).'),
        'test-keys' => t('System jest podpisany kluczami testowymi.'),
        'frida' => t('Znaleziono narzędzie do podglądania aplikacji (Frida).'),
        final String app when app.startsWith('app:') => t(
          'Zainstalowano aplikację do roota lub modyfikacji: {app}.',
          {'app': app.substring(4)},
        ),
        _ => reason,
      },
  ];
}

/// Asks the native side (`zen/integrity`, Android only).
Future<DeviceIntegrity> checkDeviceIntegrity({MethodChannel? channel}) async {
  if (kIsWeb || !Platform.isAndroid) {
    return DeviceIntegrity.clean;
  }
  try {
    final Map<Object?, Object?>? map =
        await (channel ?? const MethodChannel('zen/integrity'))
            .invokeMethod<Map<Object?, Object?>>('check');
    return map == null ? DeviceIntegrity.clean : DeviceIntegrity.fromMap(map);
  } on MissingPluginException {
    return DeviceIntegrity.clean;
  } on PlatformException catch (error) {
    logZenWarning('Integrity check: ${error.code} ${error.message}');
    return DeviceIntegrity.clean;
  }
}

final FutureProvider<DeviceIntegrity> deviceIntegrityProvider =
    FutureProvider<DeviceIntegrity>((Ref ref) => checkDeviceIntegrity());
