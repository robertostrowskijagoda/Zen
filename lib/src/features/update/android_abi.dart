import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/update/apk_signing_block.dart';

/// The Android ABIs Zen is built for, one APK each (release.yml:
/// `flutter build apk --split-per-abi`). The first one is what most
/// phones need.
const List<String> kAndroidApkAbis = <String>[
  'arm64-v8a',
  'armeabi-v7a',
  'x86_64',
];

/// The ABI of most phones: the default download.
const String kDefaultAndroidAbi = 'arm64-v8a';

/// The release file of each ABI. Every one is signed with the same key and
/// has the same version code, so any of them updates any other.
const Map<String, String> kAndroidApkAssets = <String, String>{
  'arm64-v8a': 'Zen-arm64-v8a.apk',
  'armeabi-v7a': 'Zen-armeabi-v7a.apk',
  'x86_64': 'Zen-x86_64.apk',
};

/// The release file for [abi] (an entry of [kAndroidApkAbis]); the most
/// common one for anything else.
String androidApkAssetName(String abi) =>
    kAndroidApkAssets[abi] ?? kAndroidApkAssets[kDefaultAndroidAbi]!;

/// [abi] with the kind of device it is for: `arm64-v8a (most phones)`.
String androidAbiLabel(String abi) {
  final String? kind = switch (abi) {
    'arm64-v8a' => t('większość telefonów'),
    'armeabi-v7a' => t('starsze telefony 32-bitowe'),
    'x86_64' => t('Chromebooki i emulatory'),
    _ => null,
  };
  return kind == null ? abi : '$abi ($kind)';
}

/// [abis] (of one APK) for people, e.g. `arm64-v8a (most phones)`.
String androidAbisLabel(Iterable<String> abis) =>
    abis.map(androidAbiLabel).join(', ');

/// Reads `getprop ro.product.cpu.abilist` (`arm64-v8a,armeabi-v7a,…`).
List<String> parseAbiList(String output) => <String>[
  for (final String part in output.trim().split(','))
    if (part.trim().isNotEmpty) part.trim(),
];

/// The Android ABI name of a Dart [abi] (the ABI this process runs as,
/// which is the ABI of the installed APK); null when it is not Android.
String? androidAbiOf(Abi abi) => switch (abi) {
  Abi.androidArm64 => 'arm64-v8a',
  Abi.androidArm => 'armeabi-v7a',
  Abi.androidX64 => 'x86_64',
  Abi.androidIA32 => 'x86',
  _ => null,
};

/// The platform name of the Android files of a network release
/// (the `p` of a release file): `android-arm64-v8a`, … one per ABI.
String androidReleasePlatform(String abi) => 'android-$abi';

/// Whether [platform] (a release platform name) is Android.
bool isAndroidReleasePlatform(String platform) =>
    platform == 'android' || platform.startsWith('android-');

/// The ABI of the running app on Android (that of its APK), else null.
String? get runningAndroidAbi => kIsWeb ? null : androidAbiOf(Abi.current());

/// The ABI whose APK suits a device best: the first of the device's
/// [supported] ABIs (`Build.SUPPORTED_ABIS`, best first) Zen is built
/// for; without that list, the ABI the app runs as ([running]); else the
/// one of most phones.
String preferredAndroidAbi({
  List<String> supported = const <String>[],
  String? running,
}) {
  for (final String abi in supported) {
    if (kAndroidApkAbis.contains(abi)) {
      return abi;
    }
  }
  if (running != null && kAndroidApkAbis.contains(running)) {
    return running;
  }
  return kDefaultAndroidAbi;
}

/// Whether an APK with native libraries for [apkAbis] installs on a device
/// that supports [deviceAbis]: true or false, or null when either is not
/// known. An APK without native libraries installs everywhere.
bool? apkFitsDevice({
  required Set<String>? apkAbis,
  required List<String> deviceAbis,
}) {
  if (apkAbis == null) {
    return null;
  }
  if (apkAbis.isEmpty) {
    return true;
  }
  if (deviceAbis.isEmpty) {
    return null;
  }
  return deviceAbis.any(apkAbis.contains);
}

/// The ABIs of the native libraries in [apk] (`lib/<abi>/…`), read from
/// the zip's central directory; null when it is not a readable zip.
Future<Set<String>?> readApkAbis(File apk) async {
  final List<String>? names = await readZipEntryNames(apk);
  if (names == null) {
    return null;
  }
  return apkAbisOf(names);
}

/// The ABIs named by the zip entries [names] of an APK.
Set<String> apkAbisOf(Iterable<String> names) => <String>{
  for (final String name in names)
    if (RegExp(r'^lib/([A-Za-z0-9_-]+)/[^/]+\.so$').firstMatch(name)
        case final RegExpMatch m)
      m.group(1)!,
};

const MethodChannel _appUpdateChannel = MethodChannel('zen/app_update');

List<String>? _deviceAbis;

/// The ABIs this device supports, best first (`Build.SUPPORTED_ABIS`), as
/// last read by [loadDeviceAndroidAbis]; empty until then and off Android.
List<String> get deviceAndroidAbis => _deviceAbis ?? const <String>[];

/// Reads the ABIs this Android device supports (once); empty elsewhere or
/// when the system does not say.
Future<List<String>> loadDeviceAndroidAbis() async {
  final List<String>? known = _deviceAbis;
  if (known != null) {
    return known;
  }
  if (kIsWeb || !Platform.isAndroid) {
    return const <String>[];
  }
  try {
    final List<Object?>? list = await _appUpdateChannel
        .invokeListMethod<Object?>('supportedAbis');
    final List<String> abis = List<String>.unmodifiable(<String>[
      for (final Object? a in list ?? const <Object?>[])
        if (a is String && a.isNotEmpty) a,
    ]);
    _deviceAbis = abis;
    return abis;
  } on Object {
    return const <String>[];
  }
}

/// Sets what [deviceAndroidAbis] answers (tests).
@visibleForTesting
void debugSetDeviceAndroidAbis(List<String>? abis) => _deviceAbis = abis;
