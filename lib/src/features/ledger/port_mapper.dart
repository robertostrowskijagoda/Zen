import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// A port the home router forwards to this computer (§5.1): what lets
/// other people's apps connect to it, so it can be a bridge.
@immutable
final class PortMapping {
  const PortMapping({
    required this.method,
    required this.internalPort,
    required this.externalPort,
    required this.lease,
    required this.externalAddress,
    required this.remove,
  });

  /// `upnp` or `natpmp`.
  final String method;
  final int internalPort;
  final int externalPort;

  /// Zero: until removed (some routers only allow that).
  final Duration lease;

  /// The router's address on the internet, if it told us.
  final InternetAddress? externalAddress;

  /// Takes the forwarding off the router again.
  final Future<void> Function() remove;
}

/// External ports asked for first: the mesh speaks TLS, so a bridge on 443
/// looks like any HTTPS server to whoever watches the traffic (§14.2).
const List<int> kDisguisedExternalPorts = <int>[443];

/// Opens a TCP port on the home router.
abstract interface class PortMapper {
  Future<PortMapping?> map(
    int port, {
    Duration lease = const Duration(hours: 2),
  });

  /// After a `null` from [map]: whether a router was there but said no
  /// (UPnP switched off for changes in its settings, most often), rather
  /// than no router answering at all.
  bool get routerRefused;

  /// The router's internet address when it told us even though it opened
  /// nothing (someone may have forwarded the port by hand).
  InternetAddress? get knownExternalAddress;
}

/// Tries UPnP (most home routers) and then NAT-PMP (Apple routers, some
/// others). Returns `null` when the router does neither, or refuses.
final class RouterPortMapper implements PortMapper {
  RouterPortMapper({UpnpPortMapper? upnp, NatPmpPortMapper? natPmp})
    : _upnp = upnp ?? UpnpPortMapper(),
      _natPmp = natPmp ?? NatPmpPortMapper();

  final UpnpPortMapper _upnp;
  final NatPmpPortMapper _natPmp;

  @override
  bool get routerRefused => _upnp.refused;

  @override
  InternetAddress? get knownExternalAddress =>
      _upnp.externalAddress ?? _natPmp.externalAddress;

  @override
  Future<PortMapping?> map(
    int port, {
    Duration lease = const Duration(hours: 2),
  }) async {
    _upnp
      ..refused = false
      ..externalAddress = null;
    _natPmp.externalAddress = null;
    try {
      final PortMapping? viaUpnp = await _upnp.map(port, lease: lease);
      if (viaUpnp != null) {
        return viaUpnp;
      }
    } on Object catch (error) {
      logZenWarning('UPnP: $error');
    }
    try {
      return await _natPmp.map(port, lease: lease);
    } on Object catch (error) {
      logZenWarning('NAT-PMP: $error');
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// UPnP Internet Gateway Device
// ---------------------------------------------------------------------------

/// Finds routers on the local network: the `LOCATION` URLs of their device
/// descriptions.
typedef UpnpDiscovery = Future<List<Uri>> Function(Duration wait);

const List<String> _wanServices = <String>[
  'urn:schemas-upnp-org:service:WANIPConnection:2',
  'urn:schemas-upnp-org:service:WANIPConnection:1',
  'urn:schemas-upnp-org:service:WANPPPConnection:1',
];

/// SSDP search on 239.255.255.250:1900.
Future<List<Uri>> ssdpDiscover(Duration wait) async {
  final RawDatagramSocket socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    0,
  );
  final Set<Uri> found = <Uri>{};
  final Completer<void> done = Completer<void>();
  final StreamSubscription<RawSocketEvent> sub = socket.listen((
    RawSocketEvent event,
  ) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final Datagram? d = socket.receive();
    if (d == null) {
      return;
    }
    final Uri? location = parseSsdpLocation(latin1.decode(d.data));
    if (location != null) {
      found.add(location);
    }
  });
  for (final String target in <String>[
    'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
    'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
    ..._wanServices,
  ]) {
    socket.send(
      ascii.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $target\r\n\r\n',
      ),
      InternetAddress('239.255.255.250'),
      1900,
    );
  }
  final Timer timer = Timer(wait, () {
    if (!done.isCompleted) {
      done.complete();
    }
  });
  await done.future;
  timer.cancel();
  await sub.cancel();
  socket.close();
  return found.toList();
}

