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
  /// The release file that updates this installation, or null where Zen
  /// cannot update itself (iOS: only the prompt).
  String? get assetName;

  /// Where the download goes.
  Future<Directory> workDirectory();

  /// Installs [file] of [release].
  Future<GithubInstallOutcome> install(File file, GithubRelease release);
}

/// How this Linux installation was made.
LinuxInstall currentLinuxInstall([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  if (env.containsKey('FLATPAK_ID')) {
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
///   Files, `/opt/zen` of the .deb, Flatpak) the file is saved to Downloads
///   and its folder opened instead.
final class SystemGithubInstaller implements GithubUpdateInstaller {
  SystemGithubInstaller({Future<void> Function()? quit})
    : _quit = quit ?? _quitForUpdate;

  final Future<void> Function() _quit;

  @override
  String? get assetName => kIsWeb
      ? null
      : githubAssetName(
          releasePlatform: currentReleasePlatform(),
          abi: Abi.current(),
          linux: Platform.isLinux
              ? currentLinuxInstall()
              : LinuxInstall.tarball,
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
    if (Platform.isAndroid) {
      return _installApk(file);
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final bool swapped =
          (!Platform.isLinux ||
              currentLinuxInstall() == LinuxInstall.tarball) &&
          await _swapInPlace(file, release);
      if (swapped) {
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
  /// swaps the folders once Zen has exited. False where that cannot be
  /// done (nothing is changed then).
  Future<bool> _swapInPlace(File archive, GithubRelease release) async {
    final String sep = Platform.pathSeparator;
    final File exe = File(Platform.resolvedExecutable);
    final String exeName = exe.uri.pathSegments.last;
    final Directory appDir = Platform.isMacOS
        ? exe.parent.parent.parent
        : exe.parent;
    if (Platform.isMacOS && !appDir.path.endsWith('.app')) {
      return false;
    }
    final Directory parent = appDir.parent;
    if (!await _writable(parent) || !await _writable(appDir)) {
      return false;
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
      // Windows: the zip holds the app's files; Linux: a Zen folder;
      // macOS: Zen.app.
      final String newDir = Platform.isWindows
          ? staging.path
          : Platform.isMacOS
          ? '${staging.path}${sep}Zen.app'
          : '${staging.path}${sep}Zen';
      final String newExe = Platform.isMacOS
          ? '$newDir/Contents/MacOS/$exeName'
          : '$newDir$sep$exeName';
      if (unpacked.exitCode != 0 || !await File(newExe).exists()) {
        logZenWarning('Rozpakowanie aktualizacji: ${unpacked.stderr}');
        await staging.delete(recursive: true);
        return false;
      }
      final String oldDir = '${appDir.path}.old-${release.version}';
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
      return true;
    } on Object catch (error, stack) {
      logZenError('Aktualizacja w miejscu', error, stack);
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } on Object {
        // Left for the next attempt, which deletes it first.
      }
      return false;
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
  Future<GithubInstallOutcome> _saveForPerson(File file) async {
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
    return GithubInstallOutcome(
      t('Zapisano {file} w {folder}. Uruchom go, żeby zaktualizować Zen.', {
        'file': name,
        'folder': dir.path,
      }),
    );
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
