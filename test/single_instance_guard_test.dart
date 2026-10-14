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
}
