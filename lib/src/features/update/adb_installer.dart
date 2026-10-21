import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// A phone connected to this computer over USB.
@immutable
final class AdbDevice {
  const AdbDevice({required this.serial, required this.state, this.model});

  final String serial;

  /// `device` (ready), `unauthorized` (allow on the phone), `offline`…
  final String state;
  final String? model;

  bool get ready => state == 'device';

  String get label => model ?? serial;
}

/// Parses `adb devices -l`.
List<AdbDevice> parseAdbDevices(String output) {
  final List<AdbDevice> out = <AdbDevice>[];
  for (final String raw in const LineSplitter().convert(output)) {
    final String line = raw.trim();
    if (line.isEmpty ||
        line.startsWith('List of devices') ||
        line.startsWith('*')) {
      continue;
    }
    final List<String> parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      continue;
    }
    String? model;
    for (final String p in parts.skip(2)) {
      if (p.startsWith('model:')) {
        model = p.substring(6).replaceAll('_', ' ');
      }
    }
    out.add(AdbDevice(serial: parts[0], state: parts[1], model: model));
  }
  return out;
}

/// "Zainstaluj na telefonie" on a computer: installs an APK on a
/// phone connected by cable, with Android's own `adb` tool (Android SDK
/// platform-tools). Works even where the store and websites are blocked.
final class AdbInstaller {
  AdbInstaller({this.executable});

  /// The adb found, or `null`.
  final String? executable;

  bool get available => executable != null;

  /// Looks for adb: on PATH, in the Android SDK, next to the app.
  static Future<AdbInstaller> find({Map<String, String>? environment}) async {
    final Map<String, String> env = environment ?? Platform.environment;
    final String exe = Platform.isWindows ? 'adb.exe' : 'adb';
    final String sep = Platform.pathSeparator;
    final List<String> candidates = <String>[
      for (final String root in <String?>[
        env['ANDROID_HOME'],
        env['ANDROID_SDK_ROOT'],
        if (env['LOCALAPPDATA'] != null)
          '${env['LOCALAPPDATA']}${sep}Android${sep}Sdk',
        if (env['HOME'] != null) '${env['HOME']}${sep}Android${sep}Sdk',
        if (env['HOME'] != null)
          '${env['HOME']}${sep}Library${sep}Android${sep}sdk',
      ].whereType<String>())
        '$root${sep}platform-tools$sep$exe',
      '${File(Platform.resolvedExecutable).parent.path}${sep}platform-tools$sep$exe',
      for (final String dir in (env['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ))
        if (dir.trim().isNotEmpty) '${dir.trim()}$sep$exe',
    ];
    for (final String c in candidates) {
      if (await File(c).exists()) {
        return AdbInstaller(executable: c);
      }
    }
    return AdbInstaller();
  }

  Future<List<AdbDevice>> devices() async {
    final String? adb = executable;
    if (adb == null) {
      return const <AdbDevice>[];
    }
    final ProcessResult r = await Process.run(adb, <String>['devices', '-l']);
    if (r.exitCode != 0) {
      return const <AdbDevice>[];
    }
    return parseAdbDevices('${r.stdout}');
  }

  /// Installs (or updates) [apkPath] on [device]. Returns a message.
  Future<String> install(AdbDevice device, String apkPath) async {
    final String? adb = executable;
    if (adb == null) {
      return t('Nie znaleziono narzędzia adb.');
    }
    if (!device.ready) {
      return device.state == 'unauthorized'
          ? t(
              'Na telefonie pojawiło się pytanie o debugowanie USB — zezwól i '
              'spróbuj jeszcze raz.',
            )
          : t('Telefon nie jest gotowy ({state}).', {'state': device.state});
    }
    final ProcessResult r = await Process.run(adb, <String>[
      '-s',
      device.serial,
      'install',
      '-r',
      apkPath,
    ]);
    return describeAdbInstallResult(
      exitCode: r.exitCode,
      output: '${r.stdout}\n${r.stderr}',
      deviceLabel: device.label,
    );
  }
}

/// What to tell the person after `adb install` ended with [exitCode] and
/// [output].
///
/// A different signing key never leads to "uninstall it first": that is
/// exactly the path a fake copy needs. The person learns that one
/// of the two copies may not be the real Zen and where to check.
String describeAdbInstallResult({
  required int exitCode,
  required String output,
  required String deviceLabel,
}) {
  if (exitCode == 0 && output.contains('Success')) {
    return t('Zainstalowano Zen na {device}.', {'device': deviceLabel});
  }
  final RegExpMatch? failure = RegExp(
    r'Failure \[([^\]]+)\]',
  ).firstMatch(output);
  final String reason = failure?.group(1) ?? output.trim();
  if (reason.contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
    return kAdbSignatureMismatchMessage;
  }
  if (reason.contains('INSTALL_FAILED_VERSION_DOWNGRADE')) {
    return t('Na telefonie jest nowsza wersja Zen.');
  }
  return t('Instalacja nie udała się: {reason}', {'reason': reason});
}

/// The phone refused the file because its Zen is signed with another key.
String get kAdbSignatureMismatchMessage => t(
  'Uwaga: Zen na telefonie jest podpisany innym kluczem niż ten plik. '
  'Jedna z tych kopii może być podróbką. Nie odinstalowuj Zen, żeby to '
  'obejść. Porównaj odcisk klucza i sumę SHA-256 z README: '
  'github.com/robertostrowskijagoda/Zen.',
);
