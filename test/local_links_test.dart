import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/presentation/offline_links_section.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/wifi_direct_local_link.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The node runtime, as the controller sees it.
final class _Target implements LocalLinksTarget {
  final List<Map<String, dynamic>> pushed = <Map<String, dynamic>>[];
  LocalLinkNodeApi? api;

  Map<String, dynamic> get last => pushed.last;

  @override
  void setLocalLinks(String? settingsJson) {
    pushed.add(jsonDecode(settingsJson!) as Map<String, dynamic>);
  }

  @override
  LocalLinkNodeApi? get localLinks => api;
}

/// A native transport that only records what it was told.
final class _Transport extends LocalLink {
  _Transport(this.transport);

  @override
  final LocalLinkTransport transport;
  final List<String> calls = <String>[];
  final ValueNotifier<LocalLinkState> _state = ValueNotifier<LocalLinkState>(
    LocalLinkState.off,
  );
  bool running = false;

  @override
  bool get isSupported => true;

  @override
  ValueListenable<LocalLinkState> get state => _state;

  @override
  Future<void> start(
    LocalLinkNodeApi? Function() node, {
    required bool foreground,
  }) async {
    running = true;
    calls.add('start(foreground: $foreground)');
  }

  @override
  Future<void> stop() async {
    if (running) {
      calls.add('stop');
    }
    running = false;
  }
}

/// The bridge's calls, with adverts that say who sent them.
final class _Api implements LocalLinkNodeApi {
  _Api(this.ownAdvert);

  String ownAdvert;
  final Set<String> friends = <String>{};
  LocalLinksStatus current = LocalLinksStatus.empty;

  @override
  String? advert({int bytes = 0}) => ownAdvert;

  @override
  bool matches(String advertHex) => friends.contains(advertHex);

  @override
  LocalLinksStatus status() => current;

  @override
  LocalLinksStatus configure(String settingsJson) => current;

  @override
  LocalLinkEndpoint? openStream(LocalLinkTransport transport) => null;

  @override
  void close(String id) {}
}

final class _Radio implements WifiDirectRadio {
  bool permitted = true;
  bool wifi = false;
  final List<String> calls = <String>[];
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  void emit(Map<Object?, Object?> event) => _events.add(event);

  @override
  Future<Map<String, Object?>> state() async => <String, Object?>{
    'supported': true,
    'permitted': permitted,
    'wifi': wifi,
    'group': null,
  };

  @override
  Future<bool> requestPermissions() async => permitted;

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
      calls.add('keep ${linked.length}');

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
}

LocalLinksStatus _statusWith(List<Map<String, Object>> links) =>
    LocalLinksStatus.fromJson(<String, dynamic>{
      'lan': <String, Object>{
        'on': true,
        'running': true,
        'interfaces': <String>['wlan0'],
      },
      'peers': 3,
      'links': links,
    });

