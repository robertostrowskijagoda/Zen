import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/nearby.dart';

// "W pobliżu" on computers: the same Bluetooth LE advert as the phones
// (manufacturer data of company 0xFFFF: "ZN", the 16-byte token, the
// 4-byte hint), shown and looked for by the computer's own Bluetooth:
// Windows (WinRT advertisement publisher and watcher, the runner's
// nearby_radio_bridge.cpp), macOS (CoreBluetooth, ZenNearbyRadioBridge.swift:
// Apple lets apps look but not show manufacturer data, so a Mac only looks)
// and Linux (BlueZ over D-Bus, here). The radio side is thin; the tokens,
// their schedule and the reading of adverts are worked out here
// ([BackendNearbyRadio]). Computers have no GATT "wave" (writing to someone
// nearby) and no Bluetooth alarm waves: those stay on the phones.

/// Company id of Zen's manufacturer data.
const int kNearbyCompanyId = 0xFFFF;

/// "ZN": what starts Zen's nearby advert (Zen's links use "ZL").
const List<int> kNearbyMagic = <int>[0x5A, 0x4E];

/// The manufacturer data (after the company id) showing [advert] (token and
/// hint, [kNearbyAdvertBytes]).
Uint8List nearbyManufacturerData(List<int> advert) =>
    Uint8List.fromList(<int>[...kNearbyMagic, ...advert]);

/// The token and the hint in [data] (manufacturer data of company 0xFFFF,
/// after the company id), or `null` when it is not Zen's nearby advert.
({Uint8List token, Uint8List hint})? parseNearbyManufacturerData(
  List<int> data,
) {
  if (data.length < kNearbyMagic.length + kNearbyAdvertBytes ||
      data[0] != kNearbyMagic[0] ||
      data[1] != kNearbyMagic[1]) {
    return null;
  }
  return (
    token: Uint8List.fromList(data.sublist(2, 18)),
    hint: Uint8List.fromList(data.sublist(18, 18 + kNearbyHintLength)),
  );
}

/// What a computer's Bluetooth does for "W pobliżu".
abstract interface class NearbyLeBackend {
  /// `present` (an LE adapter at all), `powered`, `canAdvertise`.
  Future<({bool present, bool powered, bool canAdvertise})> state();

  /// Shows [data] (manufacturer data of [kNearbyCompanyId], without the
  /// company id) until [stopAdvertising]; a new call replaces it.
  Future<bool> advertise(Uint8List data);
  Future<void> stopAdvertising();

  /// Looks around: [onSeen] hears the manufacturer data of
  /// [kNearbyCompanyId] (without the company id) of every device seen.
  Future<bool> startScan(
    void Function(String device, Uint8List data, int rssi) onSeen,
  );
  Future<void> stopScan();

  /// Bluetooth switched on (`true`) or off.
  Stream<bool> get powered;
}

/// [NearbyRadio] over a [NearbyLeBackend]: the phones' events and calls,
/// the token schedule followed here (a computer's app runs as long as it
/// is on), adverts read here.
final class BackendNearbyRadio implements NearbyRadio {
  BackendNearbyRadio(this.backend, {int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _poweredSub = backend.powered.listen((bool on) {
      _events.add(<Object?, Object?>{'type': 'bluetooth', 'on': on});
      if (on) {
        unawaited(_applyAdvert());
      }
    });
  }

  final NearbyLeBackend backend;
  final int Function() _now;
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();
  StreamSubscription<bool>? _poweredSub;

  Uint8List? _token;
  Uint8List? _schedule;
  int _scheduleStart = 0;
  Timer? _rotation;
  bool _scanning = false;

  /// What is shown now (tests).
  @visibleForTesting
  Uint8List? get shown => _shown;
  Uint8List? _shown;

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  @override
  Future<Map<Object?, Object?>> state() async {
    final ({bool present, bool powered, bool canAdvertise}) s = await backend
        .state();
    return <Object?, Object?>{
      'supported': s.present,
      'enabled': s.powered,
      // A computer asks nobody (macOS asks itself the first time).
      'permitted': s.present,
      'canAdvertise': s.canAdvertise,
      // No GATT here: no hellos, no alarm waves.
      'canWave': false,
    };
  }

  @override
  Future<bool> requestPermissions() async => (await backend.state()).present;

  @override
  Future<bool> requestEnable() async => (await backend.state()).powered;

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    _token = Uint8List.fromList(token);
    _schedule = null;
    return _applyAdvert();
  }

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async {
    if (adverts.isEmpty || adverts.length % kNearbyAdvertBytes != 0) {
      return false;
    }
    _token = null;
    _schedule = Uint8List.fromList(adverts);
    _scheduleStart = firstSlot;
    return _applyAdvert();
  }

