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

/// The iPhone file: the SideStore / AltStore and Scarlet sources (apps.json,
/// scarlet.json) and the install page point to it.
const String kIpaAsset = 'Zen-unsigned.ipa';

/// The sums every update is checked against (sha256SumsUri).
const String kSumsAsset = 'SHA256SUMS';

/// The maintainers' signature of [kSumsAsset] (kSignedSumsAssetName).
const String kSignedSumsAsset = 'SHA256SUMS.sig';

/// The short note about what is new in the version (kWhatsNewAssetName in
/// lib/src/features/update/whats_new.dart), made from CHANGELOG.md by
/// `tool/release.dart whats-new` and listed in SHA256SUMS like every file.
const String kWhatsNewAsset = 'whats-new.json';

/// Files a release may lack without breaking an update: the Windows ARM64
/// build is not required yet (release.yml), the signature exists only
/// when the signing key is set up (required once the app pins a key), and
/// without the note the notice shows the version alone.
const Set<String> kOptionalAssets = <String>{
  'Zen-Windows-arm64.zip',
  kSignedSumsAsset,
  kWhatsNewAsset,
};

/// Every file name the app or the install page relies on.
List<String> get kContractAssets => <String>[
  ...kUpdateAssets,
  kIpaAsset,
  kSumsAsset,
  kSignedSumsAsset,
  kWhatsNewAsset,
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
  if (body.contains('dist/$kWhatsNewAsset')) {
    names.add(kWhatsNewAsset);
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

/// The file in every Windows and Linux release folder that lists what the
/// folder holds (kAppFolderMarker in
/// lib/src/features/update/github_update_installer.dart): the app updates
/// itself in place only in a folder that holds exactly that.
const String kAppFolderMarker = 'zen-app.marker';

/// The first line of [kAppFolderMarker] (kAppFolderMarkerHeader).
const String kAppFolderMarkerHeader = 'zen-app 1';

/// What is wrong with how [releaseYml] packs the computer files: each
/// Windows zip must hold one `Zen` folder (never loose files, which
/// "Extract here" would spill into Downloads), and the Windows zips and the
/// Linux tar.gz must carry [kAppFolderMarker], written in the step that
/// packs them.
List<String> desktopArchiveProblems(String releaseYml) {
  final List<String> lines = <String>[
    for (final String l in const LineSplitter().convert(releaseYml))
      if (!l.trimLeft().startsWith('#')) l,
  ];
  // The lines of the step (from its `- name:` or `- uses:`) up to [end].
  List<String> stepOf(int end) {
    int start = end;
    final RegExp stepStart = RegExp(r'^\s*- (name|uses):');
    while (start > 0 && !stepStart.hasMatch(lines[start])) {
      start--;
    }
    return lines.sublist(start, end + 1);
  }

  bool writesMarker(List<String> step) => step.any(
    (String l) =>
        l.contains(kAppFolderMarker) && l.contains(kAppFolderMarkerHeader),
  );
  final List<String> out = <String>[];
  for (final String zip in <String>[
    'Zen-Windows.zip',
    'Zen-Windows-arm64.zip',
  ]) {
    final int at = lines.indexWhere(
      (String l) => l.contains('Compress-Archive') && l.contains('dist/$zip'),
    );
    if (at < 0) {
      out.add('release.yml does not pack $zip with Compress-Archive');
      continue;
    }
    final List<String> step = stepOf(at);
    if (RegExp(r'-Path\s+\S*\*').hasMatch(lines[at]) ||
        !step.any((String l) => RegExp(r"[/\\]Zen'").hasMatch(l))) {
      out.add('$zip must hold one Zen folder, not loose files');
    }
    if (!writesMarker(step)) {
      out.add('$zip carries no $kAppFolderMarker');
    }
  }
  final int tar = lines.indexWhere(
    (String l) => l.contains(r'dist/Zen-Linux-$ARCH.tar.gz'),
  );
  if (tar < 0) {
    out.add('release.yml does not pack Zen-Linux-\$ARCH.tar.gz');
  } else {
    final List<String> step = stepOf(tar);
    if (!step.any((String l) => l.contains("'s,^bundle,Zen,'"))) {
      out.add('the Linux tar.gz must hold one Zen folder');
    }
    if (!writesMarker(step)) {
      out.add('the Linux tar.gz carries no $kAppFolderMarker');
    }
  }
  return out;
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
  final File note = File('${dir.path}/$kWhatsNewAsset');
  if (note.existsSync()) {
    out.addAll(whatsNewProblems(note.readAsStringSync(), version: version));
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

/// The heading, inside a version's part of CHANGELOG.md, of the short note
/// the app shows with the update notice (docs/RELEASES.md, "What's new").
const String kWhatsNewHeading = "### What's new";

/// Most lines of the note per language (kMaxWhatsNewLines).
const int kMaxWhatsNewLines = 3;

/// Most characters of one line (kMaxWhatsNewLineLength).
const int kMaxWhatsNewLineLength = 160;

/// The language every note has; the app falls back to it.
const String kWhatsNewFallbackLanguage = 'en';

/// A line of the note: `- [en] Text` (a two-letter language code).
final RegExp _whatsNewLine = RegExp(r'^- \[([a-z]{2})\] (.*)$');

/// What a line of the note must not hold, exactly as the app refuses it
/// (isPlainWhatsNewLine): control characters, invisible format marks,
/// links or anything that looks like a domain, Markdown or HTML.
final RegExp _notPlainWhatsNew = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u2028\u2029*`<>\[\]]|\p{Cf}|://|www\.'
  r'|https?:|[\p{L}\p{N}_-]\.\p{L}{2,}',
  caseSensitive: false,
  unicode: true,
);

/// Why [text] cannot be a line of the note, or null when it can.
String? whatsNewLineProblem(String text) {
  if (text.isEmpty || text.trim() != text) {
    return 'is empty or starts or ends with a space';
  }
  if (text.length > kMaxWhatsNewLineLength) {
    return 'has ${text.length} characters (at most $kMaxWhatsNewLineLength)';
  }
  if (_notPlainWhatsNew.hasMatch(text)) {
    return 'is not plain text (no links or domains, invisible marks, *, `, '
        '<, >, [ or ])';
  }
  return null;
}

/// The "### What's new" note of [version]'s part of [changelog] (null:
/// "## Unreleased"): language code → lines, in order, and what is wrong
/// with it. Every non-empty line of the note is `- [xx] Text`; English is
/// required (1 to [kMaxWhatsNewLines] lines), other languages optional
/// with the same limit. [required]: a missing note is a problem too.
({Map<String, List<String>> lines, List<String> problems}) whatsNewSection(
  String changelog, {
  String? version,
  bool required = true,
}) {
  final String part = version ?? 'Unreleased';
  final List<String> rows = const LineSplitter().convert(changelog);
  final int start = rows.indexWhere(
    (String r) =>
        r == '## $part' || (version != null && r.startsWith('## $version ')),
  );
  final Map<String, List<String>> lines = <String, List<String>>{};
  final List<String> problems = <String>[];
  if (start < 0) {
    return (
      lines: lines,
      problems: <String>['CHANGELOG.md has no "## $part" part'],
    );
  }
  int at = start + 1;
  while (at < rows.length &&
      !rows[at].startsWith('## ') &&
      rows[at].trim() != kWhatsNewHeading) {
    at++;
  }
  if (at >= rows.length || rows[at].startsWith('## ')) {
    if (required) {
      problems.add('"## $part" in CHANGELOG.md has no "$kWhatsNewHeading"');
    }
    return (lines: lines, problems: problems);
  }
  for (at++; at < rows.length && !rows[at].startsWith('#'); at++) {
    final String row = rows[at].trimRight();
    if (row.trim().isEmpty) {
      continue;
    }
    final RegExpMatch? m = _whatsNewLine.firstMatch(row);
    if (m == null) {
      problems.add('$kWhatsNewHeading: "$row" is not "- [en] Text"');
      continue;
    }
    final String text = m.group(2)!;
    final String? problem = whatsNewLineProblem(text);
    if (problem != null) {
      problems.add('$kWhatsNewHeading: "$text" $problem');
      continue;
    }
    (lines[m.group(1)!] ??= <String>[]).add(text);
  }
  final List<String>? english = lines[kWhatsNewFallbackLanguage];
  if (english == null || english.isEmpty) {
    problems.add(
      '$kWhatsNewHeading of "$part" has no English line '
      '("- [$kWhatsNewFallbackLanguage] …")',
    );
  }
  lines.forEach((String language, List<String> list) {
    if (list.length > kMaxWhatsNewLines) {
      problems.add(
        '$kWhatsNewHeading of "$part" has ${list.length} [$language] lines '
        '(at most $kMaxWhatsNewLines)',
      );
    }
  });
  return (lines: lines, problems: problems);
}

/// The text of [kWhatsNewAsset] for [version] with [lines] (as the app
/// reads it, WhatsNew.fromJson).
String whatsNewJson(String version, Map<String, List<String>> lines) {
  final String json = jsonEncode(<String, Object?>{
    't': 'zen_whats_new',
    'app': 'zen',
    'version': version,
    'lines': lines,
  });
  return '$json\n';
}

/// What is wrong with the text of a [kWhatsNewAsset] for [version].
List<String> whatsNewProblems(String text, {required String version}) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    return <String>['$kWhatsNewAsset is not JSON: ${e.message}'];
  }
  if (json is! Map ||
      json['t'] != 'zen_whats_new' ||
      json['app'] != 'zen' ||
      json['lines'] is! Map) {
    return <String>['$kWhatsNewAsset is not a "zen_whats_new" note of "zen"'];
  }
  final List<String> out = <String>[
    if (json['version'] != version)
      '$kWhatsNewAsset is the note of ${json['version']}, not $version',
  ];
  final Map<dynamic, dynamic> lines = json['lines'] as Map<dynamic, dynamic>;
  if (lines[kWhatsNewFallbackLanguage] is! List) {
    out.add('$kWhatsNewAsset has no English lines');
  }
  lines.forEach((Object? language, Object? list) {
    if (language is! String ||
        !RegExp(r'^[a-z]{2}$').hasMatch(language) ||
        list is! List ||
        list.isEmpty ||
        list.length > kMaxWhatsNewLines) {
      out.add('$kWhatsNewAsset: the lines of "$language" are malformed');
      return;
    }
    for (final Object? line in list) {
      final String? problem = line is String
          ? whatsNewLineProblem(line)
          : 'is not text';
      if (problem != null) {
        out.add('$kWhatsNewAsset: "$line" $problem');
      }
    }
  });
  return out;
}

