// Mutation testing: how much the tests of the app's core files would
// notice a bug. Each target file (tool/mutation_targets.json) is changed
// in one small place at a time, the way a slip of the keyboard would
// change it (== and !=, < and >=, && and ||, true and false, a ! dropped),
// and its tests run on the change. A change the tests let through (a
// "survivor") is a line no test pins down. Plain Dart, no packages.
//
//   dart run tool/mutation.dart                 every target, 15 changes each
//   dart run tool/mutation.dart --max 40 --seed 7 --summary FILE
//   dart run tool/mutation.dart lib/src/features/social/peer_share_codec.dart
//
// The changes are picked at random among all possible ones (--seed), so
// every run looks at others. The file is put back after every change,
// also when the run is stopped (Ctrl+C) or a test hangs (--timeout,
// seconds per change). --summary appends Markdown (CI's job summary).
// Exit code 0 always unless the tests fail on the unchanged code (then 1):
// the score informs, it does not block.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const String _targetsFile = 'tool/mutation_targets.json';

/// One way of changing a line.
final class _Operator {
  const _Operator(this.name, this.pattern, this.replacement);

  final String name;
  final RegExp pattern;
  final String replacement;
}

final List<_Operator> _operators = <_Operator>[
  _Operator('== → !=', RegExp(r' == '), ' != '),
  _Operator('!= → ==', RegExp(r' != '), ' == '),
  _Operator('&& → ||', RegExp(r' && '), ' || '),
  _Operator('|| → &&', RegExp(r' \|\| '), ' && '),
  _Operator('< → >=', RegExp(r' < '), ' >= '),
  _Operator('<= → >', RegExp(r' <= '), ' > '),
  _Operator('> → <=', RegExp(r' > '), ' <= '),
  _Operator('>= → <', RegExp(r' >= '), ' < '),
  _Operator('true → false', RegExp(r'\btrue\b'), 'false'),
  _Operator('false → true', RegExp(r'\bfalse\b'), 'true'),
  _Operator('drop !', RegExp(r'!(?=[a-zA-Z_(])'), ''),
  _Operator('+ 1 → - 1', RegExp(r' \+ 1\b'), ' - 1'),
  _Operator('- 1 → + 1', RegExp(r' - 1\b'), ' + 1'),
];

/// A change: [line] (0-based) of the file with [start]..[end] replaced.
final class _Mutant {
  const _Mutant(this.line, this.start, this.end, this.op);

  final int line;
  final int start;
  final int end;
  final _Operator op;
}

