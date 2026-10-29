// The website's pictures and short films (tool/pages/shots), made from the
// app itself:
//
//   dart run tool/screenshots.dart            render and encode everything
//   dart run tool/screenshots.dart --lang pl  one language only
//   dart run tool/screenshots.dart --only dark,phone
//                                             a part (SHOTS_ONLY of the
//                                             renderer: light, dark, phone,
//                                             desktop, lock)
//   dart run tool/screenshots.dart --check    only checks that every picture
//                                             the pages need is there and
//                                             within its size (CI)
//
// Rendering runs tool/screenshots/site_screens_test.dart once per language
// (flutter test, no device) into build/shots/, then encode.py (Python with
// Pillow) writes the WebP files. Run it after the translations are up to
// date (an untranslated text shows in Polish) and commit tool/pages/shots.
import 'dart:io';

import 'screenshots/shots.dart';

Future<void> main(List<String> args) async {
  String? value(String name) {
    final int at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/screenshots.dart [--lang pl|en] '
      '[--only light,dark,phone,desktop,lock] [--check]',
    );
    return;
  }
  if (args.contains('--check')) {
    exit(_check() ? 0 : 1);
  }
  final String? lang = value('--lang');
  if (lang != null && !kShotLanguages.contains(lang)) {
    stderr.writeln(
      'screenshots: --lang is one of ${kShotLanguages.join(', ')}',
    );
    exit(64);
  }
  final String only = value('--only') ?? '';
  final Directory raw = Directory(kShotsRawDir);
  if (raw.existsSync()) {
    raw.deleteSync(recursive: true);
  }
  final String flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  for (final String l in lang == null ? kShotLanguages : <String>[lang]) {
    stdout.writeln('screenshots: rendering $l');
    final Process run = await Process.start(
      flutter,
      <String>['test', '--no-pub', 'tool/screenshots/site_screens_test.dart'],
      environment: <String, String>{'SHOTS_LANG': l, 'SHOTS_ONLY': only},
      mode: ProcessStartMode.inheritStdio,
    );
    final int code = await run.exitCode;
    if (code != 0) {
      stderr.writeln('screenshots: rendering $l failed ($code)');
      exit(code);
    }
  }
  stdout.writeln('screenshots: encoding');
  final Process encode = await Process.start(
    Platform.isWindows ? 'python' : 'python3',
    <String>['tool/screenshots/encode.py'],
    mode: ProcessStartMode.inheritStdio,
  );
  final int code = await encode.exitCode;
  if (code != 0) {
    stderr.writeln('screenshots: encoding failed ($code)');
    exit(code);
  }
  if (only.isEmpty && lang == null && !_check()) {
    exit(1);
  }
}

/// Every picture and film the pages need is in tool/pages/shots, within
/// its size, and nothing else is there.
bool _check() {
  final Map<String, int> expected = expectedShotFiles();
  final List<String> problems = <String>[];
  expected.forEach((String path, int limit) {
    final File file = File('tool/pages/$path');
    if (!file.existsSync()) {
      problems.add('missing: tool/pages/$path');
    } else if (file.lengthSync() > limit) {
      problems.add(
        'too large: tool/pages/$path (${file.lengthSync()} > $limit bytes)',
      );
    }
  });
  final Directory dir = Directory(kShotsDir);
  if (dir.existsSync()) {
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File) {
        continue;
      }
      final String path = e.path
          .replaceAll(r'\', '/')
          .substring('tool/pages/'.length);
      if (!expected.containsKey(path)) {
        problems.add('not used by the pages: tool/pages/$path');
      }
    }
  }
  for (final String p in problems) {
    stderr.writeln('screenshots: $p');
  }
  if (problems.isEmpty) {
    stdout.writeln(
      'screenshots: all ${expected.length} pictures and films are there',
    );
  } else {
    stderr.writeln(
      'screenshots: run `dart run tool/screenshots.dart` and commit '
      'tool/pages/shots',
    );
  }
  return problems.isEmpty;
}
