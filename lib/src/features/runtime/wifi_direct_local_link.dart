import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/local_link.dart';

// Wi-Fi Direct (Android 10+, §5.1 item 6): with no Wi-Fi network around,
// friends' phones nearby form a Wi-Fi Direct group, and the bridge's LAN
// discovery links them over it like over any Wi-Fi (lan_discovery.go). The
// radio is ZenWifiDirectBridge.kt; this file decides what it does.
//
// Every phone publishes a service record with the bridge's advert (a Bloom
// filter only friends can test, renewed every cycle) and looks for others'
// records in short windows. Seeing a friend's record:
//  * if it names a group (its owner publishes the name and passphrase),
//    join it: no system prompt on Android 10+;
//  * if neither phone has a group, the one whose advert is lower creates
//    one; the other joins once the record names it (or creates one itself
//    if nothing comes);
//  * two lonely groups: the one with the greater name gives up its group
//    and joins the other.
// A matching record proves nothing (it can be replayed, and its group can be
// anyone's), so a joined group is kept only once a friend's pair handshake
// succeeded over it: with no link after [joinHandshakeTimeout] the phone
// leaves and does not join that group again for [refuseGroupFor].
// A group with no link for a while is removed. Nothing runs while the
// phone is on a Wi-Fi network (the LAN covers that) or the app is neither
// used nor running its background service.

/// The radio side (ZenWifiDirectBridge.kt); a fake in tests.
abstract interface class WifiDirectRadio {
  /// `{supported, permitted, enabled, wifi, group}`.
  Future<Map<String, Object?>> state();
  Future<bool> requestPermissions();
  Future<bool> start();
  Future<void> stop();
  Future<void> setAdvert(String advertHex);
  Future<void> discover(Duration window);
  Future<bool> createGroup();
  Future<bool> joinGroup(String name, String passphrase);
  Future<bool> removeGroup();

  /// `{type: peer|group|wifi|p2p, …}`.
  Stream<Map<Object?, Object?>> get events;
}

final class MethodChannelWifiDirectRadio implements WifiDirectRadio {
  const MethodChannelWifiDirectRadio();

  static const MethodChannel _channel = MethodChannel('zen/wifi_direct');
  static const EventChannel _events = EventChannel('zen/wifi_direct/events');

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on Object catch (error) {
      logZenWarning('Wi-Fi Direct $method failed: $error');
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
  Future<void> setAdvert(String advertHex) =>
      _call<bool>('setAdvert', <String, Object>{'advert': advertHex});

  @override
  Future<void> discover(Duration window) => _call<bool>(
    'discover',
    <String, Object>{'windowMs': window.inMilliseconds},
  );

  @override
  Future<bool> createGroup() async => await _call<bool>('createGroup') ?? false;

  @override
  Future<bool> joinGroup(String name, String passphrase) async =>
      await _call<bool>('joinGroup', <String, Object>{
        'name': name,
        'passphrase': passphrase,
      }) ??
      false;

  @override
  Future<bool> removeGroup() async => await _call<bool>('removeGroup') ?? false;

  @override
  Stream<Map<Object?, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((Object? e) => e is Map)
      .cast<Map<Object?, Object?>>();
}

/// The Wi-Fi Direct group this phone is in.
@immutable
final class WifiDirectGroup {
  const WifiDirectGroup({
    required this.owner,
    required this.name,
    this.passphrase,
    this.clients = 0,
  });

  final bool owner;
  final String name;
  final String? passphrase;
  final int clients;

  static WifiDirectGroup? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? name = json['name'];
    final Object? passphrase = json['passphrase'];
    final Object? clients = json['clients'];
    if (name is! String) {
      return null;
    }
    return WifiDirectGroup(
      owner: json['owner'] == true,
      name: name,
      passphrase: passphrase is String ? passphrase : null,
      clients: clients is int ? clients : 0,
    );
  }
}

final class WifiDirectLocalLink extends LocalLink {
  WifiDirectLocalLink({
    WifiDirectRadio radio = const MethodChannelWifiDirectRadio(),
    bool? supportedPlatform,
    DateTime Function()? now,
    this.foregroundCycle = const Duration(seconds: 45),
    this.backgroundCycle = const Duration(minutes: 3),
    this.discoveryWindow = const Duration(seconds: 20),
    this.idleGroupTimeout = const Duration(minutes: 2),
    this.waitForFriendGroup = const Duration(seconds: 90),
    this.joinHandshakeTimeout = const Duration(seconds: 60),
    this.refuseGroupFor = const Duration(minutes: 30),
  }) : _radio = radio,
       _supportedPlatform = supportedPlatform ?? Platform.isAndroid,
       _now = now ?? DateTime.now;

