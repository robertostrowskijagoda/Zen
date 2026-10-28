import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/single_instance_guard.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/mark_of_the_web.dart';
import 'package:zen/src/core/utils/windows_system_paths.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/update/android_abi.dart';
import 'package:zen/src/features/update/apk_signature.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/update_service.dart';

/// What came of handing a downloaded, checked release file over.
@immutable
final class GithubInstallOutcome {
  const GithubInstallOutcome(this.message, {this.ok = true});

  /// For the person.
  final String message;

  /// False when nothing was installed (the file was refused).
  final bool ok;
}

/// Installs a release file that [GithubUpdateService] downloaded and
/// checked against the release's `SHA256SUMS`; a fake in tests.
abstract interface class GithubUpdateInstaller {
  /// The kind of installation (what "Aktualizuj" does).
  UpdateTarget get target;

  /// The release file that updates this installation, or null where Zen
  /// downloads nothing (iOS, Flatpak).
  String? get assetName;

  /// Where the download goes.
  Future<Directory> workDirectory();

  /// Installs [file] of [release].
  Future<GithubInstallOutcome> install(File file, GithubRelease release);
}

/// What a Flatpak user does to update (the banner shows it with a button
/// that opens the release page).
String get flatpakUpdateHint => t(
  'Zen z Flatpaka aktualizujesz poza aplikacją: pobierz '
  'Zen-Linux-x64.flatpak ze strony wydania i wpisz: '
  'flatpak install --user ./Zen-Linux-x64.flatpak',
);

/// The label of the iPhone and iPad update button, which opens the IPA of
/// [version] in Safari.
String iosDownloadLabel(String version) =>
    t('Pobierz Zen {version}', {'version': version});

/// Said on iPhone and iPad above [iosUpdateSteps] (Zen downloads nothing
/// there: Safari saves the IPA, Scarlet installs it).
String get iosUpdateHint => t(
  'Na iPhonie i iPadzie Zen nie zainstaluje się sam. Zaktualizujesz go '
  'przez Scarlet:',
);

/// The update of an iPhone or iPad to [version], step by step, in the words
/// of the iPhone install page and the install guide.
List<String> iosUpdateSteps(String version) => <String>[
  t(
    'Stuknij „Pobierz Zen {version}”: Safari zapisze plik Zen-unsigned.ipa '
    'w aplikacji Pliki.',
    {'version': version},
  ),
  t(
    'Otwórz Scarlet, przytrzymaj strzałkę pobierania i wybierz „Sideload IPA”.',
  ),
  t('Wskaż Zen-unsigned.ipa i stuknij „Install”.'),
  t('Nie usuwaj wcześniej obecnego Zen: nowa wersja zastąpi starą.'),
];

/// Said on iPhone and iPad below [iosUpdateSteps].
String get iosOtherSignersHint =>
    t('Instalujesz przez SideStore lub AltStore? Zaktualizuj Zen tam.');

/// What "Aktualizuj" will do on [target] with the release file [file],
/// said before it is tapped; null where Zen downloads nothing.
String? githubUpdatePlan(UpdateTarget target, String file) => switch (target) {
  UpdateTarget.android => t(
    'Zen pobierze {file}, sprawdzi go i otworzy instalator Androida: '
    'potwierdź tam instalację. Za pierwszym razem Android poprosi o '
    'zgodę na instalowanie aplikacji z Zen.',
    {'file': file},
  ),
  UpdateTarget.windows || UpdateTarget.macos || UpdateTarget.linuxTarball => t(
    'Zen pobierze {file}, sprawdzi go, zamknie się i uruchomi w nowej '
    'wersji. Jeśli nie może sam podmienić swoich plików, zapisze '
    'pobrany plik w Pobranych i powie, co dalej.',
    {'file': file},
  ),
  UpdateTarget.linuxDeb => t(
    'Zen pobierze {file}, sprawdzi go i zapisze w Pobranych. Pakiet '
    'zainstalujesz instalatorem pakietów albo poleceniem apt (z hasłem '
    'administratora).',
    {'file': file},
  ),
  UpdateTarget.flatpak || UpdateTarget.ios || UpdateTarget.other => null,
};