  /// The advert wanted now: the token, or the schedule's of this slot.
  Uint8List? _wanted() {
    final Uint8List? schedule = _schedule;
    if (schedule == null) {
      return _token;
    }
    final int index = nearbySlot(_now()) - _scheduleStart;
    if (index < 0 || index >= schedule.length ~/ kNearbyAdvertBytes) {
      return null;
    }
    return Uint8List.sublistView(
      schedule,
      index * kNearbyAdvertBytes,
      (index + 1) * kNearbyAdvertBytes,
    );
  }

  Future<bool> _applyAdvert() async {
    _rotation?.cancel();
    _rotation = null;
    final Uint8List? advert = _wanted();
    if (_schedule != null) {
      // At the next slot boundary the next token.
      final int slotMs = kNearbySlot.inMilliseconds;
      final int next = (nearbySlot(_now()) + 1) * slotMs - _now() + 500;
      _rotation = Timer(
        Duration(milliseconds: next),
        () => unawaited(_applyAdvert()),
      );
    }
    if (advert == null) {
      _shown = null;
      await backend.stopAdvertising();
      return _schedule != null;
    }
    final bool ok = await backend.advertise(nearbyManufacturerData(advert));
    _shown = ok ? Uint8List.fromList(advert) : null;
    return ok;
  }

  /// Applies the schedule again now (tests; the timer does it otherwise).
  @visibleForTesting
  Future<bool> rotateNow() => _applyAdvert();

  @override
  Future<void> stopAdvertising() async {
    _token = null;
    _schedule = null;
    _shown = null;
    _rotation?.cancel();
    _rotation = null;
    await backend.stopAdvertising();
  }

  @override
  Future<bool> startScan({bool lowPower = false}) async {
    if (_scanning) {
      return true;
    }
    _scanning = await backend.startScan(_onSeen);
    return _scanning;
  }

  void _onSeen(String device, Uint8List data, int rssi) {
    final ({Uint8List token, Uint8List hint})? advert =
        parseNearbyManufacturerData(data);
    if (advert == null || !_scanning) {
      return;
    }
    _events.add(<Object?, Object?>{
      'type': 'seen',
      'token': advert.token,
      'hint': advert.hint,
      'rssi': rssi,
      'device': device,
    });
  }

  @override
  Future<void> stopScan() async {
    _scanning = false;
    await backend.stopScan();
  }

  /// No GATT on computers: nobody nearby can be written to from here.
  @override
  Future<bool> wave(String device, Uint8List data) async => false;

  Future<void> close() async {
    await stopAdvertising();
    await stopScan();
    await _poweredSub?.cancel();
    await _events.close();
  }
}

/// Windows and macOS: the runner's `zen/nearby_le` channel.
final class ChannelNearbyLeBackend implements NearbyLeBackend {
  static const MethodChannel _channel = MethodChannel('zen/nearby_le');
  static const EventChannel _eventChannel = EventChannel(
    'zen/nearby_le/events',
  );

  static final Stream<Map<Object?, Object?>> _stream = _eventChannel
      .receiveBroadcastStream()
      .where((Object? e) => e is Map)
      .cast<Map<Object?, Object?>>()
      .handleError((Object error) => logZenWarning('W pobliżu: $error'));

