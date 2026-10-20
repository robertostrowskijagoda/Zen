import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/bluetooth_local_links.dart';
import 'package:zen/src/features/runtime/bluez_le.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/native_stream_local_link.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The bridge's calls, with adverts that say who sent them.
final class _Api implements LocalLinkNodeApi {
  _Api(this.ownAdvert);

  String ownAdvert;
  final Set<String> friends = <String>{};
  final List<int> advertSizes = <int>[];
  final List<String> closed = <String>[];
  LocalLinksStatus current = LocalLinksStatus.empty;
  int _endpoints = 0;

  @override
  String? advert({int bytes = 0}) {
    advertSizes.add(bytes);
    return ownAdvert;
  }

  @override
  bool matches(String advertHex) => friends.contains(advertHex);

  @override
  LocalLinksStatus status() => current;

  @override
  LocalLinksStatus configure(String settingsJson) => current;

  @override
  LocalLinkEndpoint? openStream(LocalLinkTransport transport) =>
      LocalLinkEndpoint(
        id: 'e${++_endpoints}',
        port: 40000 + _endpoints,
        token: Uint8List(16),
      );

  @override
  void close(String id) => closed.add(id);
}

final class _Radio implements NativeLinkRadio {
  bool permitted = true;
  bool enabled = true;
  bool paired = false;
  bool connects = true;
  List<String> pairedList = const <String>[];
  final List<String> calls = <String>[];
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  void emit(Map<Object?, Object?> event) => _events.add(event);

  @override
  Future<Map<String, Object?>> state() async => <String, Object?>{
    'supported': true,
    'permitted': permitted,
    'enabled': enabled,
    'advertBytes': 16,
    'discovery': true,
    'paired': paired,
  };

  @override
  Future<bool> requestPermissions() async => permitted;

  @override
  Future<bool> start() async {
    calls.add('start');
    return enabled;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> advertise(String advertHex, Duration window) async =>
      calls.add('advertise $advertHex');

  @override
  Future<void> scan(Duration window) async => calls.add('scan');

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
    calls.add(
      'connect $device psm=$psm classic=$classic ${endpoint.id} '
      'advert=$advert',
    );
    return connects;
  }

  @override
  Future<bool> accept(String id, LocalLinkEndpoint endpoint) async {
    calls.add('accept $id ${endpoint.id}');
    return true;
  }

  @override
  Future<void> reject(String id) async => calls.add('reject $id');

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
}

final class _Go implements GoBluetoothApi {
  final List<String> calls = <String>[];
  final Map<String, Map<String, dynamic>> answers =
      <String, Map<String, dynamic>>{};

  @override
  Map<String, dynamic>? call(String function, [Map<String, Object?>? request]) {
    calls.add(request == null ? function : '$function $request');
    return answers[function];
  }
}

LocalLinksStatus _linkedOver(String transport) =>
    LocalLinksStatus.fromJson(<String, dynamic>{
      'links': <Map<String, Object>>[
        <String, Object>{
          'id': 'x',
          'transport': transport,
          'address': '200::1',
          'up': true,
        },
      ],
    });

