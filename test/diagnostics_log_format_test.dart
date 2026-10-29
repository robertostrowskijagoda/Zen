import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/features/settings/diagnostics_log_file.dart';

/// What the diagnostics log looked like on a phone (1.13.0 → 1.14.0): the
/// same retry's stack 133 times, times without their offset across the end
/// of summer time, lines before the attach after it, the background
/// service's lines missing in another account, how Android ended the app
/// written by both isolates, and a saved file Windows shows as garbage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('zen-log-format');
    await ZenDiagnosticsLog.attach(folder, source: 'ui');
  });

  tearDown(() async {
    await ZenDiagnosticsLog.clear();
    await folder.delete(recursive: true);
  });

  /// This isolate's entries, without their time and source, once written.
  Future<List<String>> logged() async {
    await ZenDiagnosticsLog.settled;
    return <String>[
      for (final String entry in await ZenDiagnosticsLog.entries())
        entry.substring(entry.indexOf('] ') + 2),
    ];
  }

  StackTrace stackOf(void Function() thrower) {
    try {
      thrower();
    } on Object catch (_, stack) {
      return stack;
    }
    return StackTrace.current;
  }

  group('cutting', () {
    test('an over-long entry is cut between characters, never inside one', () {
      // An emoji is two UTF-16 units: cut after the first, it would be
      // written as "?" (U+FFFD).
      final String text = '${'a' * 9}😀tail';
      expect(cutOnCharacters(text, 10), startsWith('a' * 9));
      expect(cutOnCharacters(text, 10), isNot(contains('\uD83D')));
      expect(cutOnCharacters(text, 11), startsWith('${'a' * 9}😀'));
      expect(cutOnCharacters(text, 100), text);
      expect(cutOnCharacters('x' * 20, 10), endsWith('(10 more characters)'));
    });

    test('a long entry with Polish letters and emoji stays whole UTF-8 in '
        'the file', () async {
      final String long = List<String>.filled(3000, 'żółć😀').join();
      logZenWarning('Długi wpis: $long');
      await ZenDiagnosticsLog.settled;
      final List<int> bytes = await File(
        '${folder.path}/zen-diagnostics-ui.log',
      ).readAsBytes();
      final String text = utf8.decode(bytes);
      expect(text, isNot(contains('\uFFFD')));
      final String entry = (await logged()).last;
      expect(entry.length, lessThan(ZenDiagnosticsLog.entryLimitChars + 60));
      expect(entry, contains('more characters)'));
    });
  });

  group('repeats', () {
    test('the same line again is counted, not written again', () async {
      for (int i = 0; i < 5; i++) {
        logZenWarning('Relay send "rly_poll" failed: node is not running');
      }
      logZenMessage('Something else.');
      final List<String> lines = await logged();
      expect(lines.where((String l) => l.contains('rly_poll')), hasLength(1));
      expect(lines, contains('INFO  (the line before came 4 more times)'));
      expect(lines.last, 'INFO  Something else.');
    });

    test('the count is written also when nothing else follows', () async {
      logZenWarning('Once.');
      logZenWarning('Once.');
      expect(
        await logged(),
        containsAllInOrder(<String>[
          'WARN  Once.',
          'INFO  (the line before came 1 more times)',
        ]),
      );
    });

    test('an error with the same stack names the first one instead of '
        'repeating the stack', () async {
      final StackTrace stack = stackOf(
        () => throw StateError('a node with this identity already runs'),
      );
      for (int attempt = 1; attempt <= 4; attempt++) {
        logZenError(
          'Runtime live bootstrap attempt $attempt/4 failed',
          StateError('a node with this identity already runs'),
          stack,
        );
      }
      final List<String> entries = await logged();
      expect(entries, hasLength(5), reason: 'the attach line and 4 errors');
      final int stacks = entries
          .where((String e) => e.contains('stackOf'))
          .length;
      expect(stacks, 1);
      expect(
        entries.where((String e) => e.contains('(the same stack as at ')),
        hasLength(3),
      );
    });

    test('an uncaught error keeps its whole stack (not the top six frames); '
        'the same one at once again is counted', () async {
      StackTrace deep(int n) => n == 0 ? StackTrace.current : deep(n - 1);
      final StackTrace stack = deep(20);
      logZenUncaught('Uncaught asynchronous error', StateError('x'), stack);
      logZenUncaught('Uncaught asynchronous error', StateError('x'), stack);
      final List<String> entries = await logged();
      final String uncaught = entries.singleWhere(
        (String e) => e.contains('Uncaught'),
      );
      expect('\n'.allMatches(uncaught).length, greaterThan(15));
      expect(entries.last, 'INFO  (the line before came 1 more times)');
    });
  });

  group('privacy', () {
    test('what a FormatException or an ArgumentError quotes never reaches '
        'the log', () async {
      const String secret = 'Kocham Cię, spotkajmy się o 18';
      try {
        jsonDecode('{"text":"$secret" broken');
      } on FormatException catch (error, stack) {
        logZenError('Handling a signal failed', error, stack);
        logZenWarning('Reading a message failed: $error');
      }
      logZenError(
        'Saving failed',
        ArgumentError.value(secret, 'body', 'too long'),
        StackTrace.current,
      );
      final String all = (await logged()).join('\n');
      expect(all, isNot(contains('Kocham')));
      expect(all, contains('FormatException'));
      expect(all, contains('Invalid argument (body): too long'));
    });
  });

  group('time', () {
    test('every entry carries its UTC offset', () async {
      logZenMessage('With an offset.');
      final String entry = (await logged().then(
        (_) => ZenDiagnosticsLog.entries(),
      )).last;
      expect(
        entry,
        matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+[+-]\d\d:\d\d ')),
      );
      // The same moment, whatever the zone.
      final DateTime moment = DateTime.utc(2026, 10, 25, 0, 30);
      expect(DateTime.parse(diagnosticsTimestamp(moment)), moment);
    });

    test('logs merge by the moment, also across the end of summer time', () {
      // 02:30 summer time comes before 02:10 winter time (an hour later).
      expect(
        mergeDiagnosticsLogs(<String>[
          '2026-10-25T02:10:00.000+01:00 [ui] second\n',
          '2026-10-25T02:30:00.000+02:00 [svc] first\n',
        ]),
        <String>[
          '2026-10-25T02:30:00.000+02:00 [svc] first',
          '2026-10-25T02:10:00.000+01:00 [ui] second',
        ],
      );
    });
  });

  group('folders', () {
    test('with another account open, the log stays in the app\'s folder, '
        'beside the background service\'s, and none is left in the '
        'account\'s', () async {
      final Directory account = Directory('${folder.path}/accounts/0a1b2c3d')
        ..createSync(recursive: true);
      final File stale = File('${account.path}/zen-diagnostics-ui.log')
        ..writeAsStringSync('2026-10-27T10:00:00.000 [ui] INFO  old\n');
      File('${folder.path}/zen-diagnostics-svc.log').writeAsStringSync(
        '${diagnosticsTimestamp(DateTime.now())} [svc] INFO  From the service.\n',
      );
      expect(diagnosticsLogFolder(account).path, folder.path);

      await ZenDiagnosticsLog.attach(account, source: 'ui');
      logZenMessage('In the other account.');
      final String all = (await logged().then(
        (_) => ZenDiagnosticsLog.entries(),
      )).join('\n');
      expect(all, contains('From the service.'));
      expect(all, contains('In the other account.'));
      expect(ZenDiagnosticsLog.file!.parent.path, folder.path);
      expect(stale.existsSync(), isFalse);
    });
  });

  group('exit records', () {
    test('the app and the service starting together write them once', () async {
      final int at = DateTime(2026, 10, 28, 1).millisecondsSinceEpoch;
      const MethodChannel channel = MethodChannel('zen/power/test-exits');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return <Object?>[
              <Object?, Object?>{'at': at, 'reason': 3, 'importance': 125},
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await Future.wait(<Future<void>>[
        ZenTechLog.noteExits(channel: channel, android: true),
        ZenTechLog.noteExits(channel: channel, android: true),
      ]);
      await ZenTechLog.noteExits(channel: channel, android: true);
      final List<String> exits = (await logged())
          .where((String e) => e.startsWith('TECH  exit '))
          .toList();
      expect(exits, hasLength(1));
    });
  });

  test('the saved file is UTF-8 with its byte order mark', () {
    final List<int> bytes = diagnosticsLogFileBytes('Zażółć — …\n');
    expect(bytes.take(3), <int>[0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytes.skip(3).toList()), 'Zażółć — …\n');
  });
}
