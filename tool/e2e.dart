// Runs the real-node tests (test/e2e): several Zen devices in one test
// process, each with its own data folder and its own Yggdrasil node from the
// Go bridge, on a mesh of this computer only (test/e2e/support/zen_mesh.dart).
// Linux (the "End-to-end on Linux" CI job) and Windows. Plain Dart:
//
//   dart run tool/e2e.dart
//       Builds what `flutter test` lacks, then runs every file of test/e2e,
//       one at a time (they share the peering port).
//   dart run tool/e2e.dart test/e2e/friends_e2e_test.dart
//       Only these files.
//   dart run tool/e2e.dart --results <folder> --minutes 12
//       The JSON reporter's file of every run into the folder (for
//       tool/ci/ci_summary.py), and a limit for the whole run.
//   dart run tool/e2e.dart --no-build test/e2e/restart_e2e_test.dart
//       Without building the bridge again (it is there from a run before).
//   dart run tool/e2e.dart --clean
//       Removes the libraries it put next to the engine's flutter_tester.
//
// What it builds (into build/e2e/lib):
// - the Go bridge, with the build tag `zene2e` (stack_dump_e2e.go: the
//   stacks of all goroutines go to build/e2e/goroutines.txt every 10 s, so
//   a hang inside the bridge shows where), copied next to the engine's
//   `flutter_tester`, where the app looks for it under `flutter test`;
// - zstd, which the app's stores compress with (the zstandard plugin's
//   library comes from a platform build, which `flutter test` has none of),
//   from the zstd sources of the pub cache's zstandard_native package.
//
// Needs Go and a C compiler (cc on Linux, gcc on Windows, or CC). Nothing is
// downloaded. docs/TESTING.md, "End-to-end on real nodes".
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String _out = 'build/e2e';
const String _lib = '$_out/lib';
const String _stackDump = '$_out/goroutines.txt';

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
  } on _Failure catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}

Future<int> _run(List<String> args) async {
  String? results;
  int minutes = 15;
  bool clean = false;
  bool noBuild = false;
  final List<String> paths = <String>[];
  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--results':
        results = args[++i];
      case '--minutes':
        minutes = int.parse(args[++i]);
      case '--no-build':
        noBuild = true;
      case '--clean':
        clean = true;
      case final String arg when arg.startsWith('-'):
        throw _Failure('Unknown option $arg');
      case final String path:
        paths.add(path);
    }
  }
  if (!Platform.isLinux && !Platform.isWindows) {
    throw _Failure('The real-node tests run on Linux and Windows.');
  }
  final Directory engine = await _engineDirectory();
  final File bridgeNextToTester = File(
    '${engine.path}${Platform.pathSeparator}'
    '${Platform.isLinux ? 'lib/libyggdrasil_bridge.so' : 'yggdrasil_bridge.dll'}',
  );
  if (clean) {
    if (bridgeNextToTester.existsSync()) {
      bridgeNextToTester.deleteSync();
      print('Removed ${bridgeNextToTester.path}.');
    }
    return 0;
  }

  Directory(_lib).createSync(recursive: true);
  if (!noBuild || !bridgeNextToTester.existsSync()) {
    await _buildBridge(bridgeNextToTester);
  }
  await _buildZstd();

  final List<String> files = paths.isEmpty
      ? (Directory('test/e2e')
            .listSync()
            .whereType<File>()
            .map((File f) => f.path.replaceAll(r'\', '/'))
            .where((String p) => p.endsWith('_test.dart'))
            .toList()
          ..sort())
      : paths;
  if (results != null) {
    Directory(results).createSync(recursive: true);
  }
  final Map<String, String> environment = <String, String>{
    'ZEN_E2E': '1',
    'ZEN_STACK_DUMP': File(_stackDump).absolute.path,
    if (Platform.isLinux)
      'LD_LIBRARY_PATH': <String>[
        Directory(_lib).absolute.path,
        if (Platform.environment['LD_LIBRARY_PATH'] case final String old
            when old.isNotEmpty)
          old,
      ].join(':')
    else
      'PATH':
          '${Directory(_lib).absolute.path};${Platform.environment['PATH']}',
  };
  final Stopwatch clock = Stopwatch()..start();
  final Duration limit = Duration(minutes: minutes);
  final List<String> failed = <String>[];
  for (final String file in files) {
    final Duration left = limit - clock.elapsed;
    if (left <= Duration.zero) {
      failed.add('$file (not run: the ${limit.inMinutes} min were up)');
      continue;
    }
    final String name = file.split('/').last.replaceAll('.dart', '');
    final bool ok = await _flutterTest(
      file,
      environment,
      left,
      results == null ? null : '$results/e2e-$name.json',
    );
    if (!ok) {
      failed.add(file);
    }
  }
  final String took = (clock.elapsedMilliseconds / 1000).toStringAsFixed(0);
  print('');
  print(
    '${files.length - failed.length} of ${files.length} files passed '
    'in ${took}s.',
  );
  for (final String f in failed) {
    print('  failed: $f');
  }
  return failed.isEmpty ? 0 : 1;
}

/// One file in its own `flutter test`; killed after [limit], when the
/// goroutines the bridge last wrote are printed.
Future<bool> _flutterTest(
  String file,
  Map<String, String> environment,
  Duration limit,
  String? report,
) async {
  print('== $file');
  final File dump = File(_stackDump);
  if (dump.existsSync()) {
    dump.deleteSync();
  }
  final Process process = await Process.start(
    Platform.isWindows ? 'flutter.bat' : 'flutter',
    <String>[
      'test',
      '--no-pub',
      if (report != null) '--file-reporter=json:$report',
      file,
    ],
    environment: environment,
  );
  final Future<void> out = stdout.addStream(process.stdout);
  final Future<void> err = stderr.addStream(process.stderr);
  bool timedOut = false;
  final int code = await process.exitCode.timeout(
    limit,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      if (Platform.isWindows) {
        // flutter.bat leaves its children behind.
        Process.runSync('taskkill', <String>[
          '/F',
          '/IM',
          'flutter_tester.exe',
        ]);
      }
      return -1;
    },
  );
  await Future.wait(<Future<void>>[
    out,
    err,
  ]).timeout(const Duration(seconds: 10), onTimeout: () => <void>[]);
  if (timedOut) {
    print(
      '$file did not finish within ${limit.inMinutes} min and was '
      'killed.',
    );
  }
  if (code != 0 && dump.existsSync()) {
    print('Goroutines of the Go bridge at the last dump ($_stackDump):');
    print(dump.readAsStringSync());
  }
  return code == 0;
}