void main() {
  test('Bluetooth and Multipeer are turned on by their own settings', () {
    expect(enabledLocalTransports(const AppSettings()), isEmpty);
    expect(
      enabledLocalTransports(
        const AppSettings(bluetoothLinks: true, lanDiscovery: false),
      ),
      <LocalLinkTransport>{LocalLinkTransport.bluetooth},
      reason: 'Bluetooth needs no local network',
    );
    expect(
      enabledLocalTransports(
        const AppSettings(bluetoothLinks: true, multipeerLinks: true),
      ),
      <LocalLinkTransport>{
        LocalLinkTransport.bluetooth,
        LocalLinkTransport.multipeer,
      },
    );
  });

  test('the links settings are saved by name', () {
    final AppSettings settings = AppSettings.fromJson(
      const AppSettings(bluetoothLinks: true, multipeerLinks: true).toJson(),
    );
    expect(settings.bluetoothLinks, isTrue);
    expect(settings.multipeerLinks, isTrue);
    expect(
      AppSettings.fromJson(const <String, dynamic>{}).bluetoothLinks,
      isFalse,
    );
  });

  test('Zen manufacturer data carries the PSM and the advert', () {
    final List<int> advert = List<int>.generate(20, (int i) => i);
    final List<int> data = zenLinkManufacturerData(0x0081, advert);
    expect(data.sublist(0, 4), <int>[0x5A, 0x4C, 0x81, 0x00]);
    final ({int psm, List<int> advert})? parsed = parseZenLinkManufacturerData(
      data,
    );
    expect(parsed?.psm, 0x81);
    expect(parsed?.advert, advert);
    expect(parseZenLinkManufacturerData(<int>[0x5A, 0x4E, 0, 0]), isNull);
    expect(
      parseZenLinkManufacturerData(<int>[0x5A, 0x4C, 0x81, 0, 1, 2]),
      isNull,
      reason: 'too short to be an advert',
    );
    // Legacy advertising: 3 flag bytes, 4 bytes of header, the data.
    expect(
      3 +
          4 +
          zenLinkManufacturerData(
            0x80,
            List<int>.filled(7 + BluezLe.advertBytes, 0),
          ).length,
      lessThanOrEqualTo(31),
    );
  });

  group('native stream link', () {
    late _Radio radio;
    late _Api api;
    late DateTime now;
    late NativeStreamLocalLink link;

    NativeStreamLocalLink make({LocalLinkTransport? transport}) =>
        NativeStreamLocalLink(
          transport: transport ?? LocalLinkTransport.bluetooth,
          radio: radio,
          supportedPlatform: true,
          now: () => now,
        );

    setUp(() {
      radio = _Radio();
      api = _Api('5000');
      now = DateTime(2026, 10, 21, 12);
      link = make();
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

    test('with Bluetooth off it says so and shows nothing', () async {
      radio.enabled = false;
      await link.start(() => api, foreground: true);
      expect(link.state.value.phase, LocalLinkPhase.radioOff);
      expect(
        radio.calls.where((String c) => c.startsWith('advertise')),
        isEmpty,
      );
    });

    test('it listens, advertises in a window and scans', () async {
      await link.start(() => api, foreground: true);
      expect(radio.calls, <String>['start', 'advertise 5000', 'scan']);
      expect(api.advertSizes, <int>[16], reason: 'what the radio can show');
      expect(link.state.value.phase, LocalLinkPhase.searching);

      api.current = _linkedOver('bluetooth');
      await link.runCycle();
      expect(
        link.state.value,
        const LocalLinkState(LocalLinkPhase.connected, peers: 1),
      );
      api.current = _linkedOver('lan');
      await link.runCycle();
      expect(link.state.value.phase, LocalLinkPhase.searching);
    });

    test('strangers are ignored', () async {
      await link.start(() => api, foreground: true);
      await link.onSeen(device: 'aa', advert: '9999', psm: 0x81);
      expect(radio.calls.where((String c) => c.startsWith('connect')), isEmpty);
    });

    test('a friend: the lower advert connects', () async {
      api.friends.add('9999');
      await link.start(() => api, foreground: true);
      await link.onSeen(device: 'aa', advert: '9999', psm: 0x81);
      expect(
        radio.calls.last,
        'connect aa psm=129 classic=false e1 advert=5000',
      );
      // Not again at once.
      await link.onSeen(device: 'aa', advert: '9999', psm: 0x81);
      expect(
        radio.calls.where((String c) => c.startsWith('connect')),
        hasLength(1),
      );
    });

    test('a friend with the lower advert: wait, then connect anyway', () async {
      api.friends.add('1000');
      await link.start(() => api, foreground: true);
      await link.onSeen(device: 'aa', advert: '1000', psm: 0x81);
      expect(radio.calls.where((String c) => c.startsWith('connect')), isEmpty);
      now = now.add(link.waitForPeer);
      await link.onSeen(device: 'aa', advert: '1000', psm: 0x81);
      expect(radio.calls.last, startsWith('connect aa'));
    });

    test('a device without a channel is not dialled', () async {
      api.friends.add('9999');
      await link.start(() => api, foreground: true);
      await link.onSeen(device: 'aa', advert: '9999', connectable: false);
      expect(radio.calls.where((String c) => c.startsWith('connect')), isEmpty);
    });

    test('a failed connection gives the endpoint back', () async {
      radio.connects = false;
      api.friends.add('9999');
      await link.start(() => api, foreground: true);
      await link.onSeen(device: 'aa', advert: '9999', psm: 0x81);
      expect(api.closed, <String>['e1']);
    });

    test('an incoming stream goes to the bridge', () async {
      await link.start(() => api, foreground: true);
      await link.onIncoming('in1');
      expect(radio.calls.last, 'accept in1 e1');
    });

    test('an invitation from a stranger is declined', () async {
      link = make(transport: LocalLinkTransport.multipeer);
      await link.start(() => api, foreground: true);
      await link.onIncoming('in1', advert: '9999');
      expect(radio.calls.last, 'reject in1');
      api.friends.add('9999');
      await link.onIncoming('in2', advert: '9999');
      expect(radio.calls.last, 'accept in2 e1');
    });

    test('without a node incoming streams are closed', () async {
      await link.start(() => null, foreground: true);
      await link.onIncoming('in1');
      expect(radio.calls.last, 'reject in1');
    });

    test('paired devices are tried now and then', () async {
      radio.paired = true;
      radio.pairedList = <String>['AA:BB:CC:DD:EE:FF'];
      await link.start(() => api, foreground: true);
      await Future<void>.delayed(Duration.zero);
      expect(
        radio.calls.where((String c) => c.contains('classic=true')),
        hasLength(1),
      );
      await link.runCycle();
      await Future<void>.delayed(Duration.zero);
      expect(
        radio.calls.where((String c) => c.contains('classic=true')),
        hasLength(1),
        reason: 'not again before the retry time',
      );
      now = now.add(link.foregroundPairedRetry);
      await link.runCycle();
      await Future<void>.delayed(Duration.zero);
      expect(
        radio.calls.where((String c) => c.contains('classic=true')),
        hasLength(2),
      );
    });

    test('events from the radio are followed', () async {
      api.friends.add('9999');
      await link.start(() => api, foreground: true);
      radio.emit(<Object?, Object?>{
        'type': 'seen',
        'device': 'bb',
        'advert': '9999',
        'psm': 0x85,
      });
      radio.emit(<Object?, Object?>{'type': 'incoming', 'id': 'in9'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        radio.calls,
        contains('connect bb psm=133 classic=false e1 advert=5000'),
      );
      expect(radio.calls, contains('accept in9 e2'));
    });

    test('stopping gives the radio back', () async {
      await link.start(() => api, foreground: true);
      await link.stop();
      expect(radio.calls.last, 'stop');
      expect(link.state.value.phase, LocalLinkPhase.off);
    });
  });

  group('Go Bluetooth radio', () {
    test('it reports what the bridge has', () async {
      final _Go go = _Go()
        ..answers['YggBtLinkStateJson'] = <String, dynamic>{
          'supported': true,
          'l2cap': false,
          'rfcomm': true,
        };
      final GoBluetoothRadio radio = GoBluetoothRadio(go: go);
      final Map<String, Object?> state = await radio.state();
      expect(state['supported'], isTrue);
      expect(state['paired'], isTrue);
      expect(state['discovery'], isFalse, reason: 'no BLE on Windows');

      go.answers['YggBtLinkStateJson'] = <String, dynamic>{'supported': false};
      expect((await radio.state())['supported'], isFalse);
    });

    test('incoming streams and dials come from polling', () async {
      final _Go go = _Go()
        ..answers['YggBtLinkStartJson'] = <String, dynamic>{'channel': 3}
        ..answers['YggBtLinkDialJson'] = <String, dynamic>{'id': 'd1'};
      final GoBluetoothRadio radio = GoBluetoothRadio(
        go: go,
        pollEvery: const Duration(hours: 1),
      );
      final List<Map<Object?, Object?>> events = <Map<Object?, Object?>>[];
      final StreamSubscription<Map<Object?, Object?>> subscription = radio
          .events
          .listen(events.add);
      addTearDown(subscription.cancel);
      expect(await radio.start(), isTrue);

      final Future<bool> dial = radio.connect(
        'AA:BB:CC:DD:EE:FF',
        LocalLinkEndpoint(id: 'e1', port: 40001, token: Uint8List(16)),
        classic: true,
      );
      go.answers['YggBtLinkPollJson'] = <String, dynamic>{
        'listening': true,
        'incoming': <String>['in1'],
        'dials': <String, String>{'d1': 'ok'},
      };
      radio.pollOnce();
      expect(await dial, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(events, <Map<Object?, Object?>>[
        <Object?, Object?>{'type': 'incoming', 'id': 'in1'},
      ]);
      expect(
        go.calls.firstWhere((String c) => c.startsWith('YggBtLinkDialJson')),
        contains('token: 00000000000000000000000000000000'),
      );

      // The listener died (Bluetooth off).
      go.answers['YggBtLinkPollJson'] = <String, dynamic>{'listening': false};
      radio.pollOnce();
      await Future<void>.delayed(Duration.zero);
      expect(events.last, <Object?, Object?>{'type': 'radio', 'on': false});
      await radio.stop();
      expect(go.calls.last, 'YggBtLinkStopJson');
    });
  });
}