/// What the person does with [file], saved in [folder] because Zen could
/// not swap its own files ([path]: the whole path of the saved file).
String savedUpdateMessage(
  UpdateTarget target, {
  required String file,
  required String folder,
  required String path,
}) => switch (target) {
  UpdateTarget.windows => t(
    'Zapisano {file} w {folder}. Zamknij Zen, rozpakuj cały plik i zastąp '
    'nim obecny folder Zen.',
    {'file': file, 'folder': folder},
  ),
  UpdateTarget.macos => t(
    'Zapisano {file} w {folder}. Zamknij Zen, otwórz plik i przeciągnij Zen '
    'do Aplikacji, zastępując obecny.',
    {'file': file, 'folder': folder},
  ),
  UpdateTarget.linuxTarball => t(
    'Zapisano {file} w {folder}. Zamknij Zen, rozpakuj archiwum i zastąp '
    'nim obecny folder Zen.',
    {'file': file, 'folder': folder},
  ),
  UpdateTarget.linuxDeb => t(
    'Zapisano {file} w {folder}. Otwórz go instalatorem pakietów albo '
    'wpisz: sudo apt install {path}',
    {'file': file, 'folder': folder, 'path': shellQuote(path)},
  ),
  _ => t('Zapisano {file} w {folder}. Uruchom go, żeby zaktualizować Zen.', {
    'file': file,
    'folder': folder,
  }),
};

/// Whether [environment] and the file system are those of a Flatpak
/// sandbox: `FLATPAK_ID` is set there, and `/.flatpak-info` exists even
/// when the environment was cleared.
bool isFlatpakSandbox(
  Map<String, String> environment,
  bool Function(String path) fileExists,
) => environment.containsKey('FLATPAK_ID') || fileExists('/.flatpak-info');

/// Whether this Zen runs inside a Flatpak sandbox.
bool runningInFlatpak() =>
    !kIsWeb &&
    Platform.isLinux &&
    isFlatpakSandbox(
      Platform.environment,
      (String path) => File(path).existsSync(),
    );

/// The kind of this installation.
UpdateTarget currentUpdateTarget() => kIsWeb
    ? UpdateTarget.other
    : updateTargetFor(
        operatingSystem: Platform.operatingSystem,
        linux: Platform.isLinux ? currentLinuxInstall() : LinuxInstall.tarball,
      );

/// How this Linux installation was made.
LinuxInstall currentLinuxInstall() {
  if (runningInFlatpak()) {
    return LinuxInstall.flatpak;
  }
  return Platform.resolvedExecutable.startsWith('/opt/zen/')
      ? LinuxInstall.deb
      : LinuxInstall.tarball;
}

