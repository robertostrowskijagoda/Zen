import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// "Nie blokuj od razu po zamknięciu aplikacji": what keeps the app's
/// master key for a start soon after Zen was closed (swiped away, stopped
/// by the system), so that start opens without the password while the set
/// lock delay has not passed.
///
/// Whatever is sealed opens only:
///
/// * before its lifetime is over, counted on the clock that runs since the
///   device started (setting the date back gives nothing);
/// * on the same boot: after a restart of the device the password is
///   needed again;
/// * while the device's own screen lock is as it was (turned on or off
///   since: the password).
///
/// It never holds the app password, only the key the password unwraps.
abstract interface class ResumeSessionVault {
  /// Whether this device can keep it at all.
  bool get isAvailable;

  /// [secret] sealed for [lifetime]; `null` when it cannot be.
  Future<Uint8List?> seal(Uint8List secret, Duration lifetime);

  /// What [sealed] holds; `null` once expired, after a restart, after the
  /// screen lock changed, or for anything that is not a sealed secret.
  Future<Uint8List?> open(Uint8List sealed);

  /// Destroys the key everything was sealed with (where there is one):
  /// copies sealed before open nothing.
  Future<void> wipe();
}

/// The longest a sealed secret may live: the longest lock delay.
const Duration kResumeSessionLongest = Duration(
  seconds: AppSettings.maximumBackgroundLockDelaySeconds,
);

/// The vault for this device.
ResumeSessionVault platformResumeSessionVault() {
  if (kIsWeb) {
    return const NoResumeSessionVault();
  }
  if (Platform.isAndroid) {
    return ChannelResumeSessionVault();
  }
  return const ClockResumeSessionVault(
    sinceBootMillis: systemSinceBootMillis,
    screenLock: deviceScreenLockOn,
  );
}

/// Nowhere to keep it: every start asks for the password.
final class NoResumeSessionVault implements ResumeSessionVault {
  const NoResumeSessionVault();

  @override
  bool get isAvailable => false;

  @override
  Future<Uint8List?> seal(Uint8List secret, Duration lifetime) async => null;

  @override
  Future<Uint8List?> open(Uint8List sealed) async => null;

  @override
  Future<void> wipe() async {}
}

/// Android: sealed by an RSA key pair in the Android Keystore that only
/// opens while the phone is unlocked (MainActivity, `zen/resume_session`).
/// The lifetime, the boot and the screen lock are checked there, on the
/// phone's own clocks. The channel is the app's only: the background
/// service runs on an engine of its own without it, so it cannot open what
/// is sealed even though it reads the same secret store.
final class ChannelResumeSessionVault implements ResumeSessionVault {
  ChannelResumeSessionVault({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('zen/resume_session');

  final MethodChannel _channel;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      logZenWarning('The session kept after closing ($method): ${error.code}');
      return null;
    }
  }

  @override
  bool get isAvailable => true;

  @override
  Future<Uint8List?> seal(Uint8List secret, Duration lifetime) {
    if (lifetime <= Duration.zero || lifetime > kResumeSessionLongest) {
      return Future<Uint8List?>.value();
    }
    return _call<Uint8List>('seal', <String, Object>{
      'data': secret,
      'ttlMs': lifetime.inMilliseconds,
    });
  }

  @override
  Future<Uint8List?> open(Uint8List sealed) =>
      _call<Uint8List>('open', <String, Object>{'data': sealed});

  @override
  Future<void> wipe() async {
    await _call<bool>('wipe');
  }
}

/// iOS, macOS, Windows and Linux: the sealed secret is kept only in the
/// system's secret store (the iOS keychain for this device only and after
/// the first unlock, the macOS login keychain, DPAPI on Windows, the Secret
/// Service on Linux), with the boot it was made on and its end on the
/// clock since boot, checked here.
final class ClockResumeSessionVault implements ResumeSessionVault {
  const ClockResumeSessionVault({
    required this.sinceBootMillis,
    this.screenLock,
    this.now = DateTime.now,
  });

