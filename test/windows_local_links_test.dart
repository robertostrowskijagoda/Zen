import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/bluetooth_local_links.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/native_stream_local_link.dart';
import 'package:zen/src/features/runtime/wifi_direct_local_link.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The bridge's calls: [friends] are the adverts that match.
final class _Api implements LocalLinkNodeApi {
  _Api(this.ownAdvert);

  final String ownAdvert;
  final Set<String> friends = <String>{};
  LocalLinksStatus links = LocalLinksStatus.empty;
  int _endpoints = 0;

  @override
  String? advert({int bytes = 0}) => ownAdvert;

  @override
  bool matches(String advertHex) => friends.contains(advertHex);

  @override
  LocalLinksStatus status() => links;

  @override
  LocalLinksStatus configure(String settingsJson) => LocalLinksStatus.empty;

  @override
  LocalLinkEndpoint? openStream(LocalLinkTransport transport) =>
      LocalLinkEndpoint(
        id: 'e${++_endpoints}',
        port: 40000 + _endpoints,
        token: Uint8List(16),
      );

  @override
  void close(String id) {}
}

/// One side of the Windows radio ("le" or "classic"), writing to [log].
final class _Side implements NativeLinkRadio {
  _Side(
    this.name,
    this.log, {
    this.supported = true,
    this.discovery = false,
    this.paired = false,
    this.advertBytes = 0,
    this.starts = true,
  });

  final String name;
  final List<String> log;
  final bool supported;
  final bool discovery;
  final bool paired;
  final int advertBytes;
  final bool starts;
  List<String> pairedList = const <String>[];
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  void emit(Map<Object?, Object?> event) => _events.add(event);

  @override
  Future<Map<String, Object?>> state() async => <String, Object?>{
    'supported': supported,
    'permitted': true,
    'enabled': supported,
    'advertBytes': advertBytes,
    'discovery': discovery,
    'paired': paired,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> start() async {
    log.add('$name start');
    return starts;
  }

  @override
  Future<void> stop() async => log.add('$name stop');

  @override
  Future<void> advertise(String advertHex, Duration window) async =>
      log.add('$name advertise $advertHex');

  @override
  Future<void> scan(Duration window) async => log.add('$name scan');

  @override
  Future<List<String>> pairedDevices() async => pairedList;

  @override
  Future<bool> connect(
    String device,
    LocalLinkEndpoint endpoint, {
    int psm = 0,
    bool classic = false,
    String? advert,
  }) async {
    log.add('$name connect $device classic=$classic');
    return true;
  }

  @override
  Future<bool> accept(String id, LocalLinkEndpoint endpoint) async {
    log.add('$name accept $id');
    return true;
  }

  @override
  Future<void> reject(String id) async => log.add('$name reject $id');

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
}

/// Wi-Fi Direct as the Windows runner answers it (wifi_direct_bridge.cpp).
final class _WindowsWifiDirect implements WifiDirectRadio {
  final List<String> calls = <String>[];
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  void emit(Map<Object?, Object?> event) => _events.add(event);