/// The entries of `const List<String> [name] = <String>[...];` in [source]
/// as the compiler reads them: comments (`//`, `/* */`) are skipped, so a
/// commented-out key never counts; adjacent literals join; entries are
/// trimmed and empty ones left out. Empty when the list is empty or
/// missing. Throws a [FormatException] when an entry is not a plain string
/// literal (an interpolation, another constant): a check must never guess
/// what the app holds.
List<String> constStringList(String source, String name) {
  final String clean = stripDartComments(source);
  final RegExpMatch? m = RegExp(
    '\\b${RegExp.escape(name)}\\s*=\\s*<String>\\s*\\[',
  ).firstMatch(clean);
  if (m == null) {
    return const <String>[];
  }
  return _DartStringList(clean, name, m.end).read();
}

/// Where `const List<String> [name] = <String>[...];` is in [source]
/// (start, end), not counting a commented-out one; null when it is not
/// there. Throws as [constStringList].
(int, int)? constStringListSpan(String source, String name) {
  final String clean = stripDartComments(source);
  final RegExpMatch? m = RegExp(
    'const\\s+List<String>\\s+${RegExp.escape(name)}\\s*=\\s*<String>\\s*\\[',
  ).firstMatch(clean);
  if (m == null) {
    return null;
  }
  final _DartStringList list = _DartStringList(clean, name, m.end)..read();
  final Match? end = RegExp(r'\s*;').matchAsPrefix(clean, list.at);
  return end == null ? null : (m.start, end.end);
}

