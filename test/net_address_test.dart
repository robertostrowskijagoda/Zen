import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/ledger/net_address.dart';

bool _public(String ip) => isPublicAddress(InternetAddress(ip));

void main() {
  test('addresses worth announcing: global unicast only', () {
    for (final String ip in <String>[
      '8.8.8.8',
      '2a01:4f8::7',
      '2001:200::1', // the first block handed out from 2001::/16
      '2600::1',
      '::ffff:8.8.8.8',
    ]) {
      expect(_public(ip), isTrue, reason: ip);
    }
  });

  test('home, carrier, tunnel and test ranges are never public', () {
    for (final String ip in <String>[
      // IPv4
      '0.1.2.3',
      '10.0.0.1',
      '100.64.0.1', // CGNAT
      '100.127.255.254',
      '127.0.0.1',
      '169.254.1.1',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.1',
      '192.0.0.8',
      '224.0.0.251',
      '255.255.255.255',
      // IPv6
      '::1',
      '::',
      'fe80::1', // link-local
      'fd00::1', // unique local
      'fc00::1',
      'ff02::1', // multicast
      '64:ff9b::c0a8:101', // NAT64 of 192.168.1.1
      '::ffff:192.168.1.1',
      '2001:db8::1', // documentation
      '3fff::1', // documentation (RFC 9637)
      '3fff:fff::1',
      '2002:c0a8:101::1', // 6to4 of 192.168.1.1
      '2002:808:808::1', // 6to4 of a public address: deprecated relays
      '2001:0:4136:e378::1', // Teredo
      '2001:2::1', // benchmarking
      '2001:20::1', // ORCHIDv2
      '2001:1ff::1', // the end of 2001::/23
    ]) {
      expect(_public(ip), isFalse, reason: ip);
    }
  });
}
