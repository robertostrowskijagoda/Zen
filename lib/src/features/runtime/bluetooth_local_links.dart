import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/bluez_le.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/native_stream_local_link.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';

// Bluetooth and Multipeer links on each platform:
//  - Android: BLE advertising, L2CAP channels (Android 10+) and RFCOMM with
//    paired devices (ZenBluetoothLinkBridge.kt);
//  - iPhone, iPad, Mac: CoreBluetooth L2CAP channels, and Multipeer
//    Connectivity between Apple devices (ZenLocalLinksBridge.swift);
//  - Linux: BlueZ over D-Bus for the adverts (bluez_le.dart), the Go
//    bridge's L2CAP sockets for the streams;
//  - Windows: BLE adverts and GATT streams through the runner (Windows
//    gives apps no BLE L2CAP channels; bluetooth_le_bridge.cpp), with
//    Android and other Windows computers; RFCOMM with paired devices
//    through the Go bridge ([WindowsBluetoothRadio]).
// The radios share one format (bluetooth_link.go) so every pair of
// platforms that both have a way can link.

/// Whether this device has Bluetooth links.
bool get bluetoothLinksPlatform =>
    localTransportsOf(localLinksHost).contains(LocalLinkTransport.bluetooth);

/// Whether this device has Multipeer Connectivity.
bool get multipeerLinksPlatform =>
    localTransportsOf(localLinksHost).contains(LocalLinkTransport.multipeer);

/// The Bluetooth radio of [platform].
NativeLinkRadio bluetoothRadioFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.windows => WindowsBluetoothRadio(),
      TargetPlatform.linux => GoBluetoothRadio(le: BluezLe()),
      _ => const MethodChannelLinkRadio('zen/bt_link'),
    };

NativeStreamLocalLink bluetoothLocalLink([TargetPlatform? platform]) {
  final TargetPlatform on = platform ?? localLinksHost;
  return NativeStreamLocalLink(
    transport: LocalLinkTransport.bluetooth,
    radio: bluetoothRadioFor(on),
    supportedPlatform: localTransportsOf(
      on,
    ).contains(LocalLinkTransport.bluetooth),
  );
}

NativeStreamLocalLink multipeerLocalLink() => NativeStreamLocalLink(
  transport: LocalLinkTransport.multipeer,
  radio: const MethodChannelLinkRadio('zen/multipeer'),
  supportedPlatform: multipeerLinksPlatform,
);

/// The Go bridge's Bluetooth calls (bluetooth_link_exports.go): each takes
/// a JSON object and answers one (`null` on an error, logged).
abstract interface class GoBluetoothApi {
  Map<String, dynamic>? call(String function, [Map<String, Object?>? request]);
}

typedef _NativeJsonCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeJsonCallDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);

final class _FfiGoBluetoothApi implements GoBluetoothApi {
  _FfiGoBluetoothApi(this._library)
    : _free = _library
          .lookupFunction<_NativeFree, void Function(Pointer<Utf8>)>(
            'YggFreeString',
          );

  final DynamicLibrary _library;
  final void Function(Pointer<Utf8>) _free;
  final Map<String, _NativeJsonCallDart> _functions =
      <String, _NativeJsonCallDart>{};

  @override
  Map<String, dynamic>? call(String function, [Map<String, Object?>? request]) {
    final Pointer<Utf8> argument = jsonEncode(
      request ?? const <String, Object?>{},
    ).toNativeUtf8();
    try {
      final _NativeJsonCallDart call = _functions[function] ??= _library
          .lookupFunction<_NativeJsonCall, _NativeJsonCallDart>(function);
      final Pointer<Utf8> result = call(argument);
      final String text;
      try {
        text = result.toDartString();
      } finally {
        _free(result);
      }
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      if (decoded['ok'] != true) {
        logZenWarning('Bluetooth $function: ${decoded['error']}');
        return null;
      }
      final Object? data = decoded['data'];
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on Object catch (error) {
      logZenWarning('Bluetooth $function failed: $error');
      return null;
    } finally {
      malloc.free(argument);
    }
  }
}

/// Bluetooth through the Go bridge: on Linux the streams (polled while
/// running) with BlueZ's adverts ([le]); on Windows the RFCOMM streams with
/// paired devices, inside [WindowsBluetoothRadio].
final class GoBluetoothRadio implements NativeLinkRadio {
  GoBluetoothRadio({
    GoBluetoothApi? go,
    BluezLe? le,
    this.pollEvery = const Duration(milliseconds: 500),
    this.dialTimeout = const Duration(seconds: 45),
  }) : _go = go,
       _le = le;

  final BluezLe? _le;
  final Duration pollEvery;

  /// A dial whose outcome has not come by then counts as failed.
  final Duration dialTimeout;

