import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/local_link.dart';

// Links over a native byte stream (§5.1 item 6): Bluetooth (Android and
// Apple through their bridges, Linux and Windows through the Go bridge,
// bluetooth_local_links.dart) and Apple's Multipeer Connectivity. The radio
// shows the bridge's advert (a Bloom filter only friends can test, renewed
// every cycle) and looks for others' in short windows; this file decides
// whom to connect to and hands every stream to the bridge
// (LocalLinkNodeApi.openStream), which proves the pair in its handshake and
// refuses everyone else.
//
// Seeing a friend's advert: the device whose own advert is lower connects;
// the other one waits a little and connects itself if nothing comes (the
// other side may not be able to). A stream someone opened to this device
// is always handed to the bridge (strangers fail its handshake); Multipeer
// invitations carry the inviter's advert and are declined when it does
// not match. Classic Bluetooth (RFCOMM) has no adverts: devices paired in
// the system's Bluetooth settings are tried now and then instead.
//
// Battery: advertising and scanning run only in windows of every cycle,
// and only while the controller runs the link (the app is used, or the
// Android background service runs).

/// The radio side of a [NativeStreamLocalLink]; a fake in tests.
abstract interface class NativeLinkRadio {
  /// `{supported, permitted, enabled, advertBytes, discovery, paired}`:
  /// [advertBytes] the Bloom filter size the radio can show (0: any),
  /// `discovery` whether it advertises and scans, `paired` whether it links
  /// with devices paired in the system settings.
  Future<Map<String, Object?>> state();

  Future<bool> requestPermissions();

  /// Takes incoming streams from now on; `false` if it cannot (radio off).
  Future<bool> start();

  /// Stops everything, closing every stream.
  Future<void> stop();

  /// Shows [advertHex] for [window] (replacing the one shown).
  Future<void> advertise(String advertHex, Duration window);

  /// Looks for others' adverts for [window]; they come as `seen` events.
  Future<void> scan(Duration window);

  /// Paired devices worth trying that have no stream open now.
  Future<List<String>> pairedDevices();

  /// Opens a stream to [device] and pumps it into [endpoint]; `true` once
  /// it is connected. [psm]: the L2CAP channel it showed; [classic]: a
  /// paired device (RFCOMM); [advert]: this device's advert (an invitation
  /// carries it).
  Future<bool> connect(
    String device,
    LocalLinkEndpoint endpoint, {
    int psm = 0,
    bool classic = false,
    String? advert,
  });

  /// Pumps the incoming stream [id] into [endpoint].
  Future<bool> accept(String id, LocalLinkEndpoint endpoint);

  /// Closes (declines) the incoming stream [id].
  Future<void> reject(String id);

  /// `{type: seen, device, advert, psm?, connectable?}`,
  /// `{type: incoming, id, advert?}`, `{type: radio, on}`.
  Stream<Map<Object?, Object?>> get events;
}

/// A radio behind a platform channel: [name] for the calls, `[name]/events`
/// for the events (ZenBluetoothLinkBridge.kt, ZenLocalLinksBridge.swift).
final class MethodChannelLinkRadio implements NativeLinkRadio {
  const MethodChannelLinkRadio(this.name);

  final String name;

  MethodChannel get _channel => MethodChannel(name);

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on Object catch (error) {
      logZenWarning('$name $method failed: $error');
      return null;
    }
  }

  @override
  Future<Map<String, Object?>> state() async {
    final Map<Object?, Object?>? raw = await _call<Map<Object?, Object?>>(
      'state',
    );
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e
          in (raw ?? const <Object?, Object?>{}).entries)
        '${e.key}': e.value,
    };
  }

  @override
  Future<bool> requestPermissions() async =>
      await _call<bool>('requestPermissions') ?? false;

  @override
  Future<bool> start() async => await _call<bool>('start') ?? false;

  @override
  Future<void> stop() => _call<void>('stop');

  @override
  Future<void> advertise(String advertHex, Duration window) => _call<bool>(
    'advertise',
    <String, Object>{'advert': advertHex, 'windowMs': window.inMilliseconds},
  );

  @override
  Future<void> scan(Duration window) =>
      _call<bool>('scan', <String, Object>{'windowMs': window.inMilliseconds});

  @override
  Future<List<String>> pairedDevices() async {
    final List<Object?>? raw = await _call<List<Object?>>('pairedDevices');
    return raw?.whereType<String>().toList(growable: false) ?? const <String>[];
  }

  @override
  Future<bool> connect(
    String device,
    LocalLinkEndpoint endpoint, {
    int psm = 0,
    bool classic = false,
    String? advert,
  }) async =>
      await _call<bool>('connect', <String, Object>{
        'device': device,
        'psm': psm,
        'classic': classic,
        'port': endpoint.port,
        'token': endpoint.token,
        'advert': ?advert,
      }) ??
      false;

  @override
  Future<bool> accept(String id, LocalLinkEndpoint endpoint) async =>
      await _call<bool>('accept', <String, Object>{
        'id': id,
        'port': endpoint.port,
        'token': endpoint.token,
      }) ??
      false;

  @override
  Future<void> reject(String id) =>
      _call<void>('reject', <String, Object>{'id': id});

  @override
  Stream<Map<Object?, Object?>> get events => EventChannel('$name/events')
      .receiveBroadcastStream()
      .where((Object? e) => e is Map)
      .cast<Map<Object?, Object?>>();
}

