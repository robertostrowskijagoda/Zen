import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:zen/src/core/logging/zen_log.dart';

// BLE advertising and scanning on Linux through BlueZ over D-Bus, for the
// Bluetooth links (bluetooth_local_links.dart). The L2CAP channels
// themselves are the Go bridge's (bluetooth_link_linux.go).
//
// BlueZ puts everything into the advertising packet (31 bytes, with the
// 3-byte flags), so the advert goes out as manufacturer data alone:
// company 0xFFFF, "ZL", the PSM and a 20-byte advert (a 13-byte Bloom
// filter). Without the Zen service UUID an iPhone still sees it (it scans
// for everything while Zen is open). Apple devices show their advert only
// through GATT, which this side does not read: an iPhone or Mac connects
// to Linux instead (native_stream_local_link.dart lets either side do it).

const String _bluez = 'org.bluez';
const String _adapterInterface = 'org.bluez.Adapter1';
const String _deviceInterface = 'org.bluez.Device1';
const String _advertisingInterface = 'org.bluez.LEAdvertisingManager1';
const String _advertisementInterface = 'org.bluez.LEAdvertisement1';

/// Company id 0xFFFF of the manufacturer data Zen's links advertise.
const int kZenLinkCompanyId = 0xFFFF;

/// "ZL", the PSM (uint16 little-endian), then the advert.
List<int> zenLinkManufacturerData(int psm, List<int> advert) => <int>[
  0x5A,
  0x4C,
  psm & 0xFF,
  (psm >> 8) & 0xFF,
  ...advert,
];

/// The PSM and the advert of Zen's manufacturer data, or `null`.
({int psm, List<int> advert})? parseZenLinkManufacturerData(List<int> data) {
  // The smallest advert: a 7-byte header and an 8-byte filter.
  if (data.length < 4 + 15 || data[0] != 0x5A || data[1] != 0x4C) {
    return null;
  }
  return (psm: data[2] | (data[3] << 8), advert: data.sublist(4));
}

/// What [BluezLe.state] found.
typedef BluezAdapterState = ({bool present, bool powered});

/// The advertisement BlueZ reads (LEAdvertisement1).
final class _ZenAdvertisement extends DBusObject {
  _ZenAdvertisement(super.path);

  List<int> data = const <int>[];

  Map<String, DBusValue> get _properties => <String, DBusValue>{
    'Type': const DBusString('peripheral'),
    'ManufacturerData': DBusDict(
      DBusSignature('q'),
      DBusSignature('v'),
      <DBusValue, DBusValue>{
        const DBusUint16(kZenLinkCompanyId): DBusVariant(DBusArray.byte(data)),
      },
    ),
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == _advertisementInterface &&
        methodCall.name == 'Release') {
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == _advertisementInterface
            ? _properties
            : const <String, DBusValue>{},
      );

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final DBusValue? value = interface == _advertisementInterface
        ? _properties[name]
        : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }
}

final class BluezLe {
  BluezLe({DBusClient Function()? connect})
    : _connect = connect ?? DBusClient.system;

  /// The Bloom filter bytes that fit the packet (see the top of this file).
  static const int advertBytes = 13;

  final DBusClient Function() _connect;
  DBusClient? _client;
  DBusObjectPath? _adapter;
  DBusRemoteObjectManager? _manager;
  StreamSubscription<DBusSignal>? _signals;
  _ZenAdvertisement? _advertisement;
  bool _exported = false;
  bool _advertising = false;
  Timer? _advertTimer;
  Timer? _scanTimer;
  void Function(String device, List<int> data)? _onSeen;

  /// Device objects BlueZ knows: "AA:BB:CC:DD:EE:FF/public|random".
  final Map<DBusObjectPath, String> _devices = <DBusObjectPath, String>{};

  DBusClient get _bus => _client ??= _connect();