  void Function(String device, Uint8List data, int rssi)? _onSeen;
  StreamSubscription<Map<Object?, Object?>>? _sub;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      logZenWarning('W pobliżu ($method): ${error.message}');
      return null;
    }
  }

  void _listen() {
    _sub ??= _stream.listen((Map<Object?, Object?> e) {
      final Object? data = e['data'];
      final Object? device = e['device'];
      final Object? rssi = e['rssi'];
      if (e['type'] == 'seen' &&
          data is Uint8List &&
          device is String &&
          rssi is int) {
        _onSeen?.call(device, data, rssi);
      }
    });
  }

  @override
  Stream<bool> get powered => _stream
      .where((Map<Object?, Object?> e) => e['type'] == 'bluetooth')
      .map((Map<Object?, Object?> e) => e['on'] == true);

  @override
  Future<({bool present, bool powered, bool canAdvertise})> state() async {
    final Map<Object?, Object?>? s = await _call<Map<Object?, Object?>>(
      'state',
    );
    return (
      present: s?['present'] == true,
      powered: s?['powered'] == true,
      canAdvertise: s?['canAdvertise'] == true,
    );
  }

  @override
  Future<bool> advertise(Uint8List data) async =>
      await _call<bool>('advertise', <String, Object>{'data': data}) ?? false;

  @override
  Future<void> stopAdvertising() => _call<void>('stopAdvertising');

  @override
  Future<bool> startScan(
    void Function(String device, Uint8List data, int rssi) onSeen,
  ) async {
    _onSeen = onSeen;
    _listen();
    return await _call<bool>('startScan') ?? false;
  }

  @override
  Future<void> stopScan() async {
    _onSeen = null;
    await _call<void>('stopScan');
  }
}

const String _bluez = 'org.bluez';
const String _adapter1 = 'org.bluez.Adapter1';
const String _device1 = 'org.bluez.Device1';
const String _advertisingManager = 'org.bluez.LEAdvertisingManager1';
const String _advertisement1 = 'org.bluez.LEAdvertisement1';

/// The advertisement BlueZ reads: a broadcast (nothing to connect to) with
/// Zen's manufacturer data.
final class _NearbyAdvertisement extends DBusObject {
  _NearbyAdvertisement() : super(DBusObjectPath('/org/zen/nearby/advert'));

  List<int> data = const <int>[];

  Map<String, DBusValue> get _properties => <String, DBusValue>{
    'Type': const DBusString('broadcast'),
    'ManufacturerData': DBusDict(
      DBusSignature('q'),
      DBusSignature('v'),
      <DBusValue, DBusValue>{
        const DBusUint16(kNearbyCompanyId): DBusVariant(DBusArray.byte(data)),
      },
    ),
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(
    DBusMethodCall methodCall,
  ) async =>
      methodCall.interface == _advertisement1 && methodCall.name == 'Release'
      ? DBusMethodSuccessResponse()
      : DBusMethodErrorResponse.unknownMethod();

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == _advertisement1
            ? _properties
            : const <String, DBusValue>{},
      );

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final DBusValue? value = interface == _advertisement1
        ? _properties[name]
        : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }
}

/// Zen's nearby advert among a device's ManufacturerData ({uint16: bytes}),
/// unwrapped from D-Bus variants.
Uint8List? bluezNearbyData(DBusValue? manufacturerData) {
  final DBusValue? data = _unwrap(manufacturerData);
  if (data is! DBusDict) {
    return null;
  }
  for (final MapEntry<DBusValue, DBusValue> e in data.children.entries) {
    final DBusValue? value = _unwrap(e.value);
    if (e.key is DBusUint16 &&
        (e.key as DBusUint16).value == kNearbyCompanyId &&
        value is DBusArray) {
      final Uint8List bytes = Uint8List.fromList(<int>[
        for (final DBusValue b in value.children)
          if (b is DBusByte) b.value,
      ]);
      return parseNearbyManufacturerData(bytes) == null ? null : bytes;
    }
  }
  return null;
}

DBusValue? _unwrap(DBusValue? value) {
  DBusValue? out = value;
  while (out is DBusVariant) {
    out = out.value;
  }
  return out;
}

/// Linux: BlueZ over the system D-Bus.
final class BluezNearbyBackend implements NearbyLeBackend {
  BluezNearbyBackend({DBusClient Function()? connect})
    : _connect = connect ?? DBusClient.system;

