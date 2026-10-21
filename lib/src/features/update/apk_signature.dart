import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/features/update/apk_signing_block.dart';

export 'package:zen/src/features/update/apk_signing_block.dart';

/// SHA-256 fingerprints of the certificates that sign official Zen
/// releases (docs/RELEASES.md, section 2), as `keytool` prints them or as plain
/// hex. Empty until the first signed release: a computer then cannot tell
/// an official APK from another one, and says so. Filled at release time
/// with `dart run tool/zen_release.dart fingerprint app-release.apk --write`.
const List<String> kOfficialApkCertificatesSha256 = <String>[];

/// What the signature of an APK says.
enum ApkSignatureVerdict {
  /// Signed with the reference certificate (this app's own on Android, the
  /// official one on a computer).
  matches,

  /// Signed with another certificate: possibly not the real Zen.
  differs,

  /// Nothing to compare with (a computer before the first signed release).
  unknown,

  /// No signature this app can read (not an APK, damaged, or signed only
  /// the old v1 way).
  unreadable,
}

@immutable
final class ApkSignatureCheck {
  const ApkSignatureCheck(this.verdict, {this.certificates = const <String>[]});

  final ApkSignatureVerdict verdict;

  /// SHA-256 of the certificates the file is signed with (lower-case hex).
  final List<String> certificates;
}

/// Compares the signing certificate of [apk] with this app's own (Android,
/// where the system reads the file's signature itself) or with
/// [kOfficialApkCertificatesSha256] (a computer).
///
/// On a computer the certificate is only read from the APK Signing Block,
/// not verified: a copy that claims the official certificate without its
/// key is refused by the phone itself when installed.
Future<ApkSignatureCheck> checkApkSignature(File apk) async {
  List<String> reference = kOfficialApkCertificatesSha256;
  List<List<String>>? schemes;
  bool nativeAnswered = false;
  if (!kIsWeb && Platform.isAndroid) {
    final ({List<String> own, List<String>? apk})? fromSystem =
        await _nativeCertificates(apk.path);
    if (fromSystem != null) {
      nativeAnswered = true;
      if (fromSystem.own.isNotEmpty) {
        reference = fromSystem.own;
      }
      final List<String>? signed = fromSystem.apk;
      // Null: the system could not verify the file's signature.
      schemes = signed == null || signed.isEmpty
          ? null
          : <List<String>>[signed];
    }
  }
  if (!nativeAnswered) {
    schemes = await readApkSignerCertificates(apk);
  }
  return ApkSignatureCheck(
    apkSignatureVerdict(schemes: schemes, reference: reference),
    certificates: <String>{
      for (final List<String> scheme in schemes ?? const <List<String>>[])
        ...scheme,
    }.toList(growable: false),
  );
}

/// The verdict for an APK whose signature schemes hold [schemes] (the
/// certificates of each scheme's signers), compared with [reference].
/// Every scheme must match: a phone verifies only the newest one it knows,
/// so an older block claiming the right certificate proves nothing.
ApkSignatureVerdict apkSignatureVerdict({
  required List<List<String>>? schemes,
  required Iterable<String> reference,
}) {
  if (schemes == null ||
      schemes.isEmpty ||
      schemes.any((List<String> scheme) => scheme.isEmpty)) {
    return ApkSignatureVerdict.unreadable;
  }
  final Set<String> known = <String>{
    for (final String value in reference)
      if (normalizeCertificateFingerprint(value).isNotEmpty)
        normalizeCertificateFingerprint(value),
  };
  if (known.isEmpty) {
    return ApkSignatureVerdict.unknown;
  }
  for (final List<String> scheme in schemes) {
    for (final String certificate in scheme) {
      if (!known.contains(normalizeCertificateFingerprint(certificate))) {
        return ApkSignatureVerdict.differs;
      }
    }
  }
  return ApkSignatureVerdict.matches;
}

const MethodChannel _appUpdateChannel = MethodChannel('zen/app_update');

/// This app's certificates and, when the system could verify it, those of
/// the APK at [path] (Android). Null without the native side.
Future<({List<String> own, List<String>? apk})?> _nativeCertificates(
  String path,
) async {
  try {
    final Map<Object?, Object?>? reply = await _appUpdateChannel
        .invokeMethod<Map<Object?, Object?>>(
          'signingCertificates',
          <String, Object>{'path': path},
        );
    if (reply == null) {
      return null;
    }
    List<String>? strings(Object? value) =>
        value is List ? value.whereType<String>().toList() : null;
    return (
      own: strings(reply['own']) ?? const <String>[],
      apk: strings(reply['apk']),
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// SHA-256 of the certificates this very app is signed with (Android; lower
/// case hex), read by the system. Null without the native side.
Future<List<String>?> ownSigningCertificates() async {
  try {
    final Map<Object?, Object?>? reply = await _appUpdateChannel
        .invokeMethod<Map<Object?, Object?>>(
          'signingCertificates',
          <String, Object>{},
        );
    final Object? own = reply?['own'];
    return own is List ? own.whereType<String>().toList() : null;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
