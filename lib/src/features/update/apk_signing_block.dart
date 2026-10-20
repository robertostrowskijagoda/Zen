// Reading the signer certificates of an APK (APK Signature Scheme v2, v3,
// v3.1) in plain Dart, without Flutter: used by the app (apk_signature.dart)
// and by tool/zen_release.dart (`fingerprint`), so both read a file the
// same way.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int _v2BlockId = 0x7109871a;
const int _v3BlockId = 0xf05368c0;
const int _v31BlockId = 0x1b93ad61;
const String _signingBlockMagic = 'APK Sig Block 42';
const int _eocdBytes = 22;
const int _maxZipCommentBytes = 0xFFFF;
const int _maxSigningBlockBytes = 16 * 1024 * 1024;

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
