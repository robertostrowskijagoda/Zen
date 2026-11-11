// Prepares and checks a Zen release the same way every time, so the app
// can update itself from it. Plain Dart, no Flutter:
//
//   dart run tool/release.dart check
//       Do the app and .github/workflows/release.yml agree on the file
//       names (and the version in pubspec.yaml and app_version.dart)? Is
//       the "### What's new" note under "## Unreleased" of CHANGELOG.md,
//       when there is one, as the app takes it?
//   dart run tool/release.dart whats-new [--version 1.12.0] [--out FILE]
//       The "### What's new" note of that version in CHANGELOG.md (without
//       --version: of "Unreleased", under the version of pubspec.yaml) as
//       whats-new.json, the file the app shows with the update notice;
//       release.yml makes it for every tag.
//   dart run tool/release.dart pinned
//       Does the app pin its release keys (kReleaseMaintainers,
//       kOfficialApkCertificatesSha256)? CI runs it for every tag build.
//   dart run tool/release.dart prepare 1.12.0 [--build 12] [--skip-checks]
//       [--allow-dirty] [--no-tag] [--allow-unpinned-keys]
//       [--allow-unpinned-native]
//       Clean tree, a valid "### What's new" note under "## Unreleased",
//       the app pins its release keys (kReleaseMaintainers,
//       kOfficialApkCertificatesSha256; --allow-unpinned-keys only for a
//       test release), the native builds pin what they download (Gradle's
//       distributionSha256Sum, ios/ and macos/Podfile.lock,
//       tool/ci/webrtc_sdk.sha256; --allow-unpinned-native only for a test
//       release), `flutter analyze`, `flutter test`, `go test`, the tests
//       of the CI checks (tool/ci/test_*.py) and the links of the documents
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
      'Usage: dart run tool/release.dart check | pinned | prepare <x.y.z> | '
      'verify <folder> --version <x.y.z> | '
      'whats-new [--version <x.y.z>] [--out <file>]',
    );
    exitCode = 64;
    return;
  }
  try {
    switch (args.first) {
      case 'check':
        exitCode = _report('check', _check()) ? 0 : 1;
      case 'pinned':
        exitCode = _report('release keys', _pinnedKeys()) ? 0 : 1;
      case 'prepare':
        exitCode = await _prepare(args.skip(1).toList()) ? 0 : 1;
      case 'verify':
        exitCode = await _verify(args.skip(1).toList()) ? 0 : 1;
      case 'whats-new':
        exitCode = _whatsNew(args.skip(1).toList()) ? 0 : 1;
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
        '--out',
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

/// What the app of this tree does not pin yet (see [pinnedKeyProblems]).
List<String> _pinnedKeys() => pinnedKeyProblems(
  releaseDart: File('lib/src/features/update/release.dart').readAsStringSync(),
  apkSignatureDart: File(
    'lib/src/features/update/apk_signature.dart',
  ).readAsStringSync(),
);

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
    )
    ..addAll(desktopArchiveProblems(yml));
  // The names the app's code asks for are the contract's.
  final String app = <String>[
    'lib/src/features/update/android_abi.dart',
    'lib/src/features/update/github_release.dart',
    'lib/src/features/update/release.dart',
    'lib/src/features/update/sha256_sums.dart',
    'lib/src/features/update/whats_new.dart',
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
    kWhatsNewAsset,
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
  // A note already written for the next release is as the app takes it
  // (prepare requires one).
  out.addAll(
    whatsNewSection(
      File('CHANGELOG.md').readAsStringSync(),
      required: false,
    ).problems,
  );
  return out;
}

/// `whats-new`: the note of `--version` (else of "Unreleased") as
/// whats-new.json, into `--out` or on stdout.
bool _whatsNew(List<String> args) {
  final String? version = _option(args, 'version');
  if (version != null && !kVersionPattern.hasMatch(version)) {
    throw const FormatException('Give --version x.y.z');
  }
  final (
    :Map<String, List<String>> lines,
    :List<String> problems,
  ) = whatsNewSection(
    File('CHANGELOG.md').readAsStringSync(),
    version: version,
  );
  // Only problems are reported: the file itself may go to stdout.
  if (problems.isNotEmpty && !_report("What's new", problems)) {
    return false;
  }
  final String json = whatsNewJson(
    version ?? pubspecVersion(File('pubspec.yaml').readAsStringSync()).$1,
    lines,
  );
  final String? out = _option(args, 'out');
  if (out == null) {
    stdout.write(json);
  } else {
    File(out).writeAsStringSync(json);
  }
  return true;
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

  // 1a. The release before this one left its data for the upgrade tests
  // (test/start_upgrade_test.dart): a reminder, never a stop.
  final Directory fixtures = Directory('test/fixtures/upgrade');
  final String? fixture = missingUpgradeFixture(current, <String>[
    if (fixtures.existsSync())
      for (final FileSystemEntity e in fixtures.listSync())
        if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
  ]);
  if (fixture != null) {
    stdout.writeln('Reminder: $fixture');
  }

  // 1a'. Mutation testing grows with the app: the logic changed since the
  // last release that has a fast test of its own goes into
  // tool/mutation_targets.json (or is skipped there, with a reason).
  final ProcessResult changedFiles = await _run('git', <String>[
    'diff',
    '--name-only',
    'v$current..HEAD',
    '--',
    'lib',
  ], show: false);
  if (changedFiles.exitCode == 0) {
    final List<String> changed = const LineSplitter().convert(
      '${changedFiles.stdout}',
    );
    final List<dynamic> mutationTargets =
        jsonDecode(File('tool/mutation_targets.json').readAsStringSync())
            as List<dynamic>;
    final List<String> missing = missingMutationTargets(
      changed: changed,
      sources: <String, String>{
        for (final String file in changed)
          if (File(file).existsSync()) file: File(file).readAsStringSync(),
      },
      tests: <String>{
        for (final FileSystemEntity e in Directory('test').listSync())
          if (e is File) e.path.replaceAll(r'\', '/'),
      },
      slowTests:
          (jsonDecode(File('tool/test_times.json').readAsStringSync())
                  as Map<String, dynamic>)
              .keys
              .toSet(),
      listed: <String>{
        for (final dynamic t in mutationTargets)
          (t as Map<String, dynamic>)['file'] as String,
      },
    );
    if (missing.isNotEmpty) {
      stdout.writeln(
        'Reminder: changed since v$current, with a fast test of its own, '
        'and not in tool/mutation_targets.json (add it, or add it with '
        '"skip" and the reason; docs/TESTING.md, section 11.4):',
      );
      for (final String file in missing) {
        stdout.writeln('  $file');
      }
    }
  }

  // 1b. The short note the app shows with the update notice; release.yml
  // makes whats-new.json of it, which the signature covers.
  final ({Map<String, List<String>> lines, List<String> problems}) note =
      whatsNewSection(File('CHANGELOG.md').readAsStringSync());
  if (!_report("What's new", note.problems)) {
    stderr.writeln(
      'Write 1 to 3 short lines under "$kWhatsNewHeading" in "## Unreleased" '
      'of CHANGELOG.md: "- [en] …", and "- [pl] …" (docs/RELEASES.md, '
      "section 3.5).",
    );
    return false;
  }
  for (final MapEntry<String, List<String>> e in note.lines.entries) {
    for (final String line in e.value) {
      stdout.writeln("What's new [${e.key}]: $line");
    }
  }

  // 2. The app pins the keys its updates are checked with; without them
  // the release cannot be told from a forged one.
  final List<String> keys = _pinnedKeys();
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

  // 2b. The native builds pin what they download (a tag build also fails
  // on an unpinned WebRTC framework).
  final List<String> native = nativePinProblems(
    gradleWrapperProperties: File(
      'android/gradle/wrapper/gradle-wrapper.properties',
    ).readAsStringSync(),
    iosPodfileLock: File('ios/Podfile.lock').existsSync(),
    macosPodfileLock: File('macos/Podfile.lock').existsSync(),
    webrtcSdkPins: File('tool/ci/webrtc_sdk.sha256').readAsStringSync(),
  );
  if (native.isNotEmpty) {
    if (!_flag(args, 'allow-unpinned-native')) {
      _report('native dependencies', native);
      stderr.writeln(
        'Pin them first (a test release: --allow-unpinned-native).',
      );
      return false;
    }
    stderr.writeln('WARNING: --allow-unpinned-native: ${native.join('; ')}.');
  }

  // 3. The checks CI runs.
  if (_flag(args, 'skip-checks')) {
    stdout.writeln('Skipping analyze and tests: make sure CI is green.');
  } else {
    // CI's docs job runs the tests of its own checks; one of them keeps the
    // list of tests that read the documents complete, so a test added
    // without its line there fails the release's CI and not the work before.
    final String python = Platform.isWindows ? 'python' : 'python3';
    final List<String> ciTests =
        Directory('tool/ci')
            .listSync()
            .whereType<File>()
            .map((File f) => f.uri.pathSegments.last)
            .where((String n) => n.startsWith('test_') && n.endsWith('.py'))
            .toList()
          ..sort();
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
          for (final String name in ciTests)
            (python, <String>['tool/ci/$name'], null),
          (python, <String>['tool/ci/check_links.py'], null),
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
      final Set<String> pinned = pinnedReleaseKeys(
        File('lib/src/features/update/release.dart').readAsStringSync(),
      ).toSet();
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