/// The real installer of this platform:
///
/// * Android: the APK must be signed with the same certificate as the
///   installed app, then the system installer asks the person;
/// * Windows (zip), Linux (tar.gz), macOS (zip): unpacked next to the app's
///   folder, then a small helper swaps the folders after Zen exits and
///   starts the new version. Where that folder cannot be written (Program
///   Files, `/opt/zen` of the .deb), or is not provably Zen's own (Windows
///   and Linux: [isOwnAppFolder], so never Downloads or the Desktop with
///   Zen's files unpacked loose into it), the file is saved to Downloads
///   and its folder opened instead, with what to do ([savedUpdateMessage]).
/// * Linux `.deb`: saved to Downloads for the package installer (`/opt/zen`
///   belongs to the package manager).
/// * Flatpak: nothing ([assetName] is null). The sandbox can neither write
///   to Downloads nor run `flatpak install`; the banner opens the release
///   page instead ([flatpakUpdateHint]).
/// * iOS: nothing ([assetName] is null); the banner opens the release's
///   IPA in Safari, for Scarlet to install ([GithubUpdateRoute.sideload]).
final class SystemGithubInstaller implements GithubUpdateInstaller {
  SystemGithubInstaller({Future<void> Function()? quit})
    : _quit = quit ?? _quitForUpdate {
    // Android: the device's ABIs pick the APK (read long before the first
    // check of GitHub answers; until then the app's own ABI does).
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(loadDeviceAndroidAbis());
    }
  }

  final Future<void> Function() _quit;

  @override
  final UpdateTarget target = currentUpdateTarget();

  @override
  String? get assetName =>
      target == UpdateTarget.flatpak ||
          target == UpdateTarget.ios ||
          target == UpdateTarget.other
      ? null
      : githubAssetName(
          releasePlatform: currentReleasePlatform(),
          abi: Abi.current(),
          linux: Platform.isLinux
              ? currentLinuxInstall()
              : LinuxInstall.tarball,
          androidAbis: deviceAndroidAbis,
        );

  @override
  Future<Directory> workDirectory() async {
    final Directory base = await getTemporaryDirectory();
    if (!kIsWeb && Platform.isLinux) {
      // Linux: that is /tmp, shared by every user of the computer. A folder
      // with a fixed name there may belong to someone else, who could swap
      // the checked file before it is unpacked; a new private one instead.
      return base.createTemp('zen_github_update_');
    }
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}zen_github_update',
    );
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<GithubInstallOutcome> install(File file, GithubRelease release) async {
    if (target == UpdateTarget.android) {
      return _installApk(file);
    }
    if (target == UpdateTarget.windows ||
        target == UpdateTarget.macos ||
        target == UpdateTarget.linuxTarball ||
        target == UpdateTarget.linuxDeb) {
      // The .deb's /opt/zen belongs to the package manager: never swapped.
      final _Swap swap = target == UpdateTarget.linuxDeb
          ? _Swap.failed
          : await _swapInPlace(file, release);
      if (swap == _Swap.notOwnFolder) {
        return _saveForPerson(file, notOwnFolder: true);
      }
      if (swap == _Swap.swapped) {
        // A moment to read the message; the helper waits for Zen to exit.
        Timer(const Duration(seconds: 2), () => unawaited(_quit()));
        return GithubInstallOutcome(
          t(
            'Wersja {version} rozpakowana. Zen zamknie się i uruchomi '
            'ponownie w nowej wersji.',
            {'version': release.version},
          ),
        );
      }
      return _saveForPerson(file);
    }
    await _deleteQuietly(file);
    return GithubInstallOutcome(
      t('Na tym urządzeniu zaktualizuj Zen tak, jak go instalowano.'),
      ok: false,
    );
  }

  Future<GithubInstallOutcome> _installApk(File apk) async {
    final ApkSignatureCheck check = await checkApkSignature(apk);
    if (check.verdict != ApkSignatureVerdict.matches) {
      await _deleteQuietly(apk);
      return GithubInstallOutcome(
        t(
          'Pobrany plik nie jest podpisany tym samym kluczem co Twoja '
          'aplikacja — nie instaluję go.',
        ),
        ok: false,
      );
    }
    return GithubInstallOutcome(await installApk(apk.path));
  }

  /// Unpacks [archive] next to the app's folder and starts the helper that
  /// swaps the folders once Zen has exited. Anything but [_Swap.swapped]
  /// changes nothing.
  ///
  /// The helper moves the whole folder aside and deletes it, so on Windows
  /// and Linux it runs only on a folder that is provably Zen's own
  /// ([isOwnAppFolder]): never on Downloads or the Desktop into which
  /// someone unpacked the files loose.
  Future<_Swap> _swapInPlace(File archive, GithubRelease release) async {
    final String sep = Platform.pathSeparator;
    final File exe = File(Platform.resolvedExecutable);
    final String exeName = exe.uri.pathSegments.last;
    final Directory appDir = Platform.isMacOS
        ? exe.parent.parent.parent
        : exe.parent;
    final String oldDir = '${appDir.path}.old-${release.version}';
    if (Platform.isMacOS) {
      if (!appDir.path.endsWith('.app')) {
        return _Swap.failed;
      }
    } else if (!await isOwnAppFolder(appDir, exeName: exeName)) {
      logZenWarning('Aktualizacja w miejscu: folder nie jest folderem Zen');
      return _Swap.notOwnFolder;
    } else if (await Directory(oldDir).exists() &&
        !await isOwnAppFolder(Directory(oldDir), exeName: exeName)) {
      // The helper would delete it first.
      return _Swap.failed;
    }
    final Directory parent = appDir.parent;
    if (!await _writable(parent) || !await _writable(appDir)) {
      return _Swap.failed;
    }
    final Directory staging = Directory(
      '${parent.path}$sep.zen-update-${release.version}',
    );
    try {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await staging.create();
      final ProcessResult unpacked = await _unpack(archive, staging);
      // Windows and Linux: a Zen folder; macOS: Zen.app.
      final String newDir = Platform.isMacOS
          ? '${staging.path}${sep}Zen.app'
          : '${staging.path}${sep}Zen';
      final String newExe = Platform.isMacOS
          ? '$newDir/Contents/MacOS/$exeName'
          : '$newDir$sep$exeName';
      if (unpacked.exitCode != 0 ||
          !await File(newExe).exists() ||
          (!Platform.isMacOS &&
              !await isOwnAppFolder(Directory(newDir), exeName: exeName))) {
        logZenWarning('Rozpakowanie aktualizacji: ${unpacked.stderr}');
        await staging.delete(recursive: true);
        return _Swap.failed;
      }
      final Directory temp = Directory.systemTemp;
      if (Platform.isWindows) {
        final File script = File(
          '${temp.path}${sep}zen-update-${release.version}.ps1',
        );
        // With a BOM: Windows PowerShell reads a script without one in the
        // local code page, which would break paths with non-ASCII letters.
        await script.writeAsBytes(<int>[
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode(
            windowsSwapScript(
              pid: pid,
              appDir: appDir.path,
              newDir: newDir,
              oldDir: oldDir,
              stagingDir: staging.path,
              exeName: exeName,
            ),
          ),
        ], flush: true);
        await Process.start(
          '${windowsSystemRoot()}\\System32\\WindowsPowerShell\\v1.0\\'
          'powershell.exe',
          <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            script.path,
          ],
          mode: ProcessStartMode.detached,
        );
      } else {
        // In a new private folder: a script with a known name in a shared
        // /tmp could be someone else's file, written into and then run.
        final Directory scriptDir = await temp.createTemp('zen-update-');
        final File script = File(
          '${scriptDir.path}/zen-update-${release.version}.sh',
        );
        await script.writeAsString(
          posixSwapScript(
            pid: pid,
            appDir: appDir.path,
            newDir: newDir,
            oldDir: oldDir,
            stagingDir: staging.path,
            relaunch: Platform.isMacOS
                ? '/usr/bin/open ${shellQuote(appDir.path)}'
                : 'nohup ${shellQuote('${appDir.path}/$exeName')} '
                      '>/dev/null 2>&1 &',
          ),
          flush: true,
        );
        await Process.start('/bin/sh', <String>[
          script.path,
        ], mode: ProcessStartMode.detached);
      }
      await _deleteQuietly(archive);
      return _Swap.swapped;
    } on Object catch (error, stack) {
      logZenError('Aktualizacja w miejscu', error, stack);
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } on Object {
        // Left for the next attempt, which deletes it first.
      }
      return _Swap.failed;
    }
  }

  Future<ProcessResult> _unpack(File archive, Directory into) {
    if (Platform.isWindows) {
      // bsdtar, part of Windows 10 and 11, reads zip files.
      return Process.run('${windowsSystemRoot()}\\System32\\tar.exe', <String>[
        '-xf',
        archive.path,
        '-C',
        into.path,
      ]);
    }
    if (Platform.isMacOS) {
      return Process.run('/usr/bin/ditto', <String>[
        '-x',
        '-k',
        archive.path,
        into.path,
      ]);
    }
    final String tar = File('/usr/bin/tar').existsSync()
        ? '/usr/bin/tar'
        : '/bin/tar';
    return Process.run(tar, <String>['-xzf', archive.path, '-C', into.path]);
  }

  /// Saves [file] to Downloads and shows it, for the person to install.
  /// [notOwnFolder]: Zen was not updated in place because its files do not
  /// sit in a folder of their own.
  Future<GithubInstallOutcome> _saveForPerson(
    File file, {
    bool notOwnFolder = false,
  }) async {
    final String sep = Platform.pathSeparator;
    final Directory? downloads = await getDownloadsDirectory();
    final Directory dir = downloads ?? await ZenInstance.supportDirectory();
    final String name = file.uri.pathSegments.last;
    final File out = File('${dir.path}$sep$name');
    await file.copy(out.path);
    await _deleteQuietly(file);
    await markFileFromInternet(out.path);
    // Outside Zen's folders: the panic password finds it there.
    await rememberExportedFile(out.path);
    try {
      if (Platform.isWindows) {
        unawaited(
          Process.run(windowsExplorerPath(), <String>['/select,', out.path]),
        );
      } else if (Platform.isMacOS) {
        unawaited(Process.run('/usr/bin/open', <String>['-R', out.path]));
      } else {
        unawaited(Process.run('xdg-open', <String>[dir.path]));
      }
    } on Object catch (error) {
      logZenWarning('Pokazanie pobranej aktualizacji: $error');
    }
    if (notOwnFolder) {
      return GithubInstallOutcome(
        t(
          'Zen nie ma własnego folderu, więc nie podmienię go sam. Zapisano '
          '{file} w {folder}: rozpakuj całe archiwum i uruchamiaj Zen z '
          'powstałego folderu Zen.',
          {'file': name, 'folder': dir.path},
        ),
      );
    }
    return GithubInstallOutcome(
      savedUpdateMessage(target, file: name, folder: dir.path, path: out.path),
    );
  }
}

