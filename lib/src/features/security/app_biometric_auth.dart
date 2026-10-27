import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
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
    } on LocalAuthException catch (error, stackTrace) {
      logZenError('Biometric availability check failed', error, stackTrace);
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _localAuthentication.authenticate(
        localizedReason: t('Odblokuj aplikacje Zen'),
        biometricOnly: !Platform.isWindows,
        persistAcrossBackgrounding: !Platform.isWindows,
      );
    } on MissingPluginException catch (error, stackTrace) {
      logZenError('Biometric authentication is unavailable', error, stackTrace);
      return false;
    } on LocalAuthException catch (error) {
      // Backing out of the prompt is an answer, not a failure.
      if (error.code != LocalAuthExceptionCode.userCanceled &&
          error.code != LocalAuthExceptionCode.systemCanceled) {
        logZenWarning('Biometric authentication failed: ${error.code.name}');
      }
      return false;
    } catch (error, stackTrace) {
      logZenError('Biometric authentication failed', error, stackTrace);
      return false;
    }
  }
}
