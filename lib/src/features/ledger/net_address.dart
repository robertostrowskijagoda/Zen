import 'dart:io';
import 'dart:typed_data';

/// Whether [address] can be reached from the internet: not loopback, not
/// a home or company network (RFC 1918, IPv6 ULA), not link-local, not the
/// carrier's shared space (CGNAT, 100.64.0.0/10), not multicast.
///
/// Used both ways: a bridge is only announced on such an address, and a
/// probe is only ever sent to one (so nobody can make us knock on doors in
/// our own home network).
bool isPublicAddress(InternetAddress address) {
  final Uint8List b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return isPublicIpv4(b);
  }
  if (address.type != InternetAddressType.IPv6 || b.length != 16) {
    return false;
  }
  // IPv4 mapped (::ffff:a.b.c.d): judge the IPv4 part.
  final bool mapped =
      b.sublist(0, 10).every((int x) => x == 0) &&
      b[10] == 0xFF &&
      b[11] == 0xFF;
  if (mapped) {
    return isPublicIpv4(b.sublist(12));
  }
  // Only global unicast (2000::/3) counts.
  if ((b[0] & 0xE0) != 0x20) {
    return false;
  }
  // 2001:db8::/32 documentation, 2002::/16 6to4 relays.
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8) {
    return false;
  }
  return true;
}

bool isPublicIpv4(List<int> b) {
  if (b.length != 4) {
    return false;
  }
  final int a = b[0];
  final int s = b[1];
  if (a == 0 || a == 10 || a == 127 || a >= 224) {
    return false; // this network, private, loopback, multicast/reserved
  }
  if (a == 100 && (s & 0xC0) == 64) {
    return false; // 100.64.0.0/10, carrier-grade NAT
  }
  if (a == 169 && s == 254) {
    return false; // link-local
  }
  if (a == 172 && (s & 0xF0) == 16) {
    return false; // 172.16.0.0/12
  }
  if (a == 192 && s == 168) {
    return false; // 192.168.0.0/16
  }
  if (a == 192 && s == 0 && b[2] == 0) {
    return false; // 192.0.0.0/24, protocol assignments
  }
  return true;
}

/// The literal IP in [host] (brackets of an IPv6 URI host are fine), or
/// `null` for a name.
InternetAddress? ipOfHost(String host) {
  String h = host;
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  return InternetAddress.tryParse(h);
}

/// `tls://IP:port`, with brackets around an IPv6 address.
String meshTlsUri(InternetAddress address, int port) =>
    meshUri('tls', address, port);

String meshUri(String scheme, InternetAddress address, int port) =>
    address.type == InternetAddressType.IPv6
    ? '$scheme://[${address.address}]:$port'
    : '$scheme://${address.address}:$port';