/// The folder of the engine's `flutter_tester` (the executable a
/// `flutter test` runs, whose folder the app looks into for the bridge).
Future<Directory> _engineDirectory() async {
  final ProcessResult version = await Process.run(
    Platform.isWindows ? 'flutter.bat' : 'flutter',
    <String>['--version', '--machine'],
  );
  if (version.exitCode != 0) {
    throw _Failure('flutter --version failed: ${version.stderr}');
  }
  final String text = '${version.stdout}';
  final Map<String, dynamic> info =
      jsonDecode(text.substring(text.indexOf('{'))) as Map<String, dynamic>;
  final String root = info['flutterRoot'] as String;
  final String host = Platform.isLinux ? 'linux-x64' : 'windows-x64';
  final Directory engine = Directory(
    '$root/bin/cache/artifacts/engine/$host'.replaceAll(
      '/',
      Platform.pathSeparator,
    ),
  );
  if (!engine.existsSync()) {
    // A fresh SDK (a CI runner) fetches the engine on its first test run;
    // the folder is needed before that.
    final ProcessResult precache = await Process.run(
      Platform.isWindows ? 'flutter.bat' : 'flutter',
      <String>['precache', '--universal'],
    );
    if (precache.exitCode != 0 || !engine.existsSync()) {
      throw _Failure(
        'No ${engine.path} after `flutter precache --universal`:\n'
        '${precache.stdout}\n${precache.stderr}',
      );
    }
  }
  return engine;
}

/// The Go bridge with the `zene2e` tag, next to `flutter_tester`.
Future<void> _buildBridge(File target) async {
  final String name = Platform.isLinux
      ? 'libyggdrasil_bridge.so'
      : 'yggdrasil_bridge.dll';
  final File built = File('$_lib/$name');
  print('Go bridge (tag zene2e) -> ${built.path}');
  final ProcessResult go = await Process.run(
    'go',
    <String>[
      'build',
      '-tags',
      'zene2e',
      '-trimpath',
      '-buildmode=c-shared',
      '-o',
      built.absolute.path,
      '.',
    ],
    workingDirectory: 'native/yggdrasil_bridge',
    environment: <String, String>{
      'CGO_ENABLED': '1',
      if (Platform.isWindows && Platform.environment['CC'] == null) 'CC': 'gcc',
    },
  );
  if (go.exitCode != 0) {
    throw _Failure('go build failed:\n${go.stdout}\n${go.stderr}');
  }
  target.parent.createSync(recursive: true);
  built.copySync(target.path);
  print('  copied to ${target.path}');
}

/// zstd as the zstandard plugin's own library name, from the package's
/// sources in the pub cache.
Future<void> _buildZstd() async {
  final String name = Platform.isLinux
      ? 'libzstandard_linux.so'
      : 'zstandard_windows.dll';
  final File built = File('$_lib/$name');
  if (built.existsSync()) {
    return;
  }
  final Map<String, dynamic> config =
      jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
          as Map<String, dynamic>;
  final Map<String, dynamic>? package = (config['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .where((Map<String, dynamic> p) => p['name'] == 'zstandard_native')
      .firstOrNull;
  if (package == null) {
    throw _Failure(
      'zstandard_native is not in .dart_tool/package_config.json '
      '(run flutter pub get).',
    );
  }
  final Directory zstd = Directory(
    '${Uri.parse(package['rootUri'] as String).toFilePath()}'
    '${Platform.pathSeparator}src${Platform.pathSeparator}zstd',
  );
  final List<String> sources = <String>[
    for (final String part in <String>['common', 'compress', 'decompress'])
      for (final FileSystemEntity f in Directory(
        '${zstd.path}${Platform.pathSeparator}$part',
      ).listSync())
        if (f.path.endsWith('.c')) f.path,
  ]..sort();
  print('zstd (${sources.length} files) -> ${built.path}');
  final String cc =
      Platform.environment['CC'] ?? (Platform.isLinux ? 'cc' : 'gcc');
  final ProcessResult result = await Process.run(cc, <String>[
    '-shared',
    '-O2',
    if (Platform.isLinux) '-fPIC',
    '-DZSTD_DISABLE_ASM',
    '-I${zstd.path}',
    ...sources,
    '-o',
    built.absolute.path,
  ]);
  if (result.exitCode != 0) {
    throw _Failure('Building zstd failed:\n${result.stdout}\n${result.stderr}');
  }
}

final class _Failure implements Exception {
  _Failure(this.message);

  final String message;
}
