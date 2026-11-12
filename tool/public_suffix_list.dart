// Refreshes the Public Suffix List the password autofill tells one site
// from another by, and the list's own test vectors:
//
//   dart run tool/public_suffix_list.dart [--from <public_suffix_list.dat>
//       --tests-from <test_psl.txt>]
//
// Downloads https://publicsuffix.org/list/public_suffix_list.dat (the only
// address its maintainers ask to take it from) and
// https://raw.githubusercontent.com/publicsuffix/list/master/tests/test_psl.txt
// (or reads them from --from and --tests-from), and writes:
// * lib/src/features/passwords/public_suffix_rules.dart: the rules without
//   the comments (the ICANN part, then the private one), the list's
//   VERSION and COMMIT, and its licence notice (MPL 2.0);
// * test/fixtures/public_suffix/test_psl.txt: the test vectors as they are
//   (public domain), read by test/password_public_suffix_test.dart.
// Run it before a release: `release.dart prepare` stops when the list is
// older than it allows (`publicSuffixListAgeProblem`). Review the diff.
import 'dart:convert';
import 'dart:io';

const String _listUrl = 'https://publicsuffix.org/list/public_suffix_list.dat';
const String _testsUrl =
    'https://raw.githubusercontent.com/publicsuffix/list/master/tests/test_psl.txt';
const String _rulesPath = 'lib/src/features/passwords/public_suffix_rules.dart';
const String _testsPath = 'test/fixtures/public_suffix/test_psl.txt';

Future<String> _fetch(String url) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);
  try {
    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    final HttpClientResponse response = await request.close().timeout(
      const Duration(minutes: 2),
    );
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    return await utf8.decodeStream(response);
  } finally {
    client.close(force: true);
  }
}

String? _option(List<String> args, String name) {
  final int at = args.indexOf('--$name');
  return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
}

/// The Dart source of the rules of [list] (the list's text).
String rulesSource(String list) {
  final RegExp version = RegExp(r'^// VERSION: (\S+)', multiLine: true);
  final RegExp commit = RegExp(r'^// COMMIT: (\S+)', multiLine: true);
  final String? v = version.firstMatch(list)?.group(1);
  final String? c = commit.firstMatch(list)?.group(1);
  if (v == null || c == null) {
    throw const FormatException('The list names no VERSION or COMMIT.');
  }
  final List<String> rules = <String>[];
  bool icann = false;
  bool private = false;
  for (final String raw in const LineSplitter().convert(list)) {
    final String line = raw.trim();
    if (line == '// ===BEGIN ICANN DOMAINS===') {
      icann = true;
      rules.add(line);
    } else if (line == '// ===BEGIN PRIVATE DOMAINS===') {
      private = true;
      rules.add(line);
    } else if (line.isNotEmpty && !line.startsWith('//')) {
      if (line.contains("'''") || line.contains(RegExp(r'\s'))) {
        throw FormatException('Not a rule: $line');
      }
      rules.add(line);
    }
  }
  if (!icann || !private || rules.length < 5000) {
    throw const FormatException('The list does not look whole.');
  }
  return '''
// The Public Suffix List, https://publicsuffix.org/list/ (its rules,
// without the comments). Refreshed with `dart run
// tool/public_suffix_list.dart`; not edited by hand.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The list's version (its `VERSION` line, in UTC).
const String kPublicSuffixListVersion = '$v';

/// The list's commit in https://github.com/publicsuffix/list.
const String kPublicSuffixListCommit =
    '$c';

/// Its rules, one per line: the ICANN part, then the private one (a line
/// starting with `//` marks where each begins).
const String kPublicSuffixRules = r\'\'\'
${rules.join('\n')}
\'\'\';
''';
}

Future<void> main(List<String> args) async {
  final String? from = _option(args, 'from');
  final String? testsFrom = _option(args, 'tests-from');
  final String list = from != null
      ? File(from).readAsStringSync()
      : await _fetch(_listUrl);
  final String tests = testsFrom != null
      ? File(testsFrom).readAsStringSync()
      : await _fetch(_testsUrl);
  if (!tests.contains('checkPublicSuffix(')) {
    throw const FormatException('The test vectors do not look whole.');
  }
  File(_rulesPath).writeAsStringSync(rulesSource(list));
  File(_testsPath)
    ..createSync(recursive: true)
    ..writeAsStringSync(tests.replaceAll('\r\n', '\n'));
  stdout.writeln('Wrote $_rulesPath and $_testsPath. Review the diff.');
}
