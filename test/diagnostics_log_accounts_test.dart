import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';

/// The diagnostics log is the device's, in plain text: an account that is
/// not on the list leaves nothing in it, not even a sign that it was
/// opened; a listed one is logged as the default one is.
void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zen-log-accounts');
    ZenStartTrace.debugReset();
  });

  tearDown(() async {
    ZenStartTrace.debugReset();
    await ZenDiagnosticsLog.clear();
    for (int i = 0; i < 10 && await base.exists(); i++) {
      try {
        await base.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  Directory accountFolder(String name) =>
      Directory('${base.path}/accounts/$name')..createSync(recursive: true);

  Future<String> logText() async {
    await ZenDiagnosticsLog.settled;
    final StringBuffer all = StringBuffer();
    for (final FileSystemEntity e in base.listSync()) {
      if (e is File && e.path.contains(ZenDiagnosticsLog.filePrefix)) {
        all.write(e.readAsStringSync());
      }
    }
    return all.toString();
  }

  test('a hidden account writes nothing, and the default account coming '
      'back writes nothing that tells it was away', () async {
    // The process starts with the default account.
    ZenStartTrace.begin();
    ZenStartTrace.attach(base);
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    logZenMessage('App bootstrap running.');
    ZenStartTrace.reached();

    // "Inne konto": a hidden account, from leaving the default one on.
    ZenDiagnosticsLog.hush();
    logZenMessage('Stopping the node before a switch.');
    ZenStartTrace.begin();
    final Directory hidden = accountFolder('0123456789abcdef0123456789abcdef');
    ZenStartTrace.attach(hidden);
    await ZenDiagnosticsLog.attach(hidden, source: 'ui', shown: false);
    logZenMessage('App bootstrap running.');
    logZenWarning('Pushing entries to 201:abcd:1234:5678::1 failed: timeout');
    ZenTechLog.event('node', <String, Object?>{'peers': 3});
    ZenStartTrace.reached();
    logZenMessage('Hidden account at work.');

    // Locked: back to the default account, which starts again.
    ZenStartTrace.begin();
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    logZenMessage('App bootstrap running.');
    ZenStartTrace.reached();
    logZenMessage('The default account after its first screen.');

    final String text = await logText();
    expect(RegExp('ui attached').allMatches(text), hasLength(1));
    expect(RegExp('App bootstrap running').allMatches(text), hasLength(1));
    expect(RegExp(ZenStartTrace.beginMarker).allMatches(text), hasLength(1));
    expect(RegExp(ZenStartTrace.reachedMarker).allMatches(text), hasLength(1));
    expect(text, isNot(contains('201:')));
    expect(text, isNot(contains('Hidden account')));
    expect(text, isNot(contains('Stopping the node')));
    expect(text, isNot(contains('peers')));
    expect(text, contains('The default account after its first screen.'));
    expect(hidden.listSync(), isEmpty);
  });

  test('an account on the list is logged as the default one is', () async {
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    logZenMessage('Default account.');
    await ZenDiagnosticsLog.attach(
      accountFolder('fedcba9876543210fedcba9876543210'),
      source: 'ui',
      shown: true,
    );
    logZenMessage('Listed account.');
    final String text = await logText();
    expect(text, contains('Default account.'));
    expect(text, contains('Listed account.'));
    expect(RegExp('ui attached').allMatches(text), hasLength(2));
  });
}
