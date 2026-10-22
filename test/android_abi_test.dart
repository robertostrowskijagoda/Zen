import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/update/android_abi.dart';
import 'package:zen/src/features/update/apk_signing_block.dart';

/// A minimal zip (stored entries, no compression) holding [names].
Uint8List _zip(List<String> names) {
  final BytesBuilder out = BytesBuilder();
  final BytesBuilder directory = BytesBuilder();
  for (final String name in names) {
    final List<int> n = utf8.encode(name);
    final int offset = out.length;
    final ByteData local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(26, n.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(n);
    final ByteData central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(28, n.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    directory
      ..add(central.buffer.asUint8List())
      ..add(n);
  }
  final int start = out.length;
  final Uint8List dir = directory.takeBytes();
  out.add(dir);
  final ByteData end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, names.length, Endian.little)
    ..setUint16(10, names.length, Endian.little)
    ..setUint32(12, dir.length, Endian.little)
    ..setUint32(16, start, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

void main() {
  test('one release file per ABI, the common one first', () {
    expect(kAndroidApkAbis.first, kDefaultAndroidAbi);
    expect(kAndroidApkAssets.keys, kAndroidApkAbis);
    for (final String abi in kAndroidApkAbis) {
      expect(androidApkAssetName(abi), 'Zen-$abi.apk');
    }
    expect(androidApkAssetName('mips'), 'Zen-arm64-v8a.apk');
  });

  test('the best ABI: the device first, then the running app', () {
    expect(preferredAndroidAbi(), 'arm64-v8a');
    expect(
      preferredAndroidAbi(supported: <String>['armeabi-v7a', 'armeabi']),
      'armeabi-v7a',
    );
    expect(
      preferredAndroidAbi(
        supported: <String>['x86', 'armeabi-v7a'],
        running: 'arm64-v8a',
      ),
      'armeabi-v7a',
    );
    expect(preferredAndroidAbi(running: 'x86_64'), 'x86_64');
    expect(preferredAndroidAbi(running: 'x86'), 'arm64-v8a');
  });

  test('network releases name one Android file per ABI', () {
    expect(androidReleasePlatform('armeabi-v7a'), 'android-armeabi-v7a');
    for (final String abi in kAndroidApkAbis) {
      // ReleaseFile.fromJson takes platform names of up to 20 characters.
      expect(androidReleasePlatform(abi).length, lessThanOrEqualTo(20));
      expect(isAndroidReleasePlatform(androidReleasePlatform(abi)), isTrue);
    }
    expect(isAndroidReleasePlatform('android'), isTrue);
    expect(isAndroidReleasePlatform('windows'), isFalse);
    expect(isAndroidReleasePlatform('androidx'), isFalse);
  });

  test('whether an APK fits a device', () {
    const List<String> phone64 = <String>['arm64-v8a', 'armeabi-v7a'];
    const List<String> only64 = <String>['arm64-v8a'];
    const List<String> phone32 = <String>['armeabi-v7a', 'armeabi'];
    final Set<String> arm64 = <String>{'arm64-v8a'};
    final Set<String> arm32 = <String>{'armeabi-v7a'};
    expect(apkFitsDevice(apkAbis: arm64, deviceAbis: phone64), isTrue);
    expect(apkFitsDevice(apkAbis: arm32, deviceAbis: phone64), isTrue);
    expect(apkFitsDevice(apkAbis: arm32, deviceAbis: only64), isFalse);
    expect(apkFitsDevice(apkAbis: arm64, deviceAbis: phone32), isFalse);
    expect(apkFitsDevice(apkAbis: <String>{}, deviceAbis: phone32), isTrue);
    expect(apkFitsDevice(apkAbis: null, deviceAbis: phone32), isNull);
    expect(apkFitsDevice(apkAbis: arm64, deviceAbis: const <String>[]), isNull);
  });

  test('the ABIs of an APK come from its lib/ folders', () async {
    expect(
      apkAbisOf(<String>[
        'AndroidManifest.xml',
        'lib/arm64-v8a/libapp.so',
        'lib/arm64-v8a/libflutter.so',
        'lib/arm64-v8a/notes.txt',
        'assets/lib/x86/libfake.so',
      ]),
      <String>{'arm64-v8a'},
    );
    final Directory dir = Directory.systemTemp.createTempSync('zen_abi_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File apk = File('${dir.path}/Zen-armeabi-v7a.apk')
      ..writeAsBytesSync(
        _zip(<String>[
          'AndroidManifest.xml',
          'classes.dex',
          'lib/armeabi-v7a/libapp.so',
          'lib/armeabi-v7a/libyggdrasil_bridge.so',
        ]),
      );
    expect(await readZipEntryNames(apk), hasLength(4));
    expect(await readApkAbis(apk), <String>{'armeabi-v7a'});
    final File junk = File('${dir.path}/junk.apk')
      ..writeAsStringSync('not a zip');
    expect(await readApkAbis(junk), isNull);
    expect(await readApkAbis(File('${dir.path}/missing.apk')), isNull);
  });

  test('ABIs for people and from getprop', () {
    expect(androidAbiLabel('arm64-v8a'), 'arm64-v8a (większość telefonów)');
    expect(androidAbiLabel('riscv64'), 'riscv64');
    expect(
      androidAbisLabel(<String>['x86_64']),
      'x86_64 (Chromebooki i emulatory)',
    );
    expect(parseAbiList('arm64-v8a,armeabi-v7a,armeabi\n'), <String>[
      'arm64-v8a',
      'armeabi-v7a',
      'armeabi',
    ]);
    expect(parseAbiList('\n'), isEmpty);
  });

  test('the device ABIs can be set for tests and default to none', () {
    debugSetDeviceAndroidAbis(null);
    expect(deviceAndroidAbis, isEmpty);
    debugSetDeviceAndroidAbis(<String>['x86_64']);
    expect(deviceAndroidAbis, <String>['x86_64']);
    debugSetDeviceAndroidAbis(null);
  });
}
