import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_peer_warmup.dart';

void main() {
  test('rewrites a hostname peer to an IPv4 literal with sni', () {
    final String rewritten = rewritePeerUriToLiteral(
      Uri.parse('tls://ygg.example:443?key=abc'),
      InternetAddress('203.0.113.10'),
    );

    expect(rewritten, contains('203.0.113.10'));
    expect(rewritten, contains('sni=ygg.example'));
    expect(rewritten, contains('key=abc'));
  });

  test('selectReachablePeerUris keeps the first working candidates', () async {
    final List<String> selected = await selectReachablePeerUris(
      <String>[
        'tls://dead.example:443',
        'tls://ygg.example:443',
        'tls://203.0.113.9:443',
      ],
      lookup: (String host) async {
        if (host == 'dead.example') {
          throw const SocketException('no such host');
        }
        if (host == 'ygg.example') {
          return <InternetAddress>[InternetAddress('203.0.113.10')];
        }
        return <InternetAddress>[InternetAddress(host)];
      },
      probe: (InternetAddress address, int port, Duration timeout) async {
        if (address.address == '203.0.113.9' ||
            address.address == '203.0.113.10') {
          return;
        }
        throw const SocketException('refused');
      },
    );

    expect(selected, hasLength(2));
    expect(selected.first, contains('203.0.113.10'));
    expect(selected.first, contains('sni=ygg.example'));
    expect(selected.last, contains('203.0.113.9'));
  });

  test(
    'injectReachablePeersIntoConfig writes Peers and disables multicast',
    () async {
      final String next = await injectReachablePeersIntoConfig(
        '{"PrivateKey":"abc","Peers":[]}',
        candidates: <String>['tls://203.0.113.10:443'],
        lookup: (String host) async => <InternetAddress>[InternetAddress(host)],
        probe: (InternetAddress address, int port, Duration timeout) async {},
      );

      expect(next, contains('"Peers":["tls://203.0.113.10:443"]'));
      expect(next, contains('"IfName":"none"'));
      expect(next, contains('"MulticastInterfaces":[]'));
    },
  );
}
