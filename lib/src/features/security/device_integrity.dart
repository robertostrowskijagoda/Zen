import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/update/apk_signature.dart';
import 'package:zen/src/features/update/own_copy.dart';
import 'package:zen/src/features/update/store_build.dart';

/// What the device and this process say about themselves.
///
/// Two kinds of findings, answered in proportion:
///  - [rooted] (root, jailbreak, test keys, root apps, an emulator as a
///    hint): other apps may read Zen's memory and files, so the person is
///    warned; nothing is blocked — it is their phone;
///  - [tampered]: someone is inside this very process right now — a
///    debugger attached, an instrumentation tool (Frida) or a hooking
///    framework (Xposed, LSPosed, Substrate) loaded, a library injected, or
///    the app re-signed or made debuggable. Then a modified memory could
///    sign what the person never asked for, so Zen also refuses what moves
///    money or uses the pyramid's power key ([TamperGuard]) until it is
///    gone.
@immutable
final class DeviceIntegrity {
  const DeviceIntegrity({
    this.rooted = false,
    this.reasons = const <String>[],
    this.debuggable = false,
    this.tampered = false,
    this.emulator = false,
  });

  static const DeviceIntegrity clean = DeviceIntegrity();

  final bool rooted;
  final List<String> reasons;

  /// A debug build of Zen (development; in a release build it is a
  /// modified copy, [tampered]).
  final bool debuggable;

  /// Something is inside this process (see the class).
  final bool tampered;

  /// Running in an emulator or simulator (a hint only).
  final bool emulator;

  bool get hasWarning => rooted || tampered;

  /// Reasons that mean the process itself is being looked into or changed.
  static const Set<String> tamperReasons = <String>{
    'debugger',
    'frida-loaded',
    'frida-port',
    'hooks',
    'injected',
    'app-debuggable',
    'resigned',
  };

  /// [map] from the native side; [release]: this is a release build, so a
  /// debuggable app is a modified one.
  static DeviceIntegrity fromMap(
    Map<Object?, Object?> map, {
    bool release = kReleaseMode,
  }) {
    final Object? raw = map['reasons'];
    final List<String> reasons = <String>[
      if (raw is List) ...raw.whereType<String>(),
    ];
    final bool debuggable = map['debuggable'] == true;
    if (release && debuggable && !reasons.contains('app-debuggable')) {
      reasons.add('app-debuggable');
    }
    final bool tampered =
        map['tampered'] == true || reasons.any(tamperReasons.contains);
    return DeviceIntegrity(
      rooted: map['rooted'] == true,
      reasons: List<String>.unmodifiable(reasons),
      debuggable: debuggable,
      tampered: tampered,
      emulator: map['emulator'] == true || reasons.contains('emulator'),
    );
  }

  /// This, with the further [found] reasons of tampering.
  DeviceIntegrity withTampering(Iterable<String> found) {
    final List<String> more = <String>[
      for (final String r in found)
        if (!reasons.contains(r)) r,
    ];
    if (more.isEmpty) {
      return this;
    }
    return DeviceIntegrity(
      rooted: rooted,
      reasons: List<String>.unmodifiable(<String>[...reasons, ...more]),
      debuggable: debuggable,
      tampered: true,
      emulator: emulator,
    );
  }

  /// The reasons in words.
  List<String> describe() => <String>[
    for (final String reason in reasons)
      switch (reason) {
        'su' => t('Znaleziono program su (uprawnienia roota).'),
        'test-keys' => t('System jest podpisany kluczami testowymi.'),
        'frida' => t('Znaleziono narzędzie do podglądania aplikacji (Frida).'),
        'jailbreak' => t('Telefon ma jailbreak.'),
        'emulator' => t('Zen działa w emulatorze.'),
        'debugger' => t('Do Zen jest podłączony debuger.'),
        'frida-loaded' => t('W pamięci Zen działa narzędzie Frida.'),
        'frida-port' => t('Na urządzeniu działa serwer narzędzia Frida.'),
        'hooks' => t(
          'Zen jest zmieniany w locie (Xposed, LSPosed lub podobne).',
        ),
        'injected' => t('Do Zen wstrzyknięto obcą bibliotekę.'),
        'app-debuggable' => t(
          'Ta kopia Zen pozwala się debugować, a nie powinna.',
        ),
        'resigned' => t(
          'Ta kopia Zen jest podpisana innym certyfikatem niż oficjalna.',
        ),
        final String app when app.startsWith('app:') => t(
          'Zainstalowano aplikację do roota lub modyfikacji: {app}.',
          {'app': app.substring(4)},
        ),
        _ => reason,
      },
  ];
}

