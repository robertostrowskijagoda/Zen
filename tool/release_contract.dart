// What a Zen release must look like for the app to update itself from it,
// and the checks `tool/release.dart` runs before a tag and on a downloaded
// release. Plain Dart (no Flutter), so `dart run` can use it; a test keeps
// these names equal to the app's (lib/src/features/update/**).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// The files the app's GitHub updater downloads (githubAssetName in
/// lib/src/features/update/github_release.dart), one per platform and
/// kind of installation; Android one per ABI (kAndroidApkAssets in
/// lib/src/features/update/android_abi.dart).
const List<String> kUpdateAssets = <String>[
  'Zen-arm64-v8a.apk',
  'Zen-armeabi-v7a.apk',
  'Zen-x86_64.apk',
  'Zen-Windows.zip',
  'Zen-Windows-arm64.zip',
  'Zen-macOS.zip',
  'Zen-Linux-x64.tar.gz',
  'Zen-Linux-arm64.tar.gz',
  'Zen-Linux-x64.deb',
  'Zen-Linux-arm64.deb',
  'Zen-Linux-x64.flatpak',
];

/// The iPhone file: the SideStore / AltStore source (apps.json) and the
/// install page point to it.
const String kIpaAsset = 'Zen-unsigned.ipa';

/// The sums every update is checked against (sha256SumsUri).
const String kSumsAsset = 'SHA256SUMS';

/// The maintainers' signature of [kSumsAsset] (kSignedSumsAssetName).
const String kSignedSumsAsset = 'SHA256SUMS.sig';

/// Files a release may lack without breaking an update: the Windows ARM64
/// build is not required yet (release.yml), and the signature exists only
/// when the signing key is set up (required once the app pins a key).
const Set<String> kOptionalAssets = <String>{
  'Zen-Windows-arm64.zip',
  kSignedSumsAsset,
};

/// Every file name the app or the install page relies on.
List<String> get kContractAssets => <String>[
  ...kUpdateAssets,
  kIpaAsset,
  kSumsAsset,
  kSignedSumsAsset,
];

/// A release file name as the app accepts it (`_safeAssetName`).
final RegExp kSafeAssetName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$');

/// `major.minor.patch`, as the app compares versions (isValidAppVersion).
final RegExp kVersionPattern = RegExp(r'^(\d{1,4})\.(\d{1,4})\.(\d{1,4})$');

/// The largest release file the app downloads (kMaxGithubAssetBytes).
const int kMaxAssetBytes = 600 * 1024 * 1024;

/// The file names the release workflow writes into its `dist/` folder
/// (and SHA256SUMS / SHA256SUMS.sig), read from [releaseYml]; a
/// `$ARCH` / `${{ matrix.arch }}` in a name stands for every
/// `- arch:` of the workflow. [iosYml] adds the iPhone file.
Set<String> workflowAssetNames(String releaseYml, {String iosYml = ''}) {
  final List<String> lines = <String>[
    for (final String l in const LineSplitter().convert(releaseYml))
      if (!l.trimLeft().startsWith('#')) l,
  ];
  final List<String> arches = <String>[
    for (final String l in lines)
      if (RegExp(r'^\s*-\s*arch:\s*(\w+)').firstMatch(l)
          case final RegExpMatch m)
        m.group(1)!,
  ];
  final Set<String> names = <String>{};
  final RegExp dist = RegExp(r'dist/(Zen[A-Za-z0-9._${}\-]*)');
  for (final String l in lines) {
    for (final RegExpMatch m in dist.allMatches(l)) {
      final String raw = m
          .group(1)!
          .replaceAll(RegExp(r'\$\{\{\s*matrix\.arch\s*\}\}'), r'$ARCH');
      if (raw.contains(r'$ARCH')) {
        for (final String arch in arches) {
          names.add(raw.replaceAll(r'$ARCH', arch));
        }
      } else if (!raw.contains(r'$')) {
        names.add(raw);
      }
    }
  }
  final String body = lines.join('\n');
  if (RegExp(r'>\s*SHA256SUMS\b').hasMatch(body)) {
    names.add(kSumsAsset);
  }
  if (body.contains('/SHA256SUMS.sig')) {
    names.add(kSignedSumsAsset);
  }
  if (iosYml.contains(kIpaAsset) && body.contains(kIpaAsset)) {
    names.add(kIpaAsset);
  }
  return names;
}