final class NativeStreamLocalLink extends LocalLink {
  NativeStreamLocalLink({
    required this.transport,
    required NativeLinkRadio radio,
    required bool supportedPlatform,
    DateTime Function()? now,
    this.foregroundCycle = const Duration(seconds: 30),
    this.backgroundCycle = const Duration(minutes: 2),
    this.foregroundAdvertise = const Duration(seconds: 25),
    this.backgroundAdvertise = const Duration(seconds: 40),
    this.scanWindow = const Duration(seconds: 8),
    this.waitForPeer = const Duration(seconds: 20),
    this.retryAfter = const Duration(minutes: 1),
    this.foregroundPairedRetry = const Duration(minutes: 2),
    this.backgroundPairedRetry = const Duration(minutes: 10),
    this.maxDials = 2,
  }) : _radio = radio,
       _supportedPlatform = supportedPlatform,
       _now = now ?? DateTime.now;

  @override
  final LocalLinkTransport transport;

  final NativeLinkRadio _radio;
  final bool _supportedPlatform;
  final DateTime Function() _now;
  final Duration foregroundCycle;
  final Duration backgroundCycle;

  /// How long the advert is shown in each cycle.
  final Duration foregroundAdvertise;
  final Duration backgroundAdvertise;
  final Duration scanWindow;

  /// How long a friend whose advert is lower may take to connect before
  /// this device connects itself.
  final Duration waitForPeer;

  /// A device tried is not tried again for this long.
  final Duration retryAfter;

  /// How often a paired device is tried.
  final Duration foregroundPairedRetry;
  final Duration backgroundPairedRetry;

  /// Streams being opened at once at most.
  final int maxDials;

  /// Seen devices and tries are forgotten after this long.
  static const Duration _forgetAfter = Duration(minutes: 10);

  final ValueNotifier<LocalLinkState> _state = ValueNotifier<LocalLinkState>(
    LocalLinkState.off,
  );

  LocalLinkNodeApi? Function() _node = _noNode;
  static LocalLinkNodeApi? _noNode() => null;
  bool _running = false;
  bool _foreground = false;
  bool _listening = false;
  bool _busy = false;
  int _advertBytes = 0;
  String? _ownAdvert;
  Timer? _timer;
  StreamSubscription<Map<Object?, Object?>>? _events;

  /// Friends' devices seen: when first seen (for [waitForPeer]).
  final Map<String, DateTime> _waiting = <String, DateTime>{};

  /// When a device was last tried.
  final Map<String, DateTime> _tried = <String, DateTime>{};
  final Set<String> _dialing = <String>{};

  @override
  bool get isSupported => _supportedPlatform;

  @override
  ValueListenable<LocalLinkState> get state => _state;

  void _setPhase(LocalLinkPhase phase, {int peers = 0}) {
    _state.value = LocalLinkState(phase, peers: peers);
  }

  @override
  Future<bool> requestPermissions() async {
    if (!_supportedPlatform) {
      return false;
    }
    return _radio.requestPermissions();
  }