  final DBusClient Function() _connect;
  DBusClient? _client;
  DBusObjectPath? _adapter;
  DBusRemoteObjectManager? _manager;
  StreamSubscription<DBusSignal>? _signals;
  final _NearbyAdvertisement _advert = _NearbyAdvertisement();
  bool _exported = false;
  bool _advertising = false;
  bool _discovering = false;
  void Function(String device, Uint8List data, int rssi)? _onSeen;
  final StreamController<bool> _powered = StreamController<bool>.broadcast();

  /// Per device object: its address, last Zen advert and signal.
  final Map<DBusObjectPath, (String, Uint8List?, int)> _devices =
      <DBusObjectPath, (String, Uint8List?, int)>{};

  DBusClient get _bus => _client ??= _connect();

  DBusRemoteObjectManager get _objects => _manager ??= DBusRemoteObjectManager(
    _bus,
    name: _bluez,
    path: DBusObjectPath('/'),
  );

  DBusRemoteObject _object(DBusObjectPath path) =>
      DBusRemoteObject(_bus, name: _bluez, path: path);

  Future<DBusObjectPath?> _findAdapter() async {
    if (_adapter case final DBusObjectPath known) {
      return known;
    }
    final Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects =
        await _objects.getManagedObjects();
    for (final MapEntry<DBusObjectPath, Map<String, Map<String, DBusValue>>> e
        in objects.entries) {
      if (e.value.containsKey(_adapter1)) {
        _adapter = e.key;
        _watch();
        return e.key;
      }
    }
    return null;
  }

  void _watch() {
    _signals ??= _objects.signals.listen(
      _onSignal,
      onError: (Object error) => logZenWarning('BlueZ: $error'),
    );
  }

  @override
  Stream<bool> get powered => _powered.stream;

  @override
  Future<({bool present, bool powered, bool canAdvertise})> state() async {
    try {
      final DBusObjectPath? adapter = await _findAdapter();
      if (adapter == null) {
        return (present: false, powered: false, canAdvertise: false);
      }
      final DBusValue on = await _object(
        adapter,
      ).getProperty(_adapter1, 'Powered', signature: DBusSignature('b'));
      final Map<String, Map<String, DBusValue>>? adapterObject = (await _objects
          .getManagedObjects())[adapter];
      return (
        present: true,
        powered: on is DBusBoolean && on.value,
        canAdvertise: adapterObject?.containsKey(_advertisingManager) ?? false,
      );
    } on Object catch (error) {
      logZenWarning('BlueZ unavailable: $error');
      _adapter = null;
      return (present: false, powered: false, canAdvertise: false);
    }
  }

  @override
  Future<bool> advertise(Uint8List data) async {
    try {
      final DBusObjectPath? adapter = await _findAdapter();
      if (adapter == null) {
        return false;
      }
      await stopAdvertising();
      _advert.data = List<int>.unmodifiable(data);
      if (!_exported) {
        await _bus.registerObject(_advert);
        _exported = true;
      }
      await _object(adapter).callMethod(
        _advertisingManager,
        'RegisterAdvertisement',
        <DBusValue>[_advert.path, DBusDict.stringVariant(const {})],
        replySignature: DBusSignature(''),
      );
      _advertising = true;
      return true;
    } on Object catch (error) {
      logZenWarning('BlueZ: showing this computer failed: $error');
      return false;
    }
  }

  @override
  Future<void> stopAdvertising() async {
    final DBusObjectPath? adapter = _adapter;
    if (!_advertising || adapter == null) {
      return;
    }
    _advertising = false;
    try {
      await _object(adapter).callMethod(
        _advertisingManager,
        'UnregisterAdvertisement',
        <DBusValue>[_advert.path],
        replySignature: DBusSignature(''),
      );
    } on Object catch (error) {
      logZenWarning('BlueZ: advert not stopped: $error');
    }
  }