/// What is wrong with how the release builds its Android files: one APK
/// per ABI ([releaseYml] runs `flutter build apk --split-per-abi`), all
/// with the plain version code ([gradleProperties], android/
/// gradle.properties, sets `force-version-code-ignoring-abi=true`; with
/// Flutter's 1000-per-ABI codes the APK of one ABI would be a downgrade
/// of another's and could not replace it).
List<String> androidBuildProblems(String releaseYml, String gradleProperties) {
  final String yml = <String>[
    for (final String l in const LineSplitter().convert(releaseYml))
      if (!l.trimLeft().startsWith('#')) l,
  ].join('\n');
  return <String>[
    if (!RegExp(r'flutter build apk [^\n]*--split-per-abi').hasMatch(yml))
      'release.yml does not build one APK per ABI (--split-per-abi)',
    if (RegExp(r'flutter build apk(?![^\n]*--split-per-abi)').hasMatch(yml))
      'release.yml builds a universal APK',
    if (!RegExp(
      r'^\s*force-version-code-ignoring-abi\s*=\s*true\s*$',
      multiLine: true,
    ).hasMatch(gradleProperties))
      'android/gradle.properties does not keep one version code for every '
          'ABI (force-version-code-ignoring-abi=true)',
  ];
}

/// What the workflow does not produce of what the app needs ([needed]).
List<String> workflowProblems(Set<String> produced, Iterable<String> needed) =>
    <String>[
      for (final String name in needed)
        if (!produced.contains(name))
          'release.yml does not produce $name, which the app needs',
      for (final String name in produced)
        if (!kSafeAssetName.hasMatch(name))
          'release.yml produces $name, a name the app ignores',
    ];

/// The sums of a `sha256sum` file, read exactly as the app reads them
/// (parseSha256Sums): name → lower-case hex.
Map<String, String> parseSums(String text) {
  final RegExp line = RegExp(r'^([0-9a-fA-F]{64}) [ *]?(.+)$');
  final Map<String, String> sums = <String, String>{};
  for (final String raw in const LineSplitter().convert(text)) {
    final RegExpMatch? m = line.firstMatch(raw.trim());
    if (m != null) {
      sums[m.group(2)!.trim()] = m.group(1)!.toLowerCase();
    }
  }
  return sums;
}

/// A hybrid id `<Ed25519, 44 base64>.<SHA-256 of the ML-DSA key, 43/44>`.
final RegExp _hybridId = RegExp(
  r'^[A-Za-z0-9_\-+/=]{43,44}\.[A-Za-z0-9_\-+/=]{43,44}$',
);