  GoBluetoothApi? _go;
  bool _goTried = false;
  bool _started = false;
  int _psm = 0;
  Timer? _poll;
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();
  final Map<String, Completer<bool>> _dials = <String, Completer<bool>>{};

  GoBluetoothApi? get _api {
    if (_go == null && !_goTried) {
      _goTried = true;
      try {
        _go = _FfiGoBluetoothApi(YggdrasilBridgeFfi.openLibrary());
      } on Object catch (error) {
        logZenWarning('Bluetooth: no bridge library: $error');
      }
    }
    return _go;
  }

  @override
  Future<Map<String, Object?>> state() async {
    final Map<String, dynamic>? go = _api?.call('YggBtLinkStateJson');
    final bool l2cap = go?['l2cap'] == true;
    final bool rfcomm = go?['rfcomm'] == true;
    final BluezLe? le = _le;
    bool discovery = false;
    bool enabled = rfcomm;
    if (l2cap && le != null) {
      final BluezAdapterState adapter = await le.state();
      discovery = adapter.present;
      enabled = adapter.powered;
    }
    return <String, Object?>{
      'supported': go?['supported'] == true && (rfcomm || discovery),
      'permitted': true,
      'enabled': enabled,
      'advertBytes': BluezLe.advertBytes,
      'discovery': discovery,
      'paired': rfcomm,
    };
  }

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> start() async {
    final Map<String, dynamic>? info = _api?.call('YggBtLinkStartJson');
    if (info == null) {
      return false;
    }
    final Object? psm = info['psm'];
    _psm = psm is int ? psm : 0;
    _started = true;
    _poll ??= Timer.periodic(pollEvery, (_) => pollOnce());
    return true;
  }

  @override
  Future<void> stop() async {
    _started = false;
    _poll?.cancel();
    _poll = null;
    _api?.call('YggBtLinkStopJson');
    await _le?.stop();
    for (final Completer<bool> dial in _dials.values) {
      if (!dial.isCompleted) {
        dial.complete(false);
      }
    }
    _dials.clear();
  }

  @override
  Future<void> advertise(String advertHex, Duration window) async {
    final BluezLe? le = _le;
    final List<int>? advert = _unhex(advertHex);
    if (le == null || _psm == 0 || advert == null) {
      return;
    }
    await le.advertise(zenLinkManufacturerData(_psm, advert), window);
  }

  @override
  Future<void> scan(Duration window) async {
    await _le?.scan(window, (String device, List<int> data) {
      final ({int psm, List<int> advert})? seen = parseZenLinkManufacturerData(
        data,
      );
      if (seen == null || !_started) {
        return;
      }
      _events.add(<Object?, Object?>{
        'type': 'seen',
        'device': device,
        'advert': _hex(seen.advert),
        'psm': seen.psm,
        'connectable': seen.psm != 0,
      });
    });
  }

  @override
  Future<List<String>> pairedDevices() async {
    final Object? devices = _api?.call('YggBtLinkPairedJson')?['devices'];
    return devices is List
        ? devices.whereType<String>().toList(growable: false)
        : const <String>[];
  }

  @override
  Future<bool> connect(
    String device,
    LocalLinkEndpoint endpoint, {
    int psm = 0,
    bool classic = false,
    String? advert,
  }) async {
    final Object? id = _api?.call('YggBtLinkDialJson', <String, Object?>{
      'device': device,
      'psm': psm,
      'classic': classic,
      'port': endpoint.port,
      'token': _hex(endpoint.token),
    })?['id'];
    if (id is! String) {
      return false;
    }
    final Completer<bool> done = _dials[id] = Completer<bool>();
    try {
      return await done.future.timeout(dialTimeout, onTimeout: () => false);
    } finally {
      _dials.remove(id);
    }
  }

  @override
  Future<bool> accept(String id, LocalLinkEndpoint endpoint) async =>
      _api?.call('YggBtLinkAcceptJson', <String, Object?>{
        'id': id,
        'port': endpoint.port,
        'token': _hex(endpoint.token),
      }) !=
      null;