/// [source] (Dart) with every comment (`//`, `/* */`, nested) blanked out,
/// line breaks and string literals (with their interpolations) kept. Of
/// the same length, so a position in it is the same in [source].
String stripDartComments(String source) => _DartComments(source).strip();

final class _DartComments {
  _DartComments(this.source) : _out = source.codeUnits.toList();

  final String source;
  final List<int> _out;

  static final RegExp _word = RegExp(r'[A-Za-z0-9_$]');

  String strip() {
    _code(0, interpolation: false);
    return String.fromCharCodes(_out);
  }

  void _blank(int start, int end) {
    for (int k = start; k < end; k++) {
      if (_out[k] != 0x0A) {
        _out[k] = 0x20;
      }
    }
  }

  /// Code from [start] to the end of [source], or to the `}` that closes an
  /// [interpolation]; returns the position after it.
  int _code(int start, {required bool interpolation}) {
    final int n = source.length;
    int i = start;
    int depth = 0;
    while (i < n) {
      final String c = source[i];
      if (source.startsWith('//', i)) {
        final int end = source.indexOf('\n', i);
        final int stop = end < 0 ? n : end;
        _blank(i, stop);
        i = stop;
      } else if (source.startsWith('/*', i)) {
        int j = i + 2;
        int level = 1;
        while (j < n && level > 0) {
          if (source.startsWith('/*', j)) {
            level++;
            j += 2;
          } else if (source.startsWith('*/', j)) {
            level--;
            j += 2;
          } else {
            j++;
          }
        }
        _blank(i, j);
        i = j;
      } else if (c == "'" || c == '"') {
        i = _string(i);
      } else if (c == '{') {
        depth++;
        i++;
      } else if (c == '}') {
        if (interpolation && depth == 0) {
          return i + 1;
        }
        depth--;
        i++;
      } else {
        i++;
      }
    }
    return i;
  }

