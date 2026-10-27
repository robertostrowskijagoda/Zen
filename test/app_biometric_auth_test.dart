import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zen/src/features/security/app_biometric_auth.dart';

/// The biometric unlock asks the system with the options of the platform and
/// answers `false`, never an exception, when the person backs out or the
/// system fails.
void main() {
  test('the prompt is biometric only and survives backgrounding, except on '
      'Windows', () async {
    final _Auth auth = _Auth();
    final PlatformAppBiometricAuthenticator authenticator =
        PlatformAppBiometricAuthenticator(auth);

    expect(await authenticator.authenticate(), isTrue);

    expect(auth.biometricOnly, !Platform.isWindows);
    expect(auth.persistAcrossBackgrounding, !Platform.isWindows);
    expect(auth.localizedReason, isNotEmpty);
  });

  test('backing out of the prompt, a lockout or a missing plugin all say no '
      'without throwing', () async {
    for (final Object error in <Object>[
      const LocalAuthException(code: LocalAuthExceptionCode.userCanceled),
      const LocalAuthException(code: LocalAuthExceptionCode.systemCanceled),
      const LocalAuthException(code: LocalAuthExceptionCode.temporaryLockout),
      const LocalAuthException(
        code: LocalAuthExceptionCode.noBiometricsEnrolled,
      ),
      PlatformException(code: 'broken'),
      MissingPluginException(),
    ]) {
      final PlatformAppBiometricAuthenticator authenticator =
          PlatformAppBiometricAuthenticator(_Auth()..failure = error);
      expect(await authenticator.authenticate(), isFalse, reason: '$error');
    }
  });

  test('a person who does not pass the prompt is not let in', () async {
    final PlatformAppBiometricAuthenticator authenticator =
        PlatformAppBiometricAuthenticator(_Auth()..passes = false);

    expect(await authenticator.authenticate(), isFalse);
  });

  test('availability is the biometrics or a device that can check the person, '
      'and false when the system cannot tell', () async {
    expect(
      await PlatformAppBiometricAuthenticator(
        _Auth()..biometrics = true,
      ).isAvailable(),
      isTrue,
    );
    expect(
      await PlatformAppBiometricAuthenticator(
        _Auth()..deviceSupported = true,
      ).isAvailable(),
      isTrue,
    );
    expect(
      await PlatformAppBiometricAuthenticator(_Auth()).isAvailable(),
      false,
    );
    for (final Object error in <Object>[
      const LocalAuthException(code: LocalAuthExceptionCode.deviceError),
      PlatformException(code: 'broken'),
      MissingPluginException(),
    ]) {
      expect(
        await PlatformAppBiometricAuthenticator(
          _Auth()..failure = error,
        ).isAvailable(),
        isFalse,
        reason: '$error',
      );
    }
  });
}

final class _Auth implements LocalAuthentication {
  bool biometrics = false;
  bool deviceSupported = false;
  bool passes = true;
  Object? failure;

  String? localizedReason;
  bool? biometricOnly;
  bool? persistAcrossBackgrounding;

  @override
  Future<bool> get canCheckBiometrics async {
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return biometrics;
  }

  @override
  Future<bool> isDeviceSupported() async {
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return deviceSupported;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const <Object>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    this.localizedReason = localizedReason;
    this.biometricOnly = biometricOnly;
    this.persistAcrossBackgrounding = persistAcrossBackgrounding;
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return passes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
