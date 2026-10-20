import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// S-16: the diagnostics log lies next to the encrypted data in plain
/// text, so it keeps no bridge or peer URLs, IP addresses or file names.
void main() {
  test('URLs keep only their scheme, IP addresses one part', () {
    final String line = redactDiagnosticsText(
      'Dodanie mostu tls://203.0.113.5:443?key=abcd i quic://[2a01:4f8::5]:9001; '
      'opis routera http://192.168.1.1:5000/rootDesc.xml; '
      'peer 198.51.100.7:9001, lan 10.0.0.2, lo 127.0.0.1:48888; '
      'v6 2a01:4f8:1:2::5 link fe80::1%wlan0 lo ::1 bt aa:bb:cc:dd:ee:ff',
    );
    expect(line, contains('tls://…'));
    expect(line, contains('quic://…'));
    expect(line, contains('http://…'));
    for (final String secret in <String>[
      '203.0.113',
      'key=abcd',
      '4f8',
      '168.1.1',
      'rootDesc',
      '51.100.7',
      '0.0.2',
      'fe80::1',
      'bb:cc',
    ]) {
      expect(line, isNot(contains(secret)), reason: secret);
    }
    expect(line, contains('198.…:9001'));
    expect(line, contains('127.0.0.1:48888'));
    expect(line, contains('lo ::1'));
  });

  test('mesh addresses, times and code locations stay readable', () {
    final String line = redactDiagnosticsText(
      'call from 200:1111:2222:3333:4444:5555:6666:7777 failed at '
      '2026-10-13T23:29:01.123 in package:zen/src/x.dart:12:5, Zen 1.10.0',
    );
    expect(line, contains('200:1111:…'));
    expect(line, isNot(contains('3333')));
    expect(line, contains('2026-10-13T23:29:01.123'));
    expect(line, contains('package:zen/src/x.dart:12:5'));
    expect(line, contains('1.10.0'));
  });

  test('paths under the app folders keep only the first folder', () {
    final List<String> android = diagnosticsPrivatePlaces(
      '/data/user/0/com.roj.zen/files',
    );
    final String quoted = redactDiagnosticsText(
      "FileSystemException: Cannot open file, path = "
      "'/data/user/0/com.roj.zen/files/vault/Moje zdjęcie.jpg' (OS Error)",
      privatePlaces: android,
    );
    expect(quoted, contains("path = '<app>/files/…' (OS Error)"));
    expect(quoted, isNot(contains('zdjęcie')));

    final String plain = redactDiagnosticsText(
      'Could not delete /data/data/com.roj.zen/files/x/abc.bin: gone; '
      'saved /storage/emulated/0/Android/data/com.roj.zen/files/Zen/a.pdf',
      privatePlaces: android,
    );
    expect(plain, contains('Could not delete <app>/files/…: gone'));
    expect(plain, contains('saved <app>/files/…'));
    expect(plain, isNot(contains('abc.bin')));
    expect(plain, isNot(contains('a.pdf')));

    final String ios = redactDiagnosticsText(
      "'/private/var/mobile/Containers/Data/Application/"
      "0A1B2C3D-1111-2222-3333-444455556666/Documents/Zen/a b.png'",
      privatePlaces: diagnosticsPrivatePlaces(
        '/var/mobile/Containers/Data/Application/'
        '0A1B2C3D-1111-2222-3333-444455556666/Library/Application Support',
      ),
    );
    expect(ios, "'<app>/Documents/…'");
  });

  test('on a computer: the support folder of every profile, and the home '
      'folder', () {
    final String windows = redactDiagnosticsText(
      r'C:\Users\Robert\AppData\Roaming\com.roj\zen\profiles\b\vault\x.zv '
      r'failed; C:\Users\Robert\Downloads\a.apk',
      privatePlaces: diagnosticsPrivatePlaces(
        r'C:\Users\Robert\AppData\Roaming\com.roj\zen\profiles\b',
      ),
      homeDirectory: r'C:\Users\Robert',
    );
    expect(windows, contains(r'<app>\profiles\…'));
    expect(windows, contains(r'~\Downloads\a.apk'));
    expect(windows, isNot(contains('Robert')));

    final String mac = redactDiagnosticsText(
      '"/Users/robert/Library/Application Support/com.roj.zen/stores/s.json"',
      privatePlaces: diagnosticsPrivatePlaces(
        '/Users/robert/Library/Application Support/com.roj.zen',
      ),
      homeDirectory: '/Users/robert',
    );
    expect(mac, '"<app>/stores/…"');
  });

  test('clearing deletes the log, also after queued lines', () async {
    final Directory folder = await Directory.systemTemp.createTemp('zen-log');
    addTearDown(() => folder.delete(recursive: true));
    await ZenDiagnosticsLog.attach(folder, source: 'test');
    logZenMessage('Dodanie mostu tls://203.0.113.5:443');
    logZenWarning(
      'Could not delete ${folder.path}${Platform.pathSeparator}vault'
      '${Platform.pathSeparator}tajne.bin',
    );
    final String log = await _settled(ZenDiagnosticsLog.read);
    expect(log, contains('tls://…'));
    expect(log, isNot(contains('203.0.113')));
    expect(log, isNot(contains('tajne.bin')));

    logZenMessage('one more line');
    await ZenDiagnosticsLog.clear();
    expect(await ZenDiagnosticsLog.file!.exists(), isFalse);
    expect(await ZenDiagnosticsLog.read(), isEmpty);
  });
}

/// The log is written fire-and-forget: [read] once the lines landed.
Future<String> _settled(Future<String> Function() read) async {
  String text = '';
  for (int i = 0; i < 50; i++) {
    text = await read();
    if (text.contains('tajne') || text.contains('vault')) {
      return text;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return text;
}
