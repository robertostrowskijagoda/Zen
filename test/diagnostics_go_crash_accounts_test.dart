import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';

/// A fatal Go error is written to one file beside the device's log, and the
/// next start copies it into the log. While an account that is not on the
/// list is open that file must stay out of it: its text can carry addresses
/// and the time of a session the device is meant to know nothing about.
/// The bridge is told to discard the crash instead (the file it already
/// holds for this process is replaced), and an ordinary account is told the
/// device's file as before.
void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zen-go-crash-accounts');
    ZenStartTrace.debugReset();
  });

  tearDown(() async {
    // The log is process-wide: leave it speaking for the next test.
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    ZenDiagnosticsLog.startReached();
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

  /// The crash file the bridge is handed in the owner of a node started now.
  String? crashFileForTheBridge() {
    final Map<String, dynamic> sent =
        jsonDecode(withNodeOwner('{}', RuntimeNodeOwner(RuntimeNodeRole.app)))
            as Map<String, dynamic>;
    return (sent['ZenNodeOwner'] as Map<String, dynamic>)['crashFile']
        as String?;
  }

  String discarded() => Platform.isWindows ? 'NUL' : '/dev/null';

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

  const String crashText =
      'panic: runtime error: invalid memory address\n\n'
      'goroutine 7 [running]:\nmain.dial(0x200:abcd::1)\n';

  test('a start for an ordinary account hands the bridge the device\'s crash '
      'file, and the next start copies it into the log', () async {
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    expect(crashFileForTheBridge(), ZenTechLog.goCrashPath);
    expect(crashFileForTheBridge(), startsWith(base.path));

    File(ZenTechLog.goCrashPath!).writeAsStringSync(crashText);
    await ZenTechLog.noteGoCrash();
    expect(await logText(), contains('GOCRASH  panic: runtime error'));
  });

  test(
    'while an account that is not on the list is open the bridge gets no '
    'file of the device, and a crash file is neither read nor copied',
    () async {
      ZenStartTrace.begin();
      await ZenDiagnosticsLog.attach(base, source: 'ui');
      ZenStartTrace.reached();
      // A crash of an earlier ordinary run waits for the next ordinary start.
      final File earlier = File(ZenTechLog.goCrashPath!)
        ..writeAsStringSync(crashText);

      ZenDiagnosticsLog.hush();
      final Directory hidden = accountFolder(
        '0123456789abcdef0123456789abcdef',
      );
      ZenStartTrace.begin();
      await ZenDiagnosticsLog.attach(hidden, source: 'ui', shown: false);

      expect(ZenTechLog.goCrashPath, isNull);
      expect(crashFileForTheBridge(), discarded());
      expect(crashFileForTheBridge(), isNot(contains(base.path)));

      await ZenTechLog.noteGoCrash();
      expect(earlier.readAsStringSync(), crashText, reason: 'left as it was');
      expect(await logText(), isNot(contains('GOCRASH')));
      expect(hidden.listSync(), isEmpty);
    },
  );

  test('a quiet log hands the bridge nothing of the device until the start '
      'of a listed account reaches its first screen', () async {
    ZenDiagnosticsLog.hush();
    expect(crashFileForTheBridge(), discarded());
    ZenStartTrace.begin();
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    ZenStartTrace.reached();
    ZenDiagnosticsLog.startReached();
    expect(crashFileForTheBridge(), ZenTechLog.goCrashPath);
  });

  test('the default account coming back after a hidden one gets crash '
      'logging again for its next node start', () async {
    ZenStartTrace.begin();
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    ZenStartTrace.reached();
    expect(crashFileForTheBridge(), ZenTechLog.goCrashPath);

    ZenDiagnosticsLog.hush();
    final Directory hidden = accountFolder('0123456789abcdef0123456789abcdef');
    ZenStartTrace.begin();
    await ZenDiagnosticsLog.attach(hidden, source: 'ui', shown: false);
    ZenStartTrace.reached();
    expect(crashFileForTheBridge(), discarded());

    // Locked: back to the default account, which starts again. Until its
    // first screen the log is still quiet, and so is the crash file.
    ZenStartTrace.begin();
    await ZenDiagnosticsLog.attach(base, source: 'ui');
    expect(crashFileForTheBridge(), discarded());
    ZenStartTrace.reached();
    ZenDiagnosticsLog.startReached();

    expect(crashFileForTheBridge(), ZenTechLog.goCrashPath);
    expect(crashFileForTheBridge(), startsWith(base.path));
    File(ZenTechLog.goCrashPath!).writeAsStringSync(crashText);
    await ZenTechLog.noteGoCrash();
    expect(await logText(), contains('GOCRASH  panic: runtime error'));
  });
}
