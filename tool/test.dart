// Runs the app's tests in parallel. `flutter test` compiles the test files
// one after another in a single compiler, so on a computer with many cores
// a plain run waits on that compiler far more than on the tests (more
// --concurrency does not help). This script splits the test files into
// groups of about the same weight and runs one `flutter test` per group at
// the same time, each with its own compiler, then lists what failed.
// Plain Dart, no packages:
//
//   dart run tool/test.dart
//       Every *_test.dart under test/, in parallel groups (by default one
//       per four cores, at least two).
//   dart run tool/test.dart test/chat_test.dart test/wire
//       Only these files and folders.
//   dart run tool/test.dart --groups 6 --concurrency 3
//       Six runs at once, each running three test files at a time.
//   dart run tool/test.dart --shard 2/4 [--results <folder>]
//       Only the second of four parts of the files, in one run: what one
//       CI test job runs. --results writes the JSON reporter's file of
//       every run into the folder (tool/ci/ci_summary.py reads them).
//   dart run tool/test.dart --list [--shard 2/4]
//       The files (of that part) without running them.
//
// Everything after `--` goes to every `flutter test` (for example
// `-- --plain-name "mailbox"`). Runs `flutter pub get` itself only when
// .dart_tool/package_config.json is missing; the runs use --no-pub so
// they never write it at the same time. docs/TESTING.md, "Fast local runs".
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The longest list of files one `flutter test` command line gets: on
/// Windows `flutter` is a batch file and cmd.exe takes at most 8191
/// characters, so a longer group runs as several commands in turn.
const int _maxCommandFiles = 6000;

/// How long each file took in this computer's earlier runs (milliseconds by
/// path, written after every full run): the longest files start first and
/// the groups come out even. Only for local runs.
const String _timesFile = 'build/test_times.json';

/// The same for the longest files only, kept in the repository: what a
/// shard (a CI job) splits by, so that every job of a CI run computes the
/// same lists, and what a first local run starts from. A file it does not
/// name is guessed from its size ([_estimate]). Refresh it from
/// [_timesFile] now and then (the files above 15 seconds).
const String _knownTimesFile = 'tool/test_times.json';

Future<void> main(List<String> args) async {
  final int dashes = args.indexOf('--');
  final List<String> own = dashes < 0 ? args : args.sublist(0, dashes);
  final List<String> passOn = dashes < 0
      ? const <String>[]
      : args.sublist(dashes + 1);
  try {
    exitCode = await _run(own, passOn);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(
      'Usage: dart run tool/test.dart [paths...] [--groups N] '
      '[--concurrency N] [--shard PART/PARTS] [--results <folder>] [--list] '
      '[-- <flutter test options>]',
    );
    exitCode = 64;
  }
}