/// The format of a [kSignedSumsAsset] file as the app reads it
/// (SignedSums.fromJson): the signed version and files must be this
/// release's [version] and exactly the [sums]. Not the signatures
/// themselves (that needs the signer, `tool/release.dart verify` does it).
List<String> signedSumsProblems(
  String text, {
  required String version,
  required Map<String, String> sums,
}) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    return <String>['$kSignedSumsAsset is not JSON: ${e.message}'];
  }
  final List<String> out = <String>[];
  if (json is! Map || json['m'] is! Map || json['sigs'] is! List) {
    return <String>['$kSignedSumsAsset has no "m" and "sigs"'];
  }
  final Map<dynamic, dynamic> m = json['m'] as Map<dynamic, dynamic>;
  if (m['t'] != 'zen_sums' || m['app'] != 'zen') {
    out.add('$kSignedSumsAsset is not a "zen_sums" manifest of "zen"');
  }
  if (m['version'] != version) {
    out.add('$kSignedSumsAsset signs version ${m['version']}, not $version');
  }
  final Object? files = m['files'];
  if (files is! Map) {
    out.add('$kSignedSumsAsset has no "files"');
  } else {
    for (final MapEntry<String, String> e in sums.entries) {
      if (files[e.key] != e.value) {
        out.add(
          '$kSignedSumsAsset does not sign ${e.key} as SHA256SUMS lists it',
        );
      }
    }
    for (final Object? name in files.keys) {
      if (!sums.containsKey(name)) {
        out.add(
          '$kSignedSumsAsset signs $name, which SHA256SUMS does not list',
        );
      }
    }
  }
  final List<dynamic> sigs = json['sigs'] as List<dynamic>;
  if (sigs.isEmpty) {
    out.add('$kSignedSumsAsset carries no signature');
  }
  for (final Object? s in sigs) {
    if (s is! Map || s['k'] is! String || s['s'] is! String) {
      out.add('$kSignedSumsAsset has a malformed signature entry');
    } else if (!_hybridId.hasMatch(s['k'] as String)) {
      out.add(
        '$kSignedSumsAsset names a key that is not a hybrid id: ${s['k']}',
      );
    }
  }
  return out;
}

/// SHA-256 of [file], lower-case hex.
Future<String> fileSha256(File file) async =>
    (await crypto.sha256.bind(file.openRead()).first).toString();

/// Checks a downloaded release folder as the app would before updating:
/// every needed file is there, listed in SHA256SUMS with its real sum, and
/// SHA256SUMS.sig (when there, or when [requireSignature]) has the right
/// format for this [version].
Future<List<String>> verifyReleaseFolder(
  Directory dir, {
  required String version,
  bool requireSignature = false,
}) async {
  final List<String> out = <String>[];
  if (!kVersionPattern.hasMatch(version)) {
    return <String>['$version is not major.minor.patch'];
  }
  final File sumsFile = File('${dir.path}/$kSumsAsset');
  if (!sumsFile.existsSync()) {
    return <String>['$kSumsAsset is missing'];
  }
  final Map<String, String> sums = parseSums(sumsFile.readAsStringSync());
  for (final String name in kContractAssets) {
    if (name == kSumsAsset || name == kSignedSumsAsset) {
      continue;
    }
    final File f = File('${dir.path}/$name');
    if (!f.existsSync()) {
      if (!kOptionalAssets.contains(name)) {
        out.add('$name is missing');
      }
      continue;
    }
    if (!sums.containsKey(name)) {
      out.add('$name is not listed in $kSumsAsset');
    }
  }
  for (final MapEntry<String, String> e in sums.entries) {
    final File f = File('${dir.path}/${e.key}');
    if (!kSafeAssetName.hasMatch(e.key)) {
      out.add('$kSumsAsset lists ${e.key}, a name the app ignores');
    } else if (!f.existsSync()) {
      out.add('$kSumsAsset lists ${e.key}, which is not in the folder');
    } else {
      final int size = f.lengthSync();
      if (size <= 0 || size > kMaxAssetBytes) {
        out.add(
          '${e.key} has $size bytes (the app takes 1 to $kMaxAssetBytes)',
        );
      }
      if (await fileSha256(f) != e.value) {
        out.add('${e.key} does not match its sum in $kSumsAsset');
      }
    }
  }
  final File sig = File('${dir.path}/$kSignedSumsAsset');
  if (sig.existsSync()) {
    out.addAll(
      signedSumsProblems(sig.readAsStringSync(), version: version, sums: sums),
    );
  } else if (requireSignature) {
    out.add('$kSignedSumsAsset is missing');
  }
  return out;
}