  /// Milliseconds since the device started, sleep included; `null` when
  /// it cannot be told (then nothing is kept).
  final int? Function() sinceBootMillis;

  /// Whether the device has a screen lock; `null` when it cannot be told.
  final Future<bool?> Function()? screenLock;

  final DateTime Function() now;

  /// How far the start of the boot may seem to move between sealing and
  /// opening (the wall clock corrected meanwhile). A restart moves it by
  /// far more: the device's whole uptime before.
  static const Duration bootSlack = Duration(seconds: 10);

  static const int _format = 1;

  @override
  bool get isAvailable => true;

  @override
  Future<Uint8List?> seal(Uint8List secret, Duration lifetime) async {
    if (lifetime <= Duration.zero || lifetime > kResumeSessionLongest) {
      return null;
    }
    final int? since = sinceBootMillis();
    if (since == null) {
      return null;
    }
    final bool? lock = await screenLock?.call();
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'v': _format,
          'k': securityHexFromBytes(secret),
          'b': now().millisecondsSinceEpoch - since,
          's': since,
          'd': since + lifetime.inMilliseconds,
          'l': lock,
        }),
      ),
    );
  }

  @override
  Future<Uint8List?> open(Uint8List sealed) async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(sealed));
    } on FormatException {
      return null;
    }
    if (json is! Map || json['v'] != _format) {
      return null;
    }
    final Object? key = json['k'];
    final Object? boot = json['b'];
    final Object? sealedAt = json['s'];
    final Object? deadline = json['d'];
    final Object? lock = json['l'];
    if (key is! String ||
        boot is! int ||
        sealedAt is! int ||
        deadline is! int ||
        (lock != null && lock is! bool)) {
      return null;
    }
    final int? since = sinceBootMillis();
    if (since == null ||
        since < sealedAt ||
        since > deadline ||
        deadline - sealedAt > kResumeSessionLongest.inMilliseconds) {
      return null;
    }
    final int bootNow = now().millisecondsSinceEpoch - since;
    if ((bootNow - boot).abs() > bootSlack.inMilliseconds) {
      return null;
    }
    if (await screenLock?.call() != lock) {
      return null;
    }
    try {
      return securityBytesFromHex(key);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> wipe() async {}
}

/// `struct timespec` on 64-bit Apple and Linux systems.
final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

/// Milliseconds since this device started, time asleep included: Windows'
/// tick count, Linux's boot time clock, the monotonic clock of iOS and
/// macOS (which keeps counting while asleep). `null` when it cannot be
/// read.
int? systemSinceBootMillis() {
  if (kIsWeb) {
    return null;
  }
  try {
    if (Platform.isWindows) {
      final int Function() ticks = DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<Uint64 Function(), int Function()>('GetTickCount64');
      return ticks();
    }
    final int clock = Platform.isIOS || Platform.isMacOS
        // CLOCK_MONOTONIC
        ? 6
        // CLOCK_BOOTTIME
        : 7;
    final int Function(int, Pointer<_Timespec>) clockGettime =
        DynamicLibrary.process().lookupFunction<
          Int32 Function(Int32, Pointer<_Timespec>),
          int Function(int, Pointer<_Timespec>)
        >('clock_gettime');
    final Pointer<_Timespec> time = calloc<_Timespec>();
    try {
      if (clockGettime(clock, time) != 0) {
        return null;
      }
      return time.ref.seconds * 1000 + time.ref.nanoseconds ~/ 1000000;
    } finally {
      calloc.free(time);
    }
  } on Object catch (error) {
    logZenWarning('Reading the time since boot failed: $error');
    return null;
  }
}

/// Whether the device has a screen lock (a passcode, Windows Hello);
/// `null` when it cannot be told.
Future<bool?> deviceScreenLockOn() async {
  try {
    return await LocalAuthentication().isDeviceSupported();
  } on Object {
    return null;
  }
}
