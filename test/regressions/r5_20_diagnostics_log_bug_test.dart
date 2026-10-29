// Owner report R5-#20 (28.10.2026, after 1.14.0): a bug in the diagnostics logs (details to come from the owner).
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// The owner's log of 28.10.2026 showed the same retry's stack 133 times,
// times without their UTC offset across the end of summer time, quoted
// message text, the log split between accounts' folders and a saved file
// Windows showed as garbage. Fixed in zen_log.dart, zen_tech_log.dart and
// diagnostics_log_file.dart (a54c6b25); guarded by the tests below,
// test/diagnostics_log_format_test.dart and, for the chained stack trace
// found meanwhile, R5-F3 (r5_found_by_tests_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('zen-r5-20-');
    await ZenDiagnosticsLog.attach(folder, source: 'ui');
  });

  tearDown(() async {
    await ZenDiagnosticsLog.clear();
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer.
    }
  });

  Future<List<String>> entries() async {
    await ZenDiagnosticsLog.settled;
    return ZenDiagnosticsLog.entries();
  }

  test('R5-#20: the diagnostics log has the reported defect fixed: a retry '
      'that fails again is counted, not written again', () async {
    // 133 times on the owner's phone.
    for (int i = 0; i < 20; i++) {
      logZenWarning('Relay send "rly_poll" failed: node is not running');
    }
    logZenMessage('Something else.');

    final List<String> lines = await entries();
    expect(lines.where((String l) => l.contains('rly_poll')), hasLength(1));
    expect(
      lines.where((String l) => l.contains('19 more times')),
      hasLength(1),
    );
  });

  test('R5-#20: every entry carries its UTC offset', () async {
    logZenMessage('With an offset.');
    expect(
      (await entries()).last,
      matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+[+-]\d\d:\d\d ')),
    );
  });

  test(
    'R5-#20: what an error quotes of a message never reaches the log',
    () async {
      const String secret = 'Kocham Cię, spotkajmy się o 18';
      try {
        jsonDecode('{"text":"$secret" broken');
      } on FormatException catch (error, stack) {
        logZenError('Handling a signal failed', error, stack);
        logZenWarning('Reading a message failed: $error');
      }
      final String all = (await entries()).join('\n');
      expect(all, isNot(contains('Kocham')));
      expect(all, contains('FormatException'));
    },
  );
}