/// What came of trying to update the app's folder in place.
enum _Swap { swapped, notOwnFolder, failed }

/// The file in the folder of every Windows and Linux release (written by
/// .github/workflows/release.yml): the line [kAppFolderMarkerHeader], then
/// the name of every file and folder the release put next to it.
const String kAppFolderMarker = 'zen-app.marker';

/// The first line of [kAppFolderMarker].
const String kAppFolderMarkerHeader = 'zen-app 1';

/// Whether a folder whose files and folders are [entries] (names only,
/// without the path) and whose [kAppFolderMarker] reads [marker] is a Zen
/// release folder and nothing else: the marker is Zen's, lists [exeName],
/// and lists every entry. Downloads or the Desktop with Zen's files
/// unpacked loose into it hold other files, so they never qualify.
/// [ignoreCase]: Windows, whose file names ignore case.
bool isOwnAppFolderListing({
  required String? marker,
  required Iterable<String> entries,
  required String exeName,
  bool ignoreCase = false,
}) {
  if (marker == null) {
    return false;
  }
  String key(String name) => ignoreCase ? name.toLowerCase() : name;
  final List<String> lines = const LineSplitter()
      .convert(marker)
      .map((String l) => l.trim())
      .toList();
  if (lines.isEmpty || lines.first != kAppFolderMarkerHeader) {
    return false;
  }
  final Set<String> listed = <String>{
    for (final String l in lines.skip(1))
      if (l.isNotEmpty) key(l),
  };
  if (!listed.contains(key(exeName))) {
    return false;
  }
  bool sawExe = false;
  for (final String entry in entries) {
    if (key(entry) == key(kAppFolderMarker)) {
      continue;
    }
    if (!listed.contains(key(entry))) {
      return false;
    }
    sawExe = sawExe || key(entry) == key(exeName);
  }
  return sawExe;
}