  @override
  Future<Map<String, Object?>> state() async => <String, Object?>{
    'supported': true,
    'permitted': true,
    'enabled': true,
    'wifi': false,
    'group': null,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> start() async {
    calls.add('start');
    return true;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> setAdvert(String advertHex) async =>
      calls.add('advert $advertHex');

  @override
  Future<void> discover(Duration window) async => calls.add('discover');

  @override
  Future<bool> createGroup() async {
    calls.add('create');
    return true;
  }

  @override
  Future<bool> joinGroup(String name, String passphrase) async {
    calls.add('join $name');
    return true;
  }

  @override
  Future<bool> removeGroup() async {
    calls.add('remove');
    return true;
  }

  @override
  Future<void> keepClients(Set<String> linked, Duration grace) async =>
      calls.add('keep ${(linked.toList()..sort()).join(',')}');

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('Windows has Wi-Fi Direct and Bluetooth links', () {
    expect(localTransportsOf(TargetPlatform.windows), <LocalLinkTransport>{
      LocalLinkTransport.wifiDirect,
      LocalLinkTransport.bluetooth,
    });
    expect(localTransportsOf(TargetPlatform.android), <LocalLinkTransport>{
      LocalLinkTransport.wifiDirect,
      LocalLinkTransport.bluetooth,
    });
    expect(localTransportsOf(TargetPlatform.linux), <LocalLinkTransport>{
      LocalLinkTransport.bluetooth,
    });
    expect(localTransportsOf(TargetPlatform.macOS), <LocalLinkTransport>{
      LocalLinkTransport.bluetooth,
      LocalLinkTransport.multipeer,
    });
  });

  test('the Windows transports are registered and supported', () {
    final List<LocalLink> links = platformLocalLinks(TargetPlatform.windows);
    addTearDown(() {
      for (final LocalLink link in links) {
        link.dispose();
      }
    });
    expect(links.map((LocalLink l) => l.transport), <LocalLinkTransport>[
      LocalLinkTransport.wifiDirect,
      LocalLinkTransport.bluetooth,
    ]);
    expect(links.every((LocalLink l) => l.isSupported), isTrue);
    expect(
      bluetoothRadioFor(TargetPlatform.windows),
      isA<WindowsBluetoothRadio>(),
    );
  });

  test('the switches turn the Windows transports on', () {
    expect(
      enabledLocalTransports(
        const AppSettings(wifiDirect: true, bluetoothLinks: true),
      ),
      <LocalLinkTransport>{
        LocalLinkTransport.wifiDirect,
        LocalLinkTransport.bluetooth,
      },
    );
    expect(
      enabledLocalTransports(
        const AppSettings(wifiDirect: true, lanDiscovery: false),
      ),
      isEmpty,
      reason: 'Wi-Fi Direct only makes a network for the LAN discovery',
    );
  });

  group('Windows Bluetooth radio', () {
    late List<String> log;
    late _Side le;
    late _Side classic;
    late WindowsBluetoothRadio radio;

    setUp(() {
      log = <String>[];
      le = _Side('le', log, discovery: true, advertBytes: 32);
      classic = _Side('classic', log, paired: true);
      radio = WindowsBluetoothRadio(classic: classic, le: le);
    });

    test('its state joins BLE and the paired devices', () async {
      final Map<String, Object?> state = await radio.state();
      expect(state['supported'], isTrue);
      expect(state['enabled'], isTrue);
      expect(state['discovery'], isTrue);
      expect(state['paired'], isTrue);
      expect(state['advertBytes'], 32);

      final Map<String, Object?> pairedOnly = await WindowsBluetoothRadio(
        classic: classic,
        le: _Side('le', log, supported: false),
      ).state();
      expect(pairedOnly['supported'], isTrue);
      expect(pairedOnly['discovery'], isFalse, reason: 'no BLE adapter');
      expect(pairedOnly['paired'], isTrue);

      final Map<String, Object?> none = await WindowsBluetoothRadio(
        classic: _Side('classic', log, supported: false),
        le: _Side('le', log, supported: false),
      ).state();
      expect(none['supported'], isFalse);
    });

    test('it starts when either side does', () async {
      final WindowsBluetoothRadio leOnly = WindowsBluetoothRadio(
        classic: _Side('classic', log, starts: false),
        le: le,
      );
      expect(await leOnly.start(), isTrue);
      final WindowsBluetoothRadio neither = WindowsBluetoothRadio(
        classic: _Side('classic', log, starts: false),
        le: _Side('le', log, starts: false),
      );
      expect(await neither.start(), isFalse);
    });

    test(
      'adverts, scans and GATT streams are BLE; paired devices RFCOMM',
      () async {
        final LocalLinkEndpoint endpoint = LocalLinkEndpoint(
          id: 'e1',
          port: 40001,
          token: Uint8List(16),
        );
        classic.pairedList = const <String>['AA:BB:CC:DD:EE:01'];
        await radio.advertise('00ff', const Duration(seconds: 25));
        await radio.scan(const Duration(seconds: 8));
        expect(await radio.pairedDevices(), <String>['AA:BB:CC:DD:EE:01']);
        await radio.connect('AA:BB:CC:DD:EE:02', endpoint);
        await radio.connect('AA:BB:CC:DD:EE:01', endpoint, classic: true);
        expect(log, <String>[
          'le advertise 00ff',
          'le scan',
          'le connect AA:BB:CC:DD:EE:02 classic=false',
          'classic connect AA:BB:CC:DD:EE:01 classic=true',
        ]);
      },
    );

    test(
      'an incoming stream is answered by the side that reported it',
      () async {
        final List<Map<Object?, Object?>> events = <Map<Object?, Object?>>[];
        final StreamSubscription<Map<Object?, Object?>> subscription = radio
            .events
            .listen(events.add);
        addTearDown(subscription.cancel);
        le.emit(<Object?, Object?>{'type': 'incoming', 'id': 'gatt1'});
        classic.emit(<Object?, Object?>{'type': 'incoming', 'id': 'rfcomm1'});
        le.emit(<Object?, Object?>{'type': 'incoming', 'id': 'gatt2'});
        await _settle();
        expect(events, hasLength(3));

        final LocalLinkEndpoint endpoint = LocalLinkEndpoint(
          id: 'e1',
          port: 40001,
          token: Uint8List(16),
        );
        await radio.accept('gatt1', endpoint);
        await radio.accept('rfcomm1', endpoint);
        await radio.reject('gatt2');
        expect(log, <String>[
          'le accept gatt1',
          'classic accept rfcomm1',
          'le reject gatt2',
        ]);
      },
    );

    test(
      'a Windows or Android device seen over BLE is reached over GATT',
      () async {
        final _Api api = _Api('0000')..friends.add('9999');
        final NativeStreamLocalLink link = NativeStreamLocalLink(
          transport: LocalLinkTransport.bluetooth,
          radio: radio,
          supportedPlatform: true,
          foregroundCycle: const Duration(hours: 1),
        );
        addTearDown(() async {
          await link.stop();
          link.dispose();
        });
        await link.start(() => api, foreground: true);
        expect(log, containsAll(<String>['le advertise 0000', 'le scan']));

        le.emit(<Object?, Object?>{
          'type': 'seen',
          'device': 'AA:BB:CC:DD:EE:02',
          'advert': '9999',
          'psm': 0,
          'connectable': true,
        });
        await _settle();
        expect(log, contains('le connect AA:BB:CC:DD:EE:02 classic=false'));
      },
    );
  });

  group('Wi-Fi Direct on Windows', () {
    test(
      'it joins a friend computer, and gives way to the normal Wi-Fi',
      () async {
        final _WindowsWifiDirect radio = _WindowsWifiDirect();
        final _Api api = _Api('5000')..friends.add('1000');
        final WifiDirectLocalLink link = WifiDirectLocalLink(
          radio: radio,
          supportedPlatform: true,
          foregroundCycle: const Duration(hours: 1),
        );
        addTearDown(() async {
          await link.stop();
          link.dispose();
        });
        await link.start(() => api, foreground: true);
        expect(radio.calls, <String>['start', 'advert 5000', 'discover']);

        // The friend's computer takes friends in: its token is the name.
        radio.emit(<Object?, Object?>{
          'type': 'peer',
          'device': 'WiFiDirect#aa',
          'advert': '1000',
          'name': '0123456789abcdef',
          'passphrase': '0123456789abcdef',
        });
        await _settle();
        expect(radio.calls.last, 'join 0123456789abcdef');
        radio.emit(<Object?, Object?>{
          'type': 'group',
          'group': <Object?, Object?>{
            'owner': false,
            'name': '0123456789abcdef',
            'clients': 0,
          },
        });
        await _settle();
        expect(link.group?.name, '0123456789abcdef');

        // Connected to a Wi-Fi network: the runner gave the group up.
        radio
          ..emit(<Object?, Object?>{'type': 'group', 'group': null})
          ..emit(<Object?, Object?>{'type': 'wifi', 'connected': true});
        await _settle();
        final int calls = radio.calls.length;
        await link.runCycle();
        expect(link.group, isNull);
        expect(link.state.value.phase, LocalLinkPhase.idle);
        expect(radio.calls, hasLength(calls), reason: 'nothing on the air');
      },
    );

    test(
      'its own group keeps only clients that made a friend\'s link',
      () async {
        final _WindowsWifiDirect radio = _WindowsWifiDirect();
        final _Api api = _Api('1000');
        final WifiDirectLocalLink link = WifiDirectLocalLink(
          radio: radio,
          supportedPlatform: true,
          foregroundCycle: const Duration(hours: 1),
        );
        addTearDown(() async {
          await link.stop();
          link.dispose();
        });
        await link.start(() => api, foreground: true);
        // Two clients joined (the token is public); one friend linked.
        api.links = LocalLinksStatus(
          links: <LocalLinkInfo>[
            LocalLinkInfo(
              id: 'l1',
              transport: LocalLinkTransport.wifiDirect,
              address: '200::5',
              own: false,
              since: DateTime(2026),
              up: true,
              remote: '192.168.137.20',
            ),
          ],
        );
        radio.emit(<Object?, Object?>{
          'type': 'group',
          'group': <Object?, Object?>{
            'owner': true,
            'name': 'fedcba9876543210',
            'passphrase': 'fedcba9876543210',
            'clients': 2,
            'checks': true,
          },
        });
        await _settle();
        await link.runCycle();
        expect(radio.calls, contains('keep 192.168.137.20'));
        expect(link.state.value.phase, LocalLinkPhase.connected);
      },
    );
  });
}