/// The `LOCATION` of an SSDP answer, only if it points into the local
/// network over plain http (a router never lives elsewhere).
Uri? parseSsdpLocation(String response) {
  for (final String line in const LineSplitter().convert(response)) {
    final int colon = line.indexOf(':');
    if (colon <= 0 ||
        line.substring(0, colon).trim().toLowerCase() != 'location') {
      continue;
    }
    final Uri? uri = Uri.tryParse(line.substring(colon + 1).trim());
    if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) {
      return null;
    }
    final InternetAddress? ip = InternetAddress.tryParse(uri.host);
    if (ip == null || !_isLocal(ip)) {
      return null;
    }
    return uri;
  }
  return null;
}

bool _isLocal(InternetAddress ip) {
  if (ip.type != InternetAddressType.IPv4) {
    return ip.isLinkLocal || ip.isLoopback;
  }
  final Uint8List b = ip.rawAddress;
  return b[0] == 10 ||
      b[0] == 127 ||
      (b[0] == 172 && (b[1] & 0xF0) == 16) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254) ||
      (b[0] == 100 && (b[1] & 0xC0) == 64);
}

/// A WAN connection service found in a router's description.
@immutable
final class UpnpService {
  const UpnpService(this.type, this.control);

  final String type;
  final Uri control;
}

