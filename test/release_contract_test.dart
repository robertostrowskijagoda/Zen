import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart'
    as app_installer;
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';

import '../tool/release_contract.dart';

/// Every file the app's GitHub updater can ask for.
Set<String> _appAssetNames() => <String>{
  for (final (String platform, Abi abi) in <(String, Abi)>[
    ('android', Abi.androidArm64),
    ('android', Abi.androidArm),
    ('android', Abi.androidX64),
    ('windows', Abi.windowsX64),
    ('windows', Abi.windowsArm64),
    ('macos', Abi.macosArm64),
    ('linux', Abi.linuxX64),
    ('linux', Abi.linuxArm64),
  ])
    for (final LinuxInstall install in LinuxInstall.values)
      ?githubAssetName(releasePlatform: platform, abi: abi, linux: install),
};

void main() {
  group('the app and the release agree', () {
    test('the contract names exactly the files the app downloads', () {
      expect(_appAssetNames(), kUpdateAssets.toSet());
      expect(kSignedSumsAsset, kSignedSumsAssetName);
      expect(sha256SumsUri('1.2.3').path, endsWith('/v1.2.3/$kSumsAsset'));
      for (final String name in kContractAssets) {
        expect(kSafeAssetName.hasMatch(name), isTrue, reason: name);
      }
    });

    test('release.yml produces every one of them', () {
      final Set<String> produced = workflowAssetNames(
        File('.github/workflows/release.yml').readAsStringSync(),
        iosYml: File('.github/workflows/ios.yml').readAsStringSync(),
      );
      expect(workflowProblems(produced, kContractAssets), isEmpty);
      expect(produced, containsAll(kContractAssets));
    });

    test('Android: one APK per ABI, one version code for all', () {
      expect(
        androidBuildProblems(
          File('.github/workflows/release.yml').readAsStringSync(),
          File('android/gradle.properties').readAsStringSync(),
        ),
        isEmpty,
      );
      const String split = 'run: flutter build apk --release --split-per-abi\n';
      const String props = 'force-version-code-ignoring-abi=true\n';
      expect(androidBuildProblems(split, props), isEmpty);
      expect(
        androidBuildProblems('run: flutter build apk --release\n', props),
        hasLength(2),
      );
      expect(
        androidBuildProblems('# flutter build apk --split-per-abi\n', props),
        <String>[
          'release.yml does not build one APK per ABI (--split-per-abi)',
        ],
      );
      expect(androidBuildProblems(split, ''), hasLength(1));
    });

    test('release.yml refuses a tag that is not the version of the build', () {
      final String yml = File(
        '.github/workflows/release.yml',
      ).readAsStringSync();
      expect(yml, contains('The tag is the version of the build'));
      expect(yml, contains('GITHUB_REF_NAME'));
      final (String version, int build) = pubspecVersion(
        File('pubspec.yaml').readAsStringSync(),
      );
      expect(version, kAppVersion);
      expect(build, kAppBuild);
    });

    test('Windows and Linux: one Zen folder with its marker', () {
      expect(
        desktopArchiveProblems(
          File('.github/workflows/release.yml').readAsStringSync(),
        ),
        isEmpty,
      );
      // The app reads the marker the workflow writes.
      expect(kAppFolderMarker, app_installer.kAppFolderMarker);
      expect(kAppFolderMarkerHeader, app_installer.kAppFolderMarkerHeader);
      const String marker =
          "          Set-Content -LiteralPath (Join-Path \$app 'zen-app.marker') "
          "-Value (@('zen-app 1') + \$names)\n";
      const String tar =
          '      - name: Release files\n'
          '        run: |\n'
          "          { echo 'zen-app 1'; ls -A b; } > \"\$bundle/zen-app.marker\"\n"
          "          tar --transform 's,^bundle,Zen,' -cf - bundle \\\n"
          '            | gzip -9n > "dist/Zen-Linux-\$ARCH.tar.gz"\n';
      String windows(String zip, {bool loose = false, bool marked = true}) =>
          '      - name: Release files\n'
          '        run: |\n'
          "          \$app = Join-Path \$env:RUNNER_TEMP 'zip/Zen'\n"
          '${marked ? marker : ''}'
          '          Compress-Archive -Path '
          '${loose ? 'build/windows/x64/runner/Release/*' : r'$app'} '
          '-DestinationPath dist/$zip\n';
      final String good =
          windows('Zen-Windows.zip') + windows('Zen-Windows-arm64.zip') + tar;
      expect(desktopArchiveProblems(good), isEmpty);
      // Loose files in the zip: "Extract here" spills them into Downloads.
      expect(
        desktopArchiveProblems(
          windows('Zen-Windows.zip', loose: true) +
              windows('Zen-Windows-arm64.zip') +
              tar,
        ),
        <String>['Zen-Windows.zip must hold one Zen folder, not loose files'],
      );
      // No marker: the app would never update itself in place.
      expect(
        desktopArchiveProblems(
          windows('Zen-Windows.zip') +
              windows('Zen-Windows-arm64.zip', marked: false) +
              tar.replaceFirst("echo 'zen-app 1'", 'true'),
        ),
        <String>[
          'Zen-Windows-arm64.zip carries no zen-app.marker',
          'the Linux tar.gz carries no zen-app.marker',
        ],
      );
    });

    test('a workflow that renames a file is caught', () {
      final Set<String> produced = workflowAssetNames(
        'run: cp a dist/Zen-Windows-x64.zip\n'
        '      - arch: x64\n'
        'run: tar -czf "dist/Zen-Linux-\$ARCH.tar.gz" bundle\n',
      );
      expect(produced, <String>{'Zen-Windows-x64.zip', 'Zen-Linux-x64.tar.gz'});
      expect(
        workflowProblems(produced, kContractAssets),
        contains(contains('Zen-Windows.zip')),
      );
    });
  });

  group('prepare', () {
    test('refuses while the app pins no release keys', () {
      const String none =
          'const List<String> kReleaseMaintainers = <String>[];';
      const String noCert =
          'const List<String> kOfficialApkCertificatesSha256 = <String>[];';
      expect(
        pinnedKeyProblems(releaseDart: none, apkSignatureDart: noCert),
        hasLength(2),
      );
      const String key =
          "const List<String> kReleaseMaintainers = <String>[\n  'zh1abc',\n];";
      const String cert =
          'const List<String> kOfficialApkCertificatesSha256 = <String>[\n'
          "  'ab12',\n];";
      expect(
        pinnedKeyProblems(releaseDart: key, apkSignatureDart: cert),
        isEmpty,
      );
      expect(constStringList(key, 'kReleaseMaintainers'), <String>['zh1abc']);
      // The real files are read the same way.
      expect(
        constStringList(
          File('lib/src/features/update/release.dart').readAsStringSync(),
          'kReleaseMaintainers',
        ),
        kReleaseMaintainers,
      );
    });

    test('a commented-out key is not pinned', () {
      const String cert =
          'const List<String> kOfficialApkCertificatesSha256 = <String>[\n'
          "  'ab12',\n];";
      // The compiled app holds an empty list in each of these: CI must not
      // see a key there.
      for (final String release in <String>[
        "const List<String> kReleaseMaintainers = <String>[\n"
            "  // 'zh1abc',  // switched off for now\n];",
        "const List<String> kReleaseMaintainers = <String>[\n"
            "  /* 'zh1abc', /* nested */ 'zh1def', */\n];",
        "// const List<String> kReleaseMaintainers = <String>['zh1abc'];\n"
            'const List<String> kReleaseMaintainers = <String>[];',
      ]) {
        expect(pinnedReleaseKeys(release), isEmpty, reason: release);
        expect(
          pinnedKeyProblems(releaseDart: release, apkSignatureDart: cert),
          <Matcher>[contains('kReleaseMaintainers is empty')],
        );
      }
      expect(
        pinnedKeyProblems(
          releaseDart:
              "const List<String> kReleaseMaintainers = <String>['zh1abc'];",
          apkSignatureDart:
              'const List<String> kOfficialApkCertificatesSha256 = '
              "<String>[\n  // 'ab12',\n];",
        ),
        <Matcher>[contains('kOfficialApkCertificatesSha256 is empty')],
      );
      // Comment markers inside a string are text; adjacent literals join;
      // a comment after an entry does not hide it.
      expect(
        constStringList(
          "const String u = 'https://example.org/*x';\n"
              'const List<String> k = <String>[\n'
              "  'zh1' 'abc', // the first key\n"
              "  r'zh1\$def',\n"
              '];',
          'k',
        ),
        <String>['zh1abc', r'zh1$def'],
      );
      // Anything but a plain literal is an error, never a guess.
      for (final String entry in <String>['other', r"'${x}'", r"'$x'"]) {
        expect(
          () =>
              constStringList('const List<String> k = <String>[$entry];', 'k'),
          throwsFormatException,
          reason: entry,
        );
      }
      // Every real Dart file of the project is read without losing code.
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) {
          final String text = f.readAsStringSync();
          expect(stripDartComments(text).length, text.length, reason: f.path);
        }
      }
    });

    test('the APKs must be signed with the pinned certificate', () {
      final String cert = 'ab' * 32;
      final String shown = <String>[
        for (int i = 0; i < 64; i += 2) cert.substring(i, i + 2).toUpperCase(),
      ].join(':');
      // As keytool prints it, or as plain hex: the same certificate.
      expect(
        pinnedCertificateProblems(
          fingerprints: <String>[cert],
          pinned: <String>[shown],
        ),
        isEmpty,
      );
      expect(
        pinnedCertificateProblems(
          fingerprints: <String>['cd' * 32],
          pinned: <String>[cert],
        ),
        <Matcher>[contains('does not pin')],
      );
      expect(
        pinnedCertificateProblems(
          fingerprints: <String>[cert],
          pinned: const <String>[],
        ),
        <Matcher>[contains('kOfficialApkCertificatesSha256 is empty')],
      );
      // The tag build runs the check on the APKs it built.
      expect(
        File('.github/workflows/release.yml').readAsStringSync(),
        contains('dart run tool/zen_release.dart fingerprint --pinned dist/'),
      );
    });

    test('prepare refuses unpinned native downloads', () {
      final String sum = 'ab' * 32;
      final String props =
          'distributionUrl=https\\://services.gradle.org/distributions/'
          'gradle-8.14-all.zip\n';
      final String pins = '# comment\n$sum  150.7871.01/WebRTC.xcframework\n';
      expect(
        nativePinProblems(
          gradleWrapperProperties: '${props}distributionSha256Sum=$sum\n',
          iosPodfileLock: true,
          macosPodfileLock: true,
          webrtcSdkPins: pins,
        ),
        isEmpty,
      );
      expect(
        nativePinProblems(
          gradleWrapperProperties: '$props# distributionSha256Sum=$sum\n',
          iosPodfileLock: false,
          macosPodfileLock: true,
          webrtcSdkPins: '# $sum  150.7871.01/WebRTC.xcframework\n',
        ),
        <Matcher>[
          contains('distributionSha256Sum'),
          contains('ios/Podfile.lock'),
          contains('webrtc_sdk.sha256'),
        ],
      );
      // The real pin file reads as a pin file (comments only, or pins).
      for (final String line in File(
        'tool/ci/webrtc_sdk.sha256',
      ).readAsLinesSync()) {
        expect(
          line.isEmpty ||
              line.startsWith('#') ||
              RegExp(r'^[0-9a-f]{64}\s+\S+$').hasMatch(line),
          isTrue,
          reason: line,
        );
      }
    });

    test('a signature counts only by a pinned key', () {
      const String key =
          "const List<String> kReleaseMaintainers = <String>[\n  'zh1abc',\n];";
      expect(pinnedReleaseKeys(key), <String>['zh1abc']);
      expect(
        pinnedSignatureProblems(
          signers: <String>['zh1abc'],
          pinned: pinnedReleaseKeys(key),
        ),
        isEmpty,
      );
      // Signed with another key than the app's: every computer would
      // refuse the update.
      expect(
        pinnedSignatureProblems(
          signers: <String>['zh1other'],
          pinned: <String>['zh1abc'],
        ),
        <Matcher>[contains('zh1other')],
      );
      // A part of a pinned key is not the key.
      expect(
        pinnedSignatureProblems(
          signers: <String>['zh1ab'],
          pinned: <String>['zh1abc'],
        ),
        hasLength(1),
      );
      // Nothing pinned: the computers would take unsigned updates.
      expect(
        pinnedSignatureProblems(
          signers: <String>['zh1abc'],
          pinned: const <String>[],
        ),
        <Matcher>[contains('kReleaseMaintainers is empty')],
      );
      // A release for network updates needs two pinned signatures.
      expect(
        pinnedSignatureProblems(
          signers: <String>['zh1abc', 'zh1other'],
          pinned: <String>['zh1abc', 'zh1x', 'zh1y'],
          needed: 2,
        ),
        hasLength(1),
      );
    });

    test('a tag build stops without pinned keys or with a foreign one', () {
      final String yml = File(
        '.github/workflows/release.yml',
      ).readAsStringSync();
      // The pins are checked in the tag-only android job, before any key.
      final int android = yml.indexOf('\n  android:\n');
      final int windows = yml.indexOf('\n  windows:\n');
      final String androidJob = yml.substring(android, windows);
      expect(androidJob, contains('dart run tool/release.dart pinned'));
      expect(
        androidJob.indexOf('tool/release.dart pinned'),
        lessThan(androidJob.indexOf('name: Release key')),
      );
      // The signature is checked against the pins.
      final String signJob = yml.substring(yml.indexOf('\n  sign:\n'));
      expect(
        signJob,
        contains(
          'dart run tool/zen_release.dart verify --pinned '
          'signed/SHA256SUMS.sig',
        ),
      );
    });

    test('bumps pubspec.yaml and app_version.dart', () {
      const String pubspec = 'name: zen\nversion: 1.11.0+11\n\nenvironment:\n';
      expect(
        bumpPubspec(pubspec, '1.12.0', 12),
        'name: zen\nversion: 1.12.0+12\n\nenvironment:\n',
      );
      expect(pubspecVersion(bumpPubspec(pubspec, '1.12.0', 12)), (
        '1.12.0',
        12,
      ));
      const String source =
          "const String kAppVersion = '1.11.0';\nconst int kAppBuild = 11;\n";
      expect(
        bumpAppVersion(source, '1.12.0', 12),
        "const String kAppVersion = '1.12.0';\nconst int kAppBuild = 12;\n",
      );
      expect(
        () => bumpAppVersion('nothing', '1.0.0', 1),
        throwsFormatException,
      );
    });

    test('adds the release to the AppStream metadata', () {
      const String xml =
          '  <releases>\n    <release version="1.10.0" date="2026-10-14"/>\n'
          '  </releases>\n';
      final String out = bumpMetainfo(xml, '1.12.0', '2026-11-02');
      expect(
        out,
        '  <releases>\n    <release version="1.12.0" date="2026-11-02"/>\n'
        '    <release version="1.10.0" date="2026-10-14"/>\n  </releases>\n',
      );
      expect(bumpMetainfo(out, '1.12.0', '2026-11-03'), contains('2026-11-03'));
    });

    test('moves "Unreleased" into the new version', () {
      const String log =
          '# Changelog\n\n## Unreleased\n\n### New\n- A thing.\n\n'
          '## 1.11.0 — 20.10.2026\n';
      expect(
        moveUnreleased(log, '1.12.0', DateTime(2026, 11, 2)),
        '# Changelog\n\n## Unreleased\n\n## 1.12.0 — 02.11.2026\n\n'
        '### New\n- A thing.\n\n## 1.11.0 — 20.10.2026\n',
      );
      expect(
        () => moveUnreleased('# Changelog\n', '1.12.0', DateTime(2026)),
        throwsFormatException,
      );
      // The real changelog has the section.
      expect(
        moveUnreleased(
          File('CHANGELOG.md').readAsStringSync(),
          '99.0.0',
          DateTime(2030),
        ),
        contains('## 99.0.0 — 01.01.2030'),
      );
    });
  });

  group('verify', () {
    test('GitHub JSON: a draft, a wrong tag or a missing file is reported', () {
      Map<String, Object?> release({
        String tag = 'v1.12.0',
        bool draft = false,
        Iterable<String>? names,
      }) => <String, Object?>{
        'tag_name': tag,
        'draft': draft,
        'prerelease': false,
        'assets': <Object?>[
          for (final String n in names ?? kContractAssets)
            <String, Object?>{'name': n, 'size': 10},
        ],
      };
      expect(verifyReleaseJson(release(), version: '1.12.0'), isEmpty);
      expect(
        verifyReleaseJson(release(tag: 'v1.12'), version: '1.12.0'),
        isNotEmpty,
      );
      expect(
        verifyReleaseJson(release(draft: true), version: '1.12.0'),
        contains(contains('draft')),
      );
      expect(
        verifyReleaseJson(
          release(
            names: kContractAssets.where(
              (String n) => n != 'Zen-armeabi-v7a.apk',
            ),
          ),
          version: '1.12.0',
        ),
        <String>['Zen-armeabi-v7a.apk is missing'],
      );
      // The optional files may be missing, the signature not when asked for.
      final List<String> required = kContractAssets
          .where((String n) => !kOptionalAssets.contains(n))
          .toList();
      expect(verifyReleaseJson(release(names: required)), isEmpty);
      expect(
        verifyReleaseJson(release(names: required), requireSignature: true),
        <String>['$kSignedSumsAsset is missing'],
      );
      // GitHub's JSON is what the app reads too.
      expect(GithubRelease.fromJson(release())?.version, '1.12.0');
      expect(jsonEncode(release()), isNotEmpty);
    });
  });
}