  @override
  Future<void> start(
    LocalLinkNodeApi? Function() node, {
    required bool foreground,
  }) async {
    _node = node;
    _foreground = foreground;
    if (_running) {
      return;
    }
    if (!_supportedPlatform) {
      _setPhase(LocalLinkPhase.unavailable);
      return;
    }
    _running = true;
    final Map<String, Object?> state = await _radio.state();
    if (!_running) {
      return;
    }
    if (state['supported'] != true) {
      _running = false;
      _setPhase(LocalLinkPhase.unavailable);
      return;
    }
    if (state['permitted'] != true) {
      _running = false;
      _setPhase(LocalLinkPhase.needsPermission);
      return;
    }
    final Object? bytes = state['advertBytes'];
    _advertBytes = bytes is int && bytes >= 0 ? bytes : 0;
    _events = _radio.events.listen(
      _onEvent,
      onError: (Object error) => logZenWarning('${transport.wireName}: $error'),
    );
    await runCycle();
  }

  @override
  void setForeground(bool foreground) {
    if (_foreground == foreground) {
      return;
    }
    _foreground = foreground;
    if (_running) {
      _schedule();
    }
  }

  @override
  Future<void> stop() async {
    if (_running) {
      await _shutDown();
    }
    _setPhase(LocalLinkPhase.off);
  }

