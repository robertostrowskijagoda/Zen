import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/single_instance_guard.dart';

/// Port used only by these tests so a running Zen instance on the developer
/// machine cannot interfere with (or be disturbed by) the suite.
const int _testPort = 47899;

/// The lines a peer sends over [socket], read one at a time with a timeout;
/// every line read is also added to [heard].
class _Lines {
  _Lines(this._socket, this.heard)
    : _iterator = StreamIterator<String>(
        _socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  final Socket _socket;
  final List<String> heard;
  final StreamIterator<String> _iterator;

  void send(String line) => _socket.write('$line\n');

  /// The next line, or null when the peer hangs up or says nothing.
  Future<String?> read() async {
    try {
      final bool has = await _iterator.moveNext().timeout(
        const Duration(seconds: 5),
      );
      if (!has) {
        return null;
      }
      heard.add(_iterator.current);
      return _iterator.current.trim();
    } on Object {
      return null;
    }
  }
}

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

  group('ZenSingleInstance, who is on the port', () {
    late Directory dir;
    late File secretFile;
    final List<ServerSocket> squatters = <ServerSocket>[];

    const String opened = r'C:\Users\victim\Documents\private-backup.zenbackup';
    final String openedWord = base64Url.encode(utf8.encode(opened));
    final String staleSecret = 'a1' * 32;

    /// Claims the lock as the first launch does.
    Future<bool> acquire({String? open}) => ZenSingleInstance.acquire(
      port: _testPort,
      open: open,
      secretFile: () async => secretFile,
    );

    /// A program of another user that got to the port first: [behave] runs
    /// for every connection with the lines it reads; everything it hears is
    /// added to [heard].
    Future<void> squat(
      List<String> heard,
      Future<void> Function(Socket socket, _Lines lines) behave,
    ) async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _testPort,
      );
      squatters.add(server);
      server.listen((Socket socket) async {
        final _Lines lines = _Lines(socket, heard);
        try {
          await behave(socket, lines);
        } on Object {
          // The launch hung up.
        } finally {
          socket.destroy();
        }
      });
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('zen-single-who-');
      secretFile = File('${dir.path}${Platform.pathSeparator}session.key');
    });

    tearDown(() async {
      ZenSingleInstance.setActivationHandler(null);
      ZenSingleInstance.setOpenHandler(null);
      await ZenSingleInstance.release();
      for (final ServerSocket server in squatters) {
        await server.close();
      }
      squatters.clear();
      dir.deleteSync(recursive: true);
    });

    /// What the squatter must never have been told.
    void expectNothingLeaked(List<String> heard, String secret) {
      final String all = heard.join('\n');
      expect(all, isNot(contains(secret)));
      expect(all, isNot(contains(openedWord)));
      expect(all, isNot(contains(opened)));
      expect(all, isNot(contains('ZEN-SINGLE-INSTANCE/2 ACTIVATE')));
      expect(all, isNot(contains('ACTIVATE')));
    }

    /// A connection to the real owner that speaks the challenge by hand.
    Future<_Lines> connect() async {
      final Socket socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _testPort,
      );
      addTearDown(socket.destroy);
      return _Lines(socket, <String>[]);
    }

    test('an honest second start proves the owner, then hands the file '
        'over', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      int activations = 0;
      final List<String> received = <String>[];
      ZenSingleInstance.setActivationHandler(() async => activations += 1);
      ZenSingleInstance.setOpenHandler(
        (String path) async => received.add(path),
      );
      expect(await acquire(), isTrue);
      final String secret = secretFile.readAsStringSync().trim();

      // The guard short-circuits inside the owning process, so the second
      // start is the part of it that talks to the port.
      expect(
        await ZenSingleInstance.handOverToRunningInstance(
          port: _testPort,
          secret: secret,
          open: opened,
        ),
        isTrue,
      );
      for (int i = 0; i < 50 && received.isEmpty; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(activations, 1);
      expect(received, <String>[opened]);

      // Without a file: activation only.
      expect(
        await ZenSingleInstance.handOverToRunningInstance(
          port: _testPort,
          secret: secret,
        ),
        isTrue,
      );
      for (int i = 0; i < 50 && activations < 2; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(activations, 2);
      expect(received, <String>[opened]);
    });

    test(
      'the secret never crosses the socket, even to the real owner',
      () async {
        if (!ZenSingleInstance.isSupported) {
          return;
        }
        expect(await acquire(), isTrue);
        final String secret = secretFile.readAsStringSync().trim();
        final _Lines client = await connect();
        final String nonce = 'b2' * 16;
        client.send('ZEN-SINGLE-INSTANCE/3 HELLO $nonce');
        final String? proof = await client.read();
        expect(proof, isNotNull);
        expect(proof, isNot(contains(secret)));
        final List<String> words = proof!.split(' ');
        expect(words.sublist(0, 2), <String>['ZEN-SINGLE-INSTANCE/3', 'PROOF']);
        expect(
          words[3],
          ZenSingleInstance.ownerProof(
            secret: secret,
            clientNonce: nonce,
            serverNonce: words[2],
          ),
        );
      },
    );

    test('a squatter that answers like the old handshake gets neither the '
        'secret nor the file, and the launch is not taken for a second '
        'Zen', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      // A session of this user that has ended and left its secret.
      secretFile.writeAsStringSync(staleSecret);
      final List<String> heard = <String>[];
      await squat(heard, (Socket socket, _Lines lines) async {
        await lines.read();
        socket.write('ZEN-SINGLE-INSTANCE/2 ACK\n');
        socket.write('ZEN-SINGLE-INSTANCE/3 ACK\n');
        await socket.flush();
        await lines.read();
      });

      // Starts (true): the ACK of something that proved nothing is no
      // reason to quit.
      expect(await acquire(open: opened), isTrue);
      expect(heard, isNotEmpty);
      expectNothingLeaked(heard, staleSecret);
      for (final String line in heard) {
        expect(line, startsWith('ZEN-SINGLE-INSTANCE/3 HELLO '));
        expect(line.split(' '), hasLength(3));
      }
    });

    test('a squatter whose proof is wrong is sent nothing more', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      secretFile.writeAsStringSync(staleSecret);
      final List<String> heard = <String>[];
      final List<bool> replied = <bool>[];
      await squat(heard, (Socket socket, _Lines lines) async {
        final String? hello = await lines.read();
        // It has no secret, but sees the nonce and answers in the right
        // shape, with a proof under a key of its own.
        final String clientNonce = hello!.split(' ')[2];
        final String serverNonce = 'c3' * 16;
        socket.write(
          'ZEN-SINGLE-INSTANCE/3 PROOF $serverNonce '
          '${ZenSingleInstance.ownerProof(secret: '0' * 64, clientNonce: clientNonce, serverNonce: serverNonce)}\n',
        );
        await socket.flush();
        replied.add(true);
        // Whatever comes next would be the file; nothing does.
        final String? next = await lines.read();
        expect(next, isNull);
      });

      expect(await acquire(open: opened), isTrue);
      expect(replied, isNotEmpty);
      expect(heard.every((String l) => l.contains(' HELLO ')), isTrue);
      expectNothingLeaked(heard, staleSecret);
    });

    test('a squatter with a proof copied from another conversation is not '
        'believed', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      expect(await acquire(), isTrue);
      final String secret = secretFile.readAsStringSync().trim();
      // A proof the real owner made for some other nonce.
      final _Lines spy = await connect();
      spy.send('ZEN-SINGLE-INSTANCE/3 HELLO ${'d4' * 16}');
      final String recorded = (await spy.read())!;
      await ZenSingleInstance.release();

      final List<String> heard = <String>[];
      await squat(heard, (Socket socket, _Lines lines) async {
        await lines.read();
        socket.write('$recorded\n');
        await socket.flush();
        expect(await lines.read(), isNull);
      });
      expect(
        await ZenSingleInstance.handOverToRunningInstance(
          port: _testPort,
          secret: secret,
          open: opened,
        ),
        isFalse,
      );
      expect(heard, hasLength(1));
      expectNothingLeaked(heard, secret);
    });

    test('a launch started beside a 1.16.4 copy sends it nothing it could '
        'be fooled with and starts without the service', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      // What 1.16.4 runs: answers only the request that carries the secret.
      const String oldSecret =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      secretFile.writeAsStringSync(oldSecret);
      final List<String> heard = <String>[];
      await squat(heard, (Socket socket, _Lines lines) async {
        final String? line = await lines.read();
        if (line != null &&
            ZenSingleInstance.parseActivationRequest(line, secret: oldSecret) !=
                null) {
          socket.write('ZEN-SINGLE-INSTANCE/2 ACK\n');
          await socket.flush();
        }
      });

      expect(await acquire(open: opened), isTrue);
      expect(heard, isNotEmpty);
      expectNothingLeaked(heard, oldSecret);
    });

    test('a 1.16.4 launch still reaches a new copy', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      final List<String> received = <String>[];
      ZenSingleInstance.setOpenHandler(
        (String path) async => received.add(path),
      );
      expect(await acquire(), isTrue);
      final _Lines client = await connect();
      client.send(
        ZenSingleInstance.activationRequest(
          secret: secretFile.readAsStringSync().trim(),
          open: opened,
        ),
      );
      expect(await client.read(), 'ZEN-SINGLE-INSTANCE/2 ACK');
      for (int i = 0; i < 50 && received.isEmpty; i += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(received, <String>[opened]);
    });

    test('a launch with a wrong proof gets no ACK and opens nothing', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      int activations = 0;
      final List<String> received = <String>[];
      ZenSingleInstance.setActivationHandler(() async => activations += 1);
      ZenSingleInstance.setOpenHandler(
        (String path) async => received.add(path),
      );
      expect(await acquire(), isTrue);
      final String secret = secretFile.readAsStringSync().trim();

      Future<void> attempt(
        String Function(String clientNonce, String serverNonce) mac, {
        String carried = '',
      }) async {
        final _Lines client = await connect();
        final String clientNonce = 'e5' * 16;
        client.send('ZEN-SINGLE-INSTANCE/3 HELLO $clientNonce');
        final String serverNonce = (await client.read())!.split(' ')[2];
        client.send(
          'ZEN-SINGLE-INSTANCE/3 ACTIVATE ${mac(clientNonce, serverNonce)}'
          '${carried.isEmpty ? '' : ' $carried'}',
        );
        expect(await client.read(), isNull);
      }

      // Under a secret of its own (the stale one of a crashed session).
      await attempt(
        (String c, String s) => ZenSingleInstance.launcherProof(
          secret: staleSecret,
          clientNonce: c,
          serverNonce: s,
          open: openedWord,
        ),
        carried: openedWord,
      );
      // The owner's own proof handed back as the launch's (reflection).
      await attempt(
        (String c, String s) => ZenSingleInstance.ownerProof(
          secret: secret,
          clientNonce: c,
          serverNonce: s,
        ),
      );
      // A good proof for another file than the one carried.
      await attempt(
        (String c, String s) => ZenSingleInstance.launcherProof(
          secret: secret,
          clientNonce: c,
          serverNonce: s,
        ),
        carried: openedWord,
      );
      // A good proof for other nonces.
      await attempt(
        (String c, String s) => ZenSingleInstance.launcherProof(
          secret: secret,
          clientNonce: 'f6' * 16,
          serverNonce: s,
          open: openedWord,
        ),
        carried: openedWord,
      );
      // Not a proof at all.
      await attempt((String c, String s) => 'zz', carried: openedWord);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(activations, 0);
      expect(received, isEmpty);

      // A malformed or oversized request is not answered either.
      for (final String line in <String>[
        'ZEN-SINGLE-INSTANCE/3 HELLO nonce',
        'ZEN-SINGLE-INSTANCE/3 HELLO ${'a' * 31}',
        'ZEN-SINGLE-INSTANCE/3 ACTIVATE ${'a' * 64}',
        'ZEN-SINGLE-INSTANCE/3',
      ]) {
        final _Lines client = await connect();
        client.send(line);
        expect(await client.read(), isNull, reason: line);
      }
      final _Lines flood = await connect();
      flood.send('x' * (64 * 1024));
      expect(await flood.read(), isNull);
      expect(activations, 0);
    });

    test('the secret of a crashed session is replaced, and what it opened '
        'is shut', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      // A session that was killed: its file is still there.
      secretFile.writeAsStringSync(staleSecret);
      final List<String> received = <String>[];
      ZenSingleInstance.setOpenHandler(
        (String path) async => received.add(path),
      );
      expect(await acquire(), isTrue);
      final String fresh = secretFile.readAsStringSync().trim();
      expect(fresh, isNot(staleSecret));
      expect(fresh, matches(RegExp(r'^[0-9a-f]{64}$')));

      expect(
        await ZenSingleInstance.handOverToRunningInstance(
          port: _testPort,
          secret: staleSecret,
          open: opened,
        ),
        isFalse,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
      expect(
        await ZenSingleInstance.handOverToRunningInstance(
          port: _testPort,
          secret: fresh,
          open: opened,
        ),
        isTrue,
      );
    });

    test('the secret file is only the secret, written without leftovers, '
        'and gone at release', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      expect(await acquire(), isTrue);
      expect(secretFile.existsSync(), isTrue);
      expect(
        dir.listSync().map((FileSystemEntity e) => e.path).toList(),
        <String>[secretFile.path],
      );
      if (!Platform.isWindows) {
        expect(secretFile.statSync().mode & 0x1FF, 0x180);
      }
      await ZenSingleInstance.release();
      expect(secretFile.existsSync(), isFalse);
      expect(dir.listSync(), isEmpty);
      // Releasing again is harmless.
      await ZenSingleInstance.release();
    });

    test('a launch without a secret file cannot prove anything and starts '
        'beside a stranger', () async {
      if (!ZenSingleInstance.isSupported) {
        return;
      }
      final List<String> heard = <String>[];
      await squat(heard, (Socket socket, _Lines lines) async {
        await lines.read();
        socket.write('ZEN-SINGLE-INSTANCE/3 ACK\n');
        await socket.flush();
      });
      expect(await acquire(open: opened), isTrue);
      expectNothingLeaked(heard, staleSecret);
    });
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