Future<int> _run(List<String> args, List<String> passOn) async {
  int? groups;
  int? concurrency;
  (int, int)? shard;
  String? results;
  bool list = false;
  final List<String> paths = <String>[];
  for (int i = 0; i < args.length; i++) {
    String value() {
      if (i + 1 >= args.length) {
        throw FormatException('${args[i]} needs a value');
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--groups':
        groups = _positive(value(), '--groups');
      case '--concurrency' || '-j':
        concurrency = _positive(value(), '--concurrency');
      case '--shard':
        final List<String> parts = value().split('/');
        final int? index = parts.length == 2 ? int.tryParse(parts[0]) : null;
        final int? total = parts.length == 2 ? int.tryParse(parts[1]) : null;
        if (index == null || total == null || index < 1 || index > total) {
          throw const FormatException('--shard is PART/PARTS, e.g. 1/4');
        }
        shard = (index, total);
      case '--results':
        results = value();
      case '--list':
        list = true;
      case final String arg when arg.startsWith('-'):
        throw FormatException('Unknown option $arg');
      case final String path:
        paths.add(path);
    }
  }

  List<String> files = _testFiles(paths.isEmpty ? <String>['test'] : paths);
  if (files.isEmpty) {
    throw const FormatException('No *_test.dart files there');
  }
  final Map<String, int> known = _readTimes(_knownTimesFile);
  final Map<String, int> times = shard == null
      ? _readTimes(_timesFile)
      : const <String, int>{};
  int weight(String file) => times[file] ?? known[file] ?? _estimate(file);
  if (shard != null) {
    files = split(files, shard.$2, weight)[shard.$1 - 1];
  }
  if (list) {
    files.forEach(stdout.writeln);
    return 0;
  }
  if (files.isEmpty) {
    stdout.writeln('No test files in this shard.');
    return 0;
  }

  final int cores = Platform.numberOfProcessors;
  // A shard is one run (a CI job has few cores); locally one run per four
  // cores keeps every compiler and the tests busy without swapping.
  final int runs = shard != null
      ? 1
      : (groups ?? (cores ~/ 4).clamp(2, 8)).clamp(1, files.length);
  final int jobs = concurrency ?? (cores ~/ runs).clamp(1, cores);

  if (!File('.dart_tool/package_config.json').existsSync()) {
    final Process pub = await _start(<String>['pub', 'get']);
    unawaited(stdout.addStream(pub.stdout));
    unawaited(stderr.addStream(pub.stderr));
    if (await pub.exitCode != 0) {
      return 1;
    }
  }
  final Directory out = results != null
      ? (Directory(results)..createSync(recursive: true))
      : Directory.systemTemp.createTempSync('zen-test-');
  final String reportPrefix = shard == null
      ? 'run'
      : 'shard-${shard.$1}-of-${shard.$2}';

  final List<List<String>> planned = split(files, runs, weight);
  stdout.writeln(
    '${files.length} test files in ${planned.length} parallel run(s), '
    '$jobs at a time each ($cores cores).',
  );
  final Stopwatch clock = Stopwatch()..start();
  final List<Future<_GroupResult>> running = <Future<_GroupResult>>[
    for (int g = 0; g < planned.length; g++)
      _runGroup(g, planned.length, planned[g], jobs, passOn, out, reportPrefix),
  ];
  final List<_GroupResult> done = await Future.wait(running);

  int passed = 0;
  int failedCount = 0;
  int skipped = 0;
  final List<String> failures = <String>[];
  final Map<String, int> took = <String, int>{};
  bool ok = true;
  for (final _GroupResult r in done) {
    ok = ok && r.ok;
    for (final File f in r.reports) {
      final _Counts c = _Counts.read(f);
      passed += c.passed;
      failedCount += c.failed;
      skipped += c.skipped;
      failures.addAll(c.failures);
      took.addAll(c.took);
    }
  }
  // Only a run without a name filter says how long a whole file takes.
  if (shard == null && passOn.isEmpty) {
    _writeTimes(<String, int>{...times, ...took});
  }
  final String time = (clock.elapsedMilliseconds / 1000).toStringAsFixed(0);
  stdout.writeln('');
  stdout.writeln(
    '$passed passed, $failedCount failed, $skipped skipped in ${time}s.',
  );
  if (failures.isNotEmpty) {
    stdout.writeln('Failed:');
    for (final String f in failures) {
      stdout.writeln('  $f');
    }
  }
  if (results == null) {
    out.deleteSync(recursive: true);
  }
  if (!ok && failures.isEmpty) {
    stdout.writeln('A run failed without a failed test: see its output above.');
  }
  return ok ? 0 : 1;
}

int _positive(String value, String option) {
  final int? n = int.tryParse(value);
  if (n == null || n < 1) {
    throw FormatException('$option takes a number above 0');
  }
  return n;
}

/// The *_test.dart files of [paths] (files or folders), sorted, with
/// forward slashes, so every computer splits them the same way.
List<String> _testFiles(List<String> paths) {
  final Set<String> files = <String>{};
  for (final String path in paths) {
    final String clean = path.replaceAll(r'\', '/');
    if (FileSystemEntity.isDirectorySync(clean)) {
      for (final FileSystemEntity e in Directory(
        clean,
      ).listSync(recursive: true, followLinks: false)) {
        final String p = e.path.replaceAll(r'\', '/');
        if (e is File && p.endsWith('_test.dart')) {
          files.add(p);
        }
      }
    } else if (File(clean).existsSync()) {
      files.add(clean);
    } else {
      throw FormatException('$path does not exist');
    }
  }
  return files.toList()..sort();
}

/// A guess of how long [file] takes, in milliseconds, when no earlier run
/// says: loading it, and about a second per 20 KB of tests.
int _estimate(String file) => 2000 + File(file).lengthSync() ~/ 20;

Map<String, int> _readTimes(String path) {
  try {
    final Object? json = jsonDecode(File(path).readAsStringSync());
    if (json is Map<String, Object?>) {
      return <String, int>{
        for (final MapEntry<String, Object?> e in json.entries)
          if (e.value case final int ms) e.key: ms,
      };
    }
  } on Object {
    // No earlier run (or an unreadable file): estimates only.
  }
  return const <String, int>{};
}

void _writeTimes(Map<String, int> times) {
  try {
    final List<String> names = times.keys.toList()..sort();
    File(_timesFile)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent(
          ' ',
        ).convert(<String, int>{for (final String n in names) n: times[n]!}),
      );
  } on FileSystemException {
    // Only a hint for the next run.
  }
}

/// [files] in [count] lists of about the same total [weight]: the heaviest
/// file first into the lightest list (ties to the first list). Each list is
/// ordered heaviest first, so its longest files start at once instead of
/// last. The same files and weights always give the same lists.
List<List<String>> split(
  List<String> files,
  int count,
  int Function(String) weight,
) {
  final List<(String, int)> weighed = <(String, int)>[
    for (final String f in files) (f, weight(f)),
  ]..sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
  final List<List<String>> lists = <List<String>>[
    for (int i = 0; i < count; i++) <String>[],
  ];
  final List<int> loads = List<int>.filled(count, 0);
  for (final (String file, int w) in weighed) {
    int lightest = 0;
    for (int i = 1; i < count; i++) {
      if (loads[i] < loads[lightest]) {
        lightest = i;
      }
    }
    lists[lightest].add(file);
    loads[lightest] += w;
  }
  return lists;
}

Future<Process> _start(List<String> args) =>
    Process.start('flutter', args, runInShell: Platform.isWindows);

final class _GroupResult {
  _GroupResult(this.ok, this.reports);

  final bool ok;
  final List<File> reports;
}

/// One group: its files in as few `flutter test` commands as the command
/// line allows, one after another; failures only on the screen, every
/// result in a JSON file of [out].
Future<_GroupResult> _runGroup(
  int group,
  int groups,
  List<String> files,
  int jobs,
  List<String> passOn,
  Directory out,
  String reportPrefix,
) async {
  final List<List<String>> commands = <List<String>>[<String>[]];
  int length = 0;
  for (final String f in files) {
    if (length + f.length + 1 > _maxCommandFiles && commands.last.isNotEmpty) {
      commands.add(<String>[]);
      length = 0;
    }
    commands.last.add(f);
    length += f.length + 1;
  }
  final String prefix = groups > 1 ? '[${group + 1}/$groups] ' : '';
  bool ok = true;
  final List<File> reports = <File>[];
  for (int c = 0; c < commands.length; c++) {
    final File report = File('${out.path}/$reportPrefix-$group-$c.json');
    reports.add(report);
    final Process p = await _start(<String>[
      'test',
      '--no-pub',
      '--concurrency',
      '$jobs',
      // One line per failure, not a status line rewritten in place (which
      // several runs at once would garble).
      '--reporter',
      groups > 1 ? 'failures-only' : 'expanded',
      '--file-reporter',
      'json:${report.path}',
      ...passOn,
      ...commands[c],
    ]);
    await Future.wait(<Future<void>>[
      _prefixed(p.stdout, stdout, prefix),
      _prefixed(p.stderr, stderr, prefix),
    ]);
    if (await p.exitCode != 0) {
      ok = false;
    }
  }
  stdout.writeln(
    '${prefix}done (${files.length} files${ok ? '' : ', FAILED'}).',
  );
  return _GroupResult(ok, reports);
}

Future<void> _prefixed(Stream<List<int>> from, IOSink to, String prefix) => from
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter())
    .forEach((String line) => to.writeln('$prefix$line'));

/// [path] (as the JSON reporter writes it, absolute) from its `test/` on.
String _relative(String path) {
  final String p = path.replaceAll(r'\', '/');
  final int at = p.lastIndexOf('/test/');
  return at < 0 ? p : p.substring(at + 1);
}

/// Counts, failed tests and how long each file took (from its first test
/// starting to its last one done) of one JSON reporter file.
final class _Counts {
  _Counts(this.passed, this.failed, this.skipped, this.failures, this.took);

  factory _Counts.read(File file) {
    if (!file.existsSync()) {
      return _Counts(0, 0, 0, const <String>[], const <String, int>{});
    }
    final Map<int, String> suites = <int, String>{};
    final Map<int, String> names = <int, String>{};
    final Map<int, int> suiteOf = <int, int>{};
    final Map<int, int> started = <int, int>{};
    final Map<int, int> ended = <int, int>{};
    int passed = 0;
    int failed = 0;
    int skipped = 0;
    final List<String> failures = <String>[];
    for (final String line in file.readAsLinesSync()) {
      if (!line.startsWith('{')) {
        continue;
      }
      final Object? e;
      try {
        e = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (e is! Map<String, Object?>) {
        continue;
      }
      switch (e['type']) {
        case 'suite':
          final Map<String, Object?> s = e['suite']! as Map<String, Object?>;
          suites[s['id']! as int] = (s['path'] as String?) ?? '';
        case 'testStart':
          final Map<String, Object?> t = e['test']! as Map<String, Object?>;
          final int suite = t['suiteID']! as int;
          final int time = e['time']! as int;
          names[t['id']! as int] = (t['name'] as String?) ?? '';
          suiteOf[t['id']! as int] = suite;
          started.putIfAbsent(suite, () => time);
        case 'testDone':
          final int id = e['testID']! as int;
          if (suiteOf[id] case final int suite) {
            ended[suite] = e['time']! as int;
          }
          final bool success = e['result'] == 'success';
          if (e['hidden'] == true && success) {
            continue;
          }
          if (e['skipped'] == true) {
            skipped++;
          } else if (success) {
            passed++;
          } else {
            failed++;
            failures.add(
              '${_relative(suites[suiteOf[id]] ?? '')}: ${names[id]}',
            );
          }
      }
    }
    return _Counts(passed, failed, skipped, failures, <String, int>{
      for (final MapEntry<int, int> s in started.entries)
        if (suites[s.key] case final String path)
          if (ended[s.key] case final int end) _relative(path): end - s.value,
    });
  }

  final int passed;
  final int failed;
  final int skipped;
  final List<String> failures;
  final Map<String, int> took;
}