  Future<void> _shutDown() async {
    _running = false;
    _listening = false;
    _timer?.cancel();
    _timer = null;
    await _events?.cancel();
    _events = null;
    _waiting.clear();
    _tried.clear();
    _ownAdvert = null;
    // The radio stops advertising and scanning and closes every stream.
    await _radio.stop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_events?.cancel());
    _state.dispose();
  }

  void _schedule([Duration? after]) {
    _timer?.cancel();
    if (!_running) {
      return;
    }
    _timer = Timer(
      after ?? (_foreground ? foregroundCycle : backgroundCycle),
      () => unawaited(runCycle()),
    );
  }

  /// One cycle: a new advert shown for a while, a scan window, the paired
  /// devices, and the status line.
  @visibleForTesting
  Future<void> runCycle() async {
    if (!_running || _busy) {
      return;
    }
    _busy = true;
    try {
      await _cycle();
    } on Object catch (error) {
      logZenWarning('${transport.wireName} cycle failed: $error');
    } finally {
      _busy = false;
      _schedule();
    }
  }

  Future<void> _cycle() async {
    final Map<String, Object?> state = await _radio.state();
    if (!_running) {
      return;
    }
    if (state['permitted'] != true) {
      // Taken back in the system settings.
      await _shutDown();
      _setPhase(LocalLinkPhase.needsPermission);
      return;
    }
    if (state['enabled'] != true) {
      _listening = false;
      _setPhase(LocalLinkPhase.radioOff);
      return;
    }
    if (!_listening) {
      _listening = await _radio.start();
      if (!_listening) {
        _setPhase(LocalLinkPhase.radioOff);
        return;
      }
    }
    _forgetOld();
    final LocalLinkNodeApi? api = _node();
    if (api == null) {
      _setPhase(LocalLinkPhase.searching);
      return;
    }
    if (state['discovery'] != false) {
      final String? advert = _advert(api);
      if (advert != null) {
        _ownAdvert = advert;
        await _radio.advertise(
          advert,
          _foreground ? foregroundAdvertise : backgroundAdvertise,
        );
      }
      await _radio.scan(scanWindow);
    }
    if (state['paired'] == true) {
      await _dialPaired(api);
    }
    _updatePhase(api);
  }

  String? _advert(LocalLinkNodeApi api) {
    try {
      return api.advert(bytes: _advertBytes);
    } on Object catch (error) {
      logZenWarning('${transport.wireName}: no advert: $error');
      return null;
    }
  }

  void _updatePhase(LocalLinkNodeApi api) {
    int links = 0;
    try {
      links = api
          .status()
          .upLinks
          .where((LocalLinkInfo l) => l.transport == transport)
          .length;
    } on Object catch (error) {
      logZenWarning('${transport.wireName}: no status: $error');
    }
    _setPhase(
      links > 0 ? LocalLinkPhase.connected : LocalLinkPhase.searching,
      peers: links,
    );
  }

  void _forgetOld() {
    final DateTime now = _now();
    _waiting.removeWhere(
      (String _, DateTime at) => now.difference(at) > _forgetAfter,
    );
    _tried.removeWhere(
      (String _, DateTime at) => now.difference(at) > _forgetAfter,
    );
  }

  Future<void> _dialPaired(LocalLinkNodeApi api) async {
    final List<String> devices = await _radio.pairedDevices();
    final Duration retry = _foreground
        ? foregroundPairedRetry
        : backgroundPairedRetry;
    final DateTime now = _now();
    for (final String device in devices) {
      if (!_running || _dialing.length >= maxDials) {
        return;
      }
      final DateTime? last = _tried[device];
      if (last != null && now.difference(last) < retry) {
        continue;
      }
      _tried[device] = now;
      unawaited(_dial(api, device, classic: true));
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (!_running) {
      return;
    }
    switch (event['type']) {
      case 'seen':
        _onSeenEvent(event);
      case 'incoming':
        _onIncomingEvent(event);
      case 'radio':
        // Bluetooth went on or off: look again soon.
        _listening = false;
        _schedule(const Duration(seconds: 1));
    }
  }

  void _onSeenEvent(Map<Object?, Object?> event) {
    final Object? device = event['device'];
    final Object? advert = event['advert'];
    final Object? psm = event['psm'];
    if (device is String && advert is String) {
      unawaited(
        onSeen(
          device: device,
          advert: advert,
          psm: psm is int ? psm : 0,
          connectable: event['connectable'] != false,
        ),
      );
    }
  }

  void _onIncomingEvent(Map<Object?, Object?> event) {
    final Object? id = event['id'];
    final Object? advert = event['advert'];
    if (id is String) {
      unawaited(onIncoming(id, advert: advert is String ? advert : null));
    }
  }

  bool _matches(LocalLinkNodeApi api, String advert) {
    try {
      return api.matches(advert.toLowerCase());
    } on Object catch (error) {
      logZenWarning('${transport.wireName}: advert not tested: $error');
      return false;
    }
  }

  /// A Zen device's advert was seen nearby.
  @visibleForTesting
  Future<void> onSeen({
    required String device,
    required String advert,
    int psm = 0,
    bool connectable = true,
  }) async {
    final LocalLinkNodeApi? api = _node();
    if (!_running || api == null || !connectable) {
      return;
    }
    if (!_matches(api, advert)) {
      // A stranger, or a friend linked already.
      return;
    }
    final DateTime now = _now();
    final DateTime? last = _tried[device];
    if (last != null && now.difference(last) < retryAfter) {
      return;
    }
    final DateTime firstSeen = _waiting.putIfAbsent(device, () => now);
    final String? own = _ownAdvert;
    final bool mine = own == null || own.compareTo(advert.toLowerCase()) < 0;
    if (!mine && now.difference(firstSeen) < waitForPeer) {
      // The friend connects.
      return;
    }
    _tried[device] = now;
    await _dial(api, device, psm: psm);
  }

  /// Someone opened a stream to this device (or invites it).
  @visibleForTesting
  Future<void> onIncoming(String id, {String? advert}) async {
    final LocalLinkNodeApi? api = _node();
    if (!_running ||
        api == null ||
        (advert != null && !_matches(api, advert))) {
      await _radio.reject(id);
      return;
    }
    final LocalLinkEndpoint? endpoint = _open(api);
    if (endpoint == null) {
      await _radio.reject(id);
      return;
    }
    if (!await _radio.accept(id, endpoint)) {
      _close(api, endpoint.id);
    }
  }

  Future<void> _dial(
    LocalLinkNodeApi api,
    String device, {
    int psm = 0,
    bool classic = false,
  }) async {
    if (_dialing.contains(device) || _dialing.length >= maxDials) {
      return;
    }
    final LocalLinkEndpoint? endpoint = _open(api);
    if (endpoint == null) {
      return;
    }
    _dialing.add(device);
    try {
      final bool connected = await _radio.connect(
        device,
        endpoint,
        psm: psm,
        classic: classic,
        advert: _ownAdvert,
      );
      if (connected) {
        _waiting.remove(device);
      } else {
        _close(api, endpoint.id);
      }
    } finally {
      _dialing.remove(device);
    }
  }

  LocalLinkEndpoint? _open(LocalLinkNodeApi api) {
    try {
      return api.openStream(transport);
    } on Object catch (error) {
      logZenWarning('${transport.wireName}: no endpoint: $error');
      return null;
    }
  }

  void _close(LocalLinkNodeApi api, String id) {
    try {
      api.close(id);
    } on Object catch (error) {
      logZenWarning('${transport.wireName}: endpoint not closed: $error');
    }
  }
}
