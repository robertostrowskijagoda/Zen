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

void main() {
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
    final UpnpPortMapper mapper = UpnpPortMapper(
      discover: (_) async => <Uri>[igd.location],
    );
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
    final PortMapping? m = await UpnpPortMapper(
      discover: (_) async => <Uri>[igd.location],
    ).map(32913);
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
    final PortMapping? m = await UpnpPortMapper(
      discover: (_) async => <Uri>[igd.location],
    ).map(32913);
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
