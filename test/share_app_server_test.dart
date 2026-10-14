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

  test('the checksum shown is the SHA-256 of the shared file', () async {
    expect(
      await fileSha256Hex(apk),
      sha256.convert(apk.readAsBytesSync()).toString(),
    );
    expect(groupedHex('0123456789abcdef01'), '0123 4567 89ab cdef 01');
  });
}
