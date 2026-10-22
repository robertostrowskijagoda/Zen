// Prepares and checks a Zen release the same way every time, so the app
// can update itself from it. Plain Dart, no Flutter:
//
//   dart run tool/release.dart check
//       Do the app and .github/workflows/release.yml agree on the file
//       names (and the version in pubspec.yaml and app_version.dart)?
//   dart run tool/release.dart prepare 1.12.0 [--build 12] [--skip-checks]
//       [--allow-dirty] [--no-tag] [--allow-unpinned-keys]
//       Clean tree, the app pins its release keys (kReleaseMaintainers,
//       kOfficialApkCertificatesSha256; --allow-unpinned-keys only for a
//       test release), `flutter analyze`, `flutter test` and `go test`
//       (unless --skip-checks), the check above, then the version everywhere
//       (pubspec.yaml, app_version.dart, the Linux AppStream metadata),
//       CHANGELOG "Unreleased" → "1.12.0 — <date>", a commit and the
//       annotated tag v1.12.0. Prints the push command; never pushes.
//   dart run tool/release.dart verify <folder> --version 1.12.0
//       [--require-signature] [--github-json release.json]
//       A downloaded release (all its files in one folder, or GitHub's JSON
//       of it) checked as the app checks it: names, SHA256SUMS, the format
//       and the signatures of SHA256SUMS.sig (signatures need Go, as
//       tool/zen_release.dart verify).
//
// The steps around it: docs/RELEASES.md, section 3.
import 'dart:convert';
import 'dart:io';

import 'release_contract.dart';
import 'zen_release.dart' as signing;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/release.dart check | prepare <x.y.z> | '
      'verify <folder> --version <x.y.z>',
    );
    exitCode = 64;
    return;
  }
  try {
    switch (args.first) {
      case 'check':
        exitCode = _report('check', _check()) ? 0 : 1;
      case 'prepare':
        exitCode = await _prepare(args.skip(1).toList()) ? 0 : 1;
      case 'verify':
        exitCode = await _verify(args.skip(1).toList()) ? 0 : 1;
      default:
        stderr.writeln('Unknown command: ${args.first}');
        exitCode = 64;
    }
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    exitCode = 1;
  }
}

String? _option(List<String> args, String name) {
  final int i = args.indexOf('--$name');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

bool _flag(List<String> args, String name) => args.contains('--$name');

List<String> _positional(List<String> args) {
  final List<String> out = <String>[];
  for (int i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (const <String>{
        '--build',
        '--version',
        '--github-json',
      }.contains(args[i])) {
        i++;
      }
      continue;
    }
    out.add(args[i]);
  }
  return out;
}

bool _report(String what, List<String> problems) {
  if (problems.isEmpty) {
    stdout.writeln('$what: OK');
    return true;
  }
  stderr.writeln('$what: ${problems.length} problem(s)');
  for (final String p in problems) {
    stderr.writeln('  - $p');
  }
  return false;
}

/// The app and the workflow agree on names and versions.
List<String> _check() {
  final String yml = File('.github/workflows/release.yml').readAsStringSync();
  final String ios = File('.github/workflows/ios.yml').readAsStringSync();
  final Set<String> produced = workflowAssetNames(yml, iosYml: ios);
  final List<String> out = workflowProblems(produced, kContractAssets)
    ..addAll(
      androidBuildProblems(
        yml,
        File('android/gradle.properties').readAsStringSync(),
      ),
    );
  // The names the app's code asks for are the contract's.
  final String app = <String>[
    'lib/src/features/update/android_abi.dart',
    'lib/src/features/update/github_release.dart',
    'lib/src/features/update/release.dart',
    'lib/src/features/update/sha256_sums.dart',
  ].map((String p) => File(p).readAsStringSync()).join('\n');
  for (final String name in <String>[
    'Zen-arm64-v8a.apk',
    'Zen-armeabi-v7a.apk',
    'Zen-x86_64.apk',
    'Zen-Windows.zip',
    'Zen-Windows-arm64.zip',
    'Zen-macOS.zip',
    kSignedSumsAsset,
    kSumsAsset,
  ]) {
    if (!app.contains(name)) {
      out.add(
        'the app no longer names $name: update tool/release_contract.dart',
      );
    }
  }
  if (!app.contains(r"'Zen-Linux-$arch.tar.gz'") ||
      !app.contains(r"'Zen-Linux-$arch.deb'") ||
      !app.contains("'Zen-Linux-x64.flatpak'")) {
    out.add('the app names its Linux files differently: update the contract');
  }
  // The tag must be the version the build reports, or the app keeps
  // offering the release it already is.
  if (!yml.contains('pubspec.yaml') || !yml.contains('GITHUB_REF_NAME')) {
    out.add('release.yml does not check the tag against pubspec.yaml');
  }
  final (String version, int build) = pubspecVersion(
    File('pubspec.yaml').readAsStringSync(),
  );
  final String appVersion = File(
    'lib/src/app/app_version.dart',
  ).readAsStringSync();
  if (!appVersion.contains("kAppVersion = '$version'") ||
      !appVersion.contains('kAppBuild = $build;')) {
    out.add('app_version.dart is not $version+$build as pubspec.yaml');
  }
  return out;
}