  DBusRemoteObjectManager get _objects => _manager ??= DBusRemoteObjectManager(
    _bus,
    name: _bluez,
    path: DBusObjectPath('/'),
  );

  Future<DBusObjectPath?> _findAdapter() async {
    final DBusObjectPath? known = _adapter;
    if (known != null) {
      return known;
    }
    final Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects =
        await _objects.getManagedObjects();
    for (final MapEntry<DBusObjectPath, Map<String, Map<String, DBusValue>>>
        entry
        in objects.entries) {
      if (entry.value.containsKey(_adapterInterface)) {
        _adapter = entry.key;
        return entry.key;
      }
    }
    return null;
  }

  DBusRemoteObject _adapterObject(DBusObjectPath path) =>
      DBusRemoteObject(_bus, name: _bluez, path: path);

  /// Whether there is a Bluetooth adapter, and whether it is on.
  Future<BluezAdapterState> state() async {
    try {
      final DBusObjectPath? adapter = await _findAdapter();
      if (adapter == null) {
        return (present: false, powered: false);
      }
      final DBusValue powered = await _adapterObject(adapter).getProperty(
        _adapterInterface,
        'Powered',
        signature: DBusSignature('b'),
      );
      return (present: true, powered: powered is DBusBoolean && powered.value);
    } on Object catch (error) {
      logZenWarning('BlueZ unavailable: $error');
      _adapter = null;
      return (present: false, powered: false);
    }
  }

  /// Shows [data] (Zen's manufacturer data) for [window].
  Future<void> advertise(List<int> data, Duration window) async {
    try {
      final DBusObjectPath? adapter = await _findAdapter();
      if (adapter == null) {
        return;
      }
      await _stopAdvertising();
      final _ZenAdvertisement advertisement = _advertisement ??=
          _ZenAdvertisement(DBusObjectPath('/org/zen/link/advertisement'));
      advertisement.data = List<int>.unmodifiable(data);
      if (!_exported) {
        await _bus.registerObject(advertisement);
        _exported = true;
      }
      await _adapterObject(adapter).callMethod(
        _advertisingInterface,
        'RegisterAdvertisement',
        <DBusValue>[advertisement.path, DBusDict.stringVariant(const {})],
        replySignature: DBusSignature(''),
      );
      _advertising = true;
      _advertTimer = Timer(window, () => unawaited(_stopAdvertising()));
    } on Object catch (error) {
      logZenWarning('BlueZ advertising failed: $error');
    }
  }

  Future<void> _stopAdvertising() async {
    _advertTimer?.cancel();
    _advertTimer = null;
    final DBusObjectPath? adapter = _adapter;
    final _ZenAdvertisement? advertisement = _advertisement;
    if (!_advertising || adapter == null || advertisement == null) {
      return;
    }
    _advertising = false;
    try {
      await _adapterObject(adapter).callMethod(
        _advertisingInterface,
        'UnregisterAdvertisement',
        <DBusValue>[advertisement.path],
        replySignature: DBusSignature(''),
      );
    } on Object catch (error) {
      logZenWarning('BlueZ advertising not stopped: $error');
    }
  }

  /// Looks for Zen's manufacturer data for [window]; [onSeen] hears each
  /// one (the device as "AA:BB:CC:DD:EE:FF/public|random").
  Future<void> scan(
    Duration window,
    void Function(String device, List<int> data) onSeen,
  ) async {
    try {
      final DBusObjectPath? adapter = await _findAdapter();
      if (adapter == null) {
        return;
      }
      _onSeen = onSeen;
      _signals ??= _objects.signals.listen(
        _onSignal,
        onError: (Object error) => logZenWarning('BlueZ: $error'),
      );
      final Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects =
          await _objects.getManagedObjects();
      for (final MapEntry<DBusObjectPath, Map<String, Map<String, DBusValue>>>
          entry
          in objects.entries) {
        final Map<String, DBusValue>? device = entry.value[_deviceInterface];
        if (device != null) {
          _remember(entry.key, device);
        }
      }
      final DBusRemoteObject object = _adapterObject(adapter);
      await object.callMethod(
        _adapterInterface,
        'SetDiscoveryFilter',
        <DBusValue>[
          DBusDict.stringVariant(<String, DBusValue>{
            'Transport': const DBusString('le'),
            'DuplicateData': const DBusBoolean(true),
          }),
        ],
        replySignature: DBusSignature(''),
      );
      if (_scanTimer == null) {
        await object.callMethod(
          _adapterInterface,
          'StartDiscovery',
          const <DBusValue>[],
          replySignature: DBusSignature(''),
        );
      }
      _scanTimer?.cancel();
      _scanTimer = Timer(window, () => unawaited(_stopScan()));
    } on Object catch (error) {
      logZenWarning('BlueZ scan failed: $error');
    }
  }

