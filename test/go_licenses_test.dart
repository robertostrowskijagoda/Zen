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
}
