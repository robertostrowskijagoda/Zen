import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/features/update/github_release.dart';
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
