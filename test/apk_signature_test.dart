import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/update/adb_installer.dart';
import 'package:zen/src/features/update/apk_signature.dart';

const int _v2 = 0x7109871a;
const int _v3 = 0xf05368c0;

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _u64(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();

Uint8List _prefixed(List<int> bytes) =>
    Uint8List.fromList(<int>[..._u32(bytes.length), ...bytes]);

/// One scheme's value: a sequence of signers, each with signed data that
/// holds [certificate] (and, for v3, the SDK range).
Uint8List _schemeValue(List<int> certificate, {required bool v3}) {
  final Uint8List signedData = Uint8List.fromList(<int>[
    ..._prefixed(_prefixed(<int>[1, 2, 3])), // digests
    ..._prefixed(_prefixed(certificate)), // certificates
    if (v3) ...<int>[..._u32(24), ..._u32(0x7fffffff)],
    ..._prefixed(const <int>[]), // attributes
  ]);
  final Uint8List signer = Uint8List.fromList(<int>[
    ..._prefixed(signedData),
    if (v3) ...<int>[..._u32(24), ..._u32(0x7fffffff)],
    ..._prefixed(_prefixed(<int>[9, 9])), // signatures
    ..._prefixed(<int>[7, 7, 7]), // public key
  ]);
  return _prefixed(_prefixed(signer));
}

/// A minimal APK: entries, the APK Signing Block with [schemes], the
/// central directory and its end record.
Uint8List _apk(Map<int, List<int>> schemes) {
  final BytesBuilder pairs = BytesBuilder();
  schemes.forEach((int id, List<int> certificate) {
    final Uint8List value = _schemeValue(certificate, v3: id == _v3);
    pairs
      ..add(_u64(value.length + 4))
      ..add(_u32(id))
      ..add(value);
  });
  final Uint8List pairBytes = pairs.takeBytes();
  final int blockSize = pairBytes.length + 8 + 16;
  final Uint8List block = Uint8List.fromList(<int>[
    ..._u64(blockSize),
    ...pairBytes,
    ..._u64(blockSize),
    ...ascii.encode('APK Sig Block 42'),
  ]);
  final Uint8List entries = Uint8List.fromList(List<int>.filled(40, 0x11));
  final Uint8List centralDirectory = Uint8List.fromList(
    List<int>.filled(46, 0x22),
  );
  final ByteData end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint32(12, centralDirectory.length, Endian.little)
    ..setUint32(16, entries.length + block.length, Endian.little)
    ..setUint16(20, 0, Endian.little);
  return Uint8List.fromList(<int>[
    ...entries,
    ...block,
    ...centralDirectory,
    ...end.buffer.asUint8List(),
  ]);
}

void main() {
  final List<int> official = utf8.encode('certyfikat oficjalny');
  final List<int> other = utf8.encode('certyfikat podrobki');
  final String officialSha = sha256.convert(official).toString();
  final String otherSha = sha256.convert(other).toString();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zen-apk-signature-');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<File> write(Uint8List bytes) async {
    final File file = File('${dir.path}${Platform.pathSeparator}zen.apk');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('the signer certificate is read from each scheme', () async {
    final File apk = await write(
      _apk(<int, List<int>>{_v2: official, _v3: official}),
    );
    final List<List<String>>? schemes = await readApkSignerCertificates(apk);
    expect(schemes, <List<String>>[
      <String>[officialSha],
      <String>[officialSha],
    ]);
    expect(
      apkSignatureVerdict(
        schemes: schemes,
        reference: <String>[formatCertificateFingerprint(officialSha)],
      ),
      ApkSignatureVerdict.matches,
    );
  });

  test('another key, even in one scheme only, is a different signer', () async {
    final File apk = await write(
      _apk(<int, List<int>>{_v2: official, _v3: other}),
    );
    final List<List<String>>? schemes = await readApkSignerCertificates(apk);
    expect(
      apkSignatureVerdict(schemes: schemes, reference: <String>[officialSha]),
      ApkSignatureVerdict.differs,
      reason: 'a phone verifies v3 and would install the other key',
    );
    expect(
      apkSignatureVerdict(
        schemes: <List<String>>[
          <String>[otherSha],
        ],
        reference: <String>[officialSha],
      ),
      ApkSignatureVerdict.differs,
    );
  });

  test('without a reference the verdict is unknown; without a signature '
      'unreadable', () async {
    expect(
      apkSignatureVerdict(
        schemes: <List<String>>[
          <String>[officialSha],
        ],
        reference: const <String>[],
      ),
      ApkSignatureVerdict.unknown,
    );
    final File notApk = await write(Uint8List.fromList(utf8.encode('to nie')));
    expect(await readApkSignerCertificates(notApk), isNull);
    expect(
      apkSignatureVerdict(
        schemes: await readApkSignerCertificates(notApk),
        reference: <String>[officialSha],
      ),
      ApkSignatureVerdict.unreadable,
    );
    // A zip with no signing block (signed the old v1 way, or not at all).
    final File unsigned = await write(_apk(const <int, List<int>>{}));
    expect(await readApkSignerCertificates(unsigned), isNull);
  });

  test(
    'a computer compares with the official fingerprint (none yet)',
    () async {
      final File apk = await write(_apk(<int, List<int>>{_v2: official}));
      final ApkSignatureCheck check = await checkApkSignature(apk);
      expect(check.certificates, <String>[officialSha]);
      expect(
        check.verdict,
        kOfficialApkCertificatesSha256.isEmpty
            ? ApkSignatureVerdict.unknown
            : ApkSignatureVerdict.differs,
      );
    },
  );

  test('fingerprints read the way keytool prints them', () {
    expect(formatCertificateFingerprint('0a1B2c'), '0A:1B:2C');
    expect(normalizeCertificateFingerprint('0A:1B:2C'), '0a1b2c');
  });

  test('a phone with Zen signed by another key: never "uninstall it"', () {
    final String message = describeAdbInstallResult(
      exitCode: 1,
      output:
          'Performing Streamed Install\n'
          'adb: failed to install zen.apk: Failure '
          '[INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.roj.zen '
          'signatures do not match newer version; ignoring!]',
      deviceLabel: 'Pixel',
    );
    expect(message, kAdbSignatureMismatchMessage);
    expect(message, contains('podróbką'));
    expect(message, contains('github.com/robertostrowskijagoda/Zen'));
    expect(message, isNot(contains('najpierw go odinstaluj')));
    expect(
      describeAdbInstallResult(
        exitCode: 0,
        output: 'Success',
        deviceLabel: 'Pixel',
      ),
      'Zainstalowano Zen na Pixel.',
    );
  });

  test('an APK for another kind of phone is not sent to it', () {
    expect(
      adbAbiMismatchMessage(
        apkAbis: <String>{'arm64-v8a'},
        deviceAbis: const <String>['armeabi-v7a', 'armeabi'],
        deviceLabel: 'Moto',
      ),
      allOf(contains('Moto'), contains('Zen-armeabi-v7a.apk')),
    );
    // Fits, or not known: adb decides.
    expect(
      adbAbiMismatchMessage(
        apkAbis: <String>{'armeabi-v7a'},
        deviceAbis: const <String>['arm64-v8a', 'armeabi-v7a'],
        deviceLabel: 'Pixel',
      ),
      isNull,
    );
    expect(
      adbAbiMismatchMessage(
        apkAbis: null,
        deviceAbis: const <String>['x86_64'],
        deviceLabel: 'Emulator',
      ),
      isNull,
    );
    expect(
      adbAbiMismatchMessage(
        apkAbis: <String>{'x86_64'},
        deviceAbis: const <String>[],
        deviceLabel: 'Pixel',
      ),
      isNull,
    );
    expect(
      describeAdbInstallResult(
        exitCode: 1,
        output: 'Failure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract]',
        deviceLabel: 'Pixel',
      ),
      contains('Pixel'),
    );
  });
}