void main() {
  test('the bridge status is read as it comes', () {
    final LocalLinksStatus status = _statusWith(<Map<String, Object>>[
      <String, Object>{
        'id': 'a',
        'transport': 'lan',
        'address': '200::1',
        'own': true,
        'since': 1000,
        'up': true,
      },
      <String, Object>{
        'id': 'b',
        'transport': 'wifi-direct',
        'address': '200::2',
        'own': false,
        'since': 2000,
        'up': false,
      },
      <String, Object>{'id': 'broken'},
    ]);
    expect(status.lanOn, isTrue);
    expect(status.lanRunning, isTrue);
    expect(status.interfaces, <String>['wlan0']);
    expect(status.peerCount, 3);
    expect(status.links, hasLength(2));
    expect(status.links.first.transport, LocalLinkTransport.lan);
    expect(status.links.first.own, isTrue);
    expect(status.links.last.transport, LocalLinkTransport.wifiDirect);
    expect(status.upLinks.map((LocalLinkInfo l) => l.id), <String>['a']);

    final LocalLinksStatus empty = LocalLinksStatus.fromJson(
      <String, dynamic>{},
    );
    expect(empty.lanOn, isFalse);
    expect(empty.links, isEmpty);
    expect(
      LocalLinkTransport.fromWire('bluetooth'),
      LocalLinkTransport.bluetooth,
    );
    expect(LocalLinkTransport.fromWire('pigeon'), isNull);
  });

  test('an endpoint for a native stream is read with its token', () {
    final LocalLinkEndpoint? endpoint = LocalLinkEndpoint.fromJson(
      <String, dynamic>{'id': 'e1', 'port': 40100, 'token': '00ff10'},
    );
    expect(endpoint?.port, 40100);
    expect(endpoint?.token, <int>[0, 255, 16]);
    expect(
      LocalLinkEndpoint.fromJson(<String, dynamic>{
        'id': 'e1',
        'port': 1,
        'token': 'zz',
      }),
      isNull,
    );
  });

  test('the controller hands the bridge the setting and the devices', () async {
    final _Target target = _Target();
    List<LocalLinkPeer> devices = const <LocalLinkPeer>[
      LocalLinkPeer(address: '200::1', secretHex: 'aa', own: false),
    ];
    final List<bool> lock = <bool>[];
    // The ledger is still loading when the controller starts.
    final Completer<void> ledgerReady = Completer<void>();
    final LocalLinksController controller = LocalLinksController(
      target: target,
      loadPeers: () async {
        await ledgerReady.future;
        return devices;
      },
      setMulticastLock: (bool held) async => lock.add(held),
    );

    await controller.start(active: true, foreground: true);
    // At once: the setting, with no devices yet.
    expect(target.last['Lan'], isTrue);
    expect(target.last['Peers'], isEmpty);
    ledgerReady.complete();
    await Future<void>.delayed(Duration.zero);
    expect(target.last['BeaconSeconds'], kLocalLinkActiveBeaconSeconds);
    expect((target.last['Peers'] as List<dynamic>).single['Address'], '200::1');
    // The multicast lock only once there is someone to find.
    expect(lock, <bool>[false, true]);

    // A new friend's device.
    devices = <LocalLinkPeer>[
      ...devices,
      const LocalLinkPeer(address: '200::2', secretHex: 'bb', own: true),
    ];
    await controller.refreshPeers();
    expect(target.last['Peers'] as List<dynamic>, hasLength(2));

    // In the background: beacons less often, no multicast lock.
    controller.setUsage(active: false, foreground: false);
    expect(target.last['BeaconSeconds'], kLocalLinkIdleBeaconSeconds);
    await Future<void>.delayed(Duration.zero);
    expect(lock.last, isFalse);

    controller.setSettings(
      lan: false,
      transports: const <LocalLinkTransport>{},
    );
    expect(target.last['Lan'], isFalse);

    await controller.stop();
    expect(target.last['Lan'], isFalse);
    expect(target.last['Peers'], isEmpty);
  });

  test('people nearby ride on the LAN settings: adverts, looking, and what '
      'was heard', () async {
    final _Target target = _Target();
    final List<bool> lock = <bool>[];
    final LocalLinksController controller = LocalLinksController(
      target: target,
      loadPeers: () async => const <LocalLinkPeer>[],
      setMulticastLock: (bool held) async => lock.add(held),
    );
    // Set before the start: kept for it.
    controller.setNearby(
      LocalNearbyAdverts(
        firstSlot: 2950000,
        adverts: Uint8List.fromList(List<int>.generate(20, (int i) => i)),
      ),
    );
    expect(target.pushed, isEmpty);
    await controller.start(active: true, foreground: false);
    await Future<void>.delayed(Duration.zero);
    expect(target.last['Nearby'], <String, Object>{
      'Start': 2950000,
      'Adverts': '000102030405060708090a0b0c0d0e0f10111213',
      'Looking': false,
    });
    expect(lock.last, isFalse, reason: 'shown only: no multicast lock');

    // Looking around (in the background too) needs to hear the others.
    controller.setNearby(
      const LocalNearbyAdverts(firstSlot: 2950000, looking: true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(target.last['Nearby'], <String, Object>{
      'Start': 2950000,
      'Adverts': '',
      'Looking': true,
    });
    expect(lock.last, isTrue);
    final int pushes = target.pushed.length;
    controller.setNearby(
      const LocalNearbyAdverts(firstSlot: 2950000, looking: true),
    );
    expect(target.pushed, hasLength(pushes), reason: 'the same: not again');

    controller.setNearby(null);
    await Future<void>.delayed(Duration.zero);
    expect(target.last.containsKey('Nearby'), isFalse);
    expect(lock.last, isFalse);

    final LocalLinksStatus status = LocalLinksStatus.fromJson(<String, dynamic>{
      'nearby': <Object?>[
        <String, Object?>{'advert': '0a0b', 'at': 5},
        <String, Object?>{'advert': 7, 'at': 5},
      ],
    });
    expect(status.nearby.single.advert, <int>[10, 11]);
    expect(status.nearby.single.at, 5);
    expect(LocalLinksStatus.empty.nearby, isEmpty);
    await controller.stop();
  });

  test('native transports run only when on and the app is used', () async {
    final _Target target = _Target();
    final _Transport wifiDirect = _Transport(LocalLinkTransport.wifiDirect);
    final LocalLinksController controller = LocalLinksController(
      target: target,
      loadPeers: () async => const <LocalLinkPeer>[],
      transports: <LocalLink>[wifiDirect],
      setMulticastLock: (bool held) async {},
    );
    await controller.start(active: true, foreground: true);
    await Future<void>.delayed(Duration.zero);
    expect(wifiDirect.running, isFalse, reason: 'off by default');

    controller.setSettings(
      lan: true,
      transports: const <LocalLinkTransport>{LocalLinkTransport.wifiDirect},
    );
    await Future<void>.delayed(Duration.zero);
    expect(wifiDirect.running, isTrue);

    // The app goes away without its background service.
    controller.setUsage(active: false, foreground: false);
    await Future<void>.delayed(Duration.zero);
    expect(wifiDirect.running, isFalse);

    // The background service runs it.
    controller.setUsage(active: true, foreground: false);
    await Future<void>.delayed(Duration.zero);
    expect(wifiDirect.calls.last, 'start(foreground: false)');

    await controller.stop();
    expect(wifiDirect.running, isFalse);
  });

  test('Wi-Fi Direct needs the LAN setting', () {
    expect(
      enabledLocalTransports(const AppSettings(wifiDirect: true)),
      <LocalLinkTransport>{LocalLinkTransport.wifiDirect},
    );
    expect(
      enabledLocalTransports(
        const AppSettings(wifiDirect: true, lanDiscovery: false),
      ),
      isEmpty,
    );
    expect(enabledLocalTransports(const AppSettings()), isEmpty);
  });

  test('the status line says how many devices are linked and how', () {
    final LocalLinksStatus two = _statusWith(<Map<String, Object>>[
      for (final String transport in <String>['lan', 'wifi-direct'])
        <String, Object>{
          'id': transport,
          'transport': transport,
          'address': '200::1',
          'up': true,
        },
    ]);
    final String text = localLinksStatusText(two, lanOn: true);
    expect(text, contains('2'));
    expect(text, contains('Wi-Fi Direct: 1'));
    expect(
      localLinksStatusText(LocalLinksStatus.empty, lanOn: false),
      contains('internet'),
    );
    expect(
      localLinksStatusText(
        LocalLinksStatus.empty,
        lanOn: true,
        wifiDirect: const LocalLinkState(LocalLinkPhase.needsPermission),
      ),
      contains('zgod'),
    );
    // Bluetooth works without the LAN setting.
    expect(
      localLinksStatusText(
        LocalLinksStatus.empty,
        lanOn: false,
        bluetooth: const LocalLinkState(LocalLinkPhase.searching),
      ),
      contains('Bluetooth'),
    );
    expect(
      localLinksStatusText(
        LocalLinksStatus.empty,
        lanOn: true,
        bluetooth: const LocalLinkState(LocalLinkPhase.radioOff),
      ),
      'Bluetooth jest wyłączony.',
    );
    final LocalLinksStatus overBluetooth = _statusWith(<Map<String, Object>>[
      <String, Object>{
        'id': 'b',
        'transport': 'bluetooth',
        'address': '200::1',
        'up': true,
      },
    ]);
    expect(
      localLinksStatusText(overBluetooth, lanOn: false),
      contains('Bluetooth: 1'),
    );
  });

  group('Wi-Fi Direct', () {
    late _Radio radio;
    late _Api api;
    late DateTime now;
    late WifiDirectLocalLink link;

    setUp(() {
      radio = _Radio();
      api = _Api('5000');
      now = DateTime(2026, 10, 21, 12);
      link = WifiDirectLocalLink(
        radio: radio,
        supportedPlatform: true,
        now: () => now,
      );
    });

    tearDown(() async {
      await link.stop();
      link.dispose();
    });

    test('without the permission it waits for it', () async {
      radio.permitted = false;
      await link.start(() => api, foreground: true);
      expect(link.state.value.phase, LocalLinkPhase.needsPermission);
      expect(radio.calls, isEmpty);
    });

    test('on a Wi-Fi network it stays idle', () async {
      radio.wifi = true;
      await link.start(() => api, foreground: true);
      expect(link.state.value.phase, LocalLinkPhase.idle);
      expect(radio.calls, isNot(contains('discover')));
    });

    test('it advertises, and looks in a short window', () async {
      await link.start(() => api, foreground: true);
      expect(radio.calls, <String>['start', 'advert 5000', 'discover']);
      expect(link.state.value.phase, LocalLinkPhase.searching);
    });

    test('strangers are ignored', () async {
      await link.start(() => api, foreground: true);
      await link.onPeer(device: 'aa', advert: '9999');
      await link.onPeer(
        device: 'aa',
        advert: '9999',
        name: 'DIRECT-zl-x',
        passphrase: 'secret12',
      );
      expect(radio.calls, isNot(contains('create')));
      expect(radio.calls.where((String c) => c.startsWith('join')), isEmpty);
    });

    test('a friend: the lower advert makes the group', () async {
      api.friends.add('9999');
      await link.start(() => api, foreground: true);
      await link.onPeer(device: 'aa', advert: '9999');
      expect(radio.calls.last, 'create');
    });

    test('a friend with the lower advert: wait, then join', () async {
      api.friends.add('1000');
      await link.start(() => api, foreground: true);
      await link.onPeer(device: 'aa', advert: '1000');
      expect(radio.calls, isNot(contains('create')));
      await link.onPeer(
        device: 'aa',
        advert: '1000',
        name: 'DIRECT-zl-abc',
        passphrase: 'secret12',
      );
      expect(radio.calls.last, 'join DIRECT-zl-abc');
    });

    test('a friend that never makes a group: make one after a while', () async {
      api.friends.add('1000');
      await link.start(() => api, foreground: true);
      await link.onPeer(device: 'aa', advert: '1000');
      now = now.add(link.waitForFriendGroup);
      await link.onPeer(device: 'aa', advert: '1000');
      expect(radio.calls.last, 'create');
    });

    test('two lonely groups: the greater name joins the other', () async {
      api.friends.add('9999');
      await link.start(() => api, foreground: true);
      radio.emit(<Object?, Object?>{
        'type': 'group',
        'group': <Object?, Object?>{
          'owner': true,
          'name': 'DIRECT-zl-zzz',
          'passphrase': 'mine1234',
          'clients': 0,
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(link.group?.owner, isTrue);
      await link.onPeer(
        device: 'aa',
        advert: '9999',
        name: 'DIRECT-zl-aaa',
        passphrase: 'theirs12',
      );
      expect(radio.calls.sublist(radio.calls.length - 2), <String>[
        'remove',
        'join DIRECT-zl-aaa',
      ]);
    });

    test('a group nobody links over is removed', () async {
      await link.start(() => api, foreground: true);
      radio.emit(<Object?, Object?>{
        'type': 'group',
        'group': <Object?, Object?>{'owner': false, 'name': 'DIRECT-zl-a'},
      });
      await Future<void>.delayed(Duration.zero);
      await link.runCycle();
      expect(radio.calls, isNot(contains('remove')));

      api.current = _statusWith(<Map<String, Object>>[
        <String, Object>{
          'id': 'x',
          'transport': 'wifi-direct',
          'address': '200::1',
          'up': true,
        },
      ]);
      await link.runCycle();
      expect(
        link.state.value,
        const LocalLinkState(LocalLinkPhase.connected, peers: 1),
      );

      api.current = LocalLinksStatus.empty;
      now = now.add(link.idleGroupTimeout);
      await link.runCycle();
      expect(radio.calls.last, 'remove');
      expect(link.group, isNull);
    });

    test('a joined group with no handshake of a friend is left quickly and '
        'not joined again', () async {
      api.friends.add('1000');
      await link.start(() => api, foreground: true);
      // A friend's record (perhaps replayed) names a group: joined.
      await link.onPeer(
        device: 'aa',
        advert: '1000',
        name: 'DIRECT-zl-abc',
        passphrase: 'secret12',
      );
      expect(radio.calls.last, 'join DIRECT-zl-abc');
      radio.emit(<Object?, Object?>{
        'type': 'group',
        'group': <Object?, Object?>{'owner': false, 'name': 'DIRECT-zl-abc'},
      });
      await Future<void>.delayed(Duration.zero);
      await link.runCycle();
      expect(radio.calls, isNot(contains('remove')));
      // No pair handshake over it in time: left, well before the idle
      // timeout of groups that had a link.
      now = now.add(link.joinHandshakeTimeout);
      expect(link.joinHandshakeTimeout, lessThan(link.idleGroupTimeout));
      await link.runCycle();
      expect(radio.calls.last, 'remove');
      expect(link.group, isNull);
      // The same group again: not joined, and nothing made instead.
      final int before = radio.calls.length;
      await link.onPeer(
        device: 'aa',
        advert: '1000',
        name: 'DIRECT-zl-abc',
        passphrase: 'secret12',
      );
      expect(radio.calls.sublist(before), isEmpty);
      // Later it may be tried once more.
      now = now.add(link.refuseGroupFor);
      await link.onPeer(
        device: 'aa',
        advert: '1000',
        name: 'DIRECT-zl-abc',
        passphrase: 'secret12',
      );
      expect(radio.calls.last, 'join DIRECT-zl-abc');
    });

    test('a joined group is kept once the handshake linked a friend', () async {
      await link.start(() => api, foreground: true);
      radio.emit(<Object?, Object?>{
        'type': 'group',
        'group': <Object?, Object?>{'owner': false, 'name': 'DIRECT-zl-b'},
      });
      await Future<void>.delayed(Duration.zero);
      api.current = _statusWith(<Map<String, Object>>[
        <String, Object>{
          'id': 'x',
          'transport': 'wifi-direct',
          'address': '200::1',
          'up': true,
        },
      ]);
      await link.runCycle();
      now = now.add(link.joinHandshakeTimeout);
      await link.runCycle();
      expect(radio.calls, isNot(contains('remove')));
      expect(link.group?.name, 'DIRECT-zl-b');
    });

    test('stopping gives the radio back', () async {
      await link.start(() => api, foreground: true);
      await link.stop();
      expect(radio.calls.last, 'stop');
      expect(link.state.value.phase, LocalLinkPhase.off);
    });
  });
}