Future<ProcessResult> _run(
  String exe,
  List<String> args, {
  String? dir,
  bool show = true,
}) async {
  if (show) {
    stdout.writeln('\$ $exe ${args.join(' ')}');
  }
  final ProcessResult r = await Process.run(
    exe,
    args,
    workingDirectory: dir,
    runInShell: Platform.isWindows,
  );
  if (show) {
    stdout.write(r.stdout);
    stderr.write(r.stderr);
  }
  return r;
}

Future<bool> _prepare(List<String> args) async {
  final List<String> pos = _positional(args);
  if (pos.isEmpty || !kVersionPattern.hasMatch(pos.first)) {
    throw const FormatException('Give the new version: prepare 1.12.0');
  }
  final String version = pos.first;
  final File pubspecFile = File('pubspec.yaml');
  final (String current, int currentBuild) = pubspecVersion(
    pubspecFile.readAsStringSync(),
  );
  if (_compare(version, current) <= 0) {
    throw FormatException('$version is not newer than $current');
  }
  final int build =
      int.tryParse(_option(args, 'build') ?? '') ?? currentBuild + 1;
  if (build <= currentBuild) {
    throw FormatException('build $build is not above $currentBuild');
  }
  final String tag = 'v$version';

  // 1. A clean tree on a known commit.
  if (!_flag(args, 'allow-dirty')) {
    final ProcessResult status = await _run('git', <String>[
      'status',
      '--porcelain',
    ], show: false);
    if ((status.stdout as String).trim().isNotEmpty) {
      stderr.writeln(
        'The working tree has changes. Commit them first '
        '(or --allow-dirty).',
      );
      return false;
    }
  }
  final ProcessResult tags = await _run('git', <String>[
    'tag',
    '--list',
    tag,
  ], show: false);
  if ((tags.stdout as String).trim().isNotEmpty) {
    stderr.writeln('The tag $tag already exists.');
    return false;
  }

  // 2. The app pins the keys its updates are checked with; without them
  // the release cannot be told from a forged one.
  final List<String> keys = pinnedKeyProblems(
    releaseDart: File(
      'lib/src/features/update/release.dart',
    ).readAsStringSync(),
    apkSignatureDart: File(
      'lib/src/features/update/apk_signature.dart',
    ).readAsStringSync(),
  );
  if (keys.isNotEmpty) {
    if (!_flag(args, 'allow-unpinned-keys')) {
      _report('release keys', keys);
      stderr.writeln('Pin them first (a test release: --allow-unpinned-keys).');
      return false;
    }
    stderr.writeln(
      'WARNING: --allow-unpinned-keys: ${keys.join('; ')}. Not for a '
      'release people update from.',
    );
  }

  // 3. The checks CI runs.
  if (_flag(args, 'skip-checks')) {
    stdout.writeln('Skipping analyze and tests: make sure CI is green.');
  } else {
    for (final (String exe, List<String> a, String? dir)
        in <(String, List<String>, String?)>[
          (
            'dart',
            <String>[
              'format',
              '--output=none',
              '--set-exit-if-changed',
              'lib',
              'test',
              'tool',
            ],
            null,
          ),
          ('flutter', <String>['analyze'], null),
          ('flutter', <String>['test'], null),
          (
            'go',
            <String>['test', '-count=1', './...'],
            'native/yggdrasil_bridge',
          ),
        ]) {
      if ((await _run(exe, a, dir: dir)).exitCode != 0) {
        stderr.writeln('$exe ${a.first} failed: no release.');
        return false;
      }
    }
  }

  // 4. The app and the workflow agree.
  if (!_report('check', _check())) {
    return false;
  }

  // 5. The version everywhere, and the changelog.
  final DateTime today = DateTime.now();
  final String date =
      '${today.year}-${today.month.toString().padLeft(2, '0')}-'
      '${today.day.toString().padLeft(2, '0')}';
  pubspecFile.writeAsStringSync(
    bumpPubspec(pubspecFile.readAsStringSync(), version, build),
  );
  final File appVersion = File('lib/src/app/app_version.dart');
  appVersion.writeAsStringSync(
    bumpAppVersion(appVersion.readAsStringSync(), version, build),
  );
  final File metainfo = File('linux/packaging/com.roj.zen.metainfo.xml');
  metainfo.writeAsStringSync(
    bumpMetainfo(metainfo.readAsStringSync(), version, date),
  );
  final File changelog = File('CHANGELOG.md');
  changelog.writeAsStringSync(
    moveUnreleased(changelog.readAsStringSync(), version, today),
  );
  // Android, iOS, macOS and Windows take version and build from
  // pubspec.yaml when they are built (flutter.versionName / versionCode,
  // FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER, FLUTTER_VERSION).
  stdout.writeln('Version $version+$build written.');

  // 6. Commit and tag (never pushed here).
  final List<String> files = <String>[
    'pubspec.yaml',
    'lib/src/app/app_version.dart',
    'linux/packaging/com.roj.zen.metainfo.xml',
    'CHANGELOG.md',
  ];
  if (_flag(args, 'no-tag')) {
    stdout.writeln('Not committed (--no-tag). Files: ${files.join(', ')}');
    return true;
  }
  if ((await _run('git', <String>['add', ...files])).exitCode != 0 ||
      (await _run('git', <String>['commit', '-m', 'Zen $version'])).exitCode !=
          0 ||
      (await _run('git', <String>[
            'tag',
            '-a',
            tag,
            '-m',
            'Zen $version',
          ])).exitCode !=
          0) {
    return false;
  }
  stdout.writeln(
    '\nReady. Check the commit, push it and merge it into main through a '
    'pull request (a merge commit, not squash), then push the tag:\n'
    '  git push origin HEAD\n'
    '  git push origin $tag\n'
    'The Release workflow builds a draft release; publish it by hand after '
    '`dart run tool/release.dart verify` (docs/RELEASES.md, section 3).',
  );
  return true;
}