/// Checks GitHub's JSON of a release (`releases/latest` or
/// `releases/tags/vX.Y.Z`) as the app reads it (GithubRelease.fromJson).
List<String> verifyReleaseJson(
  Object? json, {
  String? version,
  bool requireSignature = false,
}) {
  if (json is! Map) {
    return <String>['not a GitHub release object'];
  }
  final List<String> out = <String>[];
  final Object? tag = json['tag_name'];
  if (tag is! String ||
      !tag.startsWith('v') ||
      !kVersionPattern.hasMatch(tag.substring(1))) {
    out.add('the tag $tag is not v<major.minor.patch>');
  } else if (version != null && tag != 'v$version') {
    out.add('the tag is $tag, not v$version');
  }
  if (json['draft'] == true) {
    out.add('the release is a draft: the app does not see it');
  }
  if (json['prerelease'] == true) {
    out.add('the release is a pre-release: the app does not see it');
  }
  final Map<String, int> assets = <String, int>{};
  for (final Object? a
      in (json['assets'] as List<dynamic>?) ?? const <dynamic>[]) {
    if (a is Map && a['name'] is String && a['size'] is int) {
      assets[a['name'] as String] = a['size'] as int;
    }
  }
  for (final String name in kContractAssets) {
    final int? size = assets[name];
    final bool optional =
        kOptionalAssets.contains(name) &&
        !(requireSignature && name == kSignedSumsAsset);
    if (size == null) {
      if (!optional) {
        out.add('$name is missing');
      }
    } else if (size <= 0 || size > kMaxAssetBytes) {
      out.add('$name has $size bytes (the app takes 1 to $kMaxAssetBytes)');
    }
  }
  return out;
}

/// [pubspec] with `version: <version>+<build>`.
String bumpPubspec(String pubspec, String version, int build) {
  // Spaces, never line breaks, around the value: `\s*` before `$` would
  // take the empty line after it too.
  final RegExp line = RegExp(r'^version:[ \t]*\S+[ \t]*$', multiLine: true);
  if (!line.hasMatch(pubspec)) {
    throw const FormatException('pubspec.yaml has no "version:" line');
  }
  return pubspec.replaceFirst(line, 'version: $version+$build');
}

/// The version and build of [pubspec] (`version: 1.11.0+11`).
(String, int) pubspecVersion(String pubspec) {
  final RegExpMatch? m = RegExp(
    r'^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*\r?$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (m == null) {
    throw const FormatException('pubspec.yaml: no "version: x.y.z+n"');
  }
  return (m.group(1)!, int.parse(m.group(2)!));
}

/// lib/src/app/app_version.dart with [version] and [build].
String bumpAppVersion(String source, String version, int build) {
  final RegExp name = RegExp(r"const String kAppVersion = '[^']*';");
  final RegExp number = RegExp(r'const int kAppBuild = \d+;');
  if (!name.hasMatch(source) || !number.hasMatch(source)) {
    throw const FormatException(
      'app_version.dart: kAppVersion / kAppBuild not found',
    );
  }
  return source
      .replaceFirst(name, "const String kAppVersion = '$version';")
      .replaceFirst(number, 'const int kAppBuild = $build;');
}

/// The AppStream metadata with [version] of [date] as its newest release.
String bumpMetainfo(String xml, String version, String date) {
  final String entry = '<release version="$version" date="$date"/>';
  if (xml.contains('<release version="$version"')) {
    return xml.replaceFirst(
      RegExp('<release version="${RegExp.escape(version)}"[^>]*/>'),
      entry,
    );
  }
  final RegExpMatch? m = RegExp(r'(\s*)<releases>').firstMatch(xml);
  if (m == null) {
    throw const FormatException('metainfo: no <releases>');
  }
  final String indent = '${m.group(1)!.replaceAll('\n', '')}  ';
  return xml.replaceFirst('<releases>', '<releases>\n$indent$entry');
}

