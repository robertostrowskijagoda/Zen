import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/ledger/port_mapper.dart';

const String _wan = 'urn:schemas-upnp-org:service:WANIPConnection:1';

String _description(String control) =>
    '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
 <device><deviceList><device><deviceList><device>
  <serviceList>
   <service>
    <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
    <controlURL>/common</controlURL>
   </service>
   <service>
    <serviceType>$_wan</serviceType>
    <controlURL>$control</controlURL>
   </service>
  </serviceList>
 </device></deviceList></device></deviceList></device>
</root>''';

/// A home router speaking UPnP, on loopback.
final class _FakeIgd {
  _FakeIgd._(this.server);

  final HttpServer server;
  final List<Map<String, String>> calls = <Map<String, String>>[];
  final Set<int> taken = <int>{};
  bool onlyPermanent = false;

  Uri get location => Uri.parse('http://127.0.0.1:${server.port}/desc.xml');

  static Future<_FakeIgd> start() async {
    final _FakeIgd igd = _FakeIgd._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    igd.server.listen(igd._handle);
    return igd;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.method == 'GET') {
      req.response.write(_description('/ctl/IPConn'));
      await req.response.close();
      return;
    }
    final String body = await utf8.decoder.bind(req).join();
    final String action = req.headers
        .value('SOAPAction')!
        .split('#')
        .last
        .replaceAll('"', '');
    final Map<String, String> args = <String, String>{'action': action};
    for (final Match m in RegExp(r'<(New\w+)>([^<]*)</\1>').allMatches(body)) {
      args[m.group(1)!] = m.group(2)!;
    }
    calls.add(args);
    String fault(int code) =>
        '<s:Envelope><s:Body><s:Fault><detail><UPnPError>'
        '<errorCode>$code</errorCode><errorDescription>x</errorDescription>'
        '</UPnPError></detail></s:Fault></s:Body></s:Envelope>';
    switch (action) {
      case 'GetExternalIPAddress':
        req.response.write(
          '<s:Envelope><s:Body><u:GetExternalIPAddressResponse>'
          '<NewExternalIPAddress>198.51.100.23</NewExternalIPAddress>'
          '</u:GetExternalIPAddressResponse></s:Body></s:Envelope>',
        );
      case 'AddPortMapping':
        final int port = int.parse(args['NewExternalPort']!);
        if (onlyPermanent && args['NewLeaseDuration'] != '0') {
          req.response
            ..statusCode = 500
            ..write(fault(725));
        } else if (taken.contains(port)) {
          req.response
            ..statusCode = 500
            ..write(fault(718));
        } else {
          taken.add(port);
          req.response.write('<s:Envelope><s:Body/></s:Envelope>');
        }
      case 'DeletePortMapping':
        taken.remove(int.parse(args['NewExternalPort']!));
        req.response.write('<s:Envelope><s:Body/></s:Envelope>');
    }
    await req.response.close();
  }
}

/// The mapper with [igd] as the gateway (on loopback, which only tests may
/// use).
UpnpPortMapper _upnp(_FakeIgd igd) => UpnpPortMapper(
  discover: (_) async => <Uri>[igd.location],
  gateways: () async => <InternetAddress>[InternetAddress.loopbackIPv4],
  routerOnLoopback: true,
);

/// A device on the same Wi-Fi that answers like a router and notes every
/// request it gets.
Future<(HttpServer, List<String>)> _hostileRouter(String external) async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final List<String> seen = <String>[];
  server.listen((HttpRequest req) async {
    final String body = await utf8.decodeStream(req);
    seen.add('${req.method} ${req.uri}');
    if (req.uri.path == '/desc.xml') {
      req.response.write(_description('/ctl'));
    } else if (body.contains('GetExternalIPAddress')) {
      req.response.write(
        '<s:Envelope><s:Body><u:GetExternalIPAddressResponse>'
        '<NewExternalIPAddress>$external</NewExternalIPAddress>'
        '</u:GetExternalIPAddressResponse></s:Body></s:Envelope>',
      );
    } else {
      req.response.write('<s:Envelope><s:Body/></s:Envelope>');
    }
    await req.response.close();
  });
  return (server, seen);
}

void main() {
  test('SSDP answers count only from the gateway, naming itself', () {
    const String answer =
        'HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\n'
        'LOCATION: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n';
    final List<InternetAddress> gateway = <InternetAddress>[
      InternetAddress('192.168.1.1'),
    ];
    expect(
      ssdpGatewayLocation(
        answer,
        from: InternetAddress('192.168.1.1'),
        gateways: gateway,
      ),
      Uri.parse('http://192.168.1.1:5000/rootDesc.xml'),
    );
    expect(
      ssdpGatewayLocation(
        answer,
        from: InternetAddress('192.168.1.66'),
        gateways: gateway,
      ),
      isNull,
      reason: 'another device on the Wi-Fi is not the router',
    );
    expect(
      ssdpGatewayLocation(
        'HTTP/1.1 200 OK\r\n'
        'LOCATION: http://192.168.1.66:5000/rootDesc.xml\r\n\r\n',
        from: InternetAddress('192.168.1.1'),
        gateways: gateway,
      ),
      isNull,
      reason: 'the gateway never sends us to another machine',
    );
    expect(
      ssdpGatewayLocation(
        answer,
        from: InternetAddress('192.168.1.1'),
        gateways: const <InternetAddress>[],
      ),
      isNull,
      reason: 'no default route, no router',
    );
  });

  test(
    'a forged SSDP answer pointing at this computer is never fetched',
    () async {
      final (HttpServer server, List<String> seen) = await _hostileRouter(
        '198.51.100.66',
      );
      addTearDown(() => server.close(force: true));
      expect(
        parseSsdpLocation(
          'HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\n'
          'LOCATION: http://127.0.0.1:${server.port}/admin/reboot.cgi?now=1'
          '\r\n\r\n',
        ),
        isNull,
        reason: 'a router never lives on this computer',
      );
      // Even if discovery handed it over (loopback, or a device that is not
      // the gateway), nothing is asked of it.
      final UpnpPortMapper upnp = UpnpPortMapper(
        discover: (_) async => <Uri>[
          Uri.parse('http://127.0.0.1:${server.port}/admin/reboot.cgi?now=1'),
          Uri.parse('http://127.0.0.1:${server.port}/desc.xml'),
        ],
        gateways: () async => <InternetAddress>[InternetAddress('192.168.1.1')],
      );
      expect(await upnp.map(32913), isNull);
      expect(upnp.externalAddress, isNull);
      expect(seen, isEmpty);
    },
  );

  test(
    'a description on another device than the gateway is not read',
    () async {
      final (HttpServer server, List<String> seen) = await _hostileRouter(
        '198.51.100.66',
      );
      addTearDown(() => server.close(force: true));
      final RouterPortMapper mapper = RouterPortMapper(
        upnp: UpnpPortMapper(
          discover: (_) async => <Uri>[
            Uri.parse('http://127.0.0.1:${server.port}/desc.xml'),
          ],
          // The gateway is elsewhere: this "router" only answered the search.
          gateways: () async => <InternetAddress>[InternetAddress('127.0.0.2')],
          routerOnLoopback: true,
        ),
        natPmp: NatPmpPortMapper(gateways: () async => <InternetAddress>[]),
      );
      expect(await mapper.map(32913), isNull);
      expect(mapper.knownExternalAddress, isNull);
      expect(seen, isEmpty);
    },
  );

  test('a router does not redirect us to another address', () async {
    final (HttpServer target, List<String> seen) = await _hostileRouter(
      '198.51.100.66',
    );
    addTearDown(() => target.close(force: true));
    final HttpServer router = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => router.close(force: true));
    router.listen((HttpRequest req) async {
      req.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://localhost:${target.port}/desc.xml',
        );
      await req.response.close();
    });
    final UpnpPortMapper upnp = UpnpPortMapper(
      discover: (_) async => <Uri>[
        Uri.parse('http://127.0.0.1:${router.port}/desc.xml'),
      ],
      gateways: () async => <InternetAddress>[InternetAddress.loopbackIPv4],
      routerOnLoopback: true,
    );
    expect(await upnp.map(32913), isNull);
    expect(seen, isEmpty);
  });

  test('SSDP answers: only local http routers count', () {
    expect(
      parseSsdpLocation(
        'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\n'
        'Location: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n',
      ),
      Uri.parse('http://192.168.1.1:5000/rootDesc.xml'),
    );
    expect(
      parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: http://8.8.8.8/x\r\n'),
      isNull,
      reason: 'a "router" on the internet is not our router',
    );
    expect(
      parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: http://[::1]:80/x\r\n'),
      isNull,
      reason: 'nor one on this computer',
    );
    expect(parseSsdpLocation('HTTP/1.1 200 OK\r\n\r\n'), isNull);
  });

  test('the WAN service is found and stays on the router', () {
    final Uri location = Uri.parse('http://192.168.1.1:5000/rootDesc.xml');
    final List<UpnpService> s = parseUpnpServices(
      _description('/ctl/IPConn'),
      location,
    );
    expect(s.single.type, _wan);
    expect(s.single.control, Uri.parse('http://192.168.1.1:5000/ctl/IPConn'));
    expect(
      parseUpnpServices(_description('http://203.0.113.5/ctl'), location),
      isEmpty,
    );
  });

  test('UPnP opens the port, steps aside when taken, and closes it', () async {
    final _FakeIgd igd = await _FakeIgd.start();
    addTearDown(() => igd.server.close(force: true));
    igd.taken
      ..add(443)
      ..add(32913);
    final UpnpPortMapper mapper = _upnp(igd);
    final PortMapping? m = await mapper.map(32913);
    expect(m, isNotNull);
    expect(m!.method, 'upnp');
    expect(m.externalPort, 32914);
    expect(m.externalAddress, InternetAddress('198.51.100.23'));
    expect(m.lease, const Duration(hours: 2));
    final Map<String, String> add = igd.calls.lastWhere(
      (Map<String, String> c) => c['action'] == 'AddPortMapping',
    );
    expect(add['NewInternalPort'], '32913');
    expect(add['NewInternalClient'], '127.0.0.1');
    expect(add['NewProtocol'], 'TCP');
    await m.remove();
    expect(igd.taken, <int>{443, 32913});
  });

  test('the bridge asks for 443 first, so it looks like HTTPS', () async {
    final _FakeIgd igd = await _FakeIgd.start();
    addTearDown(() => igd.server.close(force: true));
    final PortMapping? m = await _upnp(igd).map(32913);
    expect(m!.externalPort, 443);
    final Map<String, String> add = igd.calls.lastWhere(
      (Map<String, String> c) => c['action'] == 'AddPortMapping',
    );
    expect(add['NewInternalPort'], '32913');
  });

  test('routers that only allow permanent forwarding get one', () async {
    final _FakeIgd igd = await _FakeIgd.start();
    addTearDown(() => igd.server.close(force: true));
    igd.onlyPermanent = true;
    final PortMapping? m = await _upnp(igd).map(32913);
    expect(m!.lease, Duration.zero);
  });

  test('no router: nothing happens', () async {
    expect(
      await UpnpPortMapper(discover: (_) async => <Uri>[]).map(32913),
      isNull,
    );
  });

  test('NAT-PMP asks the gateway and reads the answer', () async {
    final RawDatagramSocket router = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(router.close);
    final List<Uint8List> asked = <Uint8List>[];
    router.listen((RawSocketEvent e) {
      final Datagram? d = router.receive();
      if (d == null) {
        return;
      }
      asked.add(d.data);
      final ByteData out;
      if (d.data[1] == 0) {
        out = ByteData(12)
          ..setUint8(1, 128)
          ..setUint32(4, 99);
        out.buffer.asUint8List().setAll(8, <int>[198, 51, 100, 40]);
      } else {
        final ByteData q = ByteData.sublistView(d.data);
        out = ByteData(16)
          ..setUint8(1, 130)
          ..setUint16(8, q.getUint16(4))
          ..setUint16(10, q.getUint16(6) == 0 ? 0 : 40000)
          ..setUint32(12, q.getUint32(8));
      }
      router.send(out.buffer.asUint8List(), d.address, d.port);
    });
    final NatPmpPortMapper mapper = NatPmpPortMapper(
      gateways: () async => <InternetAddress>[InternetAddress.loopbackIPv4],
      serverPort: router.port,
    );
    final PortMapping? m = await mapper.map(32913);
    expect(m, isNotNull);
    expect(m!.externalPort, 40000);
    expect(m.externalAddress, InternetAddress('198.51.100.40'));
    expect(m.lease, const Duration(hours: 2));
    await m.remove();
    final ByteData last = ByteData.sublistView(asked.last);
    expect(last.getUint32(8), 0, reason: 'lifetime 0 removes the mapping');
  });

  test('NAT-PMP takes answers only from the gateway\'s port', () async {
    // The gateway hears the request but stays silent; another sender
    // answers the request's port with a mapping and an external address.
    final RawDatagramSocket gateway = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final RawDatagramSocket hostile = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(gateway.close);
    addTearDown(hostile.close);
    gateway.listen((RawSocketEvent e) {
      final Datagram? d = gateway.receive();
      if (d == null) {
        return;
      }
      final ByteData out;
      if (d.data[1] == 0) {
        out = ByteData(12)..setUint8(1, 128);
        out.buffer.asUint8List().setAll(8, <int>[198, 51, 100, 66]);
      } else {
        final ByteData q = ByteData.sublistView(d.data);
        out = ByteData(16)
          ..setUint8(1, 130)
          ..setUint16(8, q.getUint16(4))
          ..setUint16(10, 443)
          ..setUint32(12, 7200);
      }
      hostile.send(out.buffer.asUint8List(), d.address, d.port);
    });
    final NatPmpPortMapper mapper = NatPmpPortMapper(
      gateways: () async => <InternetAddress>[InternetAddress.loopbackIPv4],
      serverPort: gateway.port,
    );
    expect(await mapper.map(32913), isNull);
    expect(mapper.externalAddress, isNull);
  });

  test('gateways are read from Windows and Linux routing tables', () {
    expect(
      parseWindowsRoutes('''
IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1    192.168.1.37     25
===========================================================================
'''),
      <InternetAddress>[InternetAddress('192.168.1.1')],
    );
    expect(
      parseLinuxRoutes(
        'Iface\tDestination\tGateway \tFlags\n'
        'eth0\t00000000\t0101A8C0\t0003\n'
        'eth0\t0001A8C0\t00000000\t0001\n',
      ),
      <InternetAddress>[InternetAddress('192.168.1.1')],
    );
  });
}