  /// Bloom filter bytes in a service record: it must fit a TXT entry.
  static const int advertBytes = 32;

  final WifiDirectRadio _radio;
  final bool _supportedPlatform;
  final DateTime Function() _now;
  final Duration foregroundCycle;
  final Duration backgroundCycle;
  final Duration discoveryWindow;

  /// A group with no link for this long is removed.
  final Duration idleGroupTimeout;

  /// How long to wait for a friend (with the lower advert) to make a group
  /// before making one here.
  final Duration waitForFriendGroup;

  /// A joined group (someone else's) with no friend's link over it after
  /// this long is left: only the pair handshake shows it is a friend's.
  /// Two beacon periods in the background (30 s each) fit.
  final Duration joinHandshakeTimeout;

  /// How long a group left that way is not joined again.
  final Duration refuseGroupFor;

  /// The most groups remembered in [_refused].
  static const int _maxRefused = 64;

  final ValueNotifier<LocalLinkState> _state = ValueNotifier<LocalLinkState>(
    LocalLinkState.off,
  );

  LocalLinkNodeApi? Function() _node = _noNode;
  static LocalLinkNodeApi? _noNode() => null;
  bool _running = false;
  bool _foreground = false;
  bool _wifi = false;
  WifiDirectGroup? _group;
  DateTime? _groupSince;
  DateTime? _lastLinkAt;
  String? _ownAdvert;
  bool _busy = false;
  Timer? _timer;
  StreamSubscription<Map<Object?, Object?>>? _events;

  /// Friends' records seen while neither had a group: when first seen.
  final Map<String, DateTime> _waiting = <String, DateTime>{};

  /// Groups left without a handshake: name → not joined again until then.
  final Map<String, DateTime> _refused = <String, DateTime>{};

  @override
  LocalLinkTransport get transport => LocalLinkTransport.wifiDirect;

  @override
  bool get isSupported => _supportedPlatform;

  @override
  ValueListenable<LocalLinkState> get state => _state;

