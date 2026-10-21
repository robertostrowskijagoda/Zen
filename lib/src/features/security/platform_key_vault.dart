import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_biometric_auth.dart';

/// Keeps a secret (the app's master key, for biometric unlock) wrapped by a
/// key that lives in the device's security hardware:
///
/// * Android: an RSA key pair in the Android Keystore (StrongBox when the
///   phone has it). Wrapping needs only the public key; unwrapping needs
///   the private key, which the Keystore releases only after a strong
///   biometric check in the system prompt, and which dies when a new
///   fingerprint or face is enrolled.
/// * Windows: an RSA key in the TPM (Microsoft Platform Crypto Provider).
///   Before unwrapping, the app asks Windows Hello who is there. Without a
///   TPM there is no biometric unlock (the old DPAPI fallback is gone: any
///   program of this Windows user could open it).
/// * macOS: a P-256 key in the Secure Enclave that works only after Touch
///   ID (macos/Runner/SecurityBridge.swift). Macs without Touch ID, and
///   Linux, have no biometric unlock.
///
/// The key never leaves the hardware, so a copy of the app's files is
/// useless elsewhere. On Android and macOS the hardware itself refuses to
/// unwrap without the person; on Windows the TPM key has no such policy, so a
/// program already running as this Windows user could unwrap the sealed
/// key while biometric unlock is on — which is why it is off there until
/// the person turns it on ([enforcesUserPresence]).
abstract interface class PlatformKeyVault {
  /// Whether this device can do it (hardware present, biometrics enrolled).
  Future<bool> isAvailable();

  /// Whether the hardware itself asks for the person before it unwraps
  /// (Android Keystore: a strong biometric for every use). `false` when
  /// only the app asks first (Windows Hello before the TPM): biometric
  /// unlock is then off until the person explicitly turns it on.
  bool get enforcesUserPresence;

  /// What protects the secret, for the settings ("TPM", "Android Keystore").
  Future<String> describe();

  /// Wraps [secret]; no prompt. `null` when unavailable.
  Future<Uint8List?> seal(Uint8List secret);

  /// Unwraps [sealed] after asking the user (biometrics / Windows Hello).
  /// `null` when refused, cancelled or invalidated.
  Future<Uint8List?> open(Uint8List sealed, {required String reason});

  /// Destroys the hardware key (panic, reset): sealed secrets become
  /// useless.
  Future<void> wipe();
}

/// The vault for this platform.
PlatformKeyVault platformKeyVault({AppBiometricAuthenticator? authenticator}) {
  if (kIsWeb) {
    return const NoKeyVault();
  }
  if (Platform.isAndroid || Platform.isMacOS) {
    return ChannelKeyVault();
  }
  if (Platform.isWindows) {
    final AppBiometricAuthenticator hello =
        authenticator ?? PlatformAppBiometricAuthenticator();
    return ChannelKeyVault(
      // The TPM does not ask by itself: Windows Hello asks first, and
      // without Windows Hello (UserConsentVerifier) there is no biometric
      // unlock.
      confirm: (String reason) => hello.authenticate(),
      alsoRequires: hello.isAvailable,
      enforcesUserPresence: false,
    );
  }
  return const NoKeyVault();
}

/// No hardware vault: biometric unlock is off, the password is the way in.
final class NoKeyVault implements PlatformKeyVault {
  const NoKeyVault();

  @override
  Future<bool> isAvailable() async => false;

  @override
  bool get enforcesUserPresence => false;

  @override
  Future<String> describe() async => t('brak');

  @override
  Future<Uint8List?> seal(Uint8List secret) async => null;

  @override
  Future<Uint8List?> open(Uint8List sealed, {required String reason}) async =>
      null;

  @override
  Future<void> wipe() async {}
}

/// Talks to the native vault (`zen/keyvault`: available, describe, seal,
/// open, wipe) in MainActivity / the Windows and macOS runners.
final class ChannelKeyVault implements PlatformKeyVault {
  ChannelKeyVault({
    MethodChannel? channel,
    Future<bool> Function(String reason)? confirm,
    Future<bool> Function()? alsoRequires,
    this.enforcesUserPresence = true,
  }) : _channel = channel ?? const MethodChannel('zen/keyvault'),
       _confirm = confirm,
       _alsoRequires = alsoRequires;

  final MethodChannel _channel;
  final Future<bool> Function(String reason)? _confirm;
  final Future<bool> Function()? _alsoRequires;

  @override
  final bool enforcesUserPresence;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      logZenWarning('Sejf klucza ($method): ${error.code} ${error.message}');
      return null;
    }
  }

  @override
  Future<bool> isAvailable() async =>
      (await _call<bool>('available') ?? false) &&
      (await _alsoRequires?.call() ?? true);

  @override
  Future<String> describe() async =>
      await _call<String>('describe') ?? t('brak');

  @override
  Future<Uint8List?> seal(Uint8List secret) async {
    // Nothing is sealed where the person could not open it again (no
    // Windows Hello, no enrolled biometrics).
    if (!await isAvailable()) {
      return null;
    }
    return _call<Uint8List>('seal', <String, Object>{'data': secret});
  }

  @override
  Future<Uint8List?> open(Uint8List sealed, {required String reason}) async {
    final Future<bool> Function(String reason)? confirm = _confirm;
    if (confirm != null && !await confirm(reason)) {
      return null;
    }
    return _call<Uint8List>('open', <String, Object>{
      'data': sealed,
      'reason': reason,
    });
  }

  @override
  Future<void> wipe() async {
    await _call<bool>('wipe');
  }
}

/// For tests: "hardware" that is just memory, and a switch for the prompt.
final class MemoryKeyVault implements PlatformKeyVault {
  MemoryKeyVault({this.available = true, this.enforcesUserPresence = true});

  bool available;

  @override
  final bool enforcesUserPresence;

  /// What the next prompt answers.
  bool approve = true;
  int prompts = 0;

  /// How many times the hardware key was destroyed.
  int wipes = 0;
  Uint8List _pad = Uint8List.fromList(
    List<int>.generate(64, (int i) => (i * 37 + 11) & 0xFF),
  );

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String> describe() async => 'pamięć (test)';

  Uint8List _xor(Uint8List data) => Uint8List.fromList(<int>[
    for (int i = 0; i < data.length; i++) data[i] ^ _pad[i % _pad.length],
  ]);

  @override
  Future<Uint8List?> seal(Uint8List secret) async =>
      available ? _xor(secret) : null;

  @override
  Future<Uint8List?> open(Uint8List sealed, {required String reason}) async {
    prompts++;
    if (!available || !approve) {
      return null;
    }
    return _xor(sealed);
  }

  @override
  Future<void> wipe() async {
    wipes++;
    _pad = Uint8List.fromList(
      List<int>.generate(64, (int i) => (i * 91 + 7 + wipes) & 0xFF),
    );
  }
}