/// Whether a debugger is attached to this process, from
/// `/proc/self/status` (Linux and Android): its `TracerPid` is not 0.
bool tracedFromStatus(String status) {
  for (final String line in status.split('\n')) {
    if (line.startsWith('TracerPid:')) {
      final int? pid = int.tryParse(line.substring(10).trim());
      return pid != null && pid != 0;
    }
  }
  return false;
}

/// Asks the native side (`zen/integrity`: Android, iOS, macOS, Windows);
/// on Linux reads `/proc/self/status`. On Android also compares the app's
/// signing certificate with the official one when one is pinned.
Future<DeviceIntegrity> checkDeviceIntegrity({MethodChannel? channel}) async {
  if (kIsWeb) {
    return DeviceIntegrity.clean;
  }
  DeviceIntegrity found = DeviceIntegrity.clean;
  if (Platform.isLinux) {
    try {
      final String status = await File('/proc/self/status').readAsString();
      if (tracedFromStatus(status)) {
        found = found.withTampering(const <String>['debugger']);
      }
    } on Object {
      // No /proc: nothing to tell.
    }
    return found;
  }
  if (!Platform.isAndroid &&
      !Platform.isIOS &&
      !Platform.isMacOS &&
      !Platform.isWindows) {
    return found;
  }
  try {
    final Map<Object?, Object?>? map =
        await (channel ?? const MethodChannel('zen/integrity'))
            .invokeMethod<Map<Object?, Object?>>('check');
    if (map != null) {
      found = DeviceIntegrity.fromMap(map);
    }
  } on MissingPluginException {
    return found;
  } on PlatformException catch (error) {
    logZenWarning('Integrity check: ${error.code} ${error.message}');
    return found;
  } on Object catch (error) {
    // No platform side in this process (a test, a background isolate).
    logZenWarning('Integrity check: $error');
    return found;
  }
  if (Platform.isAndroid && !isStoreBuild) {
    try {
      final List<String>? own = await ownSigningCertificates();
      if (own != null &&
          ownCopyState(own: own, official: kOfficialApkCertificatesSha256) ==
              OwnCopyState.differs) {
        found = found.withTampering(const <String>['resigned']);
      }
    } on Object catch (error) {
      logZenWarning('Integrity check (signature): $error');
    }
  }
  return found;
}

/// Refuses what must not run while someone is inside this process: money
/// leaving the wallet and the pyramid's power key.
///
/// Proportional: a rooted phone only warns; a debugger, an instrumentation
/// tool, hooks or a re-signed copy ([DeviceIntegrity.tampered]) block these
/// few operations until the next check finds them gone (checks are a
/// minute apart at most). Everything else keeps working.
///
/// Why only these: a wallet's balance is not a number in this phone's
/// memory but follows from signed records that every member's phone
/// checks for itself — a modified memory cannot mint money for anyone, nor
/// forge another person's records. What it could do is sign with this
/// phone's own keys: a payment, or a record with the power key.
abstract final class TamperGuard {
  static DeviceIntegrity? _last;
  static int _checkedAt = 0;
  static Future<DeviceIntegrity>? _running;

  /// Replaces the check (tests); `null` restores it.
  @visibleForTesting
  static Future<DeviceIntegrity> Function()? debugCheck;

  /// How long one check counts.
  static const Duration fresh = Duration(minutes: 1);

  /// The last check's findings (clean before the first).
  static DeviceIntegrity get last => _last ?? DeviceIntegrity.clean;

  /// The findings, checked again when the last check is older than
  /// [fresh].
  static Future<DeviceIntegrity> current() async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final DeviceIntegrity? had = _last;
    if (had != null && now - _checkedAt < fresh.inMilliseconds) {
      return had;
    }
    final Future<DeviceIntegrity> running = _running ??=
        (debugCheck ?? checkDeviceIntegrity)();
    try {
      final DeviceIntegrity found = await running;
      _last = found;
      _checkedAt = DateTime.now().millisecondsSinceEpoch;
      return found;
    } on Object catch (error) {
      logZenWarning('Integrity check: $error');
      return last;
    } finally {
      _running = null;
    }
  }

  /// Whether money may leave the wallet and the power key may sign now.
  static Future<bool> allowsSensitive() async => !(await current()).tampered;

  /// Forgets the last check (tests).
  @visibleForTesting
  static void reset() {
    _last = null;
    _checkedAt = 0;
    _running = null;
    debugCheck = null;
  }
}

final FutureProvider<DeviceIntegrity> deviceIntegrityProvider =
    FutureProvider<DeviceIntegrity>((Ref ref) => TamperGuard.current());