  @override
  Future<bool> startScan(
    void Function(String device, Uint8List data, int rssi) onSeen,
  ) async {
    try {
      final DBusObjectPath? adapter = await _findAdapter();
      if (adapter == null) {
        return false;
      }
      _onSeen = onSeen;
      final Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects =
          await _objects.getManagedObjects();
      for (final MapEntry<DBusObjectPath, Map<String, Map<String, DBusValue>>> e
          in objects.entries) {
        final Map<String, DBusValue>? device = e.value[_device1];
        if (device != null) {
          _remember(e.key, device);
        }
      }
      final DBusRemoteObject object = _object(adapter);
      await object.callMethod(_adapter1, 'SetDiscoveryFilter', <DBusValue>[
        DBusDict.stringVariant(<String, DBusValue>{
          'Transport': const DBusString('le'),
          'DuplicateData': const DBusBoolean(true),
        }),
      ], replySignature: DBusSignature(''));
      if (!_discovering) {
        await object.callMethod(
          _adapter1,
          'StartDiscovery',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        );
        _discovering = true;
      }
      return true;
    } on Object catch (error) {
      logZenWarning('BlueZ: looking around failed: $error');
      return false;
    }
  }

  @override
  Future<void> stopScan() async {
    _onSeen = null;
    final DBusObjectPath? adapter = _adapter;
    if (!_discovering || adapter == null) {
      return;
    }
    _discovering = false;
    try {
      await _object(adapter).callMethod(
        _adapter1,
        'StopDiscovery',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
    } on Object catch (error) {
      logZenWarning('BlueZ: looking around not stopped: $error');
    }
  }

  void _remember(DBusObjectPath path, Map<String, DBusValue> props) {
    final DBusValue? address = _unwrap(props['Address']);
    final (String, Uint8List?, int)? had = _devices[path];
    final String name = address is DBusString
        ? address.value.toUpperCase()
        : had?.$1 ?? '';
    if (name.isEmpty) {
      return;
    }
    final DBusValue? rssi = _unwrap(props['RSSI']);
    final Uint8List? data = props.containsKey('ManufacturerData')
        ? bluezNearbyData(props['ManufacturerData'])
        : had?.$2;
    final int signal = rssi is DBusInt16 ? rssi.value : had?.$3 ?? -100;
    _devices[path] = (name, data, signal);
    if (_devices.length > 2000) {
      _devices.remove(_devices.keys.first);
    }
    final void Function(String, Uint8List, int)? onSeen = _onSeen;
    if (onSeen != null &&
        data != null &&
        (props.containsKey('RSSI') || props.containsKey('ManufacturerData'))) {
      onSeen(name, data, signal);
    }
  }

  void _onSignal(DBusSignal signal) {
    if (signal is DBusObjectManagerInterfacesAddedSignal) {
      final Map<String, DBusValue>? device =
          signal.interfacesAndProperties[_device1];
      if (device != null) {
        _remember(signal.changedPath, device);
      }
    } else if (signal is DBusObjectManagerInterfacesRemovedSignal) {
      if (signal.interfaces.contains(_device1)) {
        _devices.remove(signal.changedPath);
      }
    } else if (signal is DBusPropertiesChangedSignal) {
      if (signal.propertiesInterface == _device1) {
        _remember(signal.path, signal.changedProperties);
      } else if (signal.propertiesInterface == _adapter1 &&
          signal.path == _adapter) {
        final DBusValue? on = _unwrap(signal.changedProperties['Powered']);
        if (on is DBusBoolean) {
          if (!on.value) {
            _advertising = false;
            _discovering = false;
          }
          _powered.add(on.value);
        }
      }
    }
  }
}

/// The radio of this platform: the phone's own on Android, the computer's
/// Bluetooth on Windows, macOS and Linux, none elsewhere.
NearbyRadio platformNearbyRadio() {
  // `flutter test` on a computer: no Bluetooth of the host (tests bring
  // their own radios).
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
    return ChannelNearbyRadio();
  }
  if (Platform.isWindows || Platform.isMacOS) {
    return BackendNearbyRadio(ChannelNearbyLeBackend());
  }
  if (Platform.isLinux) {
    return BackendNearbyRadio(BluezNearbyBackend());
  }
  return ChannelNearbyRadio();
}