int _compare(String a, String b) {
  final List<int> x = a.split('.').map(int.parse).toList();
  final List<int> y = b.split('.').map(int.parse).toList();
  for (int i = 0; i < 3; i++) {
    if (x[i] != y[i]) {
      return x[i].compareTo(y[i]);
    }
  }
  return 0;
}

Future<bool> _verify(List<String> args) async {
  final String? version = _option(args, 'version');
  if (version == null || !kVersionPattern.hasMatch(version)) {
    throw const FormatException('Give --version x.y.z');
  }
  final bool signature = _flag(args, 'require-signature');
  bool ok = true;
  final String? jsonPath = _option(args, 'github-json');
  if (jsonPath != null) {
    ok &= _report(
      'GitHub release JSON',
      verifyReleaseJson(
        jsonDecode(File(jsonPath).readAsStringSync()),
        version: version,
        requireSignature: signature,
      ),
    );
  }
  final List<String> pos = _positional(args);
  if (pos.isNotEmpty) {
    final Directory dir = Directory(pos.first);
    ok &= _report(
      'release folder',
      await verifyReleaseFolder(
        dir,
        version: version,
        requireSignature: signature,
      ),
    );
    final File sig = File('${dir.path}/$kSignedSumsAsset');
    if (sig.existsSync()) {
      final List<String> signers = await signing.validSigners(
        jsonDecode(sig.readAsStringSync()) as Map<String, dynamic>,
      );
      final String pinned = File(
        'lib/src/features/update/release.dart',
      ).readAsStringSync();
      final List<String> trusted = <String>[
        for (final String id in signers)
          if (pinned.contains(id)) id,
      ];
      stdout.writeln(
        'Valid signatures: ${signers.length}; by keys the app '
        'pins (kReleaseMaintainers): ${trusted.length}',
      );
      if (signers.isEmpty || (signature && trusted.isEmpty)) {
        stderr.writeln(
          '$kSignedSumsAsset: no valid signature the app accepts.',
        );
        ok = false;
      }
    }
  }
  return ok;
}