Future<void> main(List<String> args) async {
  int max = 15;
  int seed = DateTime.now().millisecondsSinceEpoch;
  int timeout = 240;
  String? summary;
  final List<String> only = <String>[];
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--max':
        max = int.parse(args[++i]);
      case '--seed':
        seed = int.parse(args[++i]);
      case '--timeout':
        timeout = int.parse(args[++i]);
      case '--summary':
        summary = args[++i];
      default:
        only.add(args[i].replaceAll(r'\', '/'));
    }
  }
  final List<dynamic> targets =
      jsonDecode(File(_targetsFile).readAsStringSync()) as List<dynamic>;
  final StringBuffer report = StringBuffer('### Mutation testing\n\n')
    ..writeln('Seed $seed, at most $max changes per file.\n')
    ..writeln('| File | Caught | Survived |')
    ..writeln('|---|---|---|');
  final StringBuffer survivors = StringBuffer();
  int failedBaseline = 0;
  for (final dynamic t in targets) {
    final String file = (t as Map<String, dynamic>)['file'] as String;
    if (only.isNotEmpty && !only.contains(file)) {
      continue;
    }
    final List<String> tests = (t['tests'] as List<dynamic>).cast<String>();
    stdout.writeln('== $file (${tests.join(', ')})');
    if (!await _testsPass(tests, timeout)) {
      stdout.writeln('   the tests fail on the unchanged file: skipped');
      failedBaseline++;
      report.writeln('| `$file` | tests fail unchanged | — |');
      continue;
    }
    final File source = File(file);
    final String original = source.readAsStringSync();
    final List<String> lines = const LineSplitter().convert(original);
    final List<_Mutant> all = _mutantsOf(lines)..shuffle(Random(seed));
    int caught = 0;
    final List<String> lived = <String>[];
    void restore() => source.writeAsStringSync(original);
    final StreamSubscription<ProcessSignal> stop = ProcessSignal.sigint
        .watch()
        .listen((_) {
          restore();
          exit(130);
        });
    try {
      for (final _Mutant m in all.take(max)) {
        final String line = lines[m.line];
        final String changed =
            line.substring(0, m.start) +
            m.op.replacement +
            line.substring(m.end);
        final List<String> copy = List<String>.of(lines)..[m.line] = changed;
        source.writeAsStringSync('${copy.join('\n')}\n');
        final bool passed = await _testsPass(tests, timeout);
        final String where = '$file:${m.line + 1} (${m.op.name})';
        if (passed) {
          lived.add(where);
          stdout.writeln('   SURVIVED $where: ${changed.trim()}');
        } else {
          caught++;
          stdout.writeln('   caught   $where');
        }
        restore();
      }
    } finally {
      restore();
      await stop.cancel();
    }
    report.writeln('| `$file` | $caught | ${lived.length} |');
    for (final String s in lived) {
      survivors.writeln('- `$s`');
    }
  }
  if (survivors.isNotEmpty) {
    report
      ..writeln()
      ..writeln('Changes no test noticed (each a line to pin down):')
      ..writeln()
      ..write(survivors);
  }
  stdout.writeln(report);
  if (summary != null) {
    File(summary).writeAsStringSync('$report\n', mode: FileMode.append);
  }
  exitCode = failedBaseline > 0 ? 1 : 0;
}

/// Every change the operators can make in [lines], outside comments,
/// imports, annotations and string literals.
List<_Mutant> _mutantsOf(List<String> lines) {
  final List<_Mutant> out = <_Mutant>[];
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final String trimmed = line.trimLeft();
    if (trimmed.startsWith('//') ||
        trimmed.startsWith('import ') ||
        trimmed.startsWith('export ') ||
        trimmed.startsWith('part ') ||
        trimmed.startsWith('@') ||
        trimmed.startsWith('assert(')) {
      continue;
    }
    final int comment = line.indexOf(' //');
    final String code = comment < 0 ? line : line.substring(0, comment);
    final List<bool> inString = _stringMask(code);
    for (final _Operator op in _operators) {
      for (final RegExpMatch match in op.pattern.allMatches(code)) {
        if (!inString[match.start]) {
          out.add(_Mutant(i, match.start, match.end, op));
        }
      }
    }
  }
  return out;
}

/// For each character of [code], whether it is inside a string literal.
List<bool> _stringMask(String code) {
  final List<bool> mask = List<bool>.filled(code.length + 1, false);
  String? quote;
  for (int i = 0; i < code.length; i++) {
    final String c = code[i];
    if (quote != null) {
      mask[i] = true;
      if (c == r'\') {
        if (i + 1 < code.length) {
          mask[++i] = true;
        }
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == "'" || c == '"') {
      quote = c;
      mask[i] = true;
    }
  }
  return mask;
}

Future<bool> _testsPass(List<String> tests, int timeout) async {
  final Process p = await Process.start(
    Platform.isWindows ? 'flutter.bat' : 'flutter',
    <String>['test', '--no-pub', '--reporter', 'failures-only', ...tests],
    runInShell: Platform.isWindows,
  );
  unawaited(p.stdout.drain<void>());
  unawaited(p.stderr.drain<void>());
  final int code = await p.exitCode.timeout(
    Duration(seconds: timeout),
    onTimeout: () {
      p.kill();
      // A test that hangs on the change noticed it.
      return 1;
    },
  );
  return code == 0;
}