  @override
  Future<void> reject(String id) async {
    _api?.call('YggBtLinkRejectJson', <String, Object?>{'id': id});
  }

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  /// One look at the bridge: incoming streams, ended dials, the listener.
  @visibleForTesting
  void pollOnce() {
    if (!_started) {
      return;
    }
    final Map<String, dynamic>? state = _api?.call('YggBtLinkPollJson');
    if (state == null) {
      return;
    }
    final Object? incoming = state['incoming'];
    if (incoming is List) {
      for (final String id in incoming.whereType<String>()) {
        _events.add(<Object?, Object?>{'type': 'incoming', 'id': id});
      }
    }
    final Object? dials = state['dials'];
    if (dials is Map) {
      for (final MapEntry<dynamic, dynamic> dial in dials.entries) {
        final Completer<bool>? done = _dials[dial.key];
        if (done != null && !done.isCompleted) {
          done.complete(dial.value == 'ok');
        }
      }
    }
    if (state['listening'] == false) {
      // The radio went away (Bluetooth off): the link starts it again.
      _started = false;
      _poll?.cancel();
      _poll = null;
      _events.add(<Object?, Object?>{'type': 'radio', 'on': false});
    }
  }
}

/// Bluetooth on Windows: BLE adverts and GATT streams from the runner
/// ([le]: `zen/bt_link`, bluetooth_le_bridge.cpp) and RFCOMM with paired
/// devices from the Go bridge ([classic]). An incoming stream goes back to
/// the side that reported it.
final class WindowsBluetoothRadio implements NativeLinkRadio {
  WindowsBluetoothRadio({NativeLinkRadio? classic, NativeLinkRadio? le})
    : _classic = classic ?? GoBluetoothRadio(),
      _le = le ?? const MethodChannelLinkRadio('zen/bt_link');

  final NativeLinkRadio _classic;
  final NativeLinkRadio _le;

  /// Incoming streams the runner reported and Dart has not answered yet
  /// (a set literal keeps the order: the oldest goes first when full).
  final Set<String> _leIncoming = <String>{};
  static const int _maxIncoming = 64;
  final List<StreamSubscription<Map<Object?, Object?>>> _subscriptions =
      <StreamSubscription<Map<Object?, Object?>>>[];
  late final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast(
        onListen: _listen,
        onCancel: _cancel,
      );

  @override
  Future<Map<String, Object?>> state() async {
    final List<Map<String, Object?>> both = await Future.wait(
      <Future<Map<String, Object?>>>[_classic.state(), _le.state()],
    );
    final Map<String, Object?> classic = both[0];
    final Map<String, Object?> le = both[1];
    final bool leOn = le['supported'] == true;
    final bool pairedOn =
        classic['supported'] == true && classic['paired'] == true;
    return <String, Object?>{
      'supported': leOn || pairedOn,
      'permitted': true,
      'enabled':
          (leOn && le['enabled'] == true) ||
          (pairedOn && classic['enabled'] == true),
      'advertBytes': le['advertBytes'] ?? 0,
      'discovery': leOn && le['discovery'] == true,
      'paired': pairedOn,
    };
  }

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> start() async {
    final List<bool> started = await Future.wait(<Future<bool>>[
      _classic.start(),
      _le.start(),
    ]);
    return started.contains(true);
  }

  @override
  Future<void> stop() async {
    _leIncoming.clear();
    await Future.wait(<Future<void>>[_classic.stop(), _le.stop()]);
  }

  @override
  Future<void> advertise(String advertHex, Duration window) =>
      _le.advertise(advertHex, window);

  @override
  Future<void> scan(Duration window) => _le.scan(window);

  @override
  Future<List<String>> pairedDevices() => _classic.pairedDevices();

  @override
  Future<bool> connect(
    String device,
    LocalLinkEndpoint endpoint, {
    int psm = 0,
    bool classic = false,
    String? advert,
  }) => classic
      ? _classic.connect(device, endpoint, classic: true)
      : _le.connect(device, endpoint, psm: psm, advert: advert);

  @override
  Future<bool> accept(String id, LocalLinkEndpoint endpoint) =>
      _leIncoming.remove(id)
      ? _le.accept(id, endpoint)
      : _classic.accept(id, endpoint);

  @override
  Future<void> reject(String id) =>
      _leIncoming.remove(id) ? _le.reject(id) : _classic.reject(id);

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  void _listen() {
    _subscriptions
      ..add(_classic.events.listen(_events.add, onError: _events.addError))
      ..add(_le.events.listen(_fromLe, onError: _events.addError));
  }

  void _fromLe(Map<Object?, Object?> event) {
    final Object? id = event['id'];
    if (event['type'] == 'incoming' && id is String) {
      if (_leIncoming.length >= _maxIncoming) {
        _leIncoming.remove(_leIncoming.first);
      }
      _leIncoming.add(id);
    }
    _events.add(event);
  }

  Future<void> _cancel() async {
    final List<StreamSubscription<Map<Object?, Object?>>> subscriptions =
        List<StreamSubscription<Map<Object?, Object?>>>.of(_subscriptions);
    _subscriptions.clear();
    for (final StreamSubscription<Map<Object?, Object?>> s in subscriptions) {
      await s.cancel();
    }
  }
}

String _hex(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  for (final int b in bytes) {
    out.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

List<int>? _unhex(String hex) {
  if (hex.length.isOdd) {
    return null;
  }
  final List<int> out = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    final int? byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) {
      return null;
    }
    out.add(byte);
  }
  return out;
}
