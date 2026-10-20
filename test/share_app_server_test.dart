import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/update/share_app_server.dart';

void main() {
  late Directory dir;
  late File apk;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zen-share-test');
    apk = File('${dir.path}/zen.apk')
      ..writeAsBytesSync(
        Uint8List.fromList(List<int>.generate(70000, (int i) => i * 7 & 0xFF)),
      );
  });

  tearDown(() => dir.delete(recursive: true));

  test('listens only on the addresses it is given', () async {
    final ShareAppServer server = ShareAppServer(
      file: apk,
      fileName: 'zen.apk',
    );
    // 192.0.2.1 (a documentation address) is not this machine's: skipped.
    await server.start(
      addresses: <InternetAddress>[
        InternetAddress.loopbackIPv4,
        InternetAddress('192.0.2.1'),
      ],
    );
    addTearDown(server.dispose);

    expect(server.servedAddresses, <InternetAddress>[
      InternetAddress.loopbackIPv4,
    ]);
    final HttpClient client = HttpClient();
    addTearDown(() => client.close(force: true));
    final HttpClientResponse response = await (await client.getUrl(
      server.fileUri(InternetAddress.loopbackIPv4),
    )).close();
    expect(response.statusCode, 200);
    await response.drain<void>();

    await server.stop();
    expect(server.isRunning, isFalse);
    expect(server.servedAddresses, isEmpty);
  });

  test('refuses to start when no address can be used', () async {
    final ShareAppServer server = ShareAppServer(
      file: apk,
      fileName: 'zen.apk',
    );
    addTearDown(server.dispose);
    await expectLater(
      server.start(addresses: <InternetAddress>[InternetAddress('192.0.2.1')]),
      throwsA(anything),
    );
    expect(server.isRunning, isFalse);
  });

  test('shares on one nearby network, never on every private address', () {
    ShareNetwork n(String name, String address) =>
        ShareNetwork(interfaceName: name, address: InternetAddress(address));
    final List<ShareNetwork> ranked = rankShareNetworks(<ShareNetwork>[
      n('eth0', '192.168.1.20'),
      n('rmnet_data0', '10.12.0.5'), // mobile data with a carrier address
      n('tun0', '10.8.0.2'), // a VPN
      n('docker0', '172.17.0.1'),
      n('vEthernet (WSL)', '172.28.0.1'),
      n('wlan0', '192.168.0.14'),
      n('lo', '127.0.0.1'),
      n('ap0', '192.168.43.1'), // this phone's hotspot
      n('eth1', '8.8.8.8'), // public: not a nearby network
    ]);
    expect(ranked.map((ShareNetwork x) => x.interfaceName), <String>[
      'ap0',
      'wlan0',
      'eth0',
    ]);

    expect(chooseShareNetwork(ranked), ranked.first);
    expect(
      chooseShareNetwork(ranked, chosen: n('eth0', '192.168.1.20')),
      ranked.last,
    );
    // A choice that is gone (the Wi-Fi changed) falls back to the best.
    expect(
      chooseShareNetwork(ranked, chosen: n('wlan1', '192.168.5.5')),
      ranked.first,
    );
    expect(chooseShareNetwork(const <ShareNetwork>[]), isNull);
    expect(ranked.first.label, 'ap0 · 192.168.43.1');
  });

  test('the checksum shown is the SHA-256 of the shared file', () async {
    expect(
      await fileSha256Hex(apk),
      sha256.convert(apk.readAsBytesSync()).toString(),
    );
    expect(groupedHex('0123456789abcdef01'), '0123 4567 89ab cdef 01');
  });
}
