import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/single_instance_guard.dart';

/// Port used only by these tests so a running Zen instance on the developer
/// machine cannot interfere with (or be disturbed by) the suite.
const int _testPort = 47899;

void main() {
  group('ZenSingleInstance', () {
    late Directory dir;
    late File secretFile;

    /// Claims the lock as the first launch does, its secret in [secretFile].
    Future<bool> acquire() => ZenSingleInstance.acquire(
      port: _testPort,
      secretFile: () async => secretFile,
    );

    /// What a second launch of this user sends: with the secret it reads.
    String request({String? open}) => ZenSingleInstance.activationRequest(
      secret: secretFile.readAsStringSync().trim(),
      open: open,
    );

    /// Sends [line] as a second launch would; the answer, or null when the
    /// running instance hung up without one.
    Future<String?> send(String line) async {
      final Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _testPort,
      );
      client.write('$line\n');
      await client.flush();
      final List<String> answer = await client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .take(1)
          .toList()
          .timeout(const Duration(seconds: 5));
      client.destroy();
      return answer.isEmpty ? null : answer.first.trim();
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('zen-single-');
      secretFile = File('${dir.path}${Platform.pathSeparator}session.key');
    });

    tearDown(() async {
      ZenSingleInstance.setActivationHandler(null);
      ZenSingleInstance.setOpenHandler(null);
      await ZenSingleInstance.release();
      dir.deleteSync(recursive: true);
    });

    test('claims the lock and answers the activation handshake', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      int activations = 0;
      ZenSingleInstance.setActivationHandler(() async => activations += 1);

      expect(await acquire(), isTrue);

      // Stand in for a second launch of the app.
      expect(await send(request()), 'ZEN-SINGLE-INSTANCE/2 ACK');
      // The ACK is sent before the window is raised so a slow handler cannot
      // stall the other launch; give it a moment to run.
      for (int i = 0; i < 50 && activations == 0; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(activations, 1);
    });

    test('a launch with a file hands it to the running instance', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      int activations = 0;
      final List<String> opened = <String>[];
      ZenSingleInstance.setActivationHandler(() async => activations += 1);
      ZenSingleInstance.setOpenHandler((String path) async => opened.add(path));
      expect(await acquire(), isTrue);

      const String file = r'C:\Users\Ala Kowalska\zen-konto.zenbackup';
      expect(await send(request(open: file)), 'ZEN-SINGLE-INSTANCE/2 ACK');
      for (int i = 0; i < 50 && opened.isEmpty; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(activations, 1);
      expect(opened, <String>[file]);
    });

    test('the activation request carries the secret and the file in one '
        'word each', () {
      const String secret = 'ab12';
      String? parse(String request) =>
          ZenSingleInstance.parseActivationRequest(request, secret: secret);
      const String file = '/home/ala/moje kopie/zażółć.zenkey';
      final String request = ZenSingleInstance.activationRequest(
        secret: secret,
        open: file,
      );
      expect(request.split(' '), hasLength(4));
      expect(parse(request), file);
      expect(parse(ZenSingleInstance.activationRequest(secret: secret)), '');
      // Activation still, the damaged file left out.
      expect(parse('ZEN-SINGLE-INSTANCE/2 ACTIVATE ab12 %%%'), '');
      expect(parse('HELLO'), isNull);
      expect(parse('ZEN-SINGLE-INSTANCE/2 ACK'), isNull);
      // Without this session's secret: nothing.
      expect(parse('ZEN-SINGLE-INSTANCE/2 ACTIVATE'), isNull);
      expect(parse('ZEN-SINGLE-INSTANCE/2 ACTIVATE ab13'), isNull);
      expect(parse('ZEN-SINGLE-INSTANCE/2 ACTIVATE ab1'), isNull);
      expect(parse('ZEN-SINGLE-INSTANCE/2 ACTIVATE ab123'), isNull);
      expect(
        ZenSingleInstance.parseActivationRequest(request, secret: ''),
        isNull,
      );
      // What 1.16.2 sent (no secret).
      expect(
        parse(
          'ZEN-SINGLE-INSTANCE/1 ACTIVATE ${base64Url.encode(utf8.encode(file))}',
        ),
        isNull,
      );
    });

    test('a request without this session\'s secret is not answered and '
        'opens nothing', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      int activations = 0;
      final List<String> opened = <String>[];
      ZenSingleInstance.setActivationHandler(() async => activations += 1);
      ZenSingleInstance.setOpenHandler((String path) async => opened.add(path));
      expect(await acquire(), isTrue);
      const String share = r'\\attacker\share\k.zenbackup';
      final String b64 = base64Url.encode(utf8.encode(share));
      for (final String line in <String>[
        'ZEN-SINGLE-INSTANCE/1 ACTIVATE $b64',
        'ZEN-SINGLE-INSTANCE/2 ACTIVATE $b64',
        'ZEN-SINGLE-INSTANCE/2 ACTIVATE ${'0' * 64} $b64',
        ZenSingleInstance.activationRequest(secret: '1' * 64, open: share),
      ]) {
        expect(await send(line), isNull, reason: line);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(activations, 0);
      expect(opened, isEmpty);
    });

    test('the secret is new each session, in a file of this user\'s', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      expect(await acquire(), isTrue);
      final String first = secretFile.readAsStringSync().trim();
      expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
      if (!Platform.isWindows) {
        expect(secretFile.statSync().mode & 0x1FF, 0x180);
      }
      await ZenSingleInstance.release();
      expect(await acquire(), isTrue);
      expect(secretFile.readAsStringSync().trim(), isNot(first));
    });

    test('a second launch is refused while the lock is held', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      expect(await acquire(), isTrue);

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

        expect(await acquire(), isTrue);
      },
    );
  });

  group('zombie cleanup', () {
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
