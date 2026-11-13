import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/features/update/apk_signing_block.dart';

export 'package:zen/src/features/update/apk_signing_block.dart';

/// SHA-256 fingerprints of the certificates that sign official Zen
/// releases (docs/RELEASES.md, section 2), as `keytool` prints them or as plain
/// hex. Empty until the first signed release: a computer then cannot tell
/// an official APK from another one, and says so. Filled at release time
/// with `dart run tool/zen_release.dart fingerprint Zen-arm64-v8a.apk --write`
/// (the same certificate signs the APK of every ABI).
///
/// A list, so that the APK key can be rotated: the release that first signs
/// with a new key (APK Signature Scheme v3, the old key vouching for the new
/// one) adds the new fingerprint here and keeps the old one, which still
/// signs the v2 block that older phones read. An installed copy counts as
/// official when the certificate it is signed with now is listed
/// ([ownCopyState]); a phone updates over a rotation by the lineage the
/// system verified ([apkUpdateSignatureVerdict]), not by this list.
const List<String> kOfficialApkCertificatesSha256 = <String>[
  '5cf84ba525ac804c842fb5b92f35c549f6c07a84fbe0c28049139191c1eef514',
];

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

/// Who signs an APK (or this installed app), as Android verified it.
@immutable
final class ApkSigners {
  const ApkSigners(this.signers, {this.lineage = const <String>[]});

  /// SHA-256 of the certificates that sign it now (lower-case hex). One,
  /// or several for an APK with several signers, which cannot rotate.
  final List<String> signers;

  /// A rotated key's proven history, oldest first and ending with the one
  /// signer: each certificate in it signed the next one (APK Signature
  /// Scheme v3 proof of rotation). Empty without a rotation. Only the
  /// system fills it, after it verified every link; certificates an APK
  /// merely lists are never taken for a lineage.
  final List<String> lineage;

  /// Every certificate named, for showing: the lineage, else the signers.
  List<String> get all => lineage.isNotEmpty ? lineage : signers;

  /// Reads `{signers, lineage}` from the native side; null when it holds no
  /// signer.
  static ApkSigners? fromChannel(Object? value) {
    if (value is! Map) {
      return null;
    }
    List<String> strings(Object? list) => list is List
        ? list.whereType<String>().toList(growable: false)
        : const <String>[];
    final List<String> signers = strings(value['signers']);
    return signers.isEmpty
        ? null
        : ApkSigners(signers, lineage: strings(value['lineage']));
  }
}

/// Compares the signing certificate of [apk] with this app's own (Android,
/// where the system reads and verifies the file's signature itself) or with
/// [kOfficialApkCertificatesSha256] (a computer, or a phone whose own
/// certificate the system did not give).
///
/// On a computer the certificate is only read from the APK Signing Block,
/// not verified: a copy that claims the official certificate without its
/// key is refused by the phone itself when installed. A computer reads no
/// proof of rotation either (it could not verify one): an APK signed with a
/// rotated key is official there once the new key is pinned.
Future<ApkSignatureCheck> checkApkSignature(File apk) async {
  if (!kIsWeb && Platform.isAndroid) {
    final ({ApkSigners? own, ApkSigners? apk})? fromSystem =
        await _nativeSigners(apk.path);
    if (fromSystem != null) {
      // Null: the system could not verify the file's signature.
      final ApkSigners? signed = fromSystem.apk;
      final ApkSigners? own = fromSystem.own;
      return ApkSignatureCheck(
        own == null
            ? apkSignatureVerdict(
                schemes: signed == null ? null : <List<String>>[signed.signers],
                reference: kOfficialApkCertificatesSha256,
              )
            : apkUpdateSignatureVerdict(apk: signed, installed: own),
        certificates: signed?.all ?? const <String>[],
      );
    }
  }
  final List<List<String>>? schemes = await readApkSignerCertificates(apk);
  return ApkSignatureCheck(
    apkSignatureVerdict(
      schemes: schemes,
      reference: kOfficialApkCertificatesSha256,
    ),
    certificates: <String>{
      for (final List<String> scheme in schemes ?? const <List<String>>[])
        ...scheme,
    }.toList(growable: false),
  );
}

/// Whether Android would let [apk] update the [installed] app, by the
/// signatures alone, the way its package manager decides: the same signer,
/// or a rotated key whose verified lineage holds the installed copy's
/// signer as an ancestor of its own. Never the other way round: an APK
/// signed with a key the installed copy rotated away from is a downgrade
/// that Android refuses unless the lineage grants that old key "rollback",
/// which Zen's releases never do (and which the flags the system gives
/// here would not show). Several signers cannot rotate: the same set, or
/// nothing.
///
/// The system's installer checks all of this again when the update is
/// installed (and also the capability flags of the lineage, which this does
/// not see): this check only spares the person a download that would be
/// refused, and refuses a file signed by somebody else before the system
/// dialog shows.
ApkSignatureVerdict apkUpdateSignatureVerdict({
  required ApkSigners? apk,
  required ApkSigners installed,
}) {
  final List<String> signers = _normalized(apk?.signers);
  if (signers.isEmpty) {
    return ApkSignatureVerdict.unreadable;
  }
  final List<String> own = _normalized(installed.signers);
  if (own.isEmpty) {
    return ApkSignatureVerdict.unknown;
  }
  if (signers.length > 1 || own.length > 1) {
    return signers.toSet().containsAll(own) && own.toSet().containsAll(signers)
        ? ApkSignatureVerdict.matches
        : ApkSignatureVerdict.differs;
  }
  final String signer = signers.single;
  if (signer == own.single) {
    return ApkSignatureVerdict.matches;
  }
  final List<String> lineage = _normalized(apk?.lineage);
  final bool wellFormed =
      lineage.length >= 2 &&
      lineage.last == signer &&
      lineage.toSet().length == lineage.length;
  return wellFormed &&
          lineage.sublist(0, lineage.length - 1).contains(own.single)
      ? ApkSignatureVerdict.matches
      : ApkSignatureVerdict.differs;
}

List<String> _normalized(List<String>? values) => <String>[
  for (final String value in values ?? const <String>[])
    if (normalizeCertificateFingerprint(value).isNotEmpty)
      normalizeCertificateFingerprint(value),
];

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

/// This app's signers and, when the system could verify it, those of the
/// APK at [path] (Android). Null without the native side.
Future<({ApkSigners? own, ApkSigners? apk})?> _nativeSigners(
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
    return (
      own: ApkSigners.fromChannel(reply['ownSigning']),
      apk: ApkSigners.fromChannel(reply['apkSigning']),
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Who signs this very app (Android), as the system verified it. Null
/// without the native side or when the system gave no certificate.
Future<ApkSigners?> ownApkSigners() async {
  try {
    final Map<Object?, Object?>? reply = await _appUpdateChannel
        .invokeMethod<Map<Object?, Object?>>(
          'signingCertificates',
          <String, Object>{},
        );
    return ApkSigners.fromChannel(reply?['ownSigning']);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
