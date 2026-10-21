import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Lines logged before the data folder is known (the window coming up
/// while the accounts are prepared) land in the file once it is attached.
void main() {
  test(
    'lines written before the attach are kept, redacted, in order',
    () async {
      final Directory folder = await Directory.systemTemp.createTemp('zen-log');
      addTearDown(() => folder.delete(recursive: true));
      for (int i = 0; i < ZenDiagnosticsLog.earlyLineLimit + 5; i++) {
        logZenMessage('early line $i');
      }
      logZenMessage(
        'tray icon at ${folder.path}${Platform.pathSeparator}vault'
        '${Platform.pathSeparator}tajne.ico',
      );
      expect(ZenDiagnosticsLog.file, isNull);

      await ZenDiagnosticsLog.attach(folder, source: 'test');
      logZenMessage('after the attach');
      final String log = await _settled(ZenDiagnosticsLog.read);

      final List<String> lines = log.trim().split('\n');
      expect(lines.first, contains('--- test attached'));
      // The oldest lines beyond the limit are dropped.
      expect(log, isNot(contains('early line 5\n')));
      expect(log, contains('early line 6\n'));
      expect(log, isNot(contains('tajne.ico')));
      final int early = lines.indexWhere((String l) => l.contains('line 6'));
      final int last = lines.indexWhere((String l) => l.contains('tray icon'));
      final int after = lines.indexWhere((String l) => l.contains('after the'));
      expect(early, greaterThan(0));
      expect(last, greaterThan(early));
      expect(after, greaterThan(last));
    },
  );
}

/// The log is written fire-and-forget: [read] once the lines landed.
Future<String> _settled(Future<String> Function() read) async {
  String text = '';
  for (int i = 0; i < 100; i++) {
    text = await read();
    if (text.contains('after the attach')) {
      return text;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return text;
}