  @visibleForTesting
  WifiDirectGroup? get group => _group;

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
    _events = _radio.events.listen(
      _onEvent,
      onError: (Object error) => logZenWarning('Wi-Fi Direct: $error'),
    );
    if (!await _radio.start()) {
      await _shutDown();
      _setPhase(LocalLinkPhase.needsPermission);
      return;
    }
    // Read again: the radio knows the Wi-Fi network and the group only
    // once it runs (later changes come as events).
    final Map<String, Object?> started = await _radio.state();
    _wifi = started['wifi'] == true;
    _setGroup(WifiDirectGroup.fromJson(started['group']));
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
    if (!_running) {
      _setPhase(LocalLinkPhase.off);
      return;
    }
    await _shutDown();
    _setPhase(LocalLinkPhase.off);
  }

  Future<void> _shutDown() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _events?.cancel();
    _events = null;
    _waiting.clear();
    _group = null;
    _groupSince = null;
    _lastLinkAt = null;
    _ownAdvert = null;
    // The radio removes the group, the record and the discovery.
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
    Duration delay = after ?? (_foreground ? foregroundCycle : backgroundCycle);
    final Duration? handshake = _handshakeLeft();
    if (handshake != null && handshake < delay) {
      // Look again when a joined group must have shown a friend.
      delay = handshake;
    }
    _timer = Timer(delay, () => unawaited(runCycle()));
  }

  /// How long a joined group without a link yet still has for the
  /// handshake; null when that does not apply.
  Duration? _handshakeLeft() {
    final WifiDirectGroup? group = _group;
    final DateTime? since = _groupSince;
    if (group == null || group.owner || since == null || _lastLinkAt != null) {
      return null;
    }
    final Duration left = joinHandshakeTimeout - _now().difference(since);
    return left < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : left;
  }

  /// Whether [name] was left without a handshake recently.
  bool _isRefused(String name) {
    final DateTime now = _now();
    _refused.removeWhere((String _, DateTime until) => !until.isAfter(now));
    return _refused.containsKey(name);
  }

  void _setGroup(WifiDirectGroup? group) {
    final bool changed = group?.name != _group?.name;
    _group = group;
    if (group == null) {
      _groupSince = null;
      _lastLinkAt = null;
    } else if (changed || _groupSince == null) {
      // Another group: its handshake has yet to happen.
      _groupSince = _now();
      _lastLinkAt = null;
      _waiting.clear();
    }
  }

  /// One cycle: a new advert, a discovery window or a look at the group.
  @visibleForTesting
  Future<void> runCycle() async {
    if (!_running || _busy) {
      return;
    }
    _busy = true;
    try {
      await _cycle();
    } on Object catch (error) {
      logZenWarning('Wi-Fi Direct cycle failed: $error');
    } finally {
      _busy = false;
      _schedule();
    }
  }

  Future<void> _cycle() async {
    final WifiDirectGroup? group = _group;
    if (_wifi && group == null) {
      // A Wi-Fi network: friends there are found over it.
      _setPhase(LocalLinkPhase.idle);
      return;
    }
    final LocalLinkNodeApi? api = _node();
    if (api == null) {
      _setPhase(LocalLinkPhase.searching);
      return;
    }
    final String? advert = api.advert(bytes: advertBytes);
    if (advert != null) {
      _ownAdvert = advert;
      await _radio.setAdvert(advert);
    }
    if (group == null) {
      _setPhase(LocalLinkPhase.searching);
      await _radio.discover(discoveryWindow);
      return;
    }
    final int links = api
        .status()
        .upLinks
        .where(
          (LocalLinkInfo l) => l.transport == LocalLinkTransport.wifiDirect,
        )
        .length;
    final DateTime now = _now();
    if (links > 0) {
      _lastLinkAt = now;
      _setPhase(LocalLinkPhase.connected, peers: links);
      return;
    }
    if (!group.owner &&
        _lastLinkAt == null &&
        now.difference(_groupSince ?? now) >= joinHandshakeTimeout) {
      // No friend's handshake over a group joined because a record
      // matched: perhaps a replayed record. Leave it, and stay away.
      if (_refused.length >= _maxRefused) {
        _refused.remove(_refused.keys.first);
      }
      _refused[group.name] = now.add(refuseGroupFor);
      await _radio.removeGroup();
      _setGroup(null);
      _setPhase(LocalLinkPhase.searching);
      return;
    }
    final DateTime since = _lastLinkAt ?? _groupSince ?? now;
    if (now.difference(since) >= idleGroupTimeout) {
      // Nobody linked over it for a while: give the radio back.
      await _radio.removeGroup();
      _setGroup(null);
      _setPhase(LocalLinkPhase.searching);
      return;
    }
    _setPhase(LocalLinkPhase.searching);
    if (group.owner) {
      // More friends may come; they find this phone's record.
      await _radio.discover(discoveryWindow);
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (!_running) {
      return;
    }
    switch (event['type']) {
      case 'peer':
        unawaited(
          onPeer(
            device: '${event['device']}',
            advert: '${event['advert']}',
            name: _text(event['name']),
            passphrase: _text(event['passphrase']),
          ),
        );
      case 'group':
        _setGroup(WifiDirectGroup.fromJson(event['group']));
        _schedule(const Duration(seconds: 2));
      case 'wifi':
        _wifi = event['connected'] == true;
        _schedule(const Duration(seconds: 1));
    }
  }

  static String? _text(Object? value) => value is String ? value : null;

  /// A Zen phone's record was seen nearby.
  @visibleForTesting
  Future<void> onPeer({
    required String device,
    required String advert,
    String? name,
    String? passphrase,
  }) async {
    final LocalLinkNodeApi? api = _node();
    if (!_running || api == null || !api.matches(advert)) {
      // A stranger, or a friend linked already.
      return;
    }
    if (name != null && _isRefused(name)) {
      // Left before without a friend's handshake.
      return;
    }
    final WifiDirectGroup? group = _group;
    final bool offersGroup = name != null && passphrase != null;
    if (group != null) {
      // Two lonely groups: the greater name joins the other.
      if (group.owner &&
          group.clients == 0 &&
          offersGroup &&
          name != group.name &&
          group.name.compareTo(name) > 0) {
        await _radio.removeGroup();
        _setGroup(null);
        await _radio.joinGroup(name, passphrase);
      }
      return;
    }
    if (offersGroup) {
      await _radio.joinGroup(name, passphrase);
      return;
    }
    final String? own = _ownAdvert;
    final DateTime now = _now();
    final DateTime firstSeen = _waiting.putIfAbsent(device, () => now);
    if ((own != null && own.compareTo(advert) < 0) ||
        now.difference(firstSeen) >= waitForFriendGroup) {
      _waiting.remove(device);
      await _radio.createGroup();
    }
  }
}
