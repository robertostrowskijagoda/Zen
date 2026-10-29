import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/about/go_licenses.dart';

void main() {
  List<GoLicenseIndexEntry> readIndex() =>
      parseGoLicenseIndex(File('$kGoLicensesDir/index.txt').readAsStringSync());

  test('the index parses tab-separated lines and skips comments', () {
    final List<GoLicenseIndexEntry> entries = parseGoLicenseIndex(
      '# comment\n\nexample.com/a\tv1.0.0\ta.txt\thttps://example.com/a\n'
      'broken line\n',
    );
    expect(entries, hasLength(1));
    expect(entries.single.module, 'example.com/a');
    expect(entries.single.version, 'v1.0.0');
    expect(entries.single.file, 'a.txt');
    expect(entries.single.source, 'https://example.com/a');
  });

  test('every Go module of the bridge has its license text', () {
    final Map<String, GoLicenseIndexEntry> byModule =
        <String, GoLicenseIndexEntry>{
          for (final GoLicenseIndexEntry e in readIndex()) e.module: e,
        };
    expect(byModule, contains('Go standard library'));
    final RegExp requirement = RegExp(
      r'^\s*(?:require\s+)?([a-z0-9.-]+\.[a-z]+/\S+)\s+(v\S+)',
      multiLine: true,
    );
    final String goMod = File(
      'native/yggdrasil_bridge/go.mod',
    ).readAsStringSync();
    final Iterable<RegExpMatch> required = requirement.allMatches(goMod);
    expect(required, isNotEmpty);
    for (final RegExpMatch m in required) {
      final GoLicenseIndexEntry? entry = byModule[m.group(1)];
      expect(
        entry?.version,
        m.group(2),
        reason:
            '${m.group(1)} changed in go.mod: run dart run tool/go_licenses.dart',
      );
    }
    for (final GoLicenseIndexEntry entry in byModule.values) {
      final File file = File('$kGoLicensesDir/${entry.file}');
      expect(file.existsSync(), isTrue, reason: entry.file);
      expect(file.readAsStringSync().trim(), isNotEmpty, reason: entry.file);
    }
  });

  test('the native index parses a file and one or more names', () {
    final List<NativeLicenseIndexEntry> entries = parseNativeLicenseIndex(
      '# comment\n\na.txt\tA\tB\nlonely.txt\n',
    );
    expect(entries, hasLength(1));
    expect(entries.single.file, 'a.txt');
    expect(entries.single.names, <String>['A', 'B']);
  });

  test('every native license text and NOTICE is there and bundled', () {
    final List<NativeLicenseIndexEntry> entries = parseNativeLicenseIndex(
      File('$kNativeLicensesDir/index.txt').readAsStringSync(),
    );
    expect(entries, isNotEmpty);
    for (final NativeLicenseIndexEntry entry in entries) {
      final File file = File('$kNativeLicensesDir/${entry.file}');
      expect(file.existsSync(), isTrue, reason: entry.file);
      expect(file.readAsStringSync().trim(), isNotEmpty, reason: entry.file);
    }
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- $kNativeLicensesDir/'));
    expect(pubspec, contains('- $kNoticePath\n'));
    expect(File(kNoticePath).readAsStringSync(), contains('section 7'));
  });

  test('every bundled native license text is listed in the index', () {
    // A text left behind for a removed component (for example a non-free
    // library) would still ship in the app.
    final Set<String> listed = <String>{
      for (final NativeLicenseIndexEntry entry in parseNativeLicenseIndex(
        File('$kNativeLicensesDir/index.txt').readAsStringSync(),
      ))
        entry.file,
    };
    final List<String> files = <String>[
      for (final FileSystemEntity e in Directory(kNativeLicensesDir).listSync())
        if (e is File) e.uri.pathSegments.last,
    ]..remove('index.txt');
    expect(files, isNotEmpty);
    for (final String file in files) {
      expect(listed, contains(file), reason: file);
    }
  });

  test('NOTICE keeps its additional terms within GPL section 7', () {
    final String notice = File(kNoticePath).readAsStringSync();
    expect(notice, contains('SPDX-License-Identifier: GPL-3.0-only'));
    for (final String kind in <String>['7(b)', '7(c)', '7(e)']) {
      expect(notice, contains('section $kind'), reason: kind);
    }
    expect(notice, contains('Zen by Robert Ostrowski-Jagoda'));
    // The donation link is not a licence condition (FSF: links are not
    // author attributions under section 7(b)).
    expect(notice, contains('The donation line is not a condition'));
    expect(notice, contains('additional permission'));
  });

  test('every bundled font family is in the font license file', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final String ofl = File(kFontLicensePath).readAsStringSync();
    final Iterable<RegExpMatch> families = RegExp(
      r'^\s*- family:\s*(.+?)\s*$',
      multiLine: true,
    ).allMatches(pubspec);
    expect(families, isNotEmpty);
    // A family is covered when the combined file names its authors ("The X
    // Project Authors" or "The X Authors") or carries the first line of the
    // licence shipped next to the font (holders like TypeTogether or
    // Astigmatic name no project).
    final Map<String, String> ownLines = <String, String>{
      for (final File f
          in Directory('assets/fonts')
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('-OFL.txt')))
        f.uri.pathSegments.last.replaceAll('-OFL.txt', ''): f
            .readAsLinesSync()
            .first
            .trim(),
    };
    for (final RegExpMatch m in families) {
      final String family = m.group(1)!;
      final String? own = ownLines[family.replaceAll(' ', '')];
      expect(
        ofl.contains('The $family Project Authors') ||
            ofl.contains('The $family Authors') ||
            (own != null && ofl.contains(own)),
        isTrue,
        reason: '$family: add its copyright line to $kFontLicensePath',
      );
    }
  });
}