/// [isOwnAppFolderListing] for [dir] on disk (never a drive's or the file
/// system's root).
Future<bool> isOwnAppFolder(
  Directory dir, {
  required String exeName,
  bool? ignoreCase,
}) async {
  try {
    final Directory absolute = dir.absolute;
    if (absolute.parent.path == absolute.path) {
      return false;
    }
    final File marker = File(
      '${absolute.path}${Platform.pathSeparator}$kAppFolderMarker',
    );
    if (!await marker.exists() || await marker.length() > 64 * 1024) {
      return false;
    }
    final String prefix = absolute.path.endsWith(Platform.pathSeparator)
        ? absolute.path
        : '${absolute.path}${Platform.pathSeparator}';
    final List<String> entries = await absolute
        .list(followLinks: false)
        .map(
          (FileSystemEntity e) => e.path.startsWith(prefix)
              ? e.path.substring(prefix.length)
              : e.path,
        )
        .toList();
    return isOwnAppFolderListing(
      marker: await marker.readAsString(),
      entries: entries,
      exeName: exeName,
      ignoreCase: ignoreCase ?? Platform.isWindows,
    );
  } on Object catch (error) {
    logZenWarning('Sprawdzenie folderu Zen: $error');
    return false;
  }
}

Future<bool> _writable(Directory dir) async {
  final File probe = File(
    '${dir.path}${Platform.pathSeparator}.zen-write-probe-$pid',
  );
  try {
    await probe.writeAsString('', flush: true);
    await probe.delete();
    return true;
  } on Object {
    return false;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on Object {
    // A temporary file; the next update replaces it.
  }
}

/// Ends Zen so the helper can swap its folder.
Future<void> _quitForUpdate() async {
  try {
    await ZenSingleInstance.release();
    await windowManager.destroy();
  } on Object catch (error) {
    logZenWarning('Zamykanie przed aktualizacją: $error');
  }
  exit(0);
}

/// [value] as one word for `/bin/sh`.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// [value] as a literal PowerShell string. PowerShell also ends a
/// single-quoted string at the typographic quotes U+2018 to U+201B, so each
/// of them is doubled as well (a folder named `O’Brien`).
String powershellQuote(String value) {
  final String escaped = value.replaceAllMapped(
    _powershellQuotes,
    (Match m) => '${m[0]}${m[0]}',
  );
  return "'$escaped'";
}

final RegExp _powershellQuotes = RegExp("['\u2018\u2019\u201A\u201B]");

/// The Windows helper: waits for Zen (process [pid]) to exit, moves
/// [appDir] aside to [oldDir], moves [newDir] in its place (back again if
/// that fails), starts [exeName] and cleans up. Paths go only through
/// `-LiteralPath` and .NET calls, which take `[`, `*` and the like
/// literally (`Move-Item -Destination` and `Start-Process -FilePath` do
/// not).
String windowsSwapScript({
  required int pid,
  required String appDir,
  required String newDir,
  required String oldDir,
  required String stagingDir,
  required String exeName,
}) =>
    '''
\$ErrorActionPreference = 'Stop'
\$app = ${powershellQuote(appDir)}
\$new = ${powershellQuote(newDir)}
\$old = ${powershellQuote(oldDir)}
\$staging = ${powershellQuote(stagingDir)}
try { Wait-Process -Id $pid -Timeout 120 -ErrorAction SilentlyContinue } catch {}
\$moved = \$false
for (\$i = 0; \$i -lt 30 -and -not \$moved; \$i++) {
  try {
    if (Test-Path -LiteralPath \$old) { Remove-Item -LiteralPath \$old -Recurse -Force }
    [System.IO.Directory]::Move(\$app, \$old)
    \$moved = \$true
  } catch { Start-Sleep -Seconds 1 }
}
\$swapped = \$false
if (\$moved) {
  try { [System.IO.Directory]::Move(\$new, \$app); \$swapped = \$true }
  catch { [System.IO.Directory]::Move(\$old, \$app) }
}
\$start = New-Object System.Diagnostics.ProcessStartInfo
\$start.FileName = [System.IO.Path]::Combine(\$app, ${powershellQuote(exeName)})
\$start.WorkingDirectory = \$app
\$start.UseShellExecute = \$true
[void][System.Diagnostics.Process]::Start(\$start)
if (\$swapped) { Remove-Item -LiteralPath \$old -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath \$staging) { Remove-Item -LiteralPath \$staging -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath \$MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
''';

/// The Linux and macOS helper: as [windowsSwapScript], then runs
/// [relaunch] (a shell command line).
String posixSwapScript({
  required int pid,
  required String appDir,
  required String newDir,
  required String oldDir,
  required String stagingDir,
  required String relaunch,
}) =>
    '''
#!/bin/sh
app=${shellQuote(appDir)}
new=${shellQuote(newDir)}
old=${shellQuote(oldDir)}
staging=${shellQuote(stagingDir)}
i=0
while kill -0 $pid 2>/dev/null && [ "\$i" -lt 120 ]; do
  sleep 1
  i=\$((i + 1))
done
rm -rf "\$old"
if mv "\$app" "\$old"; then
  if mv "\$new" "\$app"; then
    rm -rf "\$old"
  else
    mv "\$old" "\$app"
  fi
fi
rm -rf "\$staging"
$relaunch
rm -f "\$0"
rmdir "\$(dirname "\$0")" 2>/dev/null
''';
