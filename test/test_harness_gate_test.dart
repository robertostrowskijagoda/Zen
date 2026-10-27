import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The harness is a remote control for the app (state, friends, chats, the
// pyramid) used by `tool/zen_drive.dart` on test machines. It must never be
// reachable in a build people install: only a debug build starts it. The
// guard is in the source, so these tests read the source: a test run is a
// debug build itself and cannot show what a release build does.

String _read(String path) => File(path).readAsStringSync();

List<File> _libFiles() => <File>[
  for (final FileSystemEntity e in Directory(
    'lib',
  ).listSync(recursive: true, followLinks: false))
    if (e is File && e.path.endsWith('.dart')) e,
];

String _normalized(String path) => path.replaceAll('\\', '/');

void main() {
  final String server = _read(
    'lib/src/features/runtime/test_harness_server.dart',
  );

  test('only a debug build starts the harness server', () {
    final int bridge = server.indexOf('class _TestHarnessBridgeState');
    expect(bridge, greaterThan(-1));
    final String body = server.substring(bridge);
    final int guard = body.indexOf('if (!kDebugMode)');
    final int start = body.indexOf('TestHarnessServer(ref)');
    expect(guard, greaterThan(-1), reason: 'the debug-mode guard is gone');
    expect(start, greaterThan(guard), reason: 'started before the guard');
    // Not the weaker "not a release build": profile builds are installed on
    // real phones too.
    expect(body.substring(guard, start), contains('return;'));
    expect(body, isNot(contains('kReleaseMode')));
    expect(body, isNot(contains('kProfileMode')));
  });

  test('the server is created in one place only, behind that bridge', () {
    final List<String> creators = <String>[
      for (final File f in _libFiles())
        if (RegExp(r'TestHarnessServer\(').hasMatch(f.readAsStringSync()))
          _normalized(f.path),
    ];
    expect(creators, <String>[
      'lib/src/features/runtime/test_harness_server.dart',
    ]);
    expect(
      RegExp(r'TestHarnessServer\(').allMatches(server).length,
      2,
      reason: 'the declaration and the one creation in the bridge',
    );
  });

  test('the harness is wired in only from the app root and its own files', () {
    final List<String> users = <String>[
      for (final File f in _libFiles())
        if (RegExp(
          r'''test_harness_(server|features)\.dart''',
        ).hasMatch(f.readAsStringSync()))
          _normalized(f.path),
    ]..sort();
    expect(users, <String>[
      'lib/src/app/app.dart',
      'lib/src/features/runtime/test_harness_server.dart',
    ]);
  });

  test('it listens on the loopback address only', () {
    expect(server, contains('InternetAddress.loopbackIPv4'));
    expect(server, isNot(contains('InternetAddress.anyIPv4')));
    expect(server, isNot(contains('InternetAddress.anyIPv6')));
    expect(server, isNot(contains("'0.0.0.0'")));
  });

  test('every request needs the header and a loopback host before anything '
      'is handled', () {
    final int check = server.indexOf('kTestHarnessHeader) != \'1\'');
    final int handle = server.indexOf('await _handleRequest(request)');
    expect(check, greaterThan(-1));
    expect(handle, greaterThan(check));
    expect(server.substring(check, handle), contains('HttpStatus.forbidden'));
    expect(server.substring(check, handle), contains('isLoopbackHarnessHost'));
    // No CORS: a web page cannot add the header without a preflight.
    expect(server, isNot(contains('access-control-allow')));
    expect(server, isNot(contains('Access-Control-Allow')));
  });

  test('no native code or build script brings the harness into a release', () {
    // The harness has no counterpart in the Android, iOS, desktop or Go
    // code, and no release workflow turns it on.
    final List<String> places = <String>[
      'android',
      'ios',
      'linux',
      'macos',
      'windows',
      'native',
      '.github',
    ];
    for (final String place in places) {
      final Directory dir = Directory(place);
      if (!dir.existsSync()) {
        continue;
      }
      for (final FileSystemEntity e in dir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (e is! File || e.lengthSync() > 2 * 1024 * 1024) {
          continue;
        }
        final String path = _normalized(e.path);
        if (path.contains('/build/') ||
            path.contains('/.gradle/') ||
            path.contains('/Pods/') ||
            path.contains('/ephemeral/') ||
            !RegExp(
              r'\.(kt|java|swift|go|cc|cpp|h|m|mm|gradle|kts|yml|yaml|sh|ps1|plist|xml|json)$',
            ).hasMatch(path)) {
          continue;
        }
        expect(
          e.readAsStringSync().toLowerCase().contains('x-zen-harness'),
          isFalse,
          reason: path,
        );
      }
    }
  });
}