  /// The string literal whose opening quote is at [start]; returns the
  /// position after it.
  int _string(int start) {
    final int n = source.length;
    final bool raw =
        start > 0 &&
        (source[start - 1] == 'r' || source[start - 1] == 'R') &&
        !(start > 1 && _word.hasMatch(source[start - 2]));
    final String q = source[start];
    final String quote = source.startsWith(q * 3, start) ? q * 3 : q;
    int i = start + quote.length;
    while (i < n) {
      if (source.startsWith(quote, i)) {
        return i + quote.length;
      }
      if (quote.length == 1 && source[i] == '\n') {
        return i;
      }
      if (!raw && source[i] == '\\') {
        i += 2;
      } else if (!raw && source.startsWith(r'${', i)) {
        i = _code(i + 2, interpolation: true);
      } else {
        i++;
      }
    }
    return n;
  }
}

/// Reads a list of string literals from [text] (without comments), from
/// [at], just after its `[`.
final class _DartStringList {
  _DartStringList(this.text, this.name, this.at);

  final String text;
  final String name;

  /// Where reading goes on; after [read], just after the closing `]`.
  int at;

  static const Map<String, String> _escapes = <String, String>{
    'n': '\n',
    'r': '\r',
    't': '\t',
    'b': '\b',
    'f': '\f',
    'v': '\v',
  };

  void _skip() {
    while (at < text.length && text[at].trim().isEmpty) {
      at++;
    }
  }

  bool _quoteAt(int i) => i < text.length && (text[i] == "'" || text[i] == '"');

  bool _startsLiteral() =>
      _quoteAt(at) ||
      (at < text.length &&
          (text[at] == 'r' || text[at] == 'R') &&
          _quoteAt(at + 1));

  String _literal() {
    final bool raw = text[at] == 'r' || text[at] == 'R';
    if (raw) {
      at++;
    }
    final String q = text[at];
    final String quote = text.startsWith(q * 3, at) ? q * 3 : q;
    at += quote.length;
    final StringBuffer value = StringBuffer();
    while (true) {
      if (at >= text.length || (quote.length == 1 && text[at] == '\n')) {
        throw FormatException('$name: an unterminated string');
      }
      if (text.startsWith(quote, at)) {
        at += quote.length;
        return value.toString();
      }
      final String c = text[at];
      if (!raw && c == r'$') {
        throw FormatException('$name: an entry with an interpolation');
      }
      if (!raw && c == '\\') {
        if (at + 1 >= text.length ||
            text[at + 1] == 'x' ||
            text[at + 1] == 'u') {
          throw FormatException('$name: an escape this check does not read');
        }
        value.write(_escapes[text[at + 1]] ?? text[at + 1]);
        at += 2;
        continue;
      }
      value.write(c);
      at++;
    }
  }