/// CHANGELOG.md with "## Unreleased" renamed to `## <version> — <date>`
/// (dd.mm.yyyy, as the earlier entries) and a new empty "## Unreleased"
/// above it.
String moveUnreleased(String changelog, String version, DateTime date) {
  const String heading = '## Unreleased';
  final int at = changelog.indexOf('\n$heading\n');
  if (at < 0) {
    throw const FormatException('CHANGELOG.md has no "## Unreleased" section');
  }
  String two(int n) => n.toString().padLeft(2, '0');
  final String day = '${two(date.day)}.${two(date.month)}.${date.year}';
  return '${changelog.substring(0, at)}\n$heading\n\n'
      '## $version — $day\n'
      '${changelog.substring(at + heading.length + 2)}';
}

/// The entries of `const List<String> [name] = <String>[...];` in [source]
/// (empty when the list is empty or missing).
List<String> constStringList(String source, String name) {
  final RegExpMatch? m = RegExp(
    '$name\\s*=\\s*<String>\\[(.*?)\\]\\s*;',
    dotAll: true,
  ).firstMatch(source);
  if (m == null) {
    return const <String>[];
  }
  return <String>[
    for (final RegExpMatch e in RegExp(r"'([^']*)'").allMatches(m.group(1)!))
      if (e.group(1)!.trim().isNotEmpty) e.group(1)!.trim(),
  ];
}

/// The release signing keys the app pins: kReleaseMaintainers in
/// [releaseDart] (lib/src/features/update/release.dart).
List<String> pinnedReleaseKeys(String releaseDart) =>
    constStringList(releaseDart, 'kReleaseMaintainers');

/// Why a signed file whose signatures by [signers] hold (both halves) is
/// not one the app built from this tree accepts: it pins no release key at
/// all ([pinned] is empty, so its computers would take an update whose
/// SHA256SUMS nobody signed), or fewer than [needed] of [signers] are
/// pinned (the key in CI is not the one in the app, so every computer
/// would refuse the update). [needed]: 1 for SHA256SUMS.sig, 2 for a
/// release for network updates or a canary (kReleaseThreshold).
List<String> pinnedSignatureProblems({
  required List<String> signers,
  required List<String> pinned,
  int needed = 1,
}) {
  if (pinned.isEmpty) {
    return <String>[
      'kReleaseMaintainers is empty: pin the release signing key '
          '(dart run tool/zen_release.dart maintainers --write <id>; '
          'docs/RELEASES.md, 8.6)',
    ];
  }
  final Set<String> pins = pinned.toSet();
  final int trusted = signers.toSet().where(pins.contains).length;
  return <String>[
    if (trusted < needed)
      'signed by $trusted of the keys the app pins (kReleaseMaintainers), '
          '$needed needed; valid signatures by: '
          '${signers.isEmpty ? 'none' : signers.join(', ')}',
  ];
}

/// Why a release must not be prepared yet: the app does not pin the keys
/// its updates are checked with ([releaseDart] is
/// lib/src/features/update/release.dart, [apkSignatureDart]
/// lib/src/features/update/apk_signature.dart). Without
/// kReleaseMaintainers the computers accept an update whose SHA256SUMS
/// nobody signed; without kOfficialApkCertificatesSha256 a computer
/// cannot tell the official APK from another one ("Podaj dalej") and the
/// install page shows no fingerprint.
List<String> pinnedKeyProblems({
  required String releaseDart,
  required String apkSignatureDart,
}) => <String>[
  if (constStringList(releaseDart, 'kReleaseMaintainers').isEmpty)
    'kReleaseMaintainers is empty: pin the release signing key '
        '(dart run tool/zen_release.dart keygen; docs/RELEASES.md, 8.6)',
  if (constStringList(
    apkSignatureDart,
    'kOfficialApkCertificatesSha256',
  ).isEmpty)
    'kOfficialApkCertificatesSha256 is empty: pin the APK certificate '
        '(dart run tool/zen_release.dart fingerprint --keystore <jks> --write)',
];