  Future<void> _stopScan() async {
    final bool scanning = _scanTimer != null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _onSeen = null;
    final DBusObjectPath? adapter = _adapter;
    if (!scanning || adapter == null) {
      return;
    }
    try {
      await _adapterObject(adapter).callMethod(
        _adapterInterface,
        'StopDiscovery',
        const <DBusValue>[],
        replySignature: DBusSignature(''),
      );
    } on Object catch (error) {
      logZenWarning('BlueZ scan not stopped: $error');
    }
  }

  void _remember(DBusObjectPath path, Map<String, DBusValue> device) {
    final DBusValue? address = _unwrap(device['Address']);
    final DBusValue? type = _unwrap(device['AddressType']);
    if (address is DBusString) {
      final String kind = type is DBusString && type.value == 'random'
          ? 'random'
          : 'public';
      _devices[path] = '${address.value.toUpperCase()}/$kind';
    }
  }

  void _onSignal(DBusSignal signal) {
    if (signal is DBusObjectManagerInterfacesAddedSignal) {
      final Map<String, DBusValue>? device =
          signal.interfacesAndProperties[_deviceInterface];
      if (device != null) {
        _remember(signal.changedPath, device);
        _report(signal.changedPath, device['ManufacturerData']);
      }
    } else if (signal is DBusObjectManagerInterfacesRemovedSignal) {
      if (signal.interfaces.contains(_deviceInterface)) {
        _devices.remove(signal.changedPath);
      }
    } else if (signal is DBusPropertiesChangedSignal) {
      if (signal.propertiesInterface == _deviceInterface) {
        _report(signal.path, signal.changedProperties['ManufacturerData']);
      }
    }
  }

  void _report(DBusObjectPath path, DBusValue? manufacturerData) {
    final void Function(String device, List<int> data)? onSeen = _onSeen;
    final String? device = _devices[path];
    final DBusValue? data = _unwrap(manufacturerData);
    if (onSeen == null || device == null || data is! DBusDict) {
      return;
    }
    for (final MapEntry<DBusValue, DBusValue> entry in data.children.entries) {
      final DBusValue key = entry.key;
      final DBusValue? value = _unwrap(entry.value);
      if (key is DBusUint16 &&
          key.value == kZenLinkCompanyId &&
          value is DBusArray) {
        onSeen(
          device,
          value.children
              .whereType<DBusByte>()
              .map((DBusByte b) => b.value)
              .toList(growable: false),
        );
      }
    }
  }

  static DBusValue? _unwrap(DBusValue? value) {
    DBusValue? out = value;
    while (out is DBusVariant) {
      out = out.value;
    }
    return out;
  }

  /// Stops advertising and scanning (the D-Bus connection stays).
  Future<void> stop() async {
    await _stopAdvertising();
    await _stopScan();
  }

  Future<void> close() async {
    await stop();
    await _signals?.cancel();
    _signals = null;
    final DBusClient? client = _client;
    _client = null;
    _manager = null;
    _adapter = null;
    _exported = false;
    _advertisement = null;
    _devices.clear();
    await client?.close();
  }
}