/// The WAN connection services in a device description (XML), best first.
List<UpnpService> parseUpnpServices(String xml, Uri location) {
  final Match? base = RegExp(
    r'<URLBase>\s*([^<]+?)\s*</URLBase>',
    caseSensitive: false,
  ).firstMatch(xml);
  final Uri root = base != null
      ? (Uri.tryParse(base.group(1)!) ?? location)
      : location;
  final List<UpnpService> out = <UpnpService>[];
  for (final Match m in RegExp(
    r'<service>(.*?)</service>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(xml)) {
    final String block = m.group(1)!;
    final String? type = _tag(block, 'serviceType');
    final String? control = _tag(block, 'controlURL');
    if (type == null || control == null || !_wanServices.contains(type)) {
      continue;
    }
    final Uri url = root.resolve(control);
    // Never talk to anything but the router that answered.
    if (url.host != location.host) {
      continue;
    }
    out.add(UpnpService(type, url));
  }
  out.sort(
    (UpnpService a, UpnpService b) =>
        _wanServices.indexOf(a.type).compareTo(_wanServices.indexOf(b.type)),
  );
  return out;
}

String? _tag(String xml, String name) {
  final Match? m = RegExp(
    '<(?:[A-Za-z0-9_]+:)?$name>\\s*([^<]*?)\\s*</(?:[A-Za-z0-9_]+:)?$name>',
    caseSensitive: false,
  ).firstMatch(xml);
  return m?.group(1);
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// A SOAP call failed: [code] is the UPnP error (718 = port taken, 725 =
/// only permanent leases), or `null` for anything else.
final class UpnpError implements Exception {
  const UpnpError(this.code, this.message);

  final int? code;
  final String message;

  @override
  String toString() => 'UPnP ${code ?? '-'}: $message';
}

final class UpnpPortMapper {
  UpnpPortMapper({
    UpnpDiscovery? discover,
    this.wait = const Duration(seconds: 3),
    this.description = 'Zen',
    this.preferredExternalPorts = kDisguisedExternalPorts,
  }) : _discover = discover ?? ssdpDiscover;

  final UpnpDiscovery _discover;
  final Duration wait;
  final String description;

  /// How many external ports to try when the first one is taken.
  static const int portAttempts = 5;

  /// External ports tried first (§14.2: from outside, the bridge looks like
  /// an ordinary HTTPS server on 443).
  final List<int> preferredExternalPorts;

  List<int> _candidates(int port) => <int>[
    ...preferredExternalPorts.where((int p) => p != port),
    for (int i = 0; i < portAttempts; i++) port + i,
  ];

  /// The last [map] found a router that would not open the port.
  bool refused = false;

  /// What the router said its internet address is (last [map]).
  InternetAddress? externalAddress;

  Future<PortMapping?> map(
    int port, {
    Duration lease = const Duration(hours: 2),
  }) async {
    for (final Uri location in await _discover(wait)) {
      final List<UpnpService> services;
      try {
        services = parseUpnpServices(await _get(location), location);
      } on Object catch (error) {
        logZenWarning('UPnP: opis routera $location: $error');
        continue;
      }
      for (final UpnpService service in services) {
        final PortMapping? mapping = await _mapWith(service, port, lease);
        if (mapping != null) {
          return mapping;
        }
      }
    }
    return null;
  }

  Future<PortMapping?> _mapWith(
    UpnpService service,
    int port,
    Duration lease,
  ) async {
    final InternetAddress? local = await _localAddressTowards(service.control);
    if (local == null) {
      return null;
    }
    InternetAddress? external;
    try {
      final Map<String, String> got = await _call(
        service,
        'GetExternalIPAddress',
        const <String, String>{},
      );
      external = InternetAddress.tryParse(got['NewExternalIPAddress'] ?? '');
      externalAddress = external;
    } on Object catch (error) {
      logZenWarning('UPnP: GetExternalIPAddress: $error');
    }
    Duration useLease = lease;
    for (final int externalPort in _candidates(port)) {
      Future<void> add() => _call(service, 'AddPortMapping', <String, String>{
        'NewRemoteHost': '',
        'NewExternalPort': '$externalPort',
        'NewProtocol': 'TCP',
        'NewInternalPort': '$port',
        'NewInternalClient': local.address,
        'NewEnabled': '1',
        'NewPortMappingDescription': description,
        'NewLeaseDuration': '${useLease.inSeconds}',
      });
      try {
        try {
          await add();
        } on UpnpError catch (e) {
          if (e.code != 725 || useLease == Duration.zero) {
            rethrow;
          }
          useLease = Duration.zero;
          await add();
        }
        return PortMapping(
          method: 'upnp',
          internalPort: port,
          externalPort: externalPort,
          lease: useLease,
          externalAddress: external,
          remove: () async {
            try {
              await _call(service, 'DeletePortMapping', <String, String>{
                'NewRemoteHost': '',
                'NewExternalPort': '$externalPort',
                'NewProtocol': 'TCP',
              });
            } on Object catch (error) {
              logZenWarning('UPnP: zamknięcie portu: $error');
            }
          },
        );
      } on UpnpError catch (e) {
        // 718: someone else has this port; 724: this router only maps a
        // port to the same port. Either way, try the next one.
        if (e.code == 718 || e.code == 724) {
          continue;
        }
        logZenWarning('UPnP: AddPortMapping: $e');
        refused = true;
        return null;
      }
    }
    return null;
  }

  /// Our address on the network the router is in (what it must forward
  /// to).
  Future<InternetAddress?> _localAddressTowards(Uri control) async {
    try {
      final Socket s = await Socket.connect(
        control.host,
        control.port,
        timeout: const Duration(seconds: 3),
      );
      final InternetAddress local = s.address;
      s.destroy();
      return local;
    } on Object {
      return null;
    }
  }

  Future<String> _get(Uri url) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..findProxy = (_) => 'DIRECT';
    try {
      final HttpClientRequest req = await client.getUrl(url);
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 5),
      );
      return await _readLimited(res);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, String>> _call(
    UpnpService service,
    String action,
    Map<String, String> args,
  ) async {
    final StringBuffer body = StringBuffer()
      ..write('<?xml version="1.0"?>')
      ..write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">',
      )
      ..write('<s:Body><u:$action xmlns:u="${service.type}">');
    args.forEach(
      (String k, String v) => body.write('<$k>${_xmlEscape(v)}</$k>'),
    );
    body.write('</u:$action></s:Body></s:Envelope>');
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..findProxy = (_) => 'DIRECT';
    try {
      final HttpClientRequest req = await client.postUrl(service.control);
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"')
        ..set('SOAPAction', '"${service.type}#$action"');
      req.add(utf8.encode(body.toString()));
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 5),
      );
      final String text = await _readLimited(res);
      if (res.statusCode != 200) {
        final String? code = _tag(text, 'errorCode');
        throw UpnpError(
          code == null ? null : int.tryParse(code),
          _tag(text, 'errorDescription') ?? 'HTTP ${res.statusCode}',
        );
      }
      final Map<String, String> out = <String, String>{};
      for (final Match m in RegExp(
        r'<(New[A-Za-z]+)>([^<]*)</\1>',
      ).allMatches(text)) {
        out[m.group(1)!] = m.group(2)!.trim();
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _readLimited(HttpClientResponse res) async {
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in res.timeout(
      const Duration(seconds: 5),
    )) {
      bytes.add(chunk);
      if (bytes.length > 256 * 1024) {
        throw const UpnpError(null, 'odpowiedź routera jest za duża');
      }
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}

// ---------------------------------------------------------------------------
// NAT-PMP (RFC 6886)
// ---------------------------------------------------------------------------

/// Finds the default gateway (the router) of this computer.
typedef GatewayLookup = Future<List<InternetAddress>> Function();

Future<List<InternetAddress>> systemGateways() async {
  try {
    if (Platform.isWindows) {
      final ProcessResult r = await Process.run('route', <String>[
        'print',
        '-4',
        '0.0.0.0',
      ]);
      return parseWindowsRoutes(r.stdout.toString());
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return parseLinuxRoutes(await File('/proc/net/route').readAsString());
    }
    if (Platform.isMacOS) {
      final ProcessResult r = await Process.run('route', <String>[
        '-n',
        'get',
        'default',
      ]);
      final Match? m = RegExp(
        r'gateway:\s*([0-9.]+)',
      ).firstMatch(r.stdout.toString());
      final InternetAddress? ip = InternetAddress.tryParse(m?.group(1) ?? '');
      return ip == null ? <InternetAddress>[] : <InternetAddress>[ip];
    }
  } on Object catch (error) {
    logZenWarning('Nie znalazłem bramy sieci: $error');
  }
  return <InternetAddress>[];
}

/// Default routes in `route print -4 0.0.0.0` (the numbers are not
/// translated, whatever the Windows language).
List<InternetAddress> parseWindowsRoutes(String text) {
  final List<InternetAddress> out = <InternetAddress>[];
  for (final Match m in RegExp(
    r'^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+([0-9.]+)\s',
    multiLine: true,
  ).allMatches(text)) {
    final InternetAddress? ip = InternetAddress.tryParse(m.group(1)!);
    if (ip != null && !out.contains(ip)) {
      out.add(ip);
    }
  }
  return out;
}

/// Default routes in /proc/net/route (little-endian hex).
List<InternetAddress> parseLinuxRoutes(String text) {
  final List<InternetAddress> out = <InternetAddress>[];
  for (final String line in const LineSplitter().convert(text).skip(1)) {
    final List<String> f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 3 || f[1] != '00000000') {
      continue;
    }
    final int? g = int.tryParse(f[2], radix: 16);
    if (g == null || g == 0) {
      continue;
    }
    out.add(
      InternetAddress.fromRawAddress(
        Uint8List.fromList(<int>[
          g & 0xFF,
          (g >> 8) & 0xFF,
          (g >> 16) & 0xFF,
          (g >> 24) & 0xFF,
        ]),
      ),
    );
  }
  return out;
}

final class NatPmpPortMapper {
  NatPmpPortMapper({GatewayLookup? gateways, this.serverPort = 5351})
    : _gateways = gateways ?? systemGateways;

  final GatewayLookup _gateways;
  final int serverPort;

  /// What the gateway said its internet address is (last [map]).
  InternetAddress? externalAddress;

  Future<PortMapping?> map(
    int port, {
    Duration lease = const Duration(hours: 2),
  }) async {
    for (final InternetAddress gateway in await _gateways()) {
      final Uint8List? info = await _ask(
        gateway,
        Uint8List.fromList(<int>[0, 0]),
      );
      final InternetAddress? external = parseNatPmpExternal(info);
      if (info == null) {
        continue;
      }
      externalAddress = external ?? externalAddress;
      final Uint8List? answer = await _ask(
        gateway,
        // Asks for 443 (looks like HTTPS); the gateway may give another.
        natPmpMapRequest(
          port,
          kDisguisedExternalPorts.isEmpty
              ? port
              : kDisguisedExternalPorts.first,
          lease.inSeconds,
        ),
      );
      final NatPmpMapped? mapped = parseNatPmpMapped(answer);
      if (mapped == null || mapped.lifetime == 0) {
        continue;
      }
      return PortMapping(
        method: 'natpmp',
        internalPort: port,
        externalPort: mapped.externalPort,
        lease: Duration(seconds: mapped.lifetime),
        externalAddress: external,
        remove: () async {
          await _ask(gateway, natPmpMapRequest(port, 0, 0));
        },
      );
    }
    return null;
  }

  /// Sends [request] with the RFC's retries (250 ms, doubling).
  Future<Uint8List?> _ask(InternetAddress gateway, Uint8List request) async {
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    Completer<Uint8List?> got = Completer<Uint8List?>();
    // A datagram socket can be listened to only once: one listener for
    // every attempt.
    final StreamSubscription<RawSocketEvent> sub = socket.listen((
      RawSocketEvent e,
    ) {
      if (e != RawSocketEvent.read) {
        return;
      }
      final Datagram? d = socket.receive();
      if (d != null && d.address == gateway && !got.isCompleted) {
        got.complete(d.data);
      }
    });
    try {
      Duration wait = const Duration(milliseconds: 250);
      for (int attempt = 0; attempt < 4; attempt++) {
        if (got.isCompleted) {
          got = Completer<Uint8List?>();
        }
        socket.send(request, gateway, serverPort);
        final Uint8List? data = await got.future.timeout(
          wait,
          onTimeout: () => null,
        );
        if (data != null) {
          return data;
        }
        wait *= 2;
      }
      return null;
    } finally {
      await sub.cancel();
      socket.close();
    }
  }
}

Uint8List natPmpMapRequest(int internal, int external, int lifetime) {
  final ByteData b = ByteData(12)
    ..setUint8(0, 0)
    ..setUint8(1, 2) // TCP
    ..setUint16(4, internal)
    ..setUint16(6, external)
    ..setUint32(8, lifetime);
  return b.buffer.asUint8List();
}

InternetAddress? parseNatPmpExternal(Uint8List? data) {
  if (data == null || data.length < 12 || data[0] != 0 || data[1] != 128) {
    return null;
  }
  final ByteData b = ByteData.sublistView(data);
  if (b.getUint16(2) != 0) {
    return null;
  }
  return InternetAddress.fromRawAddress(
    Uint8List.fromList(data.sublist(8, 12)),
  );
}

@immutable
final class NatPmpMapped {
  const NatPmpMapped(this.internalPort, this.externalPort, this.lifetime);

  final int internalPort;
  final int externalPort;
  final int lifetime;
}

NatPmpMapped? parseNatPmpMapped(Uint8List? data) {
  if (data == null || data.length < 16 || data[0] != 0 || data[1] != 130) {
    return null;
  }
  final ByteData b = ByteData.sublistView(data);
  if (b.getUint16(2) != 0) {
    return null;
  }
  return NatPmpMapped(b.getUint16(8), b.getUint16(10), b.getUint32(12));
}
