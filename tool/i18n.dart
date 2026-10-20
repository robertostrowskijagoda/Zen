// Keeps the translations in assets/i18n/<code>.json in step with the Polish
// texts in the code: every t('…') and tn(n, one: '…', few: '…', many: '…')
// call in lib/ (see lib/src/app/i18n/zen_i18n.dart).
//
//   dart run tool/i18n.dart           checks: calls whose text is not a plain
//                                     string literal, and for every
//                                     translation file the missing and stale
//                                     texts and placeholder mismatches
//                                     (exit code 1 on any problem)
//   dart run tool/i18n.dart --keys    prints every text as JSON:
//                                     [{"key": …, "plural": {"one": …,
//                                     "few": …, "many": …}, "files": […]}]
//                                     ("plural" only for tn() texts)
//   dart run tool/i18n.dart --prune   drops the texts the code no longer
//                                     has and sorts every file by key
//
// Options: --verbose (-v) lists every missing and stale text instead of
// the first few; --root=<dir> is the project folder (default: the current
// one).
//
// A translation file maps the Polish text to its translation, with the same
// {name} placeholders. A tn() text is stored under its `many` form as an
// object of the language's CLDR plural forms (at least "other"):
//
//   "{n} osób": {"one": "{n} person", "other": "{n} people"}
import 'dart:convert';
import 'dart:io';

import 'i18n/scanner.dart';

const String _usage = '''
Usage: dart run tool/i18n.dart [--keys | --prune] [--verbose] [--root=<dir>]

  (no command)  check the translations (exit code 1 on problems)
  --keys        print every text of the code as JSON
  --prune       drop stale texts from assets/i18n/*.json and sort the files
''';

/// How many missing or stale texts a check lists per file without
/// --verbose.
const int _listLimit = 15;

void main(List<String> arguments) {
  bool keys = false;
  bool prune = false;
  bool verbose = false;
  String root = Directory.current.path;
  for (final String argument in arguments) {
    if (argument == '--keys') {
      keys = true;
    } else if (argument == '--prune') {
      prune = true;
    } else if (argument == '--verbose' || argument == '-v') {
      verbose = true;
    } else if (argument.startsWith('--root=')) {
      root = argument.substring('--root='.length);
    } else if (argument == '--help' || argument == '-h') {
      stdout.write(_usage);
      return;
    } else {
      stderr.writeln('Unknown option: $argument\n');
      stderr.write(_usage);
      exitCode = 64;
      return;
    }
  }
  if (keys && prune) {
    stderr.writeln('--keys and --prune do not go together.');
    exitCode = 64;
    return;
  }
  final Directory project = Directory(root);
  final Directory lib = Directory(_join(project.path, 'lib'));
  if (!lib.existsSync() ||
      !File(_join(project.path, 'pubspec.yaml')).existsSync()) {
    stderr.writeln(
      'No lib/ and pubspec.yaml in ${project.absolute.path}: run it from the '
      'project folder or pass --root=<dir>.',
    );
    exitCode = 2;
    return;
  }
  final I18nScan scan = scanI18nDirectory(lib, root: project);
  if (keys) {
    _printKeys(scan);
  } else if (prune) {
    _prune(scan, project);
  } else {
    _check(scan, project, verbose: verbose);
  }
}

void _printKeys(I18nScan scan) {
  _printIssues(scan, toStderr: true);
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(<Object>[
      for (final I18nEntry entry in scan.entries.values) entry.toJson(),
    ]),
  );
  if (scan.errors.isNotEmpty) {
    exitCode = 1;
  }
}

void _check(I18nScan scan, Directory project, {required bool verbose}) {
  bool problems = _printIssues(scan, toStderr: false);
  final int plurals = scan.entries.values
      .where((I18nEntry entry) => entry.plural != null)
      .length;
  stdout.writeln(
    '${scan.entries.length} texts ($plurals plural) in '
    '${scan.fileCount} files.',
  );
  final List<File> files = _translationFiles(project);
  if (files.isEmpty) {
    stdout.writeln('No translation files in assets/i18n/.');
  }
  for (final File file in files) {
    final String name = 'assets/i18n/${_baseName(file.path)}';
    final Map<String, Object?>? translations = _readTranslations(file);
    if (translations == null) {
      problems = true;
      continue;
    }
    final I18nFileReport report = checkI18nTranslations(scan, translations);
    if (report.isClean) {
      stdout.writeln('$name: OK (${translations.length} texts)');
      continue;
    }
    problems = true;
    stdout.writeln(
      '$name: ${report.missing.length} missing, ${report.stale.length} '
      'stale, ${report.mismatched.length} not matching',
    );
    _printList('missing', report.missing, verbose: verbose);
    _printList('stale', report.stale, verbose: verbose);
    for (final String mismatch in report.mismatched) {
      stdout.writeln('  $mismatch');
    }
  }
  if (problems) {
    stdout.writeln(
      'Problems found. `dart run tool/i18n.dart --keys` lists the texts; '
      '`--prune` drops stale ones.',
    );
    exitCode = 1;
  }
}

void _prune(I18nScan scan, Directory project) {
  if (_printIssues(scan, toStderr: true)) {
    stderr.writeln(
      'Not pruning: fix the errors above first (a text the scan missed '
      'would lose its translations).',
    );
    exitCode = 1;
    return;
  }
  for (final File file in _translationFiles(project)) {
    final String name = 'assets/i18n/${_baseName(file.path)}';
    final Map<String, Object?>? translations = _readTranslations(file);
    if (translations == null) {
      exitCode = 1;
      continue;
    }
    final Map<String, Object?> pruned = pruneI18nTranslations(
      scan,
      translations,
    );
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(pruned)}\n',
    );
    final int dropped = translations.length - pruned.length;
    stdout.writeln(
      '$name: ${pruned.length} texts'
      '${dropped == 0 ? '' : ', $dropped stale dropped'}',
    );
  }
}

/// Prints the scan's errors and warnings; true when there were errors.
bool _printIssues(I18nScan scan, {required bool toStderr}) {
  final IOSink out = toStderr ? stderr : stdout;
  for (final I18nIssue issue in scan.errors) {
    out.writeln('error: $issue');
  }
  for (final I18nIssue issue in scan.warnings) {
    out.writeln('warning: $issue');
  }
  return scan.errors.isNotEmpty;
}

void _printList(String label, List<String> keys, {required bool verbose}) {
  final int shown = verbose || keys.length <= _listLimit
      ? keys.length
      : _listLimit;
  for (final String key in keys.take(shown)) {
    stdout.writeln('  $label: ${jsonEncode(key)}');
  }
  if (shown < keys.length) {
    stdout.writeln('  … ${keys.length - shown} more $label (--verbose)');
  }
}

List<File> _translationFiles(Directory project) {
  final Directory folder = Directory(_join(project.path, 'assets/i18n'));
  if (!folder.existsSync()) {
    return <File>[];
  }
  return folder
      .listSync()
      .whereType<File>()
      .where((File file) => file.path.endsWith('.json'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
}

Map<String, Object?>? _readTranslations(File file) {
  final String name = 'assets/i18n/${_baseName(file.path)}';
  try {
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    stderr.writeln('$name: not a JSON object');
  } on FormatException catch (error) {
    stderr.writeln('$name: broken JSON: ${error.message}');
  } on FileSystemException catch (error) {
    stderr.writeln('$name: cannot read: ${error.message}');
  }
  return null;
}

String _join(String folder, String relative) =>
    '$folder${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}';

String _baseName(String path) =>
    path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
