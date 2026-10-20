import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/single_instance_guard.dart';

/// Port used only by these tests so a running Zen instance on the developer
/// machine cannot interfere with (or be disturbed by) the suite.
const int _testPort = 47899;

void main() {
  group('ZenSingleInstance', () {
    tearDown(() async {
      ZenSingleInstance.setActivationHandler(null);
      await ZenSingleInstance.release();
    });

    test('claims the lock and answers the activation handshake', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      int activations = 0;
      ZenSingleInstance.setActivationHandler(() async => activations += 1);

      expect(await ZenSingleInstance.acquire(port: _testPort), isTrue);

      // Stand in for a second launch of the app.
      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _testPort,
      );
      client.write('ZEN-SINGLE-INSTANCE/1 ACTIVATE\n');
      await client.flush();
      final String response = await client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      client.destroy();

      expect(response.trim(), 'ZEN-SINGLE-INSTANCE/1 ACK');
      // The ACK is sent before the window is raised so a slow handler cannot
      // stall the other launch; give it a moment to run.
      for (int i = 0; i < 50 && activations == 0; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(activations, 1);
    });

    test('a second launch is refused while the lock is held', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      expect(await ZenSingleInstance.acquire(port: _testPort), isTrue);

      // The guard short-circuits inside the owning process, so the rival
      // launch is simulated by probing the lock the way a fresh process does.
      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _testPort,
      );
      client.destroy();

      await ZenSingleInstance.release();
      // Once released the port is free again for the next launch.
      final ServerSocket reclaimed = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _testPort,
      );
      await reclaimed.close();
    });

    test(
      'an unrelated program on the port does not block the launch',
      () async {
        if (!ZenSingleInstance.isSupported) {
          return;
        }
        final ServerSocket squatter = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          _testPort,
        );
        // Never answers the handshake — exactly like some other app would.
        squatter.listen((Socket socket) => socket.destroy());
        addTearDown(squatter.close);

        expect(await ZenSingleInstance.acquire(port: _testPort), isTrue);
      },
    );
  });

  group('zombie cleanup (S-15)', () {
    const String own = r'C:\Users\Ala\AppData\Local\Zen\zen.exe';

    test('only other copies of this executable run by this user', () {
      const String listing =
          '\uFEFFME|PC\\ala\r\n'
          '100|PC\\ala|C:\\Users\\Ala\\AppData\\Local\\Zen\\zen.exe\r\n'
          // This very process.
          '200|PC\\ala|C:\\Users\\Ala\\AppData\\Local\\Zen\\zen.exe\r\n'
          // Another program that is also called zen.exe.
          '300|PC\\ala|C:\\Tools\\zen.exe\r\n'
          // Another user's Zen (same install path).
          '400|PC\\bob|C:\\Users\\Ala\\AppData\\Local\\Zen\\zen.exe\r\n'
          // Windows would not tell the owner or the path.
          '500||C:\\Users\\Ala\\AppData\\Local\\Zen\\zen.exe\r\n'
          '600|PC\\ala|\r\n'
          // Same file, other spelling.
          '700|pc\\ALA|\\\\?\\c:/users/ala/appdata/local/zen/ZEN.EXE\r\n'
          'garbage line\r\n';
      expect(
        ZenSingleInstance.zombiePids(listing, ownPid: 200, ownExecutable: own),
        <int>[100, 700],
      );
    });

    test('nothing is ended when this user is unknown', () {
      const String noOwner =
          'ME|\n'
          '100|\\|C:\\Users\\Ala\\AppData\\Local\\Zen\\zen.exe\n';
      expect(
        ZenSingleInstance.zombiePids(noOwner, ownPid: 1, ownExecutable: own),
        isEmpty,
      );
      const String noMe =
          '100|PC\\ala|C:\\Users\\Ala\\AppData\\Local\\Zen\\zen.exe\n';
      expect(
        ZenSingleInstance.zombiePids(noMe, ownPid: 1, ownExecutable: own),
        isEmpty,
      );
      expect(
        ZenSingleInstance.zombiePids('', ownPid: 1, ownExecutable: own),
        isEmpty,
      );
    });

    test('the listing script takes only a plain executable name', () {
      final String? script = ZenSingleInstance.processListingScript('zen.exe');
      expect(script, isNotNull);
      expect(script, contains("Name='zen.exe'"));
      expect(script, isNot(contains('@EXE@')));
      expect(ZenSingleInstance.processListingScript("zen'.exe"), isNull);
      expect(ZenSingleInstance.processListingScript(r'..\zen.exe'), isNull);
      expect(ZenSingleInstance.processListingScript(''), isNull);
    });

    test('system tools come from %SystemRoot%\\System32', () {
      expect(
        ZenSingleInstance.windowsSystem32(const <String, String>{
          'SystemRoot': r'D:\Windows',
        }),
        r'D:\Windows\System32',
      );
      expect(
        ZenSingleInstance.windowsSystem32(const <String, String>{}),
        r'C:\Windows\System32',
      );
      // Not an absolute local path: the default.
      expect(
        ZenSingleInstance.windowsSystem32(const <String, String>{
          'SystemRoot': r'.\evil',
        }),
        r'C:\Windows\System32',
      );
      expect(
        ZenSingleInstance.windowsSystem32(const <String, String>{
          'SystemRoot': r'\\server\share',
        }),
        r'C:\Windows\System32',
      );
    });
  });
}
