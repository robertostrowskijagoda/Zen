import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/update/apk_signature.dart';
import 'package:zen/src/features/update/share_app_server.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_service.dart';

/// What this installed copy of Zen says about itself (§14.3 point 2).
enum OwnCopyState {
  /// Signed with a pinned official certificate: "Oficjalna kopia".
  official,

  /// Signed with another certificate: possibly a modified copy.
  differs,

  /// Nothing to compare with (no official fingerprint pinned yet) or the
  /// system gave no certificate: neither good nor bad, only unchecked.
  unknown,

  /// Not an APK Zen signs itself (a computer, a store build): no check.
  notApplicable,
}

@immutable
final class OwnCopyCheck {
  const OwnCopyCheck(
    this.state, {
    this.certificates = const <String>[],
    this.apkSha256,
  });

  final OwnCopyState state;

  /// SHA-256 of the certificates this app is signed with (lower-case hex).
  final List<String> certificates;

  /// SHA-256 of the installed APK file (lower-case hex), when it could be
  /// read: the build's fingerprint, see [buildShortCode].
  final String? apkSha256;
}

/// The state for an app signed with [own], compared with the [official]
/// fingerprints (any format [normalizeCertificateFingerprint] reads).
OwnCopyState ownCopyState({
  required List<String> own,
  required Iterable<String> official,
}) => switch (apkSignatureVerdict(
  schemes: <List<String>>[own],
  reference: official,
)) {
  ApkSignatureVerdict.matches => OwnCopyState.official,
  ApkSignatureVerdict.differs => OwnCopyState.differs,
  ApkSignatureVerdict.unknown ||
  ApkSignatureVerdict.unreadable => OwnCopyState.unknown,
};

/// The first 12 characters of a build's SHA-256 as `A1B2-C3D4-E5F6`: short
/// enough to read out over the phone, so two people can check that their
/// copies are the same file (§14.3 point 3).
String buildShortCode(String sha256Hex) {
  final String hex = sha256Hex.toUpperCase().padRight(12, '0');
  return <String>[
    for (int i = 0; i < 12; i += 4) hex.substring(i, i + 4),
  ].join('-');
}

/// Reads this installation's signature (Android, not the store build).
Future<OwnCopyCheck> checkOwnCopy() async {
  if (kIsWeb || !Platform.isAndroid || isStoreBuild) {
    return const OwnCopyCheck(OwnCopyState.notApplicable);
  }
  final List<String> own = await ownSigningCertificates() ?? const <String>[];
  String? sha;
  try {
    final String? path = await ownApkPath();
    if (path != null) {
      sha = await fileSha256Hex(File(path));
    }
  } on Object catch (error) {
    logZenWarning('Kod kopii: $error');
  }
  return OwnCopyCheck(
    ownCopyState(own: own, official: kOfficialApkCertificatesSha256),
    certificates: own,
    apkSha256: sha,
  );
}

/// The check of this copy; swapped out in tests.
final FutureProvider<OwnCopyCheck> ownCopyCheckProvider =
    FutureProvider<OwnCopyCheck>((Ref ref) => checkOwnCopy());
