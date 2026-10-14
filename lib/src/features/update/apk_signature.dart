import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// SHA-256 fingerprints of the certificates that sign official Zen
/// releases (WYDANIA.md §2 point 4), as `keytool` prints them or as plain
/// hex. Empty until the first signed release: a computer then cannot tell
/// an official APK from another one, and says so.
const List<String> kOfficialApkCertificatesSha256 = <String>[];

const int _v2BlockId = 0x7109871a;
const int _v3BlockId = 0xf05368c0;
const int _v31BlockId = 0x1b93ad61;
const String _signingBlockMagic = 'APK Sig Block 42';
const int _eocdBytes = 22;
const int _maxZipCommentBytes = 0xFFFF;
const int _maxSigningBlockBytes = 16 * 1024 * 1024;

/// What the signature of an APK says (§14.3 point 3).
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

/// [value] as lower-case hex without separators (`AB:CD…` from keytool).
String normalizeCertificateFingerprint(String value) =>
    value.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');

/// [hex] the way `keytool` and `apksigner` show it: `AB:CD:…`.
String formatCertificateFingerprint(String hex) {
  final String clean = normalizeCertificateFingerprint(hex).toUpperCase();
  return <String>[
    for (int i = 0; i + 1 < clean.length; i += 2) clean.substring(i, i + 2),
  ].join(':');
}

/// The certificates of the signers of each APK signature scheme in [apk]
/// (v3.1, v3, v2 — newest first), each as the SHA-256 of the certificate,
/// or null when the file has no APK Signing Block.
Future<List<List<String>>?> readApkSignerCertificates(File apk) async {
  RandomAccessFile? handle;
  try {
    handle = await apk.open();
    final int size = await handle.length();
    if (size < _eocdBytes) {
      return null;
    }
    final int tailLength = min(size, _eocdBytes + _maxZipCommentBytes);
    await handle.setPosition(size - tailLength);
    final Uint8List tail = await handle.read(tailLength);
    final int? eocd = _findEndOfCentralDirectory(tail);
    if (eocd == null) {
      return null;
    }
    final int centralDirectory = ByteData.sublistView(
      tail,
      eocd,
    ).getUint32(16, Endian.little);
    if (centralDirectory < 32 || centralDirectory > size) {
      return null;
    }
    await handle.setPosition(centralDirectory - 24);
    final Uint8List footer = await handle.read(24);
    if (footer.length != 24 ||
        String.fromCharCodes(footer, 8) != _signingBlockMagic) {
      return null;
    }
    final int blockSize = ByteData.sublistView(
      footer,
    ).getUint64(0, Endian.little);
    if (blockSize < 24 ||
        blockSize > _maxSigningBlockBytes ||
        blockSize + 8 > centralDirectory) {
      return null;
    }
    await handle.setPosition(centralDirectory - blockSize - 8);
    final Uint8List block = await handle.read(blockSize + 8);
    if (block.length != blockSize + 8 ||
        ByteData.sublistView(block).getUint64(0, Endian.little) != blockSize) {
      return null;
    }
    final List<List<String>> schemes = parseApkSigningBlockPairs(
      Uint8List.sublistView(block, 8, block.length - 24),
    );
    return schemes.isEmpty ? null : schemes;
  } on Object {
    return null;
  } finally {
    await handle?.close();
  }
}

/// The signer certificates of each signature scheme in the ID-value pairs
/// of an APK Signing Block, newest scheme first.
@visibleForTesting
List<List<String>> parseApkSigningBlockPairs(Uint8List pairs) {
  final Map<int, List<String>> found = <int, List<String>>{};
  final ByteData data = ByteData.sublistView(pairs);
  int offset = 0;
  while (offset + 12 <= pairs.length) {
    final int length = data.getUint64(offset, Endian.little);
    if (length < 4 || length > pairs.length - offset - 8) {
      throw const FormatException('Damaged APK Signing Block.');
    }
    final int id = data.getUint32(offset + 8, Endian.little);
    if (id == _v2BlockId || id == _v3BlockId || id == _v31BlockId) {
      found[id] = _signerCertificates(
        Uint8List.sublistView(pairs, offset + 12, offset + 8 + length),
      );
    }
    offset += 8 + length;
  }
  return <List<String>>[
    for (final int id in const <int>[_v31BlockId, _v3BlockId, _v2BlockId])
      ?found[id],
  ];
}

/// The first certificate of every signer of one scheme (v2 and v3 put the
/// signed data, holding the certificates, first in each signer).
List<String> _signerCertificates(Uint8List value) {
  final _LengthPrefixedReader signers = _LengthPrefixedReader(value).nested();
  final List<String> out = <String>[];
  while (signers.hasMore) {
    final _LengthPrefixedReader signedData = signers.nested().nested();
    signedData.next(); // digests
    final _LengthPrefixedReader certificates = signedData.nested();
    if (certificates.hasMore) {
      out.add(sha256.convert(certificates.next()).toString());
    }
  }
  return out;
}

int? _findEndOfCentralDirectory(Uint8List tail) {
  for (int index = tail.length - _eocdBytes; index >= 0; index--) {
    if (tail[index] != 0x50 ||
        tail[index + 1] != 0x4B ||
        tail[index + 2] != 0x05 ||
        tail[index + 3] != 0x06) {
      continue;
    }
    final int commentLength = ByteData.sublistView(
      tail,
      index,
    ).getUint16(20, Endian.little);
    if (index + _eocdBytes + commentLength == tail.length) {
      return index;
    }
  }
  return null;
}

/// Reads `uint32 little-endian length | bytes` records.
final class _LengthPrefixedReader {
  _LengthPrefixedReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _offset = 0;

  bool get hasMore => _offset < _bytes.length;

  Uint8List next() {
    if (_offset + 4 > _bytes.length) {
      throw const FormatException('Damaged APK signature.');
    }
    final int length = _data.getUint32(_offset, Endian.little);
    final int start = _offset + 4;
    if (length > _bytes.length - start) {
      throw const FormatException('Damaged APK signature.');
    }
    _offset = start + length;
    return Uint8List.sublistView(_bytes, start, start + length);
  }

  _LengthPrefixedReader nested() => _LengthPrefixedReader(next());
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
