import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zen/src/core/logging/zen_log.dart';

final Provider<AppBiometricAuthenticator> appBiometricAuthenticatorProvider =
    Provider<AppBiometricAuthenticator>((Ref ref) {
      return PlatformAppBiometricAuthenticator();
    });

abstract class AppBiometricAuthenticator {
  Future<bool> isAvailable();

  Future<bool> authenticate();
}

final class PlatformAppBiometricAuthenticator
    implements AppBiometricAuthenticator {
  PlatformAppBiometricAuthenticator([LocalAuthentication? localAuthentication])
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> isAvailable() async {
    try {
      final bool canCheckBiometrics =
          await _localAuthentication.canCheckBiometrics;
      return canCheckBiometrics ||
          await _localAuthentication.isDeviceSupported();
    } on MissingPluginException catch (error, stackTrace) {
      logZenError(
        'Biometric availability check is unavailable',
        error,
        stackTrace,
      );
      return false;
    } on PlatformException catch (error, stackTrace) {
      logZenError('Biometric availability check failed', error, stackTrace);
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _localAuthentication.authenticate(
        localizedReason: 'Odblokuj aplikacje Zen',
        options: Platform.isWindows
            ? const AuthenticationOptions(stickyAuth: false)
            : const AuthenticationOptions(
                stickyAuth: true,
                biometricOnly: true,
              ),
      );
    } on MissingPluginException catch (error, stackTrace) {
      logZenError('Biometric authentication is unavailable', error, stackTrace);
      return false;
    } catch (error, stackTrace) {
      logZenError('Biometric authentication failed', error, stackTrace);
      return false;
    }
  }
}