  List<String> read() {
    final List<String> values = <String>[];
    while (true) {
      _skip();
      if (at < text.length && text[at] == ']') {
        at++;
        break;
      }
      final StringBuffer entry = StringBuffer();
      bool any = false;
      while (true) {
        _skip();
        if (!_startsLiteral()) {
          break;
        }
        entry.write(_literal());
        any = true;
      }
      if (!any) {
        throw FormatException('$name: an entry that is not a string literal');
      }
      values.add(entry.toString().trim());
      _skip();
      if (at < text.length && text[at] == ',') {
        at++;
      } else if (at < text.length && text[at] == ']') {
        at++;
        break;
      } else {
        throw FormatException('$name: not a list of string literals');
      }
    }
    return <String>[
      for (final String v in values)
        if (v.isNotEmpty) v,
    ];
  }
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

/// Why APKs signed with the certificates [fingerprints] (SHA-256, any
/// case, with or without colons) are not ones the app built from this tree
/// accepts: it pins no APK certificate ([pinned] is
/// kOfficialApkCertificatesSha256), or one of them is not pinned (the
/// keystore in CI is not the one in the app: phones would refuse the
/// update, and the install page would show another fingerprint).
List<String> pinnedCertificateProblems({
  required List<String> fingerprints,
  required List<String> pinned,
}) {
  String hex(String v) => v.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
  final Set<String> pins = <String>{for (final String p in pinned) hex(p)};
  if (pins.isEmpty) {
    return <String>[
      'kOfficialApkCertificatesSha256 is empty: pin the APK certificate '
          '(dart run tool/zen_release.dart fingerprint --keystore <jks> '
          '--write)',
    ];
  }
  return <String>[
    if (fingerprints.isEmpty) 'no APK certificate to compare',
    for (final String f in fingerprints)
      if (!pins.contains(hex(f)))
        'the APKs are signed with $f, which kOfficialApkCertificatesSha256 '
            'does not pin (${pins.join(', ')})',
  ];
}

/// What the native builds do not pin yet, each with where its pin comes
/// from: the Gradle distribution ([gradleWrapperProperties] without
/// `distributionSha256Sum`), the iPhone and Mac pods (no
/// `ios/Podfile.lock`, `macos/Podfile.lock`: CocoaPods resolves them anew
/// on every build) and the WebRTC framework they download
/// ([webrtcSdkPins], tool/ci/webrtc_sdk.sha256, without a line).
List<String> nativePinProblems({
  required String gradleWrapperProperties,
  required bool iosPodfileLock,
  required bool macosPodfileLock,
  required String webrtcSdkPins,
}) => <String>[
  if (!RegExp(
    r'^[ \t]*distributionSha256Sum[ \t]*=[ \t]*[0-9a-fA-F]{64}[ \t]*\r?$',
    multiLine: true,
  ).hasMatch(gradleWrapperProperties))
    'android/gradle/wrapper/gradle-wrapper.properties has no '
        'distributionSha256Sum (the SHA-256 of its Gradle zip, from '
        'https://gradle.org/release-checksums/)',
  if (!iosPodfileLock)
    'ios/Podfile.lock is not in the repository (commit the artifact '
        'podfile-lock-ios of an iOS build)',
  if (!macosPodfileLock)
    'macos/Podfile.lock is not in the repository (commit the artifact '
        'podfile-lock-macos of a release build)',
  if (!RegExp(
    r'^[0-9a-f]{64}[ \t]+\S+/WebRTC\.xcframework[ \t]*\r?$',
    multiLine: true,
  ).hasMatch(webrtcSdkPins))
    'tool/ci/webrtc_sdk.sha256 pins no WebRTC.xcframework (python3 '
        'tool/ci/check_webrtc_sdk.py --hash on the official one)',
];

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
